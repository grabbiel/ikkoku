"""Synthetic tests for adv_host_requests.py (no original scenario data).

Expected values are derived by hand from the recovered handlers and Mono's
mscorlib parsers; all strings are synthetic.
"""
import unittest

import adv_host_requests as host

CURRENT = host.INT_MAX


def cmd(cid, *args, multi=False):
    return dict(hash=0, version=0, multi=multi, id=cid, args=list(args))


def request(command):
    outcome = host.evaluate(command)
    assert outcome[0] == "request", outcome
    return outcome[3]


class MonoParseTests(unittest.TestCase):
    def test_int32_fast_path(self):
        self.assertEqual([host.int32(t) for t in ["42", " \t-7 ", "+3", "2147483647", "-2147483648", "12\0x", "　5"]],
                         [42, -7, 3, 2147483647, -2147483648, 12, 5])
        for text in ["", " ", "+", "-", "+-1", "1 2", "2147483648", "-2147483649", "mobNo", "１", "1.5", "0x10", "2147483647\0x"]:
            with self.assertRaises(host.SourceException, msg=text):
                host.int32(text)
        with self.assertRaises(host.Unmodelled):
            host.int32("​5")

    def test_single_is_invariant_and_conservative(self):
        self.assertEqual(host.single(".8"), host.float32(0.8))
        self.assertEqual([host.single(t) for t in ["1", "-.5", "5.", " 2.5 ", "1E+2"]], [1.0, -0.5, 5.0, 2.5, 100.0])
        self.assertEqual(host.single("3.4028234e38"), host.float32(3.4028234663852886e38))
        for text in ["", "  ", "abc", "1.5x", "1..5", "1e39", "3.4028235e38", "1 2", "--1"]:
            with self.assertRaises(host.SourceException, msg=text):
                host.single(text)
        for text in ["1,000", "NaN", "Infinity", "-Infinity", ".", "1e+5.5", "１.5", "-1e39", "+"]:
            with self.assertRaises(host.Unmodelled, msg=text):
                host.single(text)

    def test_boolean_and_culture_comparison(self):
        self.assertEqual([host.boolean(t) for t in ["True", "FALSE", " true\n"]], [True, False, True])
        with self.assertRaises(host.SourceException):
            host.boolean("yes")
        with self.assertRaises(host.Unmodelled):
            host.boolean("Tr ue")
        self.assertIs(host.culture_equals("In", "in", True), True)
        self.assertIs(host.culture_equals("In", "in", False), False)
        self.assertIsNone(host.culture_equals("StaffRoom01", "StaffRoom_01", True))
        self.assertIsNone(host.culture_equals("通常", "None", True))
        self.assertIs(host.culture_equals("通常", "通常", True), True)
        self.assertEqual(host.check("chara", host.NULL_TARGETS), 2)
        self.assertEqual(host.check("other", host.NULL_TARGETS), -1)

    def test_initialize_overrides_defaults_and_appends(self):
        self.assertEqual(host.initialize(["", "3"], ["a", "b", "c"]), ["a", "3", "c"])
        self.assertEqual(host.initialize(["1", "2", "3", "4"], ["a"]), ["1", "2", "3", "4"])
        self.assertEqual(host.initialize(["x"], None), ["x"])


