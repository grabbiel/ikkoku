// Observes the exact installed plugin inside an owned isolated Unity player.
// The plugin is invoked by reflection; its code is neither copied nor replaced.
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Globalization;
using System.Text;
using BepInEx;
using UnityEngine;

[BepInPlugin("org.ikkoku.validation.hideui", "Ikkoku Studio UI probe", "1.0.0")]
public sealed class OriginalHideStudioUIProbe : BaseUnityPlugin
{
    [Serializable] public sealed class Row {
        public string key, name, existence;
        public int instanceID, canvasInstanceID;
        public bool activeSelf, activeInHierarchy, hasCanvas, canvasEnabled;
    }
    [Serializable] public sealed class Phase {
        public string name, invocationError, capturedEnumerationError;
        public bool handlerVisible;
        public int[] capturedCanvasIDs;
        public List<Row> targets = new List<Row>();
    }
    [Serializable] public sealed class Report {
        public int schemaVersion = 1;
        public string kind = "original-unity-hide-studio-ui", unityVersion, productName, assemblyPath, error;
        public bool originalStartupHandlerObserved;
        public List<Phase> phases = new List<Phase>();
    }
    sealed class Target {
        public string key, name;
        public int instanceID, canvasInstanceID;
        public GameObject gameObject;
        public Canvas canvas;
        public bool activeSelf, canvasEnabled;
        public Target(string label, GameObject go) {
            key = label; gameObject = go; name = go.name; instanceID = go.GetInstanceID();
            canvas = go.GetComponent<Canvas>(); canvasInstanceID = canvas != null ? canvas.GetInstanceID() : 0; activeSelf = go.activeSelf;
            canvasEnabled = canvas != null && canvas.enabled;
        }
        public Row Read() {
            // ReferenceEquals distinguishes a destroyed Unity object from a
            // reference that was never captured. Cache identity before Destroy.
            bool missing = ReferenceEquals(gameObject, null), destroyed = !missing && gameObject == null;
            return new Row { key = key, name = !missing && !destroyed ? gameObject.name : name, instanceID = instanceID, canvasInstanceID = canvasInstanceID,
                existence = missing ? "missing" : destroyed ? "destroyed" : "alive",
                activeSelf = !missing && !destroyed && gameObject.activeSelf,
                activeInHierarchy = !missing && !destroyed && gameObject.activeInHierarchy,
                hasCanvas = canvas != null, canvasEnabled = canvas != null && canvas.enabled };
        }
        public void Restore() {
            if (gameObject != null) gameObject.SetActive(activeSelf);
            if (canvas != null) canvas.enabled = canvasEnabled;
        }
    }

    readonly Report report = new Report();
    readonly List<Target> targets = new List<Target>(), originalTargets = new List<Target>();
    readonly List<GameObject> owned = new List<GameObject>();
    Type coreType, handlerType;
    FieldInfo currentHandler, visible, canvasList;
    MethodInfo toggle, initialize;

    IEnumerator Start() {
        report.unityVersion = Application.unityVersion; report.productName = Application.productName;
        IEnumerator run = Run();
        while (true) {
            bool more;
            try { more = run.MoveNext(); }
            catch (Exception error) { report.error = Describe(error); break; }
            if (!more) break;
            yield return run.Current;
        }
        // Restore only observed state in this owned player, and destroy only
        // owned synthetic targets. The installed game directory is untouched.
        foreach (Target target in originalTargets) target.Restore();
        foreach (GameObject gameObject in owned) if (gameObject != null) Destroy(gameObject);
        yield return null;
        string directory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        File.WriteAllText(Path.Combine(directory, "hide-ui.json"), SerializeReport());
        File.WriteAllText(Path.Combine(directory, "complete.txt"), "complete");
        Application.Quit();
    }

