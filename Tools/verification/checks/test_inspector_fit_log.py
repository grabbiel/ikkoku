"""Unit tests for the inspector fit log validator (#333).

Stdlib only. Run from the repository root with:
    python3 -m unittest discover -s Tools/verification/checks -p 'test_*.py'
"""
import importlib.util
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "ikkoku_inspector_fit_log", os.path.join(_HERE, "inspector_fit_log.py"))
validator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validator)

# Lines in the app's format, shortened: a readiness poll, a good capture and #333's bad capture, where the
# inspector's scroll view (1235+379) runs past the 1600 pt window and is not found at the trailing edge.
POLL = "   0.60 poll window 1600x998 selection 963 tab Clothes clip 333 document 362 scrollers legacy views DocumentView@0+362"
GOOD = ("   1.10 captured window 1600x998 selection 963 tab Clothes clip 333 document 333 scrollers legacy views "
        "DocumentView@0+333 | content 1600 | 3 scroll views | fits true: inspector scroll view: clip 333 pt, "
        "document 333 pt, legacy scrollers, 29 elements, 0 past the visible width (333 pt)")
# #363: the layout probe's toolbar part (before " | fits"), with the pose-mode picker at its intrinsic width, and
# the compressed layout a fixed frame narrower than the control gave on a fresh build.
LAYOUT = (" | layout toolbar gizmo x 296.0+75.0 y 907.0+20.0 host 296.0+75.0 intrinsic 75.0 distribution 2 size 1 "
          "font 11.0 widths 0.0/0.0/0.0 segments 295.0+77.0; pose x 473.0+165.0 y 907.0+20.0 host 473.0+165.0 "
          "intrinsic 165.0 distribution 2 size 1 font 11.0 widths 0.0/0.0/0.0 segments 472.0+167.0; scroll clip 962.0 "
          "content 1020.0 at 0.0 scroller shown | inspector top 906.0 offset 0.0 document height 1200.0")
GOOD_POSE = GOOD.replace(" | fits true:", LAYOUT + " | fits true:")
COMPRESSED = GOOD_POSE.replace("pose x 473.0+165.0", "pose x 484.0+142.0")
# #425: the shown toolbar variant and the width it was offered (layout probe), and the ideal widths, full/compact,
# the app logs after the capture: at 1600 pt Object and IK fit in full, FK only in compact.
VARIANT = "; variant full width 925.0 available 962.0"
IDEAL = " | toolbar ideal none 735.0/525.0 object 925.0/715.0 fk 1053.0/843.0 ik 925.0/715.0 state object"
GOOD_TOOLBAR = GOOD_POSE.replace(" | inspector top", VARIANT + " | inspector top").replace(" | fits true:", IDEAL + " | fits true:")
BAD = ("   1.20 captured window 1600x998 selection 963 tab Clothes no inspector scroll view | content 1600 | "
       "3 scroll views | #2 document 362: HostingScrollView@1235+379 | fits false: no inspector scroll view")


