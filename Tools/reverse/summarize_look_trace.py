#!/usr/bin/env python3
"""Summarize one original neck/eye look-at capture (look-trace.json).

Reads the trace written by `original_character_probe.py --look-patterns` and
reports, for every camera phase and every recorded track (the cf_j_neck and
cf_j_head local rotations and each eye's local rotation): the first frame
whose onward per-frame rotation change stays below a threshold (0.01° per
frame by default, the settle definition the hand-pattern comparator uses),
the largest single-frame rotation step in the phase, the settled angle
between the phase's first and last recorded frame, and for the two neck
bones the angle between the last frame's local rotation and the internal
fixAngle. A neck pattern 4 (FIX) phase should settle at frame 0 with a fix
deviation at the threshold; a pattern 3 (ANIMATION) phase shows its animated
pose only as continued movement — the trace holds no independent animated
pose to compare against.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path

from compare_hand_patterns import angle_degrees

SETTLE_THRESHOLD_DEGREES = 0.01
TRACK_ORDER = ['cf_j_neck', 'cf_j_head']


def settle_frame(changes: list[float], threshold: float) -> int | None:
    """First frame whose onward per-frame changes all stay under the threshold.

    `changes[i]` is the rotation angle between recorded frames i and i+1.
    Returns None when the final change still exceeds the threshold, i.e. the
    track had not stopped moving by the phase's last recorded frame.
    """
    if not all(change >= 0 for change in changes):
        raise ValueError('per-frame changes must be non-negative angles')
    for i in range(len(changes) - 1, -1, -1):
        if changes[i] >= threshold:
            return None if i == len(changes) - 1 else i + 1
    return 0


def track_quaternions(frames: list[dict], track: str) -> list[list[float]]:
    """The named track's localRotation sequence over the phase's frames."""
    values = []
    for frame in frames:
        neck = frame.get('neck') or {}
        eyes = frame.get('eyes') or {}
        holder = None
        for bone in neck.get('bones') or []:
            if bone['bone'] == track:
                holder = bone
        if holder is None:
            for eye in eyes.get('eyes') or []:
                if eye['eye'] == track:
                    holder = eye
        if holder is None or len(holder.get('localRotation') or []) != 4:
            raise ValueError(f'frame at Time.frameCount {frame.get("frameCount")} has no localRotation for {track}')
        values.append(holder['localRotation'])
    return values


def phase_tracks(frames: list[dict], threshold: float) -> dict[str, dict]:
    """Per-track settle/max-step/settled-angle measurements for one phase."""
    tracks = TRACK_ORDER + [eye['eye'] for eye in (frames[-1].get('eyes') or {}).get('eyes') or []]
    result = {}
    for track in tracks:
        rotations = track_quaternions(frames, track)
        changes = [angle_degrees(rotations[i], rotations[i + 1]) for i in range(len(rotations) - 1)]
        entry = {'frames': len(rotations),
                 'settleFrame': settle_frame(changes, threshold),
                 'maxStepDegrees': max(changes) if changes else 0.0,
                 'settledAngleDegrees': angle_degrees(rotations[0], rotations[-1])}
        for bone in (frames[-1].get('neck') or {}).get('bones') or []:
            if bone['bone'] == track:
                entry['fixAngleDeviationDegrees'] = angle_degrees(bone['localRotation'], bone['fixAngle'])
        result[track] = entry
    return result


def summarize(trace: dict, threshold: float = SETTLE_THRESHOLD_DEGREES) -> list[dict]:
    """One summary per recorded camera phase; raises when the trace is broken."""
    if trace.get('error'):
        raise ValueError(f'the capture reported an error: {trace["error"]}')
    if threshold <= 0:
        raise ValueError('the settle threshold must be positive')
    summaries = []
    frames = trace.get('frames') or []
    for phase, phase_info in enumerate(trace.get('phases') or []):
        phase_frames = [frame for frame in frames if frame.get('phase') == phase]
        if len(phase_frames) != phase_info['frames']:
            raise ValueError(f'phase {phase} asked for {phase_info["frames"]} frames but the trace holds {len(phase_frames)}')
        if any(b['bone'] != name for frame in phase_frames for name, b in zip(TRACK_ORDER, frame['neck']['bones'])):
            raise ValueError(f'phase {phase} does not record {TRACK_ORDER} in order on every frame')
        summary = {'phase': phase, 'neckPattern': phase_info['neckPattern'], 'eyesPattern': phase_info['eyesPattern'],
                   'lastNeckPtnNo': phase_frames[-1]['neck']['ptnNo'], 'lastEyesPtnNo': phase_frames[-1]['eyes']['ptnNo'],
                   'tracks': phase_tracks(phase_frames, threshold)}
        summaries.append(summary)
    return summaries


def format_table(summaries: list[dict]) -> str:
    lines = ['| phase | neck/eyes ptn | track | settle frame | max step ° | settled angle ° | fixAngle dev ° |',
             '|---|---|---|---|---|---|---|']
    for summary in summaries:
        for track, entry in summary['tracks'].items():
            fix = entry.get('fixAngleDeviationDegrees')
            lines.append('| {} | {} / {} | {} | {} | {:.3f} | {:.3f} | {} |'.format(
                summary['phase'], summary['neckPattern'], summary['eyesPattern'], track,
                'never' if entry['settleFrame'] is None else entry['settleFrame'],
                entry['maxStepDegrees'], entry['settledAngleDegrees'],
                '—' if fix is None else f'{fix:.3f}'))
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('capture', type=Path, help='capture directory or look-trace.json written by --look-patterns')
    parser.add_argument('--threshold', type=float, default=SETTLE_THRESHOLD_DEGREES,
                        help='per-frame rotation change (degrees) under which a track counts as settled')
    args = parser.parse_args()
    path = args.capture if args.capture.suffix == '.json' else args.capture / 'look-trace.json'
    trace = json.loads(path.read_text())
    summaries = summarize(trace, args.threshold)
    print(format_table(summaries))
    for summary in summaries:
        print(f'phase {summary["phase"]}: last ptnNo neck={summary["lastNeckPtnNo"]} eyes={summary["lastEyesPtnNo"]}')


if __name__ == '__main__':
    main()
