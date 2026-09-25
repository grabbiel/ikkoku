#!/usr/bin/env python3
"""Extract a local head expression contract and an independent float32 oracle.

Requires the privately acquired source bundle and narrowly decompiled controllers.
All emitted source tables belong under ignored .local, never in shipped assets.
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
from pathlib import Path

import msgpack
import numpy as np
import UnityPy

REPO = Path(__file__).resolve().parents[3]
HEAD_SHA = "e6ded0a39b1ca521648597d31d9f868fe354963279a8ccf4140212598289cf7e"
FBS_PATH_ID = 6276390747262352963
CONTROLLERS = (("eyebrow", "EyebrowCtrl"), ("eyes", "EyesCtrl"), ("mouth", "MouthCtrl"))
DEFAULTS = {
    "eyebrowPattern": 0, "eyesPattern": 0, "mouthPattern": 0,
    "eyebrowOpenRate": 1.0, "eyesOpenRate": 1.0, "mouthOpenRate": 0.0,
    "eyebrowOpenMax": 1.0, "eyesOpenMax": 0.92, "mouthOpenMax": 1.0,
    "blinkRate": 1.0, "mouthFixedRate": -1.0,
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_id(reader) -> str:
    return f"{reader.assets_file.name}:{reader.path_id}"


def active_in_hierarchy(game_object) -> bool:
    if not game_object.m_IsActive:
        return False
    transform = next(c.component.read() for c in game_object.m_Component
                     if c.component.deref().type.name == "Transform")
    if not transform.m_Father.path_id:
        return True
    return active_in_hierarchy(transform.m_Father.read().m_GameObject.read())


def extract_targets(reader, source: dict):
    """Retain raw PtnSet separately: the reference evaluator never reads its export."""
    exported, originals, mesh_by_node = [], {}, {}
    for domain, field in CONTROLLERS:
        controller = source[field]
        targets = []
        originals[domain] = []
        for raw in controller["FBSTarget"]:
            pointer = raw["ObjTarget"]
            assert pointer["m_FileID"] == 0
            go_reader = reader.assets_file.objects[pointer["m_PathID"]]
            go = go_reader.read()
            renderer_reader = next(c.component.deref() for c in go.m_Component
                                   if c.component.deref().type.name == "SkinnedMeshRenderer")
            renderer = renderer_reader.read()
            mesh_reader = renderer.m_Mesh.deref()
            mesh = mesh_reader.read_typetree()
            channels, frames = mesh["m_Shapes"]["channels"], mesh["m_Shapes"]["fullWeights"]
            assert all(c["frameCount"] == 1 and frames[c["frameIndex"]] == 100.0 for c in channels)

            def channel(index):
                if index == -1:
                    return {"index": -1, "name": "", "frameIndex": -1, "frameWeight": 0.0}
                assert 0 <= index < len(channels)
                item = channels[index]
                assert item["frameCount"] == 1 and frames[item["frameIndex"]] == 100.0
                return {"index": index, "name": item["name"], "frameIndex": item["frameIndex"],
                        "frameWeight": frames[item["frameIndex"]]}

            controlled = sorted({p[k] for p in raw["PtnSet"] for k in ("Close", "Open") if p[k] >= 0})
            target = {
                "nodeName": go.m_Name, "gameObjectSourceID": source_id(go_reader),
                "rendererSourceID": source_id(renderer_reader), "meshName": mesh["m_Name"],
                "meshSourceID": source_id(mesh_reader), "channelCount": len(channels),
                "activeSelf": bool(go.m_IsActive), "activeInHierarchy": active_in_hierarchy(go),
                "rendererEnabled": bool(renderer.m_Enabled),
                "initialMorphWeights": list(renderer.m_BlendShapeWeights),
                "controlledChannelIndices": controlled,
                "patterns": [{"index": i, "close": channel(p["Close"]), "open": channel(p["Open"])}
                             for i, p in enumerate(raw["PtnSet"])],
            }
            targets.append(target)
            originals[domain].append((go.m_Name, raw["PtnSet"]))
            mesh_by_node[go.m_Name] = target
        exported.append({"id": domain, "openMin": controller["OpenMin"],
                         "openMax": controller["OpenMax"], "fixedRate": controller["FixedRate"],
                         "syncBlink": bool(controller.get("SyncBlink", False)),
                         "sourcePatternCount": len(controller["FBSTarget"][0]["PtnSet"]), "targets": targets})
    return exported, originals, mesh_by_node


def presets() -> list[dict]:
    def case(key, label, **overrides):
        return {"id": key, "label": label, "inputs": {**DEFAULTS, **overrides}}
    return [case("neutral", "Neutral"),
            case("blinkClosed", "Blink closed", blinkRate=0.0, eyesOpenRate=0.0, eyebrowOpenRate=0.0),
            case("blinkHalf", "Blink halfway", blinkRate=0.5, eyesOpenRate=0.5, eyebrowOpenRate=0.5),
            case("smile", "Smile", eyesPattern=2, mouthPattern=1),
            case("smileMouthOpen", "Smile with mouth open", eyesPattern=2, mouthPattern=1, mouthOpenRate=1.0),
            case("softSmile", "Soft smile", eyesPattern=4, mouthPattern=1)]


def eye_catalog(path: Path) -> dict:
    env = UnityPy.load(str(path))
    reader = next(o for o in env.objects if o.type.name == "TextAsset" and o.peek_name() == "cha_eyeset_00")
    raw = reader.read().m_Script.encode("utf8", "surrogateescape")
    table = msgpack.unpackb(raw, strict_map_key=False)
    rows = []
    for index in range(7):
        row = dict(zip(table["lstKey"], table["dictList"][index]))
        rows.append({"id": index, "name": row["Name"], "pattern": int(row["EyesPtn"]),
                     "eyeBase": int(row["EyeBase"]), "eyeHitomi": int(row["EyeHitomi"]),
                     "eyeObjectNumber": int(row["EyeObjNo"]),
                     "mainTexture": row["MainTex"], "expressionTexture": row["EpsTex"]})
    return {"path": str(path.relative_to(REPO)), "sha256": digest(path),
            "table": "cha_eyeset_00", "sourceID": source_id(reader), "ordinaryRows": rows}


def max_active_channels(originals: dict, meshes: dict) -> dict:
    result = {}
    for name in meshes:
        domains = [pairs for targets in originals.values() for node, pairs in targets if node == name]
        alternatives = [{frozenset(i for i in (p["Close"], p["Open"]) if i >= 0) for p in pairs}
                        for pairs in domains]
        # A blended transition can contain the two selected patterns of each controller.
        transitions = [{a | b for a in sets for b in sets} for sets in alternatives]
        result[name] = {
            "singlePatternPerController": max(len(frozenset().union(*combo)) for combo in itertools.product(*alternatives)),
            "twoPatternTransitionPerController": max(len(frozenset().union(*combo)) for combo in itertools.product(*transitions)),
        }
    return result


def evaluate_original(source: dict, originals: dict, meshes: dict, inputs: dict,
                      previous: dict | None = None, progress: float = 1.0) -> dict:
    """Independent transcription of recovered FBSBase operations, using raw PtnSet.

    This models one selected pattern per controller and neutral gaze. It preserves
    source single-precision operation order, integer truncation, reset sets and
    accumulation when a pattern's close and open refer to the same channel.
    """
    f = np.float32
    t = f(progress)
    arrays = {name: np.zeros(m["channelCount"], dtype=np.float32) for name, m in meshes.items()}
    steps = {}
    for domain, field in CONTROLLERS:
        raw = source[field]
        rate = f(inputs[domain + "OpenRate"])
        blink = f(inputs["blinkRate"])
        if (domain == "eyes" and blink >= 0) or (domain == "eyebrow" and raw["SyncBlink"] and blink >= 0):
            rate = blink
        lo, hi = f(raw["OpenMin"]), f(inputs[domain + "OpenMax"])
        if domain == "eyes":
            hi = min(f(1) - f(source["EyeLookUpCorrect"]), hi)  # neutral H/V gaze
        openness = f(lo + f(f(hi - lo) * max(f(0), min(f(1), rate))))
        fixed = f(inputs["mouthFixedRate"] if domain == "mouth" else raw["FixedRate"])
        if fixed >= 0:
            openness = fixed
        n = int(max(f(0), min(f(100), f(openness * f(100)))))
        steps[domain] = n
        for name, pairs in originals[domain]:
            weights = {p[k]: f(0) for p in pairs for k in ("Close", "Open")}
            contributions = []
            if t != f(1):
                assert previous is not None
                contributions.append((previous[domain + "Pattern"], f(f(1) - t)))
            contributions.append((inputs[domain + "Pattern"], t))
            for index, fraction in contributions:
                pair = pairs[index]
                weights[pair["Close"]] = f(weights[pair["Close"]] + f(f(100 - n) * fraction))
                weights[pair["Open"]] = f(weights[pair["Open"]] + f(f(n) * fraction))
            for channel, weight in weights.items():
                if channel != -1:
                    arrays[name][channel] = weight
    return {"quantizedOpenPercent": steps,
            "meshes": [{"nodeName": name, "meshName": meshes[name]["meshName"],
                        "weights": [float(w) for w in weights],
                        "activeChannelCount": int(np.count_nonzero(weights)),
                        "activeWeights": [{"index": i, "weight": float(w)} for i, w in enumerate(weights) if w != 0]}
                       for name, weights in arrays.items()]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", type=Path, default=REPO / ".local/reverse/rigs/source/abdata/chara/bo_head_00.unity3d")
    parser.add_argument("--catalog", type=Path, default=REPO / ".local/reverse/rigs/source/abdata/list/characustom/00.unity3d")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/rigs/source-expression-contract.json")
    parser.add_argument("--reference", type=Path, default=REPO / ".local/reverse/rigs/source-expression-expected-weights.json")
    args = parser.parse_args()
    for output in (args.output, args.reference):
        if not output.resolve().is_relative_to(REPO / ".local"):
            raise ValueError("Recovered source tables must remain under ignored .local")
    assert digest(args.head) == HEAD_SHA, "Unreviewed source bundle: inspect before extracting a new contract"
    env = UnityPy.load(str(args.head))
    reader = next(o for o in env.objects if o.path_id == FBS_PATH_ID)
    source = reader.read_typetree()
    controllers, originals, meshes = extract_targets(reader, source)
    pair_count = sum(len(pairs) for targets in originals.values() for _, pairs in targets)
    assert pair_count == 484 and len(meshes) == 13
    evidence = REPO / ".local/reverse/decompiled/Expressions"
    manifest = json.loads((evidence / "manifest.json").read_text())
    known = {entry["type"] for entry in manifest["types"]}
    if "MathfEx" not in known:
        path = evidence / "MathfEx.cs"
        manifest["types"].append({"type": "MathfEx", "file": str(path.relative_to(REPO)), "sha256": digest(path)})
        (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for entry in manifest["types"]:
        assert digest(REPO / entry["file"]) == entry["sha256"]
    assert digest(REPO / manifest["assembly"]) == manifest["assemblySHA256"]
    provenance = {"head": {"path": str(args.head.relative_to(REPO)), "sha256": HEAD_SHA,
                           "sourceID": source_id(reader), "prefab": "p_cf_head_00"},
                  "assembly": {"path": manifest["assembly"], "sha256": manifest["assemblySHA256"]},
                  "decompiledManifest": str((evidence / "manifest.json").relative_to(REPO)),
                  "chaControl": {"path": ".local/reverse/decompiled/Character/Koikatu/ChaControl.cs",
                                 "sha256": digest(REPO / ".local/reverse/decompiled/Character/Koikatu/ChaControl.cs")},
                  "chaReference": {"path": ".local/reverse/decompiled/Character/Koikatu/ChaReference.cs",
                                   "sha256": digest(REPO / ".local/reverse/decompiled/Character/Koikatu/ChaReference.cs")}}
    mouth = source["MouthCtrl"]
    contract = {
        "schemaVersion": 1, "weightUnit": "percent", "sourceFrameWeight": 100.0,
        "sourcePatternPairCount": pair_count, "sourceTargetCount": sum(len(c["targets"]) for c in controllers),
        "sourceUniqueMeshCount": len(meshes),
        "fbsEnabled": bool(source["m_Enabled"]), "updateOrder": [d for d, _ in CONTROLLERS],
        "transitionSeconds": 0.15, "transitionMode": "linearPreviousTargetToCurrentTarget",
        "provenance": provenance, "controllers": controllers, "defaults": DEFAULTS,
        "fileStatusDefaults": {"eyebrowPattern": 0, "eyesPattern": 0, "mouthPattern": 0,
                               "eyebrowOpenMax": 1.0, "eyesOpenMax": 1.0, "mouthOpenMax": 1.0,
                               "eyesBlink": True, "mouthFixed": False, "mouthAdjustWidth": True},
        "eyesOpenMaxCap": 0.92,
        "gazeCorrection": {"up": source["EyeLookUpCorrect"], "down": source["EyeLookDownCorrect"],
                           "side": source["EyeLookSideCorrect"], "acceleration": "sqrtClampedT",
                           "eyeLookControllerPrefabPathID": str(source["EyeLookController"]["m_PathID"]),
                           "assignedByChaControlAtRuntime": True, "referenceGaze": [0.0, 0.0]},
        "blink": {"frequency": source["BlinkCtrl"]["BlinkFrequency"],
                  "baseSpeedSeconds": source["BlinkCtrl"]["BaseSpeed"], "randomSpeedAdditionSeconds": [0.0, 0.05],
                  "idleIntegerRange": [0, 30], "idleSecondsPerInteger": 0.2,
                  "closeHoldFrameCountInclusive": [1, 3], "initialOpenRate": 1.0, "initialFixedFlags": 0},
        "mouthWidth": {"useAjustWidthScale": bool(mouth["useAjustWidthScale"]),
                       "objAdjustWidthScale": {"fileID": mouth["objAdjustWidthScale"]["m_FileID"],
                                               "pathID": str(mouth["objAdjustWidthScale"]["m_PathID"])},
                       **{k: mouth[k] for k in ("randTimeMin", "randTimeMax", "randScaleMin", "randScaleMax", "openRefValue")},
                       "indirectTargetNode": "cf_J_MouthBase_rx", "indirectTargetAxis": "localScale.x",
                       "indirectWriter": "ChaControl.UpdateBlendShapeVoice via ChaReference.RefObjKey.F_ADJUSTWIDTHSCALE",
                       "indirectWriterTiming": "UpdateForce writes the latest stored value; FaceBlendShape.LateUpdate computes it",
                       "referenceIncludesRandomWidthMotion": False},
        "eyeCatalog": eye_catalog(args.catalog), "presets": presets(),
        "maxActiveChannelsPerMesh": max_active_channels(originals, meshes),
        "limits": ["Reference states use neutral gaze and an externally supplied blink openness.",
                   "Random blink timing, mouth-width motion and gaze tracking are specified separately from stateless weights.",
                   "All original pattern channel sets are preserved; selected presets expose ordinary expressions only.",
                   "No special expression textures, object swaps, tear visibility, tongue states or voice analysis are reproduced.",
                   "FBS writes target weights without testing renderer enabled/active flags; rendering still observes those flags."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(contract, ensure_ascii=False, indent=2) + "\n")
    print(f"Contract ready: {args.output} ({pair_count} pairs, {len(meshes)} meshes)", flush=True)
    cases = presets()
    cases[0] = {**cases[0], "id": "defaults"}
    for suffix, rate in (("009", 0.009), ("01", 0.01), ("999", 0.999)):
        cases.append({"id": "mouthQuantization" + suffix, "inputs": {**DEFAULTS, "mouthOpenRate": rate}})
    cases.append({"id": "fixedMouthHalf", "inputs": {**DEFAULTS, "mouthFixedRate": 0.5}})
    cases.append({"id": "smileTransitionHalf", "inputs": {**DEFAULTS, "eyesPattern": 2, "mouthPattern": 1},
                  "previousInputs": DEFAULTS, "transitionProgress": 0.5})
    cases.append({"id": "explicitClosedEyesSameChannel", "inputs": {**DEFAULTS, "eyesPattern": 1}})
    for case in cases:
        case.update(evaluate_original(source, originals, meshes, case["inputs"], case.get("previousInputs"),
                                      case.get("transitionProgress", 1.0)))
    by_id = {c["id"]: c for c in cases}
    assert [by_id["mouthQuantization" + k]["quantizedOpenPercent"]["mouth"] for k in ("009", "01", "999")] == [0, 1, 99]
    assert by_id["defaults"]["quantizedOpenPercent"] == {"eyebrow": 100, "eyes": 92, "mouth": 0}
    assert by_id["blinkHalf"]["quantizedOpenPercent"] == {"eyebrow": 50, "eyes": 46, "mouth": 0}
    reference = {"schemaVersion": 1, "weightUnit": "percent", "provenance": provenance,
                 "oracle": "Original serialized PtnSet and independent NumPy float32 FBSBase calculation; neutral gaze.",
                 "contractSHA256": digest(args.output), "cases": cases}
    args.reference.write_text(json.dumps(reference, ensure_ascii=False, indent=2) + "\n")
    print(f"Reference ready: {args.reference} ({len(cases)} cases)")


if __name__ == "__main__":
    main()
