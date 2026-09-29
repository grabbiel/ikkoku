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


class SteppingTests(unittest.TestCase):
    """Per-frame stepping (OCIRoute Play + StudioTween TweenUpdate/Complete).

    Every route here uses speed 2 on straight legs so the padded PathLength
    gives exact 3 s segments at 1 s deltas: percentage after k advances is
    k/3 and positions are hand-computable on the linear padded spline.
    """

    CORNER = (_point((0, 0, 0)), _point((2, 0, 0)), _point((2, 2, 0)))

    def assertPositions(self, frames, expected):
        self.assertEqual(len(frames), len(expected))
        for frame, position in zip(frames, expected):
            for axis in range(3):
                self.assertAlmostEqual(frame.position[axis], position[axis], places=12)

    def test_two_segment_line_hands_match_the_tween_update_order(self):
        # apply-at-current-percentage-first means the written position lags
        # runningTime by one frame, and the boundary frame drops its
        # overshoot (frames 3 and 4 both sit on the corner point).
        frames = ref.simulate_frames(self.CORNER, False, "none", [1.0] * 8)
        self.assertPositions(frames,
                             [(0.0, 0.0, 0.0), (2 / 3, 0.0, 0.0), (4 / 3, 0.0, 0.0),
                              (2.0, 0.0, 0.0), (2.0, 0.0, 0.0),
                              (2.0, 2 / 3, 0.0), (2.0, 4 / 3, 0.0), (2.0, 2.0, 0.0)])
        # onComplete fires on the frame that applies percentage 1 with no
        # queued segment: active flips off that frame and holds off after.
        self.assertEqual([f.active for f in frames], [True] * 7 + [False])

    def test_record_before_update_shifts_every_write_by_one_frame(self):
        deltas = [1.0] * 8
        after = ref.simulate_frames(self.CORNER, False, "none", deltas, record_after_update=True)
        before = ref.simulate_frames(self.CORNER, False, "none", deltas, record_after_update=False)
        # Play's own percentage-0 application is the first observed write.
        self.assertEqual(before[0].position, (0.0, 0.0, 0.0))
        self.assertEqual(before[1].position, after[0].position)
        for index in range(1, len(before)):
            self.assertEqual(before[index].position, after[index - 1].position)
        # The finish write (and its active=False) is observed one frame late.
        self.assertEqual([f.active for f in before], [True] * 8)

    def test_loop_restarts_the_queue_at_percentage_zero_in_the_same_frame(self):
        # Looping two-point route: segment 0 out (3 s) and segment 1 back to
        # point 0 (3 s), so with 1 s deltas percentage reaches 1 on frame 7;
        # that frame applies percentage 1 and then segment 0 at percentage 0
        # in the SAME frame, dropping the overshoot.
        route = (_point((0, 0, 0)), _point((2, 0, 0)))
        frames = ref.simulate_frames(route, True, "none", [1.0] * 10)
        self.assertEqual(len(frames), 10)
        expected_x = [0.0, 2 / 3, 4 / 3, 2.0, 2.0, 4 / 3, 2 / 3, 0.0, 0.0, 2 / 3]
        for frame, expected in zip(frames, expected_x):
            self.assertAlmostEqual(frame.position[0], expected, places=12)
        self.assertTrue(all(f.active for f in frames))

    def test_completion_holds_the_last_aim_not_point_zero_rotation(self):
        # East leg then south leg, orient "y": the aim faces the lookahead
        # target, so after the south leg finishes the yaw must stay -90 deg
        # (quaternion (0,0,1,0) up to sign), never back to point 0's aim.
        route = (_point((0, 0, 0)), _point((2, 0, 0)), _point((2, 0, -2)))
        frames = ref.simulate_frames(route, False, "y", [1.0] * 10)
        finished = frames[7:]
        self.assertFalse(any(f.active for f in finished))
        for frame in finished:
            self.assertEqual(frame.position, (2.0, 0.0, -2.0))
            self.assertIsNotNone(frame.aim)
            w, x, y, z = frame.aim.rotation
            self.assertAlmostEqual(abs(y), 1.0, places=9)
            for component in (w, x, z):
                self.assertAlmostEqual(component, 0.0, places=9)

    def test_stepping_validates_its_frame_deltas(self):
        for delta in (-1.0, math.nan, math.inf):
            with self.assertRaises(ref.RouteNotPlayable, msg=str(delta)):
                ref.simulate_frames(self.CORNER, False, "none", [1.0, delta])

    def test_stepping_rejects_unplayable_routes(self):
        with self.assertRaises(ref.RouteNotPlayable):
            ref.simulate_frames((_point((0, 0, 0)),), True, "none", [1.0])


