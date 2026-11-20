#!/usr/bin/env python3
"""Validate that a performance-trace launch mounted its launch-time plug-in profile (#459).

Used as the second check of the `app-smoke` pair: `studio-launch-plugins-perf`
runs the Debug app as a short performance trace (IKKOKU_PERF_TRACE, not a timing
measurement) with IKKOKU_SOURCE_SCENE and IKKOKU_SOURCE_PLUGIN_PROFILE, so the
scene imports in the background; this script reads the trace's JSON report.

Passes only when the report shows that the Studio execution inputs waited for
the background import and then mounted the profile against the imported scene:
`details.launchStudioExecution.appliedAfterImport` is true, its `inputs` include
IKKOKU_SOURCE_PLUGIN_PROFILE, at least one plug-in package is mounted and at
least one character was built, and the startup scene was ready
(`summary.startupMainThread.ready`). Before #459 the inputs bound to the empty
document before the import committed, and the commit dropped what they mounted,
so no report carried `launchStudioExecution`. A missing file, malformed JSON or
any missing key fails the check.
"""
import json
import sys

PROFILE = "IKKOKU_SOURCE_PLUGIN_PROFILE"


def validate_report(data):
    """Return (passed: bool, reasons: [str]) for one performance-trace report."""
    if not isinstance(data, dict):
        return False, ["report is not a JSON object"]
    reasons = []
    launch = (data.get("details") or {}).get("launchStudioExecution")
    if not isinstance(launch, dict):
        reasons.append("details.launchStudioExecution is missing: the launch inputs did not run after the import")
    else:
        if launch.get("appliedAfterImport") is not True:
            reasons.append("appliedAfterImport is %r, expected true" % (launch.get("appliedAfterImport"),))
        if PROFILE not in (launch.get("inputs") or []):
            reasons.append("inputs %r do not include %s" % (launch.get("inputs"), PROFILE))
        for key in ("sourcePluginPackages", "charactersBuilt"):
            value = launch.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value < 1:
                reasons.append("%s is %r, expected at least 1" % (key, value))
    ready = ((data.get("summary") or {}).get("startupMainThread") or {}).get("ready")
    if ready is not True:
        reasons.append("summary.startupMainThread.ready is %r, expected true" % (ready,))
    return not reasons, reasons


def main(argv):
    if len(argv) != 2:
        print("usage: studio_launch_plugins.py <performance-trace report.json>")
        return 2
    try:
        with open(argv[1], encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        print("FAIL: cannot read %s: %s" % (argv[1], error))
        return 1
    passed, reasons = validate_report(data)
    if passed:
        launch = data["details"]["launchStudioExecution"]
        print("PASS: launch inputs %s applied after the background import; %d plug-in packages mounted, %d characters built"
              % (", ".join(launch["inputs"]), launch["sourcePluginPackages"], launch["charactersBuilt"]))
        return 0
    for reason in reasons:
        print("FAIL: " + reason)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
