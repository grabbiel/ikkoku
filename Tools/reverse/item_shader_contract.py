#!/usr/bin/env python3
"""Record FORWARD pass/variant/binding evidence for the Studio item shaders.

The basic-shape studio props (p_koi_stu_cube01_02 / p_koi_stu_cylinder00_02) use
Shader Forge/main_item_studio and main_item_studio_alpha. This re-derives the pass
states, pixel variants, bindings and DXBC blobs from the studio bundles, and with a
running VM disassembles each FORWARD pixel program in place of guessing. Derived
evidence stays in ignored .local/reverse/shaders/.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import time
from pathlib import Path

import vm_source
from clothed_material_contract import disassemble, evidence

PRIVATE = Path("/Users/rumpology/code/repo/ikkoku/.local/reverse")
# studio/00.unity3d basic-shape materials: (material, expected shader, evidence prefix).
MATERIALS = [
    ("m_koi_stu_kihon00_02", "Shader Forge/main_item_studio", "item-studio"),
    ("m_koi_stu_kihon01_02", "Shader Forge/main_item_studio_alpha", "item-studio-alpha"),
]
# Decompressed D3D11 program blob digests observed in studio/mat/00.unity3d.
PROGRAMS = {
    "Shader Forge/main_item_studio": "1464352c9bf75e19b198434a92b4610bfe22309963c594a5c7bad4de5f6efcfa",
    "Shader Forge/main_item_studio_alpha": "c2efabe204f38ba977b2c15bab09f7056410adf778f1a9d2ac6ade05c40cc0dd",
}


def state_summary(pass_dict: dict) -> dict:
    state = pass_dict["m_State"]
    blend = state["rtBlend0"]
    return {"name": state["m_Name"], "culling": state["culling"], "zTest": state["zTest"], "zWrite": state["zWrite"],
            "blend": {key: blend[key]["val"] for key in ("srcBlend", "destBlend", "srcBlendAlpha", "destBlendAlpha")}}


def dxbc_container(code: bytes) -> bytes:
    start = code.find(b"DXBC")
    if start < 0 or start + 28 > len(code):
        raise ValueError("Missing DXBC container")
    size = struct.unpack_from("<I", code, start + 24)[0]
    if size < 32 or start + size > len(code):
        raise ValueError("Truncated DXBC container")
    return code[start:start + size]


def shader_evidence(reader, prefix: str, output: Path, bundles: list[Path], vm: str | None) -> dict:
    from UnityPy.export.ShaderConverter import ShaderProgram
    from UnityPy.helpers import CompressionHelper
    from UnityPy.streams import EndianBinaryReader
    shader = reader.read().m_Shader.read()
    tree = reader.read().m_Shader.read_typetree()
    name = shader.m_ParsedForm.m_Name
    if shader.platforms != [4]:
        raise ValueError("Expected observed D3D11 shader platform")
    raw = CompressionHelper.decompress_lz4(bytes(shader.compressedBlob)[shader.offsets[0]:shader.offsets[0] + shader.compressedLengths[0]], shader.decompressedLengths[0])
    sha = hashlib.sha256(raw).hexdigest()
    if PROGRAMS.get(name) != sha:
        raise ValueError(f"Unverified {name} shader; recover this source revision before baking")
    program = ShaderProgram(EndianBinaryReader(raw, endian="<"), shader.object_reader.version)
    passes = tree["m_ParsedForm"]["m_SubShaders"][0]["m_Passes"]
    forward = next(p for p in passes if p["m_State"]["m_Name"] == "FORWARD")
    names = {index: n for n, index in forward["m_NameIndices"]}
    folders = output / "shaders"
    folders.mkdir(parents=True, exist_ok=True)
    variants = []
    for variant in forward["progFragment"]["m_SubPrograms"]:
        index = variant["m_BlobIndex"]
        registers = {names[cb["m_NameIndex"]]: cb["m_Index"] for cb in variant["m_ConstantBufferBindings"]}
        entry = {"blobIndex": index, "keywords": [names[i] for i in variant["m_KeywordIndices"]],
                 "textures": {names[p["m_NameIndex"]]: {"register": p["m_Index"], "sampler": p["m_SamplerIndex"]}
                              for p in variant["m_TextureParams"]},
                 "constants": {names[p["m_NameIndex"]]: {"buffer": names[cb["m_NameIndex"]],
                                                         "register": registers[names[cb["m_NameIndex"]]],
                                                         "byteOffset": p["m_Index"], "dim": p["m_Dim"]}
                               for cb in variant["m_ConstantBuffers"] for p in cb["m_VectorParams"]}}
        binary = folders / f"{prefix}-forward-{index}.dxbc"
        binary.write_bytes(dxbc_container(bytes(program.m_SubPrograms[index].m_ProgramCode)))
        entry["dxbc"] = evidence(binary)
        asm = binary.with_suffix(".asm")
        if vm:
            disassemble(bytes(binary.read_bytes()), asm, vm)
        if asm.exists():
            entry["assembly"] = evidence(asm)
        variants.append(entry)
    result = {"shader": name, "material": {"name": reader.peek_name(), "pathID": str(reader.path_id),
                                           "serializedFile": reader.assets_file.name},
              "programSHA256": sha, "sourceBundles": [evidence(p) for p in bundles],
              "passes": [state_summary(p) for p in passes],
              "forwardVertexBlobIndices": [v["m_BlobIndex"] for v in forward["progVertex"]["m_SubPrograms"]],
              "forwardPixelVariants": variants,
              "defaults": {p["m_Name"]: p.get("m_DefTexture", {}).get("m_DefaultName")
                           for p in tree["m_ParsedForm"]["m_PropInfo"]["m_Props"] if p["m_Type"] == 4}}
    (folders / (prefix + "-summary.json")).write_text(json.dumps(result, indent=2) + "\n")
    return result


_launch_vm = vm_source.powershell


def resilient_powershell(vm: str, script: str, attempts: int = 12) -> str:
    # Measured on the current Parallels build: the 600-char-chunk launch scripts
    # (~2.2k-char -EncodedCommand) are refused with rc=5 and empty stderr, while the
    # same script through vm_source.powershell's own gzip -Command wrapper (enabled
    # above 3000 encoded chars) runs. An ASCII comment pad forces the wrapper path.
    padded = script
    if len(script) * 2 <= 3000:
        padded = "#" + "i" * max(1, 2260 - len(script)) + "\n" + script
    for attempt in range(attempts):
        try:
            return _launch_vm(vm, padded)
        except RuntimeError:
            if attempt == attempts - 1:
                raise
            time.sleep(2)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=PRIVATE / "source/abdata",
                        help="abdata source root containing studio/00.unity3d and studio/mat/00.unity3d")
    parser.add_argument("--output", type=Path, default=PRIVATE,
                        help="Private evidence root; evidence is written under its shaders/ folder")
    parser.add_argument("--disassemble-vm", help="Optional running Parallels VM UUID; regenerate ignored DXBC assembly evidence")
    args = parser.parse_args()
    import UnityPy
    if args.disassemble_vm:
        vm_source.powershell = resilient_powershell
    bundles = [args.source / "studio/00.unity3d", args.source / "studio/mat/00.unity3d"]
    environment = UnityPy.load(*(str(p) for p in bundles))
    results = []
    for material_name, shader_name, prefix in MATERIALS:
        matches = [o for o in environment.objects if o.type.name == "Material" and o.peek_name() == material_name]
        if len(matches) != 1:
            raise ValueError(f"Expected one material {material_name}")
        result = shader_evidence(matches[0], prefix, args.output, bundles, args.disassemble_vm)
        if result["shader"] != shader_name:
            raise ValueError(f"Material {material_name} resolves to unexpected shader {result['shader']!r}")
        results.append(result)
    print(json.dumps({"shaders": [r["shader"] for r in results],
                      "pixelVariants": {r["shader"]: [v["blobIndex"] for v in r["forwardPixelVariants"]] for r in results},
                      "assemblies": {r["shader"]: any("assembly" in v for v in r["forwardPixelVariants"]) for r in results}}, indent=2))


if __name__ == "__main__":
    main()