class HandlerTests(unittest.TestCase):
    def test_look_commands(self):
        self.assertEqual(request(cmd(128)), dict(chara=CURRENT, pattern=0, rate=1.0))
        self.assertEqual(request(cmd(128, "", "1", ".5")), dict(chara=CURRENT, pattern=1, rate=0.5))
        self.assertEqual(request(cmd(125)), dict(chara=CURRENT, pattern=0))
        with self.assertRaises(host.Fault) as caught:
            host.evaluate(cmd(125, "mobNo", "1"))
        self.assertEqual((caught.exception.kind, caught.exception.reason), ("invalid-argument", "argument parse throws in Chara.LookEyes.Do No:"))
        replaced = host.evaluate(cmd(125, "mobNo", "1"), lambda t: {"mobNo": "4"}.get(t, t))
        self.assertEqual(replaced[3], dict(chara=4, pattern=1))

    def test_bgm_selectors(self):
        self.assertEqual(request(cmd(88, "Date", "", "0", "", "True")), dict(number=13, enumName="Date", delay=0.0, isAsync=True))
        self.assertEqual(request(cmd(88, "lively", "", "0", "1", "False")),
                         dict(number=24, enumName="Lively", delay=0.0, fade=1.0, isAsync=False))
        self.assertEqual(request(cmd(88, "3")), dict(number=3, delay=0.0, isAsync=True))
        self.assertEqual(request(cmd(88, "bgm/b.unity3d", "b", "0", ".8", "True")),
                         dict(bundle="bgm/b.unity3d", asset="b", delay=0.0, fade=host.float32(0.8), isAsync=True))
        self.assertEqual(request(cmd(88, "Config", "", "0", "", "True", "", "", "", ".5"))["volume"], 0.5)
        for args, reason in ((("Date", "", "soon"), "in Sound.BGM.Play.Do Delay:"), (("Date", "", "0", "", "maybe"), "isAsync"),
                             (("Staff Room",), "Enum<BGM>.FindIndex")):
            with self.assertRaises(host.Fault) as caught:
                host.evaluate(cmd(88, *args))
            self.assertIn(reason, caught.exception.reason)

    def test_expression_convert(self):
        self.assertEqual(request(cmd(112, "0", "smile")), [dict(chara=0, lookupKey="smile")])
        self.assertEqual(request(cmd(112, "0", "smile", "1", "angry")), [dict(chara=0, lookupKey="smile"), dict(chara=1, lookupKey="angry")])
        self.assertEqual(request(cmd(112, "", "smile")), [dict(chara=CURRENT, lookupKey="smile")])
        self.assertEqual(request(cmd(112, "0")), [])
        explicit = request(cmd(112, "0", "3", "1,False", "2", "1", "1", "0.5", "0", "0.3", "True", "0", "False"))
        self.assertTrue(host.same(explicit, [dict(chara=0, lookupKey="3", expression=dict(
            eyebrow=dict(pattern=3, blend=True), eyes=dict(pattern=1, blend=False), mouth=dict(pattern=2, blend=True), eyebrowOpen=1,
            eyesOpen=1, mouthOpen=0.5, eyesLook=0, cheekRedRate=0.3, highlight=True, tearsLevel=0, blink=False))]))
        self.assertEqual(request(cmd(112, "0", "", "2", "1", "", "", "0.5")),
                         [dict(chara=0, expression=dict(eyes=dict(pattern=2, blend=True), mouth=dict(pattern=1, blend=True), mouthOpen=0.5))])
        self.assertEqual(request(cmd(112, "0", "", "2", "x")), [dict(chara=0, expression=dict(eyes=dict(pattern=2, blend=True)))])
        with self.assertRaises(host.Fault) as caught:
            host.evaluate(cmd(112, "first", "smile"))
        self.assertIn("Base.Expression.Convert No:", caught.exception.reason)

    def test_motion_and_voice_swallow_like_source(self):
        self.assertEqual(request(cmd(106, "0", "Stand")), [dict(chara=0, state="Stand")])
        self.assertEqual(request(cmd(106, "mobNo", "Stand")), [dict(chara=0), dict(chara=0)])
        blank = dict.fromkeys(host._MOTION_STRINGS, "")
        self.assertEqual(request(cmd(106, "1", "Sit", *[""] * 8, "0,2")), [dict(chara=1, state="Sit", layers=[0, 2], **blank)])
        self.assertEqual(request(cmd(106, "1", "Sit", *[""] * 8, "0,x")), [dict(chara=1, state="Sit", **blank)])
        self.assertEqual(host.evaluate(cmd(17, "0", "bank", "v", "12", "1.2"))[2],
                         [dict(chara=0, bundle="bank", asset="v", personality=12, pitch=host.float32(1.2))])
        # A failed Personality ends that Data after cnt passed it; the loop then
        # reads the Pitch argument as the next No (which also fails).
        self.assertEqual(host.evaluate(cmd(17, "0", "", "v", "x", "1.2"))[2], [dict(chara=0, bundle="", asset="v"), dict(chara=0)])
        self.assertEqual(host.evaluate(cmd(17, "mobNo", "", "v"))[2], [dict(chara=0)])
        self.assertEqual(host.evaluate(cmd(19, "0", "smile")), ("binding", "expressions", [dict(chara=0, lookupKey="smile")]))

    def test_map_null_fade_and_regulate(self):
        self.assertEqual(request(cmd(169, "school", "FALSE")), dict(mapName="school", fade="None"))
        self.assertEqual(request(cmd(169, "1", "3")), dict(mapNumber=1, fade="InOut"))
        self.assertEqual(request(cmd(169, "1", "out")), dict(mapNumber=1, fade="Out"))
        self.assertEqual(request(cmd(169)), dict(mapNumber=0, fade="InOut"))
        with self.assertRaises(host.Fault) as caught:
            host.evaluate(cmd(169, "1", "None", multi=True))
        self.assertEqual(caught.exception.kind, "mapchange-multi")
        self.assertEqual(request(cmd(35, "0", "デフォルト")), dict(version=0))
        self.assertEqual(request(cmd(35, "1", "room")), dict(version=1, map="room"))
        self.assertEqual(request(cmd(37, "seat", "chara")), dict(name="seat", target="Chara"))
        self.assertEqual(request(cmd(37, "seat", "other")), dict(name="seat"))
        self.assertEqual(request(cmd(44, "Out", "", "", "", "none")), dict(fadeIn=False))
        self.assertEqual(request(cmd(44, "in", "2")), dict(fadeIn=True, time=2.0))
        with self.assertRaises(host.Fault):
            host.evaluate(cmd(44, "in", "", "1,0,0"))
        self.assertEqual(host.evaluate(cmd(45, "FALSE")), ("state", "sceneFadeRegulate", False))
        self.assertEqual(host.evaluate(cmd(16, "n", "t")), ("request", "text", "next", dict(name="n", text="t")))
        self.assertEqual(host.evaluate(cmd(44, "in"))[2], "acknowledge")

    def test_value_dependence(self):
        program = [cmd(1, "System.Int32", "who", "1", multi=True), cmd(128, "who", "1", "1"), cmd(128, "0", "1", "1")]
        assigned = host.assigned_names(program)
        self.assertEqual(assigned, {"who"})
        self.assertTrue(host.touches(program[1], assigned))
        self.assertFalse(host.touches(program[2], assigned))


