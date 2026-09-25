#!/usr/bin/env python3
"""Bake a bounded source-authored clothes/hair preview using hash-verified shaders.

All input textures, material records, shader bytecode, and derived previews stay in
ignored .local/. This recovers albedo composition, not original lighting or color space.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import time

import msgpack
import numpy as np
from PIL import Image
import UnityPy

from head_material_contract import material

ROOT = Path(__file__).resolve().parents[2]
LOCAL = ROOT / ".local/reverse/rigs"
PROGRAMS = {
    "Shader Forge/create_topN": "d709d6fc92ebecd4f8b579041c8a7abce3a13c20c18985812bde6bc42881f579",
    "Shader Forge/create_hair": "1b50b594b6e0c323865034096806c9fa488644eb5b27bc95c9e60943f7971cfe",
    "Shader Forge/main_hair": "05bcdcb592774cdd1b8b8fb225282786bc98ec7e2a0bc01dc6287536865db708",
    "Shader Forge/main_hair_front": "e75b1604bbc7d00a7b3705a51068b1201440db919e1c011b4ca32fe75bfad872",
}
CLOTHES = [
    ("top", "p_o_top_tsyatu02", "cf_top_tsyatu02_t", "cf_top_tsyatu02_mc"),
    ("pants", "p_o_bot_pants03", "cf_bot_pants03_t", "cf_bot_pants03_mc"),
    ("shoes", "p_o_shoes_run01", "cf_shoes_run01_t", "cf_shoes_run01_mc"),
]
HAIR = [
    ("hair_back", "p_cf_hair_b_03", "cf_hair_b_03_00_mc", "cf_m_hair_b_03_00", "hair-back-rig-materials.json"),
    ("hair_front", "p_cf_hair_f_01", "cf_hair_f_01_00_mc", "cf_m_hair_f_01_00", "hair-front-rig-materials.json"),
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evidence(path: Path) -> dict:
    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": digest(path)}


def ordered_tint(mask: np.ndarray, colors: np.ndarray) -> np.ndarray:
    """Verified RGB layer priority shared by create_topN/create_hair/main_hair*."""
    rgb = 1 + mask[..., 0:1] * (colors[0, :3] - 1)
    rgb += mask[..., 1:2] * (colors[1, :3] - rgb)
    rgb += mask[..., 2:3] * (colors[2, :3] - rgb)
    return rgb


def clothes_base(main: np.ndarray, mask: np.ndarray, colors: np.ndarray) -> np.ndarray:
    """No patterns: white default samples select each base color exactly.

    The shader clamps input RGB, outputs main alpha, then blends SrcAlpha onto clear
    for RGB and alpha. This is the stored RenderTexture value before sRGB conversion.
    """
    alpha = main[..., 3:4]
    rgb = np.clip(main[..., :3], 0, 1) * ordered_tint(mask, colors)
    return np.concatenate((rgb * alpha, alpha * alpha), axis=-1)


def hair_base(mask: np.ndarray, colors: np.ndarray) -> np.ndarray:
    """Selected source hair uses null MainTex/AlphaMask with verified white defaults."""
    return np.concatenate((ordered_tint(mask, colors), np.ones_like(mask[..., 3:4])), axis=-1)


def disassemble(blob: bytes, path: Path, vm: str) -> None:
    from vm_source import powershell, ps_quote
    # Independent API glue, not recovered game code. Offset writes make retries idempotent.
    native = r'''using System;using System.Runtime.InteropServices;
public static class ClothedShaderDisasm {
[DllImport("d3dcompiler_47.dll",CallingConvention=CallingConvention.StdCall)] static extern int D3DDisassemble(byte[] b,UIntPtr n,uint f,string c,out IntPtr o);
[UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr PtrFunc(IntPtr p);
[UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate UIntPtr SizeFunc(IntPtr p);
public static string Read(byte[] b){IntPtr p;int hr=D3DDisassemble(b,(UIntPtr)b.Length,0,null,out p);if(hr<0)Marshal.ThrowExceptionForHR(hr);try{IntPtr vt=Marshal.ReadIntPtr(p);var ptr=(PtrFunc)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt,3*IntPtr.Size),typeof(PtrFunc));var size=(SizeFunc)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt,4*IntPtr.Size),typeof(SizeFunc));int n=(int)size(p).ToUInt64();byte[] o=new byte[n];Marshal.Copy(ptr(p),o,0,n);return Convert.ToBase64String(o);}finally{Marshal.Release(p);}}}'''

    def run(script: str) -> str:
        for attempt in range(3):
            try:
                return powershell(vm, script)
            except RuntimeError:
                if attempt == 2:
                    raise
                time.sleep(1)
        raise AssertionError("unreachable")

    name = "ikkoku-clothed-" + hashlib.sha256(blob).hexdigest()[:12] + ".b64"
    prefix = "$ErrorActionPreference='Stop';$f=Join-Path $env:TEMP " + ps_quote(name) + ";"
    encoded = base64.b64encode(blob).decode()
    run(prefix + "[IO.File]::WriteAllText($f,'')")
    try:
        for offset in range(0, len(encoded), 600):
            run(prefix + "$b=[Text.Encoding]::ASCII.GetBytes(" + ps_quote(encoded[offset:offset + 600])
                + ");$s=[IO.File]::OpenWrite($f);try{$s.Position=" + str(offset)
                + ";$s.Write($b,0,$b.Length)}finally{$s.Close()}")
        result = run(prefix + "Add-Type -TypeDefinition " + ps_quote(native)
                     + ";[ClothedShaderDisasm]::Read([Convert]::FromBase64String([IO.File]::ReadAllText($f)))")
        path.write_text(base64.b64decode(result, validate=True).decode("ascii").rstrip("\x00"))
    finally:
        run(prefix + "[IO.File]::Delete($f)")


def shader_contract(reader, output: Path, vm: str | None) -> dict:
    from UnityPy.export.ShaderConverter import ShaderProgram
    from UnityPy.helpers import CompressionHelper
    from UnityPy.streams import EndianBinaryReader
    shader = reader.read().m_Shader.read()
    tree = reader.read().m_Shader.read_typetree()
    name = shader.m_ParsedForm.m_Name
    if shader.platforms != [4]:
        raise ValueError("Expected observed D3D11 shader platform")
    raw = CompressionHelper.decompress_lz4(bytes(shader.compressedBlob)[shader.offsets[0]:shader.offsets[0] + shader.compressedLengths[0]], shader.decompressedLengths[0])
    program = ShaderProgram(EndianBinaryReader(raw, endian="<"), shader.object_reader.version)
    forward = next(p for p in tree["m_ParsedForm"]["m_SubShaders"][0]["m_Passes"] if p["m_State"]["m_Name"] == "FORWARD")
    fragment = forward["progFragment"]["m_SubPrograms"][0]
    index = fragment["m_BlobIndex"]
    code = bytes(program.m_SubPrograms[index].m_ProgramCode)
    start = code.find(b"DXBC")
    if start < 0 or start + 28 > len(code):
        raise ValueError("Missing DXBC container")
    size = struct.unpack_from("<I", code, start + 24)[0]
    if size < 32 or start + size > len(code):
        raise ValueError("Truncated DXBC container")
    blob = code[start:start + size]
    sha = hashlib.sha256(blob).hexdigest()
    if PROGRAMS.get(name) != sha:
        raise ValueError(f"Unverified {name} shader; recover this source revision before baking")
    folder = output / "shaders"; folder.mkdir(exist_ok=True)
    filename = f"{name.split('/')[-1]}-forward-{index}"
    binary = folder / (filename + ".dxbc"); binary.write_bytes(blob)
    (folder / (name.split("/")[-1] + ".json")).write_text(json.dumps(tree, indent=2))
    (folder / (name.split("/")[-1] + "-fragment.json")).write_text(json.dumps(fragment, indent=2))
    asm = binary.with_suffix(".asm")
    if vm:
        disassemble(blob, asm, vm)
    names = {index: name for name, index in forward["m_NameIndices"]}
    result = {"shader": name, "forwardBlobIndex": index, "programSHA256": sha, "file": "shaders/" + binary.name,
              "textures": {names[p["m_NameIndex"]]: p["m_Index"] for p in fragment["m_TextureParams"]},
              "constants": {names[p["m_NameIndex"]]: p["m_Index"] for cb in fragment["m_ConstantBuffers"] for p in cb["m_VectorParams"]},
              "defaults": {p["m_Name"]: p.get("m_DefTexture", {}).get("m_DefaultName") for p in tree["m_ParsedForm"]["m_PropInfo"]["m_Props"] if p["m_Type"] == 4},
              "material": material(reader)}
    if asm.exists():
        result["disassembly"] = evidence(asm)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=LOCAL / "clothed-materials/manifest.json")
    parser.add_argument("--source", type=Path, default=LOCAL / "source/abdata")
    parser.add_argument("--output", type=Path, default=LOCAL / "clothed-materials")
    parser.add_argument("--disassemble-vm", help="Optional running Parallels VM UUID; regenerate ignored DXBC assembly evidence")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / ".local"):
        parser.error("Derived game material output must stay in ignored .local/")
    output.mkdir(parents=True, exist_ok=True)
    raw_manifest = json.loads(args.manifest.read_text())
    if raw_manifest.get("kind") != "raw-selected-source-material-inputs" or raw_manifest.get("compositionApplied") is not False:
        raise ValueError("Expected raw selected source material inputs")
    entries = {item["prefab"]: item for item in raw_manifest["entries"]}
    if len(entries) != len(raw_manifest["entries"]):
        raise ValueError("Ambiguous selected prefabs")
    source_files = [evidence(args.manifest)]
    for item in entries.values():
        bundle = ROOT / item["bundle"]
        if digest(bundle) != item["bundleSHA256"]:
            raise ValueError(f"Bundle digest mismatch: {bundle}")
        source_files.append(evidence(bundle))
    mm = args.source / "chara/mm_base.unity3d"
    environments = {"mm_base": UnityPy.load(str(mm))}
    source_files.append(evidence(mm))
    shaders = {}
    for bundle, material_name in [("mm_base", "cf_m_clothesN_create"), ("mm_base", "cf_m_hair_create"),
                                  ("bo_hair_b_00", "cf_m_hair_b_03_00"), ("bo_hair_f_00", "cf_m_hair_f_01_00")]:
        if bundle not in environments:
            environments[bundle] = UnityPy.load(str(args.source / "chara" / (bundle + ".unity3d")))
        matches = [o for o in environments[bundle].objects if o.type.name == "Material" and o.peek_name() == material_name]
        if len(matches) != 1:
            raise ValueError(f"Expected one material {material_name}")
        shaders[material_name] = shader_contract(matches[0], output, args.disassemble_vm)

    table_path = args.source / "list/characustom/00.unity3d"
    tables = [o for o in UnityPy.load(str(table_path)).objects if o.type.name == "TextAsset" and o.peek_name() == "mt_pattern_00"]
    if len(tables) != 1:
        raise ValueError("Expected original pattern catalog")
    table = msgpack.unpackb(tables[0].read().m_Script.encode("utf-8", "surrogateescape"), strict_map_key=False)
    row = dict(zip(table["lstKey"], table["dictList"][0], strict=True))
    if row["MainTexAB"] != "0" or row["MainTex"] != "0":
        raise ValueError("Pattern ID0 must select no texture")
    source_files.append(evidence(table_path))
    creator = shaders["cf_m_clothesN_create"]
    if any(creator["defaults"].get(name) != "white" for name in ["_PatternMask1", "_PatternMask2", "_PatternMask3"]):
        raise ValueError("Pattern fallback changed")
    blend = creator["material"]["passes"][0]["blend"]
    if [blend[k]["val"] for k in ["srcBlend", "destBlend", "srcBlendAlpha", "destBlendAlpha"]] != [5, 10, 5, 10]:
        raise ValueError("Unsupported clothes compositor blend state")

    def pixels(entry: dict, name: str) -> np.ndarray:
        matches = [v for v in entry["textures"] if v["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"Expected one raw input {name}")
        record = matches[0]; path = args.manifest.parent / record["file"]
        if digest(path) != record["sha256"]:
            raise ValueError(f"Input texture digest mismatch: {path}")
        source_files.append(evidence(path))
        return np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32) / 255

    records = []

    def save(role: str, data: np.ndarray, colors: np.ndarray, program: dict, used: list[str], selection: str) -> None:
        if not np.all(np.isfinite(data)):
            raise ValueError("Nonfinite material composition")
        filename = "preview_" + role + "_base.png"
        Image.fromarray(np.rint(np.clip(data, 0, 1) * 255).astype(np.uint8)).save(output / filename)
        records.append({"role": role, "file": filename, "pngSHA256": digest(output / filename), "inputs": used,
                        "shader": program["shader"], "programSHA256": program["programSHA256"], "colors": colors.tolist(),
                        "colorSelection": selection, "lightingParity": False,
                        "colorSpaceAssumption": "Byte-normalized RGB arithmetic; Unity project color space, texture sRGB sampling and GL.sRGBWrite=true conversion are not reproduced"})

    for role, prefab, main_name, mask_name in CLOTHES:
        entry = entries[prefab]
        if len(entry["componentColors"]) != 1:
            raise ValueError("Ambiguous clothes component colors")
        component = entry["componentColors"][0]
        colors = np.asarray([[component[f"defMainColor0{i}"][axis] for axis in "rgba"] for i in range(1, 4)], dtype=np.float32)
        main, mask = pixels(entry, main_name), pixels(entry, mask_name)
        if main.shape != mask.shape:
            raise ValueError("Input dimensions differ; explicit sampling reconstruction required")
        save(role, clothes_base(main, mask, colors), colors, creator, [main_name, mask_name], "Source prefab component default colors, explicit no-pattern ID0 preview")

    for role, prefab, mask_name, material_name, record_file in HAIR:
        entry, program = entries[prefab], shaders[material_name]
        record_path = args.manifest.parent.parent / record_file
        records_in = json.loads(record_path.read_text())
        matches = [m for node in records_in for m in node["materials"] if m["name"] == material_name]
        values = {json.dumps(m["tree"]["m_SavedProperties"], sort_keys=True) for m in matches}
        if len(values) != 1:
            raise ValueError("Ambiguous selected hair material")
        properties = json.loads(next(iter(values)))
        color_records, textures = dict(properties["m_Colors"]), dict(properties["m_TexEnvs"])
        colors = np.asarray([[color_records[name][axis] for axis in "rgba"] for name in ["_Color", "_Color2", "_Color3"]], dtype=np.float32)
        for name in ["_MainTex", "_AlphaMask"]:
            if textures[name]["m_Texture"]["m_PathID"] != 0 or program["defaults"].get(name) != "white":
                raise ValueError("Selected hair bake requires verified white main/alpha defaults")
        uv = textures["_ColorMask"]
        if uv["m_Scale"] != {"x": 1.0, "y": 1.0} or uv["m_Offset"] != {"x": 0.0, "y": 0.0}:
            raise ValueError("Hair mask transform needs explicit resampling")
        source_files.append(evidence(record_path))
        save(role, hair_base(pixels(entry, mask_name), colors), colors, program, [mask_name], "Serialized selected source hair material colors; runtime card colors not inferred")

    for name in ["ChaControl.cs", "CustomTextureCreate.cs"]:
        path = ROOT / ".local/reverse/decompiled/Character/Koikatu" / name
        source_files.append(evidence(path))
    result = {"schemaVersion": 1, "kind": "source-selected-clothed-albedo-preview", "compositionApplied": True,
              "previews": records, "shaderEvidence": list(shaders.values()), "patternSelection": {"id": 0, "row": row},
              "sourceEvidence": source_files,
              "limits": ["RGB composition only; source lighting, detail normals, strand gloss, ramps and view-dependent terms are not ported.",
                         "No clothing patterns or runtime character-card colors are selected.",
                         "Byte-normalized color arithmetic is approximate until original color-space configuration is reproduced.",
                         "Hair ribbon accessory material is excluded; original main_item composition remains unported.",
                         "Use baked PNG with white base color and no native color-mask tint, to avoid applying colors twice."]}
    (output / "composition.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"previewCount": len(records), "manifest": str(output / "composition.json"), "files": [r["file"] for r in records]}, indent=2))


if __name__ == "__main__":
    main()
