import copy
import math
import unittest
from compare_route_playback import compare, compare_stepped, unity_from_euler_zxy

DT = 0.5
SIN45 = math.sin(math.radians(45))


def probe_trace():
    routes = [dict(expectedName='IKKOKU-A', dicKey=0, loop=True, orientation=0, playReturned=True, points=[0, 1, 2, 3]),
              dict(expectedName='IKKOKU-B', dicKey=3, loop=False, orientation=1, playReturned=True, points=[0, 1, 2, 3])]
    trace = []
    for index in range(6):
        seconds = index*DT
        half = math.radians(18*seconds)  # matches native()'s 36 degrees/second Z-X-Y Euler X angle
        trace.append(dict(cumulativeTime=seconds, deltaTime=DT,
                          a=dict(position=[seconds, 0, 0], rotation=[0, 0, 0, 1], active=True),
                          b=dict(position=[-seconds, 0, 0], rotation=[math.sin(half), 0, 0, math.cos(half)], active=index < 4)))
    return dict(schemaVersion=1, routes=routes, trace=trace)


def native(delay=0.0, source_key=None, segment_durations=None):
    def evaluate(seconds):
        angle = 36*(seconds+delay)
        return dict(routes=[
            dict(name='IKKOKU-A', sourceKey=0 if source_key is None else source_key, loop=True, orientation=0,
                 pointCount=4, diagnostics=[], active=True,
                 childRootWorldPosition=[seconds+delay, 0, 0], childRootWorldRotationEulerZXY=[0, 0, 0]),
            dict(name='IKKOKU-B', sourceKey=3, loop=False, orientation=1, pointCount=4, diagnostics=['kept'], active=True,
                 childRootWorldPosition=[-(seconds+delay), 0, 0], childRootWorldRotationEulerZXY=[angle, 0, 0]),
        ], segmentDurations=segment_durations)
    return evaluate


def stepped(delay=0.0, source_key=None, active_override=None, frame_count=None,
            position_override=None, play_deltas=None):
    """Stub of `ikkoku-inspect route-steps`: frame `k` reproduces capture row
    `k` (the CLI is fed ``deltas[1:]`` plus the Play frame's delta), optionally
    skewed. ``play_deltas`` collects the Play deltas the driver forwards so
    tests can assert the seed arrives."""
    def step(deltas, play_delta=None):
        if play_deltas is not None:
            play_deltas.append(play_delta)
        trace = probe_trace()['trace']
        count = len(deltas) if frame_count is None else frame_count
        routes = []
        for name, key, orientation, loop in (('IKKOKU-A', 'a', 0, True), ('IKKOKU-B', 'b', 1, False)):
            frames = []
            for index in range(count):
                row = trace[min(index, len(trace)-1)][key]
                position = [row['position'][0]+delay, 0, 0]
                if position_override is not None:
                    position = position_override
                active = row['active'] if active_override is None else active_override
                euler = [0, 0, 0] if key == 'a' else [36*index*DT, 0, 0]
                frames.append(dict(deltaTime=deltas[index] if index < len(deltas) else DT,
                                   active=active, rotationFromAim=key == 'b',
                                   childRootWorldPosition=position,
                                   childRootWorldRotationEulerZXY=euler))
            routes.append(dict(name=name, sourceKey=3 if key == 'b' else (0 if source_key is None else source_key),
                               loop=loop, orientation=orientation, pointCount=4, diagnostics=[],
                               frames=frames))
        return dict(routes=routes)
    return step


