import copy
import math
import unittest
from compare_route_playback import compare, unity_from_euler_zxy

DT = 0.5
SIN45 = math.sin(math.radians(45))


def probe_trace():
    routes = [dict(expectedName='IKKOKU-A', dicKey=0, loop=True, orientation=0, playReturned=True, points=[0, 1, 2, 3]),
              dict(expectedName='IKKOKU-B', dicKey=3, loop=False, orientation=1, playReturned=True, points=[0, 1, 2, 3])]
    trace = []
    for index in range(6):
        seconds = index*DT
        half = math.radians(18*seconds)  # matches native()'s 36 degrees/second Z-X-Y Euler X angle
        trace.append(dict(cumulativeTime=seconds,
                          a=dict(position=[seconds, 0, 0], rotation=[0, 0, 0, 1], active=True),
                          b=dict(position=[-seconds, 0, 0], rotation=[math.sin(half), 0, 0, math.cos(half)], active=index < 4)))
    return dict(schemaVersion=1, routes=routes, trace=trace)


def native(delay=0.0, source_key=None):
    def evaluate(seconds):
        angle = 36*(seconds+delay)
        return dict(routes=[
            dict(name='IKKOKU-A', sourceKey=0 if source_key is None else source_key, loop=True, orientation=0,
                 pointCount=4, diagnostics=[], active=True,
                 childRootWorldPosition=[seconds+delay, 0, 0], childRootWorldRotationEulerZXY=[0, 0, 0]),
            dict(name='IKKOKU-B', sourceKey=3, loop=False, orientation=1, pointCount=4, diagnostics=['kept'], active=True,
                 childRootWorldPosition=[-(seconds+delay), 0, 0], childRootWorldRotationEulerZXY=[angle, 0, 0]),
        ])
    return evaluate


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


if __name__ == '__main__':
    unittest.main()
