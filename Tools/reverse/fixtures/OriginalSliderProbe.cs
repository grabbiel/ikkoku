// Extended shape rates (Slider Unlocker) oracle, original side: how the original CharaStudio 1.0.4.2 player
// reads and draws scene characters whose face/body shape rates lie outside 0...1. Driver:
// Tools/reverse/original_slider_probe.py run (one prlctl exec, private player root, BepInEx core only plus,
// in the "unlocked" run, a hash-checked copy of the installed KK_BepisPlugins\SliderUnlocker.dll).
//
// The driver starts the player twice. slider-mode.txt beside this plug-in names the run ("unlocked" or
// "vanilla"); the run stops with an error unless Slider Unlocker (com.bepis.bepinex.sliderunlocker) is loaded
// exactly in the unlocked run. slider-cards.tsv lists the cases, one per line:
//   <label> TAB <object key> TAB <sex 0|1> TAB <modes: "unlocked", "vanilla" or "unlocked,vanilla">
// and slider-<label>.png beside the plug-in is the uploaded scene record that holds the character.
//
// Per case, from an emptied scene (Studio.InitScene(false)):
//   parse:  new SceneInfo().Load(path), the player's own reader (OICharInfo.Load reads the card with
//           ChaFileControl.LoadCharaFile, whose CheckDataRange clamps the rates unless Slider Unlocker skips it).
//           The character with that object key is found in the parsed tree (folders, items, routes and
//           characters' children). Its rates are recorded as parsed. Its children (items on accessory points)
//           are dropped from the parsed record, so only the character is built.
//   load:   AddObjectFemale.Load / AddObjectMale.Load(info, null, null), the scene-load path for one character
//           (ChaControl.Load, the animation, IK/FK, Studio's Animator "height" parameter), SettleFrames frames,
//           then at the end of a frame:
//             - the rates on the live ChaFile, and bust softness/weight and areola size;
//             - every float Animator parameter (height, height1, Breast where present) and the layer-0 state;
//             - both ShapeInfo objects (body and face): every source channel (the anim-key names that write it,
//               and the position/rotation/scale ChangeValue computed) and every destination bone (its local
//               position, Euler angles, quaternion and scale after ShapeInfo.Update);
//             - every cf_/cm_ transform under the body and head bone roots (relative path and local transform);
//             - both EyeLookMaterialControll highlight offsets (hlUpOffsetY, hlDownOffsetY).
// Each case is written to slider/<mode>-<label>.json and the run's outcome to slider/<mode>-status.json. No installed
// card, scene or save is read or written; the uploaded records are only read.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using BepInEx;
using BepInEx.Bootstrap;
using Manager;
using Studio;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.sliderprobe", "Ikkoku slider probe", "1.0.0")]
public sealed class OriginalSliderProbe:BaseUnityPlugin {
    const int SettleFrames=30;
    const string SliderGuid="com.bepis.bepinex.sliderunlocker";
    const BindingFlags Any=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance;
    string folder,mode,voiceRepair;
    Studio.Studio studio;
    readonly List<string> errors=new List<string>();
    readonly List<string> written=new List<string>();
    IEnumerator Start() {
        var dir=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        folder=Path.Combine(dir,"slider");Directory.CreateDirectory(folder);
        mode="unknown";object slider=null;
        try {
            mode=File.ReadAllText(Path.Combine(dir,"slider-mode.txt")).Trim();
            if(mode!="unlocked"&&mode!="vanilla")throw new Exception("slider-mode.txt must say unlocked or vanilla, not "+mode);
            PluginInfo info;bool loaded=Chainloader.PluginInfos.TryGetValue(SliderGuid,out info);
            if(loaded)slider=K("guid",SliderGuid,"name",info.Metadata.Name,"version",info.Metadata.Version.ToString(),"location",info.Location);
            if(loaded!=(mode=="unlocked"))throw new Exception("Slider Unlocker loaded="+loaded+" in the "+mode+" run");
        } catch(Exception e){errors.Add("mode: "+e.Message);}
        var rows=new List<string[]>();
        if(errors.Count==0) {
            try {
                foreach(var line in File.ReadAllLines(Path.Combine(dir,"slider-cards.tsv"))) {
                    if(line.Length==0)continue;
                    var f=line.Split('\t');
                    if(f.Length!=4||!File.Exists(Path.Combine(dir,"slider-"+f[0]+".png")))throw new Exception("bad case row or missing scene record: "+line);
                    if(Array.IndexOf(f[3].Split(','),mode)>=0)rows.Add(f);
                }
                if(rows.Count==0)throw new Exception("no case for the "+mode+" run");
            } catch(Exception e){errors.Add("cases: "+e.Message);}
        }
        int waited=0;
        for(;waited<3600&&!Ready();waited++)yield return null;
        if(waited>=3600)errors.Add("Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames");
        for(int i=0;i<60&&errors.Count==0;i++)yield return null;
        if(errors.Count==0) {
            studio=Singleton<Studio.Studio>.Instance;
            try{voiceRepair=RepairVoice();}catch(Exception e){errors.Add("voice repair: "+e);}
        }
        foreach(var row in rows) {
            if(errors.Count!=0)break;
            IEnumerator run=null;
            try{run=Case(row[0],Int32.Parse(row[1],CultureInfo.InvariantCulture),Int32.Parse(row[2],CultureInfo.InvariantCulture));}catch(Exception e){errors.Add(row[0]+": "+e);}
            while(errors.Count==0){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){errors.Add(row[0]+": "+e);}if(errors.Count!=0||!more)break;yield return current;}
        }
        try{if(studio!=null)studio.InitScene(false);}catch(Exception e){errors.Add("final InitScene: "+e.Message);}
        File.WriteAllText(Path.Combine(folder,mode+"-status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "mode",mode,"sliderUnlocker",slider,"unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"voiceRepair",voiceRepair,
            "settleFrames",SettleFrames,"written",written,
            "scope","Uploaded scene records read by the original CharaStudio 1.0.4.2 player: per case the parsed character's shape rates, then the character built by the scene-load path and its rates, Animator parameters, shape channels, bone transforms and eye-highlight offsets at the end of a settled frame.")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    IEnumerator Case(string label,int key,int sex) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var path=Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location),"slider-"+label+".png");
        var parsed=new SceneInfo();Version version;
        var timer=System.Diagnostics.Stopwatch.StartNew();
        if(!parsed.Load(path,out version))throw new Exception("SceneInfo.Load returned false");
        long parseMs=timer.ElapsedMilliseconds;
        var info=Find(parsed.dicObject.Values,key);
        if(info==null)throw new Exception("no character with object key "+key);
        if(info.sex!=sex)throw new Exception("object key "+key+" has sex "+info.sex+", expected "+sex);
        var parsedRates=Rates(info.charFile);
        int dropped=0;foreach(var list in info.child.Values){dropped+=list.Count;list.Clear();}
        // The parse registered its keys in the live scene index (ObjectInfo.Load); the next InitScene clears them.
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        timer=System.Diagnostics.Stopwatch.StartNew();
        OCIChar oci=sex==1?(OCIChar)AddObjectFemale.Load(info,null,null):AddObjectMale.Load(info,null,null);
        long loadMs=timer.ElapsedMilliseconds;
        for(int i=0;i<SettleFrames;i++)yield return null;
        yield return new WaitForEndOfFrame();
        var cha=oci.charInfo;
        if(cha==null)throw new Exception("the loaded character has no ChaControl");
        var record=K("schemaVersion",1,"mode",mode,"label",label,"key",key,"sex",sex,"frame",Time.frameCount,
            "dataVersion",version==null?null:version.ToString(),"parseMs",parseMs,"loadMs",loadMs,"droppedChildren",dropped,
            "parsed",parsedRates,"loaded",Rates(cha.chaFile),
            "anime",K("group",info.animeInfo.group,"category",info.animeInfo.category,"no",info.animeInfo.no,"savedNormalizedTime",info.animeNormalizedTime,
                "enableFK",info.enableFK,"enableIK",info.enableIK,"animeParam",new List<object>(oci.animeParam)),
            "animator",AnimatorRecord(cha.animBody),
            "shapes",K("body",ShapeRecord(cha.sibBody),"face",ShapeRecord(Member(cha,"sibFace") as ShapeInfoBase)),
            "bones",K("body",Bones(cha.objBodyBone),"head",cha.objHeadBone==null||cha.objBodyBone==null||cha.objHeadBone.transform.IsChildOf(cha.objBodyBone.transform)?null:Bones(cha.objHeadBone)),
            "eyeHighlights",Highlights(cha));
        var name=mode+"-"+label+".json";
        File.WriteAllText(Path.Combine(folder,name),J(record));written.Add(name);
    }
    static OICharInfo Find(IEnumerable<ObjectInfo> list,int key) {
        foreach(var o in list) {
            var c=o as OICharInfo;
            if(c!=null) {
                if(c.dicKey==key)return c;
                foreach(var kids in c.child.Values){var r=Find(kids,key);if(r!=null)return r;}
                continue;
            }
            List<ObjectInfo> children=null;
            if(o is OIFolderInfo)children=((OIFolderInfo)o).child;
            else if(o is OIItemInfo)children=((OIItemInfo)o).child;
            else if(o is OIRouteInfo)children=((OIRouteInfo)o).child;
            if(children!=null){var r=Find(children,key);if(r!=null)return r;}
        }
        return null;
    }
    static object Rates(ChaFileControl file) {
        var body=file.custom.body;var face=file.custom.face;
        return K("body",Floats(body.shapeValueBody),"face",Floats(face.shapeValueFace),"bustSoftness",body.bustSoftness,"bustWeight",body.bustWeight,
            "areolaSize",body.areolaSize,"hlUpY",face.hlUpY,"hlDownY",face.hlDownY,"headId",face.headId,"typeBone",body.typeBone,"sex",(int)file.parameter.sex);
    }
    static object AnimatorRecord(Animator animator) {
        if(animator==null)return null;
        var floats=new Dictionary<string,object>();
        foreach(var p in animator.parameters)if(p.type==AnimatorControllerParameterType.Float)floats[p.name]=animator.GetFloat(p.name);
        var state=animator.GetCurrentAnimatorStateInfo(0);
        return K("floats",floats,"stateHash",state.fullPathHash,"normalizedTime",state.normalizedTime,"speed",animator.speed,"enabled",animator.enabled);
    }
    static object ShapeRecord(ShapeInfoBase shape) {
        if(shape==null)return null;
        var src=Member(shape,"dictSrc") as IDictionary;var dst=Member(shape,"dictDst") as IDictionary;var categories=Member(shape,"dictCategory") as IDictionary;
        if(src==null||dst==null||categories==null)throw new Exception("ShapeInfoBase dictionaries are missing");
        var names=new Dictionary<int,List<string>>();
        foreach(DictionaryEntry e in categories)foreach(var c in (IEnumerable)e.Value) {
            int id=Convert.ToInt32(Member(c,"id"));string n=(string)Member(c,"name");List<string> l;
            if(!names.TryGetValue(id,out l))names[id]=l=new List<string>();
            if(!l.Contains(n))l.Add(n);
        }
        var sources=new List<object>();
        foreach(var id in SortedKeys(src)) {
            var b=src[id];List<string> l;names.TryGetValue(id,out l);
            sources.Add(K("id",id,"names",l,"pos",V((Vector3)Member(b,"vctPos")),"rot",V((Vector3)Member(b,"vctRot")),"scl",V((Vector3)Member(b,"vctScl"))));
        }
        var destinations=new List<object>();
        foreach(var id in SortedKeys(dst)) {
            var t=Member(dst[id],"trfBone") as Transform;
            destinations.Add(t==null?K("id",id,"bone",null):K("id",id,"bone",t.name,"pos",V(t.localPosition),"euler",V(t.localEulerAngles),"quat",Q(t.localRotation),"scl",V(t.localScale)));
        }
        return K("type",shape.GetType().Name,"initEnd",shape.InitEnd,"typeBone",shape.typeBone,"sources",sources,"destinations",destinations);
    }
    static List<int> SortedKeys(IDictionary d){var keys=new List<int>();foreach(var k in d.Keys)keys.Add(Convert.ToInt32(k));keys.Sort();return keys;}
    static object Bones(GameObject root) {
        if(root==null)return null;
        var rows=new List<object>();
        foreach(var t in root.GetComponentsInChildren<Transform>(true)) {
            var n=t.name.ToLowerInvariant();
            if(!n.StartsWith("cf_",StringComparison.Ordinal)&&!n.StartsWith("cm_",StringComparison.Ordinal))continue;
            rows.Add(K("path",PathOf(t,root.transform),"pos",V(t.localPosition),"euler",V(t.localEulerAngles),"quat",Q(t.localRotation),"scl",V(t.localScale)));
        }
        return K("root",root.name,"count",rows.Count,"transforms",rows);
    }
    static string PathOf(Transform t,Transform root){var parts=new List<string>();for(var x=t;x!=null&&x!=root;x=x.parent)parts.Insert(0,x.name);return String.Join("/",parts.ToArray());}
    static object Highlights(ChaControl cha) {
        var list=Member(cha,"eyeLookMatCtrl") as IEnumerable;
        if(list==null)return null;
        var rows=new List<object>();
        foreach(var c in list) {
            var component=c as Component;
            rows.Add(component==null?null:K("gameObject",component.gameObject.name,"hlUpOffsetY",Member(c,"hlUpOffsetY"),"hlDownOffsetY",Member(c,"hlDownOffsetY")));
        }
        return rows;
    }
    static object Member(object target,string name) {
        if(target==null)return null;
        for(var type=target.GetType();type!=null;type=type.BaseType) {
            var field=type.GetField(name,Any|BindingFlags.DeclaredOnly);if(field!=null)return field.GetValue(target);
            var property=type.GetProperty(name,Any|BindingFlags.DeclaredOnly);if(property!=null&&property.GetIndexParameters().Length==0)return property.GetValue(target,null);
        }
        return null;
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // OriginalSceneReloadProbe.RepairVoice: this player copy's Manager.Voice.Awake() can die before it assigns
    // voiceInfoList, and every character load's range check then throws; an empty table lets it run (it only
    // reports and clamps voice numbers). On a healthy boot it changes nothing. The outcome goes into the status.
    static string RepairVoice() {
        if(!Singleton<Voice>.IsInstance())return "no Manager.Voice singleton: a character load cannot range-check at all";
        var voice=Singleton<Voice>.Instance;
        if(voice.voiceInfoList!=null)return "voiceInfoList already holds "+voice.voiceInfoList.Count+" voice entries: nothing to repair";
        var property=typeof(Voice).GetProperty("voiceInfoList",Any);
        var setter=property==null?null:property.GetSetMethod(true);
        if(setter==null)throw new Exception("the null Manager.Voice.voiceInfoList has no accessible private setter to repair");
        setter.Invoke(voice,new object[]{new List<VoiceInfo.Param>()});
        if(voice.voiceInfoList==null||voice.voiceInfoDic==null||voice.voiceInfoDic.Count!=0)throw new Exception("the voiceInfoList repair left the voice table unusable");
        return "Manager.Voice.Awake() had died before assigning voiceInfoList: replaced the null voice table with an empty one so the load range check runs";
    }
    static List<object> Floats(float[] values){if(values==null)return null;var l=new List<object>();foreach(var v in values)l.Add(v);return l;}
    static List<object> V(Vector3 v){return new List<object>{v.x,v.y,v.z};}
    static List<object> Q(Quaternion q){return new List<object>{q.x,q.y,q.z,q.w};}
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        if(value is float)return ((float)value).ToString("R",CultureInfo.InvariantCulture);
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J(Convert.ToString(e.Key,CultureInfo.InvariantCulture))+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
