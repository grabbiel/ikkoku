#!/usr/bin/env python3
"""Compile a bounded, verbatim local C# shape excerpt into numeric parity fixtures.

No game code or data is emitted outside ignored .local/. Unity math/Transform setters
are minimal explicit shims; this does not execute the game or establish Unity-renderer parity.
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import random
import re
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
LOCAL = ROOT / ".local/reverse"


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


SHIM = r'''
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Text.Json;

struct Vector3 {
    public float x, y, z;
    public Vector3(float x, float y, float z) { this.x=x; this.y=y; this.z=z; }
    public static Vector3 zero => new(0,0,0);
    public static Vector3 one => new(1,1,1);
    public static Vector3 Lerp(Vector3 a, Vector3 b, float t) {
        t=Math.Clamp(t,0,1);
        return new(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t);
    }
    public float[] Array() => new[]{x,y,z};
}
static class Mathf {
    public static int FloorToInt(float x) => (int)MathF.Floor(x);
    public static float LerpAngle(float a, float b, float t) {
        float d=(b-a)%360; if(d<0)d+=360; if(d>180)d-=360;
        return a+d*Math.Clamp(t,0,1);
    }
}
class Transform {
    public Vector3 position, scale;
    public float[] rotation = new[]{0f,0f,0f,1f};
    public void SetLocalScale(float x,float y,float z) { scale=new(x,y,z); }
    public void SetLocalPositionX(float x) { position.x=x; }
    public void SetLocalPositionY(float y) { position.y=y; }
    public void SetLocalPositionZ(float z) { position.z=z; }
    public void SetLocalRotation(float x,float y,float z) {
        // Unity Euler applies Z, then X, then Y. System.Numerics uses Hamilton products.
        var qz=System.Numerics.Quaternion.CreateFromAxisAngle(System.Numerics.Vector3.UnitZ,z*MathF.PI/180f);
        var qx=System.Numerics.Quaternion.CreateFromAxisAngle(System.Numerics.Vector3.UnitX,x*MathF.PI/180f);
        var qy=System.Numerics.Quaternion.CreateFromAxisAngle(System.Numerics.Vector3.UnitY,y*MathF.PI/180f);
        var q=qy*qx*qz;
        rotation=new[]{q.X,q.Y,q.Z,q.W};
    }
}
class BoneInfo {
    public Transform trfBone = new();
    public Vector3 vctPos=Vector3.zero, vctRot=Vector3.zero, vctScl=Vector3.one;
}
class CategoryInfo { public int id; public string name=""; public bool[][] use=Array.Empty<bool[]>(); public bool[] getflag=Array.Empty<bool>(); }
class AnmKeyInfo { public Vector3 pos,rot,scl; }
class AnimationKeyInfo {
    public Dictionary<string,List<AnmKeyInfo>> dictInfo=new();
    /* GET_INFO */
}
class ShapeReference {
    public Dictionary<int,List<CategoryInfo>> dictCategory=new();
    public Dictionary<int,BoneInfo> dictSrc=new(), dictDst=new();
    public AnimationKeyInfo anmKeyInfo=new();
    public BoneInfo[] correctValue=Array.Empty<BoneInfo>();
    public int typeBone, updateMask=7;
    public bool InitEnd=true;
    public Transform[] fixCorrectBone=new Transform[2];
    public float correctHeadSize=1, correctNeckSize=1;
    /* CHANGE_VALUE */
    /* UPDATE */
    /* UPDATE_ALWAYS */
}
static class Program {
    static Vector3 V(JsonElement array) { var a=array.EnumerateArray().Select(x=>x.GetSingle()).ToArray(); return new(a[0],a[1],a[2]); }
    static bool[] B(JsonElement array) => array.EnumerateArray().Select(x=>x.GetBoolean()).ToArray();
    static void Main(string[] args) {
        var input=JsonDocument.Parse(File.ReadAllText(args[0])).RootElement;
        var domain=input.GetProperty("domain");
        var result=new List<object>();
        foreach(var c in input.GetProperty("cases").EnumerateArray()) {
            var r=new ShapeReference();
            r.typeBone=c.GetProperty("corrected").GetBoolean()?1:0;
            r.updateMask=c.GetProperty("updateMask").GetInt32();
            int sex=c.GetProperty("sex").GetInt32();
            r.correctHeadSize=r.correctNeckSize=sex==0?0.91f:1f;
            foreach(var channel in domain.GetProperty("channels").EnumerateArray()) {
                r.anmKeyInfo.dictInfo[channel.GetProperty("name").GetString()!]=channel.GetProperty("samples").EnumerateArray().Select(s=>new AnmKeyInfo {
                    pos=V(s.GetProperty("position")),rot=V(s.GetProperty("rotationDegrees")),scl=V(s.GetProperty("scale")) }).ToList();
            }
            foreach(var slot in domain.GetProperty("slots").EnumerateArray()) {
                var categories=new List<CategoryInfo>();
                foreach(var b in slot.GetProperty("bindings").EnumerateArray()) {
                    var ci=new CategoryInfo { id=b.GetProperty("sourceIndex").GetInt32(),name=b.GetProperty("sourceName").GetString()!,
                        use=new[]{ B(b.GetProperty("positionMask")),B(b.GetProperty("rotationMask")),B(b.GetProperty("scaleMask")) } };
                    ci.getflag=ci.use.Select(mask=>mask.Any(x=>x)).ToArray();
                    categories.Add(ci); r.dictSrc.TryAdd(ci.id,new BoneInfo());
                }
                r.dictCategory[slot.GetProperty("index").GetInt32()]=categories;
            }
            foreach(var t in input.GetProperty("destinations").EnumerateArray()) {
                int index=t.GetProperty("index").GetInt32();
                var transform=new Transform { position=V(t.GetProperty("translation")),scale=V(t.GetProperty("scale")),
                    rotation=t.GetProperty("rotation").EnumerateArray().Select(x=>x.GetSingle()).ToArray() };
                if(index<86) r.dictDst[index]=new BoneInfo { trfBone=transform };
                else r.fixCorrectBone[index-86]=transform;
            }
            r.correctValue=input.GetProperty("corrections").EnumerateArray().Select(t=>new BoneInfo {
                vctPos=V(t.GetProperty("position")),vctRot=V(t.GetProperty("rotationDegrees")),vctScl=V(t.GetProperty("scale")) }).ToArray();
            var values=c.GetProperty("values").EnumerateArray().Select(x=>x.GetSingle()).ToArray();
            for(int i=0;i<values.Length;i++) if(!r.ChangeValue(i,values[i])) throw new Exception("Unresolved source slot");
            if(c.TryGetProperty("rawState",out var raw)) {
                int index=0;
                foreach(var t in raw.EnumerateArray()) {
                    r.dictSrc[index++]=new BoneInfo { vctPos=V(t.GetProperty("position")),
                        vctRot=V(t.GetProperty("rotationDegrees")),vctScl=V(t.GetProperty("scale")) };
                }
            }
            if(c.TryGetProperty("correctionOverride",out var replacement)) {
                r.correctValue=replacement.EnumerateArray().Select(t=>new BoneInfo {
                    vctPos=V(t.GetProperty("position")),vctRot=V(t.GetProperty("rotationDegrees")),vctScl=V(t.GetProperty("scale")) }).ToArray();
            }
            r.Update();
            if(c.GetProperty("applyAlways").GetBoolean()) r.UpdateAlways();
            result.Add(new { values,sex,corrected=r.typeBone!=0,updateMask=r.updateMask,
                applyAlways=c.GetProperty("applyAlways").GetBoolean(),
                rawState=c.TryGetProperty("rawState",out var rawOut)?(object)rawOut:null,
                correctionOverride=c.TryGetProperty("correctionOverride",out var corrOut)?(object)corrOut:null,
                destinations=input.GetProperty("destinations").EnumerateArray().Select(t=> {
                    int id=t.GetProperty("index").GetInt32();
                    var tr=id<86?r.dictDst[id].trfBone:r.fixCorrectBone[id-86];
                    return new { name=t.GetProperty("name").GetString(),position=tr.position.Array(),rotation=tr.rotation,scale=tr.scale.Array() };
                }).ToArray() });
        }
        File.WriteAllText(args[1],JsonSerializer.Serialize(new {
            rigPath=input.GetProperty("rigPath").GetString(),shapeContractPath=input.GetProperty("shapeContractPath").GetString(),
            correctionPath=input.GetProperty("correctionPath").GetString(),cases=result }));
    }
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Override the source directory selected by the hash-validated recovery index.")
    parser.add_argument("--rig", type=Path, default=LOCAL / "rigs/neutral-rig.json")
    parser.add_argument("--contract", type=Path, default=LOCAL / "rigs/character-shape-contract.json")
    parser.add_argument("--corrections", type=Path, default=LOCAL / "rigs/textassets/shapecorrect.bytes")
    parser.add_argument("--output", type=Path, default=LOCAL / "body-shape-reference")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / ".local"):
        raise ValueError("source-derived proof output must remain inside ignored .local/")
    if args.source is None:
        index = json.loads((LOCAL / "managed-recovery/index.json").read_text())
        assembly = next(a for a in index["assemblies"] if "Koikatu_Data/Managed/Assembly-CSharp.dll" in a["sourcePaths"])
        if assembly["status"] != "recovered" or hashlib.sha256(Path(assembly["assembly"]).read_bytes()).hexdigest() != assembly["assemblySHA256"]:
            raise ValueError("managed assembly provenance changed")
        args.source = Path(assembly["directory"]) / assembly["selectedProject"]
    paths = [args.source / name for name in ("ShapeBodyInfoFemale.cs", "ShapeInfoBase.cs", "AnimationKeyInfo.cs")]
    body_source, base_source, animation_source = [p.read_text() for p in paths]
    update = method(body_source, "public override void Update()").replace("public override", "public")
    always = method(body_source, "public override void UpdateAlways()").replace("public override", "public")
    always = re.sub(r"\(bool\)(fixCorrectBone\[\d\])", r"\1 != null", always)
    if update.count("dictDst.TryGetValue(") != 85 or always.count("dictDst.TryGetValue(") != 1:
        raise ValueError("source destination operation shape changed")
    get_info = method(animation_source, "public bool GetInfo(string name, float rate, ref Vector3[] value, bool[] flag)")
    change_value = method(base_source, "public bool ChangeValue(int category, float value)")
    source = SHIM.replace("/* GET_INFO */", get_info).replace("/* CHANGE_VALUE */", change_value).replace("/* UPDATE */", update).replace("/* UPDATE_ALWAYS */", always)
    contract = json.loads(args.contract.read_text())
    body = next(d for d in contract["domains"] if d["id"] == "body")
    rig = json.loads(args.rig.read_text())
    names = body["destinationNames"] + ["cf_d_shoulder_L", "cf_d_shoulder_R"]
    destinations = []
    for index, name in enumerate(names):
        matches = [node for node in rig["nodes"] if node["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"expected one destination {name}")
        destinations.append({**matches[0], "index": index})
    data = args.corrections.read_bytes()
    if len(data) != 1156 or struct.unpack_from("<i", data)[0] != 32:
        raise ValueError("unsupported correction table")
    corrections = []
    for index in range(32):
        v = struct.unpack_from("<9f", data, 4 + 36 * index)
        corrections.append({"position": v[:3], "rotationDegrees": v[3:6], "scale": v[6:]})
    cases = []
    rates = [list(body["defaultValues"])]
    for slot, rate in itertools.product(range(44), [0, 0.137, 0.863, 1]):
        values = list(body["defaultValues"]); values[slot] = rate; rates.append(values)
    rng = random.Random(92026)
    rates += [[rng.random() for _ in range(44)] for _ in range(24)]
    for values, sex, corrected in itertools.product(rates, [0, 1], [False, True]):
        cases.append({"values": values, "sex": sex, "corrected": corrected, "updateMask": 7, "applyAlways": True})
    for mask, always_enabled, sex in itertools.product(range(8), [False, True], [0, 1]):
        cases.append({"values": rates[-1], "sex": sex, "corrected": True, "updateMask": mask, "applyAlways": always_enabled})
    # Independent intermediate values exercise even axes that happen to be zero in the default table.
    # Positive denominator scales avoid undefined division; exact division failures have Swift tests.
    for index in range(8):
        raw = [{"position": [rng.uniform(-.2, .2) for _ in range(3)],
                "rotationDegrees": [rng.uniform(-90, 450) for _ in range(3)],
                "scale": [rng.uniform(.4, 1.6) for _ in range(3)]} for _ in range(111)]
        custom = [{"position": [rng.uniform(-.1, .1) for _ in range(3)],
                   "rotationDegrees": [rng.uniform(-30, 30) for _ in range(3)],
                   "scale": [rng.uniform(-.1, .1) for _ in range(3)]} for _ in range(32)]
        cases.append({"values": body["defaultValues"], "sex": index % 2, "corrected": True,
                      "updateMask": 7, "applyAlways": True, "rawState": raw, "correctionOverride": custom})
    output.mkdir(parents=True, exist_ok=True)
    (output / "Program.cs").write_text(source)
    (output / "Reference.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><Nullable>disable</Nullable></PropertyGroup></Project>')
    payload = {"domain": body, "destinations": destinations, "corrections": corrections, "cases": cases,
               "rigPath": str(args.rig.resolve()), "shapeContractPath": str(args.contract.resolve()), "correctionPath": str(args.corrections.resolve())}
    (output / "input.json").write_text(json.dumps(payload))
    subprocess.run(["dotnet", "run", "--project", str(output / "Reference.csproj"), "--configuration", "Release", "--",
                    str(output / "input.json"), str(output / "reference.json")], check=True)
    provenance = [{"path": str(p.resolve()), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths + [args.rig, args.contract, args.corrections]]
    manifest = {"caseCount": len(cases), "destinationCount": len(names), "sourceEvidence": provenance,
                "excerptSHA256": hashlib.sha256((update + always + get_info + change_value).encode()).hexdigest(),
                "scope": "Verbatim recovered GetInfo, ChangeValue, complete Update and UpdateAlways; explicit Unity math/Transform shim. No rendered parity assertion."}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"cases": len(cases), "reference": str(output / "reference.json")}, indent=2))


if __name__ == "__main__":
    main()
