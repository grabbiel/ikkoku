#!/usr/bin/env python3
"""Independent float32 timing oracle for the recovered expression controllers.

Never executes game code. Random draws are explicit source-range values so the
contract concerns state transitions, not an invented Unity PRNG replacement.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import struct

REPO = Path(__file__).resolve().parents[3]
ASSEMBLY_SHA = "0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5"
SOURCE_NAMES = ["FBSBlinkControl", "FBSAssist.TimeProgressCtrl", "FBSAssist.TimeProgressCtrlRandom",
                "FaceBlendShape", "FBSBase", "FBSCtrlEyes", "FBSCtrlEyebrow", "FBSCtrlMouth"]


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def add(a, b): return f32(f32(a) + f32(b))
def sub(a, b): return f32(f32(a) - f32(b))
def mul(a, b): return f32(f32(a) * f32(b))
def div(a, b): return f32(f32(a) / f32(b))
def clamp(value): return min(max(value, 0.0), 1.0)


class Draws:
    def __init__(self, integers=(), floats=()):
        self.integers, self.floats = list(integers), list(floats)
        self.requests = []

    def integer(self, lo, hi):
        if not self.integers: raise ValueError("Missing explicit integer draw")
        value = self.integers.pop(0)
        if type(value) is not int or not (value == lo if lo == hi else lo <= value < hi):
            raise ValueError("Integer draw is outside source range")
        self.requests.append({"kind": "integer", "minimum": lo, "maximum": hi, "value": value})
        return value

    def floating(self, lo, hi):
        if not self.floats: raise ValueError("Missing explicit float draw")
        lo, hi = f32(lo), f32(hi)
        value = f32(self.floats.pop(0))
        if not lo <= value <= hi: raise ValueError("Float draw is outside source range")
        self.requests.append({"kind": "float", "minimum": lo, "maximum": hi, "value": value})
        return value

    def finish(self):
        if self.integers or self.floats: raise ValueError("Unconsumed explicit draws")


@dataclass
class Blink:
    fixedFlags: int = 0
    frequency: int = 30
    mode: int = 0
    baseSpeed: float = f32(0.15)
    calculatedSpeed: float = 0.0
    deadline: float = 0.0
    count: int = 0
    openness: float = 1.0

    def idle_deadline(self, now, draws):
        value = draws.integer(0, self.frequency)
        inverse = 0.0 if not self.frequency else clamp(div(value, self.frequency))
        amount = mul(self.frequency, inverse)
        self.deadline = add(now, mul(0.2, amount))

    def schedule(self, now, draws, closing):
        self.calculatedSpeed = add(self.baseSpeed, draws.floating(0, 0.05))
        self.deadline = add(now, self.calculatedSpeed)
        if closing: self.count = draws.integer(0, 3) + 1
        self.mode = 1 if closing else -1

    def update(self, now, draws):
        remaining = max(0.0, sub(self.deadline, now))
        if self.mode == 0: value = 1.0
        elif self.mode == 1: value = clamp(div(remaining, self.calculatedSpeed))
        else: value = clamp(sub(1, div(remaining, self.calculatedSpeed)))
        if self.fixedFlags == 0: self.openness = value
        if self.fixedFlags or now <= self.deadline: return
        if self.mode == 0: self.schedule(now, draws, True)
        elif self.mode == 1:
            self.count -= 1
            if self.count <= 0: self.schedule(now, draws, False)
        elif self.mode == -1:
            self.idle_deadline(now, draws)
            self.mode = 0

    def action(self, value, draws):
        now = f32(value.get("time", 0))
        operation = value["operation"]
        if operation == "update": self.update(now, draws)
        elif operation == "forceOpen": self.schedule(now, draws, False)
        elif operation == "forceClose": self.schedule(now, draws, True)
        elif operation == "frequency":
            self.frequency = value["value"]
            if self.mode == 0: self.idle_deadline(now, draws)
        elif operation == "speed": self.baseSpeed = max(1.0, f32(value["value"]))
        elif operation == "flags": self.fixedFlags = value["value"]
        else: raise ValueError("Unknown blink action")


@dataclass
class Progress:
    count: float = 0.0
    rate: float = 1.0
    progressTime: float = f32(0.15)

    def start(self): self.count, self.rate = 0.0, 0.0
    def end(self): self.count, self.rate = self.progressTime, 1.0
    def calculate(self, delta):
        self.count = add(self.count, delta)
        if self.count < self.progressTime: self.rate = clamp(div(self.count, self.progressTime))
        else: self.end()
        return self.rate


@dataclass
class RandomProgress:
    minimumTime: float = f32(0.1)
    maximumTime: float = f32(0.2)

    def __post_init__(self): self.progress = Progress()
    def initialize(self, minimum, maximum, draws):
        self.minimumTime, self.maximumTime = f32(minimum), f32(maximum)
        self.progress.progressTime = draws.floating(self.minimumTime, self.maximumTime)
        self.progress.start()
    def calculate(self, delta, draws, minimum=None, maximum=None):
        if minimum is not None:
            self.minimumTime, self.maximumTime = f32(minimum), f32(maximum)
        result = self.progress.calculate(delta)
        if result == 1:
            self.progress.progressTime = draws.floating(self.minimumTime, self.maximumTime)
            self.progress.start()
        return result


def update(time, integers=(), floats=()):
    return {"operation": "update", "time": f32(time), "integers": list(integers), "floats": list(floats)}


def scenarios():
    # Times chosen both from fixed decimal input and exact binary32 deadlines.
    start = f32(0.1)
    close_end = add(start, 0.15)
    opening_start = f32(0.30)
    opening_end = add(opening_start, 0.15)
    return [
        ("initial-idle-strict-deadline", [update(0), update(0.1, [0], [0]), update(close_end),
            update(0.3, [], [0]), update(opening_end), update(0.5, [7]), update(1.8)]),
        ("closed-hold-counts-frames", [update(0.1, [2], [0.05]), update(1), update(1),
            update(1, [], [0.05]), update(1.1), update(1.3, [29])]),
        ("force-open-does-not-immediately-write-rate", [
            {"operation": "forceClose", "time": 0, "integers": [0], "floats": [0]}, update(0.075),
            {"operation": "forceOpen", "time": 0.075, "floats": [0.05]}, update(0.075), update(0.175)]),
        ("fixed-flags-freeze-and-use-negative-sentinel", [update(0.1, [1], [0]), update(0.15),
            {"operation": "flags", "value": 128}, update(100), {"operation": "flags", "value": 0},
            update(100), update(100, [], [0])]),
        ("frequency-zero-and-idle-reschedule", [{"operation": "frequency", "value": 0, "time": 4, "integers": [0]},
            update(4), update(4.01, [0], [0]), {"operation": "frequency", "value": 255, "time": 4.02},
            update(5, [], [0]), update(6, [254])]),
        ("speed-setter-lower-bound-and-overflow-safe-endpoints", [
            {"operation": "speed", "value": -4}, update(1, [0], [0]), update(1.5),
            {"operation": "speed", "value": 2}, update(3, [], [0.05]), update(4)]),
        ("large-time-step-does-not-catch-up", [update(1000, [0], [0]), update(2000, [], [0]), update(3000, [0]),
            update(3000), update(3000.01, [0], [0])]),
        ("force-while-fixed-still-schedules", [{"operation": "flags", "value": 1},
            {"operation": "forceClose", "time": 1, "integers": [2], "floats": [0.02]}, update(2),
            {"operation": "frequency", "value": 1, "time": 2}, {"operation": "flags", "value": 0}, update(2)]),
    ]


def reference():
    result = []
    for name, actions in scenarios():
        state, records = Blink(), []
        for source_action in actions:
            action = deepcopy(source_action)
            draws = Draws(action.get("integers", []), action.get("floats", []))
            state.action(action, draws)
            draws.finish()
            action["expected"] = asdict(state)
            action["expressionBlinkRate"] = -1.0 if state.fixedFlags else state.openness
            action["randomRequests"] = draws.requests
            records.append(action)
        result.append({"name": name, "actions": records})
    progress = Progress()
    timer_actions = []
    for action in [{"operation": "calculate", "delta": 0.075}, {"operation": "end"},
            {"operation": "duration", "value": 0.3}, {"operation": "calculate", "delta": 0},
            {"operation": "start"}, {"operation": "calculate", "delta": 0.1},
            {"operation": "calculate", "delta": 100}, {"operation": "duration", "value": 0},
            {"operation": "start"}, {"operation": "calculate", "delta": 0}]:
        operation = action["operation"]
        if operation == "calculate": action["result"] = progress.calculate(f32(action["delta"]))
        elif operation == "duration": progress.progressTime = f32(action["value"])
        elif operation == "start": progress.start()
        elif operation == "end": progress.end()
        action["expected"] = asdict(progress)
        timer_actions.append(action)
    random = RandomProgress()
    random_actions = []
    for action in [{"operation": "initialize", "minimum": 0.1, "maximum": 0.2, "floats": [0.1]},
            {"operation": "calculate", "delta": 0.05},
            {"operation": "calculate", "delta": 0.05, "floats": [0.2]},
            {"operation": "calculate", "delta": 0.1, "minimum": 0.4, "maximum": 0.5},
            {"operation": "calculate", "delta": 0.1, "floats": [0.4]},
            {"operation": "calculate", "delta": 1000, "floats": [0.5]},
            {"operation": "initialize", "minimum": 0, "maximum": 0, "floats": [0]},
            {"operation": "calculate", "delta": 0, "floats": [0]}]:
        draws = Draws([], action.get("floats", []))
        if action["operation"] == "initialize": random.initialize(action["minimum"], action["maximum"], draws)
        else: action["result"] = random.calculate(f32(action["delta"]), draws, action.get("minimum"), action.get("maximum"))
        draws.finish()
        action["expected"] = asdict(random.progress)
        action["minimumTime"], action["maximumTime"] = random.minimumTime, random.maximumTime
        action["randomRequests"] = draws.requests
        random_actions.append(action)
    return {"schemaVersion": 1, "kind": "ikkoku-source-expression-playback-reference",
            "numberFormat": "IEEE754-binary32", "scenarios": result,
            "progressActions": timer_actions, "randomProgressActions": random_actions}


def evidence():
    manifest = json.loads((REPO / ".local/reverse/decompiled/Expressions/manifest.json").read_text())
    if manifest["assemblySHA256"] != ASSEMBLY_SHA: raise ValueError("Unexpected expression assembly")
    files = [{"file": manifest["assembly"], "sha256": ASSEMBLY_SHA}]
    files += [entry for entry in manifest["types"] if entry["type"] in SOURCE_NAMES]
    if len(files) != len(SOURCE_NAMES) + 1: raise ValueError("Missing expression source evidence")
    for item in files:
        if hashlib.sha256((REPO / item["file"]).read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Expression evidence hash changed: " + item["file"])
    return {"schemaVersion": 1, "source": files, "float32": True,
            "unityRandomAlgorithmTranslated": False,
            "semantics": {"transitionAfterOpenness": True, "deadlineComparison": ">",
                "closedHold": "1..3 expired update calls; not seconds", "fixedFlags": "any nonzero freezes output/state; expression sentinel -1",
                "setSpeed": "max(1, value), while constructor default is 0.15",
                "frameOrder": ["internal blink CalcBlink", "select external controller if present (not advanced here)",
                    "gaze correction", "eyebrow CalcBlend", "eyes CalcBlend", "mouth CalcBlend"]}}


def dependency_inventory():
    manifest_path = REPO / ".local/reverse/decompiled/Animation/manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest["assemblySHA256"] != ASSEMBLY_SHA: raise ValueError("Unexpected animation dependency assembly")
    for item in manifest["types"]:
        if hashlib.sha256((REPO / item["file"]).read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Animation dependency evidence hash changed: " + item["file"])
    systems = [
        {"id": "runtime-controller", "types": ["Illusion.Game.Elements.EasyLoader.Motion", "Illusion.Game.Elements.EasyLoader.BaseMotion", "AnimatorControllerParameterData"],
         "dependencies": ["RuntimeAnimatorController bundle/asset", "state graphs", "blend trees", "transitions", "layer masks", "AnimationClip curves", "Avatar bindings"],
         "nativeStatus": "not-implemented"},
        {"id": "locomotion", "types": ["ActionGame.Chara.Mover.Base", "ActionGame.Chara.Mover.PlayerMover", "ActionGame.Chara.Mover.NPCMover", "ActionGame.Chara.Mover.AgentSpeeder"],
         "dependencies": ["NavMeshAgent", "reactive subscriptions", "AI and arrival state", "physical stat", "Animator Speed/MotionSpeed"],
         "playerStates": ["Idle", "Locomotion", "squat_walk", "squat_loop"],
         "npcStates": ["Idle", "Locomotion", "Locomotion 0", "Locomotion_Anger", "Escape"], "nativeStatus": "not-implemented"},
        {"id": "lip-sync", "types": ["FBSAssist.AudioAssist", "WavInfoControl.WavInfoData"],
         "dependencies": ["1024 channel-zero audio output samples", "RMS and asymmetric smoothing", "optional 100Hz precomputed float curve", "audio playback time", "FBSCtrlMouth"],
         "nativeStatus": "not-implemented"},
        {"id": "gaze", "types": ["EyeLookController", "EyeLookCalc", "NeckLookControllerVer2", "NeckLookCalcVer2"],
         "dependencies": ["eye/neck type settings", "reference transforms", "target history", "delta time", "per-bone rotations", "AnimationCurve"],
         "nativeStatus": "not-implemented"},
        {"id": "motion-ik", "types": ["MotionIK"], "dependencies": ["MotionIKData", "FinalIK full-body biped solver", "source frame/state data", "partner targets"],
         "nativeStatus": "not-implemented"},
        {"id": "secondary-motion", "types": ["DynamicBone"], "dependencies": ["particle hierarchy", "colliders", "per-particle parameters", "transform reset order", "fixed-rate accumulator"],
         "otherSourceTypes": ["DynamicBone_Ver01", "DynamicBone_Ver02"], "nativeStatus": "not-implemented"},
    ]
    recovered = {item["type"] for item in manifest["types"]}
    if any(set(system["types"]) - recovered for system in systems): raise ValueError("Dependency inventory needs missing source types")
    return {"schemaVersion": 1, "assemblySHA256": ASSEMBLY_SHA, "source": manifest["types"],
            "systems": systems, "note": "Recovered source inventory; not a claim of native implementation or complete serialized animation asset coverage."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/animation-playback")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(REPO / ".local"): raise ValueError("Local evidence must remain inside .local")
    output.mkdir(parents=True, exist_ok=True)
    documents = [("contract.json", evidence()), ("reference.json", reference())]
    if (REPO / ".local/reverse/decompiled/Animation/manifest.json").exists():
        documents.append(("dependency-inventory.json", dependency_inventory()))
    for name, data in documents:
        (output / name).write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2) + "\n")
    print(json.dumps({"output": str(output), "scenarios": len(scenarios()),
                      "actions": sum(len(actions) for _, actions in scenarios())}))


if __name__ == "__main__": main()
