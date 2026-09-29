"""Derive the CameraLightCtrl character-light direction mapping from the original capture.

``CameraLightCtrl.LightCalc.Reflect`` (recovered shape) sets
``transRoot.localRotation = Quaternion.Euler(rot[0], rot[1], 0)``. This module
reads the captured transform chains from ``light-trace.json`` (written by
``Tools/reverse/fixtures/OriginalLightProbe.cs`` through
``Tools/reverse/original_light_probe.py``), identifies ``transRoot`` as the one
chain node whose local rotation varies with ``rot``, fixes the remaining
rotations and verifies the resulting formula on every record.

The capture shows the light rig "Light Chara" hangs under the static
"StudioScene" root — it is *not* a child of ``Camera.main`` — so the candidate
camera-relative formula ``light.rotation == Camera.main.rotation * Q1 *
Euler(rot) * Q2`` is scored as well: ``Q_base`` (the fixed camera-to-light
rotation measured at rot (0,0)) and its spread across camera poses decide
whether a camera-fixed mapping exists at all.

Quaternions here are ``(w, x, y, z)``; the capture serializes Unity's
``(x, y, z, w)`` and this module converts at the boundary.
"""
from __future__ import annotations
import argparse, json, math
from pathlib import Path
from typing import Sequence

REPO=Path(__file__).resolve().parents[3]
TRACE=REPO/'.local/stt11k/probe/light-trace.json'
ANGLE_TOLERANCE_DEG=0.01
IDENTITY=(1.0, 0.0, 0.0, 0.0)


def quat_xyzw(q: Sequence[float]) -> tuple[float, float, float, float]:
    """Capture ``(x, y, z, w)`` to internal ``(w, x, y, z)``."""
    x, y, z, w = q
    return (w, x, y, z)


def quat_mul(left: Sequence[float], right: Sequence[float]) -> tuple[float, float, float, float]:
    """Hamilton product of two ``(w, x, y, z)`` rotations."""
    lw, lx, ly, lz = left
    rw, rx, ry, rz = right
    return (
        lw * rw - lx * rx - ly * ry - lz * rz,
        lw * rx + lx * rw + ly * rz - lz * ry,
        lw * ry - lx * rz + ly * rw + lz * rx,
        lw * rz + lx * ry - ly * rx + lz * rw,
    )


def quat_conj(q: Sequence[float]) -> tuple[float, float, float, float]:
    w, x, y, z = q
    return (w, -x, -y, -z)


def quat_from_euler(euler: Sequence[float]) -> tuple[float, float, float, float]:
    """``Quaternion.Euler`` for ``(x, y, z)`` degrees: the Z-X-Y composition
    ``Ry * Rx * Rz`` Unity applies (same convention as
    ``studio_route_reference.from_euler``, reimplemented so the mapping module
    stands alone for its own unit tests)."""
    cx, sx = math.cos(math.radians(euler[0]) / 2), math.sin(math.radians(euler[0]) / 2)
    cy, sy = math.cos(math.radians(euler[1]) / 2), math.sin(math.radians(euler[1]) / 2)
    cz, sz = math.cos(math.radians(euler[2]) / 2), math.sin(math.radians(euler[2]) / 2)
    return quat_mul(quat_mul((cy, 0.0, sy, 0.0), (cx, sx, 0.0, 0.0)), (cz, 0.0, 0.0, sz))


def quat_angle_deg(left: Sequence[float], right: Sequence[float]) -> float:
    """Rotation angle in degrees between two unit rotations (sign-insensitive):
    ``2*atan2`` of the vector/scalar parts of ``conj(left) * right``. The
    dot-product ``acos`` form would amplify input rounding by its square root
    near angle 0 (1e-16 in the dot becomes ~6e-7 degrees); atan2 stays at the
    inputs' own epsilon."""
    w, x, y, z = quat_mul(quat_conj(left), right)
    return math.degrees(2.0 * math.atan2(math.sqrt(x * x + y * y + z * z), abs(w)))


