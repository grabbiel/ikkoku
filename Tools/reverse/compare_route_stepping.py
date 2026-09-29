#!/usr/bin/env python3
"""Compare the captured per-frame route motion with the per-frame stepper.

Where ``compare_route_playback.py`` matches the continuous analytic evaluator
against the capture and can only absorb the recovered tween's one-frame lag as
a constant frame offset, this driver runs ``studio_route_reference.simulate_frames``
— the per-frame ``TweenUpdate``/``TweenComplete`` rules (apply the current
percentage *before* advancing ``runningTime``, drop each boundary frame's
overshoot, and on a non-loop finish hold the end position and last aim) — over
the capture's own ``deltaTime`` sequence and reports the maximum position error
per route. The probe reads ``Time.deltaTime`` at the start of its iteration and snapshots
``childRoot`` at the start of the *next* frame, after that frame's tween update applied
the running time accumulated through the previous frame, so a row's ``deltaTime`` lags
the row's position by one frame: the tween's first advance consumes row 1's delta
(row 0's is the ``Play`` frame's and is never consumed). Simulating over ``deltas[1:]``
and comparing frames ``0 .. N-2`` reproduces the capture to micrometres; the last row's
post-update state was never recorded.

Rotation follows the ST-T11h finding: each row's Euler is one ``LookUpdate``
SmoothDamp step (fresh zero velocity) from the previous row's Euler toward the
aim the previous row's tween write established, so the rotation column lags
position by one frame, the Play frame's own LateUpdate seeds row 0 on the Play
deltaTime, and the completion frame smooths for the last time before the
Euler freezes. Two smoothTime hypotheses are scored per route:
``defaultsUpdateTime`` (0.05 s, the ``Defaults.updateTime`` fallback route
tweens fall to because they carry neither ``looktime`` nor ``time``) and
``segmentDurationTimes0.0075``; the capture picks the former decisively.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
from analysis import studio_route_reference as ref
from dynamics_contract import REPO

ORIENTATIONS = ("none", "xy", "y")  # OIRouteInfo.Orient ordinal -> reference string
CONNECTIONS = ("line", "curve")     # OIRoutePointInfo.Connection ordinal

# LookUpdate smoothTime hypotheses scored against the capture. Route tweens
# pass "speed" (never "time") and carry no "looktime", so the recovered
# fallback chain lands on Defaults.updateTime; the second entry is the
# rejected alternative (segmentDuration * 0.0075) kept as scored evidence.
SMOOTH_TIME_HYPOTHESES = {
    "defaultsUpdateTime": lambda duration: ref.DEFAULT_UPDATE_TIME,
    "segmentDurationTimes0.0075": lambda duration: duration * 0.0075,
}


def _as_wxyz(quaternion):
    """``simulate_frames``' (w, x, y, z) from a trace-space (x, y, z, w)."""
    x, y, z, w = quaternion
    return (w, x, y, z)


def _as_xyzw(quaternion):
    """Trace-space (x, y, z, w) from a ``from_euler``-style (w, x, y, z)."""
    w, x, y, z = quaternion
    return (x, y, z, w)


def _quaternion_angle(left, right):
    """Degrees between two xyzw unit quaternions (sign-agnostic)."""
    dot = abs(sum(a * b for a, b in zip(left, right)))
    return 2 * math.degrees(math.acos(min(1.0, dot)))


def _route_points(route):
    """Authored route points in the capture's *world* space, so the reference
    evaluator emits ``childRoot`` world positions directly comparable to the
    trace (the captured route object carries no offset of its own)."""
    points = []
    for point in route["points"]:
        connection = CONNECTIONS[point["connection"]]
        aid = point["aidWorldPosition"] if connection == "curve" and point["aidInitialized"] else None
        points.append(ref.RoutePoint(
            position=tuple(point["worldPosition"]), aid=None if aid is None else tuple(aid),
            connection=connection, link=point["link"], speed=point["speed"],
            ease_type=ref.EASE_TYPES[point["easeType"]]))
    return points


