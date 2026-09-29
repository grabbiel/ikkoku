#!/usr/bin/env python3
"""Independent route/tween math reference ported from recovered CharaStudio code.

This is a plain transliteration of the recovered C# so the native Swift
evaluator can be compared against it. Sources (all private, decompiled):

- ``OCIRoute.cs`` 240–400: ``Play()`` builds ONE ``StudioTween`` whose
  segment list comes from ``SetPath`` (a ``Line`` segment connects the point
  and the next point; a ``Curve`` segment connects the point, its aid target
  and any following *linked* curve points' [point, aid] pairs, then the next
  point; the last point wraps to point 0 when looping; a non-looping route
  skips the last point's segment).
- ``OCIRoutePoint.cs`` 96–172: ``transform`` = [point, aid target];
  ``isLink`` = ``link && connection == Curve``.
- ``OIRoutePointInfo.cs``: speed default 2, easeType default linear,
  Connection Line/Curve, link flag. ``OIRouteInfo.cs``: loop, orient.
- ``StudioTween.cs``: ``MoveTo(Hashtable)`` 3704 (appends a segment),
  ``GenerateMoveToPathTargets`` 1177 (speed → time = PathLength/speed),
  ``ApplyMoveToPathTargets`` 1691 (orient to path; ``Defaults`` lookahead
  0.05 — the rotation itself is a stateful ``LookUpdate`` 2418 LateUpdate
  SmoothDamp pass this reference does not simulate, so only the
  instantaneous aim is emitted), ``PathLength`` 2492,
  ``PathControlPointGenerator`` 3299 and
  ``Interp`` 3322 (Catmull-Rom), ``GetEasingFunction`` 3488,
  ``UpdatePercentage`` 3591, the 32 easing functions from 3726 and the
  ``EaseType`` enum at line 17.

Only the evaluator is implemented here: no UI, no rendering, no playback.
Arithmetic stays in float64 in both this reference and the Swift port, so the
two agree far inside the 1e-5 comparison tolerance; neither claims bit-exact
Unity float32 equality.
"""
from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Sequence

REPO = Path(__file__).resolve().parents[3]

Vec = tuple[float, float, float]


class RouteNotPlayable(Exception):
    """Route data failed a source-derived precondition.

    ``evaluate`` and ``build_segments`` raise this instead of guessing a
    path, matching the repository rule of explicit boundary diagnostics.
    """


# ---------------------------------------------------------------------------
# Easing (StudioTween.cs 3726+, dispatched from GetEasingFunction at 3488).
# Each function keeps the source ``(start, end, value)`` signature; the
# tween always calls it as ``ease(0f, 1f, percentage)``.

def linear(start: float, end: float, value: float) -> float:
    return start + (end - start) * value


def spring(start: float, end: float, value: float) -> float:
    value = min(max(value, 0.0), 1.0)
    value = (math.sin(value * math.pi * (0.2 + 2.5 * value ** 3)) * (1 - value) ** 2.2 + value) \
        * (1 + 1.2 * (1 - value))
    return start + (end - start) * value


def ease_in_quad(s: float, e: float, v: float) -> float:
    return e * v * v + s


def ease_out_quad(s: float, e: float, v: float) -> float:
    return -e * v * (v - 2) + s


def ease_in_out_quad(s: float, e: float, v: float) -> float:
    v /= 0.5
    if v < 1:
        return e / 2 * v * v + s
    v -= 1
    return -e / 2 * (v * (v - 2) - 1) + s


def ease_in_cubic(s: float, e: float, v: float) -> float:
    return e * v * v * v + s


def ease_out_cubic(s: float, e: float, v: float) -> float:
    return e * ((v - 1) ** 3 + 1) + s


def ease_in_out_cubic(s: float, e: float, v: float) -> float:
    v /= 0.5
    if v < 1:
        return e / 2 * v * v * v + s
    v -= 2
    return e / 2 * (v * v * v + 2) + s


def ease_in_quart(s: float, e: float, v: float) -> float:
    return e * v ** 4 + s


def ease_out_quart(s: float, e: float, v: float) -> float:
    return -e * ((v - 1) ** 4 - 1) + s


def ease_in_out_quart(s: float, e: float, v: float) -> float:
    v /= 0.5
    if v < 1:
        return e / 2 * v ** 4 + s
    v -= 2
    return -e / 2 * (v ** 4 - 2) + s


def ease_in_quint(s: float, e: float, v: float) -> float:
    return e * v ** 5 + s


def ease_out_quint(s: float, e: float, v: float) -> float:
    return e * ((v - 1) ** 5 + 1) + s


def ease_in_out_quint(s: float, e: float, v: float) -> float:
    v /= 0.5
    if v < 1:
        return e / 2 * v ** 5 + s
    v -= 2
    return e / 2 * (v ** 5 + 2) + s


def ease_in_sine(s: float, e: float, v: float) -> float:
    return -e * math.cos(v * math.pi / 2) + e + s


def ease_out_sine(s: float, e: float, v: float) -> float:
    return e * math.sin(v * math.pi / 2) + s


