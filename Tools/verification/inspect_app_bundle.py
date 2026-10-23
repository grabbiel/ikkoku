#!/usr/bin/env python3
"""Inspect a built Ikkoku.app for release packaging (T-T02).

Checks a built `.app` against the reviewed rules in `app-bundle-rules.json`
and writes a JSON report:

- the bundle holds what the app loads at runtime: the precompiled
  `IkkokuShaders.metallib`, `catalog.json` and every model, mask and texture
  the catalog references, plus the expected Info.plist identity;
- every Mach-O file contains the required architectures (arm64);
- every other file is a declared build product or a git-tracked `Assets/`
  file (the Xcode target copies its synchronized `Assets/` folder from disk,
  so untracked or ignored files there would otherwise ship);
- nothing private is embedded: no `.local/` or original-installation paths,
  recovered source, managed assemblies, Unity asset bundles, mod archives or
  card/scene payloads, and no absolute build-machine paths in Info.plist,
  text resources, PNG text chunks or GLB JSON chunks.

Stdlib only; reads the bundle and runs `git ls-files`/`rev-parse`/`status` in
the checkout. It never launches the app, so it cannot show that resource
lookup succeeds at runtime.

Usage:
  python3 Tools/verification/inspect_app_bundle.py PATH/Ikkoku.app
      [--rules PATH] [--checkout PATH] [--report PATH]

Exit status: 0 when no error finding, 1 when there is one, 2 for invalid
arguments or an invalid rules file.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_RULES = os.path.join(HERE, "app-bundle-rules.json")
SCHEMA_VERSION = 1
SEVERITIES = ("error", "warning")
# Files above this size are hashed in chunks and not scanned for content.
MAX_SCAN_BYTES = 256 * 1024 * 1024
# Bound for one decompressed PNG text chunk.
MAX_TEXT_CHUNK_BYTES = 4 * 1024 * 1024

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_TEXT_CHUNKS = (b"tEXt", b"zTXt", b"iTXt")
GLB_MAGIC = b"glTF"
GLB_JSON_CHUNK = 0x4E4F534A

# Mach-O magics. Thin files store the magic in the file's byte order, fat
# headers are always big-endian.
MACHO_THIN = {
    b"\xcf\xfa\xed\xfe": "<", b"\xce\xfa\xed\xfe": "<",
    b"\xfe\xed\xfa\xcf": ">", b"\xfe\xed\xfa\xce": ">",
}
FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT_MAGIC_64 = b"\xca\xfe\xba\xbf"
# Java class files share 0xcafebabe; their next word is a class version
# (>= 45), never a plausible slice count.
MAX_FAT_ARCHS = 16
CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_X86 = 7
CPU_TYPE_ARM = 12
CPU_TYPE_POWERPC = 18
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_MASK = 0x00FFFFFF

RULE_KEYS = {"schemaVersion", "reviewed", "description", "infoPlist", "executable",
             "required", "catalog", "assets", "buildProducts", "unexpectedFiles",
             "forbidden", "pathScan"}
FORBIDDEN_KEYS = {"id", "why", "pathComponents", "extensions", "magic", "content",
                  "pngTrailingData", "markers"}


class RulesError(ValueError):
    """The rules file is malformed."""


# ---------------------------------------------------------------- rules


def _require(condition, message):
    if not condition:
        raise RulesError(message)


def _string_list(value, name):
    _require(isinstance(value, list) and all(isinstance(v, str) and v for v in value),
             "%s must be a list of nonempty strings" % name)
    return value


def _relative(path, name):
    _require(isinstance(path, str) and path and not path.startswith("/")
             and ".." not in path.split("/"), "%s must be a relative path inside the bundle" % name)
    return path


def load_rules(path):
    """Loads and validates the rules file; raises RulesError."""
    try:
        with open(path, encoding="utf-8") as handle:
            rules = json.load(handle)
    except (OSError, ValueError) as error:
        raise RulesError("cannot read rules %s: %s" % (path, error))
    _require(isinstance(rules, dict), "rules must be a JSON object")
    _require(rules.get("schemaVersion") == SCHEMA_VERSION,
             "rules schemaVersion must be %d" % SCHEMA_VERSION)
    unknown = set(rules) - RULE_KEYS
    _require(not unknown, "unknown rules keys: %s" % ", ".join(sorted(unknown)))

    info = rules.get("infoPlist")
    _require(isinstance(info, dict), "infoPlist must be an object")
    _relative(info.get("path"), "infoPlist.path")
    _require(isinstance(info.get("expect", {}), dict)
             and all(isinstance(v, str) for v in info.get("expect", {}).values()),
             "infoPlist.expect must map keys to strings")
    _string_list(info.get("record", []), "infoPlist.record")

    executable = rules.get("executable")
    _require(isinstance(executable, dict), "executable must be an object")
    _relative(executable.get("path"), "executable.path")
    _string_list(executable.get("requiredArchitectures"), "executable.requiredArchitectures")

    required = rules.get("required")
    _require(isinstance(required, list), "required must be a list")
    for entry in required:
        _require(isinstance(entry, dict), "required entries must be objects")
        _relative(entry.get("path"), "required[].path")
        _require(isinstance(entry.get("magic", ""), str), "required[].magic must be a string")

    catalog = rules.get("catalog")
    _require(isinstance(catalog, dict), "catalog must be an object")
    _relative(catalog.get("path"), "catalog.path")
    _relative(catalog.get("root"), "catalog.root")
    _require(isinstance(catalog.get("bareNameDirectory"), str), "catalog.bareNameDirectory must be a string")
    _string_list(catalog.get("referenceExtensions"), "catalog.referenceExtensions")
    _require(isinstance(catalog.get("ignoredKeys", {}), dict), "catalog.ignoredKeys must be an object")

    assets = rules.get("assets")
    _require(isinstance(assets, dict), "assets must be an object")
    _relative(assets.get("source"), "assets.source")
    _relative(assets.get("destination"), "assets.destination")
    _string_list(assets.get("explicitFolders"), "assets.explicitFolders")
    _string_list(assets.get("excluded", []), "assets.excluded")

    products = rules.get("buildProducts")
    _require(isinstance(products, list) and all(isinstance(p, dict) and isinstance(p.get("pattern"), str)
                                                for p in products),
             "buildProducts must be a list of {pattern, why}")
    _require(rules.get("unexpectedFiles") in SEVERITIES,
             "unexpectedFiles must be one of %s" % ", ".join(SEVERITIES))

    forbidden = rules.get("forbidden")
    _require(isinstance(forbidden, list), "forbidden must be a list")
    seen = set()
    for rule in forbidden:
        _require(isinstance(rule, dict) and isinstance(rule.get("id"), str) and rule["id"],
                 "forbidden entries need an id")
        _require(rule["id"] not in seen, "duplicate forbidden id %s" % rule["id"])
        seen.add(rule["id"])
        unknown = set(rule) - FORBIDDEN_KEYS
        _require(not unknown, "forbidden %s: unknown keys %s" % (rule["id"], ", ".join(sorted(unknown))))
        for key in ("pathComponents", "extensions", "magic", "markers"):
            if key in rule:
                _string_list(rule[key], "forbidden %s.%s" % (rule["id"], key))
        _require(rule.get("content") in (None, "pe"), "forbidden %s.content must be \"pe\"" % rule["id"])
        _require(isinstance(rule.get("pngTrailingData", False), bool),
                 "forbidden %s.pngTrailingData must be a boolean" % rule["id"])
        _require(any(key in rule for key in ("pathComponents", "extensions", "magic", "content",
                                             "pngTrailingData", "markers")),
                 "forbidden %s matches nothing" % rule["id"])

    scan = rules.get("pathScan")
    _require(isinstance(scan, dict) and isinstance(scan.get("id"), str), "pathScan needs an id")
    _string_list(scan.get("patterns"), "pathScan.patterns")
    _string_list(scan.get("textExtensions"), "pathScan.textExtensions")
    _require(isinstance(scan.get("includeCheckoutRoot", False), bool),
             "pathScan.includeCheckoutRoot must be a boolean")
    return rules


# ---------------------------------------------------------------- file formats


def macho_architectures(data):
    """Architecture names of a Mach-O file, or None if `data` is not one."""
    magic = data[:4]
    if magic in MACHO_THIN:
        if len(data) < 12:
            return None
        cputype, subtype = struct.unpack(MACHO_THIN[magic] + "ii", data[4:12])
        return [cpu_name(cputype, subtype)]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        if len(data) < 8:
            return None
        count = struct.unpack(">I", data[4:8])[0]
        if not 0 < count <= MAX_FAT_ARCHS:
            return None
        size = 32 if magic == FAT_MAGIC_64 else 20
        if len(data) < 8 + count * size:
            return None
        names = []
        for index in range(count):
            offset = 8 + index * size
            cputype, subtype = struct.unpack(">ii", data[offset:offset + 8])
            names.append(cpu_name(cputype, subtype))
        return names
    return None


def cpu_name(cputype, subtype):
    subtype &= CPU_SUBTYPE_MASK
    if cputype == CPU_TYPE_ARM | CPU_ARCH_ABI64:
        return "arm64e" if subtype == CPU_SUBTYPE_ARM64E else "arm64"
    if cputype == CPU_TYPE_X86 | CPU_ARCH_ABI64:
        return "x86_64"
    if cputype == CPU_TYPE_X86:
        return "i386"
    if cputype == CPU_TYPE_ARM:
        return "arm"
    if cputype == CPU_TYPE_POWERPC:
        return "ppc"
    return "cputype-0x%x" % (cputype & 0xFFFFFFFF)


def is_pe(data):
    """True for a DOS/PE image ("MZ" header whose e_lfanew points at "PE\\0\\0")."""
    if len(data) < 0x40 or data[:2] != b"MZ":
        return False
    offset = struct.unpack("<I", data[0x3C:0x40])[0]
    return data[offset:offset + 4] == b"PE\0\0"


def png_structure(data):
    """(text chunk payloads, trailing bytes after IEND, error) for a PNG file."""
    if not data.startswith(PNG_SIGNATURE):
        return [], b"", "missing PNG signature"
    offset = len(PNG_SIGNATURE)
    texts = []
    while True:
        if offset + 8 > len(data):
            return texts, b"", "truncated before IEND"
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        end = offset + 12 + length
        if end > len(data):
            return texts, b"", "truncated %s chunk" % kind.decode("latin-1")
        payload = data[offset + 8:offset + 8 + length]
        if kind in PNG_TEXT_CHUNKS:
            texts.append(png_text(kind, payload))
        offset = end
        if kind == b"IEND":
            return texts, data[offset:], None


def png_text(kind, payload):
    """The text of a tEXt/zTXt/iTXt chunk (keyword included), decompressed when needed."""
    keyword, _, rest = payload.partition(b"\0")
    try:
        if kind == b"zTXt" and rest:
            rest = zlib.decompressobj().decompress(rest[1:], MAX_TEXT_CHUNK_BYTES)
        elif kind == b"iTXt" and len(rest) >= 2:
            compressed, rest = rest[0], rest[2:]
            _, _, rest = rest.partition(b"\0")   # language tag
            _, _, rest = rest.partition(b"\0")   # translated keyword
            if compressed:
                rest = zlib.decompressobj().decompress(rest, MAX_TEXT_CHUNK_BYTES)
    except zlib.error:
        pass
    return keyword + b"\0" + rest


def glb_json(data):
    """(JSON chunk bytes, error) of a binary glTF file."""
    if len(data) < 20 or data[:4] != GLB_MAGIC:
        return b"", "missing glTF header"
    length, chunk_type = struct.unpack("<II", data[12:20])
    if chunk_type != GLB_JSON_CHUNK or 20 + length > len(data):
        return b"", "first chunk is not a complete JSON chunk"
    return data[20:20 + length], None


def plist_strings(value):
    """Every string key/value inside a decoded property list."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from plist_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from plist_strings(item)


