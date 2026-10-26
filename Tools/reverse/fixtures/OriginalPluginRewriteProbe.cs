// ST-T03j plug-in data rewrites (phases C and D of original_plugin_scene_probe.py): the original CharaStudio player
// with phase B's plug-in set (ExtendedSave, Sideloader, KKAPI, StudioSceneSettings, KKPE, NodesConstraints and
// MaterialEditor copied into its private root) and phase A's zipmod. reload-input\phase.txt says which phase runs.
// Compiled together with PluginSceneRules.cs, PluginSceneRuleParity.cs and PluginSceneSurvey.cs.
//
// Phase C authors scenes with data in all three plug-ins and saves CharaStudio's own edits of them:
//   author      loads phase A's fixture.png (keys as phase A's trace: folder F 0 [M2 3, V2 4], vanilla item V1 1
//               [M4 6], mod items M1 2 and M3 5, route R 7, camera C 14, light L 15), adds female W (a default
//               ChaFileControl with sex 1, as OriginalCameraObjectProbe.LookAtCase builds one) and then gives the scene:
//                 KKPE   bone data (one child transform moved and scaled) on M1, M3, V1 and V2 through
//                        HSPE.MainWindow.ExternalLoadScene, the path a scene load takes, every item's controller
//                        enabled, and bone data on W's neck through its CharaPoseController's ScheduleLoad;
//                 ME     a float, a color and a texture on M3, another texture on M1 and a float on V2, through
//                        MaterialEditor's SceneController setters;
//                 NC     constraints M3 -> V2 (item to item), W's left hand -> M1 (bone to item) and the main
//                        camera -> M4, in this order, through NodesConstraints.AddConstraint;
//               and saves authored.png, loads it and saves fixture.png (CharaStudio's load-then-save is the
//               fixture), records the plug-in state of the loaded fixture.
//   edits       each from a fresh load of fixture.png, saved as edit-<label>.png: delete (M1), delete-folder (F),
//               delete-character (W), delete-parent (M3, the parent of the item-to-item constraint), duplicate (M3),
//               duplicate-subtree (F with M2 and V2), duplicate-character (W) and delete-duplicate (delete V1,
//               then duplicate M3: issue #278, refused by our writer).
//   collider    only when the catalog has a KKPE lone collider (an item whose prefab is named "Collider", which
//               run.ps1 copies in from the install's mods when one exists): fixture.png plus that item LC, saved,
//               loaded and saved as fixture-lc.png, then lc-delete-character (W), lc-delete-collider (LC),
//               lc-duplicate-collider (LC) and lc-duplicate-character (W, refused by our writer: LC names W).
//   card-link   phase A's fixture plus female W2 whose card holds KK_AnimationController data (Links: one IK target
//               name -> M3's key, Eyes: M1's key, Pad: 40 characters), saved as card-link.png. ExtendedSave
//               writes the keys as MessagePack fixints, which NodesConstraints' card fallback cannot cast to int;
//               the driver makes card-link-int32.png from it, the same bytes with Int32 keys and an 8-character
//               shorter Pad, for phase D.
//   resave      loads and saves fixture.png, fixture-lc.png and every edit again (resave-*.png).
//
// Phase D loads files and reads back every plug-in's per-object state (`State`), saving nothing but resaves:
//   readback    reload-input\fixture*.png, edit-*.png (phase C's) and ours-*.png (our writer's exports of the same
//               edits): the objects, each KKPE controller's own SaveXml with instance IDs replaced by the owning
//               object's key, MaterialEditor's record lists with texture IDs replaced by the texture bytes' SHA-256,
//               and NodesConstraints' constraints with both ends as object key and path; each ours-*.png is also
//               saved again as resave-ours-*.png.
//   card-link   card-link.png and card-link-int32.png: the constraints NodesConstraints made from the cards, and
//               the survey model's card counts for each file (card-link-survey.json).
//   survey      last, nothing is saved after it: rule parity on reload-input\corpus.txt with this player's compiler,
//               then survey 3 over the install's scene folder (reload-input\survey.txt) into survey3.json.
// Only the private root's files and the probe's own scenes are read or written.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using BepInEx;
using Studio;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.pluginrewriteprobe", "Ikkoku plug-in rewrite probe", "1.0.0")]
public sealed class OriginalPluginRewriteProbe:BaseUnityPlugin {
    const int Settle=20;
    const string CardController="com.deathweasel.bepinex.animationcontroller";
    static readonly string[] Required={"com.bepis.bepinex.extendedsave","com.bepis.bepinex.sideloader","marco.kkapi",
        "com.deathweasel.bepinex.studioscenesettings","gravydevsupreme.xunity.resourceredirector",
        "com.joan6694.kkplugins.kkpe","com.joan6694.illusionplugins.nodesconstraints","com.deathweasel.bepinex.materialeditor"};
    public static readonly string[] Edits={"delete","delete-folder","delete-character","delete-parent","duplicate","duplicate-subtree","duplicate-character","delete-duplicate"};
    public static readonly string[] ColliderEdits={"lc-delete-character","lc-delete-collider","lc-duplicate-collider","lc-duplicate-character"};
    static readonly object[] FixtureKeys={"F",0,"V1",1,"M1",2,"M2",3,"V2",4,"M3",5,"M4",6,"R",7,"C",14,"L",15};
    static readonly string[] FixtureKinds={"F","OIFolderInfo","V1","OIItemInfo","M1","OIItemInfo","M2","OIItemInfo","V2","OIItemInfo","M3","OIItemInfo","M4","OIItemInfo","R","OIRouteInfo","C","OICameraInfo","L","OILightInfo"};
    static readonly string[] FloatProperties={"Metallic","Glossiness","Smoothness","Cutoff","SpecularPower","rimpower","ShadowExtend","LineWidthS","alpha"};
    static readonly string[] ColorProperties={"Color","Color2","ShadowColor","SpecularColor","LineColor","EmissionColor"};
    static readonly string[] TextureProperties={"MainTex","DetailMask","LineMask","AlphaMask","BumpMap","EmissionMap"};
    string folder,input,phase,voiceRepair,colliderItem;
    Studio.Studio studio;
    readonly Dictionary<string,object> cases=new Dictionary<string,object>();
    readonly Dictionary<string,int> keys=new Dictionary<string,int>();

