"""Assemble Assets/catalog.json from the build summaries (plain python3).

    python3 catalog.py
"""
import sys, os, json, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
from rig import REGIONS

HAIR_NAMES = {"bob": ("Bob", "f"), "long_straight": ("Long straight", "f"), "ponytail": ("Ponytail", "f"), "twintails": ("Twintails", "f"),
              "short_m": ("Short (M)", "m"), "messy_m": ("Messy (M)", "m"),
              "mh_bob01": ("MH bob 01", "any"), "mh_bob02": ("MH bob 02", "any"), "mh_ponytail01": ("MH ponytail", "any"), "mh_long01": ("MH long", "any"),
              "mh_afro01": ("MH afro", "any"), "mh_braid01": ("MH braid", "any"), "mh_short01": ("MH short 01", "any"), "mh_short02": ("MH short 02", "any"),
              "mh_short03": ("MH short 03", "any"), "mh_short04": ("MH short 04", "any")}


def load(name):
    p = os.path.join(OUT, name)
    return json.load(open(p)) if os.path.exists(p) else {}


def main():
    cat = {"version": 1, "regions": dict(REGIONS), "bodies": [], "hair": [], "clothes": [], "accessories": [], "items": [], "textures": {}}
    for sex in ("f", "m"):
        s = load("body_%s_summary.json" % sex)
        if not s:
            continue
        cat["bodies"].append({
            "id": "body_%s" % sex, "sex": sex, "file": "Characters/body_%s.glb" % sex,
            "regionsAttribute": "_REGION", "regionsFile": "Characters/body_%s.regions.bin" % sex,
            "meshes": ["body", "eye_L", "eye_R", "eyelash", "eyebrow", "teeth", "tongue"],
            "bones": s["bones"], "morphs": s["morphs"], "eye": s["eye"],
            "textures": {"skinBase": "skin_%s_base.png" % sex, "skinDetail": "skin_%s_detail.png" % sex},
        })
    hs = load("hair_summary.json")
    # The summary only covers the last build_hair run; fall back to the files on disk so every style is listed.
    import struct as _struct
    body_bones = set(cat["bodies"][0]["bones"]) if cat["bodies"] else set()
    for path in sorted(glob.glob(os.path.join(REPO, "Assets", "Hair", "hair_*.glb"))):
        hid = os.path.basename(path)[5:-4]
        info = hs.get(hid, {})
        if not info:
            with open(path, "rb") as f:
                d = f.read()
            clen = _struct.unpack("<I", d[12:16])[0]
            js = json.loads(d[20:20 + clen])
            joints = [js["nodes"][j]["name"] for j in js["skins"][0]["joints"]] if js.get("skins") else []
            info = {"chain_bones": [n for n in joints if n not in body_bones], "parts": {m["name"]: {} for m in js.get("meshes", [])}}
        name, sex = HAIR_NAMES.get(hid, (hid, "any"))
        cat["hair"].append({"id": hid, "file": "Hair/hair_%s.glb" % hid, "sex": sex, "name": name, "strandUV": not hid.startswith("mh_"),
                            "chainBones": info.get("chain_bones", []), "parts": list(info.get("parts", {}).keys())})
    cs = load("clothes_summary.json")
    for cid, info in cs.items():
        entry = {"id": cid, "slot": info["slot"], "file": "Clothes/%s.glb" % cid, "colorMask": "Clothes/%s_cm.png" % cid,
                 "sex": info.get("sex", "f"), "name": info.get("name", cid), "colors": info["colors"], "hideBody": info["hideBody"]}
        if info.get("bodyMask") and os.path.exists(os.path.join(REPO, info["bodyMask"])):
            entry["bodyMask"] = "Clothes/%s_bm.png" % cid
        cat["clothes"].append(entry)
    acc = load("accessories_summary.json")
    for aid, info in acc.items():
        cat["accessories"].append({"id": aid, "file": "Accessories/acc_%s.glb" % aid, "parent": info["parent"], "offset": info["offset"], "name": info["name"]})
    it = load("items_summary.json")
    for iid, info in it.items():
        cat["items"].append({"id": iid, "file": "Items/item_%s.glb" % iid, "category": info["category"], "name": info["name"]})
    tex = sorted(os.path.basename(p) for p in glob.glob(os.path.join(A_TEX, "*.png")))
    cat["textures"] = {
        "iris": [t for t in tex if t.startswith("eye_iris_")], "highlight": [t for t in tex if t.startswith("eye_highlight_")],
        "eyeWhite": "eye_white.png", "eyebrow": [t for t in tex if t.startswith("eyebrow_")], "eyelash": [t for t in tex if t.startswith("eyelash_")],
        "patterns": [t for t in tex if t.startswith("pattern_")], "hairStrand": "hair_strand.png",
        "faceOverlays": {"blush": "face_overlay_blush.png", "eyeshadow": "face_overlay_eyeshadow.png", "lip": "face_overlay_lip.png"},
        "eyeUV": {"note": "eyeball UVs are a planar projection along the gaze axis: silhouette circle radius 0.5 around (0.5,0.5); iris radius 0.38 of the texture", "irisRadius": 0.38},
        "tinted": ["skin_*_base (skin tint)", "eye_iris_* (iris tint, alpha outside iris)", "eyebrow_* (brow tint)", "eyelash_* (lash tint)", "hair_strand (hair tint)", "pattern_* (pattern colour via alpha)"],
    }
    cat["sliders"] = {
        "morphRange": "weight = slider/100; negative = mirrored delta",
        "eyeBoneSliders": {"eye.size": {"scale": 1.2}, "eye.height": {"translate": [0, 0.006, 0]}, "eye.spacing": {"translate": [0.005, 0, 0], "mirrorX": True}, "eye.depth": {"translate": [0, 0, -0.005]}},
        "boneDriven": {"height": "root scale", "head_size": "head scale", "neck_length": "neck length", "torso_length": "spine01..03 length",
                       "arm_length": "upperarm/forearm length", "leg_length": "thigh/calf length", "hand_size": "hand scale", "foot_size": "foot scale", "bust_size": "bust_L/R scale"},
    }
    cat["defaults"] = {"skinTint": [1.0, 0.86, 0.78], "eyelashTint": [0.18, 0.12, 0.16], "eyebrowTint": [0.42, 0.28, 0.30], "irisTint": [0.55, 0.35, 0.75], "hairTint": [0.45, 0.30, 0.55]}
    cat["notes"] = ["_REGION is exported by the Blender glTF exporter as a FLOAT scalar attribute (values 0..14 exact); body_<sex>.regions.bin holds the same ids as uint8 in exported vertex order. The neck is region 0 (never hidden).",
                    "clothes[].bodyMask: 1024^2 grayscale in BODY UV space, white = skin pixel hidden under the garment (dilated 3 px); hideBody lists regions with >= 90% of their vertices covered.",
                    "clothes[].colorMask: R/G/B = tint zones 1/2/3 in the garment's UV space; background is zone 1 (red).",
                    "eyelash/eyebrow meshes carry the eye/brow expression morphs (same target names) so lashes follow blinks.",
                    "Items carry a COLOR_0 base tint (alpha = outline width multiplier)."]
    out = os.path.join(ASSETS, "catalog.json")
    write_json(out, cat)
    log("catalog: %d bodies, %d hair, %d clothes, %d accessories, %d items" % (len(cat["bodies"]), len(cat["hair"]), len(cat["clothes"]), len(cat["accessories"]), len(cat["items"])))


if __name__ == "__main__":
    main()