class PredictionTests(unittest.TestCase):
    def test_batches_and_bindings(self):
        program = [cmd(44, "out"), cmd(128, "0", "1", "1", multi=True), cmd(17, "0", "", "v", multi=True), cmd(16, "n", "t"),
                   cmd(19, "0", "smile", multi=True), cmd(16, "", "u"), cmd(169, "1", "None"), cmd(22), cmd(88, "Date")]
        requests = host.predict_requests(program, len(program))
        self.assertEqual([(r["pc"], r["batch"], r["blocking"], r["command"]["kind"]) for r in requests],
                         [(0, 1, "acknowledge", "sceneFade"), (1, 2, "none", "charaLookNeck"), (3, 2, "next", "text"),
                          (5, 3, "next", "text"), (6, 4, "acknowledge", "mapChange")])
        self.assertEqual(requests[2]["command"]["arguments"], dict(name="n", text="t", voices=[[dict(chara=0, bundle="", asset="v")]]))
        self.assertEqual(requests[3]["command"]["arguments"], dict(name="", text="u", expressions=[[dict(chara=0, lookupKey="smile")]]))
        self.assertEqual(len(host.predict_requests(program, 3)), 2)

    def test_same_rounds_numbers_to_float32(self):
        self.assertTrue(host.same(dict(a=0.8, b=[1]), dict(a=host.float32(0.8), b=[1.0])))
        self.assertFalse(host.same(dict(a=True), dict(a=1)))
        self.assertFalse(host.same([1, 2], [1]))
        self.assertFalse(host.same(dict(a=1), dict(a=1, b=None)))


if __name__ == "__main__":
    unittest.main()