    IEnumerator Start() {
        string here=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        folder=Path.Combine(here,"reload");Directory.CreateDirectory(folder);
        input=Path.Combine(here,"reload-input");
        string error=null;
        try{phase=File.ReadAllText(Path.Combine(input,"phase.txt")).Trim();}catch(Exception e){error="phase.txt: "+e.Message;}
        if(error==null&&phase!="C"&&phase!="D")error="unknown phase "+phase;
        int waited=0;
        for(;waited<3600;waited++){if(Ready())break;yield return null;}
        if(error==null&&waited>=3600)error="Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames";
        for(int i=0;i<60&&error==null;i++)yield return null;
        studio=Singleton<Studio.Studio>.Instance;
        var plugins=new Dictionary<string,object>();
        foreach(var entry in BepInEx.Bootstrap.Chainloader.PluginInfos)plugins[entry.Key]=entry.Value.Metadata.Version.ToString();
        foreach(var id in Required)if(error==null&&!plugins.ContainsKey(id))error="required plug-in "+id+" did not load";
        if(error==null){try{voiceRepair=RepairVoice();}catch(Exception e){error="voice repair: "+e;}}
        for(int i=0;i<FixtureKeys.Length;i+=2)keys[(string)FixtureKeys[i]]=(int)FixtureKeys[i+1];
        var steps=new List<KeyValuePair<string,Func<IEnumerator>>>();
        if(phase=="C") {
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("author",Author));
            foreach(var label in Edits){var l=label;steps.Add(new KeyValuePair<string,Func<IEnumerator>>(l,()=>Edit(l,"fixture.png")));}
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("collider",Collider));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("card-link",CardLink));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("resave",Resaves));
        } else {
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("readback",Readback));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("card-link",CardLinkControl));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("survey",Survey)); // last: nothing is saved after it
        }
        foreach(var step in steps) {
            if(error!=null)break;
            IEnumerator run=null;
            try{run=step.Value();}catch(Exception e){error=step.Key+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error=step.Key+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        try{File.WriteAllText(Path.Combine(folder,"plugin-scene-trace.json"),J(K("schemaVersion",1,"phase",phase,"plugins",plugins,"keys",keys,"colliderItem",colliderItem,"cases",cases)));}
        catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"plugins",plugins,"phase",phase,"voiceRepair",voiceRepair,
            "scope",phase=="C"?"phase C: a fixture with KKPE, MaterialEditor and NodesConstraints data on items, a character and the camera, CharaStudio's own saves of delete and duplicate edits of it (and of a lone-collider variant when the catalog has one), a card-link scene, and the load-then-save of every saved scene"
                :"phase D: per-object KKPE, MaterialEditor and NodesConstraints state of phase C's scenes and of our exports after a load, the load-then-save of our exports, the card-link controls, and last the counts-only scene survey 3")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Manager.Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Manager.Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // OriginalSceneReloadProbe.RepairVoice: a player whose Manager.Voice.Awake died leaves voiceInfoList null, and every
    // character load's range check then throws; an empty list only makes that check clamp voice numbers.
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

    // ---- Phase C ----
    IEnumerator Author() {
        var load=Load(Path.Combine(input,"fixture.png"));while(load.MoveNext())yield return load.Current;
        for(int i=0;i<FixtureKinds.Length;i+=2){var kind=Ctrl(FixtureKinds[i]).objectInfo.GetType().Name;if(kind!=FixtureKinds[i+1])throw new Exception("phase A key of "+FixtureKinds[i]+" holds "+kind);}
        var w=AddFemale(new Vector3(2f,0f,0f));keys["W"]=w.objectInfo.dicKey;
        for(int i=0;i<Settle;i++)yield return null; // KKPE's MainWindow.Update gives the new character its CharaPoseController
        var note=new Dictionary<string,object>();
        // KKPE: bone data on four items, through the scene-load path (MainWindow.ExternalLoadScene -> LoadSceneGeneric).
        var bones=new Dictionary<string,object>();
        var xml=new StringBuilder("<root version=\"2.21.4\">");
        foreach(var entry in new SortedDictionary<int,ObjectCtrlInfo>(studio.dicObjectCtrl)) {
            var item=entry.Value as OCIItem;if(item==null)continue;
            xml.Append("<itemInfo name=\"x\" index=\"").Append(XmlConvert.ToString(entry.Key)).Append("\" enabled=\"true\">");
            string name=null;foreach(var pair in keys)if(pair.Value==entry.Key)name=pair.Key;
            if(name=="M1"||name=="M3"||name=="V1"||name=="V2") {
                var root=item.guideObject.transformTarget;var bone=root.childCount>0?root.GetChild(0):null;
                if(bone!=null){xml.Append("<advancedObjects>").Append(BoneXml(bone,root)).Append("</advancedObjects>");bones[name]=PathFrom(bone,root);}
                else bones[name]=null;
            }
            xml.Append("</itemInfo>");
        }
        xml.Append("</root>");
        var mainWindowType=FindType("HSPE.MainWindow");if(mainWindowType==null)throw new Exception("HSPE.MainWindow not found");
        var mainWindow=mainWindowType.GetField("_self",BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static).GetValue(null);
        var document=new XmlDocument();document.LoadXml(xml.ToString());
        mainWindowType.GetMethod("ExternalLoadScene").Invoke(mainWindow,new object[]{document.FirstChild});
        // KKPE: bone data on W's neck through its own controller.
        var controller=PoseController(w);if(controller==null)throw new Exception("W has no KKPE pose controller");
        var neck=Find(w.guideObject.transformTarget,"cf_j_neck");if(neck==null)throw new Exception("W has no cf_j_neck");
        var chara=new XmlDocument();chara.LoadXml("<characterInfo version=\"2.21.4\"><advancedObjects>"+BoneXml(neck,w.guideObject.transformTarget)+"</advancedObjects></characterInfo>");
        controller.GetType().GetMethod("ScheduleLoad").Invoke(controller,new object[]{chara.FirstChild,null});
        bones["W"]=PathFrom(neck,w.guideObject.transformTarget);
        note["kkpeBones"]=bones;
        for(int i=0;i<Settle;i++)yield return null;
        // MaterialEditor: two textures (so a delete purges one), floats and a color.
        var me=new Dictionary<string,object>();
        me["M3"]=SetMaterial("M3",true,true,Png(new Color(0.25f,0.5f,0.75f,1f)));
        me["M1"]=SetMaterial("M1",false,false,Png(new Color(0.75f,0.25f,0.5f,1f)));
        me["V2"]=SetMaterial("V2",true,false,null);
        note["materialEditor"]=me;
        // NodesConstraints: item to item, bone to item, camera to item (the camera one last).
        var hand=Find(w.guideObject.transformTarget,"cf_j_hand_L");if(hand==null)throw new Exception("W has no cf_j_hand_L");
        AddConstraint(Ctrl("M3").guideObject.transformTarget,Ctrl("V2").guideObject.transformTarget,new Vector3(0f,0.1f,0f),true,"item-item");
        AddConstraint(hand,Ctrl("M1").guideObject.transformTarget,Vector3.zero,false,"bone-item");
        AddConstraint(studio.cameraCtrl.mainCmaera.transform,Ctrl("M4").guideObject.transformTarget,new Vector3(0f,0f,1f),false,"camera");
        note["constraints"]=NcState().Count;
        for(int i=0;i<Settle;i++)yield return null;
        var authored=Save("authored.png");
        load=Load(Path.Combine(folder,"authored.png"));while(load.MoveNext())yield return load.Current;
        var saved=Save("fixture.png");
        cases["author"]=K("label","author","note",note,"authored",authored,"saved",saved,"state",State());
    }
    IEnumerator Edit(string label,string source) {
        var load=Load(Path.Combine(folder,source));while(load.MoveNext())yield return load.Current;
        var loaded=Snapshot();
        var note=new Dictionary<string,object>();
        if(label=="delete")Delete(Ctrl("M1"));
        else if(label=="delete-folder")Delete(Ctrl("F"));
        else if(label=="delete-character"||label=="lc-delete-character")Delete(Ctrl("W"));
        else if(label=="delete-parent")Delete(Ctrl("M3"));
        else if(label=="duplicate")note["copies"]=Duplicate(Ctrl("M3"));
        else if(label=="duplicate-subtree")note["copies"]=Duplicate(Ctrl("F"));
        else if(label=="duplicate-character"||label=="lc-duplicate-character")note["copies"]=Duplicate(Ctrl("W"));
        else if(label=="delete-duplicate"){Delete(Ctrl("V1"));note["copies"]=Duplicate(Ctrl("M3"));}
        else if(label=="lc-delete-collider")Delete(Ctrl("LC"));
        else if(label=="lc-duplicate-collider")note["copies"]=Duplicate(Ctrl("LC"));
        else throw new Exception("unknown edit "+label);
        for(int i=0;i<Settle;i++)yield return null;
        var saved=Save("edit-"+label+".png");
        cases[label]=K("label",label,"source",source,"loaded",loaded,"note",note,"saved",saved);
    }
    // A KKPE lone collider: CollidersEditor treats a controller whose object is named "Collider" with a "Collider"
    // child holding a DynamicBoneCollider as one (HSPE.AMModules/CollidersEditor.cs:563-575).
    IEnumerator Collider() {
        var info=Singleton<Studio.Info>.Instance.dicItemLoadInfo;int[] found=null;
        var groups=new List<int>(info.Keys);groups.Sort();
        foreach(var g in groups){var cats=new List<int>(info[g].Keys);cats.Sort();
            foreach(var c in cats){var nos=new List<int>(info[g][c].Keys);nos.Sort();
                foreach(var n in nos)if(found==null&&info[g][c][n].fileName=="Collider")found=new[]{g,c,n};}}
        if(found==null){cases["collider"]=K("available",false);yield break;}
        colliderItem=found[0]+"/"+found[1]+"/"+found[2];
        var load=Load(Path.Combine(folder,"fixture.png"));while(load.MoveNext())yield return load.Current;
        var lc=AddObjectItem.Add(found[0],found[1],found[2]);if(lc==null)throw new Exception("AddObjectItem.Add returned null for the collider "+colliderItem);
        keys["LC"]=lc.objectInfo.dicKey;
        for(int i=0;i<Settle;i++)yield return null;
        var child=lc.guideObject.transformTarget.Find("Collider");
        var note=K("objectName",lc.guideObject.transformTarget.name,"colliderChild",child!=null,
            "dynamicBoneCollider",child!=null&&child.GetComponent<DynamicBoneCollider>()!=null);
        var authored=Save("fixture-lc-authored.png");
        load=Load(Path.Combine(folder,"fixture-lc-authored.png"));while(load.MoveNext())yield return load.Current;
        var saved=Save("fixture-lc.png");
        cases["collider"]=K("available",true,"item",colliderItem,"note",note,"authored",authored,"saved",saved,"state",State());
        foreach(var label in ColliderEdits){var edit=Edit(label,"fixture-lc.png");while(edit.MoveNext())yield return edit.Current;}
    }
    // NodesConstraints.LoadDataFromKKAnimationController's card path (NodesConstraints.cs:2259-2306) reads Links and
    // Eyes from each character's card when the scene has no KK_AnimationController entry.
    IEnumerator CardLink() {
        var load=Load(Path.Combine(input,"fixture.png"));while(load.MoveNext())yield return load.Current;
        var w=AddFemale(new Vector3(-2f,0f,0f));keys["W2"]=w.objectInfo.dicKey;
        for(int i=0;i<Settle;i++)yield return null;
        string ik=null;
        foreach(var target in w.listIKTarget)if(ik==null&&target.boneObject.name.EndsWith("hand_L",StringComparison.Ordinal))ik=target.boneObject.name;
        if(ik==null)ik=w.listIKTarget[0].boneObject.name;
        var links=new Dictionary<object,object>();links[ik]=keys["M3"];
        var data=new Dictionary<string,object>();data["Links"]=links;data["Eyes"]=keys["M1"];data["Pad"]=new string('p',40);
        SetCardExtended(w,CardController,1,data);
        for(int i=0;i<Settle;i++)yield return null;
        cases["card-link"]=K("ikTarget",ik,"linked",keys["M3"],"eyes",keys["M1"],"saved",Save("card-link.png"));
    }
    IEnumerator Resaves() {
        var names=new List<string>{"fixture.png"};
        if(File.Exists(Path.Combine(folder,"fixture-lc.png")))names.Add("fixture-lc.png");
        foreach(var path in Directory.GetFiles(folder,"edit-*.png"))names.Add(Path.GetFileName(path));
        names.Sort(StringComparer.Ordinal);
        var list=new List<object>();
        foreach(var name in names) {
            var load=Load(Path.Combine(folder,name));while(load.MoveNext())yield return load.Current;
            list.Add(K("source",name,"saved",Save("resave-"+name)));
        }
        cases["resave"]=list;
    }

    // ---- Phase D ----
    IEnumerator Readback() {
        var names=new List<string>();
        foreach(var pattern in new[]{"fixture*.png","edit-*.png","ours-*.png"})foreach(var path in Directory.GetFiles(input,pattern))names.Add(Path.GetFileName(path));
        names.Sort(StringComparer.Ordinal);
        if(names.Count==0)throw new Exception("no scenes in reload-input");
        var list=new Dictionary<string,object>();
        foreach(var name in names) {
            var load=Load(Path.Combine(input,name));while(load.MoveNext())yield return load.Current;
            var row=K("state",State());
            if(name.StartsWith("ours-",StringComparison.Ordinal))row["resaved"]=Save("resave-"+name);
            list[name]=row;
        }
        cases["readback"]=list;
    }
    IEnumerator CardLinkControl() {
        var result=new Dictionary<string,object>();
        foreach(var name in new[]{"card-link.png","card-link-int32.png"}) {
            var load=Load(Path.Combine(input,name));while(load.MoveNext())yield return load.Current;
            result[name]=K("objects",Objects(),"nodesConstraints",NcState());
        }
        // The survey model's card counts, one file at a time, on an emptied scene (PluginSceneSurvey.Model clears
        // the scene's key set).
        var counts=new Dictionary<string,object>();
        foreach(var name in new[]{"card-link.png","card-link-int32.png"}) {
            studio.InitScene(false);
            for(int i=0;i<3;i++)yield return null;
            var survey=new PluginSceneSurvey(studio,60,512L*1024*1024);
            survey.Add(Path.Combine(input,name));
            counts[name]=survey.Result();
        }
        File.WriteAllText(Path.Combine(folder,"card-link-survey.json"),J(counts));
        cases["card-link"]=result;
    }
    IEnumerator Survey() {
        var parameters=File.ReadAllLines(Path.Combine(input,"survey.txt"));
        string scenes=parameters[0].Trim();
        double seconds=Double.Parse(parameters[1].Trim(),CultureInfo.InvariantCulture);long bound=Int64.Parse(parameters[2].Trim(),CultureInfo.InvariantCulture);
        int count;var mismatches=PluginSceneRuleParity.Check(File.ReadAllText(Path.Combine(input,"corpus.txt")),out count);
        var result=K("schemaVersion",1,"survey",3,"parityCases",count,"parityMismatches",mismatches.Count,"folderExists",Directory.Exists(scenes));
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
        File.WriteAllText(Path.Combine(folder,"survey3.json"),J(result));
        cases["survey"]=K("parityCases",count,"parityMismatches",mismatches.Count);
    }

    // ---- Plug-in state ----
    Dictionary<string,object> State(){return K("objects",Objects(),"kkpe",KkpeState(),"materialEditor",MeState(),"nodesConstraints",NcState());}
    // Each KKPE controller's own SaveXml (what the next save writes for it), with every instance ID replaced by the
    // key of the object whose controller has it ("?" for an ID no live controller has).
    Dictionary<string,object> KkpeState() {
        var owners=new Dictionary<int,int>();var controllers=new SortedDictionary<int,Component>();
        foreach(var entry in studio.dicObjectCtrl){var c=PoseController(entry.Value);if(c!=null){owners[c.GetInstanceID()]=entry.Key;controllers[entry.Key]=c;}}
        var result=new Dictionary<string,object>();
        foreach(var entry in controllers) {
            var text=new StringWriter(CultureInfo.InvariantCulture);
            using(var writer=new XmlTextWriter(text)) {
                writer.WriteStartElement("controller");
                entry.Value.GetType().GetMethod("SaveXml",new[]{typeof(XmlTextWriter)}).Invoke(entry.Value,new object[]{writer});
                writer.WriteEndElement();
            }
            string xml=Regex.Replace(text.ToString(),"(uniqueId|poseControllerId)=\"(-?[0-9]+)\"",m=>{int owner;return m.Groups[1].Value+"=\""+(owners.TryGetValue(Int32.Parse(m.Groups[2].Value,CultureInfo.InvariantCulture),out owner)?"key "+owner:"?")+"\"";});
            result[entry.Key.ToString(CultureInfo.InvariantCulture)]=K("enabled",((Behaviour)entry.Value).enabled,"xml",xml);
        }
        return result;
    }
    // MaterialEditor's scene records, list by list in list order, every public field and property of each record as
    // text, a texture ID as the SHA-256 of its texture's bytes; and the texture dictionary's hashes.
    Dictionary<string,object> MeState() {
        var controller=MeController();var type=controller.GetType();
        var textures=type.GetField("TextureDictionary",BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static).GetValue(null) as IDictionary;
        var result=new Dictionary<string,object>();
        foreach(var field in type.GetFields(BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance)) {
            if(!field.FieldType.IsGenericType||field.FieldType.GetGenericTypeDefinition()!=typeof(List<>))continue;
            var list=field.GetValue(controller) as IList;if(list==null)continue;
            var rows=new List<object>();
            foreach(var record in list) {
                var row=new SortedDictionary<string,object>(StringComparer.Ordinal);
                foreach(var member in record.GetType().GetFields(BindingFlags.Public|BindingFlags.Instance))row[member.Name]=Value(member.Name,member.GetValue(record),textures);
                foreach(var member in record.GetType().GetProperties(BindingFlags.Public|BindingFlags.Instance))if(member.GetIndexParameters().Length==0&&member.CanRead)row[member.Name]=Value(member.Name,member.GetValue(record,null),textures);
                rows.Add(row);
            }
            result[field.Name]=rows;
        }
        var hashes=new List<string>();
        if(textures!=null)foreach(DictionaryEntry e in textures)hashes.Add(TextureHash(e.Value));
        hashes.Sort(StringComparer.Ordinal);
        result["textures"]=hashes;
        return result;
    }
    static object Value(string name,object value,IDictionary textures) {
        if(value==null)return null;
        if(name=="TexID"&&value is int){var id=(int)value;return textures!=null&&textures.Contains(id)?"texture "+TextureHash(textures[id]):"missing texture "+id;}
        if(value is string||value is bool||value is int||value is float||value is double||value is Enum)return Convert.ToString(value,CultureInfo.InvariantCulture);
        if(value is Vector2){var v=(Vector2)value;return F(v.x)+","+F(v.y);}
        if(value is Color){var c=(Color)value;return F(c.r)+","+F(c.g)+","+F(c.b)+","+F(c.a);}
        return value.GetType().Name;
    }
    static string TextureHash(object container) {
        var data=container.GetType().GetProperty("Data").GetValue(container,null) as byte[];
        if(data==null)return "null";
        using(var sha=SHA256.Create()){var h=sha.ComputeHash(data);var b=new StringBuilder();foreach(var x in h)b.Append(x.ToString("x2"));return b.ToString();}
    }
    // NodesConstraints' constraints in list order: each end as the object NodesConstraints' save would name
    // (the nearest object whose transformTarget encloses it, "camera" for the main camera) and the path below it,
    // and every other public field of the constraint that is a value.
    List<object> NcState() {
        var nc=NcSelf();
        var list=nc.GetType().GetField("_constraints",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(nc) as IList;
        var targets=new Dictionary<Transform,int>();
        foreach(var entry in studio.dicObjectCtrl)targets[entry.Value.guideObject.transformTarget]=entry.Key;
        var result=new List<object>();
        foreach(var constraint in list) {
            var row=new SortedDictionary<string,object>(StringComparer.Ordinal);
            foreach(var field in constraint.GetType().GetFields(BindingFlags.Public|BindingFlags.Instance)) {
                var value=field.GetValue(constraint);
                if(field.Name=="parentTransform"||field.Name=="childTransform"){row[field.Name]=End((Transform)value,targets);continue;}
                if(value is bool||value is string||value is float)row[field.Name]=value is float?F((float)value):Convert.ToString(value,CultureInfo.InvariantCulture);
                else if(value is Vector3){var v=(Vector3)value;row[field.Name]=F(v.x)+","+F(v.y)+","+F(v.z);}
                else if(value is Quaternion){var q=(Quaternion)value;row[field.Name]=F(q.x)+","+F(q.y)+","+F(q.z)+","+F(q.w);}
            }
            result.Add(row);
        }
        return result;
    }
    string End(Transform transform,Dictionary<Transform,int> targets) {
        if(transform==null)return null;
        if(transform==studio.cameraCtrl.mainCmaera.transform)return "camera";
        for(var t=transform;t!=null;t=t.parent){int key;if(targets.TryGetValue(t,out key))return key.ToString(CultureInfo.InvariantCulture)+" "+PathFrom(transform,t);}
        return "unowned "+transform.name;
    }

    // ---- Plug-in authoring ----
    static string BoneXml(Transform bone,Transform root) {
        var p=bone.localPosition;
        return "<object name=\""+SecurityElement(PathFrom(bone,root))+"\" posX=\""+XmlConvert.ToString(p.x+0.01f)+"\" posY=\""+XmlConvert.ToString(p.y+0.02f)+"\" posZ=\""+XmlConvert.ToString(p.z+0.03f)
            +"\" scaleX=\"1.25\" scaleY=\"1.25\" scaleZ=\"1.25\" />";
    }
    static string SecurityElement(string text){return text.Replace("&","&amp;").Replace("\"","&quot;").Replace("<","&lt;").Replace(">","&gt;");}
    Dictionary<string,object> SetMaterial(string name,bool withFloat,bool withColor,byte[] texture) {
        var oci=(OCIItem)Ctrl(name);var controller=MeController();var type=controller.GetType();int id=oci.objectInfo.dicKey;
        var done=new Dictionary<string,object>();
        if(withFloat){var m=MaterialWith(oci,FloatProperties);if(m!=null){var p=m.Value.Key;var mat=m.Value.Value;var value=mat.GetFloat("_"+p)+0.25f;
            Method(type,"SetMaterialFloatProperty",5).Invoke(controller,new object[]{id,mat,p,value,true});done["float"]=p;}}
        if(withColor){var m=MaterialWith(oci,ColorProperties);if(m!=null){
            Method(type,"SetMaterialColorProperty",5).Invoke(controller,new object[]{id,m.Value.Value,m.Value.Key,new Color(0.2f,0.4f,0.6f,1f),true});done["color"]=m.Value.Key;}}
        if(texture!=null){var m=MaterialWith(oci,TextureProperties);if(m!=null){
            Method(type,"SetMaterialTexture",4).Invoke(controller,new object[]{id,m.Value.Value,m.Value.Key,texture});done["texture"]=m.Value.Key;}}
        return done;
    }
    static KeyValuePair<string,Material>? MaterialWith(OCIItem oci,string[] properties) {
        foreach(var property in properties)foreach(var renderer in oci.objectItem.GetComponentsInChildren<Renderer>(true))
            foreach(var material in renderer.sharedMaterials)if(material!=null&&material.HasProperty("_"+property))return new KeyValuePair<string,Material>(property,material);
        return null;
    }
    static byte[] Png(Color color) {
        var texture=new Texture2D(4,4,TextureFormat.RGBA32,false);var pixels=new Color[16];
        for(int i=0;i<pixels.Length;i++)pixels[i]=color;
        texture.SetPixels(pixels);texture.Apply();var bytes=texture.EncodeToPNG();UnityEngine.Object.Destroy(texture);return bytes;
    }
    void AddConstraint(Transform parent,Transform child,Vector3 offset,bool rotation,string alias) {
        var nc=NcSelf();
        MethodInfo add=null;
        foreach(var m in nc.GetType().GetMethods(BindingFlags.NonPublic|BindingFlags.Instance))if(m.Name=="AddConstraint"&&m.GetParameters().Length==10)add=m;
        if(add==null)throw new Exception("NodesConstraints.AddConstraint (10 parameters) not found");
        if(add.Invoke(nc,new object[]{true,parent,child,true,offset,rotation,Quaternion.identity,false,Vector3.one,alias})==null)throw new Exception("NodesConstraints.AddConstraint refused "+alias);
    }
    void SetCardExtended(OCIChar character,string id,int version,Dictionary<string,object> data) {
        var t=FindType("ExtensibleSaveFormat.ExtendedSave");var pt=FindType("ExtensibleSaveFormat.PluginData");
        if(t==null||pt==null)throw new Exception("ExtendedSave types not found");
        var pd=Activator.CreateInstance(pt);pt.GetField("version").SetValue(pd,version);pt.GetField("data").SetValue(pd,data);
        var set=t.GetMethod("SetExtendedDataById",BindingFlags.Public|BindingFlags.Static,null,new[]{typeof(ChaFile),typeof(string),pt},null);
        if(set==null)throw new Exception("ExtendedSave.SetExtendedDataById(ChaFile, string, PluginData) not found");
        set.Invoke(null,new object[]{character.charInfo.chaFile,id,pd});
        var info=character.objectInfo as OICharInfo;
        if(info!=null&&!ReferenceEquals(info.charFile,character.charInfo.chaFile))set.Invoke(null,new object[]{info.charFile,id,pd});
    }
    static object MeController() {
        var type=FindType("KK_Plugins.MaterialEditor.SceneController");if(type==null)throw new Exception("MaterialEditor's SceneController not found");
        var controller=BepInEx.Bootstrap.Chainloader.ManagerObject.transform.GetComponentInChildren(type);
        if(controller==null)throw new Exception("MaterialEditor's SceneController is not on the BepInEx manager object");
        return controller;
    }
    static object NcSelf() {
        var type=FindType("NodesConstraints.NodesConstraints");if(type==null)throw new Exception("NodesConstraints not found");
        var self=type.GetField("_self",BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static).GetValue(null);
        if(self==null)throw new Exception("NodesConstraints._self is null");
        return self;
    }
    static Component PoseController(ObjectCtrlInfo oci) {
        var type=FindType("HSPE.PoseController");if(type==null)throw new Exception("HSPE.PoseController not found");
        return oci.guideObject.transformTarget.GetComponent(type);
    }
    static MethodInfo Method(Type type,string name,int count) {
        foreach(var m in type.GetMethods(BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance))if(m.Name==name&&m.GetParameters().Length==count)return m;
        throw new Exception(type.Name+"."+name+" with "+count+" parameters not found");
    }

    // ---- Scene operations ----
    // One female from a default ChaFileControl (sex 1, as OriginalCameraObjectProbe.LookAtCase builds one; the
    // synthetic parser card has no parameter answers and does not load) through the player's own scene-restore
    // call (OriginalSceneReloadProbe.AddFixtureFemale).
    OCIChar AddFemale(Vector3 position) {
        var cardFile=new ChaFileControl();cardFile.parameter.sex=1;
        var info=new OICharInfo(cardFile,Studio.Studio.GetNewIndex());
        info.changeAmount.pos=position;
        var character=AddObjectFemale.Load(info,null,null);
        if(character==null)throw new Exception("AddObjectFemale.Load returned null for a default female");
        Studio.Studio.AddInfo(info,character);
        return character;
    }
    IEnumerator Load(string path) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(path))throw new Exception("Studio.LoadScene returned false for "+path);
        for(int i=0;i<Settle;i++)yield return null;
    }
    Dictionary<string,object> Save(string name) {
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        string path=Path.Combine(folder,name);
        if(!studio.sceneInfo.Save(path))throw new Exception("Studio.sceneInfo.Save returned false for "+path);
        return K("file",name,"objects",Objects(),"extendedSave",Extended());
    }
    Dictionary<string,object> Snapshot(){return K("objects",Objects(),"extendedSave",Extended());}
    List<object> Objects() {
        var list=new List<object>();var sorted=new List<int>(studio.dicObjectCtrl.Keys);sorted.Sort();
        foreach(var key in sorted) {
            var oci=studio.dicObjectCtrl[key];var info=oci.objectInfo;
            var row=K("key",key,"kind",info.GetType().Name,"parent",oci.parentInfo==null?(object)null:oci.parentInfo.objectInfo.dicKey);
            var item=info as OIItemInfo;if(item!=null){row["group"]=item.group;row["category"]=item.category;row["no"]=item.no;}
            list.Add(row);
        }
        return list;
    }
    ObjectCtrlInfo Ctrl(string name) {
        int key=keys[name];ObjectCtrlInfo oci;
        if(!studio.dicObjectCtrl.TryGetValue(key,out oci))throw new Exception("object "+name+" (key "+key+") is not in the loaded scene");
        return oci;
    }
    void Delete(ObjectCtrlInfo oci) {
        int key=oci.objectInfo.dicKey;
        studio.treeNodeCtrl.DeleteNode(oci.treeNodeObject);
        if(studio.dicObjectCtrl.ContainsKey(key))throw new Exception("TreeNodeCtrl.DeleteNode left object "+key);
    }
    List<object> Duplicate(ObjectCtrlInfo oci) {
        var before=new HashSet<int>(studio.dicObjectCtrl.Keys);
        studio.treeNodeCtrl.SelectSingle(oci.treeNodeObject,false);
        studio.Duplicate();
        var added=new List<int>();
        foreach(var key in studio.dicObjectCtrl.Keys)if(!before.Contains(key))added.Add(key);
        added.Sort();var copies=new List<object>();foreach(var key in added)copies.Add(key);
        if(copies.Count==0)throw new Exception("Studio.Duplicate added no object for "+oci.objectInfo.dicKey);
        return copies;
    }
    static Transform Find(Transform root,string name) {
        if(root.name==name)return root;
        for(int i=0;i<root.childCount;i++){var found=Find(root.GetChild(i),name);if(found!=null)return found;}
        return null;
    }
    static string PathFrom(Transform transform,Transform root) {
        var names=new List<string>();
        for(var t=transform;t!=null&&t!=root;t=t.parent)names.Insert(0,t.name);
        return String.Join("/",names.ToArray());
    }
    static Type FindType(string name) {
        foreach(var asm in AppDomain.CurrentDomain.GetAssemblies()){var t=asm.GetType(name,false);if(t!=null)return t;}
        return null;
    }
    static Dictionary<string,object> Extended() {
        var t=FindType("ExtensibleSaveFormat.ExtendedSave");if(t==null)return null;
        var f=t.GetField("internalSceneDictionary",BindingFlags.NonPublic|BindingFlags.Public|BindingFlags.Static);
        var dict=f==null?null:f.GetValue(null) as IDictionary;if(dict==null)return null;
        var d=new Dictionary<string,object>();
        foreach(DictionaryEntry e in dict) {
            if(e.Value==null){d[(string)e.Key]=null;continue;}
            var pt=e.Value.GetType();var data=pt.GetField("data").GetValue(e.Value) as IDictionary;
            var names=new List<object>();if(data!=null)foreach(DictionaryEntry x in data)names.Add(x.Key);
            d[(string)e.Key]=K("version",pt.GetField("version").GetValue(e.Value),"keys",names);
        }
        return d;
    }
    static string F(float value){return value.ToString("R",CultureInfo.InvariantCulture);}
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
