#!/usr/bin/env python3
"""Record FORWARD pass/variant/binding evidence for the Studio eye (hitomi) shader.

The cf_Ohitomi_L/R02 renderers use cf_m_hitomi_00; its Shader Forge/toon_eye_lod0
program sits in the same bo_head_00.unity3d SerializedFile (the material m_Shader
PPtr has m_FileID 0), so the pointer needs no sibling bundles here. The mapping
below records how a non-zero m_FileID would resolve through the SerializedFile
externals, so the shader is resolved by pointer rather than by name guessing.
This re-derives pass states, pixel variants, bindings and DXBC blobs with the
item shader contract's helpers (PR #55) and, with a running VM, disassembles each
FORWARD pixel program in place of PR #59's assumed iris sampling and the unknown
meaning of _rotation. Derived evidence stays in ignored .local/reverse/shaders/.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import item_shader_contract
import vm_source
from item_shader_contract import shader_evidence

PRIVATE = Path("/Users/rumpology/code/repo/ikkoku/.local/reverse")
# chara/bo_head_00.unity3d eye material: (material, expected shader, evidence prefix).
MATERIALS = [
    ("cf_m_hitomi_00", "Shader Forge/toon_eye_lod0", "eye-hitomi"),
]
# Decompressed D3D11 program blob digests observed in chara/bo_head_00.unity3d.
EYE_PROGRAMS = {
    "Shader Forge/toon_eye_lod0": "7c7e2489904cc763a8a8621a7f8f19ee32d3acd54295ae6184feede7284a94ef",
}


def shader_dependency_paths(file_id: int, externals: list[str]) -> list[str]:
    """Bundles a material shader PPtr needs beyond its own SerializedFile.

    UnityPy's PPtr.deref keeps m_FileID 0 in the material's own SerializedFile and
    maps m_FileID n >= 1 to externals[n - 1]; the observed eye shader is file id 0.
    """
    if file_id == 0:
        return []
    if file_id > len(externals):
        raise ValueError(f"Shader PPtr file id {file_id} is outside the {len(externals)} recorded externals")
    return [externals[file_id - 1]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=PRIVATE / "rigs/source/abdata",
                        help="abdata source root containing chara/bo_head_00.unity3d")
    parser.add_argument("--output", type=Path, default=PRIVATE,
                        help="Private evidence root; evidence is written under its shaders/ folder")
    parser.add_argument("--disassemble-vm", help="Optional running Parallels VM UUID; regenerate ignored DXBC assembly evidence")
    args = parser.parse_args()
    import UnityPy
    if args.disassemble_vm:
        vm_source.powershell = item_shader_contract.resilient_powershell
    bundles = [args.source / "chara/bo_head_00.unity3d"]
    environment = UnityPy.load(*(str(p) for p in bundles))
    results = []
    for material_name, shader_name, prefix in MATERIALS:
        matches = [o for o in environment.objects if o.type.name == "Material" and o.peek_name() == material_name]
        if len(matches) != 1:
            raise ValueError(f"Expected one material {material_name}")
        serialized = matches[0].assets_file
        dependencies = shader_dependency_paths(matches[0].read().m_Shader.m_FileID, [e.path for e in serialized.externals])
        missing = sorted(str(args.source / path) for path in dependencies if not (args.source / path).is_file())
        if missing:
            raise ValueError(f"Fetch these exact shader dependencies before exporting: {missing}")
        # shader_evidence pins program digests through the item contract's module
        # table; register the eye digest so the observed revision is re-checked.
        item_shader_contract.PROGRAMS.setdefault(shader_name, EYE_PROGRAMS[shader_name])
        result = shader_evidence(matches[0], prefix, args.output, bundles, args.disassemble_vm)
        if result["shader"] != shader_name:
            raise ValueError(f"Material {material_name} resolves to unexpected shader {result['shader']!r}")
        results.append(result)
    print(json.dumps({"shaders": [r["shader"] for r in results],
                      "pixelVariants": {r["shader"]: [v["blobIndex"] for v in r["forwardPixelVariants"]] for r in results},
                      "assemblies": {r["shader"]: any("assembly" in v for v in r["forwardPixelVariants"]) for r in results}}, indent=2))


if __name__ == "__main__":
    main()
