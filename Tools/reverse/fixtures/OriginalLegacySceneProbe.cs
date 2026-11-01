// ST-T05a legacy scenes (original side): what the original CharaStudio 1.0.4.2 player reads from scene
// records saved by older versions, and what it writes when it saves them again. Driver:
// Tools/reverse/original_legacy_scene_probe.py run (one prlctl exec, private player root, BepInEx core only).
//
// Every uploaded reload-<label>.png is read twice, each time from an emptied scene (Studio.InitScene(false)):
//   parse:  new SceneInfo().Load(path, out version), the player's own reader with no scene objects built
//           (SceneInfo.cs:316-449). The trace records the version string it read and every loaded record's
//           fields, the version-dependent ones included (OIItemInfo.cs:117-174, OICharInfo.cs:299,
//           OIRouteInfo.cs:73-99, OIRoutePointInfo.cs:57-81, CameraControl.cs:62-82). That SceneInfo is then
//           saved with the player's own writer (SceneInfo.Save, SceneInfo.cs:239-297, which always writes
//           1.0.4.2) as parsed-<label>.png, with nothing live in it; a failure is recorded, not fatal
//           (a route point without a saved aid has a null aidInfo, which OIRoutePointInfo.Save dereferences).
//   load:   Studio.LoadScene(path), the scene-load path (Studio.cs:507-543: objects built, route aids made by
//           AddObjectRoute.InitAid, dataVersion reset to 1.0.4.2), SettleFrames frames, the trace of the loaded
//           SceneInfo, and the save the scene-save button makes (each object's OnSavePreprocessing, the live
//           camera into cameraSaveData, SceneInfo.Save) as resave-<label>.png.
// The parse runs between two InitScene(false) calls: ObjectInfo.Load registers the keys it reads in the live
// scene's index (ObjectInfo.cs:41-51) and InitScene clears it again (Studio.cs:597-640). No installed cards,
// saves or media are read or written; everything goes to this plug-in's reload folder.
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
[BepInPlugin("org.ikkoku.validation.legacysceneprobe", "Ikkoku legacy scene probe", "1.0.0")]
public sealed class OriginalLegacySceneProbe:BaseUnityPlugin {
    const int SettleFrames=30;
    string folder,voiceRepair;
    Studio.Studio studio;
    readonly Dictionary<string,object> cases=new Dictionary<string,object>();
    readonly List<string> errors=new List<string>();
    IEnumerator Start() {
        var dir=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        folder=Path.Combine(dir,"reload");Directory.CreateDirectory(folder);
        int waited=0;
        for(;waited<3600&&!Ready();waited++)yield return null;
        if(waited>=3600)errors.Add("Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames");
        for(int i=0;i<60&&errors.Count==0;i++)yield return null;
        if(errors.Count==0) {
            studio=Singleton<Studio.Studio>.Instance;
            try{voiceRepair=RepairVoice();}catch(Exception e){errors.Add("voice repair: "+e);}
        }
        var files=new List<string>(Directory.GetFiles(dir,"reload-*.png"));files.Sort(StringComparer.Ordinal);
        if(errors.Count==0&&files.Count==0)errors.Add("no reload-*.png scene records beside the plug-in");
        foreach(var file in files) {
            if(errors.Count!=0)break;
            string label=Path.GetFileNameWithoutExtension(file).Substring("reload-".Length);
            IEnumerator run=null;
            try{run=Case(file,label);}catch(Exception e){errors.Add(label+": "+e);}
            while(errors.Count==0){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){errors.Add(label+": "+e);}if(errors.Count!=0||!more)break;yield return current;}
        }
        try{File.WriteAllText(Path.Combine(folder,"legacy-trace.json"),J(K("schemaVersion",1,"settleFrames",SettleFrames,"cases",cases)));}
        catch(Exception e){errors.Add("trace write: "+e);}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"voiceRepair",voiceRepair,"cases",new List<string>(cases.Keys),
            "scope","Uploaded scene records read by the original CharaStudio 1.0.4.2 player: per record the version string SceneInfo.Load read, every loaded record's fields (the version-dependent item, character, route, route point and camera fields included) and the scene settings, as parsed with no scene objects built and after Studio.LoadScene; the parsed SceneInfo saved with the player's writer (parsed-<label>.png) and the loaded scene saved the way the scene-save button does (resave-<label>.png); no installed cards, saves or media")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    IEnumerator Case(string path,string label) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var parsed=new SceneInfo();Version version=null;object parse;string parsedSave=null,parsedSaveError=null;
        try {
            if(!parsed.Load(path,out version))throw new Exception("SceneInfo.Load returned false");
            parse=K("dataVersion",version==null?null:version.ToString(),"scene",SceneRecord(parsed));
            var target=Path.Combine(folder,"parsed-"+label+".png");
            try{if(!parsed.Save(target))throw new Exception("SceneInfo.Save returned false");parsedSave=Path.GetFileName(target);}
            catch(Exception e){parsedSaveError=e.GetType().Name+": "+e.Message;if(File.Exists(target))File.Delete(target);}
        } catch(Exception e){parse=K("error",e.GetType().Name+": "+e.Message);}
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene before the load, found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(path))throw new Exception("Studio.LoadScene returned false for "+path);
        var afterLoad=K("dataVersion",studio.sceneInfo.dataVersion==null?null:studio.sceneInfo.dataVersion.ToString(),"objects",studio.dicObjectCtrl.Count,
            "indexKeys",IndexKeys(studio.sceneInfo),"scene",SceneRecord(studio.sceneInfo));
        for(int i=0;i<SettleFrames;i++)yield return null;
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        var resave=Path.Combine(folder,"resave-"+label+".png");
        if(!studio.sceneInfo.Save(resave))throw new Exception("Studio.sceneInfo.Save returned false for "+resave);
        cases[label]=K("label",label,"upload",Path.GetFileName(path),"parse",parse,"parsedSave",parsedSave,"parsedSaveError",parsedSaveError,
            "load",afterLoad,"saved",K("objects",studio.dicObjectCtrl.Count,"scene",SceneRecord(studio.sceneInfo)),"resave",Path.GetFileName(resave));
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // OriginalSceneReloadProbe.RepairVoice: this player copy's Manager.Voice.Awake() can die before it assigns
    // voiceInfoList, and every character load's range check then throws; an empty table lets it run (it only
    // reports and clamps voice numbers). On a healthy boot it changes nothing. The outcome goes into status.json.
    static string RepairVoice() {
        if(!Singleton<Voice>.IsInstance())return "no Manager.Voice singleton: a character load cannot range-check at all";
        var voice=Singleton<Voice>.Instance;
        if(voice.voiceInfoList!=null)return "voiceInfoList already holds "+voice.voiceInfoList.Count+" voice entries: nothing to repair";
        var property=typeof(Voice).GetProperty("voiceInfoList",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
        var setter=property==null?null:property.GetSetMethod(true);
        if(setter==null)throw new Exception("the null Manager.Voice.voiceInfoList has no accessible private setter to repair");
        setter.Invoke(voice,new object[]{new List<VoiceInfo.Param>()});
        if(voice.voiceInfoList==null||voice.voiceInfoDic==null||voice.voiceInfoDic.Count!=0)throw new Exception("the voiceInfoList repair left the voice table unusable");
        return "Manager.Voice.Awake() had died before assigning voiceInfoList: replaced the null voice table with an empty one so the load range check runs";
    }
    static readonly System.Reflection.FieldInfo HashIndex=typeof(SceneInfo).GetField("hashIndex",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
    static object IndexKeys(SceneInfo info) {
        var set=HashIndex==null||info==null?null:HashIndex.GetValue(info) as HashSet<int>;
        if(set==null)return null;var keys=new List<int>(set);keys.Sort();return keys;
    }
    // The SceneInfo as loaded: the roots in dictionary order (the order SceneInfo.Save writes them) and the settings.
    static Dictionary<string,object> SceneRecord(SceneInfo s) {
        var roots=new List<object>();
        foreach(var root in s.dicObject)roots.Add(K("key",root.Key,"object",Record(root.Value)));
        var slots=new List<object>();if(s.cameraData!=null)foreach(var c in s.cameraData)slots.Add(CameraRecord(c));
        return K("roots",roots,"map",s.map,"caMap",Change(s.caMap),"sunLightType",s.sunLightType,"mapOption",s.mapOption,"aceNo",s.aceNo,"aceBlend",s.aceBlend,
            "enableAOE",s.enableAOE,"aoeColor",C(s.aoeColor),"aoeRadius",s.aoeRadius,"enableBloom",s.enableBloom,"bloomIntensity",s.bloomIntensity,
            "bloomBlur",s.bloomBlur,"bloomThreshold",s.bloomThreshold,"enableDepth",s.enableDepth,"depthFocalSize",s.depthFocalSize,"depthAperture",s.depthAperture,
            "enableVignette",s.enableVignette,"enableFog",s.enableFog,"fogColor",C(s.fogColor),"fogHeight",s.fogHeight,"fogStartDistance",s.fogStartDistance,
            "enableSunShafts",s.enableSunShafts,"sunThresholdColor",C(s.sunThresholdColor),"sunColor",C(s.sunColor),"sunCaster",s.sunCaster,
            "enableShadow",s.enableShadow,"faceNormal",s.faceNormal,"faceShadow",s.faceShadow,"lineColorG",s.lineColorG,"ambientShadow",C(s.ambientShadow),
            "lineWidthG",s.lineWidthG,"rampG",s.rampG,"ambientShadowG",s.ambientShadowG,"camera",CameraRecord(s.cameraSaveData),"cameraSlots",slots,
            "background",s.background,"frame",s.frame);
    }
    static object CameraRecord(Studio.CameraControl.CameraData c) {
        if(c==null)return null;
        return K("pos",V(c.pos),"rotate",V(c.rotate),"distance",V(c.distance),"parse",c.parse);
    }
    // One record and its children: the ObjectInfo fields, then the fields of its kind.
    static Dictionary<string,object> Record(ObjectInfo info) {
        if(info==null)return null;
        var d=K("kind",info.kind,"dicKey",info.dicKey,"change",Change(info.changeAmount),"treeState",(int)info.treeState,"visible",info.visible);
        var item=info as OIItemInfo;var chr=info as OICharInfo;var route=info as OIRouteInfo;var fold=info as OIFolderInfo;var cam=info as OICameraInfo;var light=info as OILightInfo;
        if(item!=null) {
            var colors=new List<object>();if(item.color!=null)foreach(var c in item.color)colors.Add(C(c));
            var patterns=new List<object>();if(item.pattern!=null)foreach(var p in item.pattern)patterns.Add(Pattern(p));
            d["item"]=K("group",item.group,"category",item.category,"no",item.no,"animeSpeed",item.animeSpeed,"colors",colors,"patterns",patterns,
                "alpha",item.alpha,"lineColor",C(item.lineColor),"lineWidth",item.lineWidth,"emissionColor",C(item.emissionColor),"emissionPower",item.emissionPower,
                "lightCancel",item.lightCancel,"panel",Pattern(item.panel),"enableFK",item.enableFK,"bones",item.bones==null?0:item.bones.Count,
                "enableDynamicBone",item.enableDynamicBone,"animeNormalizedTime",item.animeNormalizedTime);
            d["children"]=Children(item.child);
        }
        if(chr!=null) {
            var groups=new List<object>();
            if(chr.child!=null)foreach(var g in chr.child)groups.Add(K("point",g.Key,"children",Children(g.Value)));
            d["character"]=K("sex",chr.sex,"expression",chr.expression,"neckBytes",chr.neckByteData==null?-1:chr.neckByteData.Length,
                "eyes",Hex(chr.eyesByteData),"animeNormalizedTime",chr.animeNormalizedTime,"bones",chr.bones==null?0:chr.bones.Count,
                "ikTargets",chr.ikTarget==null?0:chr.ikTarget.Count);
            d["accessoryChildren"]=groups;
        }
        if(route!=null) {
            var points=new List<object>();
            if(route.route!=null)foreach(var p in route.route) {
                var aid=p.aidInfo;
                points.Add(K("dicKey",p.dicKey,"change",Change(p.changeAmount),"speed",p.speed,"easeType",(int)p.easeType,"connection",(int)p.connection,"link",p.link,
                    "aid",aid==null?null:K("dicKey",aid.dicKey,"change",Change(aid.changeAmount),"isInit",aid.isInit)));
            }
            d["route"]=K("name",route.name,"active",route.active,"loop",route.loop,"visibleLine",route.visibleLine,"orient",(int)route.orient,"color",C(route.color),"points",points);
            d["children"]=Children(route.child);
        }
        if(fold!=null){d["folder"]=K("name",fold.name);d["children"]=Children(fold.child);}
        if(cam!=null)d["camera"]=K("name",cam.name,"active",cam.active);
        if(light!=null)d["light"]=K("no",light.no,"color",C(light.color),"intensity",light.intensity,"range",light.range,"spotAngle",light.spotAngle,
            "shadow",light.shadow,"enable",light.enable,"drawTarget",light.drawTarget);
        return d;
    }
    static List<object> Children(List<ObjectInfo> list){var a=new List<object>();if(list!=null)foreach(var c in list)a.Add(Record(c));return a;}
    static object Pattern(PatternInfo p) {
        if(p==null)return null;
        return K("key",p.key,"filePath",p.filePath,"clamp",p.clamp,"uv",new[]{p.uv.x,p.uv.y,p.uv.z,p.uv.w},"rot",p.rot);
    }
    static object Change(ChangeAmount c){if(c==null)return null;return K("pos",V(c.pos),"rot",V(c.rot),"scale",V(c.scale));}
    static string Hex(byte[] b){if(b==null)return null;var s=new StringBuilder();foreach(var x in b)s.Append(x.ToString("x2"));return s.ToString();}
    static float[] C(Color c){return new[]{c.r,c.g,c.b,c.a};}
    static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}
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
