#!/usr/bin/env python3
"""Read-only, hash-verified access to a local Unity installation in Parallels."""
from __future__ import annotations

import argparse
import base64
import hashlib
import gzip
import json
import os
from pathlib import Path, PureWindowsPath
import subprocess

REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO / ".local/reverse"


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def powershell(vm: str, script: str) -> str:
    # prlctl reconstructs a Windows command line; EncodedCommand avoids quoting
    # differences between zsh, prlctl, cmd.exe, and PowerShell.
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    command = ["-EncodedCommand", encoded]
    if len(encoded) > 3000:
        compressed = base64.b64encode(gzip.compress(script.encode("utf-8"))).decode("ascii")
        wrapper = "$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String('" + compressed + "'));"
        wrapper += "$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);"
        wrapper += "$r=New-Object IO.StreamReader($g);Invoke-Expression $r.ReadToEnd()"
        # The compressed wrapper contains no double quotes or user path text.
        # Sending it as ASCII avoids Parallels' ~4 KiB command limit.
        command = ["-Command", wrapper]
    result = subprocess.run(
        ["prlctl", "exec", vm, "powershell.exe", "-NoProfile", "-NonInteractive",
         *command], text=True, capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(f"VM read failed ({result.returncode}): {result.stderr or result.stdout}")
    return result.stdout.lstrip("\ufeff").strip()


def inventory(vm: str, source: str) -> dict:
    script = (Path(__file__).with_name("inventory.ps1")).read_text()
    return json.loads(powershell(vm, "$SourceRoot=" + ps_quote(source) + ";\n" + script))


def fetch(vm: str, source: str, relative: str, output: Path, max_bytes: int) -> dict:
    path = PureWindowsPath(relative)
    if path.is_absolute() or path.drive or ".." in path.parts or ":" in relative:
        raise ValueError("Source path must be relative to the installation, without '..'")
    source_file = str(PureWindowsPath(source) / path)
    script = "$ErrorActionPreference='Stop'; $p=" + ps_quote(source_file) + ";"
    script += "$f=Get-Item -LiteralPath $p;"
    script += f"if ($f.PSIsContainer -or $f.Length -gt {max_bytes}) {{throw 'Not a file, or exceeds size limit'}};"
    script += "[PSCustomObject]@{length=$f.Length;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower();data=[Convert]::ToBase64String([IO.File]::ReadAllBytes($p))}|ConvertTo-Json -Compress"
    record = json.loads(powershell(vm, script))
    data = base64.b64decode(record.pop("data"), validate=True)
    if len(data) != record["length"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
        raise ValueError("Transfer did not match source size and SHA-256")
    destination = output / "source" / Path(*path.parts)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    record.update(source=source_file, relativePath=path.as_posix(), localPath=str(destination), vm=vm)
    destination.with_name(destination.name + ".provenance.json").write_text(json.dumps(record, indent=2) + "\n")
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vm", default=os.environ.get("IKKOKU_SOURCE_VM"), help="Parallels VM UUID/name")
    parser.add_argument("--source", default=r"C:\Illusion\Koikatsu")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inventory")
    copy = commands.add_parser("fetch")
    copy.add_argument("paths", nargs="+", help="Explicit paths relative to the install")
    copy.add_argument("--max-mib", type=int, default=256, help="Per-file transfer bound")
    args = parser.parse_args()
    if not args.vm:
        parser.error("Provide --vm or IKKOKU_SOURCE_VM")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.command == "inventory":
        result = inventory(args.vm, args.source)
        result["vm"] = args.vm
        path = args.output / "inventory.json"
        path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps({"manifest": str(path), "players": result["players"],
                          "bundleCount": len(result["bundles"])}, indent=2))
    else:
        for path in args.paths:
            print(json.dumps(fetch(args.vm, args.source, path, args.output, args.max_mib * 1024 * 1024), indent=2))


if __name__ == "__main__":
    main()
