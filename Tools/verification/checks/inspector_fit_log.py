#!/usr/bin/env python3
"""Validate the inspector fit log of one Studio UI capture (#333).

Used after `studio-inspector-clothes-fit-capture` (app-smoke), which starts the
Debug app through the UI capture path (IKKOKU_CAPTURE_UI with
IKKOKU_CAPTURE_UI_STUDIO_TAB=clothes and IKKOKU_CAPTURE_UI_SELECT=0,622,963,
the start that #319's `ui-sel-clothes` capture uses) with
IKKOKU_CAPTURE_UI_FIT_LOG=<this script's argument>. The app replaces that log
on a launch's first line, so it holds one launch.

usage: inspector_fit_log.py LOG [--selection KEY] [--tab NAME] [--pose-picker]

Passes only when the log has exactly one "captured" line, that line shows the
expected selection and tab (when given), the inspector's document view is no
wider than its clip view, and the accessibility fit check after the capture
says "fits true" (`InspectorUIScenario.inspectorFit`: no element past the
visible width, judged by `InspectorFitRule`). A log without the inspector's
scroll view, the state of #333's bad captures, fails.
With --pose-picker (#363), the capture must also show the toolbar's pose-mode
picker (Object/FK/IK, from the fit log's layout probe) laid out at its
intrinsic width: under a fixed frame narrower than the control it was laid out
compressed on a fresh build and at full width on a rebuild.
"""
import re
import sys

CAPTURED = re.compile(r"^\s*[0-9.]+ captured ")
CLIP = re.compile(r" clip (\d+) document (\d+) ")
POSE = re.compile(r"\bpose x -?[0-9.]+\+([0-9.]+) .*?intrinsic ([0-9.]+)")


def validate_log(text, selection=None, tab=None, pose_picker=False):
    """Return (passed: bool, reasons: [str], detail: str) for one fit log's text."""
    captured = [line for line in text.splitlines() if CAPTURED.match(line)]
    if len(captured) != 1:
        return False, ["%d captured lines, expected exactly 1" % len(captured)], ""
    line = captured[0]
    reasons = []
    if selection is not None and (" selection %s " % selection) not in line:
        reasons.append("the capture does not show selection %s" % selection)
    if tab is not None and (" tab %s " % tab) not in line:
        reasons.append("the capture does not show tab %s" % tab)
    clip = CLIP.search(line)
    if clip is None:
        reasons.append("no inspector scroll view at the capture")
    elif int(clip.group(2)) > int(clip.group(1)) + 1:
        reasons.append("document %s pt is wider than clip %s pt" % (clip.group(2), clip.group(1)))
    if pose_picker:
        pose = POSE.search(line.split("| fits ", 1)[0])
        if pose is None:
            reasons.append("no pose-mode picker in the toolbar at the capture")
        elif abs(float(pose.group(1)) - float(pose.group(2))) > 0.5:
            reasons.append("the pose-mode picker is %s pt wide, not its intrinsic %s pt" % (pose.group(1), pose.group(2)))
    fit = line.split("| fits ", 1)
    detail = fit[1] if len(fit) == 2 else ""
    if not detail.startswith("true:"):
        reasons.append("the accessibility fit check says %r" % (detail[:300] or "nothing"))
    return not reasons, reasons, detail


def main(argv):
    args = argv[1:]
    pose_picker = "--pose-picker" in args
    args = [arg for arg in args if arg != "--pose-picker"]
    options = {}
    while len(args) >= 2 and args[-2] in ("--selection", "--tab"):
        options[args[-2][2:]] = args[-1]
        args = args[:-2]
    if len(args) != 1:
        print("usage: inspector_fit_log.py LOG [--selection KEY] [--tab NAME] [--pose-picker]", file=sys.stderr)
        return 2
    try:
        with open(args[0], "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        # A missing log is a failure, not a skip.
        print("FAIL: cannot read %s: %s" % (args[0], exc))
        return 1
    passed, reasons, detail = validate_log(text, options.get("selection"), options.get("tab"), pose_picker)
    if not passed:
        for reason in reasons:
            print("FAIL: " + reason)
        return 1
    print("PASS: " + detail)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