def ease_in_out_sine(s: float, e: float, v: float) -> float:
    return -e / 2 * (math.cos(v * math.pi) - 1) + s


def ease_in_expo(s: float, e: float, v: float) -> float:
    return e * 2 ** (10 * (v - 1)) + s


def ease_out_expo(s: float, e: float, v: float) -> float:
    return e * (-2 ** (-10 * v) + 1) + s


def ease_in_out_expo(s: float, e: float, v: float) -> float:
    v /= 0.5
    if v < 1:
        return e / 2 * 2 ** (10 * (v - 1)) + s
    v -= 1
    return e / 2 * (2 - 2 ** (-10 * v)) + s


def ease_in_circ(s: float, e: float, v: float) -> float:
    return -e * (math.sqrt(max(0.0, 1 - v * v)) - 1) + s


def ease_out_circ(s: float, e: float, v: float) -> float:
    return e * math.sqrt(max(0.0, 1 - (v - 1) ** 2)) + s


def ease_in_out_circ(s: float, e: float, v: float) -> float:
    v /= 0.5
    if v < 1:
        return -e / 2 * (math.sqrt(max(0.0, 1 - v * v)) - 1) + s
    v -= 2
    return e / 2 * (math.sqrt(max(0.0, 1 - v * v)) + 1) + s


def ease_in_bounce(s: float, e: float, v: float) -> float:
    return e - ease_out_bounce(0, e, 1 - v) + s


def ease_out_bounce(s: float, e: float, v: float) -> float:
    if v < 372 / 1023:
        return e * (7.5625 * v * v) + s
    if v < 744 / 1023:
        v -= 558 / 1023
        return e * (7.5625 * v * v + 0.75) + s
    if v < 930 / 1023:
        v -= 837 / 1023
        return e * (7.5625 * v * v + 0.9375) + s
    v -= 21 / 22
    return e * (7.5625 * v * v + 63 / 64) + s


def ease_in_out_bounce(s: float, e: float, v: float) -> float:
    if v < 0.5:
        return ease_in_bounce(0, e, v * 2) * 0.5 + s
    return ease_out_bounce(0, e, v * 2 - 1) * 0.5 + e * 0.5 + s


def ease_in_back(s: float, e: float, v: float) -> float:
    c = 1.70158
    return e * v * v * ((c + 1) * v - c) + s


def ease_out_back(s: float, e: float, v: float) -> float:
    c = 1.70158
    v -= 1
    return e * (v * v * ((c + 1) * v + c) + 1) + s


def ease_in_out_back(s: float, e: float, v: float) -> float:
    c = 1.70158
    v /= 0.5
    if v < 1:
        return e / 2 * (v * v * ((c * 1.525 + 1) * v - c * 1.525)) + s
    v -= 2
    return e / 2 * (v * v * ((c * 1.525 + 1) * v + c * 1.525) + 2) + s


def _elastic_constants(e: float) -> tuple[float, float, float]:
    """``period``/``s``/``amplitude`` as computed in the three elastic
    functions: amplitude starts at 0, so the ``num4 == 0`` branch always
    takes ``amplitude = end`` and ``s = period / 4``."""
    period = 0.3
    return period, period / 4, e


def ease_in_elastic(s: float, e: float, v: float) -> float:
    if v == 0:
        return s
    if v == 1:
        return s + e
    period, quarter, amplitude = _elastic_constants(e)
    return -amplitude * 2 ** (10 * (v - 1)) * math.sin((v - quarter) * math.pi * 2 / period) + s


def ease_out_elastic(s: float, e: float, v: float) -> float:
    if v == 0:
        return s
    if v == 1:
        return s + e
    period, quarter, amplitude = _elastic_constants(e)
    return amplitude * 2 ** (-10 * v) * math.sin((v - quarter) * math.pi * 2 / period) + e + s


def ease_in_out_elastic(s: float, e: float, v: float) -> float:
    if v == 0:
        return s
    v /= 0.5
    if v == 2:
        return s + e
    period, quarter, amplitude = _elastic_constants(e)
    if v < 1:
        return -0.5 * (amplitude * 2 ** (10 * (v - 1)) * math.sin((v - quarter) * math.pi * 2 / period)) + s
    return amplitude * 2 ** (-10 * (v - 1)) * math.sin((v - quarter) * math.pi * 2 / period) * 0.5 + e + s


# ``EaseType`` order from StudioTween.cs line 17; the route record stores the
# ordinal as ``easeType`` (default ``linear``), so keep the sequence stable.
EASE_TYPES: tuple[str, ...] = (
    "easeInQuad", "easeOutQuad", "easeInOutQuad",
    "easeInCubic", "easeOutCubic", "easeInOutCubic",
    "easeInQuart", "easeOutQuart", "easeInOutQuart",
    "easeInQuint", "easeOutQuint", "easeInOutQuint",
    "easeInSine", "easeOutSine", "easeInOutSine",
    "easeInExpo", "easeOutExpo", "easeInOutExpo",
    "easeInCirc", "easeOutCirc", "easeInOutCirc",
    "linear", "spring",
    "easeInBounce", "easeOutBounce", "easeInOutBounce",
    "easeInBack", "easeOutBack", "easeInOutBack",
    "easeInElastic", "easeOutElastic", "easeInOutElastic",
)

