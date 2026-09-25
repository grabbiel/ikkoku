#!/usr/bin/env python3
"""Verify native head poses against source setters and independent float64 math.

The reference parses the locally recovered ShapeHeadInfoFemale.Update setters;
it never reads the Swift implementation or its generated operation table. Shape
channels and category masks come from the hash-verified source data contract.
No source image is decoded and no game code is executed.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import subprocess

import numpy as np

from test_rig_parity import REPO, REFLECTION, compare, file_record, local_matrix, verify_provenance


def source_operations(path, domain):
    source = path.read_text()
    names = re.search(r"public enum DstBoneName\s*\{([^}]+)\}", source)
    if not names:
        raise ValueError("Missing source destination enum")
    names = [name.strip() for name in names[1].split(",") if name.strip()]
    if names != domain["destinationNames"] or len(names) != 59:
        raise ValueError("Source destination enum differs from contract")
    update = source.split("public override void Update()", 1)[1].split("public override void UpdateAlways()", 1)[0]
    blocks = re.findall(r"if \(dictDst.TryGetValue\((\d+), out value\)\)\s*\{([^}]+)\}", update)
    if [int(number) for number, _ in blocks] != list(range(59)):
        raise ValueError("Expected exactly 59 source setter blocks")
    # This one source block depends on the destination's parent's lossyScale.
    expected_first = """Transform parent = value.trfBone.parent;
