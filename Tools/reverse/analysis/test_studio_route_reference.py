"""Contract tests for the recovered route/tween reference port.

Checks are independent closed forms (straight-line interpolation, hand
arithmetic from the recovered formulas) — not re-runs of the port. Only the
``PathLength`` double-padding quirk is deliberately asserted as a regression:
the original times a straight two-point segment at three times its geometric
length because ``PathLength`` re-runs ``PathControlPointGenerator``.
"""
import json
import math
import tempfile
import unittest
from pathlib import Path

import studio_route_reference as ref

LINE = (ref.RoutePoint((0, 0, 0), None, "line", False, 2.0),
        ref.RoutePoint((2, 0, 0), None, "line", False, 2.0),
        ref.RoutePoint((2, 2, 0), None, "line", False, 2.0))


def _point(position, aid=None, connection="line", link=False, speed=2.0, ease="linear"):
    return ref.RoutePoint(position, aid, connection, link, speed, ease)


class EasingTests(unittest.TestCase):
    def test_ease_type_order_matches_the_recovered_enum(self):
        # StudioTween.cs EaseType at line 17; route records store this ordinal.
        self.assertEqual(ref.EASE_TYPES, (
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
        ))
        self.assertEqual(set(ref.EASING), set(ref.EASE_TYPES))

    def test_every_easing_reaches_its_end_value(self):
        # The expo pair has no value == 1 special case (StudioTween.cs
        # 3882-3898), so it stops 2**-10 / 2**-11 short of the end value.
        short_by = {"easeOutExpo": 2.0 ** -10, "easeInOutExpo": 2.0 ** -11}
        for name in ref.EASE_TYPES:
            expected = 1.0 - short_by.get(name, 0.0)
            self.assertAlmostEqual(ref.EASING[name](0.0, 1.0, 1.0), expected,
                                   places=12, msg=name)

    def test_every_easing_starts_at_zero_except_the_expo_quirk(self):
        # The source easeInExpo has no v == 0 special case: f(0) = 2**-10.
        quirky = {"easeInExpo", "easeInOutExpo"}
        for name in ref.EASE_TYPES:
            value = ref.EASING[name](0.0, 1.0, 0.0)
            if name in quirky:
                self.assertGreater(value, 0.0, name)
            else:
                self.assertAlmostEqual(value, 0.0, places=5, msg=name)
        self.assertAlmostEqual(ref.EASING["easeInExpo"](0.0, 1.0, 0.0), 2.0 ** -10)

    def test_hand_computed_ease_values(self):
        cases = {
            "linear": (0.3, 0.3),
            "easeInQuad": (0.5, 0.25),
            "easeOutQuad": (0.5, 0.75),
            "easeInOutQuad": (0.5, 0.5),
            "easeInCubic": (0.5, 0.125),
            "easeOutCubic": (0.5, 0.875),
            "easeInSine": (0.5, 1.0 - math.cos(math.pi / 4)),
            "easeOutSine": (0.5, math.sin(math.pi / 4)),
            "easeInOutSine": (0.5, 0.5),
            # easeInBack s=1.70158: v^2 * ((s+1)v - s) at v = 0.5.
            "easeInBack": (0.5, 0.25 * (2.70158 * 0.5 - 1.70158)),
            # easeOutBounce branch v < 744/1023: (v - 558/1023) = -1/22 ->
            # 7.5625/484 + 0.75 = 1/64 + 3/4 exactly.
            "easeOutBounce": (0.5, 0.765625),
            # easeInElastic: period 0.3, s = 0.075 -> -2**-5 * sin(pi/6) = -1/64.
            "easeInElastic": (0.5, -1.0 / 64.0),
            "spring": (0.0, 0.0),
            "spring": (1.0, 1.0),
        }
        for name, (value, expected) in cases.items():
            self.assertAlmostEqual(ref.EASING[name](0.0, 1.0, value), expected, places=9, msg=name)

    def test_elastic_fixed_points_are_exact(self):
        for name in ("easeInElastic", "easeOutElastic", "easeInOutElastic"):
            ease = ref.EASING[name]
            self.assertEqual(ease(0.0, 1.0, 0.0), 0.0, name)
            self.assertEqual(ease(0.0, 1.0, 1.0), 1.0, name)