EASING: dict[str, Callable[[float, float, float], float]] = {
    "easeInQuad": ease_in_quad, "easeOutQuad": ease_out_quad, "easeInOutQuad": ease_in_out_quad,
    "easeInCubic": ease_in_cubic, "easeOutCubic": ease_out_cubic, "easeInOutCubic": ease_in_out_cubic,
    "easeInQuart": ease_in_quart, "easeOutQuart": ease_out_quart, "easeInOutQuart": ease_in_out_quart,
    "easeInQuint": ease_in_quint, "easeOutQuint": ease_out_quint, "easeInOutQuint": ease_in_out_quint,
    "easeInSine": ease_in_sine, "easeOutSine": ease_out_sine, "easeInOutSine": ease_in_out_sine,
    "easeInExpo": ease_in_expo, "easeOutExpo": ease_out_expo, "easeInOutExpo": ease_in_out_expo,
    "easeInCirc": ease_in_circ, "easeOutCirc": ease_out_circ, "easeInOutCirc": ease_in_out_circ,
    "linear": linear, "spring": spring,
    "easeInBounce": ease_in_bounce, "easeOutBounce": ease_out_bounce, "easeInOutBounce": ease_in_out_bounce,
    "easeInBack": ease_in_back, "easeOutBack": ease_out_back, "easeInOutBack": ease_in_out_back,
    "easeInElastic": ease_in_elastic, "easeOutElastic": ease_out_elastic,
    "easeInOutElastic": ease_in_out_elastic,
}

DEFAULT_EASE = "linear"
DEFAULT_SPEED = 2.0
# ``Defaults.lookAhead`` (StudioTween.cs ~98) as used by ApplyMoveToPathTargets.
LOOK_AHEAD = 0.05


# ---------------------------------------------------------------------------
# Catmull-Rom path helpers (Interp 3322, PathControlPointGenerator 3299,
# PathLength 2492 — PathLength and Interp both run on the padded array).

