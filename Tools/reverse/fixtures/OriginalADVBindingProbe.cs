// G-T02: SaveData.Heroine ADV bindings in a private main-game player (Koikatu.exe).
// Each case builds `new SaveData.Heroine(false)` on an inactive TextScenario, seeds it with
// Heroine.SetADVParam(scenario), runs a program through the original CommandList.Add in the
// TextScenario main loop's order, and dumps Vars, Replaces, the heroine's public fields and
// CommandPacks. Programs: uploaded cases (cases.tsv), the first N commands of named scenario
// assets, and every scenarioParameterDic program of VAR/Calc/Clamp/HeroineParam commands
// (directly and through one ParameterFile line). Reads no save or card; writes only its folder.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Security.Cryptography;
using System.Text;
using ADV;
using BepInEx;
using UnityEngine;

[BepInPlugin("org.ikkoku.validation.advbinding", "Ikkoku ADV binding probe", "1.0.0")]
public sealed class OriginalADVBindingProbe : BaseUnityPlugin
{
    const BindingFlags Hidden = BindingFlags.Instance | BindingFlags.NonPublic;
    static readonly int[] Modelled = { (int)Command.VAR, (int)Command.Calc, (int)Command.Clamp, (int)Command.HeroineParam };
    readonly List<string> rows = new List<string>();

    static string Text(object o)
    {
        if (o == null) return "<null>";
        string s = o is float ? ((float)o).ToString("R", CultureInfo.InvariantCulture) : Convert.ToString(o, CultureInfo.InvariantCulture);
        return s.Replace("\\", "\\\\").Replace("\t", "\\t").Replace("\n", "\\n").Replace("\r", "\\r");
    }
    void Row(params object[] f) { rows.Add(string.Join("\t", f.Select(Text).ToArray())); }

