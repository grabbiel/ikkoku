#!/usr/bin/env python3
"""Recover selected Studio bone tables and independently evaluate FK contracts.

Only explicitly supplied local files are read. Derived proprietary data stays
under ignored .local; the checked-in implementation contains no asset catalog.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import math

import numpy as np

REPO = Path(__file__).resolve().parents[3]
ASSEMBLY_SHA = "902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45"
FK_PARTS = (128, 256, 512, 1, 32, 64, 1024)
IK_PARTS = (1, 2, 4, 8, 16)


def bone_group(category: int, *, guide=False) -> int:
    if not 0 <= category <= 13:
        raise ValueError("Only the recovered 0...13 classifications are supported")
    if category <= 4:
        return 1 | (1 << category) if guide else 1
    return 128 if category in (7, 8, 9) else 256 if category == 10 else 512 if category in (11, 12) else 1024 if category == 13 else 1 << category


def source_matrix(euler, translation=(0, 0, 0), scale=(1, 1, 1)):
    """Independent row-major matrix products; no native quaternion helper."""
    values = np.asarray([euler, translation, scale], dtype=np.float64)
    if values.shape != (3, 3) or not np.isfinite(values).all():
        raise ValueError("Expected three finite component vectors")
    x, y, z = np.radians(euler)
    cx, cy, cz, sx, sy, sz = math.cos(x), math.cos(y), math.cos(z), math.sin(x), math.sin(y), math.sin(z)
    rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    reflect = np.diag([1, 1, -1])
    result = np.eye(4)
    result[:3, :3] = reflect @ ry @ rx @ rz @ reflect @ np.diag(scale)
    result[:3, 3] = translation  # Current frame is already in native coordinates.
    return result.tolist()


class ActivationOracle:
    """Reference activation state transcribed independently from OCIChar.

    Target reset bookkeeping is by FK group here. Native binding tests exercise
    target identity and hierarchy search separately.
    """
    def __init__(self):
        self.fk = self.ik = False
        self.fk_preferences = [False, True, False, True, False, False, False]
        self.ik_preferences = [True] * 5
        self.targets = dict.fromkeys(FK_PARTS, True)
        self.neck = self.old_neck = 2
        self.breast = [True, False]
        self.pv = [True, False, True, False]
        self.events = []
        self.resets = []

    def activate_fk(self, mask, active, force=False):
        for i, group in enumerate(FK_PARTS):
            if not mask & group:
                continue
            if not force:
                changed = self.fk_preferences[i] != active
                self.fk_preferences[i] = active
                if not changed or not self.fk:
                    continue
            if group == 256:
                if active:
                    self.old_neck, self.neck = self.neck, 4
                else:
                    self.neck = self.old_neck
                self.events.append(["neck", self.neck])
            if group == 512:
                self.events.append(["breast", not active and self.breast[0], not active and self.breast[1]])
            if self.targets[group] != active:
                self.targets[group] = active
                if not active and group in (128, 1, 1024):
                    self.resets.append(group)
            if group in (128, 1024):
                self.events.append(["hair" if group == 128 else "skirt", not active])
            self.events.append(["fkGuide", group, active if force else self.fk and self.fk_preferences[i]])

    def activate_ik(self, mask, active, force=False):
        for i, group in enumerate(IK_PARTS):
            if not mask & group:
                continue
            if not force:
                changed = self.ik_preferences[i] != active
                self.ik_preferences[i] = active
                if not changed:
                    continue
            self.events.extend([["ikWeights", group, 1 if active else 0],
                                ["ikGuide", group, active if force else self.ik and self.ik_preferences[i]]])

    def activate_mode(self, mode, active, force=False):
        if mode == "fk":
            if force or self.fk != active:
                self.fk = active
                for i, group in enumerate(FK_PARTS):
                    self.activate_fk(group, active and self.fk_preferences[i], True)
                if self.fk:
                    self.activate_mode("ik", False, force)
        elif mode == "ik":
            if force or self.ik != active:
                self.ik = active
                for i, group in enumerate(IK_PARTS):
                    self.activate_ik(group, active and self.ik_preferences[i], True)
                if self.ik:
                    self.activate_mode("fk", False, force)
        else:
            raise ValueError("Unknown mode")
        self.events.append(["pv", *[not self.fk and enabled for enabled in self.pv]])

    def command(self, command):
        self.events = []; self.resets = []
        if command[0] == "mode":
            self.activate_mode(*command[1:])
        elif command[0] == "fk":
            self.activate_fk(*command[1:])
        elif command[0] == "ik":
            self.activate_ik(*command[1:])
        else:
            raise ValueError("Unknown command")
        return {"command": command, "events": self.events, "resetGroups": self.resets,
                "enableFK": self.fk, "enableIK": self.ik, "activeFK": self.fk_preferences.copy(),
                "activeIK": self.ik_preferences.copy(), "neck": self.neck, "previousNeck": self.old_neck,
                "enabledTargets": [self.targets[group] for group in FK_PARTS]}


def synthetic_oracle():
    matrix_cases = []
    for index, angles in enumerate([(0, 0, 0), (90, 0, 0), (0, 90, 0), (0, 0, 90),
                                     (23, -41, 67), (450, -720, 1080), (-89.9, 179, -179)]):
        position, scale = [1.25, -2.5, 3.75], [0.5, 2, 3]
        matrix_cases.append({"id": index, "degrees": angles, "translation": position, "scale": scale,
                             "nativeMatrixRows": source_matrix(angles, position, scale)})
    oracle = ActivationOracle()
    commands = [["fk", 32, True, False], ["mode", "fk", True, False],
                ["fk", 1, False, False], ["fk", 1, False, True],
                ["fk", 256, True, True], ["fk", 256, False, True],
                ["mode", "ik", True, False], ["ik", 8, False, False],
                ["mode", "fk", True, True], ["mode", "fk", False, False],
                ["ik", 8, True, False], ["mode", "ik", False, True]]
    return {"schemaVersion": 1, "matrixCases": matrix_cases,
            "groupCases": [{"sourceGroup": value, "fkGroup": bone_group(value), "guideGroup": bone_group(value, guide=True)} for value in range(14)],
            "activationCases": [oracle.command(command) for command in commands]}


def read_catalog(bundle: Path):
    import UnityPy
    if not bundle.is_file() or bundle.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("Explicit Studio info bundle must exist and be at most 32 MiB")
    table_name = "Bone_" + bundle.stem
    tables = [obj.read_typetree() for obj in UnityPy.load(str(bundle)).objects if obj.type.name == "MonoBehaviour"]
    matches = [table for table in tables if table.get("m_Name") == table_name]
    if len(matches) != 1:
        raise ValueError("Expected exactly one matching original bone table")
    entries = {}
    for row, item in enumerate(matches[0]["list"][1:], 1):
        values = item["list"]
        try:
            key = int(values[0])
        except (ValueError, IndexError):
            continue
        if not -(2**31) <= key < 2**31:
            continue
        if len(values) < 2:
            raise ValueError("Malformed required bone catalog row")
        if not values[1]:
            continue
        if len(values) < 5:
            raise ValueError("Malformed required bone catalog row")
        category, level = int(values[3]), int(values[4])
        bone_group(category)
        entries[key] = {"id": key, "name": values[1], "group": category, "level": level, "sourceRow": row}
    return list(entries.values())


def evidence(path: Path):
    data = path.read_bytes()
    return {"path": str(path.resolve()), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def write_local(path: Path, value):
    if not path.resolve().is_relative_to(REPO / ".local"):
        raise ValueError("Recovered contracts must remain under ignored .local")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=REPO / ".local/reverse/source/abdata/studio/info/00.unity3d")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/studio-pose/contract.json")
    args = parser.parse_args()
    assembly = REPO / ".local/reverse/managed/CharaStudio/Assembly-CSharp.dll"
    if evidence(assembly)["sha256"] != ASSEMBLY_SHA:
        raise ValueError("Studio assembly does not match this recovered behavioral contract")
    source_dir = REPO / ".local/reverse/decompiled/Studio"
    types = ["Studio.FKCtrl", "Studio.OCIChar", "Studio.OICharInfo", "Studio.OIBoneInfo", "Studio.AddObjectAssist",
             "Studio.Info", "Studio.Utility", "Studio.ChangeAmount", "IllusionUtility.GetUtility.TransformFindEx",
             "Studio.Preparation", "Studio.IKCtrl", "Studio.GuideObject", "Studio.SceneInfo", "Studio.CharAnimeCtrl",
             "Studio.AddObjectFemale", "Studio.AddObjectMale", "Studio.OCIRoute", "Studio.AddObjectRoute", "Studio.VoiceCtrl",
             "UniRx.ReactiveProperty", "UniRx.BoolReactiveProperty"]
    contract = {"schemaVersion": 1, "kind": "ikkoku-source-studio-pose", "assembly": evidence(assembly),
                "supportingAssemblies": [evidence(assembly.with_name("Assembly-CSharp-firstpass.dll"))],
                "sourceEvidence": [evidence(source_dir / (name + ".cs")) for name in types],
                "catalogSource": evidence(args.bundle), "bones": read_catalog(args.bundle),
                "scope": "FK activation and absolute local rotation; IK/dynamics/neck/guide/PV effects require native consumers",
                "oracle": synthetic_oracle()}
    write_local(args.output, contract)
    print(json.dumps({"output": str(args.output), "bones": len(contract["bones"]), "sourceFiles": len(types), "matrixCases": len(contract["oracle"]["matrixCases"])}))


if __name__ == "__main__":
    main()