def compare_stepping(trace):
    times = [frame["cumulativeTime"] for frame in trace["trace"]]
    deltas = [frame["deltaTime"] for frame in trace["trace"]]
    if not deltas or not all(math.isfinite(d) and d >= 0 for d in deltas):
        raise ValueError("Trace deltaTimes must be finite and non-negative")
    meta = {route["expectedName"]: route for route in trace["routes"]}
    if len(meta) != len(trace["routes"]):
        raise ValueError("Duplicate original route names")
    keys = {name: "a" if name.endswith("-A") else "b" for name in meta}
    routes = {}
    for name, route in meta.items():
        points = _route_points(route)
        recorded = [frame[keys[name]]["position"] for frame in trace["trace"]]
        recorded_rotation = [tuple(frame[keys[name]]["rotation"]) for frame in trace["trace"]]
        orientation = ORIENTATIONS[route["orientation"]]
        entry = {"sourceKey": route["dicKey"], "loop": route["loop"],
                 "orientation": orientation, "pointCount": len(points),
                 "frames": len(deltas), "framesCompared": len(deltas) - 1,
                 "recordOrder": {}}
        for record_after_update in (True, False):
            order = "afterUpdate" if record_after_update else "beforeUpdate"
            # Row 0's deltaTime belongs to the Play frame and the tween never
            # consumed it; every other advance matches the previous row's.
            frames = ref.simulate_frames(points, route["loop"], orientation, deltas[1:],
                                         record_after_update=record_after_update)
            errors = [math.dist(cell.position, vector) for cell, vector in zip(frames, recorded)]
            worst = max(range(len(errors)), key=lambda i: errors[i]) if errors else None
            active_mismatch = sum(1 for i, cell in enumerate(frames)
                                  if cell.active != trace["trace"][i][keys[name]]["active"])
            order_entry = {
                "maximumPositionErrorMetres": max(errors) if errors else None,
                "worstFrame": worst,
                "worstFrameCumulativeSeconds": times[worst] if worst is not None else None,
                "framesActiveMismatch": active_mismatch,
                "rotation": {},
            }
            # Position does not see smoothTime, so each hypothesis re-runs
            # only to score its rotation column against the capture. For an
            # unoriented route LookUpdate never runs and every hypothesis is
            # inertly zero.
            for hypothesis, smooth_time in SMOOTH_TIME_HYPOTHESES.items():
                cells = ref.simulate_frames(
                    points, route["loop"], orientation, deltas[1:],
                    record_after_update=record_after_update,
                    initial_rotation=_as_wxyz(route["points"][0]["worldRotation"]),
                    initial_delta=deltas[0], smooth_time=smooth_time)
                rotation_errors = [_quaternion_angle(_as_xyzw(ref.from_euler(cell.rotation)),
                                                     rotation)
                                   for cell, rotation in zip(cells, recorded_rotation)]
                worst_rotation = (max(range(len(rotation_errors)),
                                      key=lambda i: rotation_errors[i])
                                  if rotation_errors else None)
                order_entry["rotation"][hypothesis] = {
                    "maximumRotationErrorDegrees": (max(rotation_errors)
                                                    if rotation_errors else None),
                    "worstRotationFrame": worst_rotation,
                    "worstRotationFrameCumulativeSeconds": (times[worst_rotation]
                                                            if worst_rotation is not None
                                                            else None),
                }
            entry["recordOrder"][order] = order_entry
        orders = entry["recordOrder"]
        entry["bestRecordOrder"] = min(orders, key=lambda order: orders[order]["maximumPositionErrorMetres"])
        routes[name] = entry
    return {"schemaVersion": 1, "frames": len(deltas), "routes": routes,
            "scope": "Per-frame simulate_frames stepping over the capture deltaTimes, which lag "
                     "their row's snapshot by one frame (the Play frame's delta is never consumed, "
                     "the last row's post-update state was never recorded), versus the original "
                     "childRoot world position and rotation; both probe record orders measured; "
                     "rotation runs the LookUpdate SmoothDamp chain (one damp per row toward the "
                     "previous row's written aim, seeded by Play's LateUpdate on the Play delta, "
                     "frozen from the frame after the non-loop completion) under both smoothTime "
                     "hypotheses; captured rotations are float32-serialised (7 significant "
                     "digits), and the best residual of 0.051112 degrees sits at that "
                     "serialisation floor"}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--probe", type=Path, default=REPO / ".local/stt11c/probe")
    parser.add_argument("--output", type=Path, default=REPO / ".local/stt11c/route-stepping-comparison.json")
    arguments = parser.parse_args()
    if not arguments.output.resolve().is_relative_to((REPO / ".local").resolve()):
        raise ValueError("Original-derived reports stay in .local")
    trace_path = arguments.probe / "route-trace.json"
    result = compare_stepping(json.loads(trace_path.read_text()))
    result["evidence"] = [dict(path=str(path.resolve()), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                          for path in [trace_path, Path(__file__)]]
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
