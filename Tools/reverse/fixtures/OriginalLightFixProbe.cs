// ST-T03k (phase E of original_light_fix_probe.py): the original CharaStudio player loads the installed scenes whose
// Sideloader records name nested lights, with and without KK_Fix_UnlimitedMapLights, and runs survey 4. The private
// root holds phase D's plug-in set (ExtendedSave, Sideloader, KKAPI, StudioSceneSettings, KKPE, NodesConstraints and
// MaterialEditor), the zipmods those records name (as many as the bounds allow), and in the first launch only the
// light fix. reload-input\phase.txt says which launch runs. Compiled together with PluginSceneRules.cs,
// PluginSceneRuleParity.cs and PluginSceneSurvey.cs.
//
// Each launch first loads every reload-input\scene-*.png (copies run.ps1 made, read-only, of the install's scenes
// with the SHA-256 values the host named) with Studio.LoadScene from an empty scene. Harmony patches, applied by
// reflection and counting only while the probe's own load runs, observe Sideloader's scene load
// (UniversalAutoResolver.ExtendedSceneLoad -> ResolveStudioObjects):
//   reached     a prefix on ResolveStudioObject(StudioResolveInfo, ObjectInfo, ResolveType): the records whose object
//               the load reached, in order (a record naming an object the load does not have throws first, :1342);
//   resolved    its postfix: the records whose object's saved number the call changed (the mod's local slot);
//   patterns    a prefix on ResolveStudioObjectPattern: pattern records reached;
//   compat      a prefix on the one-argument ResolveStudioObject: objects the compatibility pass reached (:1346-1355);
//   map         a prefix on ResolveStudioMap: whether the load reached the map, filter, ramp and BGM steps;
//   exception   a finalizer on ResolveStudioObjects: the type of the exception it ended with, or none.
// Per scene the row has the first 12 hex digits of the file's SHA-256, the loaded objects and lights (nested lights
// kept, SceneInfo's light count), the records in ExtendedSave's loaded Sideloader entry, and how many of them name a
// loaded object, were reached and were resolved. No file name, GUID, object name or data value is kept.
//
//   fix     KK_Fix_UnlimitedMapLights must be loaded. After the loads: rule parity on reload-input\corpus.txt with this
//           player's compiler, then survey 4 over the install's scene folder (reload-input\survey.txt) into
//           survey4.json. Nothing is saved.
//   nofix   KK_Fix_UnlimitedMapLights must not be loaded. After the loads: CharaStudio's load-then-save of the scene
//           reload-input\resave.txt names (its SHA-256), as resave-<12 hex>.png in this launch's own output folder
//           inside the private root, and the survey's model of every scene-*.png without judging edits
//           (lights-control.json: the light counts without the fix).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using BepInEx;
using Studio;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.lightfixprobe", "Ikkoku light fix probe", "1.0.0")]
public sealed class OriginalLightFixProbe:BaseUnityPlugin {
    const int Settle=20;
    const string LightFix="KK_Fix_UnlimitedMapLights";
    const string SideloaderData="com.bepis.sideloader.universalautoresolver";
    static readonly string[] Required={"com.bepis.bepinex.extendedsave","com.bepis.bepinex.sideloader","marco.kkapi",
        "com.deathweasel.bepinex.studioscenesettings","gravydevsupreme.xunity.resourceredirector",
        "com.joan6694.kkplugins.kkpe","com.joan6694.illusionplugins.nodesconstraints","com.deathweasel.bepinex.materialeditor"};
    string folder,input,phase;
    Studio.Studio studio;
    readonly Dictionary<string,object> cases=new Dictionary<string,object>();

    // What the patches saw during the probe's current load.
    static bool loading;
    static readonly List<int> reached=new List<int>();
    static readonly HashSet<int> resolved=new HashSet<int>();
    static int numberBefore,patterns,compat,map;
    static string exception;
    static object harmony;

