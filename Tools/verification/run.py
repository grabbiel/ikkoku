#!/usr/bin/env python3
"""Manifest-driven local verification runner (T-T04/E-T03/CMT-11).

Runs a small set of declared checks at the repository root, records a JSON
report under .local/verification, and distinguishes passed / failed / skipped
results. Stdlib only; no network, no shell.

Usage:
  python3 Tools/verification/run.py --manifest PATH [--environment PATH]
      [--report PATH] [--strict] [--timeout SECONDS]

Manifest (schemaVersion 2):
  {"schemaVersion": 2, "checks": [
     {"id": "name", "argv": ["cmd", ...],
      "fixtures": [{"env": "IKKOKU_...", "kind": "file"|"directory"}],
      "env": {"IKKOKU_SETTING": "value"},
      "minimumTests": 3, "maximumSkipped": 0,
      "referenceTier": "synthetic"|"recovered-code-oracle"|
                       "original-managed-dll"|"original-player-probe"|
                       "app-smoke",
      "tolerance": "free text",
      "artifacts": [{"path": "Tools/...", "kind": "tool-output"}],
      "timeout": 600}]}

Fixture env values come from the --environment JSON map (never inherited
from the shell; that is the point of E-T03). Only IKKOKU_-prefixed names
are accepted. A check whose declared REQUIRED fixture is not supplied
there is skipped (failed under --strict); an optional fixture that is not
supplied is recorded in missingFixtures and does NOT skip the check, so a
suite can run with whatever data exists (--strict turns any missing
fixture, optional or not, into a failure). A supplied-but-unreadable
fixture is always failed. Per-test results are parsed from swift-testing
and unittest output; minimumTests applies to executed (passed + failed)
tests, maximumSkipped bounds declared skips. The report records the git
revision, the dirty flag and hash of `git diff HEAD`, the runner and
manifest hashes, captured tool versions, and per check: argv, cwd, the
check's own env settings, passedEnvironment (IKKOKU_* names only),
suppliedFixtures/missingFixtures with paths and hashes, reference tier,
tolerance, artifact hashes (taken after the run; a missing artifact
fails the check), exit code, elapsed time and the log path/hash.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LOCAL_DIR = os.path.join(REPO_ROOT, ".local", "verification")
ALLOWED_ENV_PREFIX = "IKKOKU_"
FORBIDDEN_ENV_NAMES = {"PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "PYTHONPATH"}
REFERENCE_TIERS = ("synthetic", "recovered-code-oracle", "original-managed-dll",
                   "original-player-probe", "app-smoke")
MAX_TREE_ENTRIES = 4096
MAX_TREE_BYTES = 512 * 1024 * 1024
MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_TESTS_LISTED = 500

# swift-testing lines as observed on this machine; `Test run with …` is the
# summary line (total INCLUDES skipped; executed = passed + failed). The
# skip reason is optional and the bare `skipped.` form ends with a period.
SWIFT_PASSED_RE = re.compile(r"^\s*✔ Test ((?!run ).+?) passed after ([0-9.]+) seconds?\.\s*$")
SWIFT_SKIPPED_RE = re.compile(r"^\s*➜ Test ((?!run ).+?) skipped(?:\.(?:.*)|: \"(.*)\")\s*$")
SWIFT_FAILED_RE = re.compile(r"^\s*✘ Test ((?!run ).+?) (?:failed\b.*|recorded an issue\b.*)")
SWIFT_TOTAL_RE = re.compile(r"Test run with (\d+) tests?")
SWIFT_ISSUES_RE = re.compile(r"Test run with \d+ tests?.*? with (\d+) issues?")
# unittest summary lines. Real runs print only the nonzero count fields, in
# any subset: "FAILED (failures=1)", "FAILED (errors=1, skipped=1)",
# "OK (skipped=2, expected failures=1)", "FAILED (... unexpectedsuccesses=1)".
UNITTEST_RAN_RE = re.compile(r"^Ran (\d+) tests?", re.MULTILINE)
UNITTEST_SUMMARY_RE = re.compile(r"^(?:OK|FAILED)(?: \((.*?)\))?\s*$", re.MULTILINE)
# Normalised summary keys counted as FAILED: expected failures are passes.
# Unknown keys are ignored rather than guessed.
UNITTEST_FAILED_KEYS = {"failures", "errors", "unexpectedsuccesses"}


class RunnerError(Exception):
    pass


def artifact_path(path):
    """Resolve an artifact inside the repository, including symlinked parents."""
    root = os.path.realpath(REPO_ROOT)
    resolved = os.path.realpath(os.path.join(root, path))
    if os.path.isabs(path) or os.path.commonpath([root, resolved]) != root:
        raise RunnerError("artifact path must stay inside the repository: %s" % path)
    return resolved


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hash_directory(path):
    """Deterministic child hashes for a bounded tree; rejects symlink escapes."""
    entries = []
    total_bytes = 0
    for root, dirs, files in os.walk(path, followlinks=False):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            if os.path.islink(full):
                raise RunnerError("symlink in fixture tree: %s" % name)
            size = os.path.getsize(full)
            total_bytes += size
            if total_bytes > MAX_TREE_BYTES:
                raise RunnerError("fixture tree exceeds byte bound")
            entries.append((os.path.relpath(full, path), sha256_file(full)))
        if len(entries) > MAX_TREE_ENTRIES:
            raise RunnerError("fixture tree exceeds entry bound")
    return {"entries": len(entries), "bytes": total_bytes,
            "children": [{"path": p, "sha256": h} for p, h in entries]}


def fixture_record(spec, env_map):
    """Return (record, status) where status is ok/missing/malformed.

    An optional fixture that is not supplied is recorded as missing but
    must not skip the check; supplied-but-bad paths are always failures.
    """
    name, kind = spec["env"], spec["kind"]
    value = env_map.get(name)
    record = {"env": name, "kind": kind, "path": value, "sha256": None,
              "tree": None, "optional": bool(spec.get("optional"))}
    if value is None:
        return record, "missing"
    path = os.path.abspath(value)
    record["path"] = path
    try:
        if kind == "file":
            if not os.path.isfile(path) or os.path.getsize(path) > MAX_FILE_BYTES:
                raise RunnerError("not a readable file")
            record["sha256"] = sha256_file(path)
        else:
            if not os.path.isdir(path):
                raise RunnerError("not a directory")
            record["tree"] = hash_directory(path)
    except (OSError, RunnerError) as exc:
        record["error"] = str(exc)
        return record, "malformed"
    return record, "ok"


def load_environment(path):
    if path is None:
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise RunnerError("environment file must be a JSON object")
    for key, value in data.items():
        if not key.startswith(ALLOWED_ENV_PREFIX) or key in FORBIDDEN_ENV_NAMES:
            raise RunnerError("environment override not allowed: %s" % key)
        if not isinstance(value, str):
            raise RunnerError("environment value must be a string: %s" % key)
    return data


def validate_manifest(data):
    """Return checks after schema validation; raise RunnerError on problems."""
    if not isinstance(data, dict) or data.get("schemaVersion") != 2:
        raise RunnerError("manifest schemaVersion must be 2")
    checks = data.get("checks")
    if not isinstance(checks, list) or not checks:
        raise RunnerError("manifest checks must be a non-empty list")
    seen = set()
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("id"), str) or not check["id"]:
            raise RunnerError("check id must be a non-empty string")
        if check["id"] in seen:
            raise RunnerError("duplicate check id: %s" % check["id"])
        seen.add(check["id"])
        argv = check.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            raise RunnerError("check argv must be a non-empty string array: %s" % check["id"])
        fixtures = check.get("fixtures", [])
        if not isinstance(fixtures, list):
            raise RunnerError("check fixtures must be a list: %s" % check["id"])
        for spec in fixtures:
            if not isinstance(spec, dict) or not isinstance(spec.get("env"), str) \
                    or spec.get("kind") not in ("file", "directory"):
                raise RunnerError("fixture needs env and kind file|directory: %s" % check["id"])
            if not spec["env"].startswith(ALLOWED_ENV_PREFIX):
                raise RunnerError("fixture env must start with IKKOKU_: %s" % spec["env"])
            if not isinstance(spec.get("optional", False), bool):
                raise RunnerError("fixture optional must be a bool: %s" % check["id"])
        for bound in ("minimumTests", "maximumSkipped"):
            value = check.get(bound)
            if value is not None and (not isinstance(value, int) or isinstance(value, bool)
                                       or value < 0):
                raise RunnerError("%s must be a non-negative integer: %s" % (bound, check["id"]))
        tier = check.get("referenceTier")
        if tier not in REFERENCE_TIERS:
            raise RunnerError("referenceTier must be one of %s: %s"
                              % (list(REFERENCE_TIERS), check["id"]))
        tolerance = check.get("tolerance")
        if tolerance is not None and not isinstance(tolerance, str):
            raise RunnerError("tolerance must be free text: %s" % check["id"])
        artifacts = check.get("artifacts", [])
        if not isinstance(artifacts, list):
            raise RunnerError("artifacts must be a list: %s" % check["id"])
        for artifact in artifacts:
            if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str) \
                    or not isinstance(artifact.get("kind"), str):
                raise RunnerError("artifact needs path and kind: %s" % check["id"])
            artifact_path(artifact["path"])
        timeout = check.get("timeout")
        if timeout is not None and (not isinstance(timeout, (int, float))
                                     or isinstance(timeout, bool) or timeout <= 0):
            raise RunnerError("timeout must be a positive number: %s" % check["id"])
        env = check.get("env", {})
        if not isinstance(env, dict):
            raise RunnerError("check env must be a map: %s" % check["id"])
        for name in env:
            if not isinstance(name, str) or not name.startswith(ALLOWED_ENV_PREFIX) \
                    or name in FORBIDDEN_ENV_NAMES:
                raise RunnerError("env name must be an allowed IKKOKU_* key: %s" % name)
            if not isinstance(env[name], str):
                raise RunnerError("env value must be a string: %s/%s" % (check["id"], name))
    return checks


def load_manifest(path):
    with open(path, "r", encoding="utf-8") as handle:
        return validate_manifest(json.load(handle))


def _test_result(parser, total, executed, counts, tests):
    listed = sorted(tests, key=lambda t: t["name"])[:MAX_TESTS_LISTED]
    return {"parser": parser, "total": total, "executed": executed,
            "counts": counts, "tests": listed}


def _merge_test(status, name, reason, per_test, reasons):
    """Record the worst status seen for a test name (fail beats skip)."""
    rank = {"passed": 1, "skipped": 2, "failed": 3}
    known = per_test.get(name)
    if known is None or rank[status] >= rank[known[0]]:
        per_test[name] = (status, reason)
    if name not in per_test or per_test[name][0] == status:
        reasons[name] = reason


def _test_counts(per_test):
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for status, _reason in per_test.values():
        counts[status] += 1
    return counts


def parse_swift_testing(output):
    """Per-test results plus the summary total, or None if nothing parsed.

    `Test run with N …` totals INCLUDE skipped tests, so when per-test
    records exist they dominate the counts; otherwise executed falls back
    to total − skipped and everything else counts as passed.
    """
    per_test = {}
    reasons = {}
    total = None
    for line in output.splitlines():
        summary = SWIFT_TOTAL_RE.search(line)
        if summary:
            total = int(summary.group(1))
            continue
        for pattern, status in ((SWIFT_PASSED_RE, "passed"),
                                (SWIFT_SKIPPED_RE, "skipped"),
                                (SWIFT_FAILED_RE, "failed")):
            match = pattern.match(line)
            if match:
                # Only skip lines carry a reason (optional on the first
                # group-tuple entry that is not a duration).
                reason = match.group(2) if status == "skipped" else None
                _merge_test(status, match.group(1), reason, per_test, reasons)
                break

    if not per_test and total is None:
        return None
    if per_test:
        counts = _test_counts(per_test)
        executed = counts["passed"] + counts["failed"]
    else:
        # Only the summary line parsed: attribute everything to passed.
        counts = {"passed": total, "failed": 0, "skipped": 0}
        executed = total
    return _test_result("swift-testing", total, executed, counts,
                         [{"name": n, "status": s, "reason": reasons.get(n)}
                          for n, (s, _r) in per_test.items()])


def parse_unittest(output):
    """Per-test results plus the summary counts, or None if nothing parsed."""
    ran = UNITTEST_RAN_RE.search(output)
    summary = UNITTEST_SUMMARY_RE.search(output)
    if ran is None or summary is None:
        return None
    total = int(ran.group(1))

    # Map `name (module.Class.name) ... skipped 'Reason'` / `... FAIL`
    # lines; the worst outcome wins per test name.
    per_test = {}
    reasons = {}
    for match in re.finditer(r"^\s?(.+?) \((?:[^()]*)\) \.\.\. "
                             r"(skipped(?: '(.*)')?|ok|FAIL|ERROR)$",
                             output, re.MULTILINE):
        name = match.group(1)
        status = match.group(2).split(" ")[0]
        if status in ("ok", "ERROR"):
            status = {"ok": "passed", "ERROR": "failed"}[status]
        _merge_test(status, name, match.group(3), per_test, reasons)

    if per_test:
        counts = _test_counts(per_test)
        executed = counts["passed"] + counts["failed"]
    else:
        # Only summary lines parsed; counts come straight from them.
        counts = {"passed": 0, "failed": 0, "skipped": 0}
        for key, value in re.findall(r"([A-Za-z ]+)=(\d+)",
                                      summary.group(1) or ""):
            normalised = key.lower().replace(" ", "")
            if normalised in UNITTEST_FAILED_KEYS:
                counts["failed"] += int(value)
            elif normalised == "skipped":
                counts["skipped"] = int(value)
        counts["passed"] = total - counts["failed"] - counts["skipped"]
        executed = total - counts["skipped"]
    return _test_result("unittest", total, executed, counts,
                         [{"name": n, "status": s, "reason": reasons.get(n)}
                          for n, (s, _r) in per_test.items()])


def select_parser(argv):
    """Pick the test-output parser for a command, or None when unknown."""
    program = os.path.basename(argv[0]) if argv else ""
    if program == "swift" or program.endswith("-swift"):
        return parse_swift_testing
    if program.startswith("python"):
        return parse_unittest
    return None


def run_check(check, env_map, strict, default_timeout, log_dir):
    record = {"id": check["id"], "argv": check["argv"], "cwd": ".", "status": "failed",
              "exitCode": None, "elapsedSeconds": None, "logPath": None,
              "logSha256": None, "suppliedFixtures": [], "missingFixtures": [],
              "artifacts": [], "env": dict(check.get("env", {})),
              "passedEnvironment": [],
              "referenceTier": check["referenceTier"],
              "tolerance": check.get("tolerance"),
              "tests": None, "error": None}
    missing_required = []
    malformed = False
    for spec in check.get("fixtures", []):
        fixture, status = fixture_record(spec, env_map)
        if status == "missing":
            record["missingFixtures"].append(fixture)
            if not spec.get("optional"):
                missing_required.append(spec["env"])
        elif status == "malformed":
            # A supplied-but-unreadable fixture is always a hard failure.
            record["suppliedFixtures"].append(fixture)
            malformed = True
        else:
            record["suppliedFixtures"].append(fixture)
    if record["missingFixtures"] and (missing_required or strict):
        names = ", ".join(f["env"] for f in record["missingFixtures"])
        record["status"] = "skipped" if not strict else "failed"
        record["error"] = ("missing fixture: %s" % names
                           + (" (strict)" if strict else ""))
        return record
    if malformed:
        record["error"] = "fixture malformed or unreadable"
        return record

    env = {name: value for name, value in os.environ.items()
           if not name.startswith(ALLOWED_ENV_PREFIX)}
    env.update({spec["env"]: env_map[spec["env"]]
                for spec in check.get("fixtures", []) if spec["env"] in env_map})
    env.update(check.get("env", {}))
    if strict:
        env["IKKOKU_REQUIRE_SOURCE_FIXTURES"] = "1"
    record["passedEnvironment"] = sorted(
        name for name in env if name.startswith(ALLOWED_ENV_PREFIX))

    try:
        for artifact in check.get("artifacts", []):
            os.makedirs(os.path.dirname(artifact_path(artifact["path"])), exist_ok=True)
    except (OSError, RunnerError) as exc:
        record["error"] = str(exc)
        return record

    timeout = check.get("timeout", default_timeout)
    log_path = os.path.join(log_dir, record["id"] + ".log")
    record["logPath"] = os.path.relpath(log_path, REPO_ROOT)
    started = time.monotonic()
    record["timeoutSeconds"] = timeout
    try:
        with open(log_path, "wb") as log:
            process = subprocess.run(check["argv"], cwd=REPO_ROOT, env=env,
                                     stdout=log, stderr=subprocess.STDOUT,
                                     timeout=timeout)
        record["exitCode"] = process.returncode
    except subprocess.TimeoutExpired:
        record["error"] = "timeout after %ss" % timeout
        record["elapsedSeconds"] = round(time.monotonic() - started, 3)
        return record
    except OSError as exc:
        record["error"] = "command could not start: %s" % exc
        record["elapsedSeconds"] = round(time.monotonic() - started, 3)
        return record
    record["elapsedSeconds"] = round(time.monotonic() - started, 3)

    with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
        output = handle.read()
    parser = select_parser(check["argv"])
    record["tests"] = parser(output) if parser else None

    if process.returncode != 0:
        record["error"] = "command exited %d" % process.returncode
        return record

    minimum = check.get("minimumTests")
    maximum_skipped = check.get("maximumSkipped")
    if minimum is not None or maximum_skipped is not None:
        if record["tests"] is None:
            record["error"] = "could not parse test results from output"
            return record
        if minimum is not None and record["tests"]["executed"] is not None \
                and record["tests"]["executed"] < minimum:
            record["error"] = "executed test count %d below minimumTests %d" \
                              % (record["tests"]["executed"], minimum)
            return record
        if maximum_skipped is not None:
            skipped = record["tests"]["counts"].get("skipped", 0)
            if skipped > maximum_skipped:
                record["error"] = "skipped test count %d above maximumSkipped %d" \
                                  % (skipped, maximum_skipped)
                return record

    # Artifacts are hashed after the run (built binaries, produced reports).
    for artifact in check.get("artifacts", []):
        entry = {"path": artifact["path"], "kind": artifact["kind"], "sha256": None}
        try:
            path = artifact_path(artifact["path"])
            if not os.path.isfile(path) or os.path.getsize(path) > MAX_FILE_BYTES:
                raise RunnerError("artifact missing or oversized")
            entry["sha256"] = sha256_file(path)
        except (OSError, RunnerError) as exc:
            entry["error"] = str(exc)
            record["artifacts"].append(entry)
            record["error"] = "artifact %s not hashed: %s" % (artifact["path"], exc)
            return record
        record["artifacts"].append(entry)

    record["logSha256"] = sha256_file(log_path)
    record["status"] = "passed"
    return record


def collect_tool_versions():
    versions = {}
    for label, argv in (("swift --version", ["swift", "--version"]),
                        ("xcodebuild -version", ["xcodebuild", "-version"]),
                        ("python3 --version", ["python3", "--version"])):
        try:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
            versions[label] = result.stdout.strip() if result.returncode == 0 else None
        except (OSError, subprocess.SubprocessError):
            versions[label] = None
    return versions


def git_info():
    info = {"revision": None, "dirty": None, "diffHeadSha256": None}
    try:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
                                  capture_output=True, text=True, timeout=10)
        if revision.returncode == 0:
            info["revision"] = revision.stdout.strip()
        status = subprocess.run(["git", "status", "--porcelain"], cwd=REPO_ROOT,
                                capture_output=True, text=True, timeout=10)
        if status.returncode == 0:
            info["dirty"] = bool(status.stdout.strip())
        if info["dirty"]:
            diff = subprocess.run(["git", "diff", "HEAD"], cwd=REPO_ROOT,
                                  capture_output=True, text=True, timeout=60)
            if diff.returncode == 0:
                info["diffHeadSha256"] = hashlib.sha256(
                    diff.stdout.encode("utf-8")).hexdigest()
    except (OSError, subprocess.SubprocessError):
        pass
    return info


def runner_hash():
    return sha256_file(os.path.abspath(__file__))


def resolve_report_path(requested):
    if requested is None:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = os.path.join(LOCAL_DIR, "report-%s.json" % stamp)
    else:
        path = os.path.abspath(requested)
    if os.path.commonpath([path, LOCAL_DIR]) != LOCAL_DIR:
        raise RunnerError("report must live under %s" % LOCAL_DIR)
    if os.path.exists(path):
        raise RunnerError("report already exists, refusing to overwrite: %s" % path)
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--environment")
    parser.add_argument("--report")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--timeout", type=float, default=240.0)
    args = parser.parse_args(argv)
    try:
        checks = load_manifest(os.path.abspath(args.manifest))
        env_map = load_environment(args.environment)
        report_path = resolve_report_path(args.report)
    except (RunnerError, OSError, ValueError, json.JSONDecodeError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    log_dir = os.path.join(os.path.dirname(report_path), "logs")
    os.makedirs(log_dir, exist_ok=True)
    started = time.time()
    versions = collect_tool_versions()
    records = [run_check(check, env_map, args.strict, args.timeout, log_dir)
               for check in checks]
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for record in records:
        counts[record["status"]] += 1
    report = {
        "schemaVersion": 2,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started)),
        "endedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "elapsedSeconds": round(time.time() - started, 3),
        "platform": platform.platform(),
        "git": git_info(),
        "runner": {"path": os.path.relpath(os.path.abspath(__file__), REPO_ROOT),
                   "sha256": runner_hash()},
        "manifest": {"path": os.path.relpath(os.path.abspath(args.manifest), REPO_ROOT),
                     "sha256": sha256_file(os.path.abspath(args.manifest))},
        "toolVersions": versions,
        "strict": args.strict,
        "timeoutSeconds": args.timeout,
        "counts": counts,
        "checks": records,
    }
    with open(report_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")
    print("report: %s" % report_path)
    print("passed=%d failed=%d skipped=%d" % (counts["passed"], counts["failed"], counts["skipped"]))
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
