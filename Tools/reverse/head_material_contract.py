#!/usr/bin/env python3
"""Resolve head-00 default material inputs into ignored local evidence and PNGs.

Only named nonsexual face texture inputs are decoded. Derived base-color previews
use verified create_* equations with a documented color-space assumption. The
contract also records the normal-clothes create material and no-pattern row;
garment pixels are exported separately by source_texture_store.py. The optional
ordinary-body extension records metadata only, without decoding body pixels.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

import msgpack
import numpy as np
from PIL import Image
import UnityPy

REPO = Path(__file__).resolve().parents[2]
TABLES = {
    "bo_head_00": [("faceBase", "MainTexAB", "MainTex"), ("faceColorMask", "ColorMaskAB", "ColorMaskTex")],
    "mt_eye_00": [("pupilBase", "MainAB", "EyeTex")],
    "mt_eye_gradation_00": [("pupilGradientMask", "ColorMaskAB", "ColorMaskTex")],
    "mt_eye_hi_up_00": [("highlightUpper", "MainAB", "EyeHiUpTex")],
    "mt_eye_hi_down_00": [("highlightLower", "MainAB", "EyeHiDownTex")],
    "mt_eye_white_00": [("eyeWhiteBase", "MainAB", "EyeWhiteTex")],
    "mt_eyebrow_00": [("eyebrow", "MainAB", "EyebrowTex")],
    "mt_eyeline_up_00": [("eyelineUpper", "MainAB", "EyelineUpTex"), ("eyelineShadow", "MainAB", "EyelineShadowTex")],
    "mt_eyeline_down_00": [("eyelineLower", "MainAB", "EyelineDownTex")],
    "mt_nose_00": [("nose", "MainAB", "NoseTex")],
    "mt_face_detail_00": [("faceDetailNormal", "MainAB", "NormallMapDetail"), ("faceDetailLine", "MainAB", "LineMask")],
    "mt_mole_00": [("mole", "MainAB", "MoleTex")],
    "mt_cheek_00": [("cheek", "MainAB", "CheekTex")],
    "mt_lipline_00": [("lipLine", "MainAB", "LiplineTex")],
    "mt_lip_00": [("lipMakeup", "MainAB", "LipTex")],
    "mt_eyeshadow_00": [("eyeShadow", "MainAB", "EyeshadowTex")],
    "mt_face_paint_00": [("facePaint", "MainAB", "PaintTex")],
    # ChangeCustomClothes selects no pattern texture for this recorded row.
    "mt_pattern_00": [],
}
CREATORS = {"cf_m_face_create", "cf_m_eye_create", "cf_m_eyewhite_create", "cf_m_clothesN_create"}
BODY_TABLES = {"mt_body_paint_00": [], "mt_sunburn_00": [], "bodypaint_layout_00": []}
BODY_TEXTURES = {"chara/oo_base.unity3d": ["cf_body_00_t", "cf_body_00_mc"],
                 "chara/mm_base.unity3d": ["cf_body_01_mp"]}
VERIFIED_PROGRAMS = {
    "Shader Forge/create_head": "9ec842e7b29577b0fd4ddb8ffcfc25c288471210b90ab7a312c3e7a9225df72c",
    "Shader Forge/create_eye": "c4bd7e1ec704b84075a666316519230ce163e1f4540be2af7ed25b9f3934fece",
    "Shader Forge/create_eyewhite": "4f4f69fd421ab35d9e380e418ae04b22ac88852cad0ecf6c63f75285c895b1f9",
    "Shader Forge/create_topN": "d709d6fc92ebecd4f8b579041c8a7abce3a13c20c18985812bde6bc42881f579",
    "Shader Forge/create_body": "6dec09eabb8464f6b79b6a97e978631187ca77d992a99de1a6d0fd9ffc43e1c5",
}
# Extra masks and neutral mouth/tear inputs used by the head's authored materials.
EXTRA_TEXTURES = {"chara/bo_head_00.unity3d": ["cf_face_00_md", "cf_face_00_md2", "cf_t_tooth_00",
                                              "cf_tang_md", "cf_tang_n", "cf_namida_00_t"],
                  "chara/mm_base.unity3d": ["cf_face_00_mp"]}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(reader) -> dict:
    return {"serializedFile": reader.assets_file.name, "pathID": str(reader.path_id)}


def reference(pointer) -> dict | None:
    if not pointer.path_id:
        return None
    try:
        reader = pointer.deref()
        return {**identity(reader), "type": reader.type.name, "name": reader.peek_name()}
    except Exception as error:
        return {"fileID": pointer.file_id, "pathID": str(pointer.path_id), "unresolved": str(error)}


def material(reader) -> dict:
    value = reader.read()
    shader = value.m_Shader.read_typetree()
    parsed = shader.get("m_ParsedForm", {})
    passes = []
    for sub_index, sub in enumerate(parsed.get("m_SubShaders", [])):
        for item in sub.get("m_Passes", []):
            state = item["m_State"]
            passes.append({"subshader": sub_index, "name": state["m_Name"],
                           "tags": dict(state["m_Tags"]["tags"]),
                           "state": {k: state[k] for k in ("zTest", "zWrite", "culling", "alphaToMask", "stencilRef", "stencilReadMask", "stencilWriteMask", "stencilOp")},
                           "blend": state["rtBlend0"]})
    properties = value.m_SavedProperties
    return {"name": value.m_Name, **identity(reader), "shader": parsed.get("m_Name", shader.get("m_Name")),
            "shaderSourceAvailable": bool(shader.get("m_Script")), "renderQueue": value.m_CustomRenderQueue,
            "passes": passes, "floats": dict(properties.m_Floats),
            "colors": {k: [v.r, v.g, v.b, v.a] for k, v in properties.m_Colors},
            "textures": {k: {"texture": reference(v.m_Texture), "scale": [v.m_Scale.x, v.m_Scale.y],
                              "offset": [v.m_Offset.x, v.m_Offset.y]} for k, v in properties.m_TexEnvs}}


def body_texture_metadata(by_bundle: dict, root: Path) -> list[dict]:
    """Identity/format only. Body pixels and samplers use the isolated store producer."""
    records = []
    for bundle, names in BODY_TEXTURES.items():
        for name in names:
            matches = [obj for obj in by_bundle[root / bundle].objects
                       if obj.type.name == "Texture2D" and obj.peek_name() == name]
            if len(matches) != 1:
                raise ValueError(f"Expected one {name} texture in {bundle}, found {len(matches)}")
            reader = matches[0]
            texture = reader.read()
            records.append({"name": name, "bundle": bundle, **identity(reader),
                            "width": texture.m_Width, "height": texture.m_Height,
                            "format": int(texture.m_TextureFormat), "serializedColorSpace": texture.m_ColorSpace,
                            "metadataOnly": True})
    return records


def verify_create_shader(reader, output: Path) -> dict:
    from UnityPy.export.ShaderConverter import ShaderProgram
    from UnityPy.helpers import CompressionHelper
    from UnityPy.streams import EndianBinaryReader

    shader = reader.read().m_Shader.read()
    name = shader.m_ParsedForm.m_Name
    if shader.platforms != [4]:
        raise ValueError("Expected the observed D3D11 source shader platform")
    raw = CompressionHelper.decompress_lz4(bytes(shader.compressedBlob)[shader.offsets[0]:shader.offsets[0] + shader.compressedLengths[0]], shader.decompressedLengths[0])
    program = ShaderProgram(EndianBinaryReader(raw, endian="<"), shader.object_reader.version)
    forward = next(p for p in shader.m_ParsedForm.m_SubShaders[0].m_Passes if p.m_State.m_Name == "FORWARD")
    index = forward.progFragment.m_SubPrograms[0].m_BlobIndex
    code = bytes(program.m_SubPrograms[index].m_ProgramCode)
    offset = code.find(b"DXBC")
    if offset < 0 or offset + 28 > len(code):
        raise ValueError("Expected a complete DXBC shader header")
    size = struct.unpack_from("<I", code, offset + 24)[0]
    if size < 32 or offset + size > len(code):
        raise ValueError("Invalid DXBC container length")
    code = code[offset:offset + size]
    sha = hashlib.sha256(code).hexdigest()
    if VERIFIED_PROGRAMS.get(name) != sha:
        raise ValueError(f"Unverified {name} program; recover equations before baking this source version")
    if name == "Shader Forge/create_body":
        # The body extension does not bake a CPU preview. It records the exact
        # fragment program for separate translation and independent GPU gates.
        for variant in forward.progFragment.m_SubPrograms:
            other = bytes(program.m_SubPrograms[variant.m_BlobIndex].m_ProgramCode)
            start = other.find(b"DXBC")
            if start < 0 or start + 28 > len(other):
                raise ValueError("Expected a complete body fragment DXBC header")
            length = struct.unpack_from("<I", other, start + 24)[0]
            if length < 32 or start + length > len(other) or other[start:start + length] != code:
                raise ValueError("Body fragment variants differ from the recorded program")
    shader_dir = output / "shaders"; shader_dir.mkdir(exist_ok=True)
    filename = f"{name.split('/')[-1]}-forward-{index}.dxbc"
    (shader_dir / filename).write_bytes(code)
    return {"shader": name, "forwardBlobIndex": index, "programSHA256": sha, "file": "shaders/" + filename}


def create_head_base(main: np.ndarray, mask: np.ndarray, primary: np.ndarray, secondary: np.ndarray) -> np.ndarray:
    """Recovered create_head PS prefix with ID0 (absent) makeup layers."""
    tinted = (1 + mask[..., 0:1] * (primary[:3] - 1)) * (1 + mask[..., 1:2] * (secondary[:3] - 1))
    rgb = main[..., :3] * np.maximum(mask[..., 2:3], tinted)
    return np.concatenate((rgb, np.ones_like(main[..., 3:4])), axis=-1)


def create_eye_base(main: np.ndarray, primary: np.ndarray, blend: float) -> np.ndarray:
    """ID0's all-white gradient selects primary; include source blit blending."""
    value = main[..., 0:1]
    with np.errstate(divide="ignore", invalid="ignore"):
        nonlinear = np.where(value > 0.5, primary[:3] / (2 * (1 - value)), 1 - (1 - primary[:3]) / (2 * value))
    nonlinear = np.clip(np.nan_to_num(nonlinear, nan=0, posinf=1, neginf=0), 0, 1)
    product = primary[:3] * value
    rgb = product + blend * (nonlinear - product)
    alpha = main[..., 3:4] * primary[3]
    # CustomTextureCreate clears transparent, then the serialized create_eye pass
    # uses SrcAlpha/OneMinusSrcAlpha for RGB *and* alpha (no separate alpha blend).
    return np.concatenate((rgb * alpha, alpha * alpha), axis=-1)