# ---------------------------------------------------------------- checkout


def _git(checkout, *args):
    try:
        result = subprocess.run(["git", "-C", checkout] + list(args), capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        return None, str(error)
    if result.returncode != 0:
        return None, result.stderr.decode("utf-8", "replace").strip() or "exit %d" % result.returncode
    return result.stdout, None


def git_tracked(checkout, source):
    """(sorted tracked paths under `source`, relative to it; error)."""
    output, error = _git(checkout, "ls-files", "-z", "--", source)
    if output is None:
        return None, error
    prefix = source.rstrip("/") + "/"
    paths = sorted(p[len(prefix):] for p in output.decode("utf-8").split("\0") if p.startswith(prefix))
    return paths, None


def checkout_identity(checkout):
    revision, _ = _git(checkout, "rev-parse", "HEAD")
    status, _ = _git(checkout, "status", "--porcelain", "--untracked-files=no")
    return {
        "path": checkout,
        "revision": revision.decode().strip() if revision else None,
        "dirty": bool(status.strip()) if status is not None else None,
    }


def asset_destination(relative, rules):
    """Where the Xcode target puts `Assets/<relative>`, relative to the bundle."""
    assets = rules["assets"]
    parts = relative.split("/")
    destination = relative if parts[0] in assets["explicitFolders"] else parts[-1]
    return assets["destination"] + "/" + destination


# ---------------------------------------------------------------- inspection


def sha256_file(path, data=None):
    if data is not None:
        return hashlib.sha256(data).hexdigest()
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def walk_bundle(app):
    """(relative file paths, relative symlinks) inside the bundle, sorted."""
    files, links = [], []
    for root, dirs, names in os.walk(app):
        for name in list(dirs):
            full = os.path.join(root, name)
            if os.path.islink(full):
                links.append(os.path.relpath(full, app).replace(os.sep, "/"))
                dirs.remove(name)
        for name in names:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, app).replace(os.sep, "/")
            (links if os.path.islink(full) else files).append(rel)
    return sorted(files), sorted(links)


