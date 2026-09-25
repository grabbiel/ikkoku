#!/usr/bin/env python3
"""Compare native rig snapshots against independent NumPy source-space math.

Requires NumPy (verified with 2.2.6). All reference work starts from the raw Unity
LH interchange data and recovered height samples. Native code is only called to
obtain the output under test; it is not used to construct the reference.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess

import numpy as np

REPO = Path(__file__).resolve().parents[2]
REFLECTION = np.diag([1.0, 1.0, -1.0, 1.0])


def file_record(path):
    return {"path": str(path), "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def verify_provenance(rig, contract):
    records = [*rig["sources"], *contract["provenance"]]
    for domain in contract["domains"]:
        records.extend(domain.get("provenance", []))
    verified = {}
    for expected in records:
        path = Path(expected["path"])
        if not path.is_absolute():
            path = REPO / path
        path = path.resolve()
        if path in verified:
            if verified[path]["sha256"] != expected["sha256"]:
                raise ValueError(f"Conflicting provenance hashes: {path}")
            continue
        actual = file_record(path)
        if actual["sha256"] != expected["sha256"] or actual["bytes"] != expected["bytes"]:
            raise ValueError(f"Source provenance mismatch: {path}")
        verified[path] = actual
    return list(verified.values())


def height_scale(contract, rate):
    body = next(domain for domain in contract["domains"] if domain["id"] == "body")
    binding = next(target for target in body["directTargets"] if target["sourceName"] == "cf_a_height")
    assert binding["destinationName"] == "cf_n_height"
    assert binding["scaleMask"] == [True, True, True]
    assert binding["positionMask"] == binding["rotationMask"] == [False, False, False]
    samples = next(channel["samples"] for channel in body["channels"] if channel["name"] == "cf_a_height")
    if not 0 <= rate <= 1 or len(samples) < 2:
        raise ValueError("Height rate/sample range is invalid")
    # Recovered AnimationKeyInfo.GetInfo uses sample list order, not sample key
    # timestamps: coordinate = (sampleCount - 1) * rate, then linear scale lerp.
    coordinate = (len(samples) - 1) * rate
    left = min(math.floor(coordinate), len(samples) - 2)
    fraction = coordinate - left
    return (1 - fraction) * np.asarray(samples[left]["scale"], dtype=np.float64) + fraction * np.asarray(samples[left + 1]["scale"], dtype=np.float64)


def local_matrix(node, scale_override=None):
    x, y, z, w = node["rotation"]
    # Standard quaternion rotation, evaluated independently in float64.
    rotation = np.array([
        [1 - 2 * (y*y + z*z), 2 * (x*y - z*w), 2 * (x*z + y*w)],
        [2 * (x*y + z*w), 1 - 2 * (x*x + z*z), 2 * (y*z - x*w)],
        [2 * (x*z - y*w), 2 * (y*z + x*w), 1 - 2 * (x*x + y*y)],
    ], dtype=np.float64)
    matrix = np.eye(4, dtype=np.float64)
    matrix[:3, :3] = rotation @ np.diag(node["scale"] if scale_override is None else scale_override)
    matrix[:3, 3] = node["translation"]
    return matrix


def reference_snapshot(rig, contract, rate):
    if rig["coordinateSpace"] != "unity-left-handed-y-up" or rig["matrixLayout"] != "column-major":
        raise ValueError("Reference requires raw Unity LH coordinates and column-major binds")
    scale = height_scale(contract, rate) if rate is not None else None
    height_nodes = [index for index, node in enumerate(rig["nodes"]) if node["name"] == "cf_n_height"]
    if len(height_nodes) != 1:
        raise ValueError("Expected exactly one cf_n_height destination")
    world = []
    for index, node in enumerate(rig["nodes"]):
        local = local_matrix(node, scale if index == height_nodes[0] else None)
        parent = node["parent"]
        if parent is not None and not 0 <= parent < index:
            raise ValueError("IR nodes must be parent-before-child")
        world.append(local if parent is None else world[parent] @ local)
    world = np.asarray(world)
    native_world = REFLECTION @ world @ REFLECTION
    parts = {}
    for mesh in rig["meshes"]:
        if any(mesh.get("initialMorphWeights", [])):
            raise ValueError("This parity reference requires zero initial morph weights")
        skin = rig["skins"][mesh["skin"]]
        bind = np.asarray([np.asarray(flat).reshape(4, 4, order="F") for flat in skin["inverseBindMatrices"]])
        # The mesh-space transforms cancel in world-space linear blend skinning:
        # meshWorld * inverse(meshWorld) * jointWorld * bind * p.
        # Computing this directly avoids repeating the native palette algorithm.
        source_palette = world[np.asarray(skin["joints"])] @ bind
        positions = np.c_[np.asarray(mesh["positions"], dtype=np.float64), np.ones(len(mesh["positions"]))]
        vertex_palette = source_palette[np.asarray(mesh["joints"], dtype=np.int64)]
        transformed = np.einsum("vlij,vj->vli", vertex_palette, positions)
        deformed = np.einsum("vli,vl->vi", transformed, np.asarray(mesh["weights"], dtype=np.float64))
        native_positions = (deformed @ REFLECTION)[:, :3]
        for submesh_index in range(len(mesh["submeshes"])):
            key = (f"{mesh['name']}/{submesh_index}", mesh["node"], mesh["skin"])
            if key in parts:
                raise ValueError(f"Duplicate part identity: {key}")
            parts[key] = native_positions
    return {"world": native_world, "parts": parts,
            "heightScale": scale.tolist() if scale is not None else None}


def compare(reference, native, matrix_tolerance, vertex_tolerance):
    actual_world = np.asarray([np.asarray(flat).reshape(4, 4, order="F") for flat in native["nodeWorldMatrices"]])
    if actual_world.shape != reference["world"].shape or not np.isfinite(actual_world).all():
        raise ValueError("Native node count/matrix shape/nonfinite mismatch")
    world_delta = np.abs(actual_world - reference["world"])
    max_world = float(world_delta.max(initial=0))
    worst_node = int(np.unravel_index(world_delta.argmax(), world_delta.shape)[0])
    expected_parts = reference["parts"]
    parts = {}
    for part in native["parts"]:
        key = (part["name"], part["node"], part["skin"])
        if key in parts:
            raise ValueError(f"Duplicate native part identity: {key}")
        parts[key] = part
    if parts.keys() != expected_parts.keys():
        raise ValueError(f"Native part set differs: {set(parts) ^ set(expected_parts)}")
    rows = []
    for key, expected in expected_parts.items():
        actual = np.asarray(parts[key]["positions"], dtype=np.float64)
        if actual.shape != expected.shape or not np.isfinite(actual).all():
            raise ValueError(f"Native vertex count/shape/nonfinite mismatch: {key}")
        error = np.abs(actual - expected)
        rows.append({"name": key[0], "node": key[1], "skin": key[2], "vertices": len(expected),
                     "maxAbsoluteError": float(error.max(initial=0)),
                     "rmsError": float(np.sqrt(np.mean(np.square(error)))),
                     "worstVertex": int(np.unravel_index(error.argmax(), error.shape)[0])})
    max_vertex = max(row["maxAbsoluteError"] for row in rows)
    return {"passed": max_world <= matrix_tolerance and max_vertex <= vertex_tolerance,
            "nodeCount": len(actual_world), "vertexCount": sum(row["vertices"] for row in rows),
            "nodeMatrixMaxAbsoluteError": max_world, "worstNode": worst_node,
            "vertexMaxAbsoluteError": max_vertex, "parts": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rig", type=Path, default=REPO / ".local/reverse/rigs/neutral-rig.json")
    parser.add_argument("--contract", type=Path, default=REPO / ".local/reverse/rigs/character-shape-contract.json")
    parser.add_argument("--inspect", type=Path, default=REPO / "Packages/Engine/.build/arm64-apple-macosx/debug/ikkoku-inspect")
    parser.add_argument("--rates", type=float, nargs="+", default=[0, 0.37, 0.5, 1], help="Includes an interior non-keyframe rate by default")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/rigs/parity-report.json")
    parser.add_argument("--matrix-tolerance", type=float, default=5e-5)
    parser.add_argument("--vertex-tolerance", type=float, default=2e-5)
    args = parser.parse_args()
    rig, contract = json.loads(args.rig.read_text()), json.loads(args.contract.read_text())
    report = {"schemaVersion": 1, "reference": "independent float64 NumPy, raw Unity LH then Z reflection",
              "scope": "Authored rest and cf_a_height -> cf_n_height localScale only; no other Maker destinations or GPU comparison",
              "numpyVersion": np.__version__, "matrixTolerance": args.matrix_tolerance,
              "vertexTolerance": args.vertex_tolerance, "verifiedSources": verify_provenance(rig, contract),
              "inputs": [file_record(args.rig), file_record(args.contract)],
              "nativeExecutable": file_record(args.inspect), "cases": []}
    for rate in [None, *args.rates]:
        name = "rest" if rate is None else str(rate)
        reference = reference_snapshot(rig, contract, rate)
        command = [str(args.inspect.resolve()), "rig-snapshot", str(args.rig.resolve()), str(args.contract.resolve()), name]
        result = subprocess.run(command, check=True, capture_output=True, text=True, cwd=REPO, timeout=30)
        native = json.loads(result.stdout)
        row = compare(reference, native, args.matrix_tolerance, args.vertex_tolerance)
        row.update(case=name, heightScale=reference["heightScale"])
        report["cases"].append(row)
    report["passed"] = all(row["passed"] for row in report["cases"])
    if file_record(args.inspect) != report["nativeExecutable"]:
        raise ValueError("Native executable changed while parity snapshots were collected")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"passed": report["passed"], "report": str(args.output),
                      "cases": [{k: row[k] for k in ("case", "passed", "nodeCount", "vertexCount", "nodeMatrixMaxAbsoluteError", "vertexMaxAbsoluteError")} for row in report["cases"]]}, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