class LookUpdateRotationTests(unittest.TestCase):
    """LookUpdate smoothing (ST-T11h): Mathf.DeltaAngle / SmoothDampAngle,
    Unity's Z-X-Y euler store, and the one-row aim and delta lag
    ``simulate_frames`` reproduces from the capture."""

    L_ROUTE = (_point((0, 0, 0)), _point((2, 0, 0)), _point((2, 0, -2)))

    def test_delta_angle_wraps_to_the_shortest_signed_turn(self):
        # Mathf.DeltaAngle result is (-180, 180], so +180 and -180 targets
        # both read as a half turn in the positive direction.
        self.assertEqual(ref.delta_angle(0.0, 180.0), 180.0)
        self.assertEqual(ref.delta_angle(0.0, -180.0), 180.0)
        self.assertEqual(ref.delta_angle(179.0, -179.0), 2.0)
        self.assertEqual(ref.delta_angle(10.0, 350.0), -20.0)
        self.assertEqual(ref.delta_angle(-170.0, 170.0), -20.0)
        self.assertEqual(ref.delta_angle(45.0, 45.0), 0.0)

    def test_smooth_damp_angle_one_step_from_rest(self):
        # velocity 0: out = target + (change + temp) * exp, closed-form at
        # current 0, target 90, smoothTime 0.05 (omega 40), deltaTime 1/60.
        den = 1.0 + 40 / 60 + 0.48 * (40 / 60) ** 2 + 0.235 * (40 / 60) ** 3
        value, velocity = ref.smooth_damp_angle(0.0, 90.0, 0.05, 1 / 60)
        self.assertAlmostEqual(value, 90.0 - 150.0 / den, places=12)
        self.assertAlmostEqual(velocity, 2400.0 / den, places=9)
        # Wrapped across the half turn: the damp chases current+DeltaAngle,
        # so 10 -> -170 damps toward +190, not -170.
        wrapped, wrapped_velocity = ref.smooth_damp_angle(10.0, -170.0, 0.05, 1 / 60)
        self.assertGreater(wrapped, 0.0)  # moving the positive way
        self.assertAlmostEqual(wrapped, 190.0 - 300.0 / den, places=12)
        self.assertAlmostEqual(wrapped_velocity, 4800.0 / den, places=9)

    def test_smooth_damp_angle_edge_branches(self):
        # nonPositive smoothTime teleports; the overshoot guard lands exactly
        # on the wrapped target when a carried velocity would jump past it.
        self.assertEqual(ref.smooth_damp_angle(0.0, 90.0, 0.0, 0.1), (90.0, 0.0))
        self.assertEqual(ref.smooth_damp_angle(0.0, 90.0, 0.05, 1 / 60, 10000.0)[0], 90.0)
        self.assertEqual(ref.smooth_damp_angle(0.0, -90.0, 0.05, 1 / 60, -10000.0)[0], -90.0)
        # LookUpdate calls this with a FRESH zero velocity every frame — the
        # returned velocity is discarded, so consecutive steps are independent.

    def test_euler_round_trip_matches_the_zx_y_store(self):
        # Quaternion.Euler applies Z-X-Y; to_euler inverts it and keeps
        # pitch in [-90, 90], yaw/roll in (-180, 180].
        for euler in ((0.0, 90.0, 0.0), (30.0, -75.0, 120.0), (-45.0, 170.0, -160.0)):
            quaternion = ref.from_euler(euler)
            for axis in range(3):
                self.assertAlmostEqual(ref.to_euler(quaternion)[axis], euler[axis], places=9)
        yaw_quaternion = ref.from_euler((0.0, 90.0, 0.0))
        self.assertAlmostEqual(yaw_quaternion[0], 2 ** 0.5 / 2, places=9)       # w
        self.assertAlmostEqual(yaw_quaternion[2], 2 ** 0.5 / 2, places=9)       # y
        for component in (yaw_quaternion[1], yaw_quaternion[3]):                # x, z
            self.assertAlmostEqual(component, 0.0, places=9)

    def test_look_update_smooths_per_axis_and_keeps_x_z_for_axis_y(self):
        # One damp per axis from the current euler toward the aim.
        smoothed = ref.look_update((30.0, 45.0, 60.0), (10.0, 100.0, 20.0), 0.05, 0.5, "xy")
        for axis, expected in enumerate((10.200668896321073, 99.44816053511707,
                                         20.40133779264215)):
            self.assertAlmostEqual(smoothed[axis], expected, places=9)
        # axis "y": e3 keeps the current e0.x/e0.z and takes only e3.y, and
        # the eulerAngles write-back canonicalizes the result.
        y_smoothed = ref.look_update((30.0, 45.0, 60.0), (10.0, 100.0, 20.0), 0.05, 0.5, "y")
        self.assertAlmostEqual(y_smoothed[0], 30.0, places=9)
        self.assertAlmostEqual(y_smoothed[2], 60.0, places=9)
        self.assertAlmostEqual(y_smoothed[1], 99.44816053511708, places=9)

    def test_look_update_smooth_time_fallback_chain(self):
        self.assertAlmostEqual(ref.look_update_smooth_time(0.4, None), 0.02, places=12)
        self.assertAlmostEqual(ref.look_update_smooth_time(None, 4.0), 0.03, places=12)
        self.assertEqual(ref.look_update_smooth_time(None, None), ref.DEFAULT_UPDATE_TIME)
        self.assertEqual(ref.look_update_smooth_time(), ref.DEFAULT_UPDATE_TIME)

    def test_first_row_damps_with_the_play_frames_delta(self):
        # Row 0 is Play's own LateUpdate: one damp toward Play's looktarget
        # (here yaw 90) with initial_delta 0.2 — not with row 0's own delta.
        frames = ref.simulate_frames(self.L_ROUTE, False, "y", [1.0] * 8,
                                     initial_rotation=(1.0, 0.0, 0.0, 0.0),
                                     initial_delta=0.2)
        self.assertAlmostEqual(frames[0].rotation[1], 84.93876530867281, places=9)
        wrong_delta = ref.smooth_damp_angle(0.0, 90.0, 0.05, 1.0)[0]
        self.assertGreater(abs(frames[0].rotation[1] - wrong_delta), 4.0)
        self.assertAlmostEqual(frames[0].rotation[0], 0.0, places=9)

    def test_rotation_lags_the_written_aim_and_delta_by_one_row(self):
        deltas = [0.1, 2.9, 0.1, 0.1, 1.0, 0.5, 0.25, 0.25]
        frames = ref.simulate_frames(self.L_ROUTE, False, "y", deltas)
        # Row 2's rotation damps row 1's euler toward ROW 1's written aim
        # (segment 0's looktarget, yaw 90) with row 1's delta (2.9).
        previous_yaw = frames[1].rotation[1]
        previous_aim_yaw = ref.to_euler(frames[1].aim.rotation)[1]
        self.assertAlmostEqual(previous_aim_yaw, 89.99999999999999, places=9)
        expected = ref.smooth_damp_angle(previous_yaw, previous_aim_yaw, 0.05, 2.9)[0]
        self.assertAlmostEqual(frames[2].rotation[1], expected, places=9)
        # The two wrong alignments are far away: this row's own aim (yaw 180)
        # and this row's own delta (0.1).
        wrong_aim = ref.smooth_damp_angle(previous_yaw,
                                          ref.to_euler(frames[2].aim.rotation)[1],
                                          0.05, 2.9)[0]
        wrong_delta = ref.smooth_damp_angle(previous_yaw, previous_aim_yaw, 0.05, 0.1)[0]
        self.assertGreater(abs(frames[2].rotation[1] - wrong_aim), 80.0)
        self.assertGreater(abs(frames[2].rotation[1] - wrong_delta), 2.0)

    def test_rotation_freezes_after_the_non_loop_completion(self):
        # Fine deltas keep the aim away from its limit, so the completion
        # frame's LateUpdate smoothing is visible as the LAST euler change:
        # the tween stopped, so every later row freezes at that euler.
        frames = ref.simulate_frames(self.L_ROUTE, False, "y", [0.01] * 610,
                                     initial_rotation=(1.0, 0.0, 0.0, 0.0),
                                     initial_delta=0.01)
        completion = next(index for index, frame in enumerate(frames) if not frame.active)
        self.assertGreater(completion, 2)
        self.assertNotEqual(frames[completion].rotation, frames[completion - 1].rotation)
        for frame in frames[completion + 1:]:
            self.assertEqual(frame.rotation, frames[completion].rotation)
        # A degenerate looktarget leaves the previous aim in place; the
        # frozen rotation is not necessarily the aim's own euler.

    def test_unoriented_route_never_touches_the_rotation(self):
        seed = (0.5, 0.5, 0.5, 0.5)  # unit (w, x, y, z)
        expected = ref.to_euler(seed)
        frames = ref.simulate_frames(self.L_ROUTE, False, "none", [0.25] * 12,
                                     initial_rotation=seed, initial_delta=0.25)
        for frame in frames:
            self.assertEqual(frame.rotation, expected)

    def test_initial_rotation_requires_its_play_delta(self):
        with self.assertRaises(ref.RouteNotPlayable):
            ref.simulate_frames(self.L_ROUTE, False, "y", [1.0] * 3,
                                initial_rotation=(1.0, 0.0, 0.0, 0.0))

    def test_smooth_time_override_slows_the_chain(self):
        # Only the fallback 0.05 s smoothTime matches the capture; a slower
        # override must visibly lag the default row-0 damp.
        default = ref.simulate_frames(self.L_ROUTE, False, "y", [0.1] * 8,
                                      initial_rotation=(1.0, 0.0, 0.0, 0.0),
                                      initial_delta=0.1)
        slower = ref.simulate_frames(self.L_ROUTE, False, "y", [0.1] * 8,
                                     initial_rotation=(1.0, 0.0, 0.0, 0.0),
                                     initial_delta=0.1,
                                     smooth_time=lambda duration: 0.5)
        self.assertLess(slower[1].rotation[1], default[1].rotation[1])


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
