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

    def test_main_fails_on_a_missing_log_and_passes_a_good_one(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "fit.txt")
            self.assertEqual(validator.main(["x", path]), 1)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(GOOD + "\n")
            self.assertEqual(validator.main(["x", path, "--selection", "963", "--tab", "Clothes"]), 0)


if __name__ == "__main__":
    unittest.main()
