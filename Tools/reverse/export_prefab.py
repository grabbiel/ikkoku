#!/usr/bin/env python3
"""Export one explicit static Unity prefab as glTF, with source provenance.

This is a bounded geometry/material importer, not a complete Unity shader translator.
Proprietary output belongs in .local/reverse/exports, never in Assets/.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct


def xyz(value):
    return [value.x, value.y, value.z]


def reflect(value):
    return [value[0], value[1], -value[2]]


def convert_tangent(value):
    # Z reflection and the independent V reflection each negate tangent W.
    return [value[0], value[1], -value[2], value[3]]


def convert_uv(value):
    # UnityPy's default PNG export is top-down; glTF/Metal UV origin is top-left.
    return [value[0], 1.0 - value[1]]


def convert_ag_normal(pixel, scale):
    """Observed StandardMDK forward PS: normalize(N + T*A_signed*s + B*G_signed*s).

    V reversal changes B's sign, so the corresponding normal-map Y also reverses.
    Normalize before RGB8 encoding to preserve direction without clipping XY.
    """
    x, y, z = (pixel[3] / 255 * 2 - 1) * scale, -(pixel[1] / 255 * 2 - 1) * scale, 1.0
    length = math.sqrt(x * x + y * y + z * z)
    return tuple(round((component / length * 0.5 + 0.5) * 255) for component in (x, y, z))


def studio_material_contract(color, floats):
    # Verified in FORWARD DXBC: clip(_MainTex.a - _Cutoff), multiply _Color.rgb,
    # output alpha=1. _Mode and _Color.a do not control this shader's coverage.
    return {"baseColorFactor": list(color[:3]) + [1], "alphaMode": "MASK", "alphaCutoff": floats.get("_Cutoff", 0.5)}


def convert_triangles(triangles, count):
    result = []
    for triangle in triangles:
        if len(triangle) != 3 or any(i < 0 or i >= count for i in triangle):
            raise ValueError("Invalid triangle indices")
        result.extend([triangle[0], triangle[2], triangle[1]])
    return result


def safe_name(value):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip(".") or "asset"


def key(pointer):
    reader = pointer.deref()
    return (reader.assets_file.name, reader.path_id)


class Exporter:
    def __init__(self, environment, output, stem):
        self.environment = environment
        self.output = output
        self.stem = safe_name(stem)
        self.blob = bytearray()
        self.gltf = {"asset": {"version": "2.0", "generator": "Ikkoku explicit Unity static-prefab exporter"},
                     "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [], "meshes": [],
                     "materials": [], "textures": [], "images": [], "accessors": [], "bufferViews": []}
        self.source = {"nodes": [], "meshes": [], "materials": [], "textures": [],
                       "unsupportedComponents": [], "limitations": [
                           "Static triangles, base color, verified cutout and A/G normal packing are mapped.",
                           "Parallax, metallic/gloss, lighting, collision and behavior are not translated.",
                           "Shader source has not been recovered; native shading is approximate."]}
        self.material_cache = {}
        self.texture_cache = {}
        self.visited = set()

    def accessor(self, values, shape, integer=False, bounds=False):
        components = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[shape]
        flattened = list(values) if components == 1 else [x for value in values for x in value]
        if len(flattened) != len(values) * components or not all(math.isfinite(x) for x in flattened):
            raise ValueError("Malformed or nonfinite vertex data")
        while len(self.blob) % 4:
            self.blob.append(0)
        offset = len(self.blob)
        self.blob.extend(struct.pack("<" + ("I" if integer else "f") * len(flattened), *flattened))
        view = len(self.gltf["bufferViews"])
        self.gltf["bufferViews"].append({"buffer": 0, "byteOffset": offset, "byteLength": len(self.blob) - offset})
        result = {"bufferView": view, "componentType": 5125 if integer else 5126, "count": len(values), "type": shape}
        if bounds and values:
            result["min"] = [min(v[i] for v in values) for i in range(components)]
            result["max"] = [max(v[i] for v in values) for i in range(components)]
        index = len(self.gltf["accessors"])
        self.gltf["accessors"].append(result)
        return index

    def texture(self, pointer, normal_scale=None):
        identity = (*key(pointer), normal_scale)
        if identity in self.texture_cache:
            return self.texture_cache[identity]
        texture = pointer.read()
        if pointer.type.name != "Texture2D":
            raise ValueError(f"Unsupported texture kind: {pointer.type.name}")
        role = "normal_" if normal_scale is not None else ""
        name = f"{len(self.texture_cache)}_{role}{safe_name(texture.m_Name)}.png"
        image = texture.image
        if normal_scale is not None:
            from PIL import Image
            source_pixels = image.convert("RGBA")
            image = Image.new("RGB", source_pixels.size)
            pixels = source_pixels.get_flattened_data() if hasattr(source_pixels, "get_flattened_data") else source_pixels.getdata()
            image.putdata([convert_ag_normal(pixel, normal_scale) for pixel in pixels])
        image.save(self.output / name)
        index = len(self.gltf["textures"])
        self.gltf["images"].append({"uri": name, "name": texture.m_Name})
        self.gltf["textures"].append({"source": index})
        self.texture_cache[identity] = index
        self.source["textures"].append({"sourceFile": identity[0], "pathID": str(identity[1]),
                                        "name": texture.m_Name, "output": name, "format": int(texture.m_TextureFormat),
                                        "conversion": "A/G to normalized RGB, Y inverted for flipped V" if normal_scale is not None else "base-color",
                                        "normalScaleBaked": normal_scale,
                                        "width": texture.m_Width, "height": texture.m_Height})
        return index

    def material(self, pointer):
        identity = key(pointer)
        if identity in self.material_cache:
            return self.material_cache[identity]
        material = pointer.read()
        properties = material.m_SavedProperties
        colors, floats, textures = dict(properties.m_Colors), dict(properties.m_Floats), dict(properties.m_TexEnvs)
        shader = material.m_Shader.read()
        shader_name = shader.m_Name or getattr(getattr(shader, "m_ParsedForm", None), "m_Name", "")
        color = colors.get("_Color")
        contract = studio_material_contract([color.r, color.g, color.b, color.a] if color else [1, 1, 1, 1], floats)
        result = {"name": material.m_Name, "pbrMetallicRoughness": {"baseColorFactor": contract["baseColorFactor"], "metallicFactor": 0, "roughnessFactor": 1},
                  "alphaMode": contract["alphaMode"], "alphaCutoff": contract["alphaCutoff"],
                  "doubleSided": False,  # Serialized FORWARD pass: Cull Back (2), no property binding.
                  "extras": {"unityShader": shader_name, "unityPathID": str(identity[1]), "shaderParity": "base-color-cutout-normal-packing-only"}}
        # Unknown shader families need an explicit mapping, not guessed transparency.
        if shader_name != "Shader Forge/main_StandardMDK_studio":
            raise ValueError(f"No verified base-color mapping for shader {shader_name!r}")
        main = textures.get("_MainTex")
        if main and main.m_Texture.path_id:
            if xyz2(main.m_Scale) != [1, 1] or xyz2(main.m_Offset) != [0, 0]:
                raise ValueError("Nonidentity base-texture scale/offset requires a UV transform mapping")
            result["pbrMetallicRoughness"]["baseColorTexture"] = {"index": self.texture(main.m_Texture)}
        normal = textures.get("_BumpMap")
        if normal and normal.m_Texture.path_id:
            if xyz2(normal.m_Scale) != [1, 1] or xyz2(normal.m_Offset) != [0, 0]:
                raise ValueError("Nonidentity normal-texture scale/offset requires a UV transform mapping")
            result["normalTexture"] = {"index": self.texture(normal.m_Texture, normal_scale=floats.get("_BumpScale", 1))}
        index = len(self.gltf["materials"])
        self.material_cache[identity] = index
        self.gltf["materials"].append(result)
        self.source["materials"].append({"sourceFile": identity[0], "pathID": str(identity[1]),
                                         "shaderName": shader_name, "serialized": pointer.read_typetree()})
        return index

    def mesh(self, pointer, renderer):
        from UnityPy.helpers.MeshHelper import MeshHandler
        mesh = pointer.read()
        if mesh.m_BindPose or (mesh.m_Shapes and mesh.m_Shapes.channels):
            raise ValueError("Skinned/morph meshes require a separate rig conversion")
        if any(int(sub.topology) != 0 for sub in mesh.m_SubMeshes):
            raise ValueError("Only triangle-list submeshes are supported")
        handler = MeshHandler(mesh)
        handler.process()
        positions = [reflect(v) for v in handler.m_Vertices]
        if not positions:
            raise ValueError("Empty source mesh")
        attributes = {"POSITION": self.accessor(positions, "VEC3", bounds=True)}
        for semantic, values, shape, conversion in [
            ("NORMAL", handler.m_Normals, "VEC3", reflect),
            ("TANGENT", handler.m_Tangents, "VEC4", convert_tangent),
            ("TEXCOORD_0", handler.m_UV0, "VEC2", convert_uv),
            ("COLOR_0", handler.m_Colors, "VEC4", list),
        ]:
            if values:
                if len(values) != len(positions):
                    raise ValueError(f"Mismatched {semantic} count")
                attributes[semantic] = self.accessor([conversion(v) for v in values], shape)
        triangles = handler.get_triangles()
        if len(renderer.m_Materials) != len(triangles):
            raise ValueError("Renderer material/submesh count differs; repeated Unity passes are unsupported")
        primitives = []
        for i, triangle_list in enumerate(triangles):
            indices = convert_triangles(triangle_list, len(positions))
            material_index = self.material(renderer.m_Materials[i])
            if "normalTexture" in self.gltf["materials"][material_index] and not {"TANGENT", "TEXCOORD_0", "NORMAL"}.issubset(attributes):
                raise ValueError("Normal-mapped meshes require authored normals, tangents and UV0")
            primitives.append({"attributes": attributes, "indices": self.accessor(indices, "SCALAR", integer=True),
                               "material": material_index, "mode": 4})
        index = len(self.gltf["meshes"])
        self.gltf["meshes"].append({"name": mesh.m_Name, "primitives": primitives})
        self.source["meshes"].append({"pathID": str(pointer.path_id), "name": mesh.m_Name,
                                      "vertexCount": len(positions), "triangleCount": sum(map(len, triangles)),
                                      "positions": handler.m_Vertices, "normals": handler.m_Normals,
                                      "uv0": handler.m_UV0, "tangents": handler.m_Tangents, "submeshTriangles": triangles})
        return index

    def node(self, pointer):
        identity = key(pointer)
        if identity in self.visited or len(self.visited) >= 10_000:
            raise ValueError("Cyclic, shared, or excessively large prefab hierarchy")
        self.visited.add(identity)
        game_object = pointer.read()
        components = {c.component.type.name: c.component for c in game_object.m_Component}
        if "SkinnedMeshRenderer" in components:
            raise ValueError("SkinnedMeshRenderer is not supported by static prefab export")
        if "Transform" not in components:
            raise ValueError("Prefab node lacks Transform")
        transform = components["Transform"].read()
        if not game_object.m_IsActive:
            raise ValueError("Inactive prefab nodes require visibility metadata support")
        rotation = transform.m_LocalRotation
        node = {"name": game_object.m_Name, "translation": reflect(xyz(transform.m_LocalPosition)),
                "rotation": [-rotation.x, -rotation.y, rotation.z, rotation.w], "scale": xyz(transform.m_LocalScale),
                "extras": {"unityPathID": str(pointer.path_id)}}
        index = len(self.gltf["nodes"])
        self.gltf["nodes"].append(node)
        self.source["nodes"].append({"pathID": str(pointer.path_id), "gameObject": pointer.read_typetree(),
                                    "transform": components["Transform"].read_typetree()})
        if "MeshRenderer" in components:
            renderer = components["MeshRenderer"].read()
            if not renderer.m_Enabled:
                raise ValueError("Disabled renderers require visibility metadata support")
            if "MeshFilter" not in components:
                raise ValueError("MeshRenderer lacks MeshFilter")
            node["mesh"] = self.mesh(components["MeshFilter"].read().m_Mesh, renderer)
        for name, component in components.items():
            if name not in {"Transform", "MeshFilter", "MeshRenderer"}:
                self.source["unsupportedComponents"].append({"node": game_object.m_Name, "type": name, "pathID": str(component.path_id)})
        children = [self.node(child.read().m_GameObject) for child in transform.m_Children]
        if children:
            node["children"] = children
        return index


def xyz2(value):
    return [value.x, value.y]


def export(bundles, prefab, output, stem, catalog_lookup=None):
    import UnityPy
    environment = UnityPy.load(*(str(p) for p in bundles))
    matches = [(name, value) for name, value in environment.container.items() if name == prefab or Path(name).stem == prefab]
    if len(matches) != 1:
        raise ValueError(f"Expected one explicit prefab match, found {len(matches)}")
    binding = None
    if catalog_lookup:
        lookup = json.loads(catalog_lookup.read_text())
        records = lookup["effectiveMatchesInSuppliedBundles"]
        if len(records) != 1 or records[0]["prefab"] != Path(matches[0][0]).stem:
            raise ValueError("Catalog lookup must resolve exactly this prefab")
        record = records[0]
        if record["animated"] or record["childRoot"]:
            raise ValueError("Animated items and alternate child roots require a separate mapping")
        binding = {"version": 1, "items": [{k: record[k] for k in ("group", "category", "no", "name")}],
                   "sourceEvidence": record["evidence"], "sourceCatalogs": lookup["sources"]}
        binding["items"][0]["file"] = safe_name(stem) + ".gltf"
    output.mkdir(parents=True, exist_ok=True)
    exporter = Exporter(environment, output, stem)
    exporter.node(matches[0][1])
    if not exporter.gltf["meshes"]:
        raise ValueError("Selected prefab has no drawable static meshes")
    exporter.gltf["buffers"] = [{"uri": exporter.stem + ".bin", "byteLength": len(exporter.blob)}]
    (output / (exporter.stem + ".bin")).write_bytes(exporter.blob)
    (output / (exporter.stem + ".gltf")).write_text(json.dumps(exporter.gltf, indent=2) + "\n")
    (output / "source.unity.json").write_text(json.dumps(exporter.source, indent=2) + "\n")
    provenance = {"schemaVersion": 1, "unityPyVersion": UnityPy.__version__, "prefab": matches[0][0],
                  "conversion": {"basis": "Z reflection, LH Y-up to RH Y-up", "triangles": "i0,i2,i1",
                                 "uv": "u,1-v", "tangent": "x,y,-z,w (basis and UV handedness flips)",
                                 "images": "UnityPy flip=True PNG; A/G normal converted to RGB with scale baked and Y inverted"},
                  "sources": [{"path": str(p.resolve()), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in bundles],
                  "meshes": len(exporter.gltf["meshes"]), "materials": len(exporter.gltf["materials"]),
                  "vertices": sum(m["vertexCount"] for m in exporter.source["meshes"]),
                  "triangles": sum(m["triangleCount"] for m in exporter.source["meshes"])}
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    if binding:
        (output / "catalog.json").write_text(json.dumps(binding, indent=2, ensure_ascii=False) + "\n")
    return provenance


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", action="append", type=Path, required=True, help="Explicit input and dependency bundles")
    parser.add_argument("--prefab", required=True, help="Exact container key or unique prefab filename stem")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", default="prefab")
    parser.add_argument("--catalog-lookup", type=Path, help="Exact catalog.py result to bind the exported item to its original ID")
    args = parser.parse_args()
    print(json.dumps(export(args.bundle, args.prefab, args.output, args.name, args.catalog_lookup), indent=2))