def quat_rotate(q: Sequence[float], v: Sequence[float]) -> tuple[float, float, float]:
    """Rotate ``(x, y, z)`` by a unit ``(w, x, y, z)`` rotation."""
    w, x, y, z = q
    vx, vy, vz = v
    t = (
        2.0 * (y * vz - z * vy),
        2.0 * (z * vx - x * vz),
        2.0 * (x * vy - y * vx),
    )
    return (
        vx + w * t[0] + (y * t[2] - z * t[1]),
        vy + w * t[1] + (z * t[0] - x * t[2]),
        vz + w * t[2] + (x * t[1] - y * t[0]),
    )


def forward_of(q: Sequence[float]) -> tuple[float, float, float]:
    """Unity's ``Transform.forward``: the rotated ``+Z`` axis."""
    return quat_rotate(q, (0.0, 0.0, 1.0))


def _normalize(q: Sequence[float]) -> tuple[float, float, float, float]:
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


def _chain_product(locals_: Sequence[Sequence[float]]) -> tuple[float, float, float, float]:
    """World-space factor of chain nodes listed lightwards-first: the product
    in ancestor-to-descendant order, i.e. ``reversed(locals_)`` multiplied
    left to right."""
    out = IDENTITY
    for q in reversed(list(locals_)):
        out = quat_mul(out, q)
    return _normalize(out)


def analyze(trace: dict) -> dict:
    """Identify ``transRoot``, verify the chain formula on every record and
    score the candidate camera-relative mapping from the camera-space spread."""
    records = []
    for raw in trace['records']:
        light = _select_lit(raw)
        camera = quat_xyzw(raw['camera']['rotation'])
        world = quat_xyzw(light['worldRotation'])
        chain = [quat_xyzw(node['localRotation']) for node in light['chain']]
        # chain[0] is the light transform and chain[-1] the rig root (the
        # capture's chain walk stops at Camera.main only when the camera is
        # an ancestor; here it stops at the scene root).
        records.append(dict(
            cameraPose=raw['cameraPose'], rot=(float(raw['rot'][0]), float(raw['rot'][1])),
            camera=camera, light=world, chain=chain,
            names=[node['name'] for node in light['chain']],
            cameraSpace=_normalize(quat_mul(quat_conj(camera), world)),
        ))
    if not any(r['rot'] == (0.0, 0.0) for r in records):
        raise ValueError('trace has no rot (0,0) record to anchor Q_base')
    shapes = {(len(r['chain']), tuple(r['names'])) for r in records}
    if len(shapes) != 1:
        raise ValueError('light chain differs across records: %r' % (shapes,))
    base = [r for r in records if r['rot'] == (0.0, 0.0)]
    q_base = base[0]['cameraSpace']
    base_spread = max(quat_angle_deg(q_base, r['cameraSpace']) for r in base)
    root_index = _transroot_index(records)
    if root_index is None:
        raise ValueError('no chain node varies with rot: transRoot not identified')
    transroot_error = max(
        quat_angle_deg(r['chain'][root_index], quat_from_euler((r['rot'][0], r['rot'][1], 0.0)))
        for r in records)
    light_side = [r['chain'][:root_index] for r in records]  # transRoot's descendants, listed lightwards
    root_side = [r['chain'][root_index + 1:] for r in records]  # its ancestors, listed lightwards
    light_variation = _variation(light_side)
    root_variation = _variation(root_side)
    q_light = _chain_product(light_side[0])  # right factor: locals between transRoot and the light
    q_root = _chain_product(root_side[0])  # left factor: everything above transRoot up to the chain root
    checks = []
    for r in records:
        # The chain formula uses THIS record's root-side product: the product
        # above transRoot includes the chain root, which is the camera's own
        # local whenever the rig hangs under Camera.main.
        root_r = _chain_product(r['chain'][root_index + 1:])
        predicted = quat_mul(quat_mul(root_r, quat_from_euler((r['rot'][0], r['rot'][1], 0.0))), q_light)
        r['predicted'] = _normalize(predicted)
        r['errorDeg'] = quat_angle_deg(r['predicted'], r['light'])
        r['cameraSpaceForward'] = quat_rotate(quat_conj(r['camera']), forward_of(r['light']))
        checks.append(dict(
            cameraPose=r['cameraPose'], rot=list(r['rot']),
            lightCameraSpace=list(r['cameraSpace']),
            lightCameraSpaceEuler=_euler_report(r['cameraSpace']),
            chainErrorDeg=r['errorDeg'],
            cameraSpaceForward=list(r['cameraSpaceForward']),
        ))
    residual, camera_relative, q1, q2 = _camera_fit(records, q_base, base_spread)
    return dict(
        formula='light.rotation == Q_root * Quaternion.Euler(rot[0], rot[1], 0) * Q_light'
                ' (Q_root is the fixed product of the chain above transRoot up to the chain root,'
                ' Q_light the fixed product of the locals between transRoot and the light transform;'
                ' both chains are static in the capture, so Q_root includes Camera.main only when'
                ' the rig hangs under the rendering camera)',
        transRootChainIndex=root_index,
        transRootName=records[0]['names'][root_index],
        chainNames=records[0]['names'],
        qRoot=list(q_root), qLight=list(q_light),
        qRootMaxVariationDeg=root_variation, qLightMaxVariationDeg=light_variation,
        transRootLocalRotationMaxErrorDeg=transroot_error,
        qBase=list(q_base), qBaseCameraPoseSpreadDeg=base_spread,
        cameraFitResidualDeg=residual,
        maxErrorDeg=max(r['errorDeg'] for r in records),
        cameraRelativeValid=camera_relative,
        records=checks,
    )


