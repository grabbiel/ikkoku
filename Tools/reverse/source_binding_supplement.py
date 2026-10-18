#!/usr/bin/env python3
"""Export source metadata the native shader-binding derivation needs but the
existing material contracts omit, into ignored local evidence.

For the given original bundles it records, without decoding any pixels:
material shader keywords (`m_ShaderKeywords`), Texture2D sampler and mip state
(`m_TextureSettings`, `m_MipCount`), selected draw materials in the head
contract's material format (for example `chara/mm_base.unity3d:cf_m_body`),
and catalog rows of selected categories from `list/characustom/*.unity3d`.
Everything is keyed by serialized file and path ID, so it extends the
converted Maker library and head contract without replacing them.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FILTER_MODES = {0: "Point", 1: "Bilinear", 2: "Trilinear"}
WRAP_MODES = {0: "Repeat", 1: "Clamp", 2: "Mirror", 3: "MirrorOnce"}


def keywords(tree: dict) -> list[str]:
    """`m_ShaderKeywords` is one space-separated string in Unity 5.6;
    later versions split it into valid/invalid keyword lists."""
    value = tree.get("m_ShaderKeywords")
    if isinstance(value, str):
        return [word for word in value.split(" ") if word]
    if isinstance(value, list):
        return [str(word) for word in value if word]
    valid = tree.get("m_ValidKeywords")
    if isinstance(valid, list):
        return [str(word) for word in valid if word]
    raise ValueError("Material has no recognizable shader keyword field")


def texture_settings(tree: dict) -> dict:
    """Sampler and mip state as Unity's `Texture.filterMode`/`wrapMode`/
    `anisoLevel` report them, plus the stored mip count."""
    settings = tree.get("m_TextureSettings")
    if not isinstance(settings, dict):
        raise ValueError("Texture2D has no m_TextureSettings")
    wrap = settings.get("m_WrapMode", settings.get("m_WrapU"))
    if wrap is None or settings.get("m_FilterMode") is None or settings.get("m_Aniso") is None:
        raise ValueError("Texture2D settings lack filter, wrap or aniso")
    if "m_MipCount" in tree:
        mips = int(tree["m_MipCount"])
    elif "m_MipMap" in tree:
        mips = None  # boolean-only serialization: the count is not stored
    else:
        raise ValueError("Texture2D has no mip information")
    return {"filter": FILTER_MODES.get(int(settings["m_FilterMode"]), str(settings["m_FilterMode"])),
            "wrap": WRAP_MODES.get(int(wrap), str(wrap)), "aniso": int(settings["m_Aniso"]),
            "mipLevels": mips, "width": int(tree["m_Width"]), "height": int(tree["m_Height"])}


def catalog_rows(table: dict, name: str, categories: set[int]) -> list[dict]:
    """Rows of one decoded `ChaListData` table when its category is selected."""
    if table.get("mark") != "【ChaListData】":
        raise ValueError(f"Unexpected catalog schema in {name}")
    if int(table["categoryNo"]) not in categories:
        return []
    keys = table["lstKey"]
    return [{"table": name, "category": int(table["categoryNo"]), "id": int(key), "row": dict(zip(keys, values, strict=True))}
            for key, values in sorted(table["dictList"].items())]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    import msgpack
    import UnityPy
    from head_material_contract import material

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=REPO / ".local/reverse/rigs/source/abdata")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle", action="append", default=[], help="bundle path relative to --source (repeatable)")
    parser.add_argument("--draw-material", action="append", default=[], help="bundle:materialName (repeatable)")
    parser.add_argument("--category", action="append", type=int, default=[], help="catalog category number (repeatable)")
    args = parser.parse_args()
    root, output = args.source.resolve(), args.output.resolve()
    # Any git-ignored `.local` tree qualifies, so a worktree can write into
    # the main checkout's private evidence folder.
    if ".local" not in output.parts:
        parser.error("Extracted source metadata must remain under an ignored .local folder")
    bundles = sorted({*args.bundle, *(entry.split(":", 1)[0] for entry in args.draw_material)})
    paths = {bundle: root / bundle for bundle in bundles}
    missing = sorted(str(path) for path in paths.values() if not path.is_file())
    if missing:
        raise SystemExit(f"Fetch these exact bundles first: {missing}")
    hashes = {bundle: digest(path) for bundle, path in paths.items()}
    materials, textures, draws = [], [], []
    env = UnityPy.load(*[str(paths[bundle]) for bundle in bundles])
    wanted = {}
    for entry in args.draw_material:
        bundle, name = entry.split(":", 1); wanted.setdefault(bundle, set()).add(name)
    for bundle in bundles:
        for obj in UnityPy.load(str(paths[bundle])).objects:
            if obj.type.name == "Material":
                tree = obj.read_typetree()
                materials.append({"bundle": bundle, "bundleSHA256": hashes[bundle], "serializedFile": obj.assets_file.name,
                                  "pathID": str(obj.path_id), "name": tree["m_Name"], "shaderKeywords": keywords(tree)})
                if tree["m_Name"] in wanted.get(bundle, set()):
                    # Resolve through the combined environment so cross-bundle
                    # texture references keep their own serialized identity.
                    reader = next(o for o in env.objects if o.type.name == "Material" and o.path_id == obj.path_id
                                  and o.assets_file.name == obj.assets_file.name)
                    draws.append({"bundle": bundle, "bundleSHA256": hashes[bundle], "material": material(reader)})
            elif obj.type.name == "Texture2D":
                tree = obj.read_typetree()
                textures.append({"bundle": bundle, "bundleSHA256": hashes[bundle], "serializedFile": obj.assets_file.name,
                                 "pathID": str(obj.path_id), "name": tree["m_Name"], **texture_settings(tree)})
    for entry in args.draw_material:
        bundle, name = entry.split(":", 1)
        if sum(1 for draw in draws if draw["bundle"] == bundle and draw["material"]["name"] == name) != 1:
            raise SystemExit(f"Expected exactly one material {name} in {bundle}")
    rows, lists = [], []
    if args.category:
        for path in sorted((root / "list/characustom").glob("*.unity3d")):
            lists.append({"path": str(path.relative_to(root)), "sha256": digest(path)})
            for obj in UnityPy.load(str(path)).objects:
                if obj.type.name != "TextAsset":
                    continue
                data = obj.read()
                table = msgpack.unpackb(data.m_Script.encode("utf-8", "surrogateescape"), strict_map_key=False)
                if not isinstance(table, dict) or table.get("mark") != "【ChaListData】":
                    continue
                for row in catalog_rows(table, data.m_Name, set(args.category)):
                    rows.append({**row, "list": str(path.relative_to(root))})
        found = {row["category"] for row in rows}
        if found != set(args.category):
            raise SystemExit(f"Catalog categories not found: {sorted(set(args.category) - found)}")
    result = {"schemaVersion": 1,
              "scope": "Source metadata only (no pixels): material keywords, texture sampler/mip state, selected draw materials, catalog rows",
              "sources": [{"bundle": bundle, "sha256": hashes[bundle]} for bundle in bundles] + lists,
              "materials": materials, "textures": textures, "drawMaterials": draws, "catalogRows": rows}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(output), "materials": len(materials), "textures": len(textures),
                      "drawMaterials": len(draws), "catalogRows": len(rows)}))


if __name__ == "__main__":
    main()
