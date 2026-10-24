#!/usr/bin/env python3
"""Immutable numbered generations of translated-IR and native-adapter plugin packages.

`scan` hashes and copies packages published by plugin.py beneath explicit local
roots into content-addressed revisions, then publishes a new numbered generation
only when the indexed content changed. Published revisions and generation files
are never rewritten; `library.json` is the single commit point. DLL bytes are
identity evidence and are never loaded or executed. The format and selection
policy are documented in docs/reference/mods/plugin-execution.md (Plugin library).
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

import native_adapters

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = 1
SCANNER = {"id": "ikkoku.plugin-library", "version": "1.0.0"}
LIBRARY_KIND = "ikkoku-plugin-library"
GENERATION_KIND = "ikkoku-plugin-generation"
TRANSLATED = "ikkoku-translated-plugin"
NATIVE = "ikkoku-native-plugin-adapter"
SHA = re.compile(r"[0-9a-f]{64}\Z")
# Manifest/program limits match SourcePluginPackage, SourceIRProgram and
# SourceNativePluginPackage, so an indexed revision is never larger than the
# native loader accepts.
INDEX_BYTES = 32 * 1024 * 1024
MANIFEST_BYTES = 1024 * 1024
PROGRAM_BYTES = 4 * 1024 * 1024
CONFIGURATION_BYTES = 1024 * 1024
FILE_BYTES = 32 * 1024 * 1024
PACKAGE_BYTES = 96 * 1024 * 1024
PACKAGE_FILES = 256
PACKAGE_DEPTH = 8
IDENTITY_BYTES = 1024
TRANSLATED_KEYS = {"schemaVersion", "kind", "identity", "processes", "dependencies", "incompatibilities", "components"}
NATIVE_KEYS = {"schemaVersion", "kind", "adapterID", "type", "identity", "processes", "source", "configuration", "incompatibilities"}


class LibraryFailure(ValueError):
    pass


class PackageFailure(ValueError):
    """One discovered package cannot be indexed; other packages continue."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def encoded(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def utf8(text: str) -> bool:
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def ordinal(text: str) -> bytes:
    """Sort key of the UTF-8 bytes; identity is never case-folded or normalized."""
    return text.encode("utf-8", "surrogateescape")


def diagnostic(code: str, message: str, severity: str = "error") -> dict:
    return {"code": code, "severity": severity, "message": message.encode("utf-8", "backslashreplace").decode("utf-8")}


def bounded(value) -> bool:
    return isinstance(value, str) and bool(value) and utf8(value) and len(value.encode("utf-8")) <= IDENTITY_BYTES


def exact_int(value, expected: int) -> bool:
    return type(value) is int and value == expected


def dotnet_version(text) -> tuple[int, ...] | None:
    """Strict System.Version subset: 2-4 dot-separated ASCII decimal Int32 parts.

    Whitespace, signs, prefixes and suffixes are rejected even where a .NET
    parser may accept them, so an unclear version fails instead of comparing.
    """
    if not isinstance(text, str):
        return None
    parts = text.split(".")
    if not 2 <= len(parts) <= 4 or any(not part or not part.isascii() or not part.isdigit() for part in parts):
        return None
    values = tuple(int(part) for part in parts)
    return values if all(value <= 2**31 - 1 for value in values) else None


def version_at_least(actual: str, minimum: str) -> bool:
    """.NET Version ordering: an absent build/revision compares as -1, so 1.0 < 1.0.0."""
    a, b = dotnet_version(actual), dotnet_version(minimum)
    if a is None or b is None:
        return False
    pad = lambda value: value + (-1,) * (4 - len(value))
    return pad(a) >= pad(b)


def canonical_relative(relative) -> bool:
    if not isinstance(relative, str) or not relative or relative.startswith("/") or "\\" in relative or not utf8(relative):
        return False
    return all(part not in ("", ".", "..") and not any(ord(c) < 32 or ord(c) == 127 for c in part) for part in relative.split("/"))


def contained(root: Path, relative: str) -> Path:
    """Library paths are canonical relatives and never traverse symlinks."""
    if not canonical_relative(relative):
        raise LibraryFailure("Library path must be a canonical relative path")
    result = root
    for part in relative.split("/"):
        result = result / part
        if result.is_symlink():
            raise LibraryFailure("Library path traverses a symlink")
    if not result.resolve().is_relative_to(root):
        raise LibraryFailure("Library path escapes its root")
    return result


