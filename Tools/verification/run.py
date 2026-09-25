#!/usr/bin/env python3
"""Manifest-driven local verification runner (T-T04/E-T03/CMT-11).

Runs a small set of declared checks at the repository root, records a JSON
report under .local/verification, and distinguishes passed / failed / skipped
results. Stdlib only; no network, no shell.

Usage:
  python3 Tools/verification/run.py --manifest PATH [--environment PATH]
      [--report PATH] [--strict] [--timeout SECONDS]

Manifest (schemaVersion 1):
  {"schemaVersion": 1, "checks": [
     {"id": "name", "argv": ["cmd", ...],
      "fixtures": [{"env": "IKKOKU_...", "kind": "file"|"directory"}],
      "minimumTests": 3}]}

Fixture env values come from the --environment JSON map (or the process
environment). Only IKKOKU_-prefixed names are accepted. Missing fixtures are
skipped normally and failed under --strict; existing but unreadable/malformed
fixtures are always failed. Strict runs set IKKOKU_REQUIRE_SOURCE_FIXTURES=1
for selected commands; normal runs never inherit a strict flag.
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
MAX_TREE_ENTRIES = 4096
MAX_TREE_BYTES = 512 * 1024 * 1024
MAX_FILE_BYTES = 256 * 1024 * 1024
SWIFT_TEST_RE = re.compile(r"Test run with (\d+) tests?")
UNITTEST_RE = re.compile(r"Ran (\d+) tests?")


class RunnerError(Exception):
    pass


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
    """Return (record, status) where status is ok/missing/malformed."""
    name, kind = spec["env"], spec["kind"]
    value = env_map.get(name)
    record = {"env": name, "kind": kind, "path": value, "sha256": None, "tree": None}
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


def load_manifest(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or data.get("schemaVersion") != 1:
        raise RunnerError("manifest schemaVersion must be 1")
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
        minimum = check.get("minimumTests")
        if minimum is not None and (not isinstance(minimum, int) or minimum < 0):
            raise RunnerError("minimumTests must be a non-negative integer: %s" % check["id"])
    return checks


def parse_test_count(output):
    match = SWIFT_TEST_RE.search(output) or UNITTEST_RE.search(output)
    return int(match.group(1)) if match else None


def git_info():
    info = {"revision": None, "dirty": None}
    try:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
                                  capture_output=True, text=True, timeout=10)
        if revision.returncode == 0:
            info["revision"] = revision.stdout.strip()
        status = subprocess.run(["git", "status", "--porcelain"], cwd=REPO_ROOT,
                                capture_output=True, text=True, timeout=10)
        if status.returncode == 0:
            info["dirty"] = bool(status.stdout.strip())
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


def run_check(check, env_map, strict, timeout, log_dir):
    record = {"id": check["id"], "argv": check["argv"], "status": "failed",
              "exitCode": None, "elapsedSeconds": None, "logPath": None,
              "fixtures": [], "testCount": None, "minimumTests": check.get("minimumTests"),
              "error": None}
    missing = malformed = False
    for spec in check.get("fixtures", []):
        fixture, status = fixture_record(spec, env_map)
        record["fixtures"].append(fixture)
        if status == "missing":
            missing = True
        elif status == "malformed":
            malformed = True
    if malformed:
        record["error"] = "fixture malformed or unreadable"
        return record
    if missing:
        record["status"] = "failed" if strict else "skipped"
        record["error"] = "missing fixture" + (" (strict)" if strict else "")
        return record
    log_path = os.path.join(log_dir, record["id"] + ".log")
    record["logPath"] = log_path
    env = dict(os.environ)
    env.update(env_map)
    if strict:
        env["IKKOKU_REQUIRE_SOURCE_FIXTURES"] = "1"
    started = time.monotonic()
    try:
        with open(log_path, "wb") as log:
            process = subprocess.run(check["argv"], cwd=REPO_ROOT, env=env,
                                     stdout=log, stderr=subprocess.STDOUT,
                                     timeout=timeout)
        record["exitCode"] = process.returncode
    except subprocess.TimeoutExpired:
        record["status"] = "failed"
        record["error"] = "timeout after %ss" % timeout
        record["elapsedSeconds"] = round(time.monotonic() - started, 3)
        return record
    except OSError as exc:
        record["status"] = "failed"
        record["error"] = "command could not start: %s" % exc
        record["elapsedSeconds"] = round(time.monotonic() - started, 3)
        return record
    record["elapsedSeconds"] = round(time.monotonic() - started, 3)
    output = ""
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
            output = handle.read()
    except OSError:
        pass
    record["testCount"] = parse_test_count(output)
    if process.returncode != 0:
        record["error"] = "command exited %d" % process.returncode
        return record
    minimum = check.get("minimumTests")
    if minimum is not None:
        count = record["testCount"]
        if count is None:
            record["error"] = "could not parse test count from output"
        elif count < minimum:
            record["error"] = "test count %d below minimumTests %d" % (count, minimum)
        else:
            record["status"] = "passed"
    else:
        record["status"] = "passed"
    return record


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
    records = [run_check(check, env_map, args.strict, args.timeout, log_dir)
               for check in checks]
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for record in records:
        counts[record["status"]] += 1
    report = {
        "schemaVersion": 1,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started)),
        "endedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "elapsedSeconds": round(time.time() - started, 3),
        "platform": platform.platform(),
        "git": git_info(),
        "runnerHash": runner_hash(),
        "strict": args.strict,
        "timeoutSeconds": args.timeout,
        "manifest": os.path.abspath(args.manifest),
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
