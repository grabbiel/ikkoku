#!/usr/bin/env python3
"""Independent synthetic full Studio 1.0.4.2 framing fixture and offset oracle."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import msgpack
try:
    from .card_contract import blank_png, dotnet_string, fixture_bytes, parse_card, png_end, Limits
except ImportError:
    from card_contract import blank_png, dotnet_string, fixture_bytes, parse_card, png_end, Limits

REPO = Path(__file__).resolve().parents[3]


class Writer:
    def __init__(self): self.data = bytearray()
    def i(self, value): self.data.extend(struct.pack("<i", value))
    def f(self, value): self.data.extend(struct.pack("<f", value))
    def b(self, value): self.data.append(int(value))
    def s(self, value): self.data.extend(dotnet_string(value))
    def color(self): self.s('{"r":0.2,"g":0.4,"b":0.8,"a":1}')
    def transform(self, rotation=(0, 15, 0)):
        for value in (1, 2, 3, *rotation, 1, 1, 1): self.f(value)
    def header(self, kind, key): self.i(kind); self.i(key); self.transform(); self.i(1); self.b(True)
    def bone(self, key, rotation=(0, 15, 0)): self.i(key); self.transform(rotation)
    def folder(self, key): self.header(3, key); self.s("Synthetic attachment"); self.i(0)
    def camera(self):
        self.i(2)
        for value in (1, 2, 3, 10, 20, 30, 0, 0, -5, 23): self.f(value)


def scene_fixture(*, legacy_card=False, both_modes=False):
    w = Writer(); w.data.extend(blank_png()); w.s("1.0.4.2"); w.i(2)
    w.i(10); w.header(0, 10); w.i(1)
    card = fixture_bytes(msgpack.packb([], use_bin_type=True), legacy=legacy_card, png=False)
    w.data.extend(card)
    w.i(2)
    w.i(1); w.bone(101, (0, 15, 0)); w.i(2); w.bone(102, (0, 0, 0))
    w.i(1); w.i(3); w.bone(103)
    w.i(1); w.i(7); w.i(1); w.folder(11)
    for value in (1, 2, 3, 4, 5, 6): w.i(value)  # mode, animation, two hands
    w.f(0.125); w.data.extend(bytes([0, 1, 2, 3, 4])); w.f(0.25); w.b(True); w.bone(104)
    w.b(both_modes)
    for value in [True, False, True, False, True]: w.b(value)
    w.b(True)
    for value in [False, True, False, False, False, False, False]: w.b(value)
    for value in [True, False] * 4: w.b(value)
    w.f(1.25); w.f(0.375); w.b(True); w.b(False)
    w.i(1)
    for value in (4, 5, 6, 2): w.i(value)  # voice identity and repeat
    w.b(False); w.f(1.125); w.b(False); w.color(); w.f(0.25); w.f(0.75)
    for data in [b"neck\x00\xff", b"eyes\x00\xfe"]: w.i(len(data)); w.data.extend(data)
    w.f(0.625); w.i(1); w.i(7); w.i(1); w.i(1); w.i(8); w.i(0)
    w.i(20); w.header(4, 20); w.s("Synthetic route"); w.i(1); w.folder(21); w.i(2)
    for index in range(2):
        w.bone(201 + index); w.f(2.5 + index); w.i(21); w.i(index)
        w.bone(211 + index); w.b(True); w.b(index == 1)
    w.b(False); w.b(True); w.b(True); w.i(2); w.color()
    object_end = len(w.data)
    w.i(-1); w.transform(); w.i(0); w.b(True); w.i(3); w.f(0.2)
    w.b(True); w.color(); w.f(0.1); w.b(True)
    for value in (0.4, 0.8, 0.6): w.f(value)
    w.b(False); w.f(0.95); w.f(0.6); w.b(True); w.b(False); w.color(); w.f(1); w.f(0)
    w.b(False); w.color(); w.color(); w.i(-1)
    for value in [True, False, True]: w.b(value)
    w.f(0.3); w.color(); w.f(0.7); w.i(2); w.f(0.9)
    for _ in range(11): w.camera()
    for is_map in [False, True]:
        w.color(); w.f(1.5); w.f(45); w.f(180); w.b(True)
        if is_map: w.i(1)
    for no in (12, 13): w.i(2); w.i(no); w.b(False)
    w.i(1); w.s("sample.wav"); w.b(False)
    w.s("background.png"); w.s("frame.png"); w.s("【KStudio】")
    base_end = len(w.data)
    extension = msgpack.packb({"example.scene": [7, {"opaque": b"\x00\xffpreserve"}]}, use_bin_type=True)
    w.s("KKEx"); w.i(3); w.i(len(extension)); w.data.extend(extension)
    return bytes(w.data), {"objectSectionEndOffset": object_end, "baseSceneEndOffset": base_end,
                           "cardSHA256": hashlib.sha256(card).hexdigest()}


class Reader:
    def __init__(self, data): self.data, self.pos = data, 0
    def take(self, length):
        if length < 0 or self.pos + length > len(self.data): raise ValueError("truncated input")
        result = self.data[self.pos:self.pos + length]; self.pos += length; return result
    def i(self): return struct.unpack("<i", self.take(4))[0]
    def count(self):
        value = self.i()
        if not 0 <= value <= 100000: raise ValueError("bad count")
        return value
    def f(self):
        import math
        value = struct.unpack("<f", self.take(4))[0]
        if not math.isfinite(value): raise ValueError("nonfinite value")
        return value
    def b(self):
        value = self.take(1)[0]
        if value > 1: raise ValueError("bad boolean")
        return bool(value)
    def s(self):
        length = 0
        for i in range(5):
            value = self.take(1)[0]; length |= (value & 127) << (i * 7)
            if value < 128:
                if length > 1048576: raise ValueError("oversized string")
                return self.take(length).decode("utf8")
        raise ValueError("bad string length")
    def vector(self, count=3): return [self.f() for _ in range(count)]
    def transform(self): return {key: self.vector() for key in ("position", "rotation", "scale")}
    def bone(self): return {"key": self.i(), "transform": self.transform()}
    def map(self, value):
        result = {}
        for _ in range(self.count()):
            key = str(self.i())
            if key in result: raise ValueError("duplicate key")
            result[key] = value()
        return result
    def card(self):
        start = self.pos
        if self.i() != 100 or self.s() != "【KoiKatuChara】" or self.s() != "0.0.0": raise ValueError("card framing")
        self.take(self.i()); self.take(self.i()); self.take(struct.unpack("<q", self.take(8))[0])
        if self.data[self.pos:self.pos + 9] == b"\x04KKEx\x02\x00\x00\x00":
            self.take(9); self.take(self.i())
        raw = self.data[start:self.pos]; parse_card(raw)
        return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
    def obj(self, depth=0):
        if depth > 64: raise ValueError("excessive depth")
        result = {"kind": self.i(), "key": self.i(), "transform": self.transform(), "treeState": self.i(), "visible": self.b()}
        kind = result["kind"]
        if kind == 0:
            result["sex"] = self.i(); result["card"] = self.card()
            result["bones"] = self.map(self.bone); result["ik"] = self.map(self.bone)
            result["accessories"] = self.map(lambda: [self.obj(depth + 1) for _ in range(self.count())])
            result["kinematicMode"] = self.i(); result["animation"] = [self.i() for _ in range(3)]
            result["hands"] = [self.i() for _ in range(2)]; result["nipple"] = self.f()
            result["fluidLevels"] = list(self.take(5)); result["mouthOpen"] = self.f(); result["lipSync"] = self.b()
            result["lookAt"] = self.bone(); result["enableIK"] = self.b(); result["activeIK"] = [self.b() for _ in range(5)]
            result["enableFK"] = self.b(); result["activeFK"] = [self.b() for _ in range(7)]
            result["expressions"] = [self.b() for _ in range(8)]
            result["speed"] = self.f(); result["pattern"] = self.f(); result["option"] = self.b(); result["loop"] = self.b()
            result["voices"] = [[self.i() for _ in range(3)] for _ in range(self.count())]; result["voiceRepeat"] = self.i()
            result["visibleSon"] = self.b(); result["sonLength"] = self.f(); result["simple"] = self.b(); result["simpleColor"] = json.loads(self.s())
            result["options"] = self.vector(2); result["neck"] = list(self.take(self.i())); result["eyes"] = list(self.take(self.i()))
            result["time"] = self.f(); result["groupStates"] = self.map(self.i); result["states"] = self.map(self.i)
        elif kind == 1:
            result["catalog"] = [self.i() for _ in range(3)]; result["speed"] = self.f()
            result["colors"] = [json.loads(self.s()) for _ in range(8)]
            def pattern(): return {"key": self.i(), "file": self.s(), "clamp": self.b(), "uv": json.loads(self.s()), "rotation": self.f()}
            result["patterns"] = [pattern() for _ in range(3)]
            result.update(alpha=self.f(), lineColor=json.loads(self.s()), lineWidth=self.f(), emissionColor=json.loads(self.s()),
                          emissionPower=self.f(), lightCancel=self.f(), panel=pattern(), enableFK=self.b())
            bones = {}
            for _ in range(self.count()):
                name = self.s(); bones[name] = self.bone()
            result.update(bones=bones, dynamicBone=self.b(), animationTime=self.f())
            result["children"] = [self.obj(depth + 1) for _ in range(self.count())]
        elif kind == 2:
            result.update(number=self.i(), color=self.vector(4), intensity=self.f(), range=self.f(), spotAngle=self.f(),
                          shadow=self.b(), enabled=self.b(), drawTarget=self.b())
        elif kind == 5:
            result.update(name=self.s(), active=self.b())
        elif kind in (3, 4):
            result["name"] = self.s(); result["children"] = [self.obj(depth + 1) for _ in range(self.count())]
            if kind == 4:
                result["points"] = []
                for _ in range(self.count()):
                    result["points"].append({"bone": self.bone(), "speed": self.f(), "ease": self.i(), "connection": self.i(),
                        "aid": self.bone(), "initialized": self.b(), "linked": self.b()})
                result.update(active=self.b(), loop=self.b(), visibleLine=self.b(), orientation=self.i(), color=json.loads(self.s()))
        else: raise ValueError("unsupported object kind")
        return result
    def camera(self):
        if self.i() != 2: raise ValueError("camera version")
        return self.vector(10)
    def light(self, is_map=False):
        result = {"color": json.loads(self.s()), "intensity": self.f(), "rotation": self.vector(2), "shadow": self.b()}
        if is_map: result["type"] = self.i()
        return result
    def sound(self, outside=False): return {"repeat": self.i(), "source": self.s() if outside else self.i(), "play": self.b()}


def inspect_scene(data):
    r = Reader(data); r.pos = png_end(data, Limits())
    if r.s() != "1.0.4.2": raise ValueError("version")
    objects = r.map(r.obj); object_end = r.pos
    settings = {"map": r.i(), "mapTransform": r.transform(), "sunType": r.i(), "mapOption": r.b(), "aceNo": r.i(), "aceBlend": r.f(),
                "aoe": r.b(), "aoeColor": json.loads(r.s()), "aoeRadius": r.f(), "bloom": r.b(), "bloomParameters": r.vector()}
    settings.update(depth=r.b(), depthParameters=r.vector(2), vignette=r.b(), fog=r.b(), fogColor=json.loads(r.s()), fogParameters=r.vector(2), shafts=r.b())
    settings.update(sunThreshold=json.loads(r.s()), sunColor=json.loads(r.s()), sunCaster=r.i(), shadow=r.b(), faceNormal=r.b(), faceShadow=r.b(), lineColor=r.f())
    settings.update(ambient=json.loads(r.s()), lineWidth=r.f(), ramp=r.i(), ambientDepth=r.f())
    settings["cameras"] = [r.camera() for _ in range(11)]
    settings.update(characterLight=r.light(), mapLight=r.light(True), bgm=r.sound(), env=r.sound(), outside=r.sound(True), background=r.s(), frame=r.s())
    if r.s() != "【KStudio】": raise ValueError("marker")
    base_end = r.pos
    trailer = data[base_end:]
    return {"sourceSHA256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "roots": objects,
            "settings": settings, "objectSectionEndOffset": object_end, "baseSceneEndOffset": base_end,
            "trailingBytes": len(trailer), "trailingSHA256": hashlib.sha256(trailer).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/studio-scenes")
    args = parser.parse_args()
    if not args.output.resolve().is_relative_to(REPO / ".local"): raise ValueError("output must remain under .local")
    args.output.mkdir(parents=True, exist_ok=True)
    assembly = REPO / ".local/reverse/managed/CharaStudio/Assembly-CSharp.dll"
    assembly_sha = hashlib.sha256(assembly.read_bytes()).hexdigest()
    if assembly_sha != "902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45":
        raise ValueError("Source Studio assembly does not match the recovered contract")
    fixtures = []
    for name, legacy, both in [("current", False, False), ("legacy-card", True, False), ("both-modes", False, True)]:
        data, expected = scene_fixture(legacy_card=legacy, both_modes=both)
        report = inspect_scene(data)
        assert report["objectSectionEndOffset"] == expected["objectSectionEndOffset"]
        assert report["baseSceneEndOffset"] == expected["baseSceneEndOffset"]
        assert report["roots"]["10"]["card"]["sha256"] == expected["cardSHA256"]
        (args.output / ("synthetic-" + name + ".png")).write_bytes(data)
        (args.output / ("synthetic-" + name + ".json")).write_text(json.dumps(report, indent=2) + "\n")
        fixtures.append({"name": name, "sha256": report["sourceSHA256"], "bytes": len(data)})
    types = ["SceneInfo", "OICharInfo", "ObjectInfo", "OIBoneInfo", "OIIKTargetInfo", "LookAtTargetInfo", "VoiceCtrl", "OIRouteInfo", "OIRoutePointInfo", "OIRoutePointAidInfo", "CameraControl", "CameraLightCtrl", "BGMCtrl", "ENVCtrl", "OutsideSoundCtrl"]
    source = []
    for name in types:
        path = REPO / ".local/reverse/decompiled/Studio" / ("Studio." + name + ".cs")
        source.append({"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    extension_source = REPO / ".local/reverse/cards/decompiled/ExtensibleSaveFormat.ExtendedSave.decompiled.cs"
    source.append({"path": str(extension_source), "sha256": hashlib.sha256(extension_source.read_bytes()).hexdigest()})
    contract = {"schemaVersion": 1, "sceneVersion": "1.0.4.2", "assemblySHA256": assembly_sha,
                "fixtures": fixtures, "sourceEvidence": source}
    (args.output / "contract.json").write_text(json.dumps(contract, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "fixtures": len(fixtures), "sourceFiles": len(source)}))


if __name__ == "__main__": main()