    IEnumerator Start() {
        string here=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        input=Path.Combine(here,"reload-input");
        string error=null;
        try{phase=File.ReadAllText(Path.Combine(input,"phase.txt")).Trim();}catch(Exception e){error="phase.txt: "+e.Message;}
        if(error==null&&phase!="fix"&&phase!="nofix")error="unknown phase "+phase;
        folder=Path.Combine(Path.Combine(here,"reload"),error==null?phase:"unknown");Directory.CreateDirectory(folder);
        int waited=0;
        for(;waited<3600;waited++){if(Ready())break;yield return null;}
        if(error==null&&waited>=3600)error="Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames";
        for(int i=0;i<60&&error==null;i++)yield return null;
        studio=Singleton<Studio.Studio>.Instance;
        var plugins=new Dictionary<string,object>();
        foreach(var entry in BepInEx.Bootstrap.Chainloader.PluginInfos)plugins[entry.Key]=entry.Value.Metadata.Version.ToString();
        foreach(var id in Required)if(error==null&&!plugins.ContainsKey(id))error="required plug-in "+id+" did not load";
        if(error==null&&phase=="fix"&&!plugins.ContainsKey(LightFix))error="the fix launch needs "+LightFix;
        if(error==null&&phase=="nofix"&&plugins.ContainsKey(LightFix))error="the nofix launch must not load "+LightFix;
        string voiceRepair=null;
        if(error==null){try{voiceRepair=RepairVoice();}catch(Exception e){error="voice repair: "+e;}}
        if(error==null){try{Observe();}catch(Exception e){error="patches: "+e;}}
        var steps=new List<KeyValuePair<string,Func<IEnumerator>>>();
        steps.Add(new KeyValuePair<string,Func<IEnumerator>>("loads",Loads));
        if(phase=="fix")steps.Add(new KeyValuePair<string,Func<IEnumerator>>("survey",Survey)); // last: nothing is saved
        else {
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("resave",Resave));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("lights",LightsControl));
        }
        foreach(var step in steps) {
            if(error!=null)break;
            IEnumerator run=null;string failure=null;
            try{run=step.Value();}catch(Exception e){failure=step.Key+": "+e;}
            while(failure==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){failure=step.Key+": "+e;}if(failure!=null||!more)break;yield return current;}
            if(failure!=null)error=failure;
        }
        try{File.WriteAllText(Path.Combine(folder,"light-fix-trace.json"),J(K("schemaVersion",1,"phase",phase,"plugins",plugins,"cases",cases)));}
        catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"plugins",plugins,"phase",phase,"voiceRepair",voiceRepair,
            "lightCheckWithTwoLights",LightCheckWithTwo(),
            "scope",phase=="fix"?"phase E with KK_Fix_UnlimitedMapLights: Sideloader's load of the installed scenes whose records name nested lights, then the counts-only scene survey 4"
                :"phase E without KK_Fix_UnlimitedMapLights: the same loads, CharaStudio's load-then-save of one of those scenes, and the survey model's light counts")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Manager.Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Manager.Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // As OriginalPluginRewriteProbe.RepairVoice: every character load's range check throws on a null voiceInfoList.
    static string RepairVoice() {
        if(!Singleton<Manager.Voice>.IsInstance())return "no Manager.Voice singleton";
        var voice=Singleton<Manager.Voice>.Instance;
        if(voice.voiceInfoList!=null)return "voiceInfoList already holds "+voice.voiceInfoList.Count+" voice entries: nothing to repair";
        var property=typeof(Manager.Voice).GetProperty("voiceInfoList",BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance);
        var setter=property==null?null:property.GetSetMethod(true);
        if(setter==null)throw new Exception("the null Manager.Voice.voiceInfoList has no accessible private setter to repair");
        setter.Invoke(voice,new object[]{new List<VoiceInfo.Param>()});
        return "replaced a null Manager.Voice.voiceInfoList with an empty one";
    }
    // ObjectInfoAssist.LoadChild's own check (Studio.IsLightCheck) with two lights counted, on an empty scene: true only
    // when KK_Fix_UnlimitedMapLights' getter postfix runs.
    bool? LightCheckWithTwo() {
        if(studio==null)return null;
        var field=typeof(SceneInfo).GetField("lightCount",BindingFlags.NonPublic|BindingFlags.Instance);
        if(field==null)return null;
        object saved=field.GetValue(studio.sceneInfo);
        field.SetValue(studio.sceneInfo,2);bool check=Studio.Studio.IsLightCheck();
        field.SetValue(studio.sceneInfo,saved);
        return check;
    }

    // ---- Sideloader's load, observed ----
    static void Observe() {
        var resolver=FindType("Sideloader.AutoResolver.UniversalAutoResolver");
        if(resolver==null)throw new Exception("Sideloader.AutoResolver.UniversalAutoResolver not found");
        MethodInfo records=null,single=null;
        foreach(var m in resolver.GetMethods(BindingFlags.Static|BindingFlags.Public|BindingFlags.NonPublic)) {
            if(m.Name!="ResolveStudioObject")continue;
            var p=m.GetParameters();
            if(p.Length==3&&p[1].ParameterType==typeof(ObjectInfo))records=m;
            if(p.Length==1&&p[0].ParameterType==typeof(ObjectInfo))single=m;
        }
        if(records==null||single==null)throw new Exception("ResolveStudioObject overloads not found");
        Patch(records,"RecordBefore","RecordAfter",null);
        Patch(single,"CompatBefore",null,null);
        Patch(Static(resolver,"ResolveStudioObjectPattern"),"PatternBefore",null,null);
        Patch(Static(resolver,"ResolveStudioMap"),"MapBefore",null,null);
        Patch(Static(resolver,"ResolveStudioObjects"),null,null,"ObjectsDone");
    }
    static MethodInfo Static(Type type,string name) {
        var m=type.GetMethod(name,BindingFlags.Static|BindingFlags.Public|BindingFlags.NonPublic);
        if(m==null)throw new Exception(type.FullName+"."+name+" not found");
        return m;
    }
    // Harmony.Patch(original, prefix, postfix, transpiler, finalizer[, ...]) by reflection, so the probe compiles
    // against the game and BepInEx alone.
    static void Patch(MethodBase original,string prefix,string postfix,string finalizer) {
        var harmonyType=FindType("HarmonyLib.Harmony");var methodType=FindType("HarmonyLib.HarmonyMethod");
        if(harmonyType==null||methodType==null)throw new Exception("HarmonyLib not found");
        if(harmony==null)harmony=Activator.CreateInstance(harmonyType,new object[]{"org.ikkoku.validation.lightfixprobe"});
        MethodInfo patch=null;
        foreach(var m in harmonyType.GetMethods(BindingFlags.Public|BindingFlags.Instance)) {
            var p=m.GetParameters();
            if(m.Name=="Patch"&&p.Length>=5&&p[0].ParameterType==typeof(MethodBase)&&p[1].Name=="prefix"&&p[2].Name=="postfix"&&p[4].Name=="finalizer")patch=m;
        }
        if(patch==null)throw new Exception("Harmony.Patch(MethodBase, prefix, postfix, transpiler, finalizer) not found");
        var args=new object[patch.GetParameters().Length];args[0]=original;
        string[] names={prefix,postfix,null,finalizer};
        for(int i=0;i<names.Length;i++) {
            if(names[i]==null)continue;
            var method=typeof(OriginalLightFixProbe).GetMethod(names[i],BindingFlags.Static|BindingFlags.NonPublic);
            args[i+1]=Activator.CreateInstance(methodType,new object[]{method});
        }
        patch.Invoke(harmony,args);
    }
    static void RecordBefore(ObjectInfo OI){if(!loading||OI==null)return;reached.Add(OI.dicKey);numberBefore=Number(OI);}
    static void RecordAfter(ObjectInfo OI){if(!loading||OI==null)return;if(Number(OI)!=numberBefore)resolved.Add(OI.dicKey);}
    static void CompatBefore(){if(loading)compat++;}
    static void PatternBefore(){if(loading)patterns++;}
    static void MapBefore(){if(loading)map++;}
    static void ObjectsDone(Exception __exception){if(loading)exception=__exception==null?"none":__exception.GetType().FullName;}
    static int Number(ObjectInfo info) {
        var item=info as OIItemInfo;if(item!=null)return item.no;
        var light=info as OILightInfo;if(light!=null)return light.no;
        var chara=info as OICharInfo;if(chara!=null)return chara.animeInfo.no;
        return Int32.MinValue;
    }

    // ---- Steps ----
    List<string> Scenes() {
        var names=new List<string>();
        foreach(var path in Directory.GetFiles(input,"scene-*.png"))names.Add(Path.GetFileName(path));
        names.Sort(StringComparer.Ordinal);
        if(names.Count==0)throw new Exception("no scene-*.png in reload-input");
        return names;
    }
    IEnumerator Loads() {
        var rows=new List<object>();
        foreach(var name in Scenes()) {
            var load=Load(Path.Combine(input,name));while(load.MoveNext())yield return load.Current;
            rows.Add(Row(Path.Combine(input,name)));
        }
        cases["loads"]=rows;
    }
    IEnumerator Resave() {
        string want=File.ReadAllText(Path.Combine(input,"resave.txt")).Trim().ToLowerInvariant();
        string path=null;
        foreach(var name in Scenes())if(Sha(File.ReadAllBytes(Path.Combine(input,name)))==want)path=Path.Combine(input,name);
        if(path==null)throw new Exception("resave.txt names no scene-*.png");
        var load=Load(path);while(load.MoveNext())yield return load.Current;
        string saved="resave-"+want.Substring(0,12)+".png";
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        if(!studio.sceneInfo.Save(Path.Combine(folder,saved)))throw new Exception("Studio.sceneInfo.Save returned false");
        cases["resave"]=K("source",want.Substring(0,12),"file",saved,"loaded",Row(path));
    }
    // The survey's model of each scene without judging edits: its light counts in this player.
    IEnumerator LightsControl() {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        var survey=new PluginSceneSurvey(studio,600,512L*1024*1024);survey.JudgeEdits=false;
        foreach(var name in Scenes()){survey.Add(Path.Combine(input,name));yield return null;}
        var result=survey.Result();
        File.WriteAllText(Path.Combine(folder,"lights-control.json"),J(result));
        cases["lights"]=K("counts",result["counts"],"unlimitedLights",result["unlimitedLights"]);
    }
    // As OriginalPluginRewriteProbe.Survey (phase D's survey 3), into survey4.json.
    IEnumerator Survey() {
        var parameters=File.ReadAllLines(Path.Combine(input,"survey.txt"));
        string scenes=parameters[0].Trim();
        double seconds=Double.Parse(parameters[1].Trim(),CultureInfo.InvariantCulture);long bound=Int64.Parse(parameters[2].Trim(),CultureInfo.InvariantCulture);
        int count;var mismatches=PluginSceneRuleParity.Check(File.ReadAllText(Path.Combine(input,"corpus.txt")),out count);
        var result=K("schemaVersion",1,"survey",4,"parityCases",count,"parityMismatches",mismatches.Count,"folderExists",Directory.Exists(scenes));
        if(mismatches.Count==0&&count>0&&Directory.Exists(scenes)) {
            studio.InitScene(false);
            for(int i=0;i<3;i++)yield return null;
            if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene before the survey");
            var survey=new PluginSceneSurvey(studio,seconds,bound);
            foreach(var path in Directory.GetFiles(scenes,"*.png",SearchOption.AllDirectories)) {
                if(survey.TimedOut){survey.Truncated=true;break;}
                survey.Add(path);
                yield return null;
            }
            foreach(var entry in survey.Result())result[entry.Key]=entry.Value;
        } else result["skipped"]=mismatches.Count!=0||count==0?"the rule parity check failed":"the scene folder does not exist";
        File.WriteAllText(Path.Combine(folder,"survey4.json"),J(result));
        cases["survey"]=K("parityCases",count,"parityMismatches",mismatches.Count);
    }

    IEnumerator Load(string path) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        reached.Clear();resolved.Clear();patterns=0;compat=0;map=0;exception=null;
        bool ok;
        loading=true;
        try{ok=studio.LoadScene(path);}finally{loading=false;}
        if(!ok)throw new Exception("Studio.LoadScene returned false");
        for(int i=0;i<Settle;i++)yield return null;
    }
    // The loaded scene and what Sideloader's load did with its records; counts only.
    Dictionary<string,object> Row(string path) {
        var keys=new Dictionary<int,int>();int nested=0,lights=0,depth=0;
        foreach(var entry in studio.sceneInfo.dicObject)Walk(entry.Value,1,false,keys,ref nested,ref lights,ref depth);
        var records=Records("itemInfo");var patternRecords=Records("patternInfo");
        int named=0,namedLights=0,reachedNamed=0,resolvedNamed=0,firstUnreached=-1;
        var reachedSet=new HashSet<int>(reached);
        for(int i=0;i<records.Count;i++) {
            int kind;bool loaded=keys.TryGetValue(records[i],out kind);
            if(loaded)named++;
            if(loaded&&kind==2)namedLights++;
            if(reachedSet.Contains(records[i]))reachedNamed++;else if(firstUnreached<0)firstUnreached=i;
            if(resolved.Contains(records[i]))resolvedNamed++;
        }
        var lightCount=typeof(SceneInfo).GetField("lightCount",BindingFlags.NonPublic|BindingFlags.Instance);
        return K("sha12",Sha(File.ReadAllBytes(path)).Substring(0,12),"objects",keys.Count,"depth",depth,"lights",lights,"nestedLightsKept",nested,
            "lightCount",lightCount==null?(object)null:lightCount.GetValue(studio.sceneInfo),
            "itemInfoRecords",records.Count,"patternInfoRecords",patternRecords.Count,
            "recordsNamingLoadedObjects",named,"recordsNamingLoadedLights",namedLights,
            "resolveCalls",reached.Count,"recordsReached",reachedNamed,"recordsResolved",resolvedNamed,"firstUnreachedRecord",firstUnreached,
            "patternsReached",patterns,"compatReached",compat,"mapStepReached",map,"objectsException",exception);
    }
    // Every loaded object by key with its kind (ObjectInfo.kind), as the survey walks them; nested lights counted.
    static void Walk(ObjectInfo info,int level,bool nestedIn,Dictionary<int,int> keys,ref int nested,ref int lights,ref int depth) {
        keys[info.dicKey]=info.kind;if(level>depth)depth=level;
        if(info.kind==2){lights++;if(nestedIn)nested++;}
        var children=new List<ObjectInfo>();
        var chara=info as OICharInfo;
        if(chara!=null){var points=new List<int>(chara.child.Keys);points.Sort();foreach(var point in points)children.AddRange(chara.child[point]);}
        else if(info is OIRouteInfo)children.AddRange(((OIRouteInfo)info).child);
        else if(info is OIItemInfo)children.AddRange(((OIItemInfo)info).child);
        else if(info is OIFolderInfo)children.AddRange(((OIFolderInfo)info).child);
        foreach(var child in children)Walk(child,level+1,true,keys,ref nested,ref lights,ref depth);
    }
    // The object keys of ExtendedSave's loaded Sideloader records of one list, in list order.
    static List<int> Records(string list) {
        var result=new List<int>();
        var save=FindType("ExtensibleSaveFormat.ExtendedSave");
        var data=save.GetMethod("GetSceneExtendedDataById",BindingFlags.Public|BindingFlags.Static).Invoke(null,new object[]{SideloaderData});
        var map=data==null?null:data.GetType().GetField("data").GetValue(data) as IDictionary;
        var values=map!=null&&map.Contains(list)?map[list] as IEnumerable:null;
        if(values==null)return result;
        var type=FindType(list=="itemInfo"?"Sideloader.AutoResolver.StudioResolveInfo":"Sideloader.AutoResolver.StudioPatternResolveInfo");
        var deserialize=type.GetMethod("Deserialize",BindingFlags.Static|BindingFlags.Public|BindingFlags.NonPublic);
        var key=type.GetProperty("DicKey",BindingFlags.Public|BindingFlags.Instance);
        foreach(var value in values)result.Add((int)key.GetValue(deserialize.Invoke(null,new object[]{(byte[])value}),null));
        return result;
    }

    static string Sha(byte[] data) {
        using(var sha=SHA256.Create()){var b=new StringBuilder();foreach(var x in sha.ComputeHash(data))b.Append(x.ToString("x2"));return b.ToString();}
    }
    static Type FindType(string name) {
        foreach(var asm in AppDomain.CurrentDomain.GetAssemblies()){var t=asm.GetType(name,false);if(t!=null)return t;}
        return null;
    }
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        if(value is float)return ((float)value).ToString("R",CultureInfo.InvariantCulture);
        if(value is double)return ((double)value).ToString("R",CultureInfo.InvariantCulture);
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J(Convert.ToString(e.Key,CultureInfo.InvariantCulture))+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
