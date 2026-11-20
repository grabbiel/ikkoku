// ABMX (KKABMX 5.4) oracle, original side, for #401: how the original CharaStudio player with ABMX reads a character
// whose boneData records use the older layout ([BoneName, CoordinateModifiers] records, [Scale, Length] entries), and
// what it draws. Driver: Tools/reverse/original_abmx_probe.py run (one prlctl exec, private player root, BepInEx core
// plus hash-checked COPIES of the installed ExtensibleSaveFormat, KKAPI, KKAPI.NativeHelper and KKABMX).
//
// abmx-cases.tsv beside this plug-in lists the cases, one per line: <label> TAB <object key> TAB <sex 0|1> TAB
// <mode card|synthetic|legacy>, and abmx-<label>.png beside it is the uploaded scene record that holds the character. The run stops with an error
// unless KKABMX.Core 5.4, marco.kkapi and com.bepis.bepinex.extendedsave are loaded. ABMX, KKAPI and ExtendedSave
// are reached by reflection only, so this file compiles against BepInEx core and the game's Managed assemblies.
//
// Per case, from an emptied scene (Studio.InitScene(false)), as OriginalSliderProbe does:
//   parse:  new SceneInfo().Load(path); the character with that object key is found in the parsed tree and its
//           children are dropped, so only the character is built. Recorded at once ("stage": "parsed"):
//             - ExtendedSave's KKABMPlugin.ABMData entry on the parsed ChaFile: its version, its data keys, the
//               boneData bytes' length and SHA-256 (the bytes our decoder reads), and for a version-1 (legacy text)
//               entry (#403) the boneData string's UTF-8 length and SHA-256 (the text our decoder reads) and the
//               value's type name;
//             - "deserialized": ABMX's own reader, BoneController.ReadModifiers(PluginData), on that entry: per
//               BoneModifier its BoneName, BoneLocation and every CoordinateModifiers entry's ScaleModifier,
//               LengthModifier, PositionModifier and RotationModifier, floats written round-trip ("R"); a non-finite
//               float anywhere in the output is the string "NaN", "Infinity" or "-Infinity".
//   load:   AddObjectFemale.Load / AddObjectMale.Load(info, null, null), SettleFrames frames, then at the end of a
//           frame ("stage": "loaded"):
//             - "live": the BoneController's GetAllModifiers() after the load, the same fields plus whether each
//               modifier found its bone (BoneTransform), that bone's path, and the baseline ABMX applies the
//               modifier to (its private _hasBaseline, _sclBaseline, _posBaseline and _rotBaseline);
//             - every cf_/cm_ transform under the body and head bone roots (relative path and local transform);
//             - the character's root: its localToWorld matrix and every transform from the bone root up to it;
//             - the capture: a probe camera fitted to the character's renderer bounds (in front of the root, looking
//               back along its forward, field of view FitFov, the bounds' sphere fitted with a margin), then at the
//               end of a frame three CaptureW x CaptureH renders from it: the colour frame with Camera.main's
//               settings but none of its image effects (abmx-<label>-color.png), and two white-on-black silhouettes
//               with fog off: every enabled renderer of the character (abmx-<label>-character.png), and the skin only,
//               the body and head meshes without hair, clothes, parts, accessories or hit meshes
//               (abmx-<label>-skin.png). Every other renderer is off for those two renders and restored after them.
//               The camera (pose, field of view, clip planes, worldToCamera and projection), the scene record's own
//               camera data, the character's renderers with their part, the two sets' viewport rectangles and each
//               silhouette's white pixel count are recorded.
// synthetic mode, after the above ("stage": "synthetic"): the SyntheticRows below, code constants that use Position,
//           Rotation, Length and location 0 as no saved card in the corpus does, are added in memory with ABMX's own
//           BoneController.AddModifier(new BoneModifier(name, location, {new BoneModifierData(scale, length, position,
//           rotation)})) after GetModifier shows the card has none on those bones (else the case fails). NeedsFullRefresh
//           is never set: its OnReload re-reads the card and would drop them. After SettleFrames frames, every synthetic
//           bone's local transform is sampled at the end of two consecutive frames, then the live modifiers, the bones
//           and a second capture (abmx-<label>-post-*.png) are recorded, and the synthetic modifiers alone are serialized
//           by ABMX's own writer, BoneController.SaveModifiers(list, false): the PluginData version and the boneData bytes
//           (base64, length, SHA-256), and ReadModifiers on that PluginData. No card data is in that payload.
// legacy mode (#403), right after the parse record, before the load: each LegacyTexts constant (synthetic card-v1 text,
//           no card data) is read by ABMX's own ReadModifiers from a new PluginData of the parsed entry's type (version 1,
//           data {boneData: text}), which runs OldDataConverter.MigrateOldExtData. Per text ("legacyTexts"): its label and
//           UTF-8 SHA-256, and the modifiers with every value as a float32 bit pattern (8 hex digits), or null when the
//           reader returns null, or the exception. Then the case goes on as a card case.
// Each case is written to abmx/abmx-<label>.json and the run's outcome to abmx/status.json. A failed case is recorded
// and the run goes on. No installed card, scene or save is read or written; the uploaded records are only read.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using BepInEx;
using BepInEx.Bootstrap;
using Manager;
using Studio;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.abmxprobe", "Ikkoku ABMX probe", "1.0.0")]
public sealed class OriginalABMXProbe:BaseUnityPlugin {
    const int SettleFrames=30, CaptureW=960, CaptureH=720;
    const float FitFov=23f, FitMargin=1.05f;
    const string AbmxGuid="KKABMX.Core", AbmxVersion="5.4", AbmxData="KKABMPlugin.ABMData";
    static readonly string[] Required={"KKABMX.Core","marco.kkapi","com.bepis.bepinex.extendedsave"};
    const BindingFlags Any=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance;
    const BindingFlags AnyStatic=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static;
    string dir,folder,voiceRepair;
    Studio.Studio studio;
    readonly List<string> errors=new List<string>(), caseErrors=new List<string>(), written=new List<string>();
    IEnumerator Start() {
        dir=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        folder=Path.Combine(dir,"abmx");Directory.CreateDirectory(folder);
        var plugins=new Dictionary<string,object>();
        try {
            foreach(var guid in Required) {
                PluginInfo info;
                if(!Chainloader.PluginInfos.TryGetValue(guid,out info))throw new Exception(guid+" is not loaded");
                plugins[guid]=K("name",info.Metadata.Name,"version",info.Metadata.Version.ToString(),"location",Path.GetFileName(info.Location));
            }
            var abmx=Chainloader.PluginInfos[AbmxGuid].Metadata.Version;
            if(abmx.Major!=5||abmx.Minor!=4)throw new Exception("KKABMX.Core is "+abmx+", expected "+AbmxVersion);
        } catch(Exception e){errors.Add("plugins: "+e.Message);}
        var rows=new List<string[]>();
        if(errors.Count==0) {
            try {
                foreach(var line in File.ReadAllLines(Path.Combine(dir,"abmx-cases.tsv"))) {
                    if(line.Length==0)continue;
                    var f=line.Split('\t');
                    if(f.Length!=4||(f[3]!="card"&&f[3]!="synthetic"&&f[3]!="legacy")||!File.Exists(Path.Combine(dir,"abmx-"+f[0]+".png")))throw new Exception("bad case row or missing scene record: "+line);
                    rows.Add(f);
                }
                if(rows.Count==0)throw new Exception("no case");
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
            IEnumerator run=null;string failed=null;
            try{run=Case(row[0],Int32.Parse(row[1],CultureInfo.InvariantCulture),Int32.Parse(row[2],CultureInfo.InvariantCulture),row[3]=="synthetic",row[3]=="legacy");}catch(Exception e){failed=row[0]+": "+e;}
            while(failed==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){failed=row[0]+": "+e;}if(failed!=null||!more)break;yield return current;}
            if(failed!=null)caseErrors.Add(failed);
        }
        errors.AddRange(caseErrors);
        try{if(studio!=null)studio.InitScene(false);}catch(Exception e){errors.Add("final InitScene: "+e.Message);}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "plugins",plugins,"unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"voiceRepair",voiceRepair,
            "settleFrames",SettleFrames,"syntheticRows",SyntheticRows.Length,"capture",new List<object>{CaptureW,CaptureH},"written",written,"caseErrors",caseErrors.Count,
            "scope","Uploaded scene records read by the original CharaStudio player with KKABMX 5.4: per case ABMX's deserialized modifiers, then the character built by the scene-load path, its live modifiers, baselines, bone transforms and a capture from a probe camera fitted to it; synthetic cases add constant modifiers in memory with ABMX's own API, record the same after them and serialize them with ABMX's own writer; legacy cases also read synthetic card-v1 texts with ABMX's own reader.")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    IEnumerator Case(string label,int key,int sex,bool synthetic,bool legacy) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var path=Path.Combine(dir,"abmx-"+label+".png");
        var parsed=new SceneInfo();Version version;
        if(!parsed.Load(path,out version))throw new Exception("SceneInfo.Load returned false");
        var info=Find(parsed.dicObject.Values,key);
        if(info==null)throw new Exception("no character with object key "+key);
        if(info.sex!=sex)throw new Exception("object key "+key+" has sex "+info.sex+", expected "+sex);
        int dropped=0;foreach(var list in info.child.Values){dropped+=list.Count;list.Clear();}
        var entry=Extended(info.charFile);
        var name="abmx-"+label+".json";
        var record=K("schemaVersion",1,"stage","parsed","label",label,"key",key,"sex",sex,"dataVersion",version==null?null:version.ToString(),
            "droppedChildren",dropped,"extendedData",entry==null?null:EntryRecord(entry),"deserialized",entry==null?null:Modifiers(ReadModifiers(entry),false,null));
        File.WriteAllText(Path.Combine(folder,name),J(record));
        if(entry==null)throw new Exception("the parsed character has no "+AbmxData+" entry");
        if(legacy){record["legacyTexts"]=LegacyRuns(entry);File.WriteAllText(Path.Combine(folder,name),J(record));}
        // No InitScene here: the load's guide objects need the change amounts the parse registered (OriginalSliderProbe).
        OCIChar oci=sex==1?(OCIChar)AddObjectFemale.Load(info,null,null):AddObjectMale.Load(info,null,null);
        for(int i=0;i<SettleFrames;i++)yield return null;
        yield return new WaitForEndOfFrame();
        var cha=oci.charInfo;
        if(cha==null)throw new Exception("the loaded character has no ChaControl");
        var controllerType=T("KKABMX.Core.BoneController");
        var controller=controllerType==null?null:cha.gameObject.GetComponent(controllerType);
        if(controller==null)throw new Exception("the loaded character has no KKABMX.Core.BoneController");
        var live=Modifiers((IEnumerable)controllerType.GetMethod("GetAllModifiers",Type.EmptyTypes).Invoke(controller,null),true,cha.transform);
        var bones=K("body",Bones(cha.objBodyBone),"head",cha.objHeadBone==null||cha.objBodyBone==null||cha.objHeadBone.transform.IsChildOf(cha.objBodyBone.transform)?null:Bones(cha.objHeadBone));
        var chain=new List<object>();
        for(var x=cha.objBodyBone==null?null:cha.objBodyBone.transform;x!=null;x=x==cha.transform?null:x.parent)
            chain.Add(K("name",x.name,"pos",V(x.localPosition),"quat",Q(x.localRotation),"scl",V(x.localScale)));
        var characterRoot=K("name",cha.transform.name,"localToWorld",M(cha.transform.localToWorldMatrix),"position",V(cha.transform.position),
            "rotation",Q(cha.transform.rotation),"lossyScale",V(cha.transform.lossyScale),"boneRootToCharacter",chain);
        var capture=Capture(cha,label);
        record["stage"]="loaded";record["frame"]=Time.frameCount;record["live"]=live;record["bones"]=bones;
        record["characterRoot"]=characterRoot;record["sceneCamera"]=CameraData(parsed.cameraSaveData);record["capture"]=capture;
        record["counts"]=K("deserialized",((List<object>)record["deserialized"]).Count,"live",live.Count);
        File.WriteAllText(Path.Combine(folder,name),J(record));written.Add(name);
        if(!synthetic)yield break;
        var steps=Synthetic(cha,controllerType,controller,label,record);
        while(steps.MoveNext())yield return steps.Current;
        record["stage"]="synthetic";File.WriteAllText(Path.Combine(folder,name),J(record));
    }
    sealed class Row {
        public readonly string Name;public readonly int Location;public readonly Vector3 Scale,Position,Rotation;public readonly float Length;
        public Row(string name,int location,Vector3 scale,float length,Vector3 position,Vector3 rotation){Name=name;Location=location;Scale=scale;Length=length;Position=position;Rotation=rotation;}
    }
    // Code constants, no card data. Location 1 is BodyTop, 0 Unknown. Rotation only on cf_s_ bones (not animated); the
    // animated joint cf_j_forearm01_R gets Length and Position only, so its animated rotation is left alone.
    static readonly Row[] SyntheticRows={
        new Row("cf_s_neck",1,new Vector3(1f,1f,1f),1f,new Vector3(0f,0f,0f),new Vector3(12f,-20f,7f)),
        new Row("cf_s_forearm01_L",1,new Vector3(1f,1f,1f),1f,new Vector3(0.01f,0.02f,-0.015f),new Vector3(0f,0f,25f)),
        new Row("cf_j_forearm01_R",1,new Vector3(1f,1f,1f),1.15f,new Vector3(0f,0.03f,0f),new Vector3(0f,0f,0f)),
        new Row("cf_s_thigh01_L",1,new Vector3(1.1f,1f,1.1f),1f,new Vector3(0.02f,0f,0.03f),new Vector3(0f,0f,0f)),
        new Row("cf_s_spine02",0,new Vector3(1.05f,1f,1.05f),1f,new Vector3(0f,0f,0f),new Vector3(0f,10f,0f)),
    };
    IEnumerator Synthetic(ChaControl cha,Type controllerType,object controller,string label,Dictionary<string,object> record) {
        Type modifierType=T("KKABMX.Core.BoneModifier"),dataType=T("KKABMX.Core.BoneModifierData"),locationType=T("KKABMX.Core.BoneLocation");
        if(modifierType==null||dataType==null||locationType==null)throw new Exception("KKABMX.Core.BoneModifier, BoneModifierData or BoneLocation not found");
        var dataCtor=dataType.GetConstructor(new[]{typeof(Vector3),typeof(float),typeof(Vector3),typeof(Vector3)});
        var modifierCtor=modifierType.GetConstructor(new[]{typeof(string),locationType,dataType.MakeArrayType()});
        var getModifier=controllerType.GetMethod("GetModifier",new[]{typeof(string),locationType});
        var addModifier=controllerType.GetMethod("AddModifier",new[]{modifierType});
        var save=controllerType.GetMethod("SaveModifiers",AnyStatic,null,new[]{typeof(IEnumerable<>).MakeGenericType(modifierType),typeof(bool)},null);
        if(dataCtor==null||modifierCtor==null||getModifier==null||addModifier==null||save==null)throw new Exception("an ABMX member the synthetic case needs is missing");
        foreach(var row in SyntheticRows)foreach(var at in new[]{1,row.Location})
            if(getModifier.Invoke(controller,new object[]{row.Name,Enum.ToObject(locationType,at)})!=null)throw new Exception("the card already has a modifier on synthetic bone "+row.Name+" at location "+at);
        var added=(IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(modifierType));var rows=new List<object>();
        foreach(var row in SyntheticRows) {
            var data=Array.CreateInstance(dataType,1);data.SetValue(dataCtor.Invoke(new object[]{row.Scale,row.Length,row.Position,row.Rotation}),0);
            var m=modifierCtor.Invoke(new object[]{row.Name,Enum.ToObject(locationType,row.Location),data});added.Add(m);
            string error=null;
            try{addModifier.Invoke(controller,new[]{m});}catch(TargetInvocationException e){error=e.InnerException==null?e.Message:e.InnerException.ToString();}
            var t=Member(m,"BoneTransform") as Transform;var location=Member(m,"BoneLocation");
            rows.Add(K("boneName",row.Name,"requestedLocation",row.Location,"boneLocation",location==null?null:(object)Convert.ToInt32(location),"boneLocationName",location==null?null:location.ToString(),
                "scale",V(row.Scale),"length",row.Length,"position",V(row.Position),"rotation",V(row.Rotation),"addError",error,
                "boneFound",t!=null,"bonePath",t==null?null:PathOf(t,cha.transform),"localAtAdd",t==null?null:Local(t),"baselineAtAdd",Baseline(m)));
        }
        for(int i=0;i<SettleFrames;i++)yield return null;
        yield return new WaitForEndOfFrame();
        var first=Sample(added,cha.transform);
        yield return null;
        yield return new WaitForEndOfFrame();
        var second=Sample(added,cha.transform);
        var live=Modifiers((IEnumerable)controllerType.GetMethod("GetAllModifiers",Type.EmptyTypes).Invoke(controller,null),true,cha.transform);
        var bones=K("body",Bones(cha.objBodyBone),"head",cha.objHeadBone==null||cha.objBodyBone==null||cha.objHeadBone.transform.IsChildOf(cha.objBodyBone.transform)?null:Bones(cha.objHeadBone));
        var capture=Capture(cha,label+"-post");
        var entry=save.Invoke(null,new object[]{added,false});
        object payload=null;List<object> deserialized=null;
        if(entry!=null) {
            var data=Member(entry,"data") as IDictionary;var raw=data!=null&&data.Contains("boneData")?data["boneData"] as byte[]:null;
            payload=K("entry",EntryRecord(entry),"base64",raw==null?null:Convert.ToBase64String(raw));
            deserialized=Modifiers(ReadModifiers(entry),false,null);
        }
        int found=0;foreach(Dictionary<string,object> r in rows)if((bool)r["boneFound"])found++;
        record["synthetic"]=K("rows",rows,"frames",new List<object>{first,second},"live",live,"bones",bones,"capture",capture,"payload",payload,"deserialized",deserialized,
            "counts",K("rows",rows.Count,"found",found,"live",live.Count,"payloadRecords",deserialized==null?0:deserialized.Count));
    }
    static List<object> Sample(IList modifiers,Transform root) {
        var rows=new List<object>();
        foreach(var m in modifiers){var t=Member(m,"BoneTransform") as Transform;rows.Add(K("boneName",Member(m,"BoneName"),"frame",Time.frameCount,"local",t==null?null:Local(t),"baseline",Baseline(m)));}
        return rows;
    }
    static Dictionary<string,object> Local(Transform t){return K("pos",V(t.localPosition),"quat",Q(t.localRotation),"euler",V(t.localEulerAngles),"scl",V(t.localScale));}
    static Dictionary<string,object> Baseline(object m){return K("has",Member(m,"_hasBaseline"),"scale",V3(Member(m,"_sclBaseline")),"position",V3(Member(m,"_posBaseline")),"rotation",Q4(Member(m,"_rotBaseline")));}
    // ExtendedSave.GetExtendedDataById(ChaFile, "KKABMPlugin.ABMData"): an ExtensibleSaveFormat.PluginData or null.
    static object Extended(ChaFile file) {
        var type=T("ExtensibleSaveFormat.ExtendedSave");
        if(type==null)throw new Exception("ExtensibleSaveFormat.ExtendedSave not found");
        var method=type.GetMethod("GetExtendedDataById",AnyStatic,null,new[]{typeof(ChaFile),typeof(string)},null);
        if(method==null)throw new Exception("ExtendedSave.GetExtendedDataById(ChaFile, string) not found");
        return method.Invoke(null,new object[]{file,AbmxData});
    }
    static object EntryRecord(object entry) {
        var data=Member(entry,"data") as IDictionary;var keys=new List<string>();object bytes=null;
        if(data!=null)foreach(var k in data.Keys)keys.Add(Convert.ToString(k,CultureInfo.InvariantCulture));
        keys.Sort(StringComparer.Ordinal);
        var value=data!=null&&data.Contains("boneData")?data["boneData"]:null;
        var raw=value as byte[];var text=value as string;object textRecord=null;
        if(raw!=null)using(var sha=SHA256.Create())bytes=K("length",raw.Length,"sha256",BitConverter.ToString(sha.ComputeHash(raw)).Replace("-","").ToLowerInvariant());
        if(text!=null){var utf8=Encoding.UTF8.GetBytes(text);
            using(var sha=SHA256.Create())textRecord=K("utf8Length",utf8.Length,"sha256",BitConverter.ToString(sha.ComputeHash(utf8)).Replace("-","").ToLowerInvariant());}
        return K("version",Member(entry,"version"),"keys",keys,"boneData",bytes,"boneDataText",textRecord,"boneDataType",value==null?null:value.GetType().FullName);
    }
    // BoneController.ReadModifiers(PluginData): internal static, ABMX's own reader of the saved entry.
    static IEnumerable ReadModifiers(object entry) {
        var type=T("KKABMX.Core.BoneController");
        var method=type==null?null:type.GetMethod("ReadModifiers",AnyStatic,null,new[]{entry.GetType()},null);
        if(method==null)throw new Exception("KKABMX.Core.BoneController.ReadModifiers(PluginData) not found");
        return (IEnumerable)method.Invoke(null,new[]{entry});
    }
    // Synthetic card-v1 texts for legacy mode (#403): the boundary rules the corpus does not exercise, mirrored by the
    // native decoder's synthetic tests. Bone names are labels only; ReadModifiers looks no bone up.
    static string LegacyWhitespace() {
        var b=new StringBuilder();
        foreach(var c in new[]{0x09,0x0B,0x1C,0x1F,0x85,0xA0,0x1680,0x180E,0x2000,0x200A,0x200B,0x2028,0x2029,0x202F,0x205F,0x3000,0xFEFF})
            b.Append("0,ws").Append(c.ToString("x4")).Append("_a,0,1,1,1,1,0").Append((char)c).Append("0,ws").Append(c.ToString("x4")).Append("_b,0,1,1,1,1\r\n");
        return b.ToString();
    }
    static string LegacyNumbers() {
        var b=new StringBuilder();var n=0;
        foreach(var s in new[]{"-0","+1","1.",".5","007","1.1","1e-45","1e-50","1E+2","1.0000000596046448","3.4028234663852886e38",
                               "Infinity","-Infinity","NaN","infinity","+Infinity","0x10","1e","１","1_0","1e400","-1e400"})
            b.Append("0,n").Append((++n).ToString("d2",CultureInfo.InvariantCulture)).Append(",0,").Append(s).Append(",1,1,1\r\n");
        return b.ToString();
    }
    static readonly string[][] LegacyTexts={
        new[]{"range","0,probe_pos,0,1e39,1,1,1\r\n0,probe_neg,0,-1e39,1,1,1\r\n0,probe_max,0,3.4028235e38,1,1,1\r\n0,probe_ok,0,2,1,1,1\r\n"},
        new[]{"whitespace",LegacyWhitespace()},
        new[]{"numbers",LegacyNumbers()},
        new[]{"order","0,cc__a,0,0,1,1,1\r\n0,cc___,0,1,1,1,1\r\n0,cc__A,0,2,1,1,1\r\n0,cc__1,0,3,1,1,1\r\n0,cc__0,0,4,1,1,1\r\n0,cc__2,0,5,1,1,1\r\n0,cc__3,0,6,1,1,1\r\n"},
        new[]{"counts","0,t__0,0,0,1,1,1\r\n0,t__1,0,1,1,1,1\r\n0,t__2,0,2,1,1,1\r\n0,u__0,0,0,1,1,1\r\n0,u__1,0,1,1,1,1\r\n0,u__2,0,2,1,1,1\r\n0,u__3,0,3,1,1,1\r\n0,u__4,0,4,1,1,1\r\n0,u__5,0,5,1,1,1\r\n0,u__6,0,6,1,1,1\r\n0,u__7,0,7,1,1,1\r\n0,u__8,0,8,1,1,1\r\n"},
        new[]{"fields","0,f5,0,2,3\r\n0,f6,0,2,3,4\r\n0,f8,0,2,3,4,5,x\r\n,fe,,2,3,4\r\n0,ft,0,2,3,4,\r\n"},
        new[]{"drop-short","0,ok,0,2,1,1,1\r\n0,a,0,1,1,1,1\r\n"},
        new[]{"drop-empty-key","0,ok,0,2,1,1,1\r\n0,___,0,1,1,1,1\r\n"},
        new[]{"blank"," \r\n "},
    };
    static List<object> LegacyRuns(object entry) {
        var runs=new List<object>();var type=entry.GetType();
        foreach(var row in LegacyTexts) {
            object modifiers=null;string error=null;
            try {
                var data=Activator.CreateInstance(type);SetMember(data,"version",1);
                var values=new Dictionary<string,object>();values["boneData"]=row[1];SetMember(data,"data",values);
                modifiers=Bits(ReadModifiers(data));
            } catch(Exception e){error=e.GetType().FullName+": "+e.Message;}
            string sha256;using(var sha=SHA256.Create())sha256=BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(row[1]))).Replace("-","").ToLowerInvariant();
            runs.Add(K("label",row[0],"sha256",sha256,"modifiers",modifiers,"error",error));
        }
        return runs;
    }
    static void SetMember(object target,string name,object value) {
        var type=target.GetType();var field=type.GetField(name,Any);
        if(field!=null){field.SetValue(target,value);return;}
        var property=type.GetProperty(name,Any);
        if(property==null||!property.CanWrite)throw new Exception(type.FullName+"."+name+" is not writable");
        property.SetValue(target,value,null);
    }
    static string B(float f){return BitConverter.ToUInt32(BitConverter.GetBytes(f),0).ToString("x8");}
    static List<object> B3(object v){var x=(Vector3)v;return new List<object>{B(x.x),B(x.y),B(x.z)};}
    static List<object> Bits(IEnumerable modifiers) {
        if(modifiers==null)return null;
        var rows=new List<object>();
        foreach(var m in modifiers) {
            var entries=new List<object>();var coordinates=Member(m,"CoordinateModifiers") as IEnumerable;
            if(coordinates!=null)foreach(var d in coordinates)entries.Add(d==null?null:K("scale",B3(Member(d,"ScaleModifier")),"length",B((float)Member(d,"LengthModifier")),
                "position",B3(Member(d,"PositionModifier")),"rotation",B3(Member(d,"RotationModifier"))));
            var location=Member(m,"BoneLocation");
            rows.Add(K("boneName",Member(m,"BoneName"),"boneLocation",location==null?null:(object)Convert.ToInt32(location),"coordinateModifiers",entries));
        }
        return rows;
    }
    static List<object> Modifiers(IEnumerable modifiers,bool live,Transform root) {
        var rows=new List<object>();
        if(modifiers==null)return rows;
        foreach(var m in modifiers) {
            var location=Member(m,"BoneLocation");
            var entries=new List<object>();
            var coordinates=Member(m,"CoordinateModifiers") as IEnumerable;
            if(coordinates!=null)foreach(var d in coordinates)entries.Add(d==null?null:K("scale",V3(Member(d,"ScaleModifier")),"length",Member(d,"LengthModifier"),
                "position",V3(Member(d,"PositionModifier")),"rotation",V3(Member(d,"RotationModifier"))));
            var row=K("boneName",Member(m,"BoneName"),"boneLocation",location==null?null:(object)Convert.ToInt32(location),"boneLocationName",location==null?null:location.ToString(),
                "coordinateModifiers",coordinates==null?null:entries);
            if(live) {
                var t=Member(m,"BoneTransform") as Transform;row["boneFound"]=t!=null;row["bonePath"]=t==null?null:PathOf(t,root);
                row["baseline"]=Baseline(m);
            }
            rows.Add(row);
        }
        return rows;
    }
    // One probe camera fitted to the character's renderer bounds draws the colour frame (Camera.main's settings, none of
    // its image effects) and the two silhouettes (fog off, every renderer outside the set switched off and the set drawn
    // white on black, as in OriginalMapProbe's measurement pass).
    object Capture(ChaControl cha,string label) {
        var main=Camera.main;
        if(main==null)throw new Exception("no Camera.main for the capture");
        var groups=new Dictionary<Renderer,string>();
        foreach(var r in cha.gameObject.GetComponentsInChildren<Renderer>(false))if(r.enabled&&r.gameObject.activeInHierarchy)groups[r]=Group(cha,r.transform);
        var character=new List<Renderer>(groups.Keys);var skin=new List<Renderer>();
        foreach(var p in groups)if(p.Value=="skin")skin.Add(p.Key);
        if(character.Count==0)throw new Exception("the character has no enabled renderer to frame");
        var listed=new List<object>();
        foreach(var p in groups)listed.Add(K("name",p.Key.name,"group",p.Value,"type",p.Key.GetType().Name,"path",PathOf(p.Key.transform,cha.transform)));
        var bounds=character[0].bounds;foreach(var r in character)bounds.Encapsulate(r.bounds);
        float radius=bounds.extents.magnitude,distance=FitMargin*radius/Mathf.Sin(0.5f*FitFov*Mathf.Deg2Rad);
        Vector3 forward=cha.transform.forward,up=cha.transform.up;
        var target=new RenderTexture(CaptureW,CaptureH,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Default);target.antiAliasing=1;target.Create();
        var effects=new List<object>();
        foreach(var b in main.GetComponents<Behaviour>())effects.Add(K("type",b.GetType().FullName,"enabled",b.enabled));
        var mainRecord=CameraRecord(main);
        var probeObject=new GameObject("IkkokuABMXProbeCamera");var cam=probeObject.AddComponent<Camera>();
        cam.CopyFrom(main);cam.enabled=false;cam.targetTexture=target;
        cam.transform.position=bounds.center+forward*distance;cam.transform.rotation=Quaternion.LookRotation(-forward,up);
        cam.fieldOfView=FitFov;cam.nearClipPlane=Mathf.Max(0.01f,distance-2f*radius);cam.farClipPlane=distance+2f*radius;cam.aspect=(float)CaptureW/CaptureH;
        cam.allowMSAA=false;cam.useOcclusionCulling=false;
        cam.Render();var color=Save(target,"abmx-"+label+"-color.png");
        cam.clearFlags=CameraClearFlags.SolidColor;cam.backgroundColor=Color.black;cam.allowHDR=false;cam.cullingMask=~0;cam.renderingPath=RenderingPath.Forward;
        var probeRecord=CameraRecord(cam);
        var hidden=new List<Renderer>();var saved=new Dictionary<Renderer,Material[]>();
        bool fog=RenderSettings.fog;string whiteShader;Material white=null;object characterMask,skinMask;
        try {
            white=WhiteMaterial(out whiteShader);RenderSettings.fog=false;
            foreach(var r in UnityEngine.Object.FindObjectsOfType<Renderer>())if(r.enabled&&!groups.ContainsKey(r)){r.enabled=false;hidden.Add(r);}
            foreach(var r in character){saved[r]=r.sharedMaterials;var m=new Material[r.sharedMaterials.Length];for(int i=0;i<m.Length;i++)m[i]=white;r.sharedMaterials=m;}
            cam.Render();characterMask=Save(target,"abmx-"+label+"-character.png");
            foreach(var r in character)if(groups[r]!="skin")r.enabled=false;
            cam.Render();skinMask=Save(target,"abmx-"+label+"-skin.png");
        } finally {
            foreach(var p in saved)p.Key.sharedMaterials=p.Value;
            foreach(var r in character)r.enabled=true;
            foreach(var r in hidden)r.enabled=true;
            RenderSettings.fog=fog;cam.targetTexture=null;UnityEngine.Object.Destroy(probeObject);target.Release();UnityEngine.Object.Destroy(target);
            if(white!=null)UnityEngine.Object.Destroy(white);
        }
        return K("width",CaptureW,"height",CaptureH,"color",color,"character",characterMask,"skin",skinMask,"whiteShader",whiteShader,
            "main",mainRecord,"mainBehaviours",effects,"probe",probeRecord,"fit",K("center",V(bounds.center),"extents",V(bounds.extents),"radius",radius,"distance",distance,"fieldOfView",FitFov,"margin",FitMargin),
            "renderers",listed,"hiddenRenderers",hidden.Count,"characterViewport",ScreenRect(cam,character),"skinViewport",ScreenRect(cam,skin));
    }
    // The renderer's part of the character: the first of the ChaInfo part roots above it, else skin (body or head) or other.
    static string Group(ChaControl cha,Transform t) {
        var parts=new Dictionary<string,GameObject[]>{{"hair",cha.objHair},{"clothes",cha.objClothes},{"parts",cha.objParts},{"accessory",cha.objAccessory},
            {"hit",new[]{cha.objHitBody,cha.objHitHead}},{"tongue",new[]{cha.objTongueEx}}};
        for(var x=t;x!=null;x=x.parent) {
            foreach(var p in parts)if(p.Value!=null)foreach(var g in p.Value)if(g!=null&&g.transform==x)return p.Key;
            if((cha.objBody!=null&&x==cha.objBody.transform)||(cha.objHead!=null&&x==cha.objHead.transform))return "skin";
        }
        return "other";
    }
    static Material WhiteMaterial(out string name) {
        var shader=Shader.Find("Unlit/Color");name="Unlit/Color";
        if(shader==null){shader=Shader.Find("Hidden/Internal-Colored");name="Hidden/Internal-Colored";}
        if(shader==null)throw new Exception("neither Unlit/Color nor Hidden/Internal-Colored is in this player");
        var white=new Material(shader);white.color=Color.white;
        white.SetInt("_Cull",0);white.SetInt("_ZWrite",1);white.SetInt("_ZTest",4);white.SetInt("_SrcBlend",1);white.SetInt("_DstBlend",0); // both faces: cloth and hair cards are one-sided
        return white;
    }
    static Dictionary<string,object> CameraRecord(Camera c) {
        return K("name",c.name,"position",V(c.transform.position),"rotation",Q(c.transform.rotation),"eulerAngles",V(c.transform.eulerAngles),
            "fieldOfView",c.fieldOfView,"near",c.nearClipPlane,"far",c.farClipPlane,"aspect",c.aspect,"orthographic",c.orthographic,
            "worldToCamera",M(c.worldToCameraMatrix),"projection",M(c.projectionMatrix),"clearFlags",c.clearFlags.ToString(),
            "cullingMask",c.cullingMask,"actualRenderingPath",c.actualRenderingPath.ToString(),"allowHDR",c.allowHDR,"allowMSAA",c.allowMSAA);
    }
    static Dictionary<string,object> CameraData(Studio.CameraControl.CameraData d) {
        return d==null?null:K("pos",V(d.pos),"rotate",V(d.rotate),"distance",V(d.distance),"parse",d.parse);
    }
    object Save(RenderTexture target,string file) {
        var previous=RenderTexture.active;RenderTexture.active=target;
        var readback=new Texture2D(target.width,target.height,TextureFormat.RGBA32,false,true);readback.ReadPixels(new Rect(0,0,target.width,target.height),0,0);readback.Apply(false,false);
        int white=0;foreach(var c in readback.GetPixels32())if(c.r>128)white++;
        var png=readback.EncodeToPNG();UnityEngine.Object.Destroy(readback);RenderTexture.active=previous;
        File.WriteAllBytes(Path.Combine(folder,file),png);written.Add(file);
        using(var sha=SHA256.Create())return K("file",file,"bytes",png.Length,"sha256",BitConverter.ToString(sha.ComputeHash(png)).Replace("-","").ToLowerInvariant(),"whitePixels",white);
    }
    static object ScreenRect(Camera cam,List<Renderer> renderers) {
        float x0=float.MaxValue,y0=float.MaxValue,x1=float.MinValue,y1=float.MinValue;bool any=false;
        foreach(var r in renderers) {
            var b=r.bounds;
            for(int i=0;i<8;i++) {
                var c=b.center+Vector3.Scale(b.extents,new Vector3((i&1)==0?-1:1,(i&2)==0?-1:1,(i&4)==0?-1:1));
                var s=cam.WorldToViewportPoint(c);if(s.z<=0)continue;any=true;
                x0=Mathf.Min(x0,s.x);y0=Mathf.Min(y0,s.y);x1=Mathf.Max(x1,s.x);y1=Mathf.Max(y1,s.y);
            }
        }
        return any?(object)K("viewportMin",new List<object>{x0,y0},"viewportMax",new List<object>{x1,y1}):null;
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
    static Type T(string name) {
        foreach(var a in AppDomain.CurrentDomain.GetAssemblies()){var t=a.GetType(name,false);if(t!=null)return t;}
        return null;
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
    // OriginalSliderProbe.RepairVoice: this player copy's Manager.Voice.Awake() can die before it assigns
    // voiceInfoList; an empty table lets the character load's range check run. On a healthy boot it changes nothing.
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
    static List<object> V(Vector3 v){return new List<object>{v.x,v.y,v.z};}
    static object V3(object v){return v is Vector3?V((Vector3)v):null;}
    static object Q4(object q){return q is Quaternion?Q((Quaternion)q):null;}
    static List<object> Q(Quaternion q){return new List<object>{q.x,q.y,q.z,q.w};}
    static List<object> M(Matrix4x4 m){var l=new List<object>();for(int r=0;r<4;r++)for(int c=0;c<4;c++)l.Add(m[r,c]);return l;}
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        // A non-finite float is a JSON string, so its sign survives (#403: a legacy card can hold one).
        if(value is float&&Single.IsNaN((float)value))return "\"NaN\"";
        if(value is float&&Single.IsInfinity((float)value))return (float)value>0?"\"Infinity\"":"\"-Infinity\"";
        if(value is float)return ((float)value).ToString("R",CultureInfo.InvariantCulture);
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J(Convert.ToString(e.Key,CultureInfo.InvariantCulture))+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
