using System;
using BepInEx.Configuration;
using BepInEx.Logging;

// Only Unity's audio endpoint and the component constructor are hosted here.
// ConfigFile/ConfigEntry/TomlTypeConverter execute from the installed BepInEx DLL.
namespace UnityEngine {
    public static class AudioListener { public static float volume = 1; }
}
namespace BepInEx {
    public class BaseUnityPlugin {
        public ConfigFile Config { get; set; }
        public ManualLogSource Logger { get; } = new ManualLogSource("MuteOracle");
    }
}
