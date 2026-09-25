#!/usr/bin/env python3
"""Incremental local .zipmod discovery, immutable conversion cache and explicit profiles."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import asdict
import fcntl
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

import zipmod


SCHEMA = 1
JSON_LIMIT = 32 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
PROFILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")


class LibraryFailure(ValueError):
    pass


def encoded(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def diagnostic(code: str, message: str, severity: str = "error") -> dict:
    return {"code": code, "severity": severity, "message": message}


def contained(root: Path, relative: str) -> Path:
    """Output/cache paths are canonical relatives and never traverse symlinks."""
    if not isinstance(relative, str) or not relative or relative.startswith("/") or "\\" in relative or ":" in relative:
        raise LibraryFailure("Library path must be a canonical relative path")
    if any(ord(c) < 32 for c in relative) or any(p in ("", ".", "..") for p in relative.split("/")):
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


def read_json(path: Path, kind: str) -> dict:
    value = json.loads(read_file(path, JSON_LIMIT))
    if not isinstance(value, dict) or value.get("schemaVersion") != SCHEMA or value.get("kind") != kind:
        raise LibraryFailure(f"Unsupported {kind} schema")
    return value


def atomic_json(root: Path, relative: str, value: dict) -> None:
    destination = contained(root, relative)
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = encoded(value)
    if len(data) > JSON_LIMIT:
        raise LibraryFailure("Generated library/profile index exceeds its size limit")
    fd, temporary = tempfile.mkstemp(prefix=".index-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, destination)
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
            raise LibraryFailure("Another scan is updating this library") from error
        yield
    finally:
        os.close(fd)


def configuration(textures: bool, limits: zipmod.Limits) -> dict:
    dependencies = {}
    if textures:
        try:
            dependencies["UnityPy"] = importlib.metadata.version("UnityPy")
        except importlib.metadata.PackageNotFoundError:
            dependencies["UnityPy"] = None
    return {"converter": {**zipmod.CONVERTER, "sourceSHA256": zipmod.digest(Path(zipmod.__file__).read_bytes())},
            "options": {"textures": textures, "limits": asdict(limits), "dependencies": dependencies}}


def discover(roots: list[dict], library: Path) -> tuple[list[tuple[dict, str, Path]], list[dict]]:
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
            kept = []
            for name in sorted(directories):
                child = base / name
                if child.is_symlink():
                    diagnostics.append(diagnostic("symlink_skipped", f"Directory symlink skipped: {child}", "warning"))
                elif child.resolve() != library:
                    kept.append(name)
            directories[:] = kept
            for name in sorted(files):
                if name.lower().endswith(".zipmod"):
                    file = base / name
                    found.append((root, file.relative_to(directory).as_posix(), file))
    return sorted(found, key=lambda item: (item[1], item[0]["id"])), diagnostics


def snapshot(source: Path, target: Path, maximum: int) -> tuple[str, int]:
    descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    digest, size = hashlib.sha256(), 0
    with os.fdopen(descriptor, "rb") as stream, target.open("xb") as output:
        attributes = os.fstat(stream.fileno())
        if not stat.S_ISREG(attributes.st_mode) or attributes.st_size > maximum:
            raise LibraryFailure("Archive is not a regular file within the size limit")
        while block := stream.read(min(1024 * 1024, maximum + 1 - size)):
            size += len(block)
            if size > maximum:
                raise LibraryFailure("Archive grew beyond the size limit")
            digest.update(block); output.write(block)
    return digest.hexdigest(), size


def validate_package(directory: Path, archive_sha: str, expected_manifest_sha: str) -> dict:
    data = read_file(contained(directory, "manifest.json"), zipmod.Limits().package_manifest_bytes)
    if not SHA.fullmatch(expected_manifest_sha) or zipmod.digest(data) != expected_manifest_sha:
        raise LibraryFailure("Package manifest hash changed; cache generation is invalid")
    package = json.loads(data)
    if (package.get("kind") != "ikkoku-mod-package" or package.get("schemaVersion") != 1
            or package.get("converter") != zipmod.CONVERTER
            or package.get("source", {}).get("archiveSHA256") != archive_sha
            or not package.get("source", {}).get("guid")):
        raise LibraryFailure("Package provenance differs from the selected archive/converter")
    references = [package["sourceManifest"]]
    for collection in ("archiveEntries", "resources", "catalogs", "bundles"):
        references.extend(item for item in package[collection] if "path" in item)
    checked = {}
    for reference in references:
        path, expected = reference["path"], reference["sha256"]
        if not isinstance(expected, str) or not SHA.fullmatch(expected):
            raise LibraryFailure("Invalid cached blob digest")
        if path in checked:
            if checked[path] != expected:
                raise LibraryFailure("Conflicting cached blob digests")
            continue
        actual = zipmod.digest(read_file(contained(directory, path), 256 * 1024 * 1024))
        if actual != expected:
            raise LibraryFailure("Cached blob hash changed; cache generation is invalid")
        checked[path] = expected
    return package


def select_profile(name: str, old: dict, archives: list[dict], config_sha: str,
                   choices: dict[str, str] | None, clear_choices: list[str], order: list[str] | None) -> dict:
    selected_choices = dict(old.get("choices", {}))
    for guid in clear_choices:
        selected_choices.pop(guid, None)
    selected_choices.update(choices or {})
    if any(not isinstance(guid, str) or not guid or not isinstance(sha, str) or not SHA.fullmatch(sha)
           for guid, sha in selected_choices.items()):
        raise LibraryFailure("Profile choices require a nonempty GUID and lowercase archive SHA-256")
    candidates = {}
    for archive in archives:
        if archive["status"] == "ready":
            candidates.setdefault(archive["guid"], {}).setdefault(archive["archiveSHA256"], archive)
    selected, unresolved, diagnostics = {}, [], []
    for guid, available in candidates.items():
        choice = selected_choices.get(guid)
        if choice is not None and choice not in available:
            diagnostics.append(diagnostic("choice_unavailable", f"Explicit choice for {guid} is unavailable: {choice}"))
        elif choice is not None:
            selected[guid] = available[choice]
        elif len(available) == 1:
            selected[guid] = next(iter(available.values()))
        if guid not in selected:
            unresolved.append({"guid": guid, "archiveSHA256s": sorted(available)})
    for guid in sorted(set(selected_choices) - set(candidates)):
        diagnostics.append(diagnostic("choice_unavailable", f"No ready archive remains for explicitly selected GUID {guid}"))
    previous_order = old.get("mountOrder", []) if order is None else order
    if (not isinstance(previous_order, list) or any(not isinstance(guid, str) for guid in previous_order)
            or len(set(previous_order)) != len(previous_order)):
        raise LibraryFailure("Profile mount order must be a unique list of GUIDs")
    if order is not None and set(order) != set(selected):
        raise LibraryFailure("Explicit mount order must list every currently selectable GUID exactly once")
    mount_order = [guid for guid in previous_order if guid in selected]
    mount_order.extend(guid for guid in selected if guid not in mount_order)
    fields = ("guid", "version", "archiveSHA256", "generationID", "packageManifest", "packageManifestSHA256")
    return {**old, "schemaVersion": SCHEMA, "kind": "ikkoku-mod-profile", "name": name,
            "configurationSHA256": config_sha, "choices": dict(sorted(selected_choices.items())), "mountOrder": mount_order,
            "mounts": [{key: selected[guid][key] for key in fields} for guid in mount_order],
            "unresolvedConflicts": sorted(unresolved, key=lambda item: item["guid"]), "diagnostics": diagnostics}


def scan(library: Path, roots: list[Path] | None = None, *, textures: bool | None = None,
         profile: str = "default", choices: dict[str, str] | None = None,
         clear_choices: list[str] | None = None, order: list[str] | None = None,
         limits: zipmod.Limits = zipmod.Limits(), importer=None) -> dict:
    if not PROFILE.fullmatch(profile):
        raise LibraryFailure("Profile name must use 1-64 letters, digits, underscores or hyphens")
    if any(value <= 0 for value in asdict(limits).values()):
        raise LibraryFailure("Import limits must be positive")
    library = library.absolute()
    if library.is_symlink():
        raise LibraryFailure("Library directory cannot be a symlink")
    library.mkdir(parents=True, exist_ok=True)
    library = library.resolve()
    with locked(library):
        index_path = contained(library, "library.json")
        previous = read_json(index_path, "ikkoku-mod-library") if index_path.exists() else {}
        profile_path = contained(library, f"profiles/{profile}.json")
        old_profile = read_json(profile_path, "ikkoku-mod-profile") if profile_path.exists() else {}
        directories = roots if roots is not None else [Path(item["path"]) for item in previous.get("roots", [])]
        if not directories:
            raise LibraryFailure("Supply at least one explicit local scan root")
        directories = sorted(set(path.resolve() for path in directories))
        if any(path == library or path.is_relative_to(library) for path in directories):
            raise LibraryFailure("A scan root cannot be the library or a directory inside it")
        root_records = [{"id": zipmod.digest(str(path).encode()), "path": str(path)} for path in directories]
        if textures is None:
            textures = previous.get("options", {}).get("textures", False)
        config = configuration(textures, limits)
        config_sha = zipmod.digest(encoded(config))
        found, diagnostics = discover(root_records, library)
        if textures and config["options"]["dependencies"]["UnityPy"] is None:
            diagnostics.append(diagnostic("dependency_missing", "Texture conversion requested but UnityPy is not installed; raw archive data remains preservable", "warning"))
        generations = {item["generationID"]: item for item in previous.get("generations", [])}
        archives, validated = [], {}
        imported = reused = 0
        staging = contained(library, ".staging"); staging.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="scan-", dir=staging) as temporary:
            for sequence, (root, relative, source) in enumerate(found):
                item = {"rootID": root["id"], "relativePath": relative, "status": "invalid", "diagnostics": []}
                try:
                    work = Path(temporary) / str(sequence); work.mkdir()
                    source_copy = work / "source.zipmod"
                    archive_sha, size = snapshot(source, source_copy, limits.archive_bytes)
                    generation_id = f"{archive_sha}:{config_sha}"
                    package_relative = f"generations/{archive_sha}/{config_sha}/manifest.json"
                    destination = contained(library, package_relative).parent
                    item.update(archiveSHA256=archive_sha, bytes=size, generationID=generation_id)
                    history = generations.get(generation_id)
                    if generation_id in validated:
                        package, manifest_sha = validated[generation_id]
                        reused += 1
                    elif history is not None:
                        if history.get("packageManifest") != package_relative:
                            raise LibraryFailure("Cached generation path differs from its content identity")
                        manifest_sha = history["packageManifestSHA256"]
                        package = validate_package(destination, archive_sha, manifest_sha)
                        reused += 1
                    else:
                        if destination.exists():
                            raise LibraryFailure("Unindexed generation exists; refusing to trust or replace it")
                        converted = work / "package"
                        (importer or zipmod.import_archive)(source_copy, converted, textures=textures, limits=limits)
                        manifest_sha = zipmod.digest(read_file(converted / "manifest.json", limits.package_manifest_bytes))
                        package = validate_package(converted, archive_sha, manifest_sha)
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        if destination.exists() or destination.is_symlink():
                            raise LibraryFailure("Generation appeared during scan; refusing to replace it")
                        os.rename(converted, destination)
                        generations[generation_id] = {"generationID": generation_id, "archiveSHA256": archive_sha,
                            "configurationSHA256": config_sha, "packageManifest": package_relative,
                            "packageManifestSHA256": manifest_sha}
                        imported += 1
                    validated[generation_id] = (package, manifest_sha)
                    item.update(status="ready", guid=package["source"]["guid"], version=package["source"]["version"],
                                packageManifest=package_relative, packageManifestSHA256=manifest_sha,
                                diagnostics=package["diagnostics"])
                except Exception as error:
                    item["diagnostics"] = [diagnostic("archive_unavailable", f"{type(error).__name__}: {error}")]
                archives.append(item)
        archives.sort(key=lambda item: (item["relativePath"], item["rootID"], item.get("archiveSHA256", "")))
        by_guid = {}
        for archive in archives:
            if archive["status"] == "ready":
                by_guid.setdefault(archive["guid"], set()).add(archive["archiveSHA256"])
        conflicts = [{"guid": guid, "archiveSHA256s": sorted(hashes)} for guid, hashes in sorted(by_guid.items()) if len(hashes) > 1]
        result = {"schemaVersion": SCHEMA, "kind": "ikkoku-mod-library", **config, "configurationSHA256": config_sha,
                  "roots": root_records, "archives": archives, "conflicts": conflicts,
                  "generations": [generations[key] for key in sorted(generations)],
                  "diagnostics": sorted(diagnostics, key=lambda item: (item["code"], item["message"]))}
        try:
            selected = select_profile(profile, old_profile, archives, config_sha, choices, clear_choices or [], order)
        except LibraryFailure:
            # A bad profile edit must not strand successfully imported generations.
            # Keep the old profile and index completed imports for the corrected scan.
            atomic_json(library, "library.json", result)
            raise
        # Each document is replaced atomically. Native readers also validate the
        # configuration and every mounted package identity before accepting it.
        atomic_json(library, "library.json", result)
        atomic_json(library, f"profiles/{profile}.json", selected)
        return {"library": result, "profile": selected, "summary": {"imported": imported, "reused": reused,
            "invalid": sum(item["status"] != "ready" for item in archives), "mounted": len(selected["mounts"]),
            "unresolvedConflicts": len(selected["unresolvedConflicts"])}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["scan"])
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--root", action="append", type=Path, help="Explicit local directory; repeat for multiple roots. Later scans reuse saved roots.")
    parser.add_argument("--textures", action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument("--profile", default="default")
    parser.add_argument("--choose", action="append", default=[], metavar="GUID=SHA256")
    parser.add_argument("--clear-choice", action="append", default=[], metavar="GUID")
    parser.add_argument("--order", action="append", metavar="GUID", help="Repeat in the complete desired native mount order")
    args = parser.parse_args()
    try:
        choices = {}
        for value in args.choose:
            guid, separator, sha = value.rpartition("=")
            if not separator or guid in choices:
                raise LibraryFailure("Each --choose needs one unique GUID=SHA256")
            choices[guid] = sha
        result = scan(args.library, args.root, textures=args.textures, profile=args.profile,
                      choices=choices, clear_choices=args.clear_choice, order=args.order)
    except (LibraryFailure, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Library scan failed: {error}\n")
    print(json.dumps({"library": str(args.library.resolve() / "library.json"),
                      "profile": str(args.library.resolve() / "profiles" / (args.profile + ".json")), **result["summary"]}, sort_keys=True))


if __name__ == "__main__":
    main()
