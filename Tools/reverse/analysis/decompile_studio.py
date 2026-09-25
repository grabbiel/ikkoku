#!/usr/bin/env python3
"""Recover a bounded set of Studio contracts into ignored local output using ILSpy."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[3]
TYPES = (
    "Studio.SceneInfo", "Studio.ObjectInfo", "Studio.ObjectInfoAssist",
    "Studio.ChangeAmount", "Studio.OIFolderInfo", "Studio.OICameraInfo",
    "Studio.OIItemInfo", "Studio.OILightInfo", "Studio.PatternInfo",
    "Studio.OIBoneInfo", "Studio.OIIKTargetInfo", "Studio.CameraControl",
    "Studio.GuideObject", "Studio.FKCtrl", "Studio.IKCtrl", "Studio.Utility",
    "Studio.OCICamera",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--managed", type=Path, default=REPO / ".local/reverse/managed/CharaStudio")
    parser.add_argument("--tool", type=Path, default=REPO / ".local/reverse/tools/ilspycmd")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/decompiled/Studio")
    parser.add_argument("--type", action="append", choices=TYPES, dest="types",
                        help="Repeat to select only the requested contracts; defaults to all listed contracts")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((REPO / ".local").resolve()):
        parser.error("Recovered source must remain under the ignored repository .local directory")
    assembly = args.managed.resolve() / "Assembly-CSharp.dll"
    if not assembly.is_file():
        parser.error(f"Missing assembly: {assembly}. Fetch the observed Mono Managed files first.")
    tool = args.tool.resolve()
    if not tool.is_file():
        parser.error(f"Missing ILSpy command: {tool}. See docs/reference/studio/binary-contracts.md for installation.")
    output.mkdir(parents=True, exist_ok=True)
    version = subprocess.run([str(tool), "--version"], check=True, capture_output=True, text=True).stdout.strip()
    manifest = {
        "capturedAtUTC": datetime.now(timezone.utc).isoformat(),
        "assembly": str(assembly), "assemblyBytes": assembly.stat().st_size,
        "assemblySHA256": digest(assembly), "toolVersion": version,
        "contracts": [],
    }
    failed = False
    for name in args.types or TYPES:
        result = subprocess.run(
            [str(tool), "--disable-updatecheck", "-r", str(assembly.parent), "-t", name, str(assembly)],
            capture_output=True,
        )
        record = {"type": name, "exitCode": result.returncode}
        if result.returncode:
            failed = True
            (output / f"{name}.stderr.txt").write_bytes(result.stderr)
        else:
            path = output / f"{name}.cs"
            path.write_bytes(result.stdout)
            record.update(file=path.name, sha256=digest(path), bytes=path.stat().st_size)
        manifest["contracts"].append(record)
        print(f"{name}: {'failed' if result.returncode else 'recovered'}")
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Provenance: {manifest_path}")
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
