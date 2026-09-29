#!/usr/bin/env python3
"""Validate one Studio-inspector capture report written by the app.

Used as the second `app-smoke` lane check: the first check runs the Debug
app with IKKOKU_SOURCE_SCENE/IKKOKU_SOURCE_AVATAR supplied plus
IKKOKU_CAPTURE_UI / IKKOKU_CAPTURE_UI_MODE=studio /
IKKOKU_CAPTURE_UI_STUDIO_TAB=pose / IKKOKU_CAPTURE_UI_REPORT=<this
file's argument>; this script then validates the produced JSON.

Passes only when the report proves the source character's pose tab was
reachable in the built app: `selectedIsSourceCharacter` must be true,
`inspectorView` must be exactly "SourcePoseInspector", and when the
model-derived `expectedInspectorView` key is present it must equal
`inspectorView`. Anything else — missing file, malformed JSON,
wrong/missing keys — fails the check.
"""
import json
import sys

EXPECTED_VIEW = "SourcePoseInspector"


def validate_report(data):
    """Return (passed: bool, reasons: [str]) for one report object."""
    reasons = []
    if not isinstance(data, dict):
        return False, ["report is not a JSON object"]
    if data.get("selectedIsSourceCharacter") is not True:
        reasons.append("selectedIsSourceCharacter is %r, expected true"
                       % (data.get("selectedIsSourceCharacter"),))
    if data.get("inspectorView") != EXPECTED_VIEW:
        reasons.append("inspectorView is %r, expected %r"
                       % (data.get("inspectorView"), EXPECTED_VIEW))
    if "expectedInspectorView" in data \
            and data["expectedInspectorView"] != data.get("inspectorView"):
        reasons.append("expectedInspectorView is %r, inspectorView is %r"
                       % (data["expectedInspectorView"],
                          data.get("inspectorView")))
    return (not reasons, reasons)


def main(argv):
    if len(argv) != 2:
        print("usage: studio_inspector_report.py <report.json>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "r", encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        # Missing output is a failure, not a skip (app integration gate).
        print("cannot read report: %s" % exc, file=sys.stderr)
        return 1
    passed, reasons = validate_report(report)
    if passed:
        print("studio inspector report validates: source pose inspector reached")
        return 0
    for reason in reasons:
        print("failed: %s" % reason, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