def matches(pattern, path):
    """Glob match where `*` stays inside one path component and `**` spans any."""
    regex = ""
    index = 0
    while index < len(pattern):
        if pattern.startswith("**", index):
            regex += ".*"
            index += 2
        elif pattern[index] == "*":
            regex += "[^/]*"
            index += 1
        elif pattern[index] == "?":
            regex += "[^/]"
            index += 1
        else:
            regex += re.escape(pattern[index])
            index += 1
    return re.fullmatch(regex, path) is not None


class Inspection:
    def __init__(self, app, rules, checkout=None, tracked=None):
        self.app = os.path.abspath(app)
        self.rules = rules
        self.checkout = os.path.abspath(checkout) if checkout else None
        self.tracked = tracked
        self.findings = []
        self.entries = {}
        self.scan_patterns = [p.encode() for p in rules["pathScan"]["patterns"]]
        if self.checkout and rules["pathScan"].get("includeCheckoutRoot"):
            self.scan_patterns.append((self.checkout.rstrip("/") + "/").encode())

    def add(self, severity, rule, path, detail):
        self.findings.append({"severity": severity, "rule": rule, "path": path, "detail": detail})

    def read(self, rel):
        full = os.path.join(self.app, rel)
        if os.path.getsize(full) > MAX_SCAN_BYTES:
            return None
        with open(full, "rb") as handle:
            return handle.read()

    # A text scan: absolute build-machine paths and card/scene keywords.
    def scan_text(self, rel, blob, where):
        for pattern in self.scan_patterns:
            if pattern in blob:
                self.add("error", self.rules["pathScan"]["id"], rel,
                         "%s contains %r" % (where, pattern.decode("utf-8", "replace")))
        for rule in self.rules["forbidden"]:
            for marker in rule.get("markers", []):
                if marker.encode() in blob:
                    self.add("error", rule["id"], rel, "%s contains the keyword %r" % (where, marker))

    def classify(self, rel):
        for product in self.rules["buildProducts"]:
            if matches(product["pattern"], rel):
                return "build-product", None
        if self.tracked is None:
            return "unverified", None
        if rel in self.tracked_destinations:
            return "tracked-asset", self.tracked_destinations[rel]
        if rel in self.excluded_destinations:
            return "excluded-asset", self.excluded_destinations[rel]
        return "unexpected", None

    def prepare_tracked(self):
        self.tracked_destinations, self.excluded_destinations = {}, {}
        if self.tracked is None:
            return
        excluded = set(self.rules["assets"].get("excluded", []))
        for relative in self.tracked:
            destination = asset_destination(relative, self.rules)
            other = self.tracked_destinations.get(destination) or self.excluded_destinations.get(destination)
            if other is not None:
                # Xcode refuses to build two resources with one destination.
                self.add("error", "asset-collision", destination,
                         "Assets/%s and Assets/%s land on the same bundle path" % (other, relative))
            table = self.excluded_destinations if relative in excluded else self.tracked_destinations
            table[destination] = relative

    def inspect_file(self, rel):
        full = os.path.join(self.app, rel)
        data = self.read(rel)
        size = os.path.getsize(full)
        entry = {"path": rel, "bytes": size, "sha256": sha256_file(full, data)}
        self.entries[rel] = entry
        kind, source = self.classify(rel)
        entry["class"] = kind
        if kind == "tracked-asset":
            entry["source"] = self.rules["assets"]["source"] + "/" + source
            if self.checkout is not None:
                original = os.path.join(self.checkout, entry["source"])
                if not os.path.isfile(original):
                    self.add("warning", "asset-content", rel, "%s is tracked but absent from the checkout" % entry["source"])
                elif sha256_file(original) != entry["sha256"]:
                    self.add("warning", "asset-content", rel,
                             "differs from %s in the checkout (local edit or build-time processing)" % entry["source"])
        elif kind == "excluded-asset":
            self.add("error", "excluded-asset", rel,
                     "Assets/%s is a membership exception of the app target and must not ship" % source)
        elif kind == "unexpected":
            self.add(self.rules["unexpectedFiles"], "unexpected-file", rel,
                     "neither a declared build product nor a git-tracked %s file" % self.rules["assets"]["source"])

        lowered = rel.lower()
        components = rel.split("/")
        for rule in self.rules["forbidden"]:
            for pattern in rule.get("pathComponents", []):
                if any(fnmatch.fnmatchcase(c.lower(), pattern.lower()) for c in components):
                    self.add("error", rule["id"], rel, "path component matches %r" % pattern)
            for extension in rule.get("extensions", []):
                if lowered.endswith(extension.lower()):
                    self.add("error", rule["id"], rel, "extension %s" % extension)

        if data is None:
            self.add("warning", "not-scanned", rel, "larger than %d bytes; content not scanned" % MAX_SCAN_BYTES)
            return
        for rule in self.rules["forbidden"]:
            for magic in rule.get("magic", []):
                if data.startswith(magic.encode()):
                    self.add("error", rule["id"], rel, "starts with the %r signature" % magic)
            if rule.get("content") == "pe" and is_pe(data):
                self.add("error", rule["id"], rel, "has a PE (Windows/.NET) header")

        architectures = macho_architectures(data)
        if architectures is not None:
            entry["architectures"] = architectures
            missing = [a for a in self.rules["executable"]["requiredArchitectures"] if a not in architectures]
            if missing:
                self.add("error", "architecture", rel,
                         "Mach-O lacks %s (has %s)" % (", ".join(missing), ", ".join(architectures)))
        if architectures is not None or (kind == "build-product" and not lowered.endswith(".plist")):
            # Compiled code and products (metallib, Assets.car): count path strings, never fail on them.
            counts = {p.decode(): data.count(p) for p in self.scan_patterns if p in data}
            if counts:
                entry["pathReferences"] = counts
            return

        if lowered.endswith(".png"):
            texts, trailing, error = png_structure(data)
            if error:
                self.add("error", "resource-format", rel, "PNG %s" % error)
            for text in texts:
                self.scan_text(rel, text, "a PNG text chunk")
            if trailing:
                for rule in self.rules["forbidden"]:
                    if rule.get("pngTrailingData"):
                        found = [m for m in rule.get("markers", []) if m.encode() in trailing]
                        self.add("error", rule["id"], rel, "%d bytes after IEND%s" % (
                            len(trailing), " with keyword %s" % ", ".join(found) if found else ""))
        elif lowered.endswith(".glb"):
            blob, error = glb_json(data)
            if error:
                self.add("error", "resource-format", rel, "GLB %s" % error)
            self.scan_text(rel, blob, "the GLB JSON chunk")
        elif lowered.endswith(".plist"):
            try:
                strings = "\n".join(plist_strings(plistlib.loads(data))).encode()
            except Exception as error:  # plistlib raises several unrelated types
                self.add("error", "resource-format", rel, "unreadable property list: %s" % error)
                strings = data
            self.scan_text(rel, strings, "the property list")
        elif any(lowered.endswith(e) for e in self.rules["pathScan"]["textExtensions"]):
            self.scan_text(rel, data, "the text")

    def check_symlinks(self, links):
        root = os.path.realpath(self.app)
        for rel in links:
            target = os.path.realpath(os.path.join(self.app, rel))
            inside = target == root or target.startswith(root + os.sep)
            self.entries[rel] = {"path": rel, "class": "symlink", "target": os.readlink(os.path.join(self.app, rel))}
            if not inside:
                self.add("error", "symlink-escape", rel, "points outside the bundle")

    def check_required(self):
        results = []
        for item in self.rules["required"]:
            entry = self.entries.get(item["path"])
            present = entry is not None and entry.get("bytes", 0) > 0
            result = {"path": item["path"], "present": present}
            if entry is None:
                self.add("error", "required", item["path"], "missing: %s" % item.get("why", "required"))
            elif not present:
                self.add("error", "required", item["path"], "empty file")
            elif item.get("magic"):
                with open(os.path.join(self.app, item["path"]), "rb") as handle:
                    head = handle.read(len(item["magic"]))
                result["magic"] = head == item["magic"].encode()
                if not result["magic"]:
                    self.add("error", "required", item["path"], "does not start with %r" % item["magic"])
            if entry is not None:
                result["sha256"] = entry.get("sha256")
            results.append(result)
        return results

    def check_info_plist(self):
        rules = self.rules["infoPlist"]
        path = os.path.join(self.app, rules["path"])
        result = {"path": rules["path"]}
        if not os.path.isfile(path):
            self.add("error", "info-plist", rules["path"], "missing")
            return result
        try:
            with open(path, "rb") as handle:
                info = plistlib.load(handle)
        except Exception as error:
            self.add("error", "info-plist", rules["path"], "unreadable: %s" % error)
            return result
        for key, expected in rules.get("expect", {}).items():
            actual = info.get(key)
            result[key] = actual
            if actual != expected:
                self.add("error", "info-plist", rules["path"], "%s is %r, expected %r" % (key, actual, expected))
        for key in rules.get("record", []):
            result[key] = info.get(key)
        executable = "Contents/MacOS/%s" % info.get("CFBundleExecutable")
        if executable != self.rules["executable"]["path"]:
            self.add("error", "info-plist", rules["path"],
                     "CFBundleExecutable names %s, the rules expect %s" % (executable, self.rules["executable"]["path"]))
        return result

    def check_executable(self):
        rel = self.rules["executable"]["path"]
        entry = self.entries.get(rel)
        if entry is None:
            self.add("error", "architecture", rel, "executable missing")
            return {"path": rel, "present": False}
        if "architectures" not in entry:
            self.add("error", "architecture", rel, "not a Mach-O file")
        return {"path": rel, "present": True, "architectures": entry.get("architectures"),
                "sha256": entry.get("sha256"), "pathReferences": entry.get("pathReferences", {})}

    def check_catalog(self):
        rules = self.rules["catalog"]
        result = {"path": rules["path"], "references": 0, "missing": []}
        full = os.path.join(self.app, rules["path"])
        if not os.path.isfile(full):
            return result    # reported by `required`
        try:
            with open(full, encoding="utf-8") as handle:
                catalog = json.load(handle)
        except (OSError, ValueError) as error:
            self.add("error", "catalog", rules["path"], "unreadable catalog: %s" % error)
            return result
        result["version"] = catalog.get("version") if isinstance(catalog, dict) else None
        extensions = tuple(e.lower() for e in rules["referenceExtensions"])
        ignored = set(rules.get("ignoredKeys", {}))
        references = set()

        def walk(value, key):
            if key in ignored:
                return
            if isinstance(value, dict):
                for child_key, child in value.items():
                    walk(child, child_key)
            elif isinstance(value, list):
                for child in value:
                    walk(child, key)
            elif isinstance(value, str) and value.lower().endswith(extensions):
                references.add(value if "/" in value else rules["bareNameDirectory"] + "/" + value)

        walk(catalog, None)
        result["references"] = len(references)
        for reference in sorted(references):
            parts = reference.split("/")
            if reference.startswith("/") or ".." in parts:
                self.add("error", "catalog", rules["path"], "reference escapes the assets root: %s" % reference)
                continue
            target = rules["root"] + "/" + reference
            if target not in self.entries:
                result["missing"].append(reference)
                self.add("error", "catalog", target, "referenced by catalog.json but not in the bundle")
        return result

    def run(self):
        if self.tracked is None:
            self.add("error", "provenance", self.rules["assets"]["source"],
                     "tracked asset list unavailable; files cannot be traced to the checkout")
        self.prepare_tracked()
        files, links = walk_bundle(self.app)
        for rel in files:
            self.inspect_file(rel)
        self.check_symlinks(links)
        required = self.check_required()
        info = self.check_info_plist()
        executable = self.check_executable()
        catalog = self.check_catalog()
        missing_assets = sorted(d for d in self.tracked_destinations if d not in self.entries)
        for destination in missing_assets:
            self.add("error", "asset-missing", destination,
                     "Assets/%s is tracked but not in the bundle" % self.tracked_destinations[destination])
        classes = {}
        total = 0
        for entry in self.entries.values():
            classes[entry["class"]] = classes.get(entry["class"], 0) + 1
            total += entry.get("bytes", 0)
        tree = hashlib.sha256()
        for rel in sorted(self.entries):
            tree.update(("%s\0%s\n" % (rel, self.entries[rel].get("sha256") or self.entries[rel].get("target"))).encode())
        self.findings.sort(key=lambda f: (SEVERITIES.index(f["severity"]), f["rule"], f["path"], f["detail"]))
        errors = sum(1 for f in self.findings if f["severity"] == "error")
        return {
            "bundle": {"path": self.app, "files": len(files), "symlinks": len(links), "bytes": total,
                       "treeSha256": tree.hexdigest()},
            "infoPlist": info,
            "executable": executable,
            "required": required,
            "catalog": catalog,
            "files": [self.entries[rel] for rel in sorted(self.entries)],
            "findings": self.findings,
            "summary": {"errors": errors,
                        "warnings": sum(1 for f in self.findings if f["severity"] == "warning"),
                        "byClass": dict(sorted(classes.items()))},
            "passed": errors == 0,
        }