def _select_lit(raw: dict) -> dict:
    """The capture records exactly one light; if several ever appear, the chara
    light is the enabled one Reflect just set to intensity 1.3."""
    if len(raw['lights']) == 1:
        return raw['lights'][0]
    candidates = [l for l in raw['lights'] if l['enabled'] and abs(l['intensity'] - 1.3) < 1e-3]
    if len(candidates) != 1:
        raise ValueError('cannot identify the character light among %d lights' % len(raw['lights']))
    return candidates[0]


def _transroot_index(records: Sequence[dict]) -> int | None:
    """First chain node (lightwards-first, rig root excluded) whose local
    rotation differs between records: ``transRoot``, whose local must equal
    ``Euler(rot[0], rot[1], 0)`` (verified separately)."""
    for index in range(len(records[0]['chain']) - 1):
        if any(quat_angle_deg(r['chain'][index], records[0]['chain'][index]) > ANGLE_TOLERANCE_DEG
               for r in records):
            return index
    return None


def _variation(locals_: Sequence[Sequence[Sequence[float]]]) -> float:
    """Maximum angle a list of per-record chain-node locals deviates from the
    first record's value (0.0 for an empty level)."""
    if not locals_ or not locals_[0]:
        return 0.0
    reference = _chain_product(locals_[0])
    return max(quat_angle_deg(reference, _chain_product(entry)) for entry in locals_)


def _dot(u, v):
    return sum(a * b for a, b in zip(u, v))


def _cross(u, v):
    return (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])


def _unit(v):
    n = math.sqrt(_dot(v, v))
    return tuple(c / n for c in v)


def angle_axis(q: Sequence[float]):
    """``(angle_degrees, axis_or_None)`` of a ``(w, x, y, z)`` rotation, with
    the quaternion sign fixed to ``w >= 0``; ``None`` for the identity."""
    w, x, y, z = _normalize(q)
    if w < 0:
        w, x, y, z = -w, -x, -y, -z
    s = math.sqrt(x * x + y * y + z * z)
    if s < 1e-9:
        return 0.0, None
    return math.degrees(2.0 * math.atan2(s, w)), (x / s, y / s, z / s)


def rot_about(axis: Sequence[float], angle_deg: float):
    s = math.sin(math.radians(angle_deg) / 2)
    return (math.cos(math.radians(angle_deg) / 2), axis[0] * s, axis[1] * s, axis[2] * s)


def shortest_arc(u: Sequence[float], v: Sequence[float]):
    """Rotation carrying unit ``(x, y, z)`` ``u`` onto ``v`` along the shortest
    arc (any perpendicular axis for antiparallel inputs)."""
    d = _dot(u, v)
    if d < -0.999999:
        axis = _unit(_cross((1.0, 0.0, 0.0), u)) if abs(u[0]) < 0.9 else _unit(_cross((0.0, 1.0, 0.0), u))
        return rot_about(axis, 180.0)
    return _normalize(_normalize((1.0 + d,) + _cross(u, v)))


