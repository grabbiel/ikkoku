"""Synthetic conversion regressions plus an optional original-asset export audit."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import unittest

from export_prefab import convert_ag_normal, convert_tangent, convert_triangles, convert_uv, reflect, studio_material_contract


def subtract(a, b):
    return [x - y for x, y in zip(a, b)]


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


class ConversionTests(unittest.TestCase):
    def test_shader_cutout_uses_texture_alpha_and_ignores_stale_mode(self):
        result = studio_material_contract([0.2, 0.4, 0.6, 0.1], {"_Mode": 0, "_Cutoff": 0.375, "_CutoutClip": 0})
        self.assertEqual(result, {"baseColorFactor": [0.2, 0.4, 0.6, 1], "alphaMode": "MASK", "alphaCutoff": 0.375})

    def test_ag_normal_unpack_preserves_verified_shader_direction(self):
        # Arbitrary R/B must have no effect; source A/G drive X/Y.
        pixel, scale = (13, 64, 237, 192), 0.37
        encoded = convert_ag_normal(pixel, scale)
        self.assertEqual(encoded, convert_ag_normal((99, 64, 0, 192), scale))
        decoded = [v / 255 * 2 - 1 for v in encoded]
        expected = [(192 / 255 * 2 - 1) * scale, -(64 / 255 * 2 - 1) * scale, 1]
        cosine = dot(decoded, expected) / (dot(decoded, decoded) * dot(expected, expected)) ** 0.5
        self.assertGreater(cosine, 0.9999)

    def test_reflection_and_winding_keep_outward_normals(self):
        points = [[0, 0, 0], [1, 0, 1], [0, 1, 1]]
        normal = cross(subtract(points[1], points[0]), subtract(points[2], points[0]))
        converted = list(map(reflect, points))
        a, b, c = convert_triangles([(0, 1, 2)], 3)
        face = cross(subtract(converted[b], converted[a]), subtract(converted[c], converted[a]))
        self.assertGreater(dot(face, reflect(normal)), 0)

    def test_uv_origin_and_tangent_basis_are_converted_together(self):
        # N=(0,0,1), T=(1,0,0), W=1 gives B=(0,1,0).
        # After basis conversion and V reversal B must be (0,-1,0).
        normal = reflect([0, 0, 1])
        tangent = convert_tangent([1, 0, 0, 1])
        bitangent = [x * tangent[3] for x in cross(normal, tangent[:3])]
        self.assertEqual(bitangent, [0, -1, 0])
        self.assertEqual(convert_uv([0.25, 0.125]), [0.25, 0.875])
        self.assertEqual(convert_uv(convert_uv([0.25, 0.125])), [0.25, 0.125])

    def test_invalid_topology_and_indices_fail(self):
        for triangles in [[(0, 1)], [(0, 1, 2, 3)], [(0, -1, 2)], [(0, 1, 3)]]:
            with self.assertRaises(ValueError):
                convert_triangles(triangles, 3)


def verify_export(directory):
    provenance = json.loads((directory / "provenance.json").read_text())
    source = json.loads((directory / "source.unity.json").read_text())
    candidates = list(directory.glob("*.gltf"))
    if len(candidates) != 1:
        raise ValueError("Expected exactly one exported glTF")
    gltf = json.loads(candidates[0].read_text())
    blob = (directory / gltf["buffers"][0]["uri"]).read_bytes()
    if len(blob) != gltf["buffers"][0]["byteLength"]:
        raise ValueError("Buffer length mismatch")
    for record in provenance["sources"]:
        if hashlib.sha256(Path(record["path"]).read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Original bundle hash changed")

    def read(index):
        accessor = gltf["accessors"][index]
        view = gltf["bufferViews"][accessor["bufferView"]]
        components = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[accessor["type"]]
        format = "I" if accessor["componentType"] == 5125 else "f"
        offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        flat = struct.unpack_from("<" + format * accessor["count"] * components, blob, offset)
        return list(flat) if components == 1 else [list(flat[i:i + components]) for i in range(0, len(flat), components)]

    verified_triangles = 0
    for original, mesh in zip(source["meshes"], gltf["meshes"], strict=True):
        for submesh, primitive in enumerate(mesh["primitives"]):
            attrs = primitive["attributes"]
            vertices = read(attrs["POSITION"])
            expected = list(map(reflect, original["positions"]))
            if vertices != expected:
                raise ValueError("Vertex conversion mismatch")
            indices = read(primitive["indices"])
            if indices != convert_triangles(original["submeshTriangles"][submesh], len(vertices)):
                raise ValueError("Index conversion mismatch")
            for semantic, raw, conversion in [("NORMAL", original["normals"], reflect),
                                               ("TANGENT", original["tangents"], convert_tangent),
                                               ("TEXCOORD_0", original["uv0"], convert_uv)]:
                if raw:
                    actual = read(attrs[semantic])
                    for a, b in zip(actual, map(conversion, raw), strict=True):
                        if any(abs(x - y) > 1e-6 for x, y in zip(a, b, strict=True)):
                            raise ValueError(f"{semantic} conversion mismatch")
            normals = read(attrs["NORMAL"])
            for offset in range(0, len(indices), 3):
                a, b, c = indices[offset:offset + 3]
                face = cross(subtract(vertices[b], vertices[a]), subtract(vertices[c], vertices[a]))
                average = [sum(normals[i][axis] for i in (a, b, c)) for axis in range(3)]
                if dot(face, average) < -1e-8:
                    raise ValueError("Converted triangle faces away from authored normals")
                verified_triangles += 1
    for raw, native in zip(source["nodes"], gltf["nodes"], strict=True):
        transform = raw["transform"]
        position = transform["m_LocalPosition"]
        rotation = transform["m_LocalRotation"]
        scale = transform["m_LocalScale"]
        if native["translation"] != [position["x"], position["y"], -position["z"]]:
            raise ValueError("Node position mismatch")
        if native["rotation"] != [-rotation["x"], -rotation["y"], rotation["z"], rotation["w"]]:
            raise ValueError("Node quaternion mismatch")
        if native["scale"] != [scale["x"], scale["y"], scale["z"]]:
            raise ValueError("Node signed scale mismatch")
    return {"verifiedTriangles": verified_triangles, "sourceHashesVerified": len(provenance["sources"]),
            "conversion": "positions, normals, UVs, tangents, winding, local TRS"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--export", type=Path)
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ConversionTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.export:
        print(json.dumps(verify_export(args.export), indent=2))