class RoutePlaybackComparisonTests(unittest.TestCase):
    def test_exact_parity_selects_zero_offset_and_reports_diagnostics(self):
        result = compare(probe_trace(), native())
        self.assertEqual(result['bestConstantFrameOffset'], 0)
        self.assertEqual(result['nativeDiagnostics'], {'kept': result['evaluatedTimes']})
        for entry in result['routes'].values():
            self.assertEqual(entry['atOffset0']['maximumPositionErrorMetres'], 0)
            # The native CLI emits Float32 Z-X-Y Euler angles, so the inverse
            # decode carries float32 round-trip noise (measured ~2e-6 degrees).
            self.assertLess(entry['atOffset0']['maximumRotationErrorDegrees'], 1e-4)
        self.assertEqual(result['routes']['IKKOKU-B']['firstOriginalInactiveFrame'], 4)

    def test_native_ahead_by_one_frame_selects_negative_offset(self):
        result = compare(probe_trace(), native(delay=DT))
        self.assertEqual(result['bestConstantFrameOffset'], -1)
        for entry in result['routes'].values():
            self.assertEqual(entry['atBestOffset']['maximumPositionErrorMetres'], 0)
            self.assertAlmostEqual(entry['atOffset0']['maximumPositionErrorMetres'], DT)

    def test_zxy_euler_decode_and_antipodal_quaternions(self):
        self.assertAlmostEqual(unity_from_euler_zxy([90, 0, 0])[0], SIN45)
        self.assertAlmostEqual(unity_from_euler_zxy([90, 0, 0])[3], SIN45)
        flipped = probe_trace()
        for frame in flipped['trace']:
            frame['b']['rotation'] = [-x for x in frame['b']['rotation']]
        flipped_error = compare(flipped, native())['routes']['IKKOKU-B']['atOffset0']['maximumRotationErrorDegrees']
        self.assertLess(flipped_error, 1e-4)  # antipodal quaternions compare as the same rotation
        rotated_error = compare(probe_trace(), native())['routes']['IKKOKU-B']['atOffset0']['maximumRotationErrorDegrees']
        self.assertLess(rotated_error, 1e-4)
        skewed = compare(probe_trace(), native(delay=DT/36*90))  # 36 degrees/second * delay = 45 degrees of skew
        self.assertGreater(skewed['routes']['IKKOKU-B']['atOffset0']['maximumRotationErrorDegrees'], 40)

    def test_per_offset_table_and_empty_segment_timing(self):
        result = compare(probe_trace(), native(delay=DT))
        self.assertEqual(result['bestConstantFrameOffset'], -1)
        for entry in result['routes'].values():
            by_offset = entry['maximumPositionErrorMetresByOffset']
            self.assertEqual(set(by_offset), {'-2', '-1', '0', '1', '2'})
            self.assertAlmostEqual(by_offset['0'], DT)
            self.assertEqual(by_offset[str(result['bestConstantFrameOffset'])],
                             entry['atBestOffset']['maximumPositionErrorMetres'])
        # The fake fixture emits no captured point transforms, so no timing table.
        self.assertEqual(result['segmentTiming'], {})

    def test_segment_timing_arrivals_against_native_boundaries(self):
        timed = probe_trace()
        # Route A's childRoot path runs along +x one unit/second. Point 3 sits
        # far enough ahead that the 2.5 s capture never passes it.
        positions = ([0, 0, 0], [1, 0, 0], [2.5, 0, 0], [6, 0, 0])
        timed['routes'][0]['points'] = [dict(dicKey=k, worldPosition=position)
                                        for k, position in enumerate(positions)]
        durations = [dict(sourceKey=0, startIndices=[0, 2], durations=[2.0, 2.0])]
        result = compare(timed, native(segment_durations=durations))
        self.assertEqual(list(result['segmentTiming']), ['IKKOKU-A'])  # B: no durations entry
        table = result['segmentTiming']['IKKOKU-A']
        self.assertEqual(table['segmentDurations'], [2.0, 2.0])
        self.assertEqual(table['periodSeconds'], 4.0)
        rows = table['points']
        self.assertEqual(rows[0]['arrivals'][0]['signedLagSeconds'], 0.0)
        # Point 1 is a linked chain interior: nearest approach is known but no
        # exact native boundary exists, so its lag is not measurable.
        self.assertIsNone(rows[1]['segmentIndex'])
        self.assertEqual(rows[1]['arrivals'][0]['originalNearestSeconds'], 1.0)
        self.assertIsNone(rows[1]['arrivals'][0]['signedLagSeconds'])
        # The original passes point 2 at 2.5 s while the native segment boundary
        # is at 2.0 s: the drift shows up as a signed lag.
        self.assertEqual(rows[2]['segmentIndex'], 1)
        self.assertEqual(rows[2]['arrivals'][0]['nativeArrivalSeconds'], 2.0)
        self.assertEqual(rows[2]['arrivals'][0]['signedLagSeconds'], 0.5)
        # Point 3 is never reached inside the 2.5 s capture window.
        self.assertEqual(rows[3]['arrivals'], [])

    def test_unusable_segment_boundaries_raise(self):
        timed = probe_trace()
        timed['routes'][0]['points'] = [dict(dicKey=k, worldPosition=[k, 0, 0]) for k in range(4)]
        for durations in ([dict(sourceKey=0, startIndices=[2, 0], durations=[2.0, 2.0])],
                          [dict(sourceKey=0, startIndices=[1], durations=[2.0])]):
            with self.assertRaises(ValueError):
                compare(timed, native(segment_durations=durations))

    def test_identity_and_finite_violations_raise(self):
        with self.assertRaises(ValueError):
            compare(probe_trace(), native(source_key=7))
        missing_play = probe_trace()
        missing_play['routes'][0]['playReturned'] = False
        with self.assertRaises(ValueError):
            compare(missing_play, native())
        nonfinite = probe_trace()
        nonfinite['trace'][2]['a']['position'][0] = math.nan
        with self.assertRaises(ValueError):
            compare(nonfinite, native())
        short = probe_trace()
        short['trace'] = []
        with self.assertRaises(ValueError):
            compare(short, native())
        changed = copy.deepcopy(probe_trace())
        changed['trace'][1]['cumulativeTime'] = math.inf
        with self.assertRaises(ValueError):
            compare(changed, native())


