#!/usr/bin/env python3
"""Recover and decode local Character Maker shape channels into a neutral JSON contract."""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import re
import struct
import subprocess

REPO = Path(__file__).resolve().parents[3]
LOCAL = REPO / ".local/reverse"
TYPES = ("ChaControl", "ChaFile", "ChaFileCustom", "ChaFileBody", "ChaFileFace",
         "ChaFileHair", "ChaFileDefine", "BlockHeader", "ShapeInfoBase", "AnimationKeyInfo",
         "ShapeBodyInfoFemale", "ShapeHeadInfoFemale")


def provenance(path: Path) -> dict:
    data = path.read_bytes()
    return {"path": str(path.resolve()), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


class Reader:
    def __init__(self, data: bytes):
        self.data, self.offset = data, 0
        if len(data) > 64 * 1024 * 1024:
            raise ValueError("shape data exceeds 64 MiB")

    def take(self, count: int) -> bytes:
        if count < 0 or self.offset + count > len(self.data):
            raise ValueError(f"truncated shape data at byte {self.offset}")
        result = self.data[self.offset:self.offset + count]
        self.offset += count
        return result

    def i32(self) -> int:
        return struct.unpack("<i", self.take(4))[0]

    def count(self) -> int:
        count = self.i32()
        if not 0 <= count <= 100_000:
            raise ValueError("invalid shape record count")
        return count

    def string(self) -> str:
        length = 0
        for index in range(5):
            byte = self.take(1)[0]
            if index == 4 and byte > 7:
                raise ValueError("invalid .NET string length")
            length |= (byte & 127) << (index * 7)
            if not byte & 128:
                if length > 1024 * 1024:
                    raise ValueError("shape string exceeds 1 MiB")
                return self.take(length).decode("utf-8")
        raise ValueError("unterminated .NET string")

    def transform(self) -> dict:
        values = struct.unpack("<9f", self.take(36))
        if not all(math.isfinite(value) for value in values):
            raise ValueError("nonfinite shape transform")
        return {"position": list(values[:3]), "rotationDegrees": list(values[3:6]), "scale": list(values[6:])}

    def end(self) -> None:
        if self.offset != len(self.data):
            raise ValueError(f"unexpected shape data at byte {self.offset}")


def channels(path: Path) -> list[dict]:
    reader = Reader(path.read_bytes())
    result, names, total_samples = [], set(), 0
    for _ in range(reader.count()):
        name = reader.string()
        if name in names:
            raise ValueError(f"duplicate channel {name}")
        names.add(name)
        samples = []
        count = reader.count()
        total_samples += count
        if not count or total_samples > 1_000_000:
            raise ValueError("invalid total shape sample count")
        for _ in range(count):
            samples.append({"key": reader.i32(), **reader.transform()})
        result.append({"name": name, "samples": samples})
    reader.end()
    return result


def initializer(source: str, name: str) -> str:
    match = re.search(r"\b" + re.escape(name) + r"\s*=\s*new\s+[^;{]+\{([^}]+)\}", source)
    if not match:
        raise ValueError(f"array initializer {name} was not found in recovered metadata")
    return match.group(1)


def labels(source: str, name: str) -> list[str]:
    return re.findall(r'"([^"\\]*)"', initializer(source, name))


def enum_names(source: str, name: str) -> list[str]:
    match = re.search(r"public enum " + re.escape(name) + r"\s*\{([^}]+)\}", source)
    if not match:
        raise ValueError(f"enum {name} not found")
    names = [entry.strip() for entry in match.group(1).split(",") if entry.strip()]
    if any(not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", name) for name in names):
        raise ValueError("unexpected explicit enum values; review rather than guessing ordinals")
    return names


def slots(path: Path, names: list[str], source_names: list[str]) -> list[dict]:
    result = [{"index": index, "label": name, "bindings": []} for index, name in enumerate(names)]
    index_by_name = {name: index for index, name in enumerate(source_names)}
    for line, row in enumerate(csv.reader(io.StringIO(path.read_text(encoding="utf-8-sig")), delimiter="\t"), 1):
        if not row or not any(row):
            continue
        if len(row) != 11:
            raise ValueError(f"category row {line} has {len(row)} columns, expected 11")
        index = int(row[0])
        if not 0 <= index < len(names) or row[1] not in index_by_name:
            raise ValueError(f"unresolved category row {line}")
        # The recovered loader interprets any text except "0" as enabled.
        flags = [value != "0" for value in row[2:]]
        result[index]["bindings"].append({"sourceName": row[1], "sourceIndex": index_by_name[row[1]],
                                           "positionMask": flags[:3], "rotationMask": flags[3:6], "scaleMask": flags[6:]})
    return result


def direct_target(source: str, destination: str, position: str = "", rotation: str = "", scale: str = "") -> dict:
    return {"sourceName": source, "destinationName": destination,
            "positionMask": [axis in position for axis in "xyz"],
            "rotationMask": [axis in rotation for axis in "xyz"],
            "scaleMask": [axis in scale for axis in "xyz"]}


def make_domain(identifier: str, source_dir: Path, text_dir: Path, defines: str) -> dict:
    body = identifier == "body"
    source_file = source_dir / ("ShapeBodyInfoFemale.cs" if body else "ShapeHeadInfoFemale.cs")
    source = source_file.read_text()
    names = labels(defines, "cf_bodyshapename" if body else "cf_headshapename")
    if len(names) != (44 if body else 52):
        raise ValueError("shape slot count differs from observed assembly; review required")
    source_names = enum_names(source, "SrcName" if body else "SrcBoneName")
    destination_names = enum_names(source, "DstName" if body else "DstBoneName")
    defaults = [0.5] * len(names) if body else [float(value.strip().removesuffix("f")) for value in initializer(defines, "cf_faceInitValue").split(",") if value.strip()]
    if len(defaults) != len(names):
        raise ValueError("default count differs from slot count")
    category_path = text_dir / ("cf_custombody.bytes" if body else "cf_customhead.bytes")
    channel_path = text_dir / ("cf_anmShapeBody.bytes" if body else "cf_anmShapeHead_00.bytes")
    bindings = slots(category_path, names, source_names)
    data = channels(channel_path)
    available = {item["name"] for item in data}
    unresolved = {b["sourceName"] for slot in bindings for b in slot["bindings"]} - available
    if unresolved:
        raise ValueError(f"category channels missing from animation file: {sorted(unresolved)}")
    if body:
        targets = [direct_target("cf_a_height", "cf_n_height", scale="xyz")]
    else:
        # These exact setters copy the source components without correction formulas.
        # Other destination operations are deliberately omitted and enumerated as unported.
        simple = [("cf_J_FaceUp_tz", "z", ""), ("cf_J_NoseBridge_ty", "yz", ""),
                  ("cf_J_FaceUp_ty", "y", "xyz"), ("cf_J_FaceLow_tz", "z", ""),
                  ("cf_J_ChinLow", "y", "xyz"), ("cf_J_Nose_tip", "z", ""),
                  ("cf_J_NoseBase_rx", "yz", ""), ("cf_J_NoseBridge_rx", "z", ""),
                  ("cf_J_CheekUpBase", "y", ""), ("cf_J_CheekUp_s_L", "xyz", ""),
                  ("cf_J_CheekUp_s_R", "xyz", "")]
        targets = [direct_target(name, name, position=position, scale=scale) for name, position, scale in simple]
    if any(target["sourceName"] not in source_names or target["destinationName"] not in destination_names for target in targets):
        raise ValueError("direct operation names no longer match recovered enums")
    targets_present = {target["destinationName"] for target in targets}
    return {"id": identifier, "valueCount": len(names), "defaultValues": defaults,
            "sourceNames": source_names, "destinationNames": destination_names,
            "slots": bindings, "channels": data, "directTargets": targets,
            "unportedDestinationNames": [name for name in destination_names if name not in targets_present],
            "provenance": [provenance(source_file), provenance(category_path), provenance(channel_path)],
            "destinationEvidence": f"{source_file.stem}.Update"}


def recover(assembly: Path, output: Path) -> None:
    tool = LOCAL / "tools/ilspycmd"
    manifest = {"assembly": provenance(assembly), "types": []}
    output.mkdir(parents=True, exist_ok=True)
    for name in TYPES:
        result = subprocess.run([str(tool), "--disable-updatecheck", "-r", str(LOCAL / "managed/CharaStudio"),
                                 "-t", name, str(assembly)], check=True, capture_output=True)
        path = output / f"{name}.cs"
        path.write_bytes(result.stdout)
        manifest["types"].append(provenance(path))
    manifest["toolVersion"] = subprocess.run([str(tool), "--version"], check=True, capture_output=True, text=True).stdout.strip()
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assembly", type=Path, default=LOCAL / "source/Koikatu_Data/Managed/Assembly-CSharp.dll")
    parser.add_argument("--sources", type=Path, default=LOCAL / "decompiled/Character/Koikatu")
    parser.add_argument("--textassets", type=Path, default=LOCAL / "rigs/textassets")
    parser.add_argument("--output", type=Path, default=LOCAL / "rigs/character-shape-contract.json")
    parser.add_argument("--recover", action="store_true", help="Run bounded ILSpy recovery before generating the contract")
    args = parser.parse_args()
    for output in (args.sources, args.output):
        if not output.resolve().is_relative_to((REPO / ".local").resolve()):
            parser.error("Recovered output must stay under the ignored .local directory")
    if args.recover:
        recover(args.assembly, args.sources)
    defines_path = args.sources / "ChaFileDefine.cs"
    defines = defines_path.read_text()
    domains = [make_domain(name, args.sources, args.textassets, defines) for name in ("body", "face")]
    contract = {"schemaVersion": 1, "coordinateSystem": "UnityLeftHandedYUp",
                "rotationUnit": "degrees", "valueRange": [0, 1],
                "provenance": [provenance(args.assembly), provenance(defines_path)],
                "domains": domains}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(contract, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    print(json.dumps({"output": str(args.output.resolve()), "domains": [
        {"id": d["id"], "slots": d["valueCount"], "channels": len(d["channels"]),
         "bindings": sum(len(s["bindings"]) for s in d["slots"]), "directTargets": len(d["directTargets"]),
         "sampleCounts": sorted({len(c["samples"]) for c in d["channels"]})} for d in domains]}, indent=2))


if __name__ == "__main__":
    main()