    IEnumerator Start()
    {
        string folder = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), status = "timeout";
        for (int i = 0; i < 9000 && !Ready(); i++) yield return null;
        if (Ready()) { try { Run(folder); status = "ok"; } catch (Exception e) { status = e.ToString(); } }
        File.WriteAllLines(Path.Combine(folder, "adv-binding.tsv"), rows.ToArray());
        File.WriteAllText(Path.Combine(folder, "status.txt"), status);
        // Manager.Scene.OnApplicationQuit cancels the first quit outside Init/Logo and opens its Exit dialog.
        if (Singleton<Manager.Scene>.IsInstance()) Singleton<Manager.Scene>.Instance.isGameEndCheck = false;
        Application.Quit();
    }

    static bool Ready()
    {
        try
        {
            return Singleton<Manager.Game>.IsInstance() && Singleton<Manager.Voice>.IsInstance()
                && Singleton<Manager.Game>.Instance.scenarioParameterDic != null && Singleton<Manager.Game>.Instance.saveData != null
                && Singleton<Manager.Game>.Instance.Player != null && Singleton<Manager.Voice>.Instance.voiceInfoList != null;
        }
        catch (Exception) { return false; }
    }

    // SHA-256 of "id\x1fmulti\x1farg\x1earg..." per command, joined by \x1d (the driver hashes the same).
    static string Digest(IEnumerable<ScenarioData.Param> program)
    {
        string text = string.Join("\x1d", program.Select(p => ((int)p.Command).ToString(CultureInfo.InvariantCulture) + "\x1f" + (p.Multi ? "1" : "0") + "\x1f" + string.Join("\x1e", p.Args ?? new string[0])).ToArray());
        using (var sha = SHA256.Create()) return string.Concat(sha.ComputeHash(Encoding.UTF8.GetBytes(text)).Select(b => b.ToString("x2")).ToArray());
    }

    // cases.tsv commands: id|multi|arg|arg...
    static ScenarioData.Param Parse(string text)
    {
        string[] f = text.Split('|');
        return new ScenarioData.Param(f[1] == "1", (Command)int.Parse(f[0], CultureInfo.InvariantCulture), f.Skip(2).ToArray());
    }

    // TextScenario's main loop: pack = commandPacks[currentLine++]; CommandList.Add(pack, CurrentLine).
    void Case(string label, IEnumerable<ScenarioData.Param> program)
    {
        var heroine = new SaveData.Heroine(false);
        var go = new GameObject("IkkokuADVBindingProbe");
        go.SetActive(false);
        var scenario = go.AddComponent<TextScenario>();
        var chara = (ADV.CharaData)FormatterServices.GetUninitializedObject(typeof(ADV.CharaData));
        typeof(ADV.CharaData).GetProperty("data").GetSetMethod(true).Invoke(chara, new object[] { heroine });
        scenario.currentChara = chara;
        var packs = new List<ScenarioData.Param>(program);
        Row(label, "program", packs.Count, Digest(packs));
        FieldInfo lineField = typeof(TextScenario).GetField("currentLine", Hidden);
        typeof(TextScenario).GetField("commandPacks", Hidden).SetValue(scenario, packs);
        lineField.SetValue(scenario, 0);
        try
        {
            heroine.SetADVParam(scenario);
            var list = new CommandList(scenario);
            for (int guard = 0; (int)lineField.GetValue(scenario) < packs.Count && guard < 10000; guard++)
            {
                int line = (int)lineField.GetValue(scenario);
                lineField.SetValue(scenario, line + 1);
                list.Add(packs[line], scenario.CurrentLine);
            }
        }
        catch (Exception e) { Row(label, "exception", e.GetType().FullName, scenario.CurrentLine); }
        foreach (var pair in scenario.Vars.OrderBy(p => p.Key, StringComparer.Ordinal))
            Row(label, "var", pair.Key, pair.Value.o == null ? "<null>" : pair.Value.o.GetType().FullName, pair.Value.o);
        foreach (var pair in scenario.Replaces.OrderBy(p => p.Key, StringComparer.Ordinal)) Row(label, "replace", pair.Key, pair.Value);
        for (Type type = heroine.GetType(); type != typeof(object); type = type.BaseType)
            foreach (FieldInfo field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.DeclaredOnly))
                if (field.FieldType == typeof(int) || field.FieldType == typeof(bool) || field.FieldType == typeof(string))
                    Row(label, "field", field.Name, field.GetValue(heroine));
        Row(label, "commands", string.Join(",", scenario.CommandPacks.Select(p => ((int)p.Command).ToString(CultureInfo.InvariantCulture)).ToArray()));
        Destroy(go);
    }

    void Run(string folder)
    {
        var game = Singleton<Manager.Game>.Instance;
        Row("meta", "unity", Application.unityVersion);
        Row("meta", "callDefaultID", SaveData.callDefaultID);
        Row("meta", "playerCallID", game.Player.callID);
        Row("meta", "voiceNumbers", Singleton<Manager.Voice>.Instance.voiceInfoDic.Count);
        Row("meta", "parameterPrograms", game.scenarioParameterDic.Count);
        foreach (var data in new SaveData.Heroine(false).param.datas) Row("heroineKey", data.key, data.command);
        foreach (var data in game.Player.param.datas) Row("playerKey", data.key, data.command);
        var keys = game.scenarioParameterDic.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        foreach (var key in keys) Row("library", key, game.scenarioParameterDic[key].Count, Digest(game.scenarioParameterDic[key]));
        string path = Path.Combine(folder, "cases.tsv");
        foreach (string line in File.Exists(path) ? File.ReadAllLines(path) : new string[0])
        {
            string[] f = line.Split('\t');
            if (f[0] == "program") Case(f[1], f.Skip(2).Where(s => s.Length > 0).Select(Parse));
            else if (f[0] == "asset")
            {
                var data = AssetBundleManager.LoadAsset(f[2], f[3], typeof(ScenarioData)).GetAsset<ScenarioData>();
                var prefix = data.list.Take(int.Parse(f[4], CultureInfo.InvariantCulture)).ToList();
                AssetBundleManager.UnloadAssetBundle(f[2], false);
                Case(f[1], prefix);
            }
        }
        foreach (var key in keys.Where(k => game.scenarioParameterDic[k].All(p => Modelled.Contains((int)p.Command))))
        {
            Case("library:" + key, game.scenarioParameterDic[key]);
            Case("library-pf:" + key, new[] { new ScenarioData.Param(false, Command.ParameterFile, key) });
        }
    }
}