class ValidateLogTests(unittest.TestCase):
    def test_a_good_capture_passes(self):
        passed, reasons, detail = validator.validate_log("\n".join([POLL, GOOD]), "963", "Clothes")
        self.assertTrue(passed, reasons)
        self.assertTrue(detail.startswith("true: inspector scroll view"))

    def test_the_bad_capture_fails(self):
        passed, reasons, _ = validator.validate_log("\n".join([POLL, BAD]), "963", "Clothes")
        self.assertFalse(passed)
        self.assertIn("no inspector scroll view at the capture", reasons)

    def test_a_wider_document_fails_even_if_the_fit_says_true(self):
        line = GOOD.replace("document 333 scrollers", "document 362 scrollers")
        passed, reasons, _ = validator.validate_log(line)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["document 362 pt is wider than clip 333 pt"])

    def test_an_element_past_the_width_fails(self):
        line = GOOD.replace("fits true:", "fits false:").replace("0 past the visible width (333 pt)",
                                                                  "1 past the visible width (333 pt): AXStaticText 'Top' x -14...16")
        passed, reasons, _ = validator.validate_log(line)
        self.assertFalse(passed)
        self.assertIn("AXStaticText 'Top'", reasons[0])

    def test_one_captured_line_is_required(self):
        self.assertFalse(validator.validate_log(POLL)[0])
        self.assertFalse(validator.validate_log("\n".join([GOOD, GOOD]))[0])

    def test_the_selection_and_tab_must_match(self):
        passed, reasons, _ = validator.validate_log(GOOD, "0", "Pose")
        self.assertFalse(passed)
        self.assertEqual(len(reasons), 2)

    def test_the_pose_picker_at_its_intrinsic_width_passes(self):
        passed, reasons, _ = validator.validate_log(GOOD_POSE, "963", "Clothes", pose_picker=True)
        self.assertTrue(passed, reasons)

    def test_a_compressed_pose_picker_fails(self):
        passed, reasons, _ = validator.validate_log(COMPRESSED, "963", "Clothes", pose_picker=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["the pose-mode picker is 142.0 pt wide, not its intrinsic 165.0 pt"])

    def test_a_missing_pose_picker_fails_only_when_required(self):
        self.assertTrue(validator.validate_log(GOOD, "963", "Clothes")[0])
        passed, reasons, _ = validator.validate_log(GOOD, "963", "Clothes", pose_picker=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["no pose-mode picker in the toolbar at the capture"])

    def test_the_pose_picker_is_read_before_the_fit_detail(self):
        # A "pose x" after " | fits" (the accessibility detail) does not count.
        line = GOOD + "; pose x 473.0+165.0 y 907.0+20.0 host 473.0+165.0 intrinsic 165.0"
        self.assertFalse(validator.validate_log(line, pose_picker=True)[0])

    def test_a_fitting_toolbar_in_the_first_variant_that_fits_passes(self):
        passed, reasons, _ = validator.validate_log(GOOD_TOOLBAR, "963", "Clothes", pose_picker=True, toolbar_fits=True)
        self.assertTrue(passed, reasons)
        fk = GOOD_TOOLBAR.replace("variant full width 925.0", "variant compact width 843.0").replace("state object", "state fk")
        self.assertTrue(validator.validate_log(fk, toolbar_fits=True)[0])

    def test_a_mode_that_fits_in_neither_variant_fails(self):
        line = GOOD_TOOLBAR.replace("fk 1053.0/843.0", "fk 1156.0/990.0")
        passed, reasons, _ = validator.validate_log(line, toolbar_fits=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["in fk mode the toolbar does not fit: full 1156 pt, compact 990 pt, available 962 pt"])

    def test_the_wrong_variant_for_the_state_fails(self):
        # Compact shown where full fits, and the scroll fallback where compact fits.
        line = GOOD_TOOLBAR.replace("variant full width 925.0", "variant compact width 715.0")
        passed, reasons, _ = validator.validate_log(line, toolbar_fits=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["the toolbar shows compact, expected full for state object "
                                   "(full 925 pt, compact 715 pt, available 962 pt)"])
        scroll = GOOD_TOOLBAR.replace("variant full", "variant scroll").replace("state object", "state fk")
        self.assertFalse(validator.validate_log(scroll, toolbar_fits=True)[0])
        # A variant ViewThatFits kept in the window besides the shown one.
        both = GOOD_TOOLBAR.replace("available 962.0", "available 962.0 (both markers)")
        passed, reasons, _ = validator.validate_log(both, toolbar_fits=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["the window holds both the full and the compact toolbar"])

    def test_toolbar_fits_needs_the_logged_widths(self):
        self.assertTrue(validator.validate_log(GOOD_POSE, pose_picker=True)[0])
        passed, reasons, _ = validator.validate_log(GOOD_POSE, toolbar_fits=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["no toolbar variant or ideal widths in the fit log at the capture"])
        # Widths after " | fits" (the accessibility detail) do not count.
        self.assertFalse(validator.validate_log(GOOD_POSE + VARIANT + IDEAL, toolbar_fits=True)[0])

    def test_main_fails_on_a_missing_log_and_passes_a_good_one(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "fit.txt")
            self.assertEqual(validator.main(["x", path]), 1)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(GOOD + "\n")
            self.assertEqual(validator.main(["x", path, "--selection", "963", "--tab", "Clothes"]), 0)
            self.assertEqual(validator.main(["x", path, "--selection", "963", "--tab", "Clothes", "--pose-picker"]), 1)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(GOOD_POSE + "\n")
            self.assertEqual(validator.main(["x", path, "--selection", "963", "--tab", "Clothes", "--pose-picker"]), 0)
            self.assertEqual(validator.main(["x", path, "--pose-picker", "--toolbar-fits"]), 1)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(GOOD_TOOLBAR + "\n")
            self.assertEqual(validator.main(["x", path, "--selection", "963", "--tab", "Clothes", "--pose-picker",
                                             "--toolbar-fits"]), 0)


if __name__ == "__main__":
    unittest.main()
