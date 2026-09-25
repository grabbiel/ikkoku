#!/usr/bin/env python3
"""Verify the clothed avatar against separated source hierarchies and binds.

Evaluates the source attachment rules recovered from ChaControl, CommonLib and
AssignedAnotherWeights. No native assembly output constructs the reference.
Requires the same local NumPy environment as test_face_rig_parity.py.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import subprocess

import numpy as np

from test_face_rig_parity import reference_world, source_operations
from test_rig_parity import REPO, REFLECTION, file_record, verify_provenance


def by_name(rig):
    result = {node["name"]: index for index, node in enumerate(rig["nodes"])}
    if len(result) != len(rig["nodes"]):
        raise ValueError("Ambiguous source hierarchy names")
    return result


def branch(rig, name):
    index = by_name(rig)[name]
    result = set()
    for i, node in enumerate(rig["nodes"]):
        if i == index or node["parent"] in result:
            result.add(i)
    return result


def source_reference(manifest, directory, domain, operations, rates):
    def read(path):
        return json.loads((directory / path).read_text())

    body_master = read(manifest["bodySkeleton"])
    head_master = read(manifest["headSkeleton"])
    head_geometry = read(manifest["head"]["file"])
    body_names = by_name(body_master)
    # CommonLib.CopySameNameTransform(dst,src): values come from mesh prefab.
    source_locals = {node["name"]: node for node in head_geometry["nodes"]}
    head_master = copy.deepcopy(head_master)
    for node in head_master["nodes"]:
        if node["name"] in source_locals:
            original = source_locals[node["name"]]
            for field in ("translation", "rotation", "scale"):
                node[field] = original[field]
    body_world = reference_world(body_master, domain, operations, None)
    head_world = reference_world(head_master, domain, operations, rates,
                                 root_parent_matrix=body_world[body_names["cf_s_head"]])
    head_names = by_name(head_master)
    body_targets = {body_master["nodes"][index]["name"]: body_world[index] for index in branch(body_master, "cf_j_root")}
    head_targets = {node["name"]: head_world[index] for index, node in enumerate(head_master["nodes"])}
    node_matrices = {"avatar:root": np.eye(4)}

    def remember(rig, world, prefix, removed=set()):
        for index, node in enumerate(rig["nodes"]):
            if index not in removed:
                source_id = f"{prefix}/{node['sourceID']}"
                if source_id in node_matrices:
                    raise ValueError("Duplicate expected source identifier")
                node_matrices[source_id] = REFLECTION @ world[index] @ REFLECTION

    remember(body_master, body_world, "body-master")
    remember(head_master, head_world, "head-master")
    parts = {}
    specifications = [(manifest["body"], "body", np.eye(4), "cf_j_root", body_targets),
                      (manifest["head"], "head", head_world[0], "cf_J_N_FaceRoot", head_targets)]
    specifications.extend((component, f"clothes-{i}", np.eye(4), "cf_j_root", body_targets)
                          for i, component in enumerate(manifest["clothes"]))
    specifications.extend((component, f"hair-{i}", head_world[head_names["cf_J_FaceUp_ty"]], None, None)
                          for i, component in enumerate(manifest["hair"]))
    for component, prefix, parent, removed_name, palette_targets in specifications:
        rig = read(component["file"])
        world = reference_world(rig, domain, operations, None, root_parent_matrix=parent)
        removed = branch(rig, removed_name) if removed_name else set()
        remember(rig, world, prefix, removed)
        selected = component.get("meshNames")
        for mesh in rig["meshes"]:
            if selected is not None and mesh["name"] not in selected:
                continue
            if mesh.get("hasCloth", False) or any(mesh["initialMorphWeights"]):
                raise ValueError("Cloth or expression morph deformation is outside this reference")
            skin = rig["skins"][mesh["skin"]]
            if palette_targets is None:
                joint_world = world[np.asarray(skin["joints"])]
            else:
                joint_world = np.asarray([palette_targets[rig["nodes"][index]["name"]] for index in skin["joints"]])
            bind = np.asarray([np.asarray(matrix).reshape(4, 4, order="F") for matrix in skin["inverseBindMatrices"]])
            # Source SMR bone reassignment leaves mesh inverse bind matrices and
            # four-lane vertex indices unchanged. Renderer transforms cancel.
            palette = joint_world @ bind
            positions = np.c_[np.asarray(mesh["positions"]), np.ones(len(mesh["positions"]))]
            transformed = np.einsum("vlij,vj->vli", palette[np.asarray(mesh["joints"])], positions)
            native_positions = (np.einsum("vli,vl->vi", transformed, np.asarray(mesh["weights"])) @ REFLECTION)[:, :3]
            for submesh in range(len(mesh["submeshes"])):
                name = f"{mesh['name']}/{submesh}"
                if name in parts:
                    raise ValueError(f"Ambiguous source mesh name {name}")
                parts[name] = native_positions
    return node_matrices, parts


def compare_avatar(expected_nodes, expected_parts, native, tolerance):
    identifiers = native["nodeSourceIDs"]
    actual_nodes = {key: np.asarray(matrix).reshape(4, 4, order="F") for key, matrix in zip(identifiers, native["nodeWorldMatrices"])}
    if len(identifiers) != len(actual_nodes) or actual_nodes.keys() != expected_nodes.keys():
        raise ValueError("Native retained source node set differs from source assembly")
    node_errors = {key: float(np.max(np.abs(actual_nodes[key] - expected))) for key, expected in expected_nodes.items()}
    actual_parts = {part["name"]: np.asarray(part["positions"]) for part in native["parts"]}
    if len(actual_parts) != len(native["parts"]) or actual_parts.keys() != expected_parts.keys():
        raise ValueError("Native selected mesh set differs from manifest")
    rows = []
    for name, expected in expected_parts.items():
        actual = actual_parts[name]
        if actual.shape != expected.shape or not np.isfinite(actual).all():
            raise ValueError(f"Invalid native vertex array: {name}")
        error = np.abs(actual - expected)
        rows.append({"name": name, "vertices": len(expected), "maxAbsoluteError": float(error.max()),
                     "rmsError": float(np.sqrt(np.mean(error**2)))})
    maximum_node, maximum_vertex = max(node_errors.values()), max(row["maxAbsoluteError"] for row in rows)
    return {"passed": np.isfinite(list(node_errors.values())).all().item() and maximum_node < tolerance and maximum_vertex < tolerance,
            "nodeCount": len(actual_nodes), "partCount": len(actual_parts), "vertexCount": sum(row["vertices"] for row in rows),
            "nodeMatrixMaxAbsoluteError": maximum_node, "worstNode": max(node_errors, key=node_errors.get),
            "vertexMaxAbsoluteError": maximum_vertex, "parts": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--avatar", type=Path, default=REPO / ".local/reverse/rigs/source-avatar.json")
    parser.add_argument("--contract", type=Path, default=REPO / ".local/reverse/rigs/character-shape-contract.json")
    parser.add_argument("--source", type=Path, default=REPO / ".local/reverse/decompiled/Character/Koikatu/ShapeHeadInfoFemale.cs")
    parser.add_argument("--inspect", type=Path, default=REPO / "Packages/Engine/.build/debug/ikkoku-inspect")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/rigs/avatar-parity-report.json")
    parser.add_argument("--tolerance", type=float, default=2e-5)
    args = parser.parse_args()
    manifest, contract = json.loads(args.avatar.read_text()), json.loads(args.contract.read_text())
    domain = next(domain for domain in contract["domains"] if domain["id"] == "face")
    operations = source_operations(args.source, domain)
    files = [manifest["bodySkeleton"], manifest["headSkeleton"], manifest["body"]["file"], manifest["head"]["file"],
             *[part["file"] for part in manifest["clothes"]], *[part["file"] for part in manifest["hair"]]]
    verified = []
    for filename in files:
        verified.extend(verify_provenance(json.loads((args.avatar.parent / filename).read_text()), contract))
    report = {"schemaVersion": 1, "reference": "independent float64 original separate hierarchies, source parenting/name rebinding, original inverse binds",
              "scope": "Selected clothed source assembly authored body pose, independent face poses; no appearance, GPU or body-slider parity",
              "verifiedSources": list({record["path"]: record for record in verified}.values()),
              "inputs": [file_record(args.avatar), file_record(args.contract), *[file_record(args.avatar.parent / name) for name in files]],
              "nativeExecutable": file_record(args.inspect), "tolerance": args.tolerance, "cases": []}
    report["assemblyEvidence"] = [file_record(args.source.parent / name) for name in
                                  ("ChaControl.cs", "CommonLib.cs", "AssignedAnotherWeights.cs", "ChaReference.cs", "ChaFileStatus.cs")]
    mixed = [((index * 17 + 3) % 101) / 100 for index in range(domain["valueCount"])]
    tests = [("rest", None), ("defaults", domain["defaultValues"]), ("all=0", [0] * domain["valueCount"]),
             ("all=0.37", [0.37] * domain["valueCount"]), ("all=1", [1] * domain["valueCount"]),
             (",".join(f"{index}={rate}" for index, rate in enumerate(mixed)), mixed)]
    for name, rates in tests:
        nodes, parts = source_reference(manifest, args.avatar.parent, domain, operations, rates)
        command = [str(args.inspect.resolve()), "face-snapshot", str(args.avatar.resolve()), str(args.contract.resolve()), name]
        result = subprocess.run(command, cwd=REPO, check=True, capture_output=True, text=True, timeout=60)
        row = compare_avatar(nodes, parts, json.loads(result.stdout), args.tolerance)
        row["case"] = name
        report["cases"].append(row)
    if file_record(args.inspect) != report["nativeExecutable"]:
        raise ValueError("Native executable changed during verification")
    report["passed"] = all(row["passed"] for row in report["cases"])
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"passed": report["passed"], "cases": len(report["cases"]), "report": str(args.output),
                      "nodeMatrixMaxAbsoluteError": max(row["nodeMatrixMaxAbsoluteError"] for row in report["cases"]),
                      "vertexMaxAbsoluteError": max(row["vertexMaxAbsoluteError"] for row in report["cases"])}, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
