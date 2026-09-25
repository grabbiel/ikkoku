using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using BepInEx;
using BepInEx.Configuration;
using UnityEngine;

class Program {
    static void Main(string[] args) {
        var input = JsonDocument.Parse(File.ReadAllText(args[0])).RootElement;
        var output = Path.GetDirectoryName(Path.GetFullPath(args[1]));
        typeof(Paths).GetProperty("BepInExConfigPath").SetValue(null, Path.Combine(output, "host-only-core.cfg"));
        var configs = new List<object>();
        foreach (var c in input.GetProperty("configurations").EnumerateArray()) {
            string name = c.GetProperty("name").GetString();
            string file = Path.Combine(output, name + ".cfg");
            File.WriteAllBytes(file, Convert.FromBase64String(c.GetProperty("data").GetString()));
            bool? value = null; string error = null;
            try {
                var config = new ConfigFile(file, false) { SaveOnConfigSet = false };
                value = config.Bind<bool>("Config", "Mute In Background", false).Value;
            } catch (Exception e) { error = e.GetType().Name; }
            configs.Add(new { name, value, error });
        }
        var traces = new List<object>();
        int caseIndex = 0;
        foreach (var c in input.GetProperty("cases").EnumerateArray()) {
            MuteInBackground.OriginalVolume = null;
            AudioListener.volume = c.GetProperty("volume").GetSingle();
            var plugin = new MuteInBackground { Config = new ConfigFile(Path.Combine(output, "empty-" + caseIndex++ + ".cfg"), false) { SaveOnConfigSet = false } };
            plugin.Awake();
            var states = new List<object>();
            void Capture() => states.Add(new { enabled = MuteInBackground.ConfigMuteInBackground.Value, volume = AudioListener.volume, original = MuteInBackground.OriginalVolume });
            Capture();
            foreach (var step in c.GetProperty("steps").EnumerateArray()) {
                if (step.TryGetProperty("enabled", out var enabled)) MuteInBackground.ConfigMuteInBackground.Value = enabled.GetBoolean();
                if (step.TryGetProperty("volume", out var volume)) AudioListener.volume = volume.GetSingle();
                if (step.TryGetProperty("focus", out var focus)) plugin.OnApplicationFocus(focus.GetBoolean());
                Capture();
            }
            traces.Add(new { name = c.GetProperty("name").GetString(), states });
        }
        File.WriteAllText(args[1], JsonSerializer.Serialize(new { configurations = configs, cases = traces }, new JsonSerializerOptions { WriteIndented = true }));
    }
}
