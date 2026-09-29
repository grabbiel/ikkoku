// Character-light capture: apply charaLight rot pairs through Studio's own CameraLightCtrl.Reflect under two camera poses.
// Records Camera.main placement, every Light under cameraLightCtrl and each light's transform chain up to Camera.main; no characters, routes or media.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using BepInEx;
using Manager;
using Studio;
using System.Reflection;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.lightprobe", "Ikkoku light probe", "1.0.0")]
public sealed class OriginalLightProbe:BaseUnityPlugin {
    const int SettledFrames=5,WarmFrames=2; string folder;
    IEnumerator Start() {
        folder=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"light");Directory.CreateDirectory(folder);
        string error=null;
        for(int i=0;i<1200;i++) { // Studio and its scene container are built during scene start-up.
            // Studio is both a namespace and a class, so the singleton type must be qualified from this global-namespace file.
            bool ready=Singleton<Studio.Studio>.IsInstance()&&Singleton<Scene>.IsInstance()&&Singleton<Scene>.Instance.commonSpace!=null&&Singleton<Studio.Studio>.Instance.sceneInfo!=null;
            if(ready)break;
            yield return null;
        }
        try{if(!Singleton<Studio.Studio>.IsInstance())throw new Exception("Studio singleton is not ready after startup wait");
            if(Singleton<Studio.Studio>.Instance.cameraLightCtrl==null)throw new Exception("Studio.cameraLightCtrl is missing");
            if(Singleton<Studio.Studio>.Instance.cameraCtrl==null)throw new Exception("Studio.cameraCtrl is missing");}
        catch(Exception e){error=e.ToString();} // A null field is a plain NullReferenceException at first use; check them explicitly so status.json names the member.
        if(error==null) {
            var step=Capture();
            for(;;){bool more=false;object current=null;try{more=step.MoveNext();if(more)current=step.Current;}catch(Exception e){error=e.ToString();}if(error!=null||!more)break;yield return current;}
        }
        File.WriteAllText(Path.Combine(folder,"status.json"),J(new Dictionary<string,object>{{"error",error},{"unity",Application.unityVersion},
            {"scope","charaLight color/intensity/rot/shadow applied through CameraLightCtrl.Reflect under two camera poses: Camera.main placement, all Lights under cameraLightCtrl and each light's chain up to Camera.main; no characters, routes or media"}}));
        Application.Quit();
    }
    IEnumerator Capture() {
        var studio=Singleton<Studio.Studio>.Instance;
        var light=studio.sceneInfo.charaLight; // The scene record CameraLightCtrl.Reflect() reads from.
        if(light==null)throw new Exception("Studio.sceneInfo.charaLight is missing");
        var rots=new float[][] {new float[]{0f,0f},new float[]{30f,-45f},new float[]{-20f,90f},new float[]{10f,180f}};
        var poses=new string[] {"default","tilt"};
        var records=new List<object>();
        // The camera rig damps toward its target, so the startup view is recorded only after it has been idle.
        for(int i=0;i<SettledFrames;i++)yield return null;
        foreach(var pose in poses) {
            if(pose=="tilt") {
                studio.cameraCtrl.cameraAngle=new Vector3(20f,135f,0f); // Public Euler property; the camera rig itself owns the transform.
                for(int i=0;i<WarmFrames;i++)yield return null;
            }
            foreach(var rot in rots) {
                light.color=new Color(0.9f,0.7f,0.5f);light.intensity=1.3f;light.rot=rot;light.shadow=false;
                studio.cameraLightCtrl.Reflect(); // Applies through the private nested LightCalc; its transRoot gets localRotation=Euler(rot[0],rot[1],0).
                for(int i=0;i<WarmFrames;i++)yield return null;
                records.Add(Record(pose,rot));
            }
        }
        File.WriteAllText(Path.Combine(folder,"light-trace.json"),J(new Dictionary<string,object>{{"schemaVersion",1},{"settledFrames",SettledFrames},
            {"warmFrames",WarmFrames},{"color",V(light.color)},{"intensity",1.3},{"shadow",false},{"records",records}}));
    }
    static Dictionary<string,object> Record(string pose,float[] rot) {
        if(Camera.main==null)throw new Exception("Camera.main is missing while recording pose "+pose+" rot ("+rot[0]+","+rot[1]+")");
        var ctrl=Singleton<Studio.Studio>.Instance.cameraLightCtrl;
        var cam=Camera.main.transform;
        var ctrlCamera=ctrl.GetComponent<Camera>(); // Null unless the ctrl itself sits on the rendering camera object.
        // CameraLightCtrl has no Light children: Reflect works through its private nested LightCalc, so reach the light by reflection.
        var lights=CollectLights(ctrl);
        if(lights.Count==0)lights=SceneLights(); // Reflect may keep the LightCalc only as a local; then the applied light is the one that just took the probe's colour.
        if(lights.Count==0)throw new Exception("No UnityEngine.Light member found on CameraLightCtrl or its LightCalc fields (missing member) for pose "+pose+" rot ("+rot[0]+","+rot[1]+")");
        var lightsJson=new List<object>();
        foreach(var l in lights)lightsJson.Add(LightEvidence(l,cam));
        return K("cameraPose",pose,"rot",new float[]{rot[0],rot[1]},
            "camera",K("name",cam.name,"position",V(cam.position),"rotation",Q(cam.rotation)),
            "cameraCtrl",K("name",Singleton<Studio.Studio>.Instance.cameraCtrl.name,"position",V(Singleton<Studio.Studio>.Instance.cameraCtrl.transform.position),"rotation",Q(Singleton<Studio.Studio>.Instance.cameraCtrl.transform.rotation)),
            "ctrlHasOwnCamera",ctrlCamera!=null&&ctrlCamera==Camera.main,
            "lights",lightsJson);
    }
    static List<Light> CollectLights(object ctrl) { // Light objects on the ctrl's own fields and on any LightCalc-typed field (directly, or as a list/array element).
        var found=new List<Light>();
        foreach(var f in ctrl.GetType().GetFields(BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic)) {
            object value=null;try{value=f.GetValue(ctrl);}catch{}
            foreach(var cand in Flatten(value))AddCalcLights(cand,found);
        }
        return found;
    }
    static IEnumerable<object> Flatten(object value) {
        var list=value as System.Collections.IEnumerable;
        if(list!=null&&!(value is string)) { var items=new List<object>();foreach(var x in list)items.Add(x);return items; }
        return new[]{value};
    }
    static void AddCalcLights(object calc,List<Light> found) { // Any object exposing UnityEngine.Light (and optional Transform transRoot) members counts; the calc object is stashed on its light for ChainOf.
        if(calc==null)return;
        var flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
        var lf=calc.GetType().GetField("light",flags);if(lf==null||lf.FieldType!=typeof(Light))return;
        var l=(Light)lf.GetValue(calc);if(l==null||found.Contains(l))return;
        var tf=calc.GetType().GetField("transRoot",flags);
        if(tf!=null&&tf.FieldType==typeof(Transform))calcTransRoots[l]=tf.GetValue(calc) as Transform; // May be null: the light transform itself is then the rotated node.
        found.Add(l);
    }
    static List<Light> SceneLights() { // Fallback when the LightCalc object is not reachable as a field: Reflect just set color (0.9,0.7,0.5) and intensity 1.3 on the character light.
        var found=new List<Light>();
        foreach(var l in UnityEngine.Object.FindObjectsOfType<Light>()) {
            var c=l.color;
            if(Math.Abs(c.r-0.9f)<1e-4&&Math.Abs(c.g-0.7f)<1e-4&&Math.Abs(c.b-0.5f)<1e-4&&Math.Abs(l.intensity-1.3f)<1e-4)found.Add(l);
        }
        return found;
    }
    static Dictionary<string,object> LightEvidence(Light l,Transform cam) {
        var tr=calcTransRoots.ContainsKey(l)?calcTransRoots[l]:null;
        return K("name",l.name,"type",(int)l.type,"enabled",l.enabled,"color",V(l.color),"intensity",l.intensity,
            "shadows",(int)l.shadows,"worldPosition",V(l.transform.position),"worldRotation",Q(l.transform.rotation),
            "forward",V(l.transform.forward),
            "cameraIsAncestor",l.transform==cam||l.transform.IsChildOf(cam),
            "chain",Chain(l.transform,cam),
            "transRoot",tr==null?null:K("name",tr.name,"localRotation",Q(tr.localRotation),"localEulerAngles",V(tr.localEulerAngles),
                "worldRotation",Q(tr.rotation),"chain",Chain(tr,cam)));
    }
    static readonly Dictionary<Light,Transform> calcTransRoots=new Dictionary<Light,Transform>();
    static List<object> Chain(Transform t,Transform cam) { // The light transform up to Camera.main inclusive; stops at the scene root if Camera.main is not an ancestor.
        var chain=new List<object>();Transform node=t;
        for(int guard=0;guard<64;guard++) {
            if(node==null)break;
            chain.Add(K("name",node.name,"localPosition",V(node.localPosition),
                "localRotation",Q(node.localRotation),"localEulerAngles",V(node.localEulerAngles)));
            if(node==cam)break;
            node=node.parent;
        }
        return chain;
    }
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}static float[] Q(Quaternion q){return new[]{q.x,q.y,q.z,q.w};}
    static float[] V(Color c){return new[]{c.r,c.g,c.b};}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
