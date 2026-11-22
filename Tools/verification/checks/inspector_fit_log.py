#!/usr/bin/env python3
"""Validate the inspector fit log of one Studio UI capture (#333).

Used after `studio-inspector-clothes-fit-capture` (app-smoke), which starts the
Debug app through the UI capture path (IKKOKU_CAPTURE_UI with
IKKOKU_CAPTURE_UI_STUDIO_TAB=clothes and IKKOKU_CAPTURE_UI_SELECT=0,622,963,
the start that #319's `ui-sel-clothes` capture uses) with
IKKOKU_CAPTURE_UI_FIT_LOG=<this script's argument>. The app replaces that log
on a launch's first line, so it holds one launch.

usage: inspector_fit_log.py LOG [--selection KEY] [--tab NAME] [--pose-picker] [--toolbar-fits]
                             [--object-heights NAME VECTOR]

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
With --toolbar-fits (#425), at the capture's window width the Studio toolbar
must fit without its scroll view in Object, FK and IK mode (its full or its
compact variant, by the ideal widths the app logs after the capture), and the
variant shown must be the first that fits the state shown (ViewThatFits' order:
full, compact, then compact in a scroll view).
With --object-heights NAME VECTOR (#366), at the capture the heights measured
from an AppKit prototype (`InspectorTextFieldHeight`: SwiftUI's automatic style
and the Transform fields' `.roundedBorder`) must be NAME and VECTOR pt, the Name
field's intrinsic height NAME, and every other editable field's (the Transform
rows on the Object tab) VECTOR. That checks the prototype against SwiftUI's own
fields on this machine, and the AppKit Name field (`InspectorNameField`) against
SwiftUI's automatic style. Frame heights are not checked: one capture cannot
show a rate.
"""
import re
import sys

CAPTURED = re.compile(r"^\s*[0-9.]+ captured ")
CLIP = re.compile(r" clip (\d+) document (\d+) ")
POSE = re.compile(r"\bpose x -?[0-9.]+\+([0-9.]+) .*?intrinsic ([0-9.]+)")
VARIANT = re.compile(r"; variant (full|compact|scroll|none)(?: width ([0-9.]+) available ([0-9.]+|\?))?( \(both markers\))?")
NAME = re.compile(r"\| name height ([0-9.]+) intrinsic ([0-9.]+)")
HEIGHTS = re.compile(r"\| heights name ([0-9.]+) vector ([0-9.]+) fields (none|[0-9.,]+)")
IDEAL = re.compile(r"\| toolbar ideal none ([0-9.]+)/([0-9.]+) object ([0-9.]+)/([0-9.]+) fk ([0-9.]+)/([0-9.]+)"
                   r" ik ([0-9.]+)/([0-9.]+) state (none|object|fk|ik)\b")


def toolbar_reasons(head):
    """#425: why the toolbar does not fit or shows the wrong variant, from the captured line before "| fits"."""
    variant, ideal = VARIANT.search(head), IDEAL.search(head)
    if variant is None or ideal is None:
        return ["no toolbar variant or ideal widths in the fit log at the capture"]
    if variant.group(3) in (None, "?"):
        return ["no available toolbar width in the fit log at the capture"]
    available = float(variant.group(3))
    numbers = [float(value) for value in ideal.groups()[:8]]
    widths = dict(zip(("none", "object", "fk", "ik"), zip(numbers[0::2], numbers[1::2])))
    reasons = []
    if variant.group(4):
        reasons.append("the window holds both the full and the compact toolbar")
    for mode in ("object", "fk", "ik"):
        full, compact = widths[mode]
        if min(full, compact) > available + 0.5:
            reasons.append("in %s mode the toolbar does not fit: full %g pt, compact %g pt, available %g pt"
                           % (mode, full, compact, available))
    state = ideal.group(9)
    full, compact = widths[state]
    expected = "full" if full <= available + 0.5 else "compact" if compact <= available + 0.5 else "scroll"
    if variant.group(1) != expected:
        reasons.append("the toolbar shows %s, expected %s for state %s (full %g pt, compact %g pt, available %g pt)"
                       % (variant.group(1), expected, state, full, compact, available))
    return reasons


def heights_reasons(head, name_height, vector_height):
    """#366: why the explicit text-field heights or the fields' intrinsic heights at the capture are not the
    expected ones, from the captured line before "| fits"."""
    heights, name = HEIGHTS.search(head), NAME.search(head)
    if heights is None:
        return ["no explicit text-field heights in the fit log at the capture"]
    if name is None:
        return ["no name field in the inspector at the capture"]
    reasons = []
    for label, value, expected in (("Name", heights.group(1), name_height), ("Transform", heights.group(2), vector_height)):
        if abs(float(value) - expected) > 0.5:
            reasons.append("the explicit %s field height is %s pt, expected %g pt" % (label, value, expected))
    if abs(float(name.group(2)) - name_height) > 0.5:
        reasons.append("the Name field's intrinsic height is %s pt, expected %g pt" % (name.group(2), name_height))
    if heights.group(3) == "none":
        reasons.append("no editable field besides the Name field at the capture")
    else:
        fields = heights.group(3).split(",")
        wrong = [value for value in fields if abs(float(value) - vector_height) > 0.5]
        if wrong:
            reasons.append("%d of %d fields have intrinsic heights %s pt, expected %g pt"
                           % (len(wrong), len(fields), ", ".join(wrong), vector_height))
    return reasons


def validate_log(text, selection=None, tab=None, pose_picker=False, toolbar_fits=False, object_heights=None):
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
    if toolbar_fits:
        reasons.extend(toolbar_reasons(line.split("| fits ", 1)[0]))
    if object_heights is not None:
        reasons.extend(heights_reasons(line.split("| fits ", 1)[0], *object_heights))
    fit = line.split("| fits ", 1)
    detail = fit[1] if len(fit) == 2 else ""
    if not detail.startswith("true:"):
        reasons.append("the accessibility fit check says %r" % (detail[:300] or "nothing"))
    return not reasons, reasons, detail


def main(argv):
    args = argv[1:]
    pose_picker = "--pose-picker" in args
    toolbar_fits = "--toolbar-fits" in args
    args = [arg for arg in args if arg not in ("--pose-picker", "--toolbar-fits")]
    object_heights = None
    if "--object-heights" in args:
        at = args.index("--object-heights")
        try:
            object_heights = (float(args[at + 1]), float(args[at + 2]))
        except (IndexError, ValueError):
            print("--object-heights needs two heights in points", file=sys.stderr)
            return 2
        args = args[:at] + args[at + 3:]
    options = {}
    while len(args) >= 2 and args[-2] in ("--selection", "--tab"):
        options[args[-2][2:]] = args[-1]
        args = args[:-2]
    if len(args) != 1:
        print("usage: inspector_fit_log.py LOG [--selection KEY] [--tab NAME] [--pose-picker] [--toolbar-fits]"
              " [--object-heights NAME VECTOR]", file=sys.stderr)
        return 2
    try:
        with open(args[0], "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        # A missing log is a failure, not a skip.
        print("FAIL: cannot read %s: %s" % (args[0], exc))
        return 1
    passed, reasons, detail = validate_log(text, options.get("selection"), options.get("tab"), pose_picker, toolbar_fits,
                                           object_heights)
    if not passed:
        for reason in reasons:
            print("FAIL: " + reason)
        return 1
    print("PASS: " + detail)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
