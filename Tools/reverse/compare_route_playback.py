#!/usr/bin/env python3
"""Compare original CharaStudio route capture with the native route-playback evaluator.

Position and rotation maxima are reported per route over every recorded frame, both at
offset 0 and at the best constant frame offset, because the original StudioTween advances
in Update by whole Time.deltaTime steps while the native evaluator is analytic in time.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import subprocess
from pathlib import Path
from dynamics_contract import REPO

OFFSETS = (0, -1, 1, -2, 2)  # search order also breaks ties: 0 first, then nearer frames


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw*bx+ax*bw+ay*bz-az*by, aw*by-ax*bz+ay*bw+az*bx, aw*bz+ax*by-ay*bx+az*bw, aw*bw-ax*bx-ay*by-az*bz)


def axis_quaternion(axis, degrees):
    half = math.radians(degrees) / 2
    sine = math.sin(half)
    return (axis[0]*sine, axis[1]*sine, axis[2]*sine, math.cos(half))


def unity_from_euler_zxy(euler):
    # Inverse of UnityCoordinates.sourceEulerDegrees. The rotation() conjugation used by
    # eulerDegrees is its own inverse, so it cancels when comparing in the Unity basis:
    # Unity Quaternion.Euler applies Z first, then X, then Y.
    return qmul(qmul(axis_quaternion((0, 1, 0), euler[1]), axis_quaternion((1, 0, 0), euler[0])), axis_quaternion((0, 0, 1), euler[2]))


def angle_degrees(a, b):
    dot = sum(x*y for x, y in zip(a, b))
    return math.degrees(2*math.acos(min(1.0, abs(dot))))  # ±q are the same rotation


def vector(row, field):
    value = row[field]
    if not all(math.isfinite(component) for component in value):
        raise ValueError(f'Nonfinite {field}')
    return list(value)


def segment_timing(times, frames, meta, native):
    """Where the original childRoot comes nearest each route point, per loop cycle,
    against the native segment boundaries from ikkoku-inspect's segmentDurations.

    The capture records each point object's world position and the childRoot world
    position in Unity space, so nearest approach is a direct distance. For looping
    routes the native boundaries repeat every period (the sum of the segment
    durations), so per-cycle arrival drift becomes visible.
    """
    entries = {entry['sourceKey']: entry for entry in native(times[0])['segmentDurations'] or []}
    table = {}
    for name, expected in meta.items():
        entry = entries.get(expected['dicKey'])
        points = expected['points']
        if entry is None or not all(isinstance(point, dict) and 'worldPosition' in point for point in points):
            continue  # fake fixtures without captured point transforms or durations report no timing
        durations, start_indices = entry['durations'], entry['startIndices']
        if len(durations) != len(start_indices) or start_indices != sorted(set(start_indices)) \
                or start_indices[0] != 0 or sum(durations) <= 0:
            raise ValueError(f'Native segment boundaries are not usable for {name}')
        period = sum(durations)
        bounds = [0.0]
        for duration in durations:
            bounds.append(bounds[-1]+duration)
        segment_at = {start: index for index, start in enumerate(start_indices)}
        cycles = int(times[-1]//period)+1 if expected['loop'] else 1
        rows = []
        for index, point in enumerate(points):
            boundary = segment_at.get(index)
            arrivals = []
            for cycle in range(cycles):
                low, high = (cycle*period, (cycle+1)*period) if expected['loop'] else (0.0, math.inf)
                best_distance = best_frame = None
                for frame_index, seconds in enumerate(times):
                    if not low <= seconds < high:
                        continue
                    distance = math.dist(frames[frame_index][name]['position'], point['worldPosition'])
                    if best_distance is None or distance < best_distance:
                        best_distance, best_frame = distance, frame_index
                # Only report a true pass-through: the childRoot's world path goes
                # through every route point, so anything farther apart than one
                # frame's travel is a window edge (capture too short for this
                # cycle), not an arrival.
                if best_frame is None or not best_distance <= 2*abs(times[1]-times[0]):
                    continue
                # Only a segment start has an exact native boundary time; a
                # linked curve chain passes through its interior points mid
                # segment, so their lag against a boundary is not measurable.
                target = bounds[boundary]+cycle*period if boundary is not None else None
                arrivals.append(dict(cycle=cycle, nativeArrivalSeconds=target, originalNearestFrame=best_frame,
                                     originalNearestSeconds=times[best_frame], distanceMetres=best_distance,
                                     signedLagSeconds=times[best_frame]-target if target is not None else None))
            rows.append(dict(pointDicKey=point.get('dicKey'), segmentIndex=boundary, arrivals=arrivals))
        table[name] = dict(segmentDurations=durations, periodSeconds=period, points=rows)
    return table


def compare(probe, evaluate):
    meta = {route['expectedName']: route for route in probe['routes']}
    if len(meta) != len(probe['routes']):
        raise ValueError('Duplicate original route names')
    for name, route in meta.items():
        if not route['playReturned']:
            raise ValueError(f'Original Play() failed for {name}')
    times = [frame['cumulativeTime'] for frame in probe['trace']]
    if not times or not all(math.isfinite(t) for t in times):
        raise ValueError('Trace cumulative times must be finite')
    keys = {name: 'a' if name.endswith('-A') else 'b' for name in meta}
    reports = {}

    def native(seconds):
        if seconds not in reports:
            payload = evaluate(seconds)
            by_name = {route['name']: route for route in payload['routes']}
            if set(by_name) != set(meta):
                raise ValueError(f'Native route names differ at t={seconds}')
            for name, route in by_name.items():
                expected = meta[name]
                if route['sourceKey'] != expected['dicKey'] or route['loop'] != expected['loop'] \
                        or route['orientation'] != expected['orientation'] or route['pointCount'] != len(expected['points']):
                    raise ValueError(f'Native/original route identity differs at t={seconds}')
            reports[seconds] = dict(routes=by_name, segmentDurations=payload.get('segmentDurations'))
        return reports[seconds]

    diagnostics = {}
    frames = []
    for seconds, frame in zip(times, probe['trace']):
        row = {}
        for name in meta:
            recorded, route = frame[keys[name]], native(seconds)['routes'][name]
            for message in route['diagnostics']:
                diagnostics[message] = diagnostics.get(message, 0) + 1
            rotation = vector(recorded, 'rotation')
            if sum(x*x for x in rotation) <= 0:
                raise ValueError('Original quaternion is degenerate')
            row[name] = dict(position=vector(recorded, 'position'), rotation=rotation,
                             active=recorded['active'])
        frames.append(row)

    offsets = []
    for offset in OFFSETS:
        table = {}
        for name in meta:
            position_error = rotation_error = active_position = active_rotation = 0.0
            active_frames = 0
            for index, cell in enumerate((row[name] for row in frames)):
                shifted = index + offset
                if not 0 <= shifted < len(times):
                    continue
                sampled = native(times[shifted])['routes'][name]
                error = math.dist(cell['position'], vector(sampled, 'childRootWorldPosition'))
                rotation = angle_degrees(cell['rotation'], unity_from_euler_zxy(vector(sampled, 'childRootWorldRotationEulerZXY')))
                position_error = max(position_error, error)
                rotation_error = max(rotation_error, rotation)
                if cell['active']:
                    active_frames += 1
                    active_position = max(active_position, error)
                    active_rotation = max(active_rotation, rotation)
            table[name] = dict(framesCompared=sum(1 for i in range(len(frames)) if 0 <= i+offset < len(times)),
                               framesOriginalActive=active_frames,
                               maximumPositionErrorMetres=position_error, maximumRotationErrorDegrees=rotation_error,
                               maximumPositionErrorMetresWhileActive=active_position,
                               maximumRotationErrorDegreesWhileActive=active_rotation)
        offsets.append(dict(offset=offset, routes=table,
                            maximumPositionErrorMetres=max(row['maximumPositionErrorMetres'] for row in table.values())))
    best = min(offsets, key=lambda entry: (entry['maximumPositionErrorMetres'], offsets.index(entry)))
    timing = segment_timing(times, frames, meta, native)
    routes = {}
    for name, expected in meta.items():
        inactive = [index for index, row in enumerate(frames) if not row[name]['active']]
        entry = dict(sourceKey=expected['dicKey'], name=name, orientation=expected['orientation'],
                     loop=expected['loop'], pointCount=len(expected['points']),
                     firstOriginalInactiveFrame=inactive[0] if inactive else None,
                     originalMaximumFrameDriftAfterInactiveMetres=max(
                         (math.dist(frames[i][name]['position'], frames[i-1][name]['position']) for i in inactive if i > 0),
                         default=None),
                     atOffset0=offsets[OFFSETS.index(0)]['routes'][name])
        chosen = best['routes'][name]
        entry['atBestOffset'] = dict(offset=best['offset'], **chosen)
        entry['maximumPositionErrorMetresByOffset'] = {
            str(entry['offset']): round(entry['routes'][name]['maximumPositionErrorMetres'], 9) for entry in offsets}
        routes[name] = entry
    return dict(schemaVersion=1, frames=len(frames), evaluatedTimes=len(reports), routes=routes,
                bestConstantFrameOffset=best['offset'], offsetScan=offsets, segmentTiming=timing,
                nativeDiagnostics=diagnostics,
                scope='Native ikkoku-inspect route-playback versus original per-frame childRoot world placement; '
                      'rotation compared as quaternions reconstructed from the emitted Z-X-Y Euler angles; '
                      'original LookUpdate smoothing is not simulated by the native evaluator')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, default=REPO/'.local/stt11c/probe')
    parser.add_argument('--cli', type=Path, default=REPO/'Packages/Engine/.build/debug/ikkoku-inspect')
    parser.add_argument('--output', type=Path, default=REPO/'.local/stt11c/route-playback-comparison.json')
    arguments = parser.parse_args()
    if not arguments.output.resolve().is_relative_to((REPO/'.local').resolve()):
        raise ValueError('Original-derived reports stay in .local')
    trace_path = arguments.probe/'route-trace.json'
    scene_path = arguments.probe/'route-scene.png'

    def evaluate(seconds):
        result = subprocess.run([str(arguments.cli), 'route-playback', str(scene_path), '%.9g' % seconds],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return json.loads(result.stdout)

    result = compare(json.loads(trace_path.read_text()), evaluate)
    result['evidence'] = [dict(path=str(path.resolve()), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                          for path in [trace_path, scene_path, Path(__file__)]]
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ('offsetScan', 'evidence')}, indent=2))


if __name__ == '__main__':
    main()
