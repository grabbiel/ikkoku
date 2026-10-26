#!/usr/bin/env python3
"""ST-A11 maps: convert one CharaStudio map (a Unity scene bundle) to glTF for the preview.

CharaStudio 1.0.4.2 loads a map as a Unity scene, not a prefab (`Studio.Map.LoadMap`:
`Manager.Scene.LoadBaseScene` with the catalog row's bundle and scene name, loaded additively
and made the active scene). Its root GameObject named "Map" is `mapRoot`; `MapCtrl.Reflect`
then overwrites only that root's local position and rotation with the scene record's map
transform (`caMap.pos`, `Quaternion.Euler(caMap.rot)`); scale is never written. Every other
root of the map scene stays where it was authored. `sunLightType` selects the
`SunLightInfo` entry on mapRoot: the other entries' `visibleList` objects are deactivated
and the chosen entry's are activated, in the entries' array order.

This converter reuses export_prefab.py's conversion helpers (basis reflection, winding, UV
origin, tangent handedness) and its explicit-mapping rule: a material's shader must be in
MAP_SHADER_RULES or the conversion fails by name. Geometry is merged per (role, material,
visibility class, lightmap index): role "mapRoot" vertices are in mapRoot's local frame
(placed at run time by the map transform), role "scene" vertices are in scene world space.
Each merged mesh's glTF extras name its role, the sun-type keys it is visible for (0, 1, 2,
and -1 for any other saved value, which leaves the authored state) and its lightmap index.

Baked lightmaps (slice 2): TEXCOORD_1 is the lightmap UV (mesh UV1, else UV0) with the
effective `lightmapScaleOffset` applied (LightmapPrefab.Resetup's value where it names the
renderer) and V flipped like TEXCOORD_0. Each LightmapSettings entry's light map and
CombinedDirectional direction map are written as their serialized Unity `image_data`, byte for
byte: DXT1/DXT5 blocks (BC1/BC3), every mip level largest first, rows bottom-up as in Unity's
texture memory, so the output's SHA-256 equals the bundle's. Nothing is decoded: the app
uploads the blocks and decodes RGBM in the shader. The glTF's top-level extras
`ikkokuLightmaps` name the files, their format, size, mips, colour space (m_ColorSpace 1 = sRGB)
and hashes, the lightmaps mode, the RGBM encoding (m_LightmapFormat 2) and the player's colour
space (Linear). Standard materials carry `ikkokuStandard` extras: `_Color` and
`_EmissionColor` converted to Linear (GammaToLinearSpaceExact, as a Linear player uploads
material colours), OneMinusReflectivityFromMetallic(_Metallic) and the `_EmissionMap` image.
provenance.json also records the lights, RenderSettings and SunLightInfo entries.

Proprietary output belongs in .local, never in the repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re

from export_prefab import Exporter, convert_tangent, convert_triangles, convert_uv, key, reflect, safe_name, xyz2

REPO = Path(__file__).resolve().parents[2]
MAP_TABLE = re.compile(r"Map_(\d+)$", re.IGNORECASE)
SUN_TYPES = (0, 1, 2)
OTHER_SUN_TYPE = -1  # a saved sunLightType with no SunLightInfo entry: authored state
NO_LIGHTMAP = -1
# Unity 5.6 "unity default resources" mesh path IDs (the player's Resources file, not the bundle).
UNITY_BUILTIN_MESHES = {10202: "Cube", 10206: "Cylinder", 10207: "Sphere", 10208: "Capsule", 10209: "Plane", 10210: "Quad"}

# Explicit shader rules. "verified" names a contract recovered from the shader itself;
# "approximated" rules are the base-color/alpha subset of a published Unity built-in
# shader, with every dropped term listed in `dropped` (it becomes the app's label).
# A shader that is not listed fails the conversion by name.
MAP_SHADER_RULES = {
    "Standard": {
        "parity": "approximated",
        # Unity 5.6 Standard (built-in source): albedo = _MainTex * _Color; _ALPHATEST_ON clips
        # at _Cutoff; _ALPHABLEND_ON / _ALPHAPREMULTIPLY_ON blend; Cull Back (no cull property).
        "dropped": ["PBR lighting (metallic/smoothness)", "normal maps", "occlusion", "emission", "detail maps",
                    "reflection probes"],
    },
    "Particles/Alpha Blended": {
        "parity": "approximated",
        # Unity built-in: 2 * _TintColor * vertex color * _MainTex, Blend SrcAlpha OneMinusSrcAlpha,
        # Cull Off, ZWrite Off, no lighting.
        "dropped": ["soft particles", "ZWrite Off ordering"],
    },
}
# Shaders the map scene references that draw nothing in Studio's map path.
NON_GEOMETRY_SHADERS = {"Skybox/Procedural", "Skybox/Cubemap"}
# The original player's QualitySettings.activeColorSpace (Unity 5.6.2f1, D3D11), which the
# phase-B probe recorded in its status.json; it selects the Linear RGBM decode.
PLAYER_COLOR_SPACE = "Linear"
# Unity TextureFormat values whose serialized data the app uploads as block textures.
BLOCK_FORMATS = {10: ("BC1", 8), 12: ("BC3", 16)}  # DXT1, DXT5
# LightmapSettings.m_LightmapsMode values the app draws.
LIGHTMAPS_MODES = {0: "NonDirectional", 1: "CombinedDirectional"}
# Texture2D.m_LightmapFormat (TextureUsageMode) 2: an RGBM-encoded lightmap.
RGBM_LIGHTMAP_FORMAT = 2
# unity_ColorSpaceDielectricSpec.a in Linear (UnityCG.cginc L27): 1 - 0.04.
ONE_MINUS_DIELECTRIC_SPEC = 1 - 0.04


# ---------------------------------------------------------------- pure math (unit tested)

def quaternion_matrix(q):
    """Unity quaternion (x, y, z, w) to a row-major 3x3 rotation."""
    x, y, z, w = q
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]


def trs(position, rotation, scale):
    """Row-major 4x4 local-to-parent matrix T * R * S (column vectors), Unity space."""
    r = quaternion_matrix(rotation)
    return [[r[i][0] * scale[0], r[i][1] * scale[1], r[i][2] * scale[2], position[i]] for i in range(3)] + [[0, 0, 0, 1]]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def linear(m):
    return [row[:3] for row in m[:3]]


def det3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


def inverse3(m):
    d = det3(m)
    if not math.isfinite(d) or abs(d) < 1e-12:
        raise ValueError("Singular transform")
    c = [[m[(j + 1) % 3][(i + 1) % 3] * m[(j + 2) % 3][(i + 2) % 3] - m[(j + 1) % 3][(i + 2) % 3] * m[(j + 2) % 3][(i + 1) % 3]
          for j in range(3)] for i in range(3)]
    return [[c[i][j] / d for j in range(3)] for i in range(3)]


def inverse_affine(m):
    r = inverse3(linear(m))
    t = [-sum(r[i][k] * m[k][3] for k in range(3)) for i in range(3)]
    return [r[i] + [t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def apply_point(m, p):
    return [m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] + m[i][3] for i in range(3)]


def apply_linear(m3, v):
    return [m3[i][0] * v[0] + m3[i][1] * v[1] + m3[i][2] * v[2] for i in range(3)]


def normalized(v):
    length = math.sqrt(sum(x * x for x in v))
    return [x / length for x in v] if length > 1e-20 else [0.0, 0.0, 0.0]


def normal_matrix(m):
    """Inverse transpose of the linear part: transforms normals."""
    r = inverse3(linear(m))
    return [[r[j][i] for j in range(3)] for i in range(3)]


def lightmap_uv(uv, scale_offset):
    """Unity's lightmap UV (uv * ST.xy + ST.zw, bottom-up), then the UV0 origin flip."""
    return convert_uv([uv[0] * scale_offset[0] + scale_offset[2], uv[1] * scale_offset[1] + scale_offset[3]])


