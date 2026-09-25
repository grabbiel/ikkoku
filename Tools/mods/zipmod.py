#!/usr/bin/env python3
"""Bounded, deterministic Sideloader archive preservation and Texture2D import.

No original plugins are executed. Python is offline conversion tooling; this does
not implement Unity/BepInEx behavior or source archive conflict precedence.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import asdict, dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
import zipfile


CONVERTER = {"id": "ikkoku.zipmod", "version": "1.1.0"}


class ImportFailure(ValueError):
    """Invalid or out-of-bounds input; no package will be published."""


@dataclass(frozen=True)
class Limits:
    archive_bytes: int = 256 * 1024 * 1024
    file_bytes: int = 128 * 1024 * 1024
    total_bytes: int = 512 * 1024 * 1024
    entry_count: int = 10000
    compression_ratio: int = 200
    manifest_bytes: int = 1024 * 1024
    package_manifest_bytes: int = 16 * 1024 * 1024
    csv_bytes: int = 8 * 1024 * 1024
    bundle_decoded_bytes: int = 256 * 1024 * 1024
    texture_pixels: int = 16 * 1024 * 1024
    texture_total_pixels: int = 64 * 1024 * 1024
    object_count: int = 10000


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_id(guid: str, bundle_path: str, asset_name: str) -> str:
    """Identity excludes archive ordering, version, content hash and pathID."""
    encoded = json.dumps([guid, bundle_path, asset_name], ensure_ascii=False,
                         separators=(",", ":")).encode("utf-8")
    return "zipmod:" + digest(encoded)


def source_registers_bundle(name: str) -> bool:
    """ZipmodInfo uses EndsWith(".unity3d", OrdinalIgnoreCase), with any prefix.

    Do not infer registration from payload magic or normalize the archive path.
    The fixed ASCII suffix is the only case-insensitive part of this check.
    """
    return name[-8:].lower() == ".unity3d"


def safe_source_path(name: str) -> str:
    # Do not repair an ambiguous source path: its exact spelling is identity.
    if not name or len(name) > 1024 or name.startswith("/") or "\\" in name or ":" in name:
        raise ImportFailure(f"Unsafe archive path: {name!r}")
    if any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ImportFailure(f"Control character in archive path: {name!r}")
    parts = name.removesuffix("/").split("/")
    if any(p in ("", ".", "..") or p.endswith((".", " ")) for p in parts):
        raise ImportFailure(f"Ambiguous archive path: {name!r}")
    return name


def checked_entries(archive: zipfile.ZipFile, limits: Limits) -> list[zipfile.ZipInfo]:
    infos = archive.infolist()
    if len(infos) > limits.entry_count:
        raise ImportFailure("ZIP entry count exceeds limit")
    seen: dict[str, str] = {}
    prefixes: dict[str, str] = {}
    files: set[str] = set()
    total = 0
    for info in infos:
        # ZipInfo truncates filename at NUL; orig_filename retains the evidence.
        name = safe_source_path(info.orig_filename)
        if name != info.filename:
            raise ImportFailure("ZIP filename was altered while parsing")
        key = unicodedata.normalize("NFC", name.removesuffix("/")).casefold()
        if key in seen:
            raise ImportFailure(f"Duplicate or case-folding path collision: {seen[key]!r}, {name!r}")
        seen[key] = name
        parts = name.removesuffix("/").split("/")
        for index in range(1, len(parts) + 1):
            prefix = "/".join(parts[:index])
            normalized = unicodedata.normalize("NFC", prefix).casefold()
            if normalized in prefixes and prefixes[normalized] != prefix:
                raise ImportFailure(f"Case-folding directory collision: {prefix!r}")
            prefixes[normalized] = prefix
        mode = info.external_attr >> 16
        file_type = stat.S_IFMT(mode)
        if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise ImportFailure(f"Symlink or special ZIP entry: {name!r}")
        if file_type == stat.S_IFDIR and not info.is_dir():
            raise ImportFailure(f"Inconsistent ZIP directory mode: {name!r}")
        if info.flag_bits & 1 or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise ImportFailure(f"Encrypted or unsupported ZIP compression: {name!r}")
        if info.is_dir() and info.file_size:
            raise ImportFailure(f"Directory contains data: {name!r}")
        if info.file_size > limits.file_bytes:
            raise ImportFailure(f"ZIP entry exceeds size limit: {name!r}")
        if info.file_size and info.file_size > max(1, info.compress_size) * limits.compression_ratio:
            raise ImportFailure(f"ZIP expansion ratio exceeds limit: {name!r}")
        total += info.file_size
        if total > limits.total_bytes:
            raise ImportFailure("Total expanded ZIP size exceeds limit")
        if not info.is_dir():
            files.add(key)
    for key in seen:
        parts = key.split("/")
        if any("/".join(parts[:i]) in files for i in range(1, len(parts))):
            raise ImportFailure("ZIP file/directory ancestor collision")
    return sorted(infos, key=lambda item: item.filename)


def read_entry(archive: zipfile.ZipFile, info: zipfile.ZipInfo, bound: int) -> bytes:
    if info.file_size > bound:
        raise ImportFailure(f"Entry exceeds parser limit: {info.filename!r}")
    with archive.open(info) as stream:
        data = stream.read(bound + 1)
    if len(data) != info.file_size or len(data) > bound:
        raise ImportFailure(f"Expanded entry length mismatch: {info.filename!r}")
    return data


def parse_manifest(data: bytes) -> tuple[dict, list[dict]]:
    try:
        text = data.decode("utf-8-sig")
        if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper() or "\x00" in text:
            raise ImportFailure("DTD/entity declarations and UTF-16 XML are not supported")
        root = ET.fromstring(text)
    except (UnicodeError, ET.ParseError) as error:
        raise ImportFailure("Manifest must be well-formed UTF-8 XML") from error
    if root.tag != "manifest" or root.attrib.get("schema-ver") != "1":
        raise ImportFailure("Root manifest schema-ver must be 1")
    for field in ("guid", "name", "version"):
        if len(root.findall(field)) > 1:
            raise ImportFailure(f"Duplicate manifest {field} field")
    fields = {key: (root.findtext(key) or "").strip() for key in ("guid", "version", "name")}
    if not fields["guid"]:
        raise ImportFailure("Manifest GUID must be nonempty")
    fields["games"] = [e.text.strip() for e in root.findall("game") if e.text and e.text.strip()]
    migrations = [{"attributes": dict(sorted(e.attrib.items())), "xml": ET.tostring(e, encoding="unicode")}
                  for e in root.findall("migrationInfo/info")]
    return fields, migrations


def parse_catalog(data: bytes) -> dict:
    encoding = "utf-8-sig"
    try:
        text = data.decode(encoding)
    except UnicodeDecodeError:
        encoding = "cp932"
        text = data.decode(encoding)
    lines = text.splitlines()
    if len(lines) < 4:
        raise ValueError("Catalog requires three preamble lines and a header")
    rows = list(csv.reader(io.StringIO("\n".join(lines[3:])), strict=True))
    columns = rows[0]
    if not columns or columns[0] != "ID" or len(set(columns)) != len(columns):
        raise ValueError("Catalog requires unique columns starting with ID")
    if any(len(row) != len(columns) for row in rows[1:]):
        raise ValueError("Catalog row width differs from header")
    return {"encoding": encoding, "preamble": lines[:3], "columns": columns, "rows": rows[1:]}


class Cursor:
    def __init__(self, data: bytes):
        self.data, self.position = data, 0

    def take(self, count: int) -> bytes:
        if count < 0 or self.position + count > len(self.data):
            raise ValueError("Truncated UnityFS metadata")
        result = self.data[self.position:self.position + count]
        self.position += count
        return result

    def number(self, fmt: str) -> int:
        return struct.unpack(">" + fmt, self.take(struct.calcsize(">" + fmt)))[0]

    def string(self, bound: int = 1024) -> str:
        end = self.data.find(b"\0", self.position, self.position + bound + 1)
        if end < 0:
            raise ValueError("Unterminated UnityFS string")
        return self.take(end - self.position + 1)[:-1].decode("utf-8")


def unityfs_identity(data: bytes) -> dict:
    cursor = Cursor(data)
    signature = cursor.string(16)
    if signature != "UnityFS":
        raise ValueError("Only UnityFS bundle conversion is supported")
    return {"signature": signature, "formatVersion": cursor.number("I"),
            "playerVersion": cursor.string(128), "unityVersion": cursor.string(128)}


def validate_unityfs(data: bytes, limits: Limits) -> dict:
    """Preflight the observed Unity 5.x format before optional UnityPy parsing.

    Reject LZMA/encrypted/newer formats instead of allowing unbounded internal
    decompression. LZ4 decoding uses an explicit expected-size bound.
    """
    identity = unityfs_identity(data)
    cursor = Cursor(data)
    cursor.string(16); cursor.number("I"); cursor.string(128); cursor.string(128)
    size = cursor.number("Q")
    packed, unpacked, flags = cursor.number("I"), cursor.number("I"), cursor.number("I")
    if identity["formatVersion"] != 6 or not identity["unityVersion"].startswith("5."):
        raise ValueError("Texture conversion currently supports UnityFS v6 / Unity 5.x only")
    if size != len(data) or flags & ~0x1FF or flags & 0x3F not in (0, 2, 3):
        raise ValueError("Unsupported UnityFS flags, compression or size")
    if packed > len(data) or unpacked > min(limits.bundle_decoded_bytes, 4 * 1024 * 1024):
        raise ValueError("UnityFS block metadata exceeds bounds")
    metadata_start = len(data) - packed if flags & 0x80 else cursor.position
    if metadata_start < cursor.position or metadata_start + packed > len(data):
        raise ValueError("UnityFS block metadata range is invalid")
    block_bytes = data[metadata_start:metadata_start + packed]
    if flags & 0x3F:
        from UnityPy.helpers.CompressionHelper import decompress_lz4
        block_bytes = decompress_lz4(block_bytes, unpacked)
    if len(block_bytes) != unpacked:
        raise ValueError("UnityFS metadata decompressed size mismatch")
    blocks = Cursor(block_bytes)
    blocks.take(16)
    count = blocks.number("i")
    if count < 0 or count > limits.object_count:
        raise ValueError("UnityFS block count exceeds bounds")
    total_plain = total_packed = 0
    for _ in range(count):
        plain, compressed, block_flags = blocks.number("I"), blocks.number("I"), blocks.number("H")
        if block_flags & ~0x7F or block_flags & 0x3F not in (0, 2, 3):
            raise ValueError("Unsupported UnityFS block compression")
        total_plain += plain
        total_packed += compressed
        if total_plain > limits.bundle_decoded_bytes or total_packed > len(data):
            raise ValueError("UnityFS decoded payload exceeds bounds")
    data_start = cursor.position if flags & 0x80 else metadata_start + packed
    data_end = metadata_start if flags & 0x80 else len(data)
    if total_packed != data_end - data_start:
        raise ValueError("UnityFS compressed payload length mismatch")
    nodes = blocks.number("i")
    if nodes < 0 or nodes > limits.object_count:
        raise ValueError("UnityFS directory count exceeds bounds")
    names = set()
    for _ in range(nodes):
        offset, length = blocks.number("q"), blocks.number("q")
        blocks.number("I")
        name = safe_source_path(blocks.string())
        if name in names or offset < 0 or length < 0 or offset + length > total_plain:
            raise ValueError("Invalid UnityFS internal file range or duplicate name")
        names.add(name)
    identity["decodedBytes"] = total_plain
    return identity


def write_blob(stage: Path, data: bytes, directory: str, suffix: str) -> tuple[str, str]:
    sha = digest(data)
    relative = f"{directory}/{sha}{suffix}"
    destination = stage / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        destination.write_bytes(data)
    return relative, sha


def diagnostic(manifest: dict, code: str, message: str, severity: str = "warning") -> None:
    manifest["diagnostics"].append({"code": code, "severity": severity, "message": message})


def extract_textures(data: bytes, bundle: dict, package: dict, stage: Path, limits: Limits) -> None:
    import UnityPy
    bundle.update(validate_unityfs(data, limits))
    env = UnityPy.load(data)  # bytes only: do not supply a source filesystem root.
    objects = sorted(env.objects, key=lambda o: (str(o.assets_file.name), o.path_id))
    if len(objects) > limits.object_count:
        raise ValueError("Unity object count exceeds limit")
    names: dict[str, int] = {}
    textures = []
    total_pixels = sum(resource["width"] * resource["height"] for resource in package["resources"])
    for obj in objects:
        item = {"sourcePathID": obj.path_id, "serializedFile": str(obj.assets_file.name),
                "type": obj.type.name, "assetName": None, "status": "unsupported"}
        bundle["objects"].append(item)
        if obj.type.name != "Texture2D":
            continue
        try:
            texture = obj.read()
            item["assetName"] = texture.m_Name
            names[texture.m_Name] = names.get(texture.m_Name, 0) + 1
            width, height = texture.m_Width, texture.m_Height
            if not texture.m_Name or not 0 < width <= 16384 or not 0 < height <= 16384 or width * height > limits.texture_pixels:
                raise ValueError("Unnamed texture or dimensions exceed limits")
            total_pixels += width * height
            if total_pixels > limits.texture_total_pixels:
                raise ValueError("Total texture pixel count exceeds limit")
            stream = getattr(texture, "m_StreamData", None)
            if stream and (getattr(stream, "size", 0) or getattr(stream, "path", "")):
                raise ValueError("External/streamed texture data is not supported")
            textures.append((texture, item))
        except Exception as error:
            diagnostic(package, "texture_unsupported", f"{bundle['bundlePath']} pathID {obj.path_id}: {error}")
    for texture, item in textures:
        if names[texture.m_Name] != 1:
            diagnostic(package, "ambiguous_asset_identity", f"Duplicate texture name in {bundle['bundlePath']}: {texture.m_Name}")
            continue
        try:
            png = io.BytesIO()
            texture.image.save(png, format="PNG", optimize=False, compress_level=9)
            relative, sha = write_blob(stage, png.getvalue(), "textures", ".png")
            resource_id = stable_id(package["source"]["guid"], bundle["bundlePath"], texture.m_Name)
            package["resources"].append({"id": resource_id, "kind": "texture2D", "status": "converted",
                "bundlePath": bundle["bundlePath"], "assetName": texture.m_Name,
                "sourcePathID": item["sourcePathID"], "sourceSHA256": bundle["sha256"],
                "path": relative, "sha256": sha, "width": texture.m_Width, "height": texture.m_Height})
            item.update(status="converted", resourceID=resource_id)
        except Exception as error:
            diagnostic(package, "texture_unsupported", f"{bundle['bundlePath']} pathID {item['sourcePathID']}: {error}")
    unsupported = sum(item["status"] == "unsupported" for item in bundle["objects"])
    if unsupported:
        diagnostic(package, "unity_objects_unsupported", f"{bundle['bundlePath']}: {unsupported} objects have no native conversion")


def import_archive(source: Path, output: Path, *, textures: bool = False, limits: Limits = Limits()) -> dict:
    if any(value <= 0 for value in asdict(limits).values()):
        raise ValueError("All import limits must be positive")
    source = source.resolve(strict=True)
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise ImportFailure("Output already exists; choose a new package directory")
    if not source.is_file() or source.stat().st_size > limits.archive_bytes:
        raise ImportFailure("Source is not a file or archive size exceeds limit")
    # A snapshot avoids mixing hashes and content if the source changes mid-run.
    with source.open("rb") as stream:
        archive_data = stream.read(limits.archive_bytes + 1)
    if len(archive_data) > limits.archive_bytes:
        raise ImportFailure("Archive grew beyond size limit")
    package = {"schemaVersion": 1, "kind": "ikkoku-mod-package", "converter": dict(CONVERTER),
               "source": {}, "sourceManifest": {}, "archiveEntries": [], "resources": [],
               "catalogs": [], "bundles": [], "bundleRegistrationOrder": [], "diagnostics": []}
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".zipmod-", dir=output.parent))
    try:
        with zipfile.ZipFile(io.BytesIO(archive_data)) as archive:
            entries = checked_entries(archive, limits)
            # checked_entries returns a sorted index after validating every entry.
            # Source alias precedence uses the original ZIP enumeration instead.
            package["bundleRegistrationOrder"] = [info.filename for info in archive.infolist()
                                                   if source_registers_bundle(info.filename)]
            manifest_info = next((e for e in entries if e.filename == "manifest.xml" and not e.is_dir()), None)
            if manifest_info is None:
                raise ImportFailure("Archive must contain exactly one root manifest.xml")
            xml = read_entry(archive, manifest_info, limits.manifest_bytes)
            metadata, migrations = parse_manifest(xml)
            package["source"] = {**metadata, "archiveSHA256": digest(archive_data)}
            xml_path, xml_sha = write_blob(stage, xml, "source", ".bin")
            package["sourceManifest"] = {"sourcePath": "manifest.xml", "path": xml_path,
                                         "sha256": xml_sha, "migrations": migrations}
            for info in entries:
                name = info.filename
                if info.is_dir():
                    package["archiveEntries"].append({"sourcePath": name, "kind": "directory", "status": "preserved"})
                    continue
                data = read_entry(archive, info, limits.file_bytes)
                relative, sha = write_blob(stage, data, "source", ".bin")
                entry = {"sourcePath": name, "path": relative, "sha256": sha, "size": len(data),
                         "kind": "file", "status": "preserved"}
                package["archiveEntries"].append(entry)
                lower = name.lower()
                if lower.endswith((".dll", ".exe")):
                    entry.update(kind="managedOrNativePlugin", status="unsupported")
                    diagnostic(package, "plugin_behavior_unsupported", f"{name}: binary preserved without execution or behavior conversion")
                elif lower.startswith("abdata/list/") and lower.endswith(".csv"):
                    entry["kind"] = "catalog"
                    catalog = {"sourcePath": name, "path": relative, "sha256": sha, "status": "preserved"}
                    package["catalogs"].append(catalog)
                    try:
                        if len(data) > limits.csv_bytes:
                            raise ValueError("Catalog exceeds parser size limit")
                        catalog.update(parse_catalog(data))
                    except (ValueError, UnicodeError, csv.Error) as error:
                        catalog["parseStatus"] = "unsupported"
                        diagnostic(package, "catalog_parse_unsupported", f"{name}: {error}")
                elif source_registers_bundle(name):
                    entry["kind"] = "unityBundle"
                    bundle = {"bundlePath": name, "path": relative, "sha256": sha, "status": "preserved",
                              "objects": [], "objectInspection": "notRequested"}
                    package["bundles"].append(bundle)
                    try:
                        bundle.update(unityfs_identity(data))
                    except ValueError as error:
                        diagnostic(package, "bundle_format_unsupported", f"{name}: {error}")
                    if textures:
                        try:
                            extract_textures(data, bundle, package, stage, limits)
                            bundle["objectInspection"] = "complete"
                        except Exception as error:
                            bundle["objectInspection"] = "unsupported"
                            diagnostic(package, "bundle_conversion_unsupported", f"{name}: {error}")
                elif data.startswith((b"UnityFS\0", b"UnityRaw\0", b"UnityWeb\0")):
                    entry["kind"] = "unregisteredUnityBundle"
                    diagnostic(package, "bundle_not_registered",
                               f"{name}: Unity payload preserved without conversion; Sideloader only registers .unity3d names")
        package["resources"].sort(key=lambda r: r["id"])
        package["diagnostics"].sort(key=lambda d: (d["code"], d["message"], d["severity"]))
        encoded_manifest = (json.dumps(package, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
        if len(encoded_manifest) > limits.package_manifest_bytes:
            raise ImportFailure("Generated package manifest exceeds native reader size limit")
        (stage / "manifest.json").write_bytes(encoded_manifest)
        if output.exists() or output.is_symlink():
            raise ImportFailure("Output appeared during import; refusing to replace it")
        os.rename(stage, output)
        return package
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path, help="New package directory; existing outputs are never replaced")
    parser.add_argument("--textures", action="store_true", help="Optionally convert supported inline Texture2D objects using UnityPy")
    args = parser.parse_args()
    try:
        result = import_archive(args.archive, args.output, textures=args.textures)
    except (ImportFailure, zipfile.BadZipFile, OSError) as error:
        parser.exit(1, f"Import failed: {error}\n")
    print(json.dumps({"manifest": str(args.output / "manifest.json"), "guid": result["source"]["guid"],
                      "texturesConverted": len(result["resources"]), "catalogs": len(result["catalogs"]),
                      "diagnostics": len(result["diagnostics"])}))


if __name__ == "__main__":
    main()