    IEnumerator Run() {
        float deadline = Time.realtimeSinceStartup + 90f;
        object handler = null;
        while (Time.realtimeSinceStartup < deadline) {
            Assembly source = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetType("HideAllUI.HideStudioUI", false) != null);
            if (source != null) {
                report.assemblyPath = source.Location;
                coreType = source.GetType("HideAllUI.HideAllUICore", true);
                handlerType = source.GetType("HideAllUI.HideStudioUI", true);
                currentHandler = coreType.GetField("currentUIHandler", BindingFlags.Static | BindingFlags.NonPublic);
                handler = currentHandler.GetValue(null);
                if (handler != null && handler.GetType() == handlerType) break;
            }
            yield return null;
        }
        if (handler == null || handler.GetType() != handlerType) throw new InvalidOperationException("Original Studio.Init handler was not observed.");
        report.originalStartupHandlerObserved = true;
        visible = handlerType.GetField("visible", BindingFlags.Instance | BindingFlags.NonPublic);
        canvasList = handlerType.GetField("canvasList", BindingFlags.Instance | BindingFlags.NonPublic);
        toggle = handlerType.GetMethod("ToggleUI", BindingFlags.Instance | BindingFlags.Public);
        initialize = handlerType.GetMethod("StudioInit", BindingFlags.Static | BindingFlags.NonPublic);
        foreach (Canvas canvas in UnityEngine.Object.FindObjectsOfType<Canvas>()) {
            var target = new Target("original-canvas-" + canvas.GetInstanceID(), canvas.gameObject);
            originalTargets.Add(target); targets.Add(target);
        }
        Record("original-startup", null);

        // All synthetic names match known source roles. Duplicate game canvas
        // names are intentional: the plugin captures all matching instances.
        var disabled = CreateCanvas("captured-disabled-canvas", "Canvas Pattern", true, false);
        CreateCanvas("inactive-at-capture", "Canvas Guide Input", false, true);
        var rename = CreateCanvas("captured-renamed-later", "IKKOKU-unmatched", true, true);
        if (GameObject.Find("KKPECanvas(Clone)") != null || GameObject.Find("QuickAccessBoxCanvas(Clone)") != null)
            throw new InvalidOperationException("Optional plugin fixture path is already occupied.");
        var optional = CreateCanvas("dynamic-plugin-before", "KKPECanvas(Clone)", true, false);
        GameObject manager = GameObject.Find("BepInEx_Manager");
        if (manager == null || GameObject.Find("BepInEx_Manager/MaterialEditorCanvas") != null)
            throw new InvalidOperationException("Optional manager fixture path is unavailable.");
        var inactivePlugin = CreateCanvas("dynamic-plugin-inactive", "MaterialEditorCanvas", false, true);
        inactivePlugin.gameObject.transform.SetParent(manager.transform, false);
        GameObject gizmo = null;
        if (Camera.main == null) throw new InvalidOperationException("Original Studio main camera was not observed.");
        if (Camera.main != null) {
            Transform existing = Camera.main.transform.Find("CustomManipulatorGizmo");
            if (existing != null) {
                var target = new Target("original-gizmo", existing.gameObject);
                originalTargets.Add(target); targets.Add(target);
            } else {
                gizmo = new GameObject("CustomManipulatorGizmo"); owned.Add(gizmo);
                gizmo.transform.SetParent(Camera.main.transform, false);
                targets.Add(new Target("owned-gizmo", gizmo));
            }
        }
        // This explicitly invokes the original Studio.Init postfix. The first
        // phase observed its real startup delivery; this is controlled callback
        // reinitialization, not a claim of a second whole-scene load.
        initialize.Invoke(null, null);
        Record("controlled-init", null);
        Record("toggle-1", InvokeToggle());
        CreateCanvas("late-game", "Canvas Object List", true, true);
        CreateCanvas("dynamic-plugin-late", "QuickAccessBoxCanvas(Clone)", true, false);
        rename.gameObject.name = "CvsColor";
        Record("late-targets", null);
        Record("toggle-2", InvokeToggle());
        inactivePlugin.gameObject.SetActive(true);
        Record("toggle-3", InvokeToggle());

