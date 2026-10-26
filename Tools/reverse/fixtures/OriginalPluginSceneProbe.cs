// ST-T03/ST-S09 plug-in data references (phase A of original_plugin_scene_probe.py): the original CharaStudio
// player, with ExtendedSave, Sideloader, KKAPI and StudioSceneSettings copied into its private root and one
// studio-item zipmod copied into the root's own mods folder, authors a fixture scene that carries
// Sideloader (com.bepis.sideloader.universalautoresolver) and StudioSceneSettings data, then performs the
// edits our writer supports and saves each with SceneInfo.Save(string), the path that runs Sideloader's
// SavePrefix and ExtendedSave's SceneBeingSaved. Every edit starts from a fresh load of the fixture:
//   delete            delete root mod item M1
//   delete-folder     delete folder F (mod item M2, vanilla item V2)
//   duplicate         Studio.Duplicate of folder F, then of root mod item M3
//   delete-duplicate  delete root vanilla item V1 (child mod item M4), then duplicate M3: the copy takes the
//                     lowest free key and the freed dicObject slot, so it is saved where V1 was
//   move              reparent root mod item M3 into folder F
//   route-add         OCIRoute.AddPoint on route R
//   route-delete      delete route R's middle point through its tree node
// Each saved scene is then loaded into an emptied scene and saved again (resave-*.png), which shows the
// trailer CharaStudio writes for a load-then-save of that file. Last, passthrough.png carries one entry under
// an ID no installed plug-in owns (values of every integer width, a float, a double, a string and bytes);
// passthrough-delete.png loads it, deletes M1 and saves, which shows ExtendedSave's carry-over of an entry
// no plug-in rewrites. Only the private root's files and the probe's own scenes are read or written.
//
// Phase B runs when the plug-in folder holds reload-input\fixture.png (phase A's fixture), with KKPE, NodesConstraints
// and MaterialEditor copied in as well. Compiled together with PluginSceneRules.cs, PluginSceneRuleParity.cs and
// PluginSceneSurvey.cs. Instead of authoring, it loads phase A's fixture and saves it as fixture.png, which adds the
// three plug-ins' entries for that scene, then makes the same edits of that fixture and two more that leave every
// item in place (delete-light deletes light L; add-folder adds a folder at the root with AddObjectFolder.Add), the
// resaves and the passthrough pair. Then:
//   ours        loads each reload-input\ours-<edit>.png (our writer's export of phase A's edit) and saves it again
//   nil         loads reload-input\fixture-nil.png (phase A's fixture plus nil MaterialEditor and example.nil
//               entries) and saves it again
//   survey      last, and nothing is saved after it: repeats the rule parity check on reload-input\corpus.txt with
//               this player's compiler, and only when every case agrees runs PluginSceneSurvey over the install's
//               scene folder (reload-input\survey.txt: folder, seconds bound, per-file byte bound) into survey2.json.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using BepInEx;
using Studio;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.pluginsceneprobe", "Ikkoku plug-in scene probe", "1.0.0")]
public sealed class OriginalPluginSceneProbe:BaseUnityPlugin {
    const int Settle=10;
    const int ModSlotBase=100000000; // Sideloader's UniversalAutoResolver.BaseSlotID: resolved studio IDs start here
    static readonly string[] Required={"com.bepis.bepinex.extendedsave","com.bepis.bepinex.sideloader","marco.kkapi",
        "com.deathweasel.bepinex.studioscenesettings","gravydevsupreme.xunity.resourceredirector"};
    static readonly string[] RequiredReload={"com.joan6694.kkplugins.kkpe","com.joan6694.illusionplugins.nodesconstraints","com.deathweasel.bepinex.materialeditor"};
    static readonly string[] Edits={"delete","delete-folder","duplicate","delete-duplicate","move","route-add","route-delete"};
    static readonly string[] ReloadEdits={"delete-light","add-folder"};
    // Phase A's fixture keys (its plugin-scene-trace.json), checked against the loaded scene in phase B.
    static readonly object[] FixtureKeys={"F",0,"V1",1,"M1",2,"M2",3,"V2",4,"M3",5,"M4",6,"R",7,"R.p0",8,"R.p1",10,"R.p2",12,"C",14,"L",15};
    const string PassthroughID="org.ikkoku.probe.passthrough";
    string folder,fixture,input;
    bool reload;
    Studio.Studio studio;
    readonly Dictionary<string,object> cases=new Dictionary<string,object>();
    readonly Dictionary<string,int> keys=new Dictionary<string,int>();
    string modItem,vanillaItem;
    IEnumerator Start() {
        string here=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        folder=Path.Combine(here,"reload");Directory.CreateDirectory(folder);
        input=Path.Combine(here,"reload-input");reload=File.Exists(Path.Combine(input,"fixture.png"));
        string error=null;int waited=0;
        for(;waited<3600;waited++){if(Ready())break;yield return null;}
        if(waited>=3600)error="Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames";
        for(int i=0;i<600&&error==null&&SettingsSet("MapMasking")==null;i++)yield return null; // StudioSceneSettings builds its sets on the Studio scene load
        for(int i=0;i<60&&error==null;i++)yield return null;
        studio=Singleton<Studio.Studio>.Instance;
        var plugins=new Dictionary<string,object>();
        foreach(var entry in BepInEx.Bootstrap.Chainloader.PluginInfos)plugins[entry.Key]=entry.Value.Metadata.Version.ToString();
        var required=new List<string>(Required);if(reload)required.AddRange(RequiredReload);
        foreach(var id in required)if(error==null&&!plugins.ContainsKey(id))error="required plug-in "+id+" did not load";
        if(error==null&&SettingsSet("MapMasking")==null)error="StudioSceneSettings did not build its scene settings within 600 frames";
        var steps=new List<KeyValuePair<string,Func<IEnumerator>>>();
        if(reload)steps.Add(new KeyValuePair<string,Func<IEnumerator>>("base",Base));
        else steps.Add(new KeyValuePair<string,Func<IEnumerator>>("author",Author));
        foreach(var label in Labels()){var l=label;steps.Add(new KeyValuePair<string,Func<IEnumerator>>(l,()=>Edit(l)));}
        steps.Add(new KeyValuePair<string,Func<IEnumerator>>("resave",Resaves));
        steps.Add(new KeyValuePair<string,Func<IEnumerator>>("passthrough",Passthrough));
        if(reload) {
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("ours",Ours));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("nil",Nil));
            steps.Add(new KeyValuePair<string,Func<IEnumerator>>("survey",Survey)); // last: nothing is saved after it
        }
        foreach(var step in steps) {
            if(error!=null)break;
            IEnumerator run=null;
            try{run=step.Value();}catch(Exception e){error=step.Key+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error=step.Key+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        try{File.WriteAllText(Path.Combine(folder,"plugin-scene-trace.json"),J(K("schemaVersion",1,"phase",reload?"B":"A","plugins",plugins,"keys",keys,"modItem",modItem,"vanillaItem",vanillaItem,"cases",cases)));}
        catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"plugins",plugins,
            "phase",reload?"B":"A",
            "scope",reload?"phase B: the phase A fixture saved again with KKPE, NodesConstraints and MaterialEditor loaded, CharaStudio's own saves of each edit of it, the load-then-save of every saved scene, of our exports and of the nil-entry fixture, ExtendedSave's carry-over of an entry no plug-in owns, and last the counts-only scene survey"
                :"CharaStudio's own saves of the plug-in data fixture and of each supported edit, the load-then-save of every saved scene, and ExtendedSave's carry-over of an entry no plug-in owns")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Manager.Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Manager.Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    // The fixture: F folder, V1 vanilla item (child M4 mod item), M1 mod item, M2 mod item and V2 vanilla item in F,
    // M3 mod item, R route with three points, C camera, L light, in this root order. Vanilla items sit between the
    // mod items so a deletion shifts Sideloader's per-type SceneObjectOrder of the mod items after it.
    IEnumerator Author() {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("expected an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var fold=AddObjectFolder.Add();if(fold==null)throw new Exception("AddObjectFolder.Add returned null");
        fold.name="IKKOKU-PD-F";keys["F"]=fold.objectInfo.dicKey;
        var v1=AddVanilla(new Vector3(-1f,0f,0f));keys["V1"]=v1.objectInfo.dicKey;
        var m1=AddMod(new Vector3(-0.5f,0f,0f));keys["M1"]=m1.objectInfo.dicKey;
        var m2=AddMod(new Vector3(0f,0f,0.5f));keys["M2"]=m2.objectInfo.dicKey;Parent(m2,fold);
        var v2=AddVanilla(new Vector3(0f,0f,-0.5f));keys["V2"]=v2.objectInfo.dicKey;Parent(v2,fold);
        var m3=AddMod(new Vector3(0.5f,0f,0f));keys["M3"]=m3.objectInfo.dicKey;
        var m4=AddMod(new Vector3(-1f,0.5f,0f));keys["M4"]=m4.objectInfo.dicKey;Parent(m4,v1);
        var route=AddObjectRoute.Add();if(route==null)throw new Exception("AddObjectRoute.Add returned null");
        route.routeInfo.name="IKKOKU-PD-R";keys["R"]=route.objectInfo.dicKey;
        for(int i=0;i<2;i++)if(route.AddPoint()==null)throw new Exception("OCIRoute.AddPoint returned null");
        for(int i=0;i<route.listPoint.Count;i++){var ca=route.listPoint[i].routePointInfo.changeAmount;ca.pos=new Vector3(i,0f,1f);ca.OnChange();keys["R.p"+i]=route.listPoint[i].objectInfo.dicKey;}
        var cam=AddObjectCamera.Add();if(cam==null)throw new Exception("AddObjectCamera.Add returned null");
        cam.name="IKKOKU-PD-C";keys["C"]=cam.objectInfo.dicKey;
        var lights=new List<int>(Singleton<Studio.Info>.Instance.dicLightLoadInfo.Keys);lights.Sort();
        var light=AddObjectLight.Add(lights[0]);if(light==null)throw new Exception("AddObjectLight.Add returned null");
        keys["L"]=light.objectInfo.dicKey;
        // StudioSceneSettings: masking on, near clip and shadow distance off their defaults, far clip at its default (saved as nil).
        SetSetting("MapMasking",true);SetSetting("NearClipPlane",0.05f);SetSetting("ShadowDistance",250f);
        for(int i=0;i<Settle;i++)yield return null;
        var saved=Save("fixture.png");fixture=Path.Combine(folder,"fixture.png");
        cases["author"]=K("label","author","saved",saved);
    }
    List<string> Labels(){var labels=new List<string>(Edits);if(reload)labels.AddRange(ReloadEdits);return labels;}
    // Phase B: phase A's fixture, loaded and saved with the full plug-in set, is this phase's fixture.
    IEnumerator Base() {
        for(int i=0;i<FixtureKeys.Length;i+=2)keys[(string)FixtureKeys[i]]=(int)FixtureKeys[i+1];
        var load=Load(Path.Combine(input,"fixture.png"));while(load.MoveNext())yield return load.Current;
        var loaded=Snapshot();
        var expected=new[]{"F","OIFolderInfo","V1","OIItemInfo","M1","OIItemInfo","M2","OIItemInfo","V2","OIItemInfo","M3","OIItemInfo","M4","OIItemInfo","R","OIRouteInfo","C","OICameraInfo","L","OILightInfo"};
        for(int i=0;i<expected.Length;i+=2){var kind=Ctrl(expected[i]).objectInfo.GetType().Name;if(kind!=expected[i+1])throw new Exception("phase A key of "+expected[i]+" holds "+kind);}
        var route=(OCIRoute)Ctrl("R");
        for(int i=0;i<3;i++)if(route.listPoint.Count!=3||route.listPoint[i].objectInfo.dicKey!=keys["R.p"+i])throw new Exception("route R's points differ from phase A's");
        var saved=Save("fixture.png");fixture=Path.Combine(folder,"fixture.png");
        cases["base"]=K("label","base","loaded",loaded,"saved",saved);
    }
    IEnumerator Edit(string label) {
        var load=Load(fixture);while(load.MoveNext())yield return load.Current;
        var loaded=Snapshot();
        var note=new Dictionary<string,object>();
        if(label=="delete")Delete(Ctrl("M1"));
        else if(label=="delete-folder")Delete(Ctrl("F"));
        else if(label=="duplicate"){note["copies"]=Duplicate(Ctrl("F"));var more=Duplicate(Ctrl("M3"));((List<object>)note["copies"]).AddRange(more);}
        else if(label=="delete-duplicate"){Delete(Ctrl("V1"));note["copies"]=Duplicate(Ctrl("M3"));}
        else if(label=="move")Parent(Ctrl("M3"),Ctrl("F"));
        else if(label=="route-add"){var route=(OCIRoute)Ctrl("R");var point=route.AddPoint();if(point==null)throw new Exception("OCIRoute.AddPoint returned null");note["addedPoint"]=point.objectInfo.dicKey;}
        else if(label=="route-delete"){
            var route=(OCIRoute)Ctrl("R");int count=route.listPoint.Count;var point=route.listPoint[1];note["deletedPoint"]=point.objectInfo.dicKey;
            studio.treeNodeCtrl.DeleteNode(point.treeNodeObject);
            if(route.listPoint.Count!=count-1)throw new Exception("route point delete left "+route.listPoint.Count+" points, expected "+(count-1));
        }
        else if(label=="delete-light")Delete(Ctrl("L"));
        else if(label=="add-folder"){var added=AddObjectFolder.Add();if(added==null)throw new Exception("AddObjectFolder.Add returned null");note["added"]=added.objectInfo.dicKey;}
        else throw new Exception("unknown edit "+label);
        for(int i=0;i<Settle;i++)yield return null;
        var saved=Save("edit-"+label+".png");
        cases[label]=K("label",label,"loaded",loaded,"note",note,"saved",saved);
    }
    IEnumerator Resaves() {
        var names=new List<string>{"fixture.png"};
        foreach(var label in Labels())names.Add("edit-"+label+".png");
        var list=new List<object>();
        foreach(var name in names) {
            var load=Load(Path.Combine(folder,name));while(load.MoveNext())yield return load.Current;
            var loaded=Snapshot();
            list.Add(K("source",name,"loaded",loaded,"saved",Save("resave-"+name)));
        }
        cases["resave"]=list;
    }
    IEnumerator Passthrough() {
        var load=Load(fixture);while(load.MoveNext())yield return load.Current;
        var data=new Dictionary<string,object>();
        data["fixint"]=5;data["uint8"]=200;data["uint16"]=300;data["uint32"]=70000;data["negfix"]=-5;data["int8"]=-100;data["int16"]=-1000;data["int32"]=-70000;
        data["int64"]=5000000000L;data["single"]=0.5f;data["double"]=0.25;data["text"]="ikkoku";data["bytes"]=new byte[]{1,2,3};
        data["keys"]=new List<object>{keys["M1"],keys["M3"]};data["flag"]=true;data["nothing"]=null;
        SetExtended(PassthroughID,7,data);
        var first=Save("passthrough.png");
        load=Load(Path.Combine(folder,"passthrough.png"));while(load.MoveNext())yield return load.Current;
        var loaded=Snapshot();
        Delete(Ctrl("M1"));
        for(int i=0;i<Settle;i++)yield return null;
        cases["passthrough"]=K("label","passthrough","saved",first,"loaded",loaded,"deleted",Save("passthrough-delete.png"));
    }
    // Phase B: our writer's exports of phase A's edits, loaded and saved by CharaStudio with the full plug-in set.
    IEnumerator Ours() {
        var names=new List<string>();
        foreach(var path in Directory.GetFiles(input,"ours-*.png"))names.Add(Path.GetFileName(path));
        names.Sort(StringComparer.Ordinal);
        if(names.Count==0)throw new Exception("no ours-*.png in reload-input");
        var list=new List<object>();
        foreach(var name in names) {
            var load=Load(Path.Combine(input,name));while(load.MoveNext())yield return load.Current;
            var loaded=Snapshot();
            list.Add(K("source",name,"loaded",loaded,"saved",Save("resave-"+name)));
        }
        cases["ours"]=list;
    }
    // Phase B: nil entries (a MaterialEditor one and one no plug-in owns) on phase A's fixture.
    IEnumerator Nil() {
        var load=Load(Path.Combine(input,"fixture-nil.png"));while(load.MoveNext())yield return load.Current;
        var loaded=Snapshot();
        cases["nil"]=K("label","nil","loaded",loaded,"saved",Save("resave-fixture-nil.png"));
    }
    // Phase B, last: the counts-only scene survey. Nothing is saved after it.
    IEnumerator Survey() {
        var parameters=File.ReadAllLines(Path.Combine(input,"survey.txt"));
        string scenes=parameters[0].Trim();
        double seconds=Double.Parse(parameters[1].Trim(),CultureInfo.InvariantCulture);long bound=Int64.Parse(parameters[2].Trim(),CultureInfo.InvariantCulture);
        int count;var mismatches=PluginSceneRuleParity.Check(File.ReadAllText(Path.Combine(input,"corpus.txt")),out count);
        var result=K("schemaVersion",1,"parityCases",count,"parityMismatches",mismatches.Count,"folderExists",Directory.Exists(scenes));
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
        File.WriteAllText(Path.Combine(folder,"survey2.json"),J(result));
        cases["survey"]=K("parityCases",count,"parityMismatches",mismatches.Count);
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
        var roots=new List<object>();foreach(var entry in studio.sceneInfo.dicObject)roots.Add(entry.Key); // the enumeration SceneInfo.Save and Sideloader both walk
        string path=Path.Combine(folder,name);
        if(!studio.sceneInfo.Save(path))throw new Exception("Studio.sceneInfo.Save returned false for "+path);
        return K("file",name,"rootOrder",roots,"objects",Objects(),"extendedSave",Extended(),"sceneSettings",Settings());
    }
    Dictionary<string,object> Snapshot(){var roots=new List<object>();foreach(var entry in studio.sceneInfo.dicObject)roots.Add(entry.Key);return K("rootOrder",roots,"objects",Objects(),"extendedSave",Extended(),"sceneSettings",Settings());}
    // Every live object: kind, parent key and, for items and lights, the catalog IDs (a resolved mod item's no is >= 100000000).
    List<object> Objects() {
        var list=new List<object>();var sorted=new List<int>(studio.dicObjectCtrl.Keys);sorted.Sort();
        foreach(var key in sorted) {
            var oci=studio.dicObjectCtrl[key];var info=oci.objectInfo;
            var row=K("key",key,"kind",info.GetType().Name,"parent",oci.parentInfo==null?(object)null:oci.parentInfo.objectInfo.dicKey);
            var item=info as OIItemInfo;if(item!=null){row["group"]=item.group;row["category"]=item.category;row["no"]=item.no;}
            var light=info as OILightInfo;if(light!=null)row["no"]=light.no;
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
        studio.treeNodeCtrl.DeleteNode(oci.treeNodeObject); // the tree's Delete: OnDeleteNode, OnDelete, Studio.DeleteInfo (releases the key)
        if(studio.dicObjectCtrl.ContainsKey(key))throw new Exception("TreeNodeCtrl.DeleteNode left object "+key);
    }
    List<object> Duplicate(ObjectCtrlInfo oci) {
        var before=new HashSet<int>(studio.dicObjectCtrl.Keys);
        studio.treeNodeCtrl.SelectSingle(oci.treeNodeObject,false);
        studio.Duplicate();
        var copies=new List<object>();var added=new List<int>();
        foreach(var key in studio.dicObjectCtrl.Keys)if(!before.Contains(key))added.Add(key);
        added.Sort();foreach(var key in added)copies.Add(key);
        if(copies.Count==0)throw new Exception("Studio.Duplicate added no object for "+oci.objectInfo.dicKey);
        return copies;
    }
    void Parent(ObjectCtrlInfo child,ObjectCtrlInfo parent) {
        studio.treeNodeCtrl.SetParent(child.treeNodeObject,parent.treeNodeObject);
        if(child.parentInfo!=parent)throw new Exception("TreeNodeCtrl.SetParent did not attach "+child.objectInfo.dicKey+" to "+parent.objectInfo.dicKey);
    }
    OCIItem AddMod(Vector3 position){return AddItem(true,position);}
    OCIItem AddVanilla(Vector3 position){return AddItem(false,position);}
    // The first catalog item (group, category, no ascending) that loads: a Sideloader-resolved one (no >= 100000000) or a
    // vanilla one. The pick is remembered, so every mod item in the fixture is the same catalog item.
    OCIItem AddItem(bool mod,Vector3 position) {
        string picked=mod?modItem:vanillaItem;
        var info=Singleton<Studio.Info>.Instance.dicItemLoadInfo;var tried=new List<string>();
        var groups=new List<int>(info.Keys);groups.Sort();
        foreach(var g in groups){var cats=new List<int>(info[g].Keys);cats.Sort();
            foreach(var c in cats){var nos=new List<int>(info[g][c].Keys);nos.Sort();
                foreach(var n in nos) {
                    if((n>=ModSlotBase)!=mod)continue;
                    string id=g+"/"+c+"/"+n;
                    if(picked!=null&&picked!=id)continue;
                    var e=info[g][c][n];
                    if(picked==null&&(e.isAnime||!String.IsNullOrEmpty(e.childRoot)||mod&&!(String.IsNullOrEmpty(e.manifest)||e.manifest=="abdata")))continue; // the run.ps1 zipmod pick has such an item
                    if(tried.Count>=40)throw new Exception("no "+(mod?"mod":"vanilla")+" item loaded in 40 tries: "+String.Join(", ",tried.ToArray()));
                    OCIItem item=null;
                    try{item=AddObjectItem.Add(g,c,n);}catch(Exception failure){tried.Add(id+" ("+failure.GetType().Name+")");continue;} // a bundle or manifest the player cannot load throws from AssetBundleManager
                    tried.Add(id);
                    if(item==null)continue;
                    if(mod)modItem=id;else vanillaItem=id;
                    item.itemInfo.changeAmount.pos=position;item.itemInfo.changeAmount.OnChange();
                    return item;
                }}}
        throw new Exception("no loadable "+(mod?"mod (Sideloader-resolved)":"vanilla")+" item in the catalog; tried "+String.Join(", ",tried.ToArray()));
    }
    static Type FindType(string name) {
        foreach(var asm in AppDomain.CurrentDomain.GetAssemblies()){var t=asm.GetType(name,false);if(t!=null)return t;}
        return null;
    }
    static object SettingsSet(string field) {
        var t=FindType("KK_Plugins.StudioSceneSettings.SceneController");if(t==null)return null;
        var f=t.GetField(field,BindingFlags.Public|BindingFlags.Static);return f==null?null:f.GetValue(null);
    }
    static void SetSetting(string field,object value) {
        var set=SettingsSet(field);if(set==null)throw new Exception("StudioSceneSettings has no "+field+" set");
        set.GetType().GetProperty("Value").SetValue(set,value,null);
        if(!Equals(set.GetType().GetProperty("Value").GetValue(set,null),value))throw new Exception("StudioSceneSettings "+field+" did not take "+value);
    }
    static Dictionary<string,object> Settings() {
        var d=new Dictionary<string,object>();
        foreach(var field in new[]{"MapMasking","NearClipPlane","FarClipPlane","ShadowDistance"}) {
            var set=SettingsSet(field);if(set==null){d[field]=null;continue;}
            var t=set.GetType();var initial=t.GetProperty("InitialValue");
            d[field]=K("value",t.GetProperty("Value").GetValue(set,null),"initial",initial==null?null:initial.GetValue(set,null));
        }
        return d;
    }
    // ExtendedSave's live scene dictionary (the one SceneInfo.Save serializes): entry ID, PluginData version and data keys.
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
    static void SetExtended(string id,int version,Dictionary<string,object> data) {
        var t=FindType("ExtensibleSaveFormat.ExtendedSave");var pt=FindType("ExtensibleSaveFormat.PluginData");
        if(t==null||pt==null)throw new Exception("ExtendedSave types not found");
        var pd=Activator.CreateInstance(pt);pt.GetField("version").SetValue(pd,version);pt.GetField("data").SetValue(pd,data);
        t.GetMethod("SetSceneExtendedDataById",BindingFlags.Public|BindingFlags.Static).Invoke(null,new object[]{id,pd});
    }
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