class SteppedComparisonTests(unittest.TestCase):
    def test_exact_parity_reports_zero_error_and_no_active_mismatch(self):
        result = compare_stepped(probe_trace(), stepped())
        self.assertEqual(result['framesCompared'], 5)  # row 0's deltaTime is Play's, never consumed
        for entry in result['routes'].values():
            self.assertEqual(entry['framesCompared'], 5)
            self.assertEqual(entry['maximumPositionErrorMetres'], 0)
            # The Z-X-Y Euler decode is float-sensitive; see the note in the
            # continuous parity test above.
            self.assertLess(entry['maximumRotationErrorDegrees'], 1e-4)
            self.assertEqual(entry['framesActiveMismatch'], 0)
            self.assertNotIn('maximumPositionErrorMetresContinuous', entry)  # no continuous run asked for

    def test_position_skew_and_active_mismatch_are_measured(self):
        result = compare_stepped(probe_trace(), stepped(delay=DT, active_override=False))
        for name, entry in result['routes'].items():
            self.assertAlmostEqual(entry['maximumPositionErrorMetres'], DT)
            self.assertEqual(entry['framesActiveMismatch'], 4 if name == 'IKKOKU-B' else 5)

    def test_continuous_maxima_are_carried_alongside_stepped_ones(self):
        continuous = compare(probe_trace(), native())
        result = compare_stepped(probe_trace(), stepped(), continuous=continuous)
        for name, entry in result['routes'].items():
            self.assertEqual(entry['maximumPositionErrorMetresContinuous'],
                             continuous['routes'][name]['atOffset0']['maximumPositionErrorMetres'])
            self.assertEqual(entry['maximumRotationErrorDegreesContinuous'],
                             continuous['routes'][name]['atOffset0']['maximumRotationErrorDegrees'])

    def test_play_frame_delta_is_forwarded_as_the_lookupdate_seed(self):
        trace = probe_trace()
        trace['trace'][0]['deltaTime'] = 0.019  # distinguishable from the consumed rows
        play_deltas = []
        compare_stepped(trace, stepped(play_deltas=play_deltas))
        self.assertEqual(play_deltas, [0.019])

    def test_identity_frame_count_and_finite_violations_raise(self):
        with self.assertRaises(ValueError):  # wrong sourceKey
            compare_stepped(probe_trace(), stepped(source_key=7))
        with self.assertRaises(ValueError):  # CLI emitted the wrong frame count
            compare_stepped(probe_trace(), stepped(frame_count=4))
        with self.assertRaises(ValueError):  # nonfinite stepped position
            compare_stepped(probe_trace(), stepped(position_override=[math.nan, 0, 0]))
        negative = probe_trace()
        negative['trace'][2]['deltaTime'] = -0.1
        with self.assertRaises(ValueError):  # invalid trace deltaTime
            compare_stepped(negative, stepped())


if __name__ == '__main__':
    unittest.main()