float num = ((typeBone != 0) ? headCorrectValue : 1f);
float num2 = parent.lossyScale.y * num;
float num3 = num2 / parent.lossyScale.x;
float y = num2 / parent.lossyScale.y;
float z = num2 / parent.lossyScale.z;
value.trfBone.SetLocalScale(num3 + (dictSrc[0].vctScl.x - 1f), y, z);"""
    if re.sub(r"\s", "", blocks[0][1]) != re.sub(r"\s", "", expected_first):
        raise ValueError("FaceBase correction formula changed; reference needs review")
    operations = [(names[0], None)]
    for number, body in blocks[1:]:
        setters = []
        for statement in body.split(";"):
            if not statement.strip():
                continue
            setter = re.fullmatch(r"\s*value.trfBone.SetLocal(Position[XYZ]|Scale|Rotation)\(([^)]+)\)\s*", statement)
            if not setter:
                raise ValueError(f"Unsupported source setter in destination {number}: {statement}")
            operands = []
            for argument in setter[2].split(","):
                argument = argument.strip()
                reference = re.fullmatch(r"dictSrc\[(\d+)\]\.vct(Pos|Rot|Scl)\.([xyz])", argument)
                if reference:
                    operands.append((int(reference[1]), {"Pos": 0, "Rot": 1, "Scl": 2}[reference[2]], "xyz".index(reference[3])))
                elif re.fullmatch(r"-?\d+(?:\.\d+)?f", argument):
                    operands.append(float(argument[:-1]))
                else:
                    raise ValueError(f"Unsupported source argument {argument}")
            expected_count = 1 if setter[1].startswith("Position") else 3
            if len(operands) != expected_count:
                raise ValueError("Unexpected setter argument count")
            setters.append((setter[1], operands))
        operations.append((names[int(number)], setters))
    return operations


def shape_values(domain, rates):
    if len(rates) != domain["valueCount"] or any(not 0 <= value <= 1 for value in rates):
        raise ValueError("Invalid face rate array")
    channels = {channel["name"]: channel["samples"] for channel in domain["channels"]}
    # ShapeInfoBase.BoneInfo initializes position/rotation to zero and scale one.
    source = np.zeros((len(domain["sourceNames"]), 3, 3), dtype=np.float64)
    source[:, 2, :] = 1
    for slot in domain["slots"]:
        rate = rates[slot["index"]]
        for binding in slot["bindings"]:
            samples = channels[binding["sourceName"]]
            coordinate = (len(samples) - 1) * rate
            left = min(math.floor(coordinate), len(samples) - 2)
            fraction = coordinate - left
            for component, (field, mask_name) in enumerate((("position", "positionMask"), ("rotationDegrees", "rotationMask"), ("scale", "scaleMask"))):
                a = np.asarray(samples[left][field], dtype=np.float64)
                b = np.asarray(samples[left + 1][field], dtype=np.float64)
                if rate == 0:
                    value = np.asarray(samples[0][field], dtype=np.float64)
                elif rate == 1:
                    value = np.asarray(samples[-1][field], dtype=np.float64)
                elif component == 1:
                    # Mathf.LerpAngle uses Repeat(delta,360), then subtracts360
                    # only for values strictly above180 (positive180 tie).
                    delta = (b - a) % 360
                    delta[delta > 180] -= 360
                    value = a + delta * fraction
                else:
                    value = a + (b - a) * fraction
                mask = np.asarray(binding[mask_name], dtype=bool)
                source[binding["sourceIndex"], component, mask] = value[mask]
    return source


def euler_matrix(degrees):
    x, y, z = np.radians(degrees)
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    # Unity applies Euler Z, then X, then Y to a column vector.
    return ry @ rx @ rz


def reference_world(rig, domain, operations, rates, root_parent_matrix=None):
    locals_ = [local_matrix(node) for node in rig["nodes"]]
    by_name = {node["name"]: index for index, node in enumerate(rig["nodes"])}
    if len(by_name) != len(rig["nodes"]):
        raise ValueError("Duplicate source node name")
    translations = [np.asarray(node["translation"]).copy() for node in rig["nodes"]]
    scales = [np.asarray(node["scale"]).copy() for node in rig["nodes"]]
    rotations = [local[:3, :3] @ np.diag(1 / scale) for local, scale in zip(locals_, scales)]

    def rebuild(index):
        locals_[index][:3, :3] = rotations[index] @ np.diag(scales[index])
        locals_[index][:3, 3] = translations[index]

    root_parent_matrix = np.eye(4) if root_parent_matrix is None else root_parent_matrix

    def world_at(index):
        parent = rig["nodes"][index]["parent"]
        return root_parent_matrix @ locals_[index] if parent is None else world_at(parent) @ locals_[index]

    if rates is not None:
        source = shape_values(domain, rates)
        for name, setters in operations:
            index = by_name[name]
            if setters is None:
                parent = rig["nodes"][index]["parent"]
                parent_scale = np.linalg.norm(world_at(parent)[:3, :3], axis=0)
                scale = parent_scale[1] / parent_scale
                scale[0] += source[0, 2, 0] - 1
                scales[index] = scale
            else:
                for setter, operands in setters:
                    values = [source[value] if isinstance(value, tuple) else value for value in operands]
                    if setter.startswith("Position"):
                        translations[index]["XYZ".index(setter[-1])] = values[0]
                    elif setter == "Scale":
                        scales[index] = np.asarray(values)
                    else:
                        rotations[index] = euler_matrix(values)
            rebuild(index)
    world = []
    for index, node in enumerate(rig["nodes"]):
        parent = node["parent"]
        if parent is not None and not 0 <= parent < index:
            raise ValueError("Expected parent-before-child source hierarchy")
        world.append(root_parent_matrix @ locals_[index] if parent is None else world[parent] @ locals_[index])
    return np.asarray(world)


def reference_snapshot(rig, domain, operations, rates):
    if rig["coordinateSpace"] != "unity-left-handed-y-up" or rig["matrixLayout"] != "column-major":
        raise ValueError("Expected original Unity source coordinate system")
    world = reference_world(rig, domain, operations, rates)
    parts = {}
    for mesh in rig["meshes"]:
        if any(mesh["initialMorphWeights"]):
            raise ValueError("Expression morph weights are outside this verification")
        skin = rig["skins"][mesh["skin"]]
        binds = np.asarray([np.asarray(matrix).reshape(4, 4, order="F") for matrix in skin["inverseBindMatrices"]])
        source_palette = world[np.asarray(skin["joints"])] @ binds
        positions = np.c_[np.asarray(mesh["positions"]), np.ones(len(mesh["positions"]))]
        transformed = np.einsum("vlij,vj->vli", source_palette[np.asarray(mesh["joints"])], positions)
        deformed = np.einsum("vli,vl->vi", transformed, np.asarray(mesh["weights"]))
        for submesh in range(len(mesh["submeshes"])):
            parts[(f"{mesh['name']}/{submesh}", mesh["node"], mesh["skin"])] = (deformed @ REFLECTION)[:, :3]
    return {"world": REFLECTION @ world @ REFLECTION, "parts": parts}


def bind_report(rig, world):
    rows = []
    for mesh in rig["meshes"]:
        skin = rig["skins"][mesh["skin"]]
        binds = np.asarray([np.asarray(matrix).reshape(4, 4, order="F") for matrix in skin["inverseBindMatrices"]])
        palette = np.linalg.inv(world[skin["meshNode"]]) @ world[np.asarray(skin["joints"])] @ binds
        active, node = mesh["rendererEnabled"], mesh["node"]
        while node is not None:
            active = active and rig["nodes"][node]["active"]
            node = rig["nodes"][node]["parent"]
        rows.append({"mesh": mesh["name"], "vertices": len(mesh["positions"]), "submeshes": len(mesh["submeshes"]),
                     "joints": len(skin["joints"]), "activeInPrefab": active,
                     "initialMorphWeights": mesh["initialMorphWeights"], "morphChannels": len(mesh["morphChannels"]),
                     "paletteIdentityResidual": float(np.max(np.abs(palette - np.eye(4))))})
    return rows


def cases(domain):
    count, defaults = domain["valueCount"], domain["defaultValues"]
    yield "rest", None
    yield "defaults", defaults
    for rate in (0, 0.37, 0.5, 1):
        yield f"all={rate}", [rate] * count
    mixed = [((index * 17 + 3) % 101) / 100 for index in range(count)]
    yield ",".join(f"{index}={rate}" for index, rate in enumerate(mixed)), mixed
    # Each serialized slot independently at both extremes catches category-index
    # swaps or missing setters that an all-slots-at-one-rate case can conceal.
    for index in range(count):
        for rate in (0, 1):
            values = list(defaults)
            values[index] = rate
            yield f"{index}={rate}", values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rig", type=Path, default=REPO / ".local/reverse/rigs/head-rig.json")
    parser.add_argument("--contract", type=Path, default=REPO / ".local/reverse/rigs/character-shape-contract.json")
    parser.add_argument("--source", type=Path, default=REPO / ".local/reverse/decompiled/Character/Koikatu/ShapeHeadInfoFemale.cs")
    parser.add_argument("--inspect", type=Path, default=REPO / "Packages/Engine/.build/arm64-apple-macosx/debug/ikkoku-inspect")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/rigs/face-parity-report.json")
    parser.add_argument("--reference-only", action="store_true", help="Inspect source binds without calling the native executable")
    parser.add_argument("--matrix-tolerance", type=float, default=5e-5)
    parser.add_argument("--vertex-tolerance", type=float, default=2e-5)
    args = parser.parse_args()
    rig, contract = json.loads(args.rig.read_text()), json.loads(args.contract.read_text())
    domain = next(domain for domain in contract["domains"] if domain["id"] == "face")
    verified = verify_provenance(rig, contract)
    if file_record(args.source) not in verified:
        raise ValueError("Setter source not covered by verified provenance")
    operations = source_operations(args.source, domain)
    report = {"schemaVersion": 1, "reference": "independent float64 NumPy, parsed recovered C# setters, raw LH geometry",
              "scope": "52 face slots, all 59 destinations, every imported head vertex; standalone boneType0, expression morphs zero; no material, GPU or full-body assembly parity",
              "numpyVersion": np.__version__, "nodeCount": len(rig["nodes"]), "meshCount": len(rig["meshes"]),
              "vertexCount": sum(len(mesh["positions"]) for mesh in rig["meshes"]),
              "matrixTolerance": args.matrix_tolerance, "vertexTolerance": args.vertex_tolerance,
              "verifiedSources": verified, "inputs": [file_record(args.rig), file_record(args.contract)],
              "restBindings": bind_report(rig, reference_world(rig, domain, operations, None)), "cases": []}
    if not args.reference_only:
        report["nativeExecutable"] = file_record(args.inspect)
        for name, rates in cases(domain):
            reference = reference_snapshot(rig, domain, operations, rates)
            command = [str(args.inspect.resolve()), "face-snapshot", str(args.rig.resolve()), str(args.contract.resolve()), name]
            result = subprocess.run(command, check=True, capture_output=True, text=True, cwd=REPO, timeout=30)
            native = json.loads(result.stdout)
            row = compare(reference, native, args.matrix_tolerance, args.vertex_tolerance)
            row.update(case=name)
            report["cases"].append(row)
        if file_record(args.inspect) != report["nativeExecutable"]:
            raise ValueError("Native executable changed during verification")
        report["passed"] = all(case["passed"] for case in report["cases"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"report": str(args.output), "referenceOnly": args.reference_only, "cases": len(report["cases"]),
                      "passed": report.get("passed"),
                      "maxNodeError": max((case["nodeMatrixMaxAbsoluteError"] for case in report["cases"]), default=None),
                      "maxVertexError": max((case["vertexMaxAbsoluteError"] for case in report["cases"]), default=None)}, indent=2))
    if not args.reference_only and not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
