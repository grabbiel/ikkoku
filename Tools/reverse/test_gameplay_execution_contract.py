import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from analysis.gameplay_execution_contract import adv_fixtures, convert_fixed, evaluate_fixed, extract_tables, selected_source


class GameplayExecutionContractTests(unittest.TestCase):
    def row(self, **overrides):
        return {"Asset":"0", "Bundle":"fixture", "isVisible":False, "Cycle":["朝"], "Map":"room", "Week":[],
                "LayerName":"", "Coordinate":"", "AfterDay":0, **overrides}

    def context(self, **overrides):
        return dict(isTaked=False, eventAfterDay=0, completedEvents=[], week=0, period=1,
                    mapNumbers={"room":5}, waitPoints=[], lessons=["room","other"], **overrides)

    def test_first_uncompleted_failure_blocks_later_matching_event(self):
        rows=[self.row(AfterDay=2), self.row(Asset="1")]
        self.assertIsNone(evaluate_fixed(rows,self.context()))
        context=self.context();context["completedEvents"]=[0]
        self.assertEqual(evaluate_fixed(rows,context)["assetID"],1)

    def test_taken_heroine_short_circuits_before_invalid_asset(self):
        context=self.context();context["isTaked"]=True
        self.assertIsNone(evaluate_fixed([self.row(Asset="invalid")],context))

    def test_weekday_marker_has_priority_over_explicit_holiday(self):
        context=self.context();context["week"]=6
        self.assertIsNone(evaluate_fixed([self.row(Week=["平日","休日"])],context))

    def test_empty_week_filter_allows_holiday(self):
        context=self.context();context["week"]=6
        self.assertEqual(evaluate_fixed([self.row()],context)["assetID"],0)

    def test_first_point_and_first_matching_layer_win(self):
        context=self.context();context.update(period=8,waitPoints=[dict(id="first",mapNo=5,layers=["x","event","event"]),dict(id="second",mapNo=5,layers=["event"])])
        result=evaluate_fixed([self.row(Cycle=["部活時間"],LayerName="event")],context)
        self.assertEqual((result["waitPointID"],result["layerIndex"]),("first",1))

    def test_lesson_map_is_substring_not_exact_match(self):
        context=self.context();context.update(period=4,lessons=["roo","other"])
        self.assertIsNotNone(evaluate_fixed([self.row(Cycle=["授業1"])],context))
        context["period"]=6
        self.assertIsNone(evaluate_fixed([self.row(Cycle=["授業2"])],context))

    def test_unresolved_map_retains_original_minus_one(self):
        result=evaluate_fixed([self.row(Map="unknown")],self.context())
        self.assertEqual(result["mapNo"],-1)

    def test_converter_preserves_event_identity_and_ordered_filters(self):
        converted=convert_fixed(self.row(Asset="001",Cycle=["朝","起床"],Week=["休日","平日"],isVisible=1))
        self.assertEqual(converted["asset"],"001")
        self.assertEqual(converted["cycles"],["朝","起床"])
        self.assertEqual(converted["weeks"],["休日","平日"])
        self.assertTrue(converted["isVisible"])

    def test_class_schedule_whitespace_defaults_are_source_classroom(self):
        raw={"m_Name":"2-1","param":[dict(Week="Monday",Lesson1=" \t",Lesson2="room")]}
        with patch("analysis.gameplay_execution_contract.mono_records",return_value=[(10,raw)]), patch("analysis.gameplay_execution_contract.digest",return_value="a"*64):
            table,_=extract_tables(Path("fixture"),[])
        self.assertEqual(table["classSchedules"][0]["days"][0]["lessons"],["教室","room"])

    def test_selected_type_override_supersedes_broken_primary(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/"project").mkdir();(root/"fallback.cs").write_text("public class Sample {}")
            (root/"manifest.json").write_text(json.dumps(dict(typeOverrides=[dict(type="Sample",file="fallback.cs")])))
            (root/"index.json").write_text(json.dumps(dict(assemblies=[dict(directory=directory,selectedProject="project",sourcePaths=["Koikatu_Data/Managed/Assembly-CSharp.dll"])])))
            path,text=selected_source(root/"index.json","Sample")
            self.assertEqual(path,root/"fallback.cs")
            self.assertIn("Sample",text)

    def test_decompiler_error_stub_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/"project").mkdir();(root/"project/Sample.cs").write_text("Error decompiling")
            (root/"manifest.json").write_text("{}")
            (root/"index.json").write_text(json.dumps(dict(assemblies=[dict(directory=directory,selectedProject="project",sourcePaths=["Koikatu_Data/Managed/Assembly-CSharp.dll"])])))
            with self.assertRaisesRegex(ValueError,"stub"):selected_source(root/"index.json","Sample")

    def test_hand_derived_adv_cases_include_blocking_and_fault_boundaries(self):
        cases={case["name"]:case for case in adv_fixtures()["cases"]}
        self.assertEqual(len(cases),12)
        loop=cases["loop-branch-wait"]["expected"]
        self.assertEqual([state["status"] for state in loop],["waiting","waiting","closed"])
        self.assertEqual(loop[0]["variables"]["counter"]["value"],"3")
        self.assertEqual(cases["unsupported-command"]["expected"][0]["faultPC"],0)
        self.assertEqual(cases["calc-left-to-right"]["expected"][0]["variables"]["result"]["value"],"20")


if __name__=="__main__":unittest.main()