def tiled_uv(uv, scale, offset):
    """_MainTex_ST baked into UV0 before the origin flip (the repeat sampler tiles it)."""
    return convert_uv([uv[0] * scale[0] + offset[0], uv[1] * scale[1] + offset[1]])


def sun_type_active(authored, infos):
    """GameObject activeSelf per sun-type key after `SunLightInfo.Set`.

    authored: {node: activeSelf}; infos: [(type, [node, ...]), ...] in array order. For a key
    with an entry, every entry's list is set (active for the chosen entry, inactive for the
    others) in array order, so a node listed twice takes the later entry's value. A key
    without an entry (and OTHER_SUN_TYPE) keeps the authored state (`Set` returns false)."""
    result = {}
    types = {t for t, _ in infos}
    for key_ in SUN_TYPES + (OTHER_SUN_TYPE,):
        active = dict(authored)
        if key_ in types:
            chosen = next(i for i, (t, _) in enumerate(infos) if t == key_)  # FirstOrDefault
            for index, (_, nodes) in enumerate(infos):
                for node in nodes:
                    active[node] = index == chosen
        result[key_] = active
    return result


def visibility_keys(node, parents, active_by_key):
    """The sun-type keys for which `node` is activeInHierarchy."""
    keys = []
    for key_, active in active_by_key.items():
        current, visible = node, True
        while current is not None:
            if not active.get(current, False):
                visible = False
                break
            current = parents.get(current)
        if visible:
            keys.append(key_)
    return sorted(keys)


def effective_lightmap(renderer_index, renderer_offset, prefab_parameter):
    """`LightmapPrefab.Resetup` overwrites a listed renderer's index and scale/offset at
    Start when its saved index is >= 0; otherwise the renderer's serialized values stand.
    Unity's 0xFFFF / 0xFFFE indices (none / realtime-only) mean no baked lightmap."""
    index, offset, source = renderer_index, renderer_offset, "renderer"
    if prefab_parameter is not None and prefab_parameter[0] >= 0:
        index, offset, source = prefab_parameter[0], prefab_parameter[1], "LightmapPrefab"
    if index < 0 or index >= 0xFFFE:
        return NO_LIGHTMAP, None, source
    return index, list(offset), source


def gamma_to_linear_exact(value):
    """UnityCG.cginc GammaToLinearSpaceExact (L88-L96): how a Linear player uploads colours."""
    if value <= 0.04045:
        return value / 12.92
    if value < 1.0:
        return ((value + 0.055) / 1.055) ** 2.4
    return value ** 2.2


def one_minus_reflectivity(metallic):
    """UnityStandardUtils.cginc OneMinusReflectivityFromMetallic (L35-L44), Linear."""
    return ONE_MINUS_DIELECTRIC_SPEC - metallic * ONE_MINUS_DIELECTRIC_SPEC


def standard_inputs(colors, floats, keywords, emission_image=None, emission_srgb=True):
    """What the app's baked-lightmap material needs from a Standard material: albedo and
    emission colours in Linear, and diffColor's factor. `_METALLICGLOSSMAP` reads metallic
    from a texture the export does not carry, so `_Metallic` stands in and says so."""
    color = colors.get("_Color", [1, 1, 1, 1])
    words = set(keywords)
    metallic = floats.get("_Metallic", 0.0)
    result = {"albedoLinear": [gamma_to_linear_exact(c) for c in color[:3]] + [color[3]],
              "metallic": metallic, "oneMinusReflectivity": one_minus_reflectivity(metallic),
              "metallicSource": "_MetallicGlossMap.r (not exported; _Metallic used)" if "_METALLICGLOSSMAP" in words else "_Metallic",
              "emission": None}
    if "_EMISSION" in words:
        # Without a texture Unity samples the property's default, "white" (image None).
        emission = colors.get("_EmissionColor", [0, 0, 0, 1])
        result["emission"] = {"colorLinear": [gamma_to_linear_exact(c) for c in emission[:3]], "image": emission_image,
                              "srgb": emission_srgb}
    return result