def inspect(app, rules, checkout=None, tracked=None):
    """Inspects `app` with validated `rules`. `tracked` lists git-tracked paths
    under the assets source (relative to it); None means unavailable."""
    return Inspection(app, rules, checkout, tracked).run()


def write_report(path, report):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".bundle-report-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, sort_keys=False)
            stream.write("\n")
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description="Inspect a built Ikkoku.app for release packaging (T-T02).")
    parser.add_argument("app", help="path to the built .app bundle")
    parser.add_argument("--rules", default=DEFAULT_RULES, help="rules file (default: %(default)s)")
    parser.add_argument("--checkout", default=REPO_ROOT,
                        help="checkout the app was built from, for git-tracked asset provenance (default: this repository)")
    parser.add_argument("--report", help="write the JSON report here (outside the bundle)")
    args = parser.parse_args(argv)

    app = os.path.abspath(args.app)
    if not os.path.isdir(os.path.join(app, "Contents")):
        print("error: %s is not an app bundle (no Contents/)" % args.app, file=sys.stderr)
        return 2
    if args.report:
        report_path = os.path.abspath(args.report)
        if report_path == app or report_path.startswith(app + os.sep):
            print("error: --report must be outside the inspected bundle", file=sys.stderr)
            return 2
    try:
        rules = load_rules(args.rules)
    except RulesError as error:
        print("error: %s" % error, file=sys.stderr)
        return 2

    checkout = os.path.abspath(args.checkout)
    tracked, error = git_tracked(checkout, rules["assets"]["source"])
    if tracked is None:
        print("warning: cannot list tracked %s files in %s: %s" % (rules["assets"]["source"], checkout, error),
              file=sys.stderr)
    body = inspect(app, rules, checkout, tracked)
    with open(os.path.abspath(__file__), "rb") as handle:
        tool_hash = hashlib.sha256(handle.read()).hexdigest()
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"path": os.path.relpath(os.path.abspath(__file__), REPO_ROOT), "sha256": tool_hash},
        "rules": {"path": os.path.abspath(args.rules), "sha256": sha256_file(args.rules)},
        "checkout": dict(checkout_identity(checkout), trackedAssets=len(tracked) if tracked is not None else None),
    }
    report.update(body)
    if args.report:
        write_report(args.report, report)
        print("report: %s" % os.path.abspath(args.report))
    summary = report["summary"]
    print("bundle: %s (%d files, %d bytes)" % (app, report["bundle"]["files"], report["bundle"]["bytes"]))
    print("architectures: %s" % ", ".join(report["executable"].get("architectures") or ["?"]))
    print("classes: %s" % ", ".join("%s=%d" % kv for kv in summary["byClass"].items()))
    for finding in report["findings"]:
        print("%s [%s] %s: %s" % (finding["severity"], finding["rule"], finding["path"], finding["detail"]))
    print("errors=%d warnings=%d %s" % (summary["errors"], summary["warnings"],
                                        "PASSED" if report["passed"] else "FAILED"))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