        // Deferred name filtering precedes the source truthiness filter. Retain
        // and report any real MissingReferenceException, do not assume filtering
        // makes a destroyed captured Canvas safe or replace it with a stub result.
        Destroy(disabled.gameObject);
        Destroy(optional.gameObject);
        if (gizmo != null) Destroy(gizmo);
        yield return null; yield return null;
        Record("destroyed-targets", null);
        Record("toggle-after-destroy", InvokeToggle());
        // A new handler drops stale references and captures the late game
        // target only if it is active. Initialization itself must not force an
        // existing hidden GameObject or disabled Canvas to become visible.
        initialize.Invoke(null, null);
        Record("controlled-reinit", null);
        Record("toggle-after-reinit", InvokeToggle());
    }

    Target CreateCanvas(string key, string name, bool active, bool enabled) {
        var go = new GameObject(name); owned.Add(go);
        var canvas = go.AddComponent<Canvas>(); canvas.enabled = enabled; go.SetActive(active);
        var target = new Target(key, go); targets.Add(target); return target;
    }
    string InvokeToggle() {
        try { toggle.Invoke(currentHandler.GetValue(null), null); return null; }
        catch (Exception error) { return Describe(error); }
    }
    void Record(string name, string invocationError) {
        object handler = currentHandler.GetValue(null);
        var phase = new Phase { name = name, invocationError = invocationError, handlerVisible = (bool)visible.GetValue(handler) };
        // Enumerating the deferred sequence after destruction may itself throw.
        // Preserve that observation separately from the invocation's exception.
        try {
            var ids = new List<int>();
            foreach (Canvas canvas in (IEnumerable)canvasList.GetValue(handler)) if (canvas != null) ids.Add(canvas.GetInstanceID());
            phase.capturedCanvasIDs = ids.OrderBy(id => id).ToArray();
        } catch (Exception error) { phase.capturedCanvasIDs = null; phase.capturedEnumerationError = Describe(error); }
        foreach (Target target in targets) phase.targets.Add(target.Read());
        report.phases.Add(phase);
    }
    string SerializeReport() {
        var phases = new List<object>();
        foreach (Phase phase in report.phases) {
            var rows = new List<object>();
            foreach (Row row in phase.targets) rows.Add(new Dictionary<string, object> {
                {"key", row.key}, {"name", row.name}, {"existence", row.existence},
                {"instanceID", row.instanceID}, {"canvasInstanceID", row.canvasInstanceID},
                {"activeSelf", row.activeSelf}, {"activeInHierarchy", row.activeInHierarchy},
                {"hasCanvas", row.hasCanvas}, {"canvasEnabled", row.canvasEnabled} });
            phases.Add(new Dictionary<string, object> {
                {"name", phase.name}, {"invocationError", phase.invocationError},
                {"capturedEnumerationError", phase.capturedEnumerationError},
                {"handlerVisible", phase.handlerVisible}, {"capturedCanvasIDs", phase.capturedCanvasIDs}, {"targets", rows} });
        }
        return JSON(new Dictionary<string, object> {
            {"schemaVersion", report.schemaVersion}, {"kind", report.kind}, {"unityVersion", report.unityVersion},
            {"productName", report.productName}, {"assemblyPath", report.assemblyPath}, {"error", report.error},
            {"originalStartupHandlerObserved", report.originalStartupHandlerObserved}, {"phases", phases} });
    }
    // Unity 5.6 JsonUtility omitted the nested observation list in the first
    // retained probe. Explicit primitive/dictionary serialization preserves it.
    static string JSON(object value) {
        if (value == null) return "null";
        if (value is string) {
            var text = new StringBuilder(); text.Append('"');
            foreach (char c in (string)value) {
                if (c == '"' || c == '\\') text.Append('\\').Append(c);
                else if (c < 32) text.Append("\\u").Append(((int)c).ToString("x4"));
                else text.Append(c);
            }
            return text.Append('"').ToString();
        }
        if (value is bool) return (bool)value ? "true" : "false";
        if (value is int) return ((int)value).ToString(CultureInfo.InvariantCulture);
        var dictionary = value as IDictionary;
        if (dictionary != null) {
            var items = new List<string>();
            foreach (DictionaryEntry entry in dictionary) items.Add(JSON((string)entry.Key) + ":" + JSON(entry.Value));
            return "{" + String.Join(",", items.ToArray()) + "}";
        }
        var sequence = value as IEnumerable;
        if (sequence != null) {
            var items = new List<string>(); foreach (object item in sequence) items.Add(JSON(item));
            return "[" + String.Join(",", items.ToArray()) + "]";
        }
        throw new InvalidOperationException("Unsupported probe JSON type " + value.GetType().FullName);
    }
    static string Describe(Exception error) {
        while (error is TargetInvocationException && error.InnerException != null) error = error.InnerException;
        return error.GetType().FullName + ": " + error.Message;
    }
}