def block_level_bytes(width, height, mip_count, block_bytes):
    """Bytes of each mip level of a DXT/BC texture, largest first (a level under 4x4 is one block)."""
    sizes, w, h = [], width, height
    for _ in range(mip_count):
        sizes.append(max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * block_bytes)
        w, h = max(1, w // 2), max(1, h // 2)
    return sizes


def lightmap_file_entry(record, file, data):
    """The `ikkokuLightmaps` entry for one serialized lightmap texture written verbatim."""
    fmt = BLOCK_FORMATS.get(record["textureFormat"])
    if fmt is None:
        raise ValueError(f"{record['name']}: TextureFormat {record['textureFormat']} is not a block format the app uploads")
    expected = sum(block_level_bytes(record["width"], record["height"], record["mipCount"], fmt[1]))
    if len(data) != expected:
        raise ValueError(f"{record['name']}: {len(data)} serialized bytes, {fmt[0]} with {record['mipCount']} mips needs {expected}")
    return {"name": record["name"], "file": file, "format": fmt[0], "width": record["width"], "height": record["height"],
            "mipCount": record["mipCount"], "srgb": record["colorSpace"] == 1, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def lightmaps_extras(mode, entries):
    """glTF top-level extras for the exported lightmaps. entries: [(index, light, direction)]."""
    if mode not in LIGHTMAPS_MODES:
        raise ValueError(f"LightmapsMode {mode} is not drawn")
    if LIGHTMAPS_MODES[mode] == "CombinedDirectional" and any(direction is None for _, _, direction in entries):
        raise ValueError("A CombinedDirectional lightmap lacks its direction map")
    maps = [{"index": index, "light": light, **({"direction": direction} if direction else {})} for index, light, direction in entries]
    return {"kind": "ikkoku.unityLightmaps", "version": 1, "mode": LIGHTMAPS_MODES[mode], "encoding": "RGBM",
            "colorSpace": PLAYER_COLOR_SPACE, "rows": "bottomUp", "maps": maps}


def standard_contract(colors, floats, keywords):
    """Base color and alpha subset of Unity 5.6's built-in Standard shader."""
    color = colors.get("_Color", [1, 1, 1, 1])
    words = set(keywords)
    if "_ALPHATEST_ON" in words:
        return {"baseColorFactor": [color[0], color[1], color[2], 1], "alphaMode": "MASK",
                "alphaCutoff": floats.get("_Cutoff", 0.5), "doubleSided": False}
    if words & {"_ALPHABLEND_ON", "_ALPHAPREMULTIPLY_ON"}:
        return {"baseColorFactor": list(color[:4]), "alphaMode": "BLEND", "doubleSided": False}
    return {"baseColorFactor": [color[0], color[1], color[2], 1], "alphaMode": "OPAQUE", "doubleSided": False}


def particle_contract(colors):
    tint = colors.get("_TintColor", [0.5, 0.5, 0.5, 0.5])
    return {"baseColorFactor": [min(2 * tint[0], 1), min(2 * tint[1], 1), min(2 * tint[2], 1), min(2 * tint[3], 1)],
            "alphaMode": "BLEND", "doubleSided": True, "unlit": True, "vertexColor": True}


def map_material_contract(shader_name, colors, floats, keywords):
    rule = MAP_SHADER_RULES.get(shader_name)
    if rule is None:
        raise ValueError(f"No map mapping for shader {shader_name!r}")
    contract = standard_contract(colors, floats, keywords) if shader_name == "Standard" else particle_contract(colors)
    contract.update(shaderParity=rule["parity"], dropped=list(rule["dropped"]))
    return contract


def catalog_rows(tables):
    """`Studio.Info.LoadMapLoadInfo` over (bundle, table name, rows) in load order: two header
    rows skipped, a row whose first cell is not an Int32 skipped, a later row replaces an
    earlier one with the same number."""
    maps = {}
    for bundle, name, rows in tables:
        for row_index, values in enumerate(rows):
            if row_index < 2 or not values:
                continue
            try:
                number = int(values[0])
            except ValueError:
                continue
            if not -(2 ** 31) <= number < 2 ** 31 or len(values) < 4:
                continue
            cell = lambda i: values[i] if i < len(values) else None
            maps[number] = {"no": number, "name": values[1], "bundlePath": values[2], "scene": values[3],
                            "manifest": cell(4) or None,
                            "vanish": {"bundlePath": cell(5), "file": cell(6)} if cell(5) and cell(6) else None,
                            "evidence": {"infoBundle": bundle, "table": name, "row": row_index}}
    return [maps[n] for n in sorted(maps)]


# ---------------------------------------------------------------- Unity reading

def read_tables(info_bundles):
    import UnityPy
    tables, sources = [], []
    # Studio.Info sorts the info bundle names before loading them.
    for bundle in sorted({Path(p).resolve() for p in info_bundles}, key=lambda p: str(p).casefold()):
        data = bundle.read_bytes()
        sources.append({"path": str(bundle), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        found = []
        for obj in UnityPy.load(str(bundle)).objects:
            if obj.type.name != "MonoBehaviour":
                continue
            tree = obj.read_typetree()
            if MAP_TABLE.fullmatch(tree.get("m_Name", "")):
                found.append((tree["m_Name"], [entry.get("list", []) for entry in tree.get("list", [])]))
        for name, rows in sorted(found):
            tables.append((str(bundle), name, rows))
    return tables, sources


class MapScene:
    """The scene file of a map bundle, read without instantiating anything."""

    def __init__(self, bundles, scene):
        import UnityPy
        self.bundles = [Path(p).resolve() for p in bundles]
        self.environment = UnityPy.load(*(str(p) for p in self.bundles))
        wanted = "buildplayer-" + scene.casefold()
        files = {}
        for bundle in self.environment.files.values():
            for name, file in getattr(bundle, "files", {}).items():
                if hasattr(file, "objects"):
                    files[name] = file
        matches = [file for name, file in files.items() if name.casefold() == wanted]
        if len(matches) != 1:
            raise ValueError(f"Expected one scene file BuildPlayer-{scene}, found {len(matches)} among {sorted(files)}")
        self.scene_file = matches[0]
        self.scene = scene
        self.objects = {path_id: reader for path_id, reader in self.scene_file.objects.items()}
        self.transforms = {pid: r.read() for pid, r in self.objects.items() if r.type.name == "Transform"}
        self.game_objects = {pid: r.read() for pid, r in self.objects.items() if r.type.name == "GameObject"}
        self.transform_of_object = {t.m_GameObject.path_id: pid for pid, t in self.transforms.items()}
        self.parents = {pid: (t.m_Father.path_id or None) for pid, t in self.transforms.items()}
        roots = [pid for pid, parent in self.parents.items() if parent is None]
        self.roots = roots
        named = [pid for pid in roots if self.game_objects[self.transforms[pid].m_GameObject.path_id].m_Name == "Map"]
        if len(named) != 1:
            raise ValueError(f"Expected one root GameObject named 'Map', found {len(named)}")
        self.map_root = named[0]
        self.local = {pid: trs(*self.local_trs(t)) for pid, t in self.transforms.items()}
        self.world = {}
        for pid in self.transforms:
            self.world_matrix(pid)

    @staticmethod
    def local_trs(t):
        p, r, s = t.m_LocalPosition, t.m_LocalRotation, t.m_LocalScale
        return [p.x, p.y, p.z], [r.x, r.y, r.z, r.w], [s.x, s.y, s.z]

    def world_matrix(self, pid):
        if pid not in self.world:
            parent = self.parents[pid]
            self.world[pid] = self.local[pid] if parent is None else matmul(self.world_matrix(parent), self.local[pid])
        return self.world[pid]

    def name(self, transform_id):
        return self.game_objects[self.transforms[transform_id].m_GameObject.path_id].m_Name

    def path(self, transform_id):
        names = []
        current = transform_id
        while current is not None:
            names.append(self.name(current))
            current = self.parents[current]
        return "/".join(reversed(names))

    def under_map_root(self, transform_id):
        current = transform_id
        while current is not None:
            if current == self.map_root:
                return True
            current = self.parents[current]
        return False

    def external_path(self, pointer):
        return None if pointer.file_id == 0 else self.scene_file.externals[pointer.file_id - 1].path

    def builtin_mesh(self, pointer):
        """The built-in mesh name when `pointer` names the player's default resources."""
        path = self.external_path(pointer)
        if path and path.casefold().endswith("unity default resources"):
            return UNITY_BUILTIN_MESHES.get(pointer.path_id, f"builtin:{pointer.path_id}")
        return None

    def components(self, game_object):
        result = []
        for pair in game_object.m_Component:
            pointer = pair.component if hasattr(pair, "component") else pair[1]
            result.append(pointer)
        return result

    def of_type(self, type_name):
        return [(pid, r) for pid, r in self.objects.items() if r.type.name == type_name]

    def monobehaviours(self, class_name):
        found = []
        for pid, reader in self.of_type("MonoBehaviour"):
            behaviour = reader.read()
            script = behaviour.m_Script.read() if behaviour.m_Script and behaviour.m_Script.path_id else None
            if script is not None and script.m_ClassName == class_name:
                found.append((pid, behaviour, reader.read_typetree()))
        return found

    def authored_active(self):
        return {pid: bool(self.game_objects[t.m_GameObject.path_id].m_IsActive) for pid, t in self.transforms.items()}

    def sun_light_info(self):
        """(typetree, infos as [(type, [transform ids])]) of the SunLightInfo on mapRoot."""
        map_object = self.transforms[self.map_root].m_GameObject.path_id
        found = [tree for _, behaviour, tree in self.monobehaviours("SunLightInfo") if behaviour.m_GameObject.path_id == map_object]
        if not found:
            return None, []
        if len(found) > 1:
            raise ValueError("More than one SunLightInfo on mapRoot")
        tree = found[0]
        infos = []
        for info in tree.get("_infos", []):
            nodes = []
            for pointer in info.get("visibleList", []):
                if pointer.get("m_FileID", 0) != 0:
                    raise ValueError("SunLightInfo visibleList names an object outside the scene file")
                if pointer["m_PathID"]:
                    nodes.append(self.transform_of_object[pointer["m_PathID"]])
            infos.append((int(info["type"]), nodes))
        return tree, infos

    def lightmap_prefab_parameters(self):
        """{renderer path id: (index, [sx, sy, ox, oy])} from every LightmapPrefab whose
        GameObject is active in the hierarchy (Start only runs there)."""
        active = self.authored_active()
        result = {}
        for _, behaviour, tree in self.monobehaviours("LightmapPrefab"):
            host = self.transform_of_object[behaviour.m_GameObject.path_id]
            if not visibility_keys(host, self.parents, {OTHER_SUN_TYPE: active}):
                continue
            for parameter in tree.get("lightmapParameters", []) or []:
                pointer = parameter.get("renderer", {})
                if pointer.get("m_FileID", 0) != 0 or not pointer.get("m_PathID"):
                    continue
                st = parameter["scaleOffset"]
                result[pointer["m_PathID"]] = (int(parameter["lightmapIndex"]), [st["x"], st["y"], st["z"], st["w"]])
        return result


def texture_record(texture, pointer, decode=True):
    data = getattr(texture, "image_data", None)
    raw = bytes(data) if data else b""
    record = {"name": texture.m_Name, "pathID": str(pointer.path_id), "width": texture.m_Width, "height": texture.m_Height,
              "textureFormat": int(texture.m_TextureFormat), "mipCount": getattr(texture, "m_MipCount", None),
              "lightmapFormat": getattr(texture, "m_LightmapFormat", None), "colorSpace": getattr(texture, "m_ColorSpace", None),
              "serializedBytes": len(raw), "serializedSHA256": hashlib.sha256(raw).hexdigest() if raw else None}
    if decode:
        try:
            image = texture.image
            record["decodable"] = True
            record["decodedMode"] = image.mode
        except Exception as error:  # the next slice needs to know which formats decode
            record["decodable"] = False
            record["decodeError"] = f"{type(error).__name__}: {error}"[:300]
    return record


def gpu_bytes(width, height):
    """RGBA8 with a full mip chain, the way ResourceStore uploads a PNG (MTKTextureLoader)."""
    total, w, h = 0, width, height
    while True:
        total += w * h * 4
        if w == 1 and h == 1:
            return total
        w, h = max(1, w // 2), max(1, h // 2)


def colors_of(material):
    return {name: [value.r, value.g, value.b, value.a] for name, value in dict(material.m_SavedProperties.m_Colors).items()}


def keywords_of(material):
    words = material.m_ShaderKeywords
    if isinstance(words, str):
        return [w for w in words.split() if w]
    return list(words or material.m_ValidKeywords or [])


def shader_name(material):
    shader = material.m_Shader.read()
    return shader.m_Name or getattr(getattr(shader, "m_ParsedForm", None), "m_Name", "")


# ---------------------------------------------------------------- inventory

def inventory(bundles, scene):
    """Metadata only: counts, triangles, texture memory, lightmaps, shaders, lights."""
    from UnityPy.helpers.MeshHelper import MeshHandler
    map_scene = MapScene(bundles, scene)
    sun_tree, infos = map_scene.sun_light_info()
    active = sun_type_active(map_scene.authored_active(), infos)
    renderers, materials, textures, meshes, unsupported = [], {}, {}, {}, {}
    prefab_lightmaps = map_scene.lightmap_prefab_parameters()
    draw_groups = set()
    for pid, reader in map_scene.of_type("MeshRenderer"):
        renderer = reader.read()
        host = map_scene.transform_of_object[renderer.m_GameObject.path_id]
        components = {p.type.name: p for p in map_scene.components(renderer.m_GameObject.read())}
        mesh_pointer = components["MeshFilter"].read().m_Mesh if "MeshFilter" in components else None
        builtin = map_scene.builtin_mesh(mesh_pointer) if mesh_pointer is not None else None
        try:
            mesh = mesh_pointer.read() if mesh_pointer and mesh_pointer.path_id else None
        except FileNotFoundError:
            if builtin is None:
                raise
            mesh = None  # the default resources file was not supplied
        triangles = None if builtin and mesh is None else 0
        if mesh is not None:
            identity = key(mesh_pointer)
            if identity not in meshes:
                handler = MeshHandler(mesh)
                handler.process()
                tris = handler.get_triangles()
                meshes[identity] = {"name": mesh.m_Name, "vertices": len(handler.m_Vertices or []),
                                    "submeshTriangles": [len(t) for t in tris], "uv1": bool(handler.m_UV1)}
            triangles = sum(meshes[identity]["submeshTriangles"][:len(renderer.m_Materials)])
        names = []
        for pointer in renderer.m_Materials:
            if not pointer.path_id:
                names.append(None)
                continue
            material = pointer.read()
            identity = key(pointer)
            names.append(material.m_Name)
            if identity not in materials:
                textures_bound = {}
                for slot, env in dict(material.m_SavedProperties.m_TexEnvs).items():
                    if env.m_Texture.path_id:
                        texture = env.m_Texture.read()
                        textures_bound[slot] = texture.m_Name
                        tid = key(env.m_Texture)
                        if tid not in textures and env.m_Texture.type.name == "Texture2D":
                            textures[tid] = texture_record(texture, env.m_Texture, decode=False)
                            textures[tid]["slots"] = set()
                        if tid in textures:
                            textures[tid]["slots"].add(slot)
                floats = dict(material.m_SavedProperties.m_Floats)
                colors = colors_of(material)
                materials[identity] = {"name": material.m_Name, "shader": shader_name(material),
                                       "keywords": keywords_of(material), "textures": textures_bound,
                                       "mainTexST": [xyz2(e.m_Scale) + xyz2(e.m_Offset) for s, e in dict(material.m_SavedProperties.m_TexEnvs).items() if s == "_MainTex"],
                                       "mode": floats.get("_Mode"), "cutoff": floats.get("_Cutoff"),
                                       "color": colors.get("_Color"), "emissionColor": colors.get("_EmissionColor"),
                                       "tintColor": colors.get("_TintColor"), "renderQueue": getattr(material, "m_CustomRenderQueue", None),
                                       "textureIDs": sorted({key(e.m_Texture) for e in dict(material.m_SavedProperties.m_TexEnvs).values() if e.m_Texture.path_id})}
        static_batch = renderer.m_StaticBatchInfo
        keys = visibility_keys(host, map_scene.parents, active)
        lm_index, _, lm_source = effective_lightmap(renderer.m_LightmapIndex, [0, 0, 0, 0], prefab_lightmaps.get(pid))
        if renderer.m_Enabled and keys:
            for pointer in renderer.m_Materials:
                if pointer.path_id and materials[key(pointer)]["shader"] not in NON_GEOMETRY_SHADERS:
                    draw_groups.add((map_scene.under_map_root(host), key(pointer), tuple(keys), lm_index))
        renderers.append({"path": map_scene.path(host), "enabled": bool(renderer.m_Enabled), "materials": names,
                          "triangles": triangles, "builtinMesh": builtin, "underMapRoot": map_scene.under_map_root(host),
                          "visibleFor": keys, "lightmapIndex": renderer.m_LightmapIndex,
                          "effectiveLightmapIndex": lm_index, "lightmapSource": lm_source,
                          "staticBatch": [static_batch.firstSubMesh, static_batch.subMeshCount] if static_batch else None})
    for pid, reader in map_scene.objects.items():
        name = reader.type.name
        if name in {"Transform", "GameObject", "MeshRenderer", "MeshFilter"}:
            continue
        if name == "MonoBehaviour":
            behaviour = reader.read()
            script = behaviour.m_Script.read() if behaviour.m_Script.path_id else None
            name = "MonoBehaviour:" + (script.m_ClassName if script else "?")
        unsupported[name] = unsupported.get(name, 0) + 1
    lightmaps = []
    for _, reader in map_scene.of_type("LightmapSettings"):
        settings = reader.read()
        for index, data in enumerate(settings.m_Lightmaps):
            entry = {"index": index}
            for field in ("m_Lightmap", "m_DirLightmap", "m_ShadowMask"):
                pointer = getattr(data, field, None)
                if pointer is not None and pointer.path_id:
                    entry[field[2:]] = texture_record(pointer.read(), pointer)
            lightmaps.append(entry)
    for record in textures.values():
        record["slots"] = sorted(record["slots"])
        record["gpuBytesRGBA8Mips"] = gpu_bytes(record["width"], record["height"])
    drawn = [r for r in renderers if r["enabled"] and r["visibleFor"]]
    geometry_materials = {identity for identity, m in materials.items() if m["shader"] not in NON_GEOMETRY_SHADERS}
    drawn_materials = {identity for identity in geometry_materials
                       if any(materials[identity]["name"] in r["materials"] for r in drawn)}
    base_ids = set()
    for identity in drawn_materials:
        envs = materials[identity]["textures"]
        if "_MainTex" in envs:
            base_ids.update(t for t in materials[identity]["textureIDs"] if t in textures and textures[t]["name"] == envs["_MainTex"])
    base_textures = [textures[t] for t in base_ids]
    for material in materials.values():
        material.pop("textureIDs")
    budget = {"mergedDraws": len(draw_groups),
              "mergedDrawsBySunType": {str(k): sum(1 for g in draw_groups if k in g[2]) for k in SUN_TYPES + (OTHER_SUN_TYPE,)},
              "baseTextures": len(base_textures),
              "baseTextureBytesRGBA8Mips": sum(gpu_bytes(t["width"], t["height"]) for t in base_textures),
              "baseTextureBytesRGBA8MipsCap": {str(cap): sum(gpu_bytes(min(t["width"], cap), min(t["height"], cap) if t["width"] <= cap
                                                                           else max(1, t["height"] * cap // t["width"])) for t in base_textures)
                                               for cap in (2048, 1024, 512)},
              "baseTextureBytesNative": sum(t["serializedBytes"] for t in base_textures),
              "baseTextureFormats": sorted({t["textureFormat"] for t in base_textures}),
              "skyboxShaderMeshes": sorted({r["path"] for r in drawn
                                            if any(materials[i]["shader"] in NON_GEOMETRY_SHADERS and materials[i]["name"] in r["materials"]
                                                   for i in materials)})}
    return {
        "scene": scene, "bundles": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in map_scene.bundles],
        "roots": [{"name": map_scene.name(r), "mapRoot": r == map_scene.map_root,
                   "localTRS": map_scene.local_trs(map_scene.transforms[r])} for r in map_scene.roots],
        "renderers": renderers, "rendererCount": len(renderers), "drawnRendererCount": len(drawn),
        "triangles": sum(r["triangles"] or 0 for r in drawn),
        "drawnBuiltinMeshes": sorted({r["builtinMesh"] for r in drawn if r["builtinMesh"] and r["triangles"] is None}),
        "meshes": len(meshes), "materials": list(materials.values()), "materialCount": len(materials),
        "textures": sorted(textures.values(), key=lambda t: t["name"]), "textureCount": len(textures),
        "baseTextureGPUBytes": budget["baseTextureBytesRGBA8Mips"], "budget": budget,
        "allTextureGPUBytes": sum(t["gpuBytesRGBA8Mips"] for t in textures.values()),
        "shaders": sorted({m["shader"] for m in materials.values()}),
        "lightmaps": lightmaps, "sunLightInfo": summarize_sun(map_scene, sun_tree, infos),
        "lights": lights_of(map_scene, active), "renderSettings": render_settings_of(map_scene),
        "otherComponents": dict(sorted(unsupported.items())),
        "lightmapPrefabRenderers": len(map_scene.lightmap_prefab_parameters()),
    }


def summarize_sun(map_scene, tree, infos):
    if tree is None:
        return None
    entries = []
    for info, (kind, nodes) in zip(tree.get("_infos", []), infos):
        color = info.get("color", {})
        entries.append({"type": kind, "visibleList": [map_scene.path(n) for n in nodes],
                        "angle": [info.get("angle", {}).get(a) for a in "xyz"],
                        "color": [color.get(c) for c in "rgba"], "intensity": info.get("intensity"),
                        "fogUse": info.get("fogUse"), "fogStart": info.get("fogStart"), "fogEnd": info.get("fogEnd"),
                        "backTexture": bool(info.get("backTexture", {}).get("m_PathID"))})
    target = tree.get("_targetLight", {}).get("m_PathID")
    return {"entries": entries, "targetLightPathID": str(target) if target else None}


def lights_of(map_scene, active):
    result = []
    for pid, reader in map_scene.of_type("Light"):
        light = reader.read()
        host = map_scene.transform_of_object[light.m_GameObject.path_id]
        world = map_scene.world[host]
        color = light.m_Color
        result.append({"path": map_scene.path(host), "pathID": str(pid), "type": light.m_Type, "enabled": bool(light.m_Enabled),
                       "color": [color.r, color.g, color.b, color.a], "intensity": light.m_Intensity, "range": light.m_Range,
                       "spotAngle": light.m_SpotAngle, "lightmapping": light.m_Lightmapping,
                       "shadows": light.m_Shadows.m_Type, "cullingMask": light.m_CullingMask.m_Bits,
                       "visibleFor": visibility_keys(host, map_scene.parents, active),
                       "underMapRoot": map_scene.under_map_root(host),
                       "worldForwardUnity": normalized(apply_linear(linear(world), [0, 0, 1])),
                       "worldPositionUnity": [world[0][3], world[1][3], world[2][3]]})
    return result


def render_settings_of(map_scene):
    for _, reader in map_scene.of_type("RenderSettings"):
        r = reader.read()
        rgba = lambda c: [c.r, c.g, c.b, c.a] if c is not None else None
        return {"fog": bool(r.m_Fog), "fogMode": r.m_FogMode, "fogColor": rgba(r.m_FogColor), "fogDensity": r.m_FogDensity,
                "linearFogStart": r.m_LinearFogStart, "linearFogEnd": r.m_LinearFogEnd, "ambientMode": r.m_AmbientMode,
                "ambientSky": rgba(r.m_AmbientSkyColor), "ambientEquator": rgba(r.m_AmbientEquatorColor),
                "ambientGround": rgba(r.m_AmbientGroundColor), "ambientIntensity": r.m_AmbientIntensity,
                "skyboxMaterial": shader_name(r.m_SkyboxMaterial.read()) if r.m_SkyboxMaterial.path_id else None,
                "subtractiveShadowColor": rgba(r.m_SubtractiveShadowColor)}
    return None


# ---------------------------------------------------------------- export

class MapExporter(Exporter):
    """export_prefab's Exporter with merged map geometry and the map shader rules."""

    def __init__(self, environment, output, stem, max_texture=None):
        super().__init__(environment, output, stem)
        self.max_texture = max_texture
        self.gltf["generator"] = "Ikkoku CharaStudio map-scene exporter"
        self.source = {"materials": [], "textures": [], "groups": []}

    def texture(self, pointer, normal_scale=None):
        identity = (*key(pointer), normal_scale)
        if identity in self.texture_cache:
            return self.texture_cache[identity]
        texture = pointer.read()
        if pointer.type.name != "Texture2D":
            raise ValueError(f"Unsupported texture kind: {pointer.type.name}")
        image = texture.image
        reduction = 1
        if self.max_texture:
            while max(image.width, image.height) // reduction > self.max_texture:
                reduction *= 2
            if reduction > 1:
                image = image.reduce(reduction)  # box filter: the next mip level(s)
        name = f"{len(self.texture_cache)}_{safe_name(texture.m_Name)}.png"
        image.save(self.output / name)
        index = len(self.gltf["textures"])
        self.gltf["images"].append({"uri": name, "name": texture.m_Name})
        self.gltf["textures"].append({"source": index})
        self.texture_cache[identity] = index
        record = texture_record(texture, pointer, decode=False)
        record.update(output=name, reduction=reduction, outputWidth=image.width, outputHeight=image.height,
                      outputSHA256=hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        self.source["textures"].append(record)
        return index

    def map_material(self, pointer):
        identity = key(pointer)
        if identity in self.material_cache:
            return self.material_cache[identity]
        material = pointer.read()
        properties = material.m_SavedProperties
        floats, envs = dict(properties.m_Floats), dict(properties.m_TexEnvs)
        name = shader_name(material)
        contract = map_material_contract(name, colors_of(material), floats, keywords_of(material))
        main = envs.get("_MainTex")
        result = {"name": material.m_Name,
                  "pbrMetallicRoughness": {"baseColorFactor": contract["baseColorFactor"], "metallicFactor": 0, "roughnessFactor": 1},
                  "alphaMode": contract["alphaMode"], "doubleSided": contract["doubleSided"],
                  "extras": {"unityShader": name, "unityPathID": str(identity[1]), "shaderParity": contract["shaderParity"],
                             "droppedTerms": contract["dropped"]}}
        if "alphaCutoff" in contract:
            result["alphaCutoff"] = contract["alphaCutoff"]
        if contract.get("unlit"):
            result["extensions"] = {"KHR_materials_unlit": {}}
            result["extras"]["unlit"] = True
        tiling = ([1.0, 1.0], [0.0, 0.0])
        if main and main.m_Texture.path_id:
            result["pbrMetallicRoughness"]["baseColorTexture"] = {"index": self.texture(main.m_Texture)}
            tiling = (xyz2(main.m_Scale), xyz2(main.m_Offset))
        if name == "Standard":
            emission_map = envs.get("_EmissionMap")
            image, srgb = None, True
            # Standard samples _EmissionMap at i.tex.xy, the _MainTex_ST UV already baked into
            # TEXCOORD_0 (UnityStandardCore.cginc L421); the map's own _ST is never read.
            if "_EMISSION" in keywords_of(material) and emission_map and emission_map.m_Texture.path_id:
                image = self.gltf["textures"][self.texture(emission_map.m_Texture)]["source"]
                srgb = emission_map.m_Texture.read().m_ColorSpace == 1
            result["extras"]["ikkokuStandard"] = standard_inputs(colors_of(material), floats, keywords_of(material), image, srgb)
        index = len(self.gltf["materials"])
        self.material_cache[identity] = (index, tiling, bool(contract.get("vertexColor")))
        self.gltf["materials"].append(result)
        self.source["materials"].append({"pathID": str(identity[1]), "name": material.m_Name, "shaderName": name,
                                         "keywords": keywords_of(material), "mainTexST": [*tiling[0], *tiling[1]],
                                         "serialized": pointer.read_typetree()})
        return self.material_cache[identity]


def export(bundles, scene, map_no, output, max_texture=None):
    import UnityPy
    from UnityPy.helpers.MeshHelper import MeshHandler
    map_scene = MapScene(bundles, scene)
    sun_tree, infos = map_scene.sun_light_info()
    active = sun_type_active(map_scene.authored_active(), infos)
    prefab_lightmaps = map_scene.lightmap_prefab_parameters()
    stem = safe_name(scene)
    output.mkdir(parents=True, exist_ok=True)
    exporter = MapExporter(map_scene.environment, output, stem, max_texture)
    map_root_world_inverse = inverse_affine(map_scene.world[map_scene.map_root])
    groups, skipped = {}, []
    lightmap_sources = {"renderer": 0, "LightmapPrefab": 0}
    handlers = {}
    for pid, reader in sorted(map_scene.of_type("MeshRenderer")):
        renderer = reader.read()
        host = map_scene.transform_of_object[renderer.m_GameObject.path_id]
        path = map_scene.path(host)
        keys = visibility_keys(host, map_scene.parents, active)
        if not renderer.m_Enabled or not keys:
            skipped.append({"path": path, "reason": "disabled renderer" if not renderer.m_Enabled else "never active"})
            continue
        batch = renderer.m_StaticBatchInfo
        if batch is not None and batch.subMeshCount > 0:
            raise ValueError(f"{path}: static-batched renderers are not in the verified maps; their placement rule needs evidence")
        components = {p.type.name: p for p in map_scene.components(renderer.m_GameObject.read())}
        if "MeshFilter" not in components:
            raise ValueError(f"{path}: MeshRenderer lacks MeshFilter")
        mesh_pointer = components["MeshFilter"].read().m_Mesh
        mesh = mesh_pointer.read()
        if mesh.m_BindPose or (mesh.m_Shapes and mesh.m_Shapes.channels):
            raise ValueError(f"{path}: skinned or morph mesh on a MeshRenderer")
        identity = key(mesh_pointer)
        if identity not in handlers:
            handler = MeshHandler(mesh)
            handler.process()
            handlers[identity] = (handler, handler.get_triangles())
        handler, triangles = handlers[identity]
        if len(renderer.m_Materials) > len(triangles):
            raise ValueError(f"{path}: more materials than submeshes (extra passes are unsupported)")
        role = "mapRoot" if map_scene.under_map_root(host) else "scene"
        world = map_scene.world[host]
        matrix = matmul(map_root_world_inverse, world) if role == "mapRoot" else world
        normals_matrix = normal_matrix(matrix)
        mirrored = det3(linear(matrix)) < 0
        lm_index, lm_offset, lm_source = effective_lightmap(renderer.m_LightmapIndex,
            [renderer.m_LightmapTilingOffset.x, renderer.m_LightmapTilingOffset.y,
             renderer.m_LightmapTilingOffset.z, renderer.m_LightmapTilingOffset.w], prefab_lightmaps.get(pid))
        lightmap_sources[lm_source] += 1
        for submesh, pointer in enumerate(renderer.m_Materials):
            if not pointer.path_id:
                skipped.append({"path": path, "submesh": submesh, "reason": "no material"})
                continue
            if shader_name(pointer.read()) in NON_GEOMETRY_SHADERS:
                skipped.append({"path": path, "submesh": submesh, "reason": "skybox shader on a mesh"})
                continue
            material_index, (scale, offset), vertex_color = exporter.map_material(pointer)
            group_key = (role, material_index, tuple(keys), lm_index)
            group = groups.setdefault(group_key, {"positions": [], "normals": [], "tangents": [], "uv0": [], "uv1": [],
                                                  "colors": [], "indices": [], "renderers": [], "vertexColor": vertex_color})
            used = sorted({i for triangle in triangles[submesh] for i in triangle})
            remap = {old: len(group["positions"]) + new for new, old in enumerate(used)}
            for old in used:
                group["positions"].append(reflect(apply_point(matrix, handler.m_Vertices[old])))
                if handler.m_Normals:
                    group["normals"].append(reflect(normalized(apply_linear(normals_matrix, handler.m_Normals[old]))))
                if handler.m_Tangents:
                    t = handler.m_Tangents[old]
                    direction = normalized(apply_linear(linear(matrix), t[:3]))
                    group["tangents"].append(convert_tangent(direction + [t[3] * (-1 if mirrored else 1)]))
                if handler.m_UV0:
                    group["uv0"].append(tiled_uv(handler.m_UV0[old], scale, offset))
                if lm_index != NO_LIGHTMAP:
                    source_uv = handler.m_UV1 if handler.m_UV1 else handler.m_UV0
                    group["uv1"].append(lightmap_uv(source_uv[old], lm_offset))
                if vertex_color and handler.m_Colors:
                    group["colors"].append(list(handler.m_Colors[old]))
            converted = convert_triangles([[remap[i] for i in triangle] for triangle in triangles[submesh]], len(group["positions"]))
            if mirrored:  # a mirroring transform reverses the authored winding once more
                converted = [converted[i + j] for i in range(0, len(converted), 3) for j in (0, 2, 1)]
            group["indices"].extend(converted)
            group["renderers"].append({"path": path, "submesh": submesh, "vertices": len(used), "triangles": len(triangles[submesh]),
                                       "lightmapIndex": lm_index, "lightmapScaleOffset": lm_offset, "lightmapSource": lm_source,
                                       "mirrored": mirrored})
    # glTF: node 0 "Map" (mapRoot's authored scale; the app replaces translation and rotation
    # with the record's map transform), node 1 "Scene" (identity, scene-space geometry).
    root_scale = map_scene.local_trs(map_scene.transforms[map_scene.map_root])[2]
    exporter.gltf["nodes"] = [{"name": "Map", "scale": root_scale, "children": [], "extras": {"ikkokuMapRole": "mapRoot"}},
                              {"name": "Scene", "children": [], "extras": {"ikkokuMapRole": "scene"}}]
    exporter.gltf["scenes"] = [{"nodes": [0, 1]}]
    totals = {"vertices": 0, "triangles": 0}
    for group_key in sorted(groups, key=lambda k: (k[0], k[1], k[2], k[3])):
        role, material_index, keys, lm_index = group_key
        group = groups[group_key]
        count = len(group["positions"])
        attributes = {"POSITION": exporter.accessor(group["positions"], "VEC3", bounds=True)}
        for semantic, values, shape in [("NORMAL", group["normals"], "VEC3"), ("TANGENT", group["tangents"], "VEC4"),
                                        ("TEXCOORD_0", group["uv0"], "VEC2"), ("TEXCOORD_1", group["uv1"], "VEC2"),
                                        ("COLOR_0", group["colors"], "VEC4")]:
            if values:
                if len(values) != count:
                    raise ValueError(f"Merged {semantic} count differs from the vertex count (mixed source streams)")
                attributes[semantic] = exporter.accessor(values, shape)
        extras = {"ikkokuMap": {"role": role, "visibleFor": list(keys), "lightmapIndex": lm_index,
                                "renderers": len(group["renderers"])}}
        mesh_index = len(exporter.gltf["meshes"])
        exporter.gltf["meshes"].append({"name": f"{role}_{material_index}_{'_'.join(map(str, keys))}_{lm_index}",
                                        "primitives": [{"attributes": attributes, "mode": 4, "material": material_index,
                                                        "indices": exporter.accessor(group["indices"], "SCALAR", integer=True)}],
                                        "extras": extras})
        node_index = len(exporter.gltf["nodes"])
        exporter.gltf["nodes"].append({"name": exporter.gltf["meshes"][-1]["name"], "mesh": mesh_index})
        exporter.gltf["nodes"][0 if role == "mapRoot" else 1]["children"].append(node_index)
        totals["vertices"] += count
        totals["triangles"] += len(group["indices"]) // 3
        exporter.source["groups"].append({"mesh": mesh_index, "role": role, "material": material_index, "visibleFor": list(keys),
                                          "lightmapIndex": lm_index, "renderers": group["renderers"]})
    if not exporter.gltf["meshes"]:
        raise ValueError("The map scene has no drawable static meshes")
    if any(m.get("extensions", {}).get("KHR_materials_unlit") is not None for m in exporter.gltf["materials"]):
        exporter.gltf["extensionsUsed"] = ["KHR_materials_unlit"]
    lightmaps, lightmap_mode, lightmap_export = export_lightmaps(map_scene, output)
    lightmap_extras = lightmap_export.pop("extras", None)
    lightmap_export["drawn"] = lightmap_extras is not None
    if lightmap_extras:
        exporter.gltf["extras"] = {"ikkokuLightmaps": lightmap_extras}
    exporter.gltf["buffers"] = [{"uri": stem + ".bin", "byteLength": len(exporter.blob)}]
    (output / (stem + ".bin")).write_bytes(exporter.blob)
    (output / (stem + ".gltf")).write_text(json.dumps(exporter.gltf, indent=2) + "\n")
    (output / "source.unity.json").write_text(json.dumps(exporter.source, indent=2, ensure_ascii=False) + "\n")
    dropped = sorted({term for m in exporter.gltf["materials"] for term in m["extras"]["droppedTerms"]})
    shaders = sorted({m["extras"]["unityShader"] for m in exporter.gltf["materials"]})
    provenance = {
        "schemaVersion": 1, "unityPyVersion": UnityPy.__version__, "mapNo": map_no, "scene": scene,
        "conversion": {"basis": "Z reflection, LH Y-up to RH Y-up", "triangles": "i0,i2,i1 (again reversed under a mirroring transform)",
                       "uv0": "_MainTex_ST baked, then u,1-v", "uv1": "lightmap UV (mesh UV1, else UV0) * ST.xy + ST.zw, then u,1-v",
                       "tangent": "x,y,-z,w (w negated again under a mirroring transform)",
                       "merge": "per (role, material, visibility class, lightmap index); role mapRoot in mapRoot's local frame, role scene in world space",
                       "lightmaps": "serialized image_data written verbatim (BC blocks, all mips, rows bottom-up); sampled at (u, 1 - v) of TEXCOORD_1",
                       "images": "UnityPy PNG (top-down)" + (f"; reduced by powers of two to <= {max_texture} px" if max_texture else "")},
        "transformRule": "mapRoot.localPosition = caMap.pos; mapRoot.localRotation = Quaternion.Euler(caMap.rot); scale never written (MapCtrl.Reflect)",
        "sources": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "bytes": p.stat().st_size} for p in map_scene.bundles],
        "outputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.iterdir()) if p.is_file() and p.name != "provenance.json"},
        "meshes": len(exporter.gltf["meshes"]), "materials": len(exporter.gltf["materials"]), "textures": len(exporter.gltf["textures"]),
        "vertices": totals["vertices"], "triangles": totals["triangles"],
        "textureGPUBytesRGBA8Mips": sum(gpu_bytes(t["outputWidth"], t["outputHeight"]) for t in exporter.source["textures"]),
        "shaders": shaders, "droppedTerms": dropped, "skipped": skipped, "lightmapUVSources": lightmap_sources,
        "lightmapsMode": lightmap_mode if lightmaps else None, "lightmaps": lightmaps, "lightmapExport": lightmap_export,
        "sunLightInfo": summarize_sun(map_scene, sun_tree, infos), "lights": lights_of(map_scene, active),
        "renderSettings": render_settings_of(map_scene),
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2, ensure_ascii=False) + "\n")
    return provenance


def texture_settings(texture):
    """m_TextureSettings (filter, anisotropy, mip bias, wrap) as serialized."""
    settings = getattr(texture, "m_TextureSettings", None)
    if settings is None:
        return None
    return {k: getattr(settings, k) for k in ("m_FilterMode", "m_Aniso", "m_MipBias", "m_WrapMode", "m_WrapU", "m_WrapV", "m_WrapW")
            if hasattr(settings, k)}


def export_lightmaps(map_scene, output):
    """Records every LightmapSettings entry and writes each light/direction map's serialized
    data verbatim. Returns (records, mode, export summary); the summary's "extras" is the glTF's
    `ikkokuLightmaps`, absent when the lightmaps cannot be drawn (the reason is recorded)."""
    records, mode, entries, problems = [], None, [], []
    for _, reader in map_scene.of_type("LightmapSettings"):
        settings = reader.read()
        mode = settings.m_LightmapsMode
        for index, data in enumerate(settings.m_Lightmaps):
            record, written = {"index": index}, {}
            for field in ("m_Lightmap", "m_DirLightmap", "m_ShadowMask"):
                pointer = getattr(data, field, None)
                if pointer is None or not pointer.path_id:
                    continue
                texture = pointer.read()
                record[field[2:]] = texture_record(texture, pointer)
                record[field[2:]]["textureSettings"] = texture_settings(texture)
                if field == "m_ShadowMask":
                    problems.append(f"lightmap {index}: a shadow mask is not drawn")
                    continue
                if field == "m_Lightmap" and record["Lightmap"]["lightmapFormat"] != RGBM_LIGHTMAP_FORMAT:
                    problems.append(f"lightmap {index}: m_LightmapFormat {record['Lightmap']['lightmapFormat']} is not RGBM")
                    continue
                raw = bytes(texture.image_data)
                fmt = BLOCK_FORMATS.get(int(texture.m_TextureFormat), ("raw", 0))[0].lower()
                name = f"lightmap-{index}-{'light' if field == 'm_Lightmap' else 'dir'}.{fmt}"
                try:
                    entry = lightmap_file_entry(record[field[2:]], name, raw)
                except ValueError as error:
                    problems.append(str(error))
                    continue
                if entry["sha256"] != record[field[2:]]["serializedSHA256"]:
                    raise ValueError(f"{name}: written data differs from the serialized image data")
                (output / name).write_bytes(raw)
                record[field[2:]]["output"] = name
                written[field] = entry
            records.append(record)
            if "m_Lightmap" in written:
                entries.append((index, written["m_Lightmap"], written.get("m_DirLightmap")))
            else:
                problems.append(f"lightmap {index}: no light map written")
    summary = {"written": [name for _, light, direction in entries for name in [light["file"]] + ([direction["file"]] if direction else [])],
               "problems": problems}
    if entries and not problems:
        try:
            summary["extras"] = lightmaps_extras(mode, entries)
        except ValueError as error:
            problems.append(str(error))
    return records, mode, summary


# What the app's Standard baked-lightmap material (map_fragment) leaves out; the app's
# status line names the same terms (SourceStudioMapStatus.lightmappedLabel).
LIGHTMAPPED_OMISSIONS = ["realtime sun and its shadows", "specular and reflections", "normal, metallic and detail maps",
                         "fog", "camera effects"]


def approximations(provenance):
    """The catalog's list of what the converted map does not reproduce. With lightmaps, the
    Standard terms the app leaves out are named one by one; any other shader is still listed
    as approximated."""
    if (provenance.get("lightmapExport") or {}).get("drawn"):
        notes = list(LIGHTMAPPED_OMISSIONS)
        others = [shader for shader in provenance.get("shaders", []) if shader != "Standard"]
        if others:
            notes.append("shaders approximated (" + ", ".join(others) + ")")
        return notes
    notes = ["no baked lightmaps", "map lights", "sun-type lighting", "fog", "ambient"]
    if provenance.get("droppedTerms"):
        notes.append("shaders approximated (" + ", ".join(provenance["shaders"]) + ")")
    return notes


def write_catalog(info_bundles, converted, output):
    """catalog.json: every Map_ row of the supplied info bundles by original number, with
    the converted glTF (relative to the catalog) or null."""
    tables, sources = read_tables(info_bundles)
    rows = catalog_rows(tables)
    by_no = {row["no"]: row for row in rows}
    output = output.resolve()
    for directory in converted:
        provenance = json.loads((directory / "provenance.json").read_text())
        number = provenance["mapNo"]
        if number not in by_no:
            raise ValueError(f"Converted map {number} is not in the supplied Map_ tables")
        if by_no[number]["scene"].casefold() != provenance["scene"].casefold():
            raise ValueError(f"Map {number} names scene {by_no[number]['scene']}, the export is {provenance['scene']}")
        gltf = directory.resolve() / (safe_name(provenance["scene"]) + ".gltf")
        by_no[number].update(file=str(gltf.relative_to(output.parent)), approximations=approximations(provenance),
                             conversion={k: provenance[k] for k in ("meshes", "materials", "textures", "vertices", "triangles",
                                                                     "textureGPUBytesRGBA8Mips", "shaders", "droppedTerms")},
                             provenanceSHA256=hashlib.sha256((directory / "provenance.json").read_bytes()).hexdigest())
    for row in rows:
        row.setdefault("file", None)
    catalog = {"version": 1, "kind": "ikkoku.sourceStudioMapCatalog",
               "coverage": "Map_ rows of the supplied studio/info bundles only; mods are not evaluated.",
               "sources": sources, "maps": rows}
    output.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    return catalog


def local_roots():
    """The ignored .local directory and the targets of symlinks placed directly in it (a
    worktree links its private folders to the main checkout's .local that way)."""
    local = REPO / ".local"
    links = [entry.resolve() for entry in local.iterdir() if entry.is_symlink()] if local.is_dir() else []
    return [local.resolve(), *links]


def private(path):
    resolved = path.resolve()
    if not any(resolved.is_relative_to(root) for root in local_roots()):
        raise ValueError("Source-derived output must stay in the repository's ignored .local directory")
    return resolved


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    inv = commands.add_parser("inventory", help="metadata-only inventory of one map scene bundle")
    inv.add_argument("--bundle", type=Path, action="append", required=True)
    inv.add_argument("--scene", required=True)
    inv.add_argument("--output", type=Path, required=True)
    exp = commands.add_parser("export", help="convert one map scene bundle to glTF")
    exp.add_argument("--bundle", type=Path, action="append", required=True)
    exp.add_argument("--scene", required=True)
    exp.add_argument("--map-no", type=int, required=True, help="the original Map_ number (catalog key)")
    exp.add_argument("--output", type=Path, required=True)
    exp.add_argument("--max-texture", type=int, help="reduce base textures by powers of two to at most this size")
    cat = commands.add_parser("catalog", help="write the runtime map catalog")
    cat.add_argument("--info-bundle", type=Path, action="append", required=True)
    cat.add_argument("--converted", type=Path, action="append", default=[], help="an export directory (repeatable)")
    cat.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "inventory":
        result = inventory(args.bundle, args.scene)
        private(args.output).parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps({k: result[k] for k in ("scene", "rendererCount", "drawnRendererCount", "triangles", "meshes",
                                                 "materialCount", "textureCount", "baseTextureGPUBytes", "shaders")}, indent=2))
    elif args.command == "export":
        result = export(args.bundle, args.scene, args.map_no, private(args.output), args.max_texture)
        print(json.dumps({k: result[k] for k in ("mapNo", "scene", "meshes", "materials", "textures", "vertices", "triangles",
                                                 "textureGPUBytesRGBA8Mips", "shaders", "droppedTerms")}, indent=2, ensure_ascii=False))
    else:
        catalog = write_catalog(args.info_bundle, args.converted, private(args.output))
        print(json.dumps({"maps": len(catalog["maps"]), "converted": [m["no"] for m in catalog["maps"] if m["file"]]}, indent=2))


if __name__ == "__main__":
    main()