class SplineTests(unittest.TestCase):
    def test_reflective_padding_of_a_two_point_path(self):
        padded = ref.path_control_point_generator(((0, 0, 0), (2, 0, 0)))
        self.assertEqual(padded, [(-2, 0, 0), (0, 0, 0), (2, 0, 0), (4, 0, 0)])

    def test_closed_path_wraps_instead_of_reflecting(self):
        path = ((0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 0, 0))
        padded = ref.path_control_point_generator(path)
        # array[0] = array[-3] and array[-1] = array[2] on a closed path.
        self.assertEqual(padded[0], padded[-3])
        self.assertEqual(padded[-1], padded[2])

    def test_interp_runs_the_segment_linearly_on_collinear_controls(self):
        padded = ref.path_control_point_generator(((0, 0, 0), (2, 0, 0)))
        self.assertEqual(ref.interp(padded, 0.0), (0.0, 0.0, 0.0))
        self.assertEqual(ref.interp(padded, 1.0), (2.0, 0.0, 0.0))
        for t in (0.1, 0.5, 0.9):
            position = ref.interp(padded, t)
            self.assertAlmostEqual(position[0], 2.0 * t, places=12)

    def test_path_length_double_pads_like_the_source(self):
        # PathLength(vector3s) re-runs PathControlPointGenerator over the
        # already-padded array: a 2-unit straight path measures 6 units.
        padded = ref.path_control_point_generator(((0, 0, 0), (2, 0, 0)))
        self.assertAlmostEqual(ref.path_length(padded), 6.0, places=9)


class SegmentBuildingTests(unittest.TestCase):
    def test_line_loop_wraps_and_line_no_loop_skips_the_last_point(self):
        loop = ref.build_segments(ref.Route(points=LINE, loop=True))
        self.assertEqual(len(loop), 3)
        self.assertEqual(loop[2].path, ((2, 2, 0), (0, 0, 0)))
        no_loop = ref.build_segments(ref.Route(points=LINE, loop=False))
        self.assertEqual([s.start_index for s in no_loop], [0, 1])

    def test_curve_segments_interleave_point_and_aid_pairs(self):
        route = ref.Route(points=(
            _point((0, 0, 0), (1, 0, 0), "curve"),
            _point((2, 0, 0), (3, 1, 0), "curve"),
            _point((4, 0, 0), (5, 2, 0), "curve"),
        ), loop=False)
        segments = ref.build_segments(route)
        self.assertEqual([s.path for s in segments],
                         [((0, 0, 0), (1, 0, 0), (2, 0, 0)),
                          ((2, 0, 0), (3, 1, 0), (4, 0, 0))])

    def test_linked_curve_points_join_one_segment(self):
        # link only chains Curve points (isLink); the joined path carries
        # every [point, aid] pair and ends at the first unlinked point.
        route = ref.Route(points=(
            _point((0, 0, 0), (1, 0, 0), "curve", link=True),
            _point((2, 0, 0), (3, 1, 0), "curve", link=True),
            _point((4, 0, 0), (5, 2, 0), "curve"),
        ), loop=False)
        segments = ref.build_segments(route)
        self.assertEqual(len(segments), 1)
        self.assertEqual(segments[0].path,
                         ((0, 0, 0), (1, 0, 0), (2, 0, 0), (3, 1, 0), (4, 0, 0)))

    def test_link_flag_on_a_line_point_does_not_chain(self):
        route = ref.Route(points=(
            _point((0, 0, 0), None, "line", link=True),
            _point((2, 0, 0), None, "line", link=True),
            _point((4, 0, 0), None, "line"),
        ), loop=False)
        segments = ref.build_segments(route)
        self.assertEqual([s.path for s in segments],
                         [((0, 0, 0), (2, 0, 0)), ((2, 0, 0), (4, 0, 0))])

    def test_segment_duration_uses_the_segment_speed(self):
        route = ref.Route(points=(_point((0, 0, 0), speed=4.0), _point((2, 0, 0), speed=4.0)),
                          loop=False)
        self.assertAlmostEqual(ref.build_segments(route)[0].duration, 1.5, places=9)

    def test_unplayable_routes_raise_with_diagnostics(self):
        cases = {
            "fewer than two points": ref.Route(points=(_point((0, 0, 0)),)),
            "zero speed": ref.Route(points=(_point((0, 0, 0), speed=0.0), _point((2, 0, 0)))),
            "non-finite speed": ref.Route(points=(_point((0, 0, 0), speed=math.inf), _point((2, 0, 0)))),
            "non-finite position": ref.Route(points=(_point((math.nan, 0, 0)), _point((2, 0, 0)))),
            "unknown connection": ref.Route(points=(_point((0, 0, 0), connection="bezier"),
                                                    _point((2, 0, 0)))),
            "unknown ease": ref.Route(points=(_point((0, 0, 0), ease="easeInChaos"),
                                              _point((2, 0, 0)))),
            "curve without aid": ref.Route(points=(_point((0, 0, 0), None, "curve"),
                                                   _point((2, 0, 0)))),
            "non-finite aid": ref.Route(points=(_point((0, 0, 0), (math.inf, 0, 0), "curve"),
                                                _point((2, 0, 0)))),
            "unknown orientation": ref.Route(points=LINE, orient="xyz"),
            "zero-length path": ref.Route(points=(_point((1, 1, 1)), _point((1, 1, 1))), loop=False),
        }
        for label, route in cases.items():
            with self.assertRaises(ref.RouteNotPlayable, msg=label):
                ref.build_segments(route)


