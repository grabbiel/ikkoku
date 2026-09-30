// ST-T03 reload acceptance (our side): reload the scene records our app exported and record what the
// original CharaStudio player shows after loading them. Scene records are uploaded beside the plugin as
// reload-*.png (the route probe's upload pattern); only those files are read. No characters, cards,
// saves, media or third-party plug-ins are read or written.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using BepInEx;
using Manager;
using Studio;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.scenereloadprobe", "Ikkoku scene reload probe", "1.0.0")]
public sealed class OriginalSceneReloadProbe:BaseUnityPlugin {
    const int Frames=4;
    string folder;
    Studio.Studio studio;
    readonly Dictionary<string,object> cases=new Dictionary<string,object>();
    IEnumerator Start() {
        folder=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"reload");Directory.CreateDirectory(folder);
        string error=null;
        int waited=0;
        for(;waited<3600;waited++) { // Studio, its scene container and the scene camera are built during start-up.
            if(Ready())break;
            yield return null;
        }
        if(waited>=3600)error="Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames";
        for(int i=0;i<60&&error==null;i++)yield return null; // settled frames before the first load
        studio=Singleton<Studio.Studio>.Instance;
        var dir=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        var files=new List<string>(Directory.GetFiles(dir,"reload-*.png"));files.Sort();
        if(error==null&&files.Count==0)error="no reload-*.png scene records beside the plugin";
        foreach(var file in files) {
            if(error!=null)break;
            IEnumerator run=null;
            try{run=ReloadCase(file);}catch(Exception e){error=Path.GetFileName(file)+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error=Path.GetFileName(file)+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        try{File.WriteAllText(Path.Combine(folder,"reload-trace.json"),J(K("schemaVersion",1,"framesPerPhase",Frames,"cases",cases)));}catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,
            "scope","Our exported scene records reloaded in the original player: per-object name, objectInfo and tree-node visibility, per-camera active flag and the load view-camera winner, per-route playing state; no characters, cards, saves or media")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();} // repeat until the player exits
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // Each uploaded record is loaded into an emptied scene (the camera probe's InitScene(false)-then-load rule).
    // "afterLoad" is measured as soon as LoadScene returns, "settled" Frames frames later.
    IEnumerator ReloadCase(string path) {
        string label=Path.GetFileNameWithoutExtension(path).Substring("reload-".Length);
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("reload expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(path))throw new Exception("Studio.LoadScene returned false for "+path);
        var afterLoad=Record();
        for(int i=0;i<Frames;i++)yield return new WaitForEndOfFrame();
        var settled=Record();
        cases[label]=K("label",label,"scene",Path.GetFileName(path),"afterLoad",afterLoad,"settled",settled);
    }
    // What the player shows for the loaded scene: every object's name, info-level and tree-node visibility,
    // camera active flags, the camera the view uses and each route's playing state.
    Dictionary<string,object> Record() {
        var objects=new List<object>();
        foreach(var entry in studio.dicObjectCtrl) {
            var ctrl=entry.Value;var info=ctrl.objectInfo;
            var cam=ctrl as OCICamera;var route=ctrl as OCIRoute;
            objects.Add(K("dicKey",info.dicKey,"kind",info.kind,"name",Name(info),
                "objectInfoVisible",info.visible,"objectInfoTreeState",(int)info.treeState,
                "treeNodeVisible",ctrl.treeNodeObject==null?null:(object)ctrl.treeNodeObject.visible,
                "treeNodeTreeState",ctrl.treeNodeObject==null?null:(object)(int)ctrl.treeNodeObject.treeState,
                "cameraActive",cam!=null?(object)cam.cameraInfo.active:null,
                "viewCamera",cam!=null?(object)(studio.ociCamera==cam):null,
                "routePlaying",route!=null?(object)route.isPlay:null));
        }
        return K("objectCount",studio.dicObjectCtrl.Count,
            "viewCameraKey",studio.ociCamera==null?null:(object)studio.ociCamera.cameraInfo.dicKey,
            "viewCameraName",studio.ociCamera==null?null:studio.ociCamera.cameraInfo.name,
            "cameraCtrlEnabled",studio.cameraCtrl==null?null:(object)studio.cameraCtrl.enabled,
            "objects",objects);
    }
    static string Name(ObjectInfo info) { // names live on the concrete info types, not on ObjectInfo
        var cam=info as OICameraInfo;if(cam!=null)return cam.name;
        var fold=info as OIFolderInfo;if(fold!=null)return fold.name;
        var route=info as OIRouteInfo;if(route!=null)return route.name;
        return null; // only cameras, folders and routes occur in the reload records
    }
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        if(value is float)return ((float)value).ToString("R",CultureInfo.InvariantCulture);
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