def read_file(path: Path, maximum: int) -> bytes:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        raise LibraryFailure(f"Not a bounded regular file: {path.name}")
    with path.open("rb") as stream:
        value = stream.read(maximum + 1)
    if len(value) > maximum:
        raise LibraryFailure(f"File grew beyond its limit: {path.name}")
    return value


def strict_json(data: bytes, code: str):
    """UTF-8 JSON without duplicate keys or non-finite numbers (which Swift rejects or reads differently)."""
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise PackageFailure(code, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    def constant(name):
        raise PackageFailure(code, f"Non-finite JSON number: {name}")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PackageFailure(code, f"Malformed JSON: {error}") from error


def atomic_json(root: Path, relative: str, value: dict) -> None:
    destination = contained(root, relative)
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = encoded(value)
    if len(data) > INDEX_BYTES:
        raise LibraryFailure("Generated plugin library index exceeds its size limit")
    fd, temporary = tempfile.mkstemp(prefix=".index-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


def publish_exclusive(target: Path, data: bytes) -> None:
    """Write beside the target, then hard-link it into place: the name appears
    complete or not at all, and an existing file is never replaced."""
    if len(data) > INDEX_BYTES:
        raise LibraryFailure("Generated plugin generation index exceeds its size limit")
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".generation-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.link(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


@contextmanager
def locked(root: Path):
    path = contained(root, ".scan.lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise LibraryFailure("Another scan is updating this plugin library") from error
        yield
    finally:
        os.close(fd)


def generation_path(number: int) -> str:
    return f"generations/{number:06d}.json"


def copy_file(source: Path, target: Path | None, maximum: int) -> tuple[str, int]:
    descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    hasher, size = hashlib.sha256(), 0
    with os.fdopen(descriptor, "rb") as stream:
        attributes = os.fstat(stream.fileno())
        if not stat.S_ISREG(attributes.st_mode) or attributes.st_size > maximum:
            raise PackageFailure("package_limit", f"Not a regular file within {maximum} bytes: {source.name}")
        output = target.open("xb") if target is not None else None
        try:
            while block := stream.read(min(1024 * 1024, maximum + 1 - size)):
                size += len(block)
                if size > maximum:
                    raise PackageFailure("package_limit", f"File grew beyond {maximum} bytes: {source.name}")
                hasher.update(block)
                if output is not None:
                    output.write(block)
        finally:
            if output is not None:
                output.close()
    return hasher.hexdigest(), size


def package_files(directory: Path, target: Path | None = None) -> list[dict]:
    """Hash every regular package file, copying it to `target` when given.
    Symlinks, special files and non-canonical names reject the whole package."""
    files, total = [], 0
    def visit(folder: Path, prefix: str, depth: int) -> None:
        nonlocal total
        if depth > PACKAGE_DEPTH:
            raise PackageFailure("package_limit", "Package directory nesting exceeds its limit")
        with os.scandir(folder) as iterator:
            entries = sorted(iterator, key=lambda entry: ordinal(entry.name))
        for entry in entries:
            relative = prefix + entry.name
            if not canonical_relative(relative):
                raise PackageFailure("package_path", f"Package file name is not canonical UTF-8: {relative!r}")
            if entry.is_symlink():
                raise PackageFailure("package_symlink", f"Package contains a symlink: {relative}")
            if entry.is_dir(follow_symlinks=False):
                if target is not None:
                    (target / relative).mkdir()
                visit(Path(entry.path), relative + "/", depth + 1)
            elif entry.is_file(follow_symlinks=False):
                if len(files) >= PACKAGE_FILES:
                    raise PackageFailure("package_limit", f"Package has more than {PACKAGE_FILES} files")
                sha, size = copy_file(Path(entry.path), None if target is None else target / relative, FILE_BYTES)
                total += size
                if total > PACKAGE_BYTES:
                    raise PackageFailure("package_limit", f"Package exceeds {PACKAGE_BYTES} bytes")
                files.append({"path": relative, "sha256": sha, "bytes": size})
            else:
                raise PackageFailure("package_special_file", f"Package contains a special file: {relative}")
    if target is not None:
        target.mkdir()
    visit(directory, "", 0)
    return sorted(files, key=lambda item: ordinal(item["path"]))


def package_digest(files: list[dict]) -> str:
    """SHA-256 of the compact sorted-key JSON array of {bytes, path, sha256},
    ordered by the UTF-8 bytes of path. It covers evidence files as well."""
    return digest(json.dumps(files, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def string_list(value, limit: int, code: str, what: str) -> list[str]:
    if not isinstance(value, list) or len(value) > limit or not all(bounded(item) for item in value):
        raise PackageFailure(code, f"Invalid {what}")
    return value


def file_reference(value, hashes: dict, code: str, what: str) -> str:
    if not isinstance(value, dict) or set(value) != {"file", "sha256"} or not canonical_relative(value["file"]) \
            or not isinstance(value["sha256"], str) or not SHA.fullmatch(value["sha256"]):
        raise PackageFailure("manifest_invalid", f"Invalid {what} reference")
    if hashes.get(value["file"]) != value["sha256"]:
        raise PackageFailure(code, f"{what.capitalize()} {value['file']} is missing or differs from its manifest hash")
    return value["file"]


def inspect_package(package: Path, files: list[dict], registry: dict) -> dict:
    """Validate a staged package copy and return its revision record (without sources)."""
    hashes = {item["path"]: item["sha256"] for item in files}
    sizes = {item["path"]: item["bytes"] for item in files}
    if "manifest.json" not in hashes:
        raise PackageFailure("manifest_missing", "Package has no manifest.json")
    if sizes["manifest.json"] > MANIFEST_BYTES:
        raise PackageFailure("package_limit", "Manifest exceeds 1 MiB")
    manifest_bytes = read_file(package / "manifest.json", MANIFEST_BYTES)
    manifest_sha = digest(manifest_bytes)
    if manifest_sha != hashes["manifest.json"]:
        raise PackageFailure("package_changed", "Manifest changed while it was staged")
    manifest = strict_json(manifest_bytes, "manifest_invalid")
    if not isinstance(manifest, dict) or not exact_int(manifest.get("schemaVersion"), 1) or manifest.get("kind") not in (TRANSLATED, NATIVE):
        raise PackageFailure("manifest_unsupported", "Unsupported plugin manifest schema or kind")
    kind = manifest["kind"]
    allowed = TRANSLATED_KEYS if kind == TRANSLATED else NATIVE_KEYS
    if not set(manifest) <= allowed:
        raise PackageFailure("manifest_unsupported", f"Unknown manifest fields: {sorted(set(manifest) - allowed)}")
    identity = manifest.get("identity")
    if not isinstance(identity, dict) or set(identity) != {"guid", "version", "name"} or not all(bounded(identity[key]) for key in identity):
        raise PackageFailure("identity_invalid", "Plugin identity requires bounded guid, version and name")
    guid, version, name = identity["guid"], identity["version"], identity["name"]
    if dotnet_version(version) is None:
        raise PackageFailure("version_invalid", f"{guid} version {version!r} is not a 2-4 component numeric .NET version")
    processes = string_list(manifest.get("processes"), 32, "manifest_invalid", "process filters")
    if kind == TRANSLATED:
        dependencies = []
        raw = manifest.get("dependencies")
        if not isinstance(raw, list) or len(raw) > 128:
            raise PackageFailure("manifest_invalid", "Invalid dependencies")
        for dependency in raw:
            if not isinstance(dependency, dict) or not set(dependency) <= {"guid", "minimumVersion", "required"} \
                    or not bounded(dependency.get("guid")) or type(dependency.get("required")) is not bool:
                raise PackageFailure("manifest_invalid", "Invalid dependency")
            minimum = dependency.get("minimumVersion")
            if minimum is not None and dotnet_version(minimum) is None:
                raise PackageFailure("version_invalid", f"{guid} dependency {dependency['guid']} minimum {minimum!r} is not a numeric .NET version")
            if any(item["guid"] == dependency["guid"] for item in dependencies):
                raise PackageFailure("manifest_invalid", f"Duplicate dependency {dependency['guid']}")
            dependencies.append({"guid": dependency["guid"], "minimumVersion": minimum, "required": dependency["required"]})
        incompatibilities = string_list(manifest.get("incompatibilities"), 128, "manifest_invalid", "incompatibilities")
        components = manifest.get("components")
        if not isinstance(components, list) or not 1 <= len(components) <= 128:
            raise PackageFailure("manifest_invalid", "Invalid components")
        types, converter = [], None
        for component in components:
            if not isinstance(component, dict) or set(component) != {"type", "program"} or not bounded(component["type"]) \
                    or component["type"] in types:
                raise PackageFailure("manifest_invalid", "Invalid or duplicate component")
            file = file_reference(component["program"], hashes, "program_changed", "program")
            if sizes[file] > PROGRAM_BYTES:
                raise PackageFailure("package_limit", "Translated program exceeds 4 MiB")
            program = strict_json(read_file(package / file, PROGRAM_BYTES), "program_invalid")
            program_identity = program.get("identity") if isinstance(program, dict) else None
            if not isinstance(program_identity, dict) or not exact_int(program.get("schemaVersion"), 1) \
                    or program.get("status") != "ready" or program.get("mode") != "component" \
                    or program.get("type") != component["type"] or program_identity.get("pluginGUID") != guid:
                raise PackageFailure("program_invalid", f"Program {file} is not a ready component of {guid}")
            hashes_of = {key: program.get(key) for key in ("emitterSHA256", "bridgeSHA256", "semanticSurfaceSHA256")}
            if not all(isinstance(value, str) and SHA.fullmatch(value) for value in hashes_of.values()):
                raise PackageFailure("program_invalid", f"Program {file} lacks converter identity hashes")
            identified = {"id": "ikkoku.translation", "irSchemaVersion": "1", **hashes_of}
            if converter is not None and converter != identified:
                raise PackageFailure("converter_mixed", "Components were produced by different converter revisions")
            converter = identified
            types.append(component["type"])
    else:
        source = manifest.get("source")
        source_sha = source.get("sha256") if isinstance(source, dict) else None
        row = registry.get(source_sha) if isinstance(source_sha, str) else None
        if row is None or any(manifest.get(key) != row[key] for key in ("adapterID", "type", "identity", "processes")):
            raise PackageFailure("adapter_unverified", "Native adapter manifest differs from every verified original assembly")
        incompatibilities = string_list(manifest.get("incompatibilities", []), 128, "manifest_invalid", "incompatibilities")
        if incompatibilities != row.get("incompatibilities", []):
            raise PackageFailure("adapter_unverified", "Native adapter incompatibilities differ from the verified original")
        file_reference(source, hashes, "source_changed", "original assembly")
        configuration = manifest.get("configuration")
        if configuration is not None:
            if manifest["adapterID"] not in native_adapters.CONFIGURABLE:
                raise PackageFailure("configuration_unsupported", "This adapter has no original configuration file")
            file = file_reference(configuration, hashes, "configuration_changed", "configuration")
            if sizes[file] > CONFIGURATION_BYTES:
                raise PackageFailure("package_limit", "Configuration exceeds 1 MiB")
        dependencies, types = [], [manifest["type"]]
        converter = {"id": "ikkoku.native-adapter", "adapterID": manifest["adapterID"], "sourceSHA256": source_sha}
    return {"kind": kind, "guid": guid, "version": version, "name": name,
            "manifest": f"revisions/{manifest_sha}/manifest.json", "manifestSHA256": manifest_sha,
            "packageSHA256": package_digest(files), "processes": processes, "dependencies": dependencies,
            "incompatibilities": incompatibilities, "types": types, "converter": converter}


def rejected_conversion(directory: Path) -> dict:
    """plugin.py rejection evidence: a conversion report without a loadable manifest."""
    report = strict_json(read_file(directory / "conversion.json", MANIFEST_BYTES), "conversion_invalid")
    if not isinstance(report, dict) or report.get("status") != "rejected":
        raise PackageFailure("manifest_missing", "Conversion report is not a rejection, but no manifest.json exists")
    result = {"status": "rejected", "diagnostics": []}
    if bounded(report.get("type")):
        result["type"] = report["type"]
    identity = report.get("identity")
    if isinstance(identity, dict):
        result["identity"] = {key: identity[key] for key in ("guid", "version", "name") if bounded(identity.get(key))}
    rows = report.get("diagnostics") if isinstance(report.get("diagnostics"), list) else []
    for row in rows[:256]:
        if isinstance(row, dict):
            location = f" (line {row.get('line')}, column {row.get('column')})" if "line" in row else ""
            result["diagnostics"].append(diagnostic("source_" + str(row.get("code", "unknown")), str(row.get("message", "")) + location))
    return result


def discover(roots: list[dict], library: Path) -> tuple[list[tuple[dict, str, Path, str]], list[dict]]:
    found, diagnostics = [], []
    for root in roots:
        directory = Path(root["path"])
        if not directory.is_dir():
            diagnostics.append(diagnostic("root_unavailable", f"Scan root is unavailable: {directory}"))
            continue
        def on_error(error):
            diagnostics.append(diagnostic("discovery_error", str(error)))
        for parent, directories, files in os.walk(directory, followlinks=False, onerror=on_error):
            base = Path(parent)
            relative = base.relative_to(directory).as_posix()
            if "manifest.json" in files or "conversion.json" in files:
                directories[:] = []  # Package contents (program/) are not separate packages.
                if not utf8(relative):
                    diagnostics.append(diagnostic("path_unsupported", f"Package path is not UTF-8: {relative!r}"))
                else:
                    found.append((root, relative, base, "package" if "manifest.json" in files else "rejected"))
                continue
            kept = []
            for name in sorted(directories, key=ordinal):
                child = base / name
                if child.is_symlink():
                    diagnostics.append(diagnostic("symlink_skipped", f"Directory symlink skipped: {child}", "warning"))
                elif name.startswith(".plugin-stage-"):
                    diagnostics.append(diagnostic("staging_skipped", f"Incomplete plugin.py staging directory skipped: {child}", "warning"))
                elif child.resolve() != library:
                    kept.append(name)
            directories[:] = kept
    return sorted(found, key=lambda item: (ordinal(item[1]), item[0]["id"])), diagnostics


def load_pointer(library: Path) -> tuple[dict, list[tuple[dict, dict]]]:
    """Verify `library.json` and every published generation before trusting either."""
    path = contained(library, "library.json")
    if not path.exists() and not path.is_symlink():
        return {}, []
    try:
        pointer = strict_json(read_file(path, INDEX_BYTES), "library_invalid")
    except PackageFailure as error:
        raise LibraryFailure(str(error)) from error
    records = pointer.get("generations") if isinstance(pointer, dict) else None
    if not isinstance(pointer, dict) or not exact_int(pointer.get("schemaVersion"), SCHEMA) or pointer.get("kind") != LIBRARY_KIND \
            or not isinstance(records, list) or not records:
        raise LibraryFailure("Unsupported plugin library index")
    published, previous = [], 0
    for record in records:
        number = record.get("number") if isinstance(record, dict) else None
        if type(number) is not int or number <= previous or record.get("index") != generation_path(number) \
                or not isinstance(record.get("indexSHA256"), str) or not SHA.fullmatch(record["indexSHA256"]):
            raise LibraryFailure("Plugin library generation records are not strictly numbered")
        previous = number
        data = read_file(contained(library, record["index"]), INDEX_BYTES)
        if digest(data) != record["indexSHA256"]:
            raise LibraryFailure(f"Published generation {number} changed; refusing to extend a damaged library")
        try:
            document = strict_json(data, "generation_invalid")
        except PackageFailure as error:
            raise LibraryFailure(str(error)) from error
        revisions = document.get("revisions") if isinstance(document, dict) else None
        if not isinstance(document, dict) or document.get("kind") != GENERATION_KIND or not exact_int(document.get("schemaVersion"), SCHEMA) \
                or document.get("number") != number or not isinstance(revisions, list) \
                or not all(isinstance(r, dict) and all(isinstance(r.get(key), str) and SHA.fullmatch(r[key])
                                                       for key in ("manifestSHA256", "packageSHA256")) for r in revisions):
            raise LibraryFailure(f"Unsupported plugin generation {number}")
        published.append((record, document))
    if pointer.get("current") != previous:
        raise LibraryFailure("Plugin library current generation is not its newest published generation")
    return pointer, published


def load(library: Path, generation: int | None = None) -> dict:
    """Read one published generation (default: current) after verifying its hash."""
    library = library.resolve()
    pointer, published = load_pointer(library)
    if not published:
        raise LibraryFailure("Plugin library has no published generation")
    number = pointer["current"] if generation is None else generation
    for record, document in published:
        if record["number"] == number:
            return document
    raise LibraryFailure(f"Plugin library generation {number} is not published")


def content(document: dict) -> dict:
    return {key: value for key, value in document.items() if key not in ("number", "previous")}


def check_private_location(library: Path) -> None:
    if library.is_relative_to(ROOT) and not library.is_relative_to(ROOT / ".local"):
        raise LibraryFailure("Plugin libraries hold recovered and original package bytes; keep them under ignored .local/")


def scan(library: Path, roots: list[Path] | None = None, *, registry: dict | None = None) -> dict:
    registry = native_adapters.REGISTRY if registry is None else registry
    library = library.absolute()
    if library.is_symlink():
        raise LibraryFailure("Library directory cannot be a symlink")
    check_private_location(library.resolve())  # Before creating anything.
    library.mkdir(parents=True, exist_ok=True)
    library = library.resolve()
    with locked(library):
        pointer, published = load_pointer(library)
        directories = roots if roots is not None else [Path(item["path"]) for item in pointer.get("roots", [])]
        if not directories:
            raise LibraryFailure("Supply at least one explicit local scan root")
        directories = sorted(set(path.resolve() for path in directories), key=lambda path: ordinal(str(path)))
        if any(path == library or path.is_relative_to(library) for path in directories):
            raise LibraryFailure("A scan root cannot be the library or a directory inside it")
        if not all(utf8(str(path)) for path in directories):
            raise LibraryFailure("Scan root paths must be UTF-8")
        root_records = [{"id": digest(str(path).encode("utf-8")), "path": str(path)} for path in directories]
        known = {}
        for _, document in published:
            for revision in document.get("revisions", []):
                if known.setdefault(revision["manifestSHA256"], revision["packageSHA256"]) != revision["packageSHA256"]:
                    raise LibraryFailure("Published generations disagree about a revision's package files")
        found, diagnostics = discover(root_records, library)
        scan_diagnostics, revisions, packages, verified = [], {}, [], {}
        imported = reused = 0
        staging = contained(library, ".staging"); staging.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="scan-", dir=staging) as temporary:
            for sequence, (root, relative, source, state) in enumerate(found):
                item = {"rootID": root["id"], "relativePath": relative, "status": "invalid", "diagnostics": []}
                try:
                    if state == "rejected":
                        item.update(rejected_conversion(source))
                    else:
                        work = Path(temporary) / str(sequence); work.mkdir()
                        staged = work / "package"
                        files = package_files(source, staged)
                        revision = inspect_package(staged, files, registry)
                        sha, package_sha = revision["manifestSHA256"], revision["packageSHA256"]
                        item.update(manifestSHA256=sha, packageSHA256=package_sha)
                        destination = contained(library, f"revisions/{sha}")
                        recorded = known[sha] if sha in known else verified.get(sha)
                        if recorded is not None and recorded != package_sha:
                            raise PackageFailure("manifest_reused", "An indexed revision has this manifest with different package files; "
                                                 "publish changed evidence under a new manifest")
                        if sha in verified:
                            reused += 1
                        elif destination.exists() or destination.is_symlink():
                            if destination.is_symlink() or package_digest(package_files(destination)) != package_sha:
                                code = "revision_changed" if sha in known else "revision_unindexed"
                                raise PackageFailure(code, "Existing revision bytes differ; refusing to trust or replace them")
                            if sha not in known:
                                # A complete rename from an interrupted scan: identical bytes only.
                                scan_diagnostics.append(diagnostic("revision_adopted", f"Adopted identical unindexed revision {sha}", "warning"))
                            reused += 1
                        elif sha in known:
                            raise PackageFailure("revision_missing", "An indexed revision directory is missing; it is not recreated silently")
                        else:
                            destination.parent.mkdir(parents=True, exist_ok=True)
                            os.rename(staged, destination)
                            imported += 1
                        verified[sha] = package_sha
                        entry = revisions.setdefault(sha, {**revision, "sources": []})
                        entry["sources"].append({"rootID": root["id"], "relativePath": relative})
                        item.update(status="ready", kind=revision["kind"], guid=revision["guid"], version=revision["version"])
                except PackageFailure as failure:
                    item["diagnostics"] = [diagnostic(failure.code, str(failure))]
                except Exception as error:
                    item["diagnostics"] = [diagnostic("package_unavailable", f"{type(error).__name__}: {error}")]
                packages.append(item)
        ready = sorted(revisions.values(), key=lambda r: (ordinal(r["guid"]), ordinal(r["version"]), r["manifestSHA256"]))
        by_guid = {}
        for revision in ready:
            revision["sources"].sort(key=lambda s: (ordinal(s["relativePath"]), s["rootID"]))
            by_guid.setdefault(revision["guid"], []).append(revision)
        conflicts = [{"guid": guid, "manifestSHA256s": sorted(r["manifestSHA256"] for r in group)}
                     for guid, group in sorted(by_guid.items(), key=lambda item: ordinal(item[0])) if len(group) > 1]
        # Generation-wide reports are warnings; resolving a selection still fails explicitly.
        for revision in ready:
            label = f"{revision['guid']} {revision['version']} ({revision['manifestSHA256']})"
            for dependency in revision["dependencies"]:
                providers = by_guid.get(dependency["guid"], [])
                if not providers and dependency["required"]:
                    diagnostics.append(diagnostic("dependency_missing", f"{label} requires {dependency['guid']}, which no revision provides", "warning"))
                elif providers and dependency["required"] and dependency["minimumVersion"] is not None \
                        and not any(version_at_least(p["version"], dependency["minimumVersion"]) for p in providers):
                    diagnostics.append(diagnostic("dependency_version", f"{label} requires {dependency['guid']} {dependency['minimumVersion']}; "
                                                  f"available: {', '.join(sorted(p['version'] for p in providers))}", "warning"))
            for other in revision["incompatibilities"]:
                if other in by_guid:
                    diagnostics.append(diagnostic("incompatibility_present", f"{label} is incompatible with present {other}", "warning"))
        body = {"schemaVersion": SCHEMA, "kind": GENERATION_KIND, "scanner": SCANNER, "roots": root_records,
                "revisions": ready, "conflicts": conflicts,
                "packages": sorted(packages, key=lambda p: (ordinal(p["relativePath"]), p["rootID"])),
                "diagnostics": sorted(diagnostics, key=lambda d: (d["code"], d["message"]))}
        records = [record for record, _ in published]
        current = records[-1]["number"] if records else 0
        if published and content(published[-1][1]) == body:
            number, document, changed = current, published[-1][1], False
        else:
            number, changed = current + 1, True
            previous = {"number": current, "indexSHA256": records[-1]["indexSHA256"]} if records else None
            while True:
                document = {**body, "number": number, "previous": previous}
                data, relative = encoded(document), generation_path(number)
                target = contained(library, relative)
                if target.exists() or target.is_symlink():
                    # Left by an interrupted publication: never replaced.
                    if not target.is_symlink() and read_file(target, INDEX_BYTES) == data:
                        scan_diagnostics.append(diagnostic("generation_adopted", f"Adopted identical unpublished {relative}", "warning"))
                        break
                    scan_diagnostics.append(diagnostic("generation_orphaned", f"Unpublished {relative} differs; numbering skips it", "warning"))
                    number += 1
                    continue
                publish_exclusive(target, data)
                break
            records = records + [{"number": number, "index": relative, "indexSHA256": digest(data)}]
            # The only commit point: until this replace, readers see the prior generation.
            atomic_json(library, "library.json", {"schemaVersion": SCHEMA, "kind": LIBRARY_KIND, "scanner": SCANNER,
                                                  "roots": root_records, "current": number, "generations": records})
        statuses = [item["status"] for item in packages]
        return {"generation": document, "diagnostics": scan_diagnostics,
                "summary": {"generation": number, "published": changed, "imported": imported, "reused": reused,
                            "ready": statuses.count("ready"), "rejected": statuses.count("rejected"),
                            "invalid": statuses.count("invalid"), "revisions": len(ready), "conflicts": len(conflicts)}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["scan", "show"])
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--root", action="append", type=Path, help="Explicit local package directory; repeat for several. Later scans reuse saved roots.")
    parser.add_argument("--generation", type=int, help="show: published generation number (default: current)")
    args = parser.parse_args()
    try:
        if args.command == "scan":
            result = scan(args.library, args.root)
            print(json.dumps({"library": str(args.library.resolve() / "library.json"), **result["summary"],
                              "diagnostics": result["diagnostics"]}, ensure_ascii=False, sort_keys=True))
        else:
            document = load(args.library, args.generation)
            print(json.dumps({"generation": document["number"],
                              "revisions": [{key: r[key] for key in ("kind", "guid", "version", "manifestSHA256")} for r in document["revisions"]],
                              "conflicts": document["conflicts"],
                              "packages": [{key: p[key] for key in ("relativePath", "status") } for p in document["packages"]]},
                             ensure_ascii=False, sort_keys=True))
    except (LibraryFailure, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Plugin library {args.command} failed: {error}\n")


if __name__ == "__main__":
    main()
