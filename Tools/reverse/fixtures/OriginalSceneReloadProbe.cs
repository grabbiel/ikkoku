// ST-T03 reload acceptance (our side): reload the scene records our app exported and record what the
// original CharaStudio player shows after loading them. Scene records are uploaded beside the plugin as
// reload-*.png (the route probe's upload pattern); only those files are read. A synthetic fixture card
// uploaded beside the plugin as author-card.png (driver --author-character, the ST-T01 source scene)
// first makes the player author scene-char.png from it: one female, FK disabled, default pose. No
// installed cards, saves, media or third-party plug-ins are read or written.
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
    static readonly int[] ProbeBones={19,21}; // the ST-T01 acceptance bones: 19 the FK-edited arm guide (the "fk-edit" bone), 21 the left hand guide
    string folder,mode="reload",voiceRepair;
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
        if(error==null) { try{voiceRepair=RepairVoice();}catch(Exception e){error="voice repair: "+e;} } // a dead Manager.Voice otherwise throws on every character load
        var dir=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        var files=new List<string>(Directory.GetFiles(dir,"reload-*.png"));files.Sort();
        var card=Path.Combine(dir,"author-card.png"); // an uploaded fixture card (driver --author-character) switches to author mode first
        if(error==null&&files.Count==0&&!File.Exists(card))error="no reload-*.png scene records and no author-card.png beside the plugin";
        if(error==null&&File.Exists(card)) {
            IEnumerator run=null;
            try{run=AuthorCase(card);}catch(Exception e){error="author-card.png: "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error="author-card.png: "+e;}if(error!=null||!more)break;yield return current;}
        }
        foreach(var file in files) {
            if(error!=null)break;
            IEnumerator run=null;
            try{run=ReloadCase(file);}catch(Exception e){error=Path.GetFileName(file)+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error=Path.GetFileName(file)+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        try{File.WriteAllText(Path.Combine(folder,"reload-trace.json"),J(K("schemaVersion",1,"framesPerPhase",Frames,"cases",cases)));}catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"mode",mode,
            "voiceRepair",voiceRepair,
            "scope","Our exported scene records reloaded in the original player: per-object name, objectInfo and tree-node visibility, per-camera active flag and the load view-camera winner, per-route playing state, and per-character FK state, active FK groups, saved and live bone transforms; the fixture-card author mode saves scene-char.png from one female in the default pose with FK disabled; this player copy boots with a Manager.Voice whose Awake threw, and the voiceRepair field records replacing its null voice table with an empty one so the load range check (voice numbers only, never FK or bone data) can run; no installed cards, saves or media")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();} // repeat until the player exits
    }
    // Environment repair, not an acceptance detail: this player copy's Manager.Voice.Awake() threw
    // during start-up (unity.log: AssetBundleManager.LoadAllAsset NullReferenceException on the
    // AppleDouble junk beside the real bundles in abdata/etcetra/list/config) after its singleton had
    // registered but before "voiceInfoList = sortList" ran. ChaFileControl.LoadCharaFile without
    // skipRangeCheck — every Studio.LoadScene of a character-bearing scene, via OICharInfo.Load —
    // range-checks the loaded data against voiceInfoDic, which throws on the null list, so no
    // character scene loads in this VM at all. The probe cannot rebuild the list without re-running
    // Awake, so it supplies an empty one: its only consumer, ChaFileControl.CheckDataRangeParameter,
    // then reports the character's personality as an out-of-range voice number and clamps it to 0
    // (the fixture card's is 0 either way), and LoadCharaFile ignores the check's result; nothing in
    // the range check touches FK bookkeeping or bone transforms. On a healthy boot the list is
    // populated and this changes nothing. The outcome goes into status.json for every capture.
    static string RepairVoice() {
        if(!Singleton<Voice>.IsInstance())return "no Manager.Voice singleton: a character load cannot range-check at all";
        var voice=Singleton<Voice>.Instance;
        if(voice.voiceInfoList!=null)return "voiceInfoList already holds "+voice.voiceInfoList.Count+" voice entries: nothing to repair";
        var property=typeof(Voice).GetProperty("voiceInfoList",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
        var setter=property==null?null:property.GetSetMethod(true); // the setter is private; the getter is public
        if(setter==null)throw new Exception("the null Manager.Voice.voiceInfoList has no accessible private setter to repair");
        setter.Invoke(voice,new object[]{new List<VoiceInfo.Param>()});
        if(voice.voiceInfoList==null||voice.voiceInfoDic==null||voice.voiceInfoDic.Count!=0)throw new Exception("the voiceInfoList repair left the voice table unusable");
        return "Manager.Voice.Awake() had died before assigning voiceInfoList (unity.log): replaced the null voice table with an empty one so the load range check runs (it only reports and clamps voice numbers, never FK or bone data)";
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // ST-T01 source scene, authored by the original player itself: one female from the uploaded synthetic
    // fixture card. This player copy's Manager.Voice.Awake() threw during start-up (unity.log), so the card
    // range check AddObjectFemale.Add feeds throws unless RepairVoice first replaces the dead voice table;
    // the probe does not depend on that for its own card: it reads the card with skipRangeCheck and gives
    // it to the same synchronous scene-restore call the player itself makes for a saved female,
    // AddObjectFemale.Load(info,null,null), registering the info itself because that path only records the
    // ctrl info. A fresh OICharInfo leaves enableFK false and activeFK at its default.
    IEnumerator AuthorCase(string card) {
        mode="author";
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("author mode expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var cardFile=new ChaFileControl();cardFile.skipRangeCheck=true;
        if(!cardFile.LoadCharaFile(card,byte.MaxValue,true))throw new Exception("ChaFileControl.LoadCharaFile returned false for "+card);
        var info=new OICharInfo(cardFile,Studio.Studio.GetNewIndex());
        var character=AddObjectFemale.Load(info,null,null);
        if(character==null)throw new Exception("AddObjectFemale.Load returned null for "+card);
        Studio.Studio.AddInfo(info,character); // Load registers only the ctrl info (it is the _addInfo:false scene-restore path); sceneInfo.dicObject is what Save serializes
        var authored=Record();
        cases["author"]=K("label","author","card",Path.GetFileName(card),"scene","scene-char.png","afterLoad",authored,"settled",authored);
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export(); // the route probe's save rule: the view belongs to the record
        string scene=Path.Combine(folder,"scene-char.png");
        if(!studio.sceneInfo.Save(scene))throw new Exception("Studio.sceneInfo.Save returned false for "+scene);
        // Read the saved scene back into an emptied scene (the camera probe's InitScene(false)-then-load rule),
        // so the trace also shows what the player itself sees when it opens our FK edit's source scene.
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("author mode expects an empty scene before the read-back, found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(scene))throw new Exception("Studio.LoadScene returned false for "+scene);
        var afterLoad=Record();
        for(int i=0;i<Frames;i++)yield return new WaitForEndOfFrame();
        cases["charastudio-fk-source"]=K("label","charastudio-fk-source","scene","scene-char.png","afterLoad",afterLoad,"settled",Record());
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
    // camera active flags, the camera the view uses, each route's playing state and each character's FK state.
    Dictionary<string,object> Record() {
        var objects=new List<object>();
        foreach(var entry in studio.dicObjectCtrl) {
            var ctrl=entry.Value;var info=ctrl.objectInfo;
            var cam=ctrl as OCICamera;var route=ctrl as OCIRoute;var chr=ctrl as OCIChar;
            objects.Add(K("dicKey",info.dicKey,"kind",info.kind,"name",Name(info),
                "objectInfoVisible",info.visible,"objectInfoTreeState",(int)info.treeState,
                "treeNodeVisible",ctrl.treeNodeObject==null?null:(object)ctrl.treeNodeObject.visible,
                "treeNodeTreeState",ctrl.treeNodeObject==null?null:(object)(int)ctrl.treeNodeObject.treeState,
                "cameraActive",cam!=null?(object)cam.cameraInfo.active:null,
                "viewCamera",cam!=null?(object)(studio.ociCamera==cam):null,
                "routePlaying",route!=null?(object)route.isPlay:null,
                "character",chr==null?null:CharRecord(chr,(OICharInfo)info)));
        }
        return K("objectCount",studio.dicObjectCtrl.Count,
            "viewCameraKey",studio.ociCamera==null?null:(object)studio.ociCamera.cameraInfo.dicKey,
            "viewCameraName",studio.ociCamera==null?null:studio.ociCamera.cameraInfo.name,
            "cameraCtrlEnabled",studio.cameraCtrl==null?null:(object)studio.cameraCtrl.enabled,
            "objects",objects);
    }
    // The character's FK bookkeeping plus the acceptance bones: the bone's saved (loaded) rotation and
    // world placement, live from guideObject.transformTarget — what the player's own views would show.
    static Dictionary<string,object> CharRecord(OCIChar ctrl,OICharInfo info) {
        var groups=new List<object>();if(info.activeFK!=null)foreach(var active in info.activeFK)groups.Add(active);
        var bones=new List<object>();
        foreach(int id in ProbeBones) {
            OCIChar.BoneInfo bone=null;
            if(ctrl.listBones!=null)foreach(var b in ctrl.listBones)if(b!=null&&b.boneID==id)bone=b;
            var target=bone==null||bone.guideObject==null?null:bone.guideObject.transformTarget;
            bones.Add(K("boneID",id,"found",bone!=null,
                "group",bone==null?null:(object)(int)bone.boneGroup,
                "savedRotation",bone==null?null:(object)V(bone.boneInfo.changeAmount.rot),
                "worldPosition",target==null?null:(object)V(target.position),
                "worldRotation",target==null?null:(object)Q(target.rotation)));
        }
        return K("dicKey",info.dicKey,"enableFK",info.enableFK,"enableIK",info.enableIK,"activeFK",groups,"bones",bones);
    }
    static string Name(ObjectInfo info) { // names live on the concrete info types, not on ObjectInfo
        var cam=info as OICameraInfo;if(cam!=null)return cam.name;
        var fold=info as OIFolderInfo;if(fold!=null)return fold.name;
        var route=info as OIRouteInfo;if(route!=null)return route.name;
        var chr=info as OICharInfo;if(chr!=null)return chr.charFile==null?null:chr.charFile.parameter.fullname;
        return null; // cameras, folders, routes and characters carry names; lights and guides do not
    }
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}static float[] Q(Quaternion q){return new[]{q.x,q.y,q.z,q.w};}
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