class EvaluationTests(unittest.TestCase):
    def test_line_segments_interpolate_at_closed_form_positions(self):
        route = ref.Route(points=LINE, loop=True)
        segments = ref.build_segments(route)
        durations = [s.duration for s in segments]
        total = sum(durations)
        # t = 8.0: inside the closing (2,2,0)->(0,0,0) segment.
        evaluation = ref.evaluate(route, 8.0)
        self.assertEqual(evaluation.segment_index, 2)
        fraction = (8.0 - durations[0] - durations[1]) / durations[2]
        expected = 2.0 - 2.0 * fraction
        for axis in (0, 1):
            self.assertAlmostEqual(evaluation.position[axis], expected, places=9)
        # Each straight segment times at 3x its geometric length (PathLength
        # re-pads the already-padded array): 2 units at speed 2 -> 3.0 s, and
        # the closing diagonal of length 2*sqrt(2) adds 3*sqrt(2) seconds.
        self.assertAlmostEqual(durations[0], 3.0, places=9)
        self.assertAlmostEqual(durations[1], 3.0, places=9)
        self.assertAlmostEqual(total, 6.0 + 3.0 * math.sqrt(2.0), places=9)
        self.assertFalse(evaluation.finished)

    def test_loop_wraps_time_and_never_finishes(self):
        route = ref.Route(points=LINE, loop=True)
        total = sum(s.duration for s in ref.build_segments(route))
        wrapped = ref.evaluate(route, 8.0 + total)
        direct = ref.evaluate(route, 8.0)
        # total is not a power of two, so (8 + total) % total can land one
        # ulp from 8 % total; compare the wrapped sample with tolerance.
        for axis in range(3):
            self.assertAlmostEqual(wrapped.position[axis], direct.position[axis],
                                   places=12, msg=str(axis))
        self.assertFalse(wrapped.finished)

    def test_no_loop_clamps_at_the_endpoint_and_finishes(self):
        route = ref.Route(points=(_point((0, 0, 0), speed=4.0), _point((2, 0, 0), speed=4.0),
                                  _point((2, 2, 0), speed=4.0)), loop=False)
        # PathLength triple-counts each straight segment, so at speed 4 every
        # segment runs 6 padded units / 4 = 1.5 s: t = 2.0 sits a third into
        # the second segment, t = 2.25 at its midpoint.
        third = ref.evaluate(route, 2.0)
        self.assertEqual(third.segment_index, 1)
        self.assertAlmostEqual(third.position[1], 2.0 / 3.0, places=12)
        middle = ref.evaluate(route, 2.25)
        self.assertEqual(middle.segment_index, 1)
        self.assertEqual(middle.position, (2.0, 1.0, 0.0))
        self.assertFalse(middle.finished)
        end = ref.evaluate(route, 3.0)
        self.assertTrue(end.finished)
        self.assertEqual(end.position, (2.0, 2.0, 0.0))
        # Time past the end keeps clamping to the final position.
        past = ref.evaluate(route, 9.0)
        self.assertEqual(past.position, end.position)
        self.assertEqual(past.segment_index, end.segment_index)

    def test_easing_reaches_the_segment_end_at_the_segment_time(self):
        # Speed 6 on a two-point segment makes the source's padded path
        # length (6 units) run in exactly 1.0 s; no-loop keeps the route a
        # single segment so percentage 1 is sampled on the first segment.
        short_at_end = {"easeOutExpo": 2.0 ** -10, "easeInOutExpo": 2.0 ** -11}
        for ease in ref.EASE_TYPES:
            route = ref.Route(points=(_point((0, 0, 0), speed=6.0, ease=ease),
                                       _point((2, 0, 0), speed=6.0, ease=ease)),
                              loop=False)
            segment = ref.build_segments(route)[0]
            self.assertAlmostEqual(segment.duration, 1.0, places=9, msg=ease)
            evaluation = ref.evaluate(route, segment.duration)
            self.assertEqual(evaluation.segment_index, 0, ease)
            # The straight padded spline reaches its closing point at t = 1,
            # so position = 2 * ease(1): exactly 2.0 except for the expo pair
            # the source leaves 2**-10 / 2**-11 short of the end value.
            expected = 2.0 * (1.0 - short_at_end.get(ease, 0.0))
            self.assertAlmostEqual(evaluation.position[0], expected, places=9, msg=ease)

    def test_orientation_look_target_and_yaw_rotation(self):
        route = ref.Route(points=(_point((0, 0, 0)), _point((2, 1, 2))), orient="y")
        evaluation = ref.evaluate(route, 0.5)
        self.assertAlmostEqual(evaluation.position[0], 2.0 / 9.0, places=12)
        look = evaluation.orientation
        self.assertEqual(look.axis, "y")
        fraction = min(1.0, 0.5 / 4.5 + ref.LOOK_AHEAD)
        for axis in range(3):
            self.assertAlmostEqual(look.look_target[axis],
                                   2.0 * fraction, places=12 if axis != 1 else 12,
                                   msg=str(axis)) if axis != 1 else self.assertAlmostEqual(
                look.look_target[1], 1.0 * fraction, places=12)
        # Horizontal aim along (1, 0, 1): +45 degrees about Y, w = cos(22.5 deg).
        for got, want in zip(look.rotation, (math.cos(math.pi / 8), 0.0, math.sin(math.pi / 8), 0.0)):
            self.assertAlmostEqual(got, want, places=9)

    def test_orientation_none_axis_emits_no_rotation(self):
        route = ref.Route(points=(_point((0, 0, 0)), _point((2, 1, 2))))
        self.assertIsNone(ref.evaluate(route, 0.5).orientation)

    def test_degenerate_horizontal_aim_reports_no_rotation(self):
        # axis "y" zeroes x/z; a straight-up lookahead target gives no yaw.
        route = ref.Route(points=(_point((0, 0, 0)), _point((0, 2, 0))), orient="y")
        self.assertIsNone(ref.evaluate(route, 0.5).orientation.rotation)

    def test_evaluate_rejects_unusable_times(self):
        route = ref.Route(points=LINE)
        for time in (-0.5, math.nan, math.inf):
            with self.assertRaises(ref.RouteNotPlayable, msg=str(time)):
                ref.evaluate(route, time)


class FixtureTests(unittest.TestCase):
    def test_sample_times_reach_the_boundaries(self):
        self.assertIn(6.5, ref.sample_times("line-no-loop"))
        self.assertNotIn(6.5, ref.sample_times("ease-spring"))

    def test_main_writes_a_parsable_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "route-reference.json"
            ref.main(["--out", str(out)])
            fixture = json.loads(out.read_text())
            self.assertEqual(len(fixture["routes"]), 32 + 9)
            for name, route in fixture["routes"].items():
                for stamp, sample in route["samples"].items():
                    self.assertEqual(len(sample["position"]), 3, f"{name}@{stamp}")
                    self.assertIsInstance(sample["segmentIndex"], int)
                    orientation = sample["orientation"]
                    if name.startswith("orient-"):
                        self.assertEqual(len(orientation["lookTarget"]), 3, f"{name}@{stamp}")
                        if orientation["rotation"] is not None:
                            self.assertEqual(len(orientation["rotation"]), 4)
                    else:
                        self.assertIsNone(orientation, f"{name}@{stamp}")


if __name__ == "__main__":
    unittest.main()
