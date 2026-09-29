#!/usr/bin/env python3
"""Compare original Unity local TRS with native card-pose world matrices."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path

import numpy as np


REFLECTION = np.diag([1.0, 1.0, -1.0, 1.0])
ANCHOR = "p_cf_body_bone"


def file_record(path: Path) -> dict:
    return {"path": str(path), "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def local_matrix(record: dict) -> np.ndarray:
    """Unity column-vector local matrix T @ R(q) @ S."""
    x, y, z, w = record["rotation"]
    rotation = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float64)
    matrix = np.eye(4, dtype=np.float64)
    matrix[:3, :3] = rotation @ np.diag(record["scale"])
    matrix[:3, 3] = record["position"]
    return matrix


def compose_original_worlds(bones: list) -> dict:
    """Compose unique paths in depth order, with an identity wrapper root."""
    counts = Counter(record["path"] for record in bones)
    duplicates = [{"path": path, "copies": count}
                  for path, count in sorted(counts.items()) if count > 1]
    records = {record["path"]: record for record in bones if counts[record["path"]] == 1}
    roots = {path.split("/")[0] for path in counts}
    if len(roots) != 1:
        raise ValueError(f"Expected one original wrapper root, found {sorted(roots)}")
    root = roots.pop()
    world = {root: np.eye(4, dtype=np.float64)} if counts[root] <= 1 else {}
    excluded = []
    for path in sorted(counts, key=lambda path: (path.count("/"), path)):
        if path == root:
            if counts[path] > 1:
                excluded.append(path)
            continue
        parent = path.rsplit("/", 1)[0]
        if counts[path] > 1 or parent not in world:
            excluded.append(path)
            continue
        world[path] = world[parent] @ local_matrix(records[path])
    return {"world": world, "root": root, "duplicates": duplicates,
            "excludedPaths": excluded}


def build_native_tree(native: dict) -> dict:
    names = native["nodeNames"]
    parents = native["nodeParents"]
    flats = native["nodeWorldMatrices"]
    if not (len(names) == len(parents) == len(flats)):
        raise ValueError("Native node arrays must agree in length")
    paths = {}
    visiting = set()

    def path_for(index: int) -> str:
        if index in paths:
            return paths[index]
        if index in visiting:
            raise ValueError("Cycle in native node parents")
        visiting.add(index)
        parent = parents[index]
        if parent == -1:
            path = names[index]
        elif 0 <= parent < len(names):
            path = f"{path_for(parent)}/{names[index]}"
        else:
            raise ValueError(f"Native node {index} has invalid parent {parent}")
        visiting.remove(index)
        paths[index] = path
        return path

    for index in range(len(names)):
        path_for(index)
    matrices = [np.asarray(flat, dtype=np.float64).reshape(4, 4).T for flat in flats]
    return {"names": names, "parents": parents, "paths": paths, "matrices": matrices}


def bone_key(path: str) -> str | None:
    parts = path.split("/")
    try:
        return "/".join(parts[parts.index(ANCHOR):])
    except ValueError:
        return None


def match_bones(native: dict, original: dict) -> dict:
    """Pair unique suffixes beginning at p_cf_body_bone."""
    originals = defaultdict(list)
    natives = defaultdict(list)
    for path in original["world"]:
        key = bone_key(path)
        if key is not None:
            originals[key].append(path)
    for index, path in native["paths"].items():
        key = bone_key(path)
        if key is not None:
            natives[key].append(index)

    # A duplicate original record cannot be represented in world, but still
    # makes its suffix ambiguous. Its descendants are listed as excluded.
    for duplicate in original["duplicates"]:
        key = bone_key(duplicate["path"])
        if key is not None:
            originals[key].extend([duplicate["path"]] * duplicate["copies"])

    ambiguous_keys = {key for key in originals.keys() | natives.keys()
                      if len(originals.get(key, [])) > 1 or len(natives.get(key, [])) > 1}
    ambiguous = [
        {"key": key, "originalPaths": sorted(set(originals.get(key, []))),
         "nativePaths": sorted(native["paths"][index] for index in natives.get(key, []))}
        for key in sorted(ambiguous_keys)]
    pairs = {indices[0]: paths[0] for key, paths in originals.items()
             if key not in ambiguous_keys and len(paths) == 1
             if (indices := natives.get(key)) and len(indices) == 1}
    paired_keys = {bone_key(path) for path in pairs.values()}
    unmatched_original_keys = sorted(key for key in originals
                                     if key not in paired_keys and key not in ambiguous_keys)
    unmatched_native_keys = sorted(key for key in natives
                                   if key not in paired_keys and key not in ambiguous_keys)
    return {"pairs": pairs, "unmatchedOriginalKeys": unmatched_original_keys,
            "unmatchedNativeKeys": unmatched_native_keys,
            "ambiguousKeys": ambiguous,
            "excludedOriginalPaths": original["excludedPaths"]}


def transform_errors(reference: np.ndarray, native: np.ndarray) -> dict:
    """Measure translation, column-norm scale, and normalized rotation."""
    if not np.isfinite(reference).all() or not np.isfinite(native).all():
        raise ValueError("Non-finite matrix in pose comparison")
    reference_scale = np.linalg.norm(reference[:3, :3], axis=0)
    native_scale = np.linalg.norm(native[:3, :3], axis=0)
    if np.any(reference_scale == 0) or np.any(native_scale == 0):
        raise ValueError("Zero scale makes rotation undefined")
    reference_rotation = reference[:3, :3] / reference_scale
    native_rotation = native[:3, :3] / native_scale
    cosine = (np.trace(reference_rotation.T @ native_rotation) - 1.0) / 2.0
    return {
        "position": float(np.linalg.norm(reference[:3, 3] - native[:3, 3])),
        "rotationDeg": float(np.degrees(np.arccos(np.clip(cosine, -1.0, 1.0)))),
        "scale": float(np.max(np.abs(reference_scale - native_scale))),
    }


def classification(key: str) -> str:
    parts = [part.lower() for part in key.split("/")]
    if any(part in ("cf_j_hand_l", "cf_j_hand_r") for part in parts):
        return "hand"
    if any(part.startswith("cf_j_") and any(
            finger in part for finger in ("thumb", "index", "middle", "ring", "little"))
           for part in parts):
        return "hand"
    return "other"


def compare_bones(native: dict, original: dict, matching: dict,
                  position_tolerance: float, rotation_tolerance: float,
                  scale_tolerance: float) -> dict:
    tolerances = {"position": position_tolerance, "rotationDeg": rotation_tolerance,
                  "scale": scale_tolerance}
    rows = []
    for index, path in sorted(matching["pairs"].items()):
        key = bone_key(path)
        reference = REFLECTION @ original["world"][path] @ REFLECTION
        errors = transform_errors(reference, native["matrices"][index])
        rows.append({"key": key, "bone": native["names"][index],
                     "originalPath": path, "nativePath": native["paths"][index],
                     **errors})

    summary = {}
    for metric, tolerance in tolerances.items():
        values = np.asarray([row[metric] for row in rows], dtype=np.float64)
        summary[metric] = {
            "p50": float(np.quantile(values, 0.5)) if len(values) else None,
            "p99": float(np.quantile(values, 0.99)) if len(values) else None,
            "max": float(np.max(values)) if len(values) else None,
            "tolerance": tolerance,
            "overTolerance": int(np.count_nonzero(values > tolerance)),
        }
    outliers = []
    for row in rows:
        if any(row[metric] > tolerance for metric, tolerance in tolerances.items()):
            outliers.append({**row, "classification": classification(row["key"])})

    def severity(row: dict) -> float:
        return max(row[metric] / tolerance for metric, tolerance in tolerances.items())

    classes = {}
    for name in ("hand", "other"):
        selected = sorted((row for row in outliers if row["classification"] == name),
                          key=lambda row: (-severity(row), row["key"]))
        classes[name] = {"count": len(selected), "worst": selected[:20]}
    return {"boneCount": len(rows), "summary": summary,
            "outlierCount": len(outliers), "classification": classes,
            "unmatchedNativeKeys": matching["unmatchedNativeKeys"],
            "unmatchedOriginalKeys": matching["unmatchedOriginalKeys"],
            "ambiguousKeys": matching["ambiguousKeys"],
            "excludedOriginalPaths": matching["excludedOriginalPaths"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe_folder", type=Path)
    parser.add_argument("native_snapshot", type=Path)
    parser.add_argument("--avatar", type=Path,
                        help="avatar manifest (default: native snapshot 'source' field)")
    parser.add_argument("--position-tolerance", type=float, default=1e-4)
    parser.add_argument("--rotation-tolerance-deg", type=float, default=1e-2)
    parser.add_argument("--scale-tolerance", type=float, default=1e-4)
    args = parser.parse_args()

    frame_path = args.probe_folder / "frame.json"
    frame = json.loads(frame_path.read_text())
    native = json.loads(args.native_snapshot.read_text())
    if args.avatar is None:
        source = native.get("source")
        if not isinstance(source, str) or not source:
            parser.error("native snapshot missing 'source' field for default --avatar")
        args.avatar = Path(source)
    original = compose_original_worlds(frame["bones"])
    native_tree = build_native_tree(native)
    matching = match_bones(native_tree, original)
    comparison = compare_bones(native_tree, original, matching,
                               args.position_tolerance, args.rotation_tolerance_deg,
                               args.scale_tolerance)
    gate = comparison["outlierCount"] == 0
    report = {
        "schemaVersion": 1,
        "reference": "float64 NumPy local Unity TRS world composition, then C @ W @ C",
        "scope": (
            "Native card-pose world matrices versus the retained original-player "
            "capture of the controlled clothed fixture, matched by bone chain. "
            "Animated states, other coordinate outfits, corrected bone types and "
            "per-variant rigs remain uncovered."
        ),
        "numpyVersion": np.__version__,
        "sourceFrameSHA256": file_record(frame_path)["sha256"],
        "cardSHA256": file_record(args.probe_folder / frame["card"])["sha256"],
        "avatarSHA256": file_record(args.avatar)["sha256"],
        "verifiedSources": [file_record(frame_path), file_record(args.native_snapshot),
                            file_record(args.probe_folder / frame["card"]),
                            file_record(args.avatar)],
        "duplicateBoneRecords": original["duplicates"],
        "pose": {key: value for key, value in native["appliedInputs"].items()},
        "comparison": comparison,
        "gatePassed": gate,
        "gatePassedExcludingHands": comparison["classification"]["other"]["count"] == 0,
        "gatePassedExcludingHandsNote": "Diagnostic only; gatePassed includes hand outliers.",
    }
    print(json.dumps(report, indent=2, allow_nan=False))
    if not gate:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