def create_eye_white(main: np.ndarray, primary: np.ndarray, secondary: np.ndarray) -> np.ndarray:
    rgb = secondary[:3] + main[..., 0:1] * (primary[:3] - secondary[:3])
    return np.concatenate((rgb, np.ones_like(main[..., 3:4])), axis=-1)


def previews(output: Path, inputs: list[dict], creators: list[dict]) -> list[dict]:
    materials = {item["name"]: item for item in creators}
    sources = {item["role"]: item for item in inputs}

    def pixels(role: str) -> np.ndarray:
        return np.asarray(Image.open(output / sources[role]["texture"]["file"]).convert("RGBA"), dtype=np.float32) / 255

    def color(name: str, prop: str) -> np.ndarray:
        return np.asarray(materials[name]["colors"][prop], dtype=np.float32)

    # This explicit recipe is a source-authored preview, not ChaFile constructor
    # defaults or an inferred startup card. ID0 has no cheek/lip/paint/mole layers.
    disabled = ("cheek", "lipLine", "facePaint", "mole")
    if any(sources[role]["texture"] is not None for role in disabled):
        raise ValueError("Base-only head bake requires absent ID0 makeup layers")
    gradient = pixels("pupilGradientMask")
    if not np.all(gradient[..., 0] == 1):
        raise ValueError("Supported ID0 eye recipe requires the observed constant-white gradient mask")
    main, mask = pixels("faceBase"), pixels("faceColorMask")
    if main.shape != mask.shape:
        raise ValueError("Head base/mask dimensions differ; explicit sampler reconstruction required")
    face = create_head_base(main, mask, color("cf_m_face_create", "_Color"), color("cf_m_face_create", "_Color2"))
    eye = create_eye_base(pixels("pupilBase"), color("cf_m_eye_create", "_Color"), materials["cf_m_eye_create"]["floats"]["_Blend"])
    white = create_eye_white(pixels("eyeWhiteBase"), color("cf_m_eyewhite_create", "_Color"), color("cf_m_eyewhite_create", "_Color2"))
    records = []
    for role, data, filename, shader, used in [
        ("faceBase", face, "preview_face_base.png", "create_head", ["faceBase", "faceColorMask"]),
        ("pupilBase", eye, "preview_eye_base.png", "create_eye", ["pupilBase", "pupilGradientMask"]),
        ("eyeWhiteBase", white, "preview_eye_white.png", "create_eyewhite", ["eyeWhiteBase"]),
    ]:
        if not np.all(np.isfinite(data)):
            raise ValueError(f"Nonfinite preview shader output for {role}")
        Image.fromarray(np.rint(np.clip(data, 0, 1) * 255).astype(np.uint8)).save(output / filename)
        records.append({"role": role, "file": filename, "shader": shader, "pngSHA256": digest(output / filename),
                        "inputs": [sources[name]["texture"]["file"] for name in used],
                        "colorSelection": "Serialized source create-material colors, with catalog ID0 textures",
                        "colorSpaceAssumption": "Byte-normalized RGB arithmetic; source GL.sRGBWrite and project color-space conversion are not reproduced",
                        "lightingParity": False,
                        "limitations": ["No eye highlights, gaze, or runtime material transforms are baked.",
                                        "No makeup overlays are selected.",
                                        "Native sampler/quantization and sRGB conversion may differ from Unity."]})
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=REPO / ".local/reverse/rigs/source/abdata")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/rigs/head-materials")
    parser.add_argument("--body-composite", action="store_true",
                        help="Include ordinary female body creator/input/catalog metadata, without decoding body pixels")
    args = parser.parse_args()
    output, root = args.output.resolve(), args.source.resolve()
    if not output.is_relative_to((REPO / ".local").resolve()):
        parser.error("Extracted source material data and PNGs must remain under ignored .local")
    output.mkdir(parents=True, exist_ok=True)
    table_path = root / "list/characustom/00.unity3d"
    tables = {**TABLES, **(BODY_TABLES if args.body_composite else {})}
    rows, inputs = [], []
    for obj in UnityPy.load(str(table_path)).objects:
        if obj.type.name != "TextAsset" or obj.peek_name() not in tables:
            continue
        data = obj.read()
        raw = data.m_Script.encode("utf-8", "surrogateescape")
        table = msgpack.unpackb(raw, strict_map_key=False)
        if table.get("mark") != "【ChaListData】" or 0 not in table["dictList"]:
            raise ValueError(f"Unexpected catalog schema or missing ID0 in {data.m_Name}")
        row = dict(zip(table["lstKey"], table["dictList"][0], strict=True))
        rows.append({"table": data.m_Name, "category": table["categoryNo"], "selectedID": 0,
                     "row": row, **identity(obj)})
        for role, bundle_key, asset_key in tables[data.m_Name]:
            inputs.append({"role": role, "category": table["categoryNo"], "id": 0,
                           "bundle": row[bundle_key], "asset": row[asset_key]})
    if {row["table"] for row in rows} != set(tables):
        raise ValueError("A required ID0 catalog table is absent")
    bundles = {table_path, root / "chara/bo_head_00.unity3d", root / "chara/mm_base.unity3d"}
    if args.body_composite:
        bundles.update(root / bundle for bundle in BODY_TEXTURES)
    bundles.update(root / entry["bundle"] for entry in inputs if entry["bundle"] != "0")
    missing = sorted(str(path) for path in bundles if not path.is_file())
    if missing:
        raise ValueError(f"Fetch these exact dependencies before exporting: {missing}")
    env = UnityPy.load(*[str(path) for path in sorted(bundles)])
    # Resolve by explicit source bundle and container suffix; no global name guessing.
    by_bundle = {path: UnityPy.load(str(path)) for path in bundles if path != table_path}
    exported: dict[tuple[str, int], dict] = {}

    def export(bundle: str, name: str) -> dict:
        matches = [obj for obj in by_bundle[root / bundle].objects
                   if obj.type.name == "Texture2D" and obj.peek_name() == name]
        if len(matches) != 1:
            raise ValueError(f"Expected one {name} texture in {bundle}, found {len(matches)}")
        obj = matches[0]; key = (obj.assets_file.name, obj.path_id)
        if key not in exported:
            texture = obj.read()
            filename = re.sub(r"[^A-Za-z0-9_.-]", "_", name) + ".png"
            image = texture.image
            image.save(output / filename)
            rgba = image.convert("RGBA")
            record = {"name": name, "bundle": bundle, **identity(obj), "file": filename,
                      "width": texture.m_Width, "height": texture.m_Height, "format": int(texture.m_TextureFormat),
                      "serializedColorSpace": texture.m_ColorSpace,
                      "channelExtrema": rgba.getextrema(), "pngSHA256": digest(output / filename),
                      "conversion": "UnityPy upright PNG; source UV must map v to 1-v"}
            exported[key] = record
        return exported[key]

    for entry in inputs:
        entry["texture"] = None if entry["bundle"] == "0" or entry["asset"] == "0" else export(entry["bundle"], entry["asset"])
    for bundle, names in EXTRA_TEXTURES.items():
        for name in names:
            export(bundle, name)
    prefab_key = "assets/illusion/assetbundle/chara/head/00/bo_head_00/p_cf_head_00.prefab"
    prefab = env.container[prefab_key].read()
    materials, renderers = {}, []

    def visit(go) -> None:
        for component in go.m_Component:
            if component.component.type.name == "SkinnedMeshRenderer":
                renderer = component.component.read()
                for pointer in renderer.m_Materials:
                    reader = pointer.deref(); materials[(reader.assets_file.name, reader.path_id)] = material(reader)
                submesh_count = len(renderer.m_Mesh.read().m_SubMeshes)
                if len(renderer.m_Materials) != submesh_count and submesh_count != 1:
                    raise ValueError("Unverified extra-material behavior on a multi-submesh head mesh")
                renderers.append({"nodeName": go.m_Name, "activeSelf": go.m_IsActive, "enabled": renderer.m_Enabled,
                                  "mesh": reference(renderer.m_Mesh), "submeshCount": submesh_count,
                                  "materialSlots": [reference(p) for p in renderer.m_Materials],
                                  "draws": [{"materialSlot": index, "submesh": 0 if submesh_count == 1 else index}
                                            for index in range(len(renderer.m_Materials))]})
        transform = next(p.component.read() for p in go.m_Component if p.component.type.name == "Transform")
        for child in transform.m_Children:
            visit(child.read().m_GameObject.read())

    visit(prefab)
    creator_names = CREATORS | ({"cf_m_body_create"} if args.body_composite else set())
    creator_readers = [obj for obj in env.objects if obj.type.name == "Material" and obj.peek_name() in creator_names]
    verified_shaders = [verify_create_shader(obj, output) for obj in creator_readers]
    creators = [material(obj) for obj in creator_readers]
    result = {"schemaVersion": 1, "scope": "Original head00 ID0 inputs and base previews; source shader lighting is not implemented",
              "sources": [{"path": str(path), "bytes": path.stat().st_size, "sha256": digest(path)} for path in sorted(bundles)],
              "catalogRows": rows, "defaultInputs": inputs,
              "textures": list(exported.values()) + (body_texture_metadata(by_bundle, root) if args.body_composite else []),
              "drawMaterials": list(materials.values()), "createMaterials": creators, "renderers": renderers,
              "verifiedCreateShaders": verified_shaders,
              "derivedPreviews": previews(output, inputs, creators),
              "limitations": ["Constructor defaults differ from serialized prefab defaults and from sample cards.",
                              "Derived base previews use recovered shader equations with an explicit color-space assumption; raw inputs remain separate.",
                              "Tags and blend/depth/cull/stencil states are extracted; main_skin coverage is verified, but full lighting is not implemented.",
                              "No fluid, body, or sexual textures are decoded or exported."]}
    (output / "contract.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(output), "textures": len(exported), "materials": len(materials), "renderers": len(renderers)}))


if __name__ == "__main__":
    main()
