// Isolated validation plug-in: captures only explicitly configured material blits.
// It never reads cards, captures the desktop, or writes user save/plugin folders.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Globalization;
using System.Text;
using BepInEx;
using UnityEngine;

[BepInPlugin("org.ikkoku.validation.shaderprobe", "Ikkoku shader probe", "1.0.0")]
public sealed class OriginalShaderProbe : BaseUnityPlugin
{
    [Serializable] public class Input { public string property, file, wrap, bundle, asset; public int width, height; public bool linear; }
    [Serializable] public class Vector { public string property; public float[] values; }
    [Serializable] public class Scalar { public string property; public float value; }
    [Serializable] public class Recipe { public string name, material; public int width, height; public Input[] textures; public Vector[] vectors; public Scalar[] scalars; }
    [Serializable] public class Config { public string bundle; public Recipe[] recipes; }
    [Serializable] public class Result { public string name, material, shader, file; public bool supported; public double cpuMilliseconds; public int width, height; }
    [Serializable] public class Report { public string unity, device, graphicsAPI, colorSpace, error; public long residentBytes; public Result[] results; }
    private string folder;
    private IEnumerator Start()
    {
        folder = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        yield return null;
        var report = new Report();
        report.unity = Application.unityVersion; report.device = SystemInfo.graphicsDeviceName;
        report.graphicsAPI = SystemInfo.graphicsDeviceVersion; report.colorSpace = QualitySettings.activeColorSpace.ToString();
        try { Execute(report); } catch (Exception e) { report.error = e.ToString(); }
        report.residentBytes = Process.GetCurrentProcess().WorkingSet64;
        File.WriteAllText(Path.Combine(folder, "report.json"), EncodeReport(report));
        Application.Quit();
    }
    private static string Quote(string value) {
        if (value == null) return "null";
        var text = new StringBuilder("\"");
        foreach (char c in value) {
            if (c == '\\' || c == '\"') text.Append('\\').Append(c);
            else if (c < 32) text.Append("\\u").Append(((int)c).ToString("x4"));
            else text.Append(c);
        }
        return text.Append('\"').ToString();
    }
    private static string EncodeReport(Report r) {
        var rows = new List<string>();
        foreach (var item in r.results ?? new Result[0]) rows.Add("{\"name\":"+Quote(item.name)+",\"material\":"+Quote(item.material)+",\"shader\":"+Quote(item.shader)+",\"file\":"+Quote(item.file)+",\"supported\":"+(item.supported ? "true" : "false")+",\"width\":"+item.width+",\"height\":"+item.height+",\"cpuMilliseconds\":"+item.cpuMilliseconds.ToString("R",CultureInfo.InvariantCulture)+"}");
        return "{\"unity\":"+Quote(r.unity)+",\"device\":"+Quote(r.device)+",\"graphicsAPI\":"+Quote(r.graphicsAPI)+",\"colorSpace\":"+Quote(r.colorSpace)+",\"error\":"+Quote(r.error)+",\"residentBytes\":"+r.residentBytes+",\"results\":["+String.Join(",",rows.ToArray())+"]}";
    }
    private void Execute(Report report)
    {
        var config = OriginalShaderProbeInputs.Create();
        if (config == null || config.recipes == null) throw new Exception("Probe configuration recipes are missing");
        var bundle = AssetBundle.LoadFromFile(config.bundle);
        if (bundle == null) throw new Exception("Configured material bundle failed to load");
        var results = new List<Result>();
        var bundles = new Dictionary<string,AssetBundle>(); bundles[config.bundle] = bundle;
        foreach (var recipe in config.recipes)
        {
            if (recipe.width < 1 || recipe.height < 1 || recipe.width > 2048 || recipe.height > 2048) throw new Exception("Output dimensions exceeded probe limit");
            var original = bundle.LoadAsset<Material>(recipe.material);
            if (original == null) throw new Exception("Material not found: " + recipe.material);
            if (original.shader == null) throw new Exception("Configured source shader is unavailable");
            var material = new Material(original);
            var textures = new List<Texture2D>();
            Texture main = null;
            foreach (var input in recipe.textures)
            {
                if (!String.IsNullOrEmpty(input.bundle)) {
                    AssetBundle source;
                    if (!bundles.TryGetValue(input.bundle, out source)) {
                        source = AssetBundle.LoadFromFile(input.bundle);
                        if (source == null) throw new Exception("Input bundle failed: " + input.bundle);
                        bundles[input.bundle] = source;
                    }
                    var originalTexture = source.LoadAsset<Texture2D>(input.asset);
                    if (originalTexture == null) {
                        var embedded = original.GetTexture(input.property) as Texture2D;
                        if (embedded != null && embedded.name == input.asset) originalTexture = embedded;
                    }
                    if (originalTexture == null) throw new Exception("Input asset failed: " + input.asset);
                    material.SetTexture(input.property,originalTexture);
                    if (input.property == "_MainTex") main = originalTexture;
                    continue;
                }
                var bytes = File.ReadAllBytes(Path.Combine(folder, input.file));
                if (bytes.Length != input.width * input.height * 4) throw new Exception("RGBA dimensions differ");
                var upright = new byte[bytes.Length];
                for (int row = 0; row < input.height; ++row) Buffer.BlockCopy(bytes, row * input.width * 4, upright, (input.height - row - 1) * input.width * 4, input.width * 4);
                var texture = new Texture2D(input.width, input.height, TextureFormat.RGBA32, false, input.linear);
                texture.LoadRawTextureData(upright); texture.Apply(false, false);
                texture.filterMode = FilterMode.Bilinear; texture.wrapMode = input.wrap == "repeat" ? TextureWrapMode.Repeat : TextureWrapMode.Clamp;
                material.SetTexture(input.property, texture); textures.Add(texture);
                if (input.property == "_MainTex") main = texture;
            }
            foreach (var vector in recipe.vectors ?? new Vector[0]) material.SetVector(vector.property, new Vector4(vector.values[0], vector.values[1], vector.values[2], vector.values[3]));
            foreach (var scalar in recipe.scalars ?? new Scalar[0]) material.SetFloat(scalar.property, scalar.value);
            var target = new RenderTexture(recipe.width, recipe.height, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Default);
            target.Create();
            var previous = RenderTexture.active; var previousSRGB = GL.sRGBWrite;
            GL.sRGBWrite = true; RenderTexture.active = target; GL.Clear(false, true, Color.clear); RenderTexture.active = null;
            var timer = Stopwatch.StartNew();
            Graphics.Blit(main, target, material, 0);
            RenderTexture.active = target;
            var readback = new Texture2D(recipe.width, recipe.height, TextureFormat.RGBA32, false, true);
            readback.ReadPixels(new Rect(0, 0, recipe.width, recipe.height), 0, 0); readback.Apply(false, false);
            timer.Stop();
            string file = recipe.name + ".png";
            File.WriteAllBytes(Path.Combine(folder, file), readback.EncodeToPNG());
            results.Add(new Result { name=recipe.name, material=recipe.material, shader=material.shader.name, supported=material.shader.isSupported, file=file, width=recipe.width, height=recipe.height, cpuMilliseconds=timer.Elapsed.TotalMilliseconds });
            report.results = results.ToArray();
            RenderTexture.active = previous; GL.sRGBWrite = previousSRGB;
            Destroy(readback); target.Release(); Destroy(target); Destroy(material);
            foreach (var texture in textures) Destroy(texture);
        }
        report.results = results.ToArray(); bundle.Unload(false);
    }
}