def _camera_fit(records: Sequence[dict], q_base, base_spread: float):
    """Solve whether constants ``Q1``/``Q2`` give
    ``light.rotation == Camera.main.rotation * Q1 * Euler(rot) * Q2``.

    At rot (0,0) the split is forced: ``Q1 * Q2 == conj(camera) * light ==
    Q_base``. Substituting ``Q2 = conj(Q1) * Q_base`` and setting
    ``T = conj(camera) * light * conj(Q_base)`` makes the question: is there a
    ``Q1`` conjugating ``Euler(rot)`` onto ``T`` for every record? Conjugation
    preserves the rotation angle, so a mismatch over the ``angle(T)`` vs
    ``angle(Euler(rot))`` pairs rules the whole family out. Otherwise ``Q1``
    is pinned by carrying ``Euler(rot)``'s axes onto ``T``'s (two records with
    non-parallel axes fix it, otherwise a twist grid is scanned), and the
    winning candidate is the one whose formula error is smallest."""
    conjugation = 0.0
    pairs = []
    for r in records:
        euler = quat_from_euler((r['rot'][0], r['rot'][1], 0.0))
        t = quat_mul(quat_mul(quat_conj(r['camera']), r['light']), quat_conj(q_base))
        a_angle, a_axis = angle_axis(euler)
        t_angle, t_axis = angle_axis(t)
        conjugation = max(conjugation, abs(a_angle - t_angle))
        if a_axis is not None and t_axis is not None:
            pairs.append((a_axis, t_axis, r))
    candidates = []
    if pairs:
        first = pairs[0]
        anchor = shortest_arc(first[0], first[1])
        candidates.append(anchor)
        for a_axis, t_axis, _ in pairs[1:]:
            if abs(_dot(first[0], a_axis)) > 0.999:
                continue
            u = quat_rotate(anchor, a_axis)
            c = _dot(u, first[1])
            p = tuple(a - c * b for a, b in zip(u, first[1]))
            q = tuple(a - c * b for a, b in zip(t_axis, first[1]))
            if math.sqrt(_dot(p, p)) < 1e-6 or math.sqrt(_dot(q, q)) < 1e-6:
                continue
            t = math.degrees(math.atan2(_dot(first[1], _cross(p, q)), _dot(p, q)))
            candidates.append(quat_mul(rot_about(first[1], t), anchor))
            break
        for step in range(1, 8):  # twist-only ambiguity when every axis pair is parallel
            candidates.append(quat_mul(rot_about(first[1], step * 45.0), anchor))
    else:
        candidates.append(IDENTITY)
    best_residual, best = None, None
    for q1 in candidates:
        q2 = quat_mul(quat_conj(q1), q_base)
        residual = 0.0
        for r in records:
            predicted = quat_mul(quat_mul(r['camera'], quat_mul(q1, quat_from_euler((r['rot'][0], r['rot'][1], 0.0)))), q2)
            residual = max(residual, quat_angle_deg(_normalize(predicted), r['light']))
        if best_residual is None or residual < best_residual:
            best_residual, best = residual, (q1, q2)
    residual = max(base_spread, conjugation, best_residual)
    return residual, residual <= ANGLE_TOLERANCE_DEG, best[0], best[1]


def _euler_report(q: Sequence[float]) -> list[float]:
    """Unity-style ``(x, y, z)`` Euler of ``(w, x, y, z)`` with y, z wrapped to
    [0, 360) the way ``Transform.localEulerAngles`` reports."""
    w, x, y, z = q
    pitch = max(-1.0, min(1.0, 2.0 * (w * x - y * z)))
    ex = math.degrees(math.asin(pitch))
    ey = math.degrees(math.atan2(2.0 * (x * z + w * y), 1.0 - 2.0 * (x * x + y * y))) % 360.0
    ez = math.degrees(math.atan2(2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z))) % 360.0
    return [ex, ey, ez]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--trace', type=Path, default=TRACE)
    parser.add_argument('--output', type=Path, help='where to write mapping.json (default: beside --trace)')
    args = parser.parse_args()
    report = analyze(json.loads(args.trace.read_text()))
    output = args.output or args.trace.parent/'mapping.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'records'}, indent=2))


if __name__ == '__main__':
    main()