def interp(pts: Sequence[Sequence[float]], t: float) -> Vec:
    """Port of ``Interp`` / ``CRSpline.Interp``: pick the control span that
    covers ``t`` over ``pts.Length − 3`` spans and evaluate it."""
    spans = len(pts) - 3
    if spans < 1:
        raise RouteNotPlayable("control point array too short to interpolate")
    segment = min(math.floor(t * spans), spans - 1)
    u = t * spans - segment
    p0, p1, p2, p3 = pts[segment], pts[segment + 1], pts[segment + 2], pts[segment + 3]
    return tuple(
        0.5 * ((-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * u ** 3
              + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * u ** 2
              + (-p0[k] + p2[k]) * u
              + 2 * p1[k])
        for k in range(3)
    )


def _reflect(reference: Sequence[float], following: Sequence[float]) -> Vec:
    """``array[0] = array[1] + (array[1] − array[2])`` and the mirrored
    end of the control array in ``PathControlPointGenerator``."""
    return tuple(reference[k] + (reference[k] - following[k]) for k in range(3))


def path_control_point_generator(path: Sequence[Sequence[float]]) -> list[Vec]:
    """Port of ``PathControlPointGenerator``: pad one reflected control
    point on each end; a closed path (first point == last point) wraps to
    the opposite side instead of reflecting."""
    padded: list[Vec] = [_reflect(path[0], path[1]), *path, _reflect(path[-1], path[-2])]
    if padded[1] == padded[-2]:
        wrapped = list(padded)
        wrapped[0] = padded[-3]
        wrapped[-1] = padded[2]
        return wrapped
    return padded


def path_length(path: Sequence[Sequence[float]]) -> float:
    """Port of ``PathLength``: sum 20·|path| samples over the padded
    control array (``path.Length * 20`` samples, ``i = 1…n``)."""
    pts = path_control_point_generator(path)
    cursor = interp(pts, 0)
    total = 0.0
    samples = len(path) * 20
    for i in range(1, samples + 1):
        next_position = interp(pts, i / samples)
        total += math.dist(cursor, next_position)
        cursor = next_position
    return total


# ---------------------------------------------------------------------------
# Route model and segment building (OCIRoute.cs Play/SetPath).

@dataclass(frozen=True)
class RoutePoint:
    """One authored route point: position, optional aid control point for a
    Curve connection, whether the *next* point is linked, plus the speed and
    ease that drive the segment starting here."""

    position: Vec
    aid: Optional[Vec]
    connection: str  # "line" | "curve"
    link: bool
    speed: float
    ease_type: str = DEFAULT_EASE


@dataclass(frozen=True)
class Route:
    points: tuple[RoutePoint, ...]
    loop: bool = True
    orient: str = "none"  # "none" | "xy" | "y"


@dataclass(frozen=True)
class RouteSegment:
    """One ``MoveTo`` segment: the control path (route positions with the
    segment's aid points interleaved), its speed/ease and start point."""

    start_index: int
    path: tuple[Vec, ...]
    speed: float
    ease_type: str

    @property
    def control_points(self) -> list[Vec]:
        return path_control_point_generator(self.path)

    @property
    def duration(self) -> float:
        return path_length(self.control_points) / self.speed


@dataclass(frozen=True)
class Orientation:
    """Orient-to-path result: the sampled lookahead target plus the
    instantaneous aim rotation facing it (``None`` if degenerate). The
    original ``LookUpdate`` then SmoothDampAngle-rotates toward it each
    frame and, for axis "y", re-keeps the root's own x/z Euler; that
    stateful LateUpdate pass is not simulated here."""

    axis: str
    look_target: Vec
    rotation: Optional[tuple[float, float, float, float]]  # quaternion w, x, y, z


@dataclass(frozen=True)
class Evaluation:
    position: Vec
    segment_index: int
    finished: bool
    orientation: Optional[Orientation]


def is_link(point: RoutePoint) -> bool:
    """``OCIRoutePoint.isLink``: link only chains Curve points."""
    return point.link and point.connection == "curve"


def _validate_point(index: int, point: RoutePoint) -> None:
    if point.connection not in ("line", "curve"):
        raise RouteNotPlayable(f"point {index}: unknown connection {point.connection!r}")
    if point.ease_type not in EASING:
        raise RouteNotPlayable(f"point {index}: unknown ease type {point.ease_type!r}")
    if not math.isfinite(point.speed) or point.speed <= 0:
        raise RouteNotPlayable(f"point {index}: speed {point.speed} must be finite and positive")
    if not all(math.isfinite(component) for component in point.position):
        raise RouteNotPlayable(f"point {index}: position {point.position} is not finite")
    if point.connection == "curve":
        if point.aid is None:
            raise RouteNotPlayable(f"point {index}: curve connection has no initialised aid target")
        if not all(math.isfinite(component) for component in point.aid):
            raise RouteNotPlayable(f"point {index}: aid target {point.aid} is not finite")


def build_segment(points: Sequence[RoutePoint], index: int, loop: bool) -> Optional[RouteSegment]:
    """Port of ``SetPath``/``Move``: one segment starting at ``index``. The
    path is [point, next point] for Line, or [point, aid] plus the pairs of
    every following *linked* curve point, plus the next point (wrapping to
    point 0 when looping). A non-looping route skips the last point's
    segment, so this returns ``None`` there."""

    count = len(points)
    if not loop and index == count - 1:
        return None
    first = points[index]
    if first.connection == "line":
        if index != count - 1:
            path = (points[index].position, points[index + 1].position)
        else:
            path = (points[count - 1].position, points[0].position)
    else:
        path = [points[index].position, points[index].aid]
        following = index + 1
        while following < count and (loop or following != count - 1) and is_link(points[following]):
            path.extend((points[following].position, points[following].aid))
            following += 1
        path.append(points[0].position if following >= count else points[following].position)
        path = tuple(path)
    return RouteSegment(start_index=index, path=tuple(path), speed=first.speed, ease_type=first.ease_type)


def build_segments(route: Route) -> list[RouteSegment]:
    """Port of ``Play``: walk route points from 0 and append one segment per
    Start position; stop once a non-looping route reaches the last point."""

    if len(route.points) < 2:
        raise RouteNotPlayable(f"route has {len(route.points)} points; at least 2 are needed")
    for index, point in enumerate(route.points):
        _validate_point(index, point)
    if route.orient not in ("none", "xy", "y"):
        raise RouteNotPlayable(f"route orientation {route.orient!r} is not a known enum value")

    segments: list[RouteSegment] = []
    index = 0
    while index < len(route.points):
        segment = build_segment(route.points, index, route.loop)
        if segment is None:
            break  # non-looping route reached the last point: that segment is skipped
        if segment.duration <= 0 or not math.isfinite(segment.duration):
            raise RouteNotPlayable(
                f"segment starting at point {segment.start_index} has no playable "
                f"duration (path length {path_length(segment.path)}, speed {segment.speed})"
            )
        segments.append(segment)
        # ``SetPath`` advances to the segment's closing point, so segments
        # overlap by one point: the next one starts at that closing point.
        index = segment.start_index + len(segment.path) // 2
    return segments


def look_rotation(position: Sequence[float], target: Sequence[float],
                  axis: str) -> Optional[tuple[float, float, float, float]]:
    """Instantaneous aim at ``target`` from ``position``: the rotation
    ``transform.LookAt`` computes before the original applies it — ``"y"``
    faces only the horizontal component (the source's axis-"y" post-pass
    keeps the root's own x/z Euler around it), ``"xy"`` rotates in all
    dimensions. Returns ``None`` when the aim direction is degenerate.
    The *visible* original rotation additionally runs a stateful
    ``SmoothDampAngle`` frame pass (``LookUpdate``) this evaluator does not
    simulate. Quaternion is returned as ``(w, x, y, z)``."""
    direction = tuple(target[k] - position[k] for k in range(3))
    if axis == "y":
        direction = (direction[0], 0.0, direction[2])
    if max(abs(component) for component in direction) < 1e-9:
        return None
    return _look_at(direction)


def _look_at(direction: Vec) -> tuple[float, float, float, float]:
    """Same construction as ``simd_quatf.lookRotation`` in CoreMath and as
    Unity's ``Quaternion.LookRotation``: basis columns are right, up,
    forward, so the object faces ``direction`` with world up as reference."""
    forward = _unit(direction)
    up = (0.0, 1.0, 0.0)
    if abs(sum(a * b for a, b in zip(forward, up))) > 0.999:
        up = (1.0, 0.0, 0.0)
    right = _unit(_cross(up, forward))
    up = _cross(forward, right)
    return _quaternion_from_basis(right, up, forward)


def _unit(value: Vec) -> Vec:
    length = math.sqrt(sum(component * component for component in value))
    return tuple(component / length for component in value)  # type: ignore[return-value]


def _cross(a: Sequence[float], b: Sequence[float]) -> Vec:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _quaternion_from_basis(right: Vec, up: Vec, forward: Vec) -> Vec:
    """Sheppards' method (same as the C# ``Quaternion`` matrix constructor):
    build the rotation matrix from the basis and convert it to a
    quaternion. Returns ``(w, x, y, z)``."""
    matrix = (
        (right[0], up[0], forward[0]),
        (right[1], up[1], forward[1]),
        (right[2], up[2], forward[2]),
    )
    trace = matrix[0][0] + matrix[1][1] + matrix[2][2]
    if trace > 0:
        s = math.sqrt(trace + 1) / 2
        w = s
        x = (matrix[2][1] - matrix[1][2]) / (4 * s)
        y = (matrix[0][2] - matrix[2][0]) / (4 * s)
        z = (matrix[1][0] - matrix[0][1]) / (4 * s)
    elif matrix[0][0] >= matrix[1][1] and matrix[0][0] >= matrix[2][2]:
        s = math.sqrt(1 + matrix[0][0] - matrix[1][1] - matrix[2][2]) / 2
        w = (matrix[2][1] - matrix[1][2]) / (4 * s)
        x = s
        y = (matrix[0][1] + matrix[1][0]) / (4 * s)
        z = (matrix[0][2] + matrix[2][0]) / (4 * s)
    elif matrix[1][1] >= matrix[2][2]:
        s = math.sqrt(1 + matrix[1][1] - matrix[0][0] - matrix[2][2]) / 2
        w = (matrix[0][2] - matrix[2][0]) / (4 * s)
        x = (matrix[0][1] + matrix[1][0]) / (4 * s)
        y = s
        z = (matrix[1][2] + matrix[2][1]) / (4 * s)
    else:
        s = math.sqrt(1 + matrix[2][2] - matrix[0][0] - matrix[1][1]) / 2
        w = (matrix[1][0] + matrix[0][1]) / (4 * s)
        x = (matrix[2][0] + matrix[0][2]) / (4 * s)
        y = (matrix[2][1] + matrix[1][2]) / (4 * s)
        z = s
    magnitude = math.sqrt(w * w + x * x + y * y + z * z)
    return (w / magnitude, x / magnitude, y / magnitude, z / magnitude)


def evaluate(route: Route, elapsed_seconds: float) -> Evaluation:
    """Sample the route at ``elapsed_seconds``: which segment, the eased
    position on it, whether it finished, and the orient-to-path rotation."""

    if not math.isfinite(elapsed_seconds) or elapsed_seconds < 0:
        raise RouteNotPlayable(f"elapsed time {elapsed_seconds} must be finite and non-negative")
    segments = build_segments(route)
    if not segments:
        raise RouteNotPlayable("route cannot play: no segments were built")

    total = sum(segment.duration for segment in segments)
    if not math.isfinite(total) or total <= 0:
        raise RouteNotPlayable(f"route duration {total} is not playable")
    looping = route.loop
    if looping:
        elapsed_seconds %= total
    finished = not looping and elapsed_seconds >= total

    index = 0
    start = 0.0
    segment = segments[index]
    while index + 1 < len(segments) and elapsed_seconds >= start + segment.duration:
        start += segment.duration
        index += 1
        segment = segments[index]
    percentage = min(max((elapsed_seconds - start) / segment.duration, 0.0), 1.0)
    eased = EASING[segment.ease_type](0, 1, percentage)
    position = interp(segment.control_points, min(max(eased, 0.0), 1.0))

    orientation = None
    if route.orient != "none":
        ahead_percentage = min(1.0, percentage + LOOK_AHEAD)
        ahead_eased = EASING[segment.ease_type](0, 1, ahead_percentage)
        look_target = interp(segment.control_points, min(max(ahead_eased, 0.0), 1.0))
        orientation = Orientation(axis=route.orient, look_target=look_target,
                                 rotation=look_rotation(position, look_target, route.orient))
    return Evaluation(position=position, segment_index=index, finished=finished, orientation=orientation)


# ---------------------------------------------------------------------------
# Per-frame stepping (OCIRoute Play + StudioTween UpdateAsObservable).
#
# ``Play`` puts ``childRoot`` at point 0 and starts segment 0 (one
# ``TweenStart`` ``apply()`` at percentage 0), queuing every later segment.
# Then every frame while the tween runs, in Update:
#
# - ``percentage < 1``: ``TweenUpdate`` FIRST applies the position/aim at the
#   CURRENT percentage, THEN advances ``runningTime += Time.deltaTime`` and
#   recomputes ``percentage = runningTime / time`` — the written position
#   lags the time by one frame;
# - otherwise: ``TweenComplete`` applies percentage 1; a queued next segment
#   (or, when looping, segment 0 again) restarts with ``percentage = 0`` and
#   ``runningTime = 0`` — that frame's overshoot is dropped — and is applied
#   at percentage 0 in the SAME frame; a non-looping route with nothing left
#   stops: ``onComplete`` sets the route inactive and ``childRoot`` keeps the
#   end position and its last aim rotation.

@dataclass(frozen=True)
class SteppedFrame:
    """State ``childRoot`` holds after one stepped frame: applied position,
    last aim (``None`` for a route without orientation) and the active flag
    ``onComplete`` flips off at the non-loop finish frame."""

    position: Vec
    aim: Optional[Orientation]
    active: bool


def simulate_frames(points: Sequence[RoutePoint], loop: bool, orientation: str,
                    frame_deltas: Sequence[float], record_after_update: bool = True) -> list[SteppedFrame]:
    """Run the recovered per-frame tween rules over ``frame_deltas`` seconds.

    Each entry is one ``Time.deltaTime``. ``record_after_update=True`` models
    the capture observing the tween write of the SAME frame (the trace frame
    holds what that frame's Update applied); ``False`` models the capture
    running first, so each trace frame still holds the PREVIOUS frame's write
    and the first frame holds ``Play``'s own percentage-0 application. The
    probe ordering is unknown, so callers try both.
    """
    route = Route(points=tuple(points), loop=loop, orient=orientation)
    segments = build_segments(route)
    if not segments:
        raise RouteNotPlayable("route cannot play: no segments were built")
    for index, delta in enumerate(frame_deltas):
        if not math.isfinite(delta) or delta < 0:
            raise RouteNotPlayable(f"deltaTime {delta} at frame {index} is not finite and non-negative")

    def apply(segment_index: int, percentage: float) -> tuple[Vec, Optional[Orientation]]:
        segment = segments[segment_index]
        ease = EASING[segment.ease_type]
        position = interp(segment.control_points, min(max(ease(0, 1, percentage), 0.0), 1.0))
        aim = None
        if orientation != "none":
            ahead = min(1.0, percentage + LOOK_AHEAD)
            look_target = interp(segment.control_points, min(max(ease(0, 1, ahead), 0.0), 1.0))
            rotation = look_rotation(position, look_target, orientation)
            if rotation is not None:
                # A degenerate aim direction leaves the previous rotation in
                # place in the original, so only a valid aim replaces it.
                aim = Orientation(axis=orientation, look_target=look_target, rotation=rotation)
        return position, aim

    # ``Play``: childRoot at point 0, segment 0 started, percentage 0. The
    # ``TweenStart`` application at percentage 0 is write 0; a degenerate
    # instantaneous aim keeps the previous rotation (never point 0's rotation
    # once the aim has been established).
    segment_index, running_time, percentage, finished = 0, 0.0, 0.0, False
    position, aim = segments[0].path[0], None

    def apply_and_hold(index: int, percentage: float) -> None:
        nonlocal position, aim
        new_position, new_aim = apply(index, percentage)
        position = new_position
        if new_aim is not None:
            aim = new_aim

    apply_and_hold(0, 0.0)
    writes: list[tuple[Vec, Optional[Orientation], bool]] = [(position, aim, True)]
    for delta in frame_deltas:
        if finished:
            pass  # tween stopped; childRoot keeps the end placement
        elif percentage < 1.0:
            apply_and_hold(segment_index, percentage)  # apply BEFORE advancing time
            running_time += delta
            percentage = running_time / segments[segment_index].duration
        else:
            apply_and_hold(segment_index, 1.0)  # TweenComplete end point
            if segment_index + 1 < len(segments):
                segment_index += 1  # Next: overshoot dropped, applied in the same frame
                apply_and_hold(segment_index, 0.0)
                running_time, percentage = 0.0, 0.0
            elif loop:
                segment_index = 0  # looping queue restarts the same way
                apply_and_hold(0, 0.0)
                running_time, percentage = 0.0, 0.0
            else:
                finished = True  # onComplete: route inactive, end placement kept
        writes.append((position, aim, not finished))
    # ``writes[0]`` is Play's own application; writes[k+1] is what frame k's
    # Update left on childRoot. Selecting from the front models a capture
    # that records before the tween's Update ran that frame.
    chosen = writes[1:] if record_after_update else writes[:-1]
    return [SteppedFrame(position=written_position, aim=written_aim, active=written_active)
            for written_position, written_aim, written_active in chosen]

# Stepping fixture: irregular deltas chosen to cross every per-frame rule on
# the routes below. ``stepping_routes()``'s no-loop route (segment durations
# 3.0 s + 7.430112 s) sees a segment-boundary drop, a clamped overshoot frame,
# completion and hold frames; the loop route (1.5 + 1.5 + 2.121320 s) sees a
# boundary drop and the same-frame loop restart.
def _stepping_scenarios() -> dict[str, tuple[Route, tuple[float, ...]]]:
    """Routes for the per-frame stepping fixture with their irregular frame
    deltas: a straight looping route in orientation y (segment durations
    1.5 + 1.5 + 2.121320 s — the deltas cross a boundary drop and the
    same-frame loop restart) and a line-curve-linked-curve-line route with no
    loop in orientation xy (3.0 + 7.430112 s — a boundary drop, a clamped
    overshoot frame, completion and hold frames)."""
    return {
        "stepping-line-loop": (Route(
            points=(_line_point((0, 0, 0), speed=4), _line_point((2, 0, 0), speed=4),
                    _line_point((2, 2, 0), speed=4)),
            loop=True, orient="y"),
            (0.25, 0.5, 0.3, 1.0, 0.1666, 0.05, 0.7, 1.5, 0.3333, 0.2, 1.2, 1.5, 0.4, 0.05)),
        "stepping-curves-no-loop": (Route(
            points=(_line_point((0, 0, 0)),
                    _curve_point((2, 0, 0), (3, 1, 0), speed=1.5, ease="easeInQuad"),
                    _curve_point((4, 0, 0), (5, 2, 0), link=True),
                    _line_point((6, 0, 0))),
            loop=False, orient="xy"),
            (0.1, 0.05, 0.0166, 0.0333, 0.25, 0.1666, 0.3333, 0.5, 0.1666, 0.7, 0.8,
             0.9, 1.5, 1.1, 2.0, 1.3, 2.6, 0.1666, 0.05, 0.25, 0.3333, 0.1, 0.5)),
    }


def _stepping_sample(route: Route, deltas: tuple[float, ...]) -> dict[str, object]:
    """One stepping fixture entry: the route definition, its frame deltas and
    ``simulate_frames``' write-after-update frames."""
    frames = simulate_frames(route.points, route.loop, route.orient, deltas)
    return {
        "points": [{"position": list(point.position),
                    "aid": list(point.aid) if point.aid else None,
                    "connection": point.connection, "link": point.link,
                    "speed": point.speed, "easeType": point.ease_type}
                   for point in route.points],
        "loop": route.loop,
        "orient": route.orient,
        "deltas": list(deltas),
        "frames": [{"position": list(frame.position),
                    "active": frame.active,
                    "aim": None if frame.aim is None else {
                        "axis": frame.aim.axis,
                        "lookTarget": list(frame.aim.look_target),
                        "rotation": list(frame.aim.rotation) if frame.aim.rotation is not None else None}}
                   for frame in frames],
    }


def stepping_fixture() -> dict[str, object]:
    return {
        "note": ("Synthetic authored routes with irregular frame deltas; expected "
                 "per-frame writes come from simulate_frames in this file (float64, "
                 "record-after-update order), not from an original CharaStudio run."),
        "tolerance": 1e-5,
        "routes": {name: _stepping_sample(route, deltas)
                   for name, (route, deltas) in _stepping_scenarios().items()},
    }


def _line_point(position: Vec, speed: float = DEFAULT_SPEED, ease: str = DEFAULT_EASE) -> RoutePoint:
    return RoutePoint(position=position, aid=None, connection="line", link=False, speed=speed, ease_type=ease)


def _curve_point(position: Vec, aid: Vec, link: bool = False,
                 speed: float = DEFAULT_SPEED, ease: str = DEFAULT_EASE) -> RoutePoint:
    return RoutePoint(position=position, aid=aid, connection="curve", link=link, speed=speed, ease_type=ease)


def synthetic_routes() -> dict[str, Route]:
    """Small authored routes covering the recovered branches: Line only,
    Curve with aid, linked curves, loop versus no-loop, each orientation and
    all 32 ease types."""

    routes: dict[str, Route] = {
        # One-second segments: sample times cross the first segment boundary.
        "line-loop": Route(points=(_line_point((0, 0, 0)), _line_point((2, 0, 0)), _line_point((2, 2, 0)))),
        "line-no-loop": Route(points=(_line_point((0, 0, 0)), _line_point((2, 0, 0)), _line_point((2, 2, 0))),
                              loop=False),
        # Half-second segments: every segment plus the loop wrap is sampled.
        "line-fast-loop": Route(points=(_line_point((0, 0, 0), speed=4), _line_point((2, 0, 0), speed=4),
                                         _line_point((2, 2, 0), speed=4))),
        "line-fast-no-loop": Route(points=(_line_point((0, 0, 0), speed=4), _line_point((2, 0, 0), speed=4),
                                            _line_point((2, 2, 0), speed=4)),
                                   loop=False),
        # Segments interleave [point, aid] control points; linking extends
        # the first curve segment across all three points.
        "curve-aid": Route(points=(_curve_point((0, 0, 0), (1, 0, 0)),
                                   _curve_point((2, 0, 0), (3, 1, 0)),
                                   _curve_point((4, 0, 0), (5, 2, 0))),
                           loop=False),
        "linked-curves": Route(points=(_curve_point((0, 0, 0), (1, 0, 0), link=True),
                                       _curve_point((2, 0, 0), (3, 1, 0), link=True),
                                       _curve_point((4, 0, 0), (5, 2, 0), speed=4)),
                               loop=False),
        "curve-loop": Route(points=(_curve_point((0, 0, 0), (1, 0, 0), link=True),
                                    _curve_point((2, 0, 0), (3, 1, 0), link=True),
                                    _curve_point((4, 0, 0), (5, 2, 0), speed=4))),
        "orient-y": Route(points=(_line_point((0, 0, 0)), _line_point((2, 1, 2))), orient="y"),
        "orient-xy": Route(points=(_line_point((0, 0, 0)), _line_point((2, 1, 2))), orient="xy"),
    }
    for ease in EASE_TYPES:
        routes[f"ease-{ease}"] = Route(points=(_line_point((0, 0, 0), ease=ease),
                                                 _line_point((2, 0, 0), ease=ease)))
    return routes


_BASE_TIMES: tuple[float, ...] = (0, 0.1, 0.25, 0.5, 0.75, 0.9, 1)
# Structural routes only need sample times that cross the real segment
# boundaries; the recovered PathLength triple-counts straight segments.
_EXTRA_TIMES: dict[str, tuple[float, ...]] = {
    "line-loop": (8.0,),            # loop wrap into the closing segment
    "line-no-loop": (6.5,),         # past the end: clamped, finished
    "line-fast-loop": (6.0,),       # wraps into segment 0
    "line-fast-no-loop": (2.0,),    # clamped at the endpoint, finished
    "curve-aid": (2.5,),            # crosses into the second segment
    "linked-curves": (4.5,),        # single-segment route, finished
    "curve-loop": (4.0,),           # second segment of a looping curve
}


def sample_times(name: str) -> tuple[float, ...]:
    return _BASE_TIMES + _EXTRA_TIMES.get(name, ())


def _sample(route: Route, elapsed: float) -> dict[str, object]:
    evaluation = evaluate(route, elapsed)
    orientation = None
    if evaluation.orientation is not None:
        rotation = evaluation.orientation.rotation
        orientation = {"axis": evaluation.orientation.axis,
                       "lookTarget": list(evaluation.orientation.look_target),
                       "rotation": list(rotation) if rotation is not None else None}
    return {"position": list(evaluation.position),
            "segmentIndex": evaluation.segment_index,
            "finished": evaluation.finished,
            "orientation": orientation}


def main(argv: Optional[Sequence[str]] = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=None,
                        help="where to write the sampled fixture (defaults: "
                             ".local/reverse/studio-routes/route-reference.json for "
                             "samples, Packages/Engine/Tests/EngineTests/Fixtures/"
                             "route-stepping.json for stepping)")
    parser.add_argument("--fixture", choices=("samples", "stepping"), default="samples",
                        help="write the continuous-evaluator fixture, or the "
                             "per-frame stepping fixture")
    arguments = parser.parse_args(argv)
    if arguments.out is None:
        arguments.out = (REPO / "Packages/Engine/Tests/EngineTests/Fixtures/route-stepping.json"
                         if arguments.fixture == "stepping"
                         else REPO / ".local/reverse/studio-routes/route-reference.json")

    if arguments.fixture == "stepping":
        stepping = stepping_fixture()
        arguments.out.parent.mkdir(parents=True, exist_ok=True)
        arguments.out.write_text(json.dumps(stepping, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"wrote {arguments.out}")
        return

    fixture: dict[str, object] = {
        "note": ("Synthetic authored routes; expected values come from the "
                 "recovered C# ported in this reference file (float64), not "
                 "from an original CharaStudio run."),
        "tolerance": 1e-5,
        "routes": {
            name: {
                "points": [{"position": list(point.position),
                            "aid": list(point.aid) if point.aid else None,
                            "connection": point.connection, "link": point.link,
                            "speed": point.speed, "easeType": point.ease_type}
                           for point in route.points],
                "loop": route.loop,
                "orient": route.orient,
                "samples": {str(t): _sample(route, t) for t in sample_times(name)},
            }
            for name, route in synthetic_routes().items()
        },
    }
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    arguments.out.write_text(json.dumps(fixture, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {arguments.out}")


if __name__ == "__main__":
    main()
