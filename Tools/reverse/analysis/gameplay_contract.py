"""Bounded source-cycle evidence and independent scalar oracle (no game execution).

Only type names, structural observations, hashes and synthetic traces are emitted.
Decompiled source stays under .local. Native code is not imported or invoked.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct

PERIODS = ("WakeUp", "Morning", "GotoSchool", "HR1", "Lesson1", "LunchTime",
           "Lesson2", "HR2", "StaffTime", "AfterSchool", "GotoMyHouse", "MyHouse")
WEEKS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Holiday")
TIME_ZONES = (0, 0, 0, 0, 0, 1, 1, 1, 2, 3, 3, 4)


def f32(value: float) -> float:
    try:
        return struct.unpack("<f", struct.pack("<f", value))[0]
    except OverflowError:
        return math.copysign(math.inf, value)


class Oracle:
    """Source operations on valid enum states, with explicit native guardrails."""
    def __init__(self, opening=True, week=6):
        self.period = 0 if opening else 11
        self.week = week
        self.opening = opening
        self.timer = 0.0
        self.time_pass = 0.0
        self.visible = False
        self.shuffle = False
        self.active = False

    def snapshot(self):
        return dict(period=self.period, week=self.week, timer=self.timer,
                    timePass=self.time_pass, timerVisible=self.visible,
                    isOpening=self.opening, isShufflePoped=self.shuffle,
                    mapMoveActive=self.active, isAction=self.period in (5, 8, 9),
                    isActionEnd=self.timer >= 500.0)

    def _week(self, value):
        if value not in range(7):
            raise ValueError("invalidWeekAdvance")
        count, cursor = 0, self.week
        while cursor != value:
            cursor = (cursor + 1) % 7
            count += 1
        self.week = value
        return count or 7

    def apply(self, command):
        op = command["op"]
        days = []
        if op == "changeWeek":
            days.append(self._week(command["value"]))
        elif op == "nextWeek":
            raw = (self.week + command.get("value", 1)) & 0xffffffff
            signed = raw if raw < 0x80000000 else raw - 0x100000000
            target = abs(signed) % 7 * (-1 if signed < 0 else 1)
            days.append(self._week(target))
        elif op in ("changePeriod", "nextPeriod"):
            if op == "nextPeriod" and (command.get("returningToTitle", False) or command.get("gameEnded", False)):
                return days
            target = command["value"] if op == "changePeriod" else (self.period + 1) % 12
            if op == "changePeriod" and self.period > target:
                days.append(self._week((self.week + 1) % 7))
            self.period = target
            self.active = False
        elif op == "reloadNightMenuWeek":
            if self.period != 11:
                raise ValueError("nightMenuNotActive")
            self.week = command["value"]
        elif op == "completeNightMenu":
            if self.period != 11:
                raise ValueError("nightMenuNotActive")
            if command.get("returningToTitle", False) or command.get("gameEnded", False):
                return days
            self.shuffle = False
            days.append(self._week((self.week + 1) % 7))
            self.period = 0
            self.active = False
        elif op == "addTimer":
            fraction = f32(command["value"])
            if not math.isfinite(fraction):
                raise ValueError("nonFiniteTimerInput")
            total = f32(self.timer + f32(500.0 * fraction))
            self.timer = max(0.0, min(500.0, total))
        elif op == "actionEnd":
            self.timer = 500.0
        elif op == "beginMapMove":
            if self.period not in (5, 8, 9) or self.week == 6:
                raise ValueError("mapMoveNotAvailable")
            self.timer = self.time_pass = 0.0
            self.visible = self.active = self.shuffle = True
            self.opening = False
        elif op == "tickMapMove":
            if not self.active:
                raise ValueError("mapMoveNotActive")
            delta = f32(command["deltaTime"])
            if not math.isfinite(delta) or delta < 0:
                raise ValueError("invalidFrameDelta")
            if command["cursorLocked"] and not command["gameRegulated"]:
                value = f32(self.timer + delta)
                if not math.isfinite(value):
                    raise ValueError("nonFiniteTimerInput")
                self.timer = value
            self.time_pass = f32(self.timer / 500.0)
            self.visible = not any(command.get(key, False) for key in
                                   ("advProcessing", "talkSceneActive", "interactionSceneActive"))
        elif op == "finishMapMove":
            if not self.active or self.timer < 500.0:
                raise ValueError("mapMoveNotActive")
            self.active = False
            self.time_pass = 1.0
            self.visible = True
        else:
            raise ValueError(f"unknown operation: {op}")
        return days


def trace(name, commands, opening=True, week=6):
    oracle = Oracle(opening, week)
    result = dict(name=name, initial=dict(isOpening=opening, week=week), steps=[])
    for command in commands:
        try:
            days = oracle.apply(command)
            error = None
        except ValueError as exc:
            days, error = [], str(exc)
        result["steps"].append(dict(command=command, state=oracle.snapshot(), elapsedCharacterDays=days, error=error))
    return result


def fixtures():
    cases = []
    for first in range(12):
        for second in range(12):
            cases.append(trace(f"period-{first}-{second}", [
                dict(op="changePeriod", value=first), dict(op="changePeriod", value=second)], week=0))
    for first in range(7):
        for second in range(7):
            cases.append(trace(f"weekday-{first}-{second}", [dict(op="changeWeek", value=second)], week=first))
        for plus in (-8, -7, -1, 0, 1, 6, 7, 14, 2147483647):
            cases.append(trace(f"next-week-{first}-{plus}", [dict(op="nextWeek", value=plus)], week=first))
    cases += [
        trace("next-wrap-does-not-age", [dict(op="nextPeriod") for _ in range(25)], opening=False, week=5),
        trace("night-week-wrap", [dict(op="completeNightMenu")], opening=False),
        trace("loaded-night-save-does-not-age", [dict(op="reloadNightMenuWeek", value=2), dict(op="completeNightMenu")], opening=False),
        trace("title-interruption", [dict(op="nextPeriod", returningToTitle=True), dict(op="completeNightMenu", gameEnded=True)], opening=False),
        trace("timer-control", [
            dict(op="changePeriod", value=5), dict(op="beginMapMove"),
            dict(op="tickMapMove", deltaTime=10, cursorLocked=False, gameRegulated=False),
            dict(op="tickMapMove", deltaTime=10, cursorLocked=True, gameRegulated=True, talkSceneActive=True),
            dict(op="tickMapMove", deltaTime=10, cursorLocked=True, gameRegulated=False, advProcessing=True),
            dict(op="addTimer", value=.5), dict(op="addTimer", value=-.25),
            dict(op="tickMapMove", deltaTime=366, cursorLocked=True, gameRegulated=False),
            dict(op="finishMapMove"), dict(op="changePeriod", value=8), dict(op="beginMapMove"),
            dict(op="actionEnd"), dict(op="tickMapMove", deltaTime=.25, cursorLocked=True, gameRegulated=False),
            dict(op="finishMapMove"), dict(op="addTimer", value=-10), dict(op="addTimer", value=3.4028234e38)
        ], week=0),
        trace("holiday-skips-map-move", [dict(op="changePeriod", value=5), dict(op="beginMapMove")]),
        trace("invalid-timer-phase", [dict(op="tickMapMove", deltaTime=1, cursorLocked=True, gameRegulated=False),
                                     dict(op="finishMapMove"), dict(op="completeNightMenu")]),
        trace("negative-delta", [dict(op="changePeriod", value=9), dict(op="beginMapMove"),
                                 dict(op="tickMapMove", deltaTime=-1, cursorLocked=True, gameRegulated=False)], week=5),
    ]
    return dict(schemaVersion=1, periods=list(PERIODS), weeks=list(WEEKS), timeZones=list(TIME_ZONES), cases=cases)


def source_evidence(source_root: Path, assembly: Path):
    evidence = []
    for path in [assembly, *sorted(source_root.glob("*.cs"))]:
        data = path.read_bytes()
        if not data:
            continue
        evidence.append(dict(path=str(path), bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                             decompilationErrors=data.count(b"Error decompiling")))
    cycle = (source_root / "ActionGame.Cycle.cs").read_text()
    save = (source_root / "SaveData.cs").read_text()
    for enum, expected in (("Type", PERIODS), ("Week", WEEKS)):
        body = re.search(r"public enum " + enum + r"\s*\{([^}]+)\}", cycle).group(1)
        actual = tuple(item.strip() for item in body.split(",") if item.strip())
        if actual != expected:
            raise ValueError(f"source {enum} enum does not match recovered contract")
    required = ("public const int TIME_LIMIT = 500;", "public const int EVENT_LIMIT = 499;",
                "if (!isNextCall && nowType > type)", "cnt = length;", "isNextCall = true;",
                "_timer += Time.deltaTime;", "timeCtrl.timePass = _timer / 500f;")
    if not all(text in cycle for text in required) or "public int week = 6;" not in save or "private bool _isOpening = true;" not in save:
        raise ValueError("source cycle/default evidence differs from the translated version")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--assembly", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = fixtures()
    result["sourceEvidence"] = source_evidence(args.source_root, args.assembly)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(output=str(args.output), cases=len(result["cases"]),
                          steps=sum(len(case["steps"]) for case in result["cases"]),
                          sourceFiles=len(result["sourceEvidence"]))))


if __name__ == "__main__":
    main()
