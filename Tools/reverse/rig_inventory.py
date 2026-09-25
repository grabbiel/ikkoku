#!/usr/bin/env python3
"""Inventory Unity rigs and export one explicitly selected prefab to neutral JSON.

Outputs are local technical data. This tool never decodes textures, renders an
image, runs game code, or guesses missing bone references.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path


def identity(reader):
    return f"{reader.assets_file.name}:{reader.path_id}"


def reference(pointer):
    if not pointer.path_id:
        return None
    try:
        reader = pointer.deref()
        return {"id": identity(reader), "type": reader.type.name, "name": reader.peek_name()}
    except Exception as error:
        return {"fileID": pointer.file_id, "pathID": str(pointer.path_id), "unresolved": str(error)}


def xyz(v):
    return [v.x, v.y, v.z]


def matrix_columns(matrix):
    return [getattr(matrix, f"e{row}{column}") for column in range(4) for row in range(4)]


def bounds(points):
    return {"min": [min(v[i] for v in points) for i in range(3)],
            "max": [max(v[i] for v in points) for i in range(3)]} if points else None


def weight_summary(indices, weights, bind_count):
    sums = [sum(row) for row in weights]
    used = [index for row_i, row_w in zip(indices, weights) for index, weight in zip(row_i, row_w) if weight > 0]
    return {"vertexCount": len(weights), "indexVertexCount": len(indices),
            "influenceCounts": dict(Counter(sum(w > 0 for w in row) for row in weights)),
            "sumMin": min(sums, default=0), "sumMax": max(sums, default=0),
            "nonUnitSums": sum(abs(s - 1) > 0.001 for s in sums),
            "nonfiniteWeights": sum(not math.isfinite(w) for row in weights for w in row),
            "negativeWeights": sum(w < 0 for row in weights for w in row),
            "usedJointMin": min(used, default=None), "usedJointMax": max(used, default=None),
            "invalidActiveBindIndices": sum(i < 0 or i >= bind_count for i in used)}


def skin_joint_palette(joints, bind_count, vertex_indices, allow_unused_trailing_bones=False):
    """Keep the mesh bind palette, accepting surplus references only by opt-in.

    Unity renderers can serialize extra bone references that are never indexed
    by this mesh. Every lane is checked, including lanes with zero weight, since
    a GPU may still fetch that lane before multiplication. Nothing is padded.
    """
    if len(joints) == bind_count:
        return joints, None
    if not allow_unused_trailing_bones or bind_count <= 0 or len(joints) < bind_count:
        raise ValueError(f"Bone/bind pose count mismatch: {len(joints)} vs {bind_count}")
    indices = [index for row in vertex_indices for index in row]
    if any(not isinstance(index, int) or index < 0 or index >= bind_count for index in indices):
        raise ValueError("Surplus bone references are indexed by the mesh; cannot omit them")
    return joints[:bind_count], {"decision": "omit-explicitly-verified-unindexed-trailing-references",
                               "originalCount": len(joints), "retainedCount": bind_count,
                               "allLanesMax": max(indices, default=None), "sourceRendererJointNodes": joints}


def uv_channel(values, vertex_count, label):
    values = values or []
    if values and len(values) != vertex_count:
        raise ValueError(f"{label} vertex count differs from mesh")
    for value in values:
        if len(value) != 2 or any(not isinstance(v, (float, int)) or isinstance(v, bool) or not math.isfinite(v) for v in value):
            raise ValueError(f"{label} must contain finite two-component coordinates")
    return values


def morph_channels(shapes, vertex_count):
    """Retain original channel metadata with validated sparse source frames.

    Frame weights remain Unity percentages. This exports data only; interpolation
    between multiple frames is not implemented or inferred by the extractor.
    """
    channels = shapes.get("channels", [])
    raw_frames = shapes.get("shapes", [])
    frame_weights = shapes.get("fullWeights", [])
    deltas = shapes.get("vertices", [])
    if len(frame_weights) != len(raw_frames):
        raise ValueError("Morph frame and frame-weight counts differ")

    def integer(value, label):
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"Invalid morph {label}")
        return value

    def vector(delta, field):
        raw = delta.get(field)
        if not isinstance(raw, dict) or any(axis not in raw for axis in "xyz"):
            raise ValueError(f"Missing morph {field} delta")
        result = [raw[axis] for axis in "xyz"]
        if any(not isinstance(value, (float, int)) or isinstance(value, bool) or not math.isfinite(value) for value in result):
            raise ValueError(f"Nonfinite morph {field} delta")
        return result

    frames = []
    for index, frame in enumerate(raw_frames):
        first = integer(frame.get("firstVertex"), "first delta")
        count = integer(frame.get("vertexCount"), "delta count")
        if first > len(deltas) or count > len(deltas) - first:
            raise ValueError("Morph frame delta range exceeds source array")
        weight = frame_weights[index]
        if not isinstance(weight, (float, int)) or isinstance(weight, bool) or not math.isfinite(weight):
            raise ValueError("Nonfinite morph frame weight")
        selected = deltas[first:first + count]
        indices = [integer(delta.get("index"), "vertex index") for delta in selected]
        if any(i >= vertex_count for i in indices) or len(set(indices)) != len(indices):
            raise ValueError("Morph frame has out-of-range or duplicate sparse indices")
        frames.append({"weight": weight, "indices": indices,
                       "positionDeltas": [vector(delta, "vertex") for delta in selected],
                       "normalDeltas": [vector(delta, "normal") for delta in selected] if frame.get("hasNormals", False) else [],
                       "tangentDeltas": [vector(delta, "tangent") for delta in selected] if frame.get("hasTangents", False) else []})
    result, names, claimed = [], set(), set()
    for channel in channels:
        name = channel.get("name")
        if not isinstance(name, str) or not name or name in names:
            raise ValueError("Morph channels require unique nonempty names")
        names.add(name)
        first = integer(channel.get("frameIndex"), "first frame")
        count = integer(channel.get("frameCount"), "frame count")
        if count == 0 or first > len(frames) or count > len(frames) - first:
            raise ValueError("Morph channel frame range exceeds source array")
        selected_indices = set(range(first, first + count))
        if claimed.intersection(selected_indices):
            raise ValueError("Morph channels overlap the same source frame")
        claimed.update(selected_indices)
        result.append({**channel, "frames": frames[first:first + count]})
    if len(claimed) != len(frames):
        raise ValueError("Source morph frames are not assigned to a channel")
    return result, frames


class Inspector:
    def __init__(self, environment):
        self.environment = environment
        self.mesh_cache = {}

    def mesh(self, reader):
        from UnityPy.helpers.MeshHelper import MeshHandler
        key = identity(reader)
        if key in self.mesh_cache:
            return self.mesh_cache[key]
        mesh = reader.read()
        handler = MeshHandler(mesh)
        handler.process()
        data = reader.read_typetree()
        shapes = data.get("m_Shapes", {})
        bind_poses = [matrix_columns(m) for m in mesh.m_BindPose or []]
        vertices = handler.m_Vertices or []
        summary = {"id": key, "name": mesh.m_Name, "vertexCount": handler.m_VertexCount,
                   "boundsMeshLocalUnity": bounds(vertices), "bindPoseCount": len(bind_poses),
                   "inverseBindMatricesColumnMajor": bind_poses,
                   "boneNameHashes": list(mesh.m_BoneNameHashes or []),
                   "rootBoneNameHash": mesh.m_RootBoneNameHash,
                   "submeshTriangleCounts": [len(v) for v in handler.get_triangles()],
                   "hasNormals": bool(handler.m_Normals), "hasTangents": bool(handler.m_Tangents),
                   "uvChannelVertexCounts": [len(values or []) for values in (handler.m_UV0, handler.m_UV1, handler.m_UV2)],
                   "weightValidation": weight_summary(handler.m_BoneIndices or [], handler.m_BoneWeights or [], len(bind_poses)),
                   "morphChannels": shapes.get("channels", []),
                   "morphFrames": shapes.get("shapes", []), "morphFrameWeights": shapes.get("fullWeights", []),
                   "morphDeltaCount": len(shapes.get("vertices", []))}
        self.mesh_cache[key] = (summary, handler, shapes)
        return self.mesh_cache[key]

    def prefab_nodes(self, game_object):
        nodes, renderers = [], []
        seen = set()

        def visit(go, parent):
            transform = next(p.component.read() for p in go.m_Component if p.component.type.name == "Transform")
            key = identity(transform.object_reader)
            if key in seen:
                raise ValueError(f"Cycle or duplicate transform in prefab: {key}")
            seen.add(key)
            index = len(nodes)
            node = {"name": go.m_Name, "parent": parent, "sourceID": key,
                    "translation": xyz(transform.m_LocalPosition),
                    "rotation": [*xyz(transform.m_LocalRotation), transform.m_LocalRotation.w],
                    "scale": xyz(transform.m_LocalScale), "active": go.m_IsActive}
            nodes.append(node)
            for component in go.m_Component:
                if component.component.type.name == "SkinnedMeshRenderer":
                    renderers.append((index, component.component.read()))
            for child in transform.m_Children:
                visit(child.read().m_GameObject.read(), index)

        visit(game_object, None)
        return nodes, renderers

    def neutral(self, prefab_path, skeleton_only=False, allow_unused_trailing_bones=False):
        game_object = self.environment.container[prefab_path].read()
        nodes, renderers = self.prefab_nodes(game_object)
        node_indices = {n["sourceID"]: i for i, n in enumerate(nodes)}
        result = {"schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up",
                  "lengthUnit": "unity-source-unit", "uvConvention": "unity-source",
                  "matrixLayout": "column-major", "sourcePrefab": prefab_path,
                  "nodes": nodes, "skins": [], "meshes": []}
        if skeleton_only:
            return result
        for node_index, renderer in renderers:
            mesh_reader = renderer.m_Mesh.deref()
            summary, handler, shapes = self.mesh(mesh_reader)
            joints = []
            for bone in renderer.m_Bones:
                ref = reference(bone)
                if not ref or ref.get("id") not in node_indices:
                    raise ValueError(f"Unresolved or external joint in {summary['name']}: {ref}")
                joints.append(node_indices[ref["id"]])
            try:
                joints, palette_audit = skin_joint_palette(joints, summary["bindPoseCount"], handler.m_BoneIndices or [], allow_unused_trailing_bones)
            except ValueError as error:
                raise ValueError(f"{summary['name']}: {error}") from error
            validation = summary["weightValidation"]
            if any(validation[k] for k in ("nonUnitSums", "nonfiniteWeights", "negativeWeights", "invalidActiveBindIndices")):
                raise ValueError(f"Invalid skin weights: {summary['name']}: {validation}")
            if validation["vertexCount"] != handler.m_VertexCount or validation["indexVertexCount"] != handler.m_VertexCount:
                raise ValueError(f"Missing skin weights: {summary['name']}")
            if any(len(row) != 4 for row in [*handler.m_BoneIndices, *handler.m_BoneWeights]):
                raise ValueError(f"Expected four influence slots: {summary['name']}")
            triangles = list(handler.get_triangles())
            if any(len(face) != 3 or any(index < 0 or index >= handler.m_VertexCount for index in face)
                   for faces in triangles for face in faces):
                raise ValueError(f"Invalid triangle indices: {summary['name']}")
            root = reference(renderer.m_RootBone)
            skin_index = len(result["skins"])
            result["skins"].append({"name": summary["name"], "meshNode": node_index,
                                    "joints": joints, "rootJoint": node_indices.get(root.get("id")) if root else None,
                                    "inverseBindMatrices": summary["inverseBindMatricesColumnMajor"]})
            if palette_audit:
                result["skins"][-1]["sourcePaletteAudit"] = palette_audit
            channels, frames = morph_channels(shapes, handler.m_VertexCount)
            # Retain the earlier global frame table for local inspection tools;
            # native consumers use each channel's explicit frames array.
            legacy_frames = [{"weight": frame["weight"], "indices": frame["indices"],
                              "positions": frame["positionDeltas"], "normals": frame["normalDeltas"],
                              "tangents": frame["tangentDeltas"]} for frame in frames]
            result["meshes"].append({"name": summary["name"], "node": node_index, "skin": skin_index,
                                     "rendererEnabled": renderer.m_Enabled,
                                     "hasCloth": any(component.component.type.name == "Cloth" for component in renderer.m_GameObject.read().m_Component),
                                     "positions": handler.m_Vertices, "normals": [v[:3] for v in handler.m_Normals or []],
                                     "tangents": handler.m_Tangents or [],
                                     "uv0": uv_channel(handler.m_UV0, handler.m_VertexCount, "UV0"),
                                     "uv1": uv_channel(handler.m_UV1, handler.m_VertexCount, "UV1"),
                                     "uv2": uv_channel(handler.m_UV2, handler.m_VertexCount, "UV2"),
                                     "joints": handler.m_BoneIndices, "weights": handler.m_BoneWeights,
                                     "submeshes": [{"indices": [i for triangle in faces for i in triangle]} for faces in triangles],
                                     "morphChannels": channels, "morphFrames": legacy_frames,
                                     "initialMorphWeights": list(renderer.m_BlendShapeWeights or [])})
        return result

    def manifest(self):
        result = {"schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up",
                  "matrixLayout": "column-major", "objectCounts": {}, "serializedFiles": [],
                  "prefabs": [], "meshes": [], "textAssets": [], "warnings": []}
        objects = list(self.environment.objects)
        result["objectCounts"] = dict(Counter(o.type.name for o in objects))
        files = {o.assets_file.name: o.assets_file for o in objects}
        for name, file in sorted(files.items()):
            result["serializedFiles"].append({"name": name, "unityVersion": file.unity_version,
                "dependencies": [{"path": x.path, "guid": bytes(x.guid).hex(), "type": x.type} for x in file.externals]})
        for path, reader in self.environment.container.items():
            if reader.type.name != "GameObject":
                continue
            nodes, renderers = self.prefab_nodes(reader.read())
            row = {"path": path, "nodes": nodes, "renderers": []}
            for node_index, renderer in renderers:
                try:
                    summary, _, _ = self.mesh(renderer.m_Mesh.deref())
                    bones = [reference(bone) for bone in renderer.m_Bones]
                    row["renderers"].append({"node": node_index, "mesh": reference(renderer.m_Mesh),
                                              "bones": bones, "rootBone": reference(renderer.m_RootBone),
                                              "hasCloth": any(component.component.type.name == "Cloth" for component in renderer.m_GameObject.read().m_Component),
                                              "materials": [reference(m) for m in renderer.m_Materials],
                                              "initialMorphWeights": list(renderer.m_BlendShapeWeights or []),
                                              "boneBindCountsMatch": len(bones) == summary["bindPoseCount"]})
                    if len(bones) != summary["bindPoseCount"]:
                        result["warnings"].append(f"{path}: {summary['name']}: {len(bones)} bone references, {summary['bindPoseCount']} bind poses")
                except Exception as error:
                    row["renderers"].append({"node": node_index, "error": str(error)})
            result["prefabs"].append(row)
        result["meshes"] = [value[0] for value in self.mesh_cache.values()]
        for obj in objects:
            if obj.type.name == "TextAsset":
                data = obj.read()
                raw = data.m_Script.encode("utf-8", "surrogateescape")
                result["textAssets"].append({"name": data.m_Name, "id": identity(obj), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
        return result


def main():
    import UnityPy
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundles", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="Rig metadata JSON")
    parser.add_argument("--prefab", help="Exact prefab container key to export to neutral JSON")
    parser.add_argument("--neutral-output", type=Path)
    parser.add_argument("--skeleton-only", action="store_true")
    parser.add_argument("--allow-unused-trailing-bones", action="store_true",
                        help="Explicitly allow renderer references beyond bind count only if every mesh joint lane is within bind count; records the complete source palette in an audit field")
    parser.add_argument("--extract-shape-textassets", type=Path, help="Directory for customization binary inputs, never textures")
    args = parser.parse_args()
    if bool(args.prefab) != bool(args.neutral_output):
        parser.error("--prefab and --neutral-output must be supplied together")
    env = UnityPy.load(*[str(p) for p in args.bundles])
    inspector = Inspector(env)
    manifest = inspector.manifest()
    provenance = [{"path": str(p), "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in args.bundles]
    manifest["sources"] = provenance
    manifest["extractor"] = {"name": "UnityPy", "version": UnityPy.__version__}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    if args.prefab:
        neutral = inspector.neutral(args.prefab, args.skeleton_only, args.allow_unused_trailing_bones)
        neutral["sources"] = provenance
        args.neutral_output.parent.mkdir(parents=True, exist_ok=True)
        args.neutral_output.write_text(json.dumps(neutral, separators=(",", ":"), allow_nan=False) + "\n")
    if args.extract_shape_textassets:
        args.extract_shape_textassets.mkdir(parents=True, exist_ok=True)
        for obj in env.objects:
            if obj.type.name != "TextAsset":
                continue
            data = obj.read()
            if not ("anmshape" in data.m_Name.lower() or data.m_Name.lower() in ("cf_custombody", "cf_customhead", "shapecorrect")):
                continue
            if Path(data.m_Name).name != data.m_Name:
                raise ValueError("Unsafe TextAsset filename")
            raw = data.m_Script.encode("utf-8", "surrogateescape")
            (args.extract_shape_textassets / (data.m_Name + ".bytes")).write_bytes(raw)
    print(json.dumps({"manifest": str(args.output), "prefabCount": len(manifest["prefabs"]),
                      "meshCount": len(manifest["meshes"]), "warnings": manifest["warnings"],
                      "neutralOutput": str(args.neutral_output) if args.neutral_output else None}, indent=2))


if __name__ == "__main__":
    main()
