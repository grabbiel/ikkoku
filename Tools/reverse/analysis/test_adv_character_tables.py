"""Synthetic tests for adv_character_tables.py (no original data; a hand-written SaveData shape)."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import adv_character_tables as tables

SAVEDATA = '''public class SaveData
{
\tpublic abstract class CharaData
\t{
\t\tpublic abstract class Params
\t\t{
\t\t\tpublic int ignored;
\t\t}

\t\tpublic int callID = -1;

\t\tpublic string callName = string.Empty;

\t\tpublic static readonly string[] Names = new string[4] { "Last", "First", "Full", "Nick" };

\t\tpublic NameType nameType = NameType.First;

\t\tpublic abstract int voiceNo { get; }

\t\tpublic bool isNickNameNormal => !SaveData.GetCallName(this).isSpecial;

\t\tpublic int callMyID
\t\t{
\t\t\tget
\t\t\t{
\t\t\t\treturn callID;
\t\t\t}
\t\t}

\t\tpublic float voicePitch => parameter.voicePitch;

\t\tpublic bool charFileInitialized { get; set; }

\t\tpublic void Method(int value)
\t\t{
\t\t}
\t}

\tpublic class Heroine : CharaData
\t{
\t\tpublic new class Params : CharaData.Params
\t\t{
\t\t\tpublic Params(Heroine heroine)
\t\t\t\t: base(heroine, "H_")
\t\t\t{
\t\t\t\tstring text = "H_" + Utils.String.GetPropertyName(() => heroine.HExperience);
\t\t\t\t_datas.AddRange(new List<Data>
\t\t\t\t{
\t\t\t\t\tnew Data(Data.Command.Replace, "H", () => string.Empty),
\t\t\t\t\tnew Data(Data.Command.Replace, "H" + CharaData.Names[3], () => heroine.nickname),
\t\t\t\t\tnew Data(Data.Command.String, text, () => heroine.HExperience.ToString()),
\t\t\t\t\tnew Data(Data.Command.Int, text + "Index", () => (int)heroine.HExperience)
\t\t\t\t});
\t\t\t}
\t\t}

\t\tpublic const string ParamHead = "H";

\t\tprivate int? cachedVoiceNo;

\t\tpublic int favor;

\t\tpublic bool isVirgin = true;

\t\tpublic float countKokanH;

\t\tpublic int talkTime = 4;

\t\tpublic bool[] isDresses { get; set; }

\t\tpublic bool isTeacher => fixCharaID >= -4;

\t\tpublic override int voiceNo
\t\t{
\t\t\tget
\t\t\t{
\t\t\t\treturn 0;
\t\t\t}
\t\t}

\t\tpublic Heroine(bool isRandomize)
\t\t{
\t\t}
\t}

\tpublic class Player : CharaData
\t{
\t\tpublic new class Params : CharaData.Params
\t\t{
\t\t\tpublic Params(Player player)
\t\t\t\t: base(player, "P_")
\t\t\t{
\t\t\t\t_datas.AddRange(new List<Data>
\t\t\t\t{
\t\t\t\t\tnew Data(Data.Command.Replace, "P", () => string.Empty),
\t\t\t\t\tnew Data(Data.Command.Replace, "P" + CharaData.Names[0], () => player.lastname)
\t\t\t\t});
\t\t\t}
\t\t}

\t\tpublic int intellect;

\t\tpublic uint playTime;

\t\tpublic override int voiceNo => 0;
\t}

\tpublic static void InitializeCall()
\t{
\t\tNickName.Param param = GetCallNameList(-1).Find((NickName.Param p) => p.Name == "Synthetic");
\t\tcallDefaultID = param.ID;
\t}
}
'''


def cmd(cid, *args, multi=False):
    return dict(hash=0, version=0, multi=multi, id=cid, args=list(args))


class SourceKeyTests(unittest.TestCase):
    def test_keys_follow_params_reflection_order_and_types(self):
        keys = tables.source_keys(SAVEDATA)
        heroine = [(r["key"], r["command"], r["writable"], r.get("default")) for r in keys["heroine"]]
        self.assertEqual(heroine, [
            ("H_favor", "Int", True, 0), ("H_isVirgin", "BOOL", True, True), ("H_talkTime", "Int", True, 4),  # Own fields.
            ("H_callID", "Int", True, -1), ("H_callName", "String", True, ""),  # Base fields (no float, enum or static).
            ("H_isTeacher", "BOOL", False, None), ("H_voiceNo", "Int", False, None),  # Own properties, the override once.
            ("H_isNickNameNormal", "BOOL", False, None), ("H_callMyID", "Int", False, None),
            ("H_charFileInitialized", "BOOL", False, None),
            ("H", "Replace", False, None), ("HNick", "Replace", False, None),  # Params rows.
            ("H_HExperience", "String", False, None), ("H_HExperienceIndex", "Int", False, None)])
        player = [r["key"] for r in keys["player"]]
        self.assertEqual(player, ["P_intellect", "P_callID", "P_callName", "P_voiceNo", "P_isNickNameNormal", "P_callMyID",
                                  "P_charFileInitialized", "P", "PLast"])

    def test_default_call_name_needs_the_modelled_form(self):
        self.assertEqual(tables.default_call_name(SAVEDATA), "Synthetic")
        with self.assertRaisesRegex(ValueError, "modelled form"):
            tables.default_call_name(SAVEDATA.replace("callDefaultID = param.ID", "callDefaultID = 0"))


class ModelTests(unittest.TestCase):
    def test_int32_parse_follows_number_styles_integer(self):
        for text, value in ((" 6 ", 6), ("-7", -7), ("+3", 3), ("- 4", -4), ("2147483647", 2**31 - 1), ("-2147483648", -2**31),
                            ("12\x00junk", 12)):
            self.assertEqual(tables.int32_parse(text), value, text)
        for text in ("", "+", "1 2", "2147483648", "6.0", "0x10", "True"):
            self.assertIsNone(tables.int32_parse(text), text)

    def test_library_effect_adds_clamps_and_writes(self):
        triple = [cmd(3, "H_intimacy", "1", "4", multi=True), cmd(4, "H_intimacy", "H_intimacy", "0", "100"),
                  cmd(165, "H_intimacy", "H_intimacy")]
        self.assertEqual(tables.library_effect(triple, {"H_intimacy": 0}), {"H_intimacy": 4})
        self.assertEqual(tables.library_effect(triple, {"H_intimacy": 98}), {"H_intimacy": 100})
        minus = [cmd(3, "H_intimacy", "2", "5", multi=True)] + triple[1:]
        self.assertEqual(tables.library_effect(minus, {"H_intimacy": 3}), {"H_intimacy": 0})
        self.assertEqual(tables.library_effect([cmd(165, "H_other", "1")], {"H_intimacy": 1}), {"H_intimacy": 1})
        with self.assertRaisesRegex(ValueError, "not modelled"):
            tables.library_effect([cmd(31, "x")], {"H_intimacy": 0})
        with self.assertRaisesRegex(ValueError, "conversion"):
            tables.library_effect([cmd(4, "v", "6.5", "0", "100"), cmd(165, "H_intimacy", "v")], {"H_intimacy": 0})


class ExtractTests(unittest.TestCase):
    def test_bundle_order_filters_and_last_name_wins(self):
        names = {"a.unity3d": [(2, dict(m_Name="c00", param=[dict(Name="A", ID=1, Category=2, Bundle="b"),
                                                               dict(Name="", ID=2, Category=2, Bundle="b"),
                                                               dict(Name="X", ID=-1, Category=0, Bundle="b")]))],
                 "sub/b.unity3d": [(1, dict(m_Name="c00", param=[dict(Name="B", ID=3, Category=0, Bundle="b")]))]}
        scenarios = {"20.unity3d": [(1, dict(m_Name="301", list=[dict(_hash=1, _version=0, _multi=1, _command=3, _args=["x", "1", "2"])]))],
                     "25.unity3d": [(1, dict(m_Name="301", list=[]))]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ("etcetra/list/nickname/a.unity3d", "etcetra/list/nickname/sub/b.unity3d",
                             "adv/scenario/common_param/20.unity3d", "adv/scenario/common_param/25.unity3d",
                             "adv/scenario/common_param/._25.unity3d"):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_bytes(b"x")
            def records(path, class_name):
                key = Path(path).relative_to(root).as_posix().split("/", 3)[-1]
                return (names if class_name == "NickName" else scenarios).get(key, [])
            with patch.object(tables, "mono_records", side_effect=records):
                found, files = tables.call_names(root)
                programs, library_files, duplicates = tables.library(root)
        self.assertEqual([e["name"] for e in found["c00"]], ["A", "B"])  # Empty names and ID -1 are dropped.
        self.assertEqual([f["path"] for f in files], ["etcetra/list/nickname/a.unity3d", "etcetra/list/nickname/sub/b.unity3d"])
        self.assertEqual((programs, duplicates, len(library_files)), ({"301": []}, 1, 2))  # 25 loads after 20.


if __name__ == "__main__":
    unittest.main()
