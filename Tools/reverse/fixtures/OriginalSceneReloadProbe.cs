// ST-T03 reload acceptance (our side): reload the scene records our app exported and record what the
// original CharaStudio player shows after loading them. Scene records are uploaded beside the plugin as
// reload-*.png (the route probe's upload pattern); only those files are read. A synthetic fixture card
// uploaded beside the plugin as author-card.png (driver --author-character, the ST-T01 source scene)
// first makes the player author scene-char.png from it: one female, FK disabled, default pose. An
// author-scenes.txt beside the card (driver --author-scenes) instead lists which fixture scenes to author
// from that card: "char" (scene-char.png), "route-children" (scene-route-children.png: one playing route
// whose children are a folder and the fixture female), "neck-target" (scene-neck-target.png: two
// fixture females, neck pattern TARGET and AWAY, eyes pattern TARGET) and "mirrored-camera"
// (scene-mirrored-camera.png: a camera under a scalable item with scale (-1, 1, 1) and a control camera
// under an unmirrored copy of that item; it needs no card, so author-scenes.txt alone starts author mode
// when it lists only card-free scenes); each is read back into an emptied scene and traced. The ST-T11
// route-edit records (reload-route-edit.png, reload-route-children-edit.png) are also traced frame by frame
// after their load, with the route point panel's prefab values. No installed cards, saves, media or
// third-party plug-ins are read or written.
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
        var sceneList=Path.Combine(dir,"author-scenes.txt"); // driver --author-scenes: the fixture scenes to author; absent = scene-char.png only
        bool author=File.Exists(card)||File.Exists(sceneList); // a card-free scene list (mirrored-camera) starts author mode without a card
        if(error==null&&files.Count==0&&!author)error="no reload-*.png scene records and no author-card.png or author-scenes.txt beside the plugin";
        var authored=new List<string>();
        if(error==null&&author) {
            if(File.Exists(sceneList)){foreach(var line in File.ReadAllLines(sceneList)){var name=line.Trim();if(name.Length>0)authored.Add(name);}}
            else authored.Add("char");
            if(authored.Count==0)error="author-scenes.txt lists no fixture scene";
            foreach(var name in authored)if(error==null&&name!="mirrored-camera"&&!File.Exists(card))error="author scene \""+name+"\" needs author-card.png beside the plugin";
        }
        foreach(var scene in authored) {
            if(error!=null)break;
            IEnumerator run=null;
            try{
                if(scene=="char")run=AuthorCase(card);
                else if(scene=="route-children")run=AuthorRouteChildren(card);
                else if(scene=="neck-target")run=AuthorNeckTarget(card);
                else if(scene=="mirrored-camera")run=AuthorMirroredCamera();
                else throw new Exception("unknown fixture scene \""+scene+"\" (char, route-children, neck-target or mirrored-camera)");
            }catch(Exception e){error="author "+scene+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error="author "+scene+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        foreach(var file in files) {
            if(error!=null)break;
            IEnumerator run=null;
            try{run=ReloadCase(file);}catch(Exception e){error=Path.GetFileName(file)+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error=Path.GetFileName(file)+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        try{File.WriteAllText(Path.Combine(folder,"reload-trace.json"),J(K("schemaVersion",1,"framesPerPhase",Frames,"cases",cases)));}catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"mode",mode,
            "voiceRepair",voiceRepair,"authorScenes",authored,
            "scope","Our exported scene records reloaded in the original player: per-object name, objectInfo and tree-node visibility, per-camera active flag and the load view-camera winner, per-route playing state and childRoot position, per-object parent, world position and rotation, lossy scale, authored change amount and saved child lists, the root dictionary order and sun caster, and per-character FK state, active FK groups, saved and live bone transforms and look patterns with the neck/head the look controllers drive; the fixture-card author mode saves scene-char.png from one female in the default pose with FK disabled, and with author-scenes.txt also scene-route-children.png (a playing route whose children are a folder and the female) and scene-neck-target.png (two females, neck TARGET and AWAY, eyes TARGET, traced under the saved camera and orbited +/-"+LookYaw+" degrees) and scene-mirrored-camera.png (camera objects under a scalable item with scale (-1, 1, 1) and under an unmirrored copy, the render camera recorded while each is active, after toggling off and after re-activating the mirrored one); every loaded route's point, aid and setting records and the line it built, and for the route-edit labels a per-frame trace (at least "+RouteTraceFrames+" frames and "+RouteTraceSeconds+" s) of every route's childRoot and children with the route point panel's speed slider range, ease list and point limit option; this player copy boots with a Manager.Voice whose Awake threw, and the voiceRepair field records replacing its null voice table with an empty one so the load range check (voice numbers only, never FK or bone data) can run; no installed cards, saves or media")));
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
        AddFixtureFemale(card);
        var authored=Record();
        cases["author"]=K("label","author","card",Path.GetFileName(card),"scene","scene-char.png","afterLoad",authored,"settled",authored);
        string scene=SaveScene("scene-char.png");
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
    // One female from the synthetic fixture card through the player's own scene-restore call (see AuthorCase).
    OCIChar AddFixtureFemale(string card) {
        var cardFile=new ChaFileControl();cardFile.skipRangeCheck=true;
        if(!cardFile.LoadCharaFile(card,byte.MaxValue,true))throw new Exception("ChaFileControl.LoadCharaFile returned false for "+card);
        var info=new OICharInfo(cardFile,Studio.Studio.GetNewIndex());
        var character=AddObjectFemale.Load(info,null,null);
        if(character==null)throw new Exception("AddObjectFemale.Load returned null for "+card);
        Studio.Studio.AddInfo(info,character); // Load registers only the ctrl info (it is the _addInfo:false scene-restore path); sceneInfo.dicObject is what Save serializes
        return character;
    }
    // The route probe's save rule: every object's own save preprocessing (a character writes its live neck
    // and eye look state into neckByteData/eyesByteData there), and the view belongs to the record.
    string SaveScene(string name) {
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        string scene=Path.Combine(folder,name);
        if(!studio.sceneInfo.Save(scene))throw new Exception("Studio.sceneInfo.Save returned false for "+scene);
        return scene;
    }
    // ST-T11 route children fixture: one looping four-point route, saved playing, whose two children are a
    // folder and the fixture female. They are parented the way the workspace tree's drag does it
    // (TreeNodeCtrl.SetParent -> Studio.OnParentage -> OCIRoute.OnAttach, which records each child in
    // routeInfo.child under the route's childRoot) while the route is stopped, so their saved local
    // placement is relative to point 0. The read-back loads the saved scene into an emptied scene (the load
    // path plays an active route) and traces every object's world position at load and RouteFrames later.
    const int RouteFrames=60;
    static readonly Vector3[] RoutePoints={new Vector3(0f,0f,0f),new Vector3(1.2f,0f,0f),new Vector3(1.2f,0f,1.2f),new Vector3(0f,0f,1.2f)};
    IEnumerator AuthorRouteChildren(string card) {
        mode="author";
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("route-children expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var route=AddObjectRoute.Add();
        if(route==null)throw new Exception("AddObjectRoute.Add returned null (route asset failed to load)");
        route.routeInfo.name="IKKOKU-RC";
        route.routeInfo.changeAmount.pos=Vector3.zero;route.routeInfo.changeAmount.rot=Vector3.zero;route.routeInfo.changeAmount.OnChange();
        for(int i=1;i<RoutePoints.Length;i++)if(route.AddPoint()==null)throw new Exception("OCIRoute.AddPoint returned null");
        if(route.listPoint.Count!=RoutePoints.Length)throw new Exception("route holds "+route.listPoint.Count+" points, expected "+RoutePoints.Length);
        for(int i=0;i<RoutePoints.Length;i++){var ca=route.listPoint[i].routePointInfo.changeAmount;ca.pos=RoutePoints[i];ca.OnChange();}
        route.routeInfo.loop=true;
        var fold=AddObjectFolder.Add();
        if(fold==null)throw new Exception("AddObjectFolder.Add returned null");
        fold.name="IKKOKU-RC-F";
        fold.objectInfo.changeAmount.pos=new Vector3(0f,0.5f,0f);fold.objectInfo.changeAmount.rot=Vector3.zero;fold.objectInfo.changeAmount.OnChange();
        var female=AddFixtureFemale(card);
        female.objectInfo.changeAmount.pos=Vector3.zero;female.objectInfo.changeAmount.OnChange();
        for(int i=0;i<3;i++)yield return null;
        foreach(var child in new ObjectCtrlInfo[]{fold,female}) {
            studio.treeNodeCtrl.SetParent(child.treeNodeObject,route.treeNodeObject);
            if(child.parentInfo!=route||!route.routeInfo.child.Contains(child.objectInfo))
                throw new Exception("TreeNodeCtrl.SetParent did not attach object "+child.objectInfo.dicKey+" to the route");
        }
        if(route.routeInfo.child.Count!=2)throw new Exception("route holds "+route.routeInfo.child.Count+" children, expected the folder and the female");
        if(!route.Play())throw new Exception("OCIRoute.Play returned false");
        var authored=Record();
        cases["route-children-author"]=K("label","route-children-author","card",Path.GetFileName(card),"scene","scene-route-children.png","afterLoad",authored,"settled",authored);
        string scene=SaveScene("scene-route-children.png"); // saved right after Play, like the route probe: active=true
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("route-children expects an empty scene before the read-back, found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(scene))throw new Exception("Studio.LoadScene returned false for "+scene);
        var afterLoad=Record();float loadTime=Time.time;
        for(int i=0;i<RouteFrames;i++)yield return null;
        var moved=Record();
        cases["route-children"]=K("label","route-children","scene","scene-route-children.png","afterLoad",afterLoad,"settled",moved,
            "settledFrames",RouteFrames,"settledSeconds",Time.time-loadTime);
    }
    // ST-T07 neck look fixture: two fixture females side by side, neck pattern 1 (kocchi, TARGET) and 2
    // (acchi, AWAY), both eyes pattern 1 (kocchi, TARGET), set through OCIChar's own pattern calls (the
    // MPCharCtrl look buttons) and given LookFrames frames to run before the save, so the saved neck bytes
    // hold the controllers' live state. The read-back loads it into an emptied scene and records both
    // characters' neck/head under the saved camera and after orbiting the Studio camera LookYaw degrees to
    // either side (CameraControl.Import of the saved view with rotate.y moved), LookFrames frames each.
    const int LookFrames=120;
    const float LookYaw=60f;
    static readonly int[] NeckPatterns={1,2};
    const int EyesPattern=1;
    IEnumerator AuthorNeckTarget(string card) {
        mode="author";
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("neck-target expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var characters=new List<OCIChar>();
        for(int i=0;i<NeckPatterns.Length;i++) {
            var female=AddFixtureFemale(card);
            female.objectInfo.changeAmount.pos=new Vector3(i==0?-0.5f:0.5f,0f,0f);female.objectInfo.changeAmount.OnChange();
            female.ChangeLookNeckPtn(NeckPatterns[i]);
            female.ChangeLookEyesPtn(EyesPattern);
            characters.Add(female);
        }
        for(int i=0;i<LookFrames;i++)yield return null;
        for(int i=0;i<characters.Count;i++) {
            var status=characters[i].charFileStatus;
            if(status.neckLookPtn!=NeckPatterns[i]||status.eyesLookPtn!=EyesPattern)
                throw new Exception("character "+characters[i].objectInfo.dicKey+" holds neck "+status.neckLookPtn+" eyes "+status.eyesLookPtn+" before the save");
        }
        var authored=Record();
        cases["neck-target-author"]=K("label","neck-target-author","card",Path.GetFileName(card),"scene","scene-neck-target.png","afterLoad",authored,"settled",authored);
        string scene=SaveScene("scene-neck-target.png");
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("neck-target expects an empty scene before the read-back, found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(scene))throw new Exception("Studio.LoadScene returned false for "+scene);
        var afterLoad=Record();
        var saved=studio.cameraCtrl.Export();
        var phases=new List<object>();
        foreach(float yaw in new[]{0f,LookYaw,-LookYaw}) {
            var view=new Studio.CameraControl.CameraData(saved);view.rotate.y=saved.rotate.y+yaw;
            studio.cameraCtrl.Import(view);
            for(int i=0;i<LookFrames;i++)yield return null;
            phases.Add(K("cameraYawOffset",yaw,"frames",LookFrames,"cameraRotate",V(studio.cameraCtrl.Export().rotate),"snapshot",Record()));
        }
        studio.cameraCtrl.Import(saved);
        cases["neck-target"]=K("label","neck-target","scene","scene-neck-target.png","afterLoad",afterLoad,"settled",((Dictionary<string,object>)phases[0])["snapshot"],"orbit",phases);
    }
    // R4 mirrored camera parent (ST-A06): two copies of the first scalable catalog item without a named child
    // root (the camera probe's PickScalableItem rule, so the item itself is the child root), one with scale
    // (-1, 1, 1) and one with (1, 1, 1), each holding one camera object at the same local placement. The scale
    // goes through ChangeAmount.scale, the setter the Studio scale input (GuideInput.OnEndEditScale) and drag
    // (GuideScale.OnDrag) call; both of those clamp every component to >= 0.01 first, so a mirrored item comes
    // only from a scene file or code. The saved view is a distinct CameraControl.Import, the mirrored camera
    // is activated with ChangeCamera (the tree-node toggle) and saved active, so the read-back loads with it
    // as the view camera. The read-back then records the render camera (Camera.main) and both camera objects
    // MirrorFrames end-of-frame snapshots per phase: as loaded, after switching to the control camera, after
    // toggling the control off (the saved view), after re-activating the mirrored camera and after toggling it off.
    const int MirrorFrames=8;
    static readonly Vector3 MirrorScale=new Vector3(-1f,1f,1f);
    static readonly Vector3 MirrorCameraPosition=new Vector3(0.3f,0.6f,-0.9f),MirrorCameraRotation=new Vector3(10f,70f,25f);
    const string MirrorName="IKKOKU-MIRROR",ControlName="IKKOKU-CONTROL";
    IEnumerator AuthorMirroredCamera() {
        mode="author";
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("mirrored-camera expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        var view=new Studio.CameraControl.CameraData();
        view.pos=new Vector3(0.2f,1.1f,0.3f);view.rotate=new Vector3(15f,200f,0f);view.distance=new Vector3(0f,0f,-3f);view.parse=35f;
        studio.cameraCtrl.Import(view); // becomes the record's cameraSaveData, the view a toggle-off restores
        int g,c,n;string picked=PickScalableItem(out g,out c,out n);
        var mirror=AddScaledItem(g,c,n,new Vector3(-0.6f,0.3f,0.6f),MirrorScale);
        var control=AddScaledItem(g,c,n,new Vector3(0.6f,0.3f,0.6f),Vector3.one);
        foreach(var pair in new[]{new KeyValuePair<OCIItem,string>(mirror,MirrorName),new KeyValuePair<OCIItem,string>(control,ControlName)}) {
            // The nested-record load path (OnLoadAttach with worldPositionStays false), so changeAmount is local.
            var info=new OICameraInfo(Studio.Studio.GetNewIndex());info.changeAmount.pos=MirrorCameraPosition;info.changeAmount.rot=MirrorCameraRotation;
            var cam=AddObjectCamera.Load(info,pair.Key,null,true,-1);if(cam==null)throw new Exception("camera icon asset failed to load");
            cam.name=pair.Value;
        }
        studio.cameraSelector.Init(); // as Studio.AddCamera does; SetCamera needs its camera list
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame(); // GuideObject.LateUpdate enforces each target's lossy scale
        var mirrorCam=FindCamera(MirrorName);var controlCam=FindCamera(ControlName);
        var items=new List<object>();
        foreach(var item in new[]{mirror,control})
            items.Add(K("dicKey",item.objectInfo.dicKey,"authoredPosition",V(item.itemInfo.changeAmount.pos),"authoredRotation",V(item.itemInfo.changeAmount.rot),
                "authoredScale",V(item.itemInfo.changeAmount.scale),"guideEnableScale",item.guideObject.enableScale,"childRootIsObject",item.childRoot==item.objectItem.transform,
                "object",Pose(item.objectItem.transform)));
        var placed=new List<object>();var phase=MirrorPhase(placed,null);while(phase.MoveNext())yield return phase.Current;
        studio.ChangeCamera(mirrorCam); // the tree-node toggle; the save then writes this camera's active flag
        if(studio.ociCamera!=mirrorCam)throw new Exception("ChangeCamera did not make "+MirrorName+" the view camera");
        var active=new List<object>();phase=MirrorPhase(active,null);while(phase.MoveNext())yield return phase.Current;
        var authored=Record();
        cases["mirrored-camera-author"]=K("label","mirrored-camera-author","scene","scene-mirrored-camera.png","catalogItem",picked,"items",items,
            "savedCameraData",K("pos",V(view.pos),"rotate",V(view.rotate),"distance",V(view.distance),"parse",view.parse),
            "placed",placed,"mirrorActive",active,"afterLoad",authored,"settled",authored);
        string scene=SaveScene("scene-mirrored-camera.png");
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("mirrored-camera expects an empty scene before the read-back, found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(scene))throw new Exception("Studio.LoadScene returned false for "+scene);
        var afterLoad=Record();
        mirrorCam=FindCamera(MirrorName);controlCam=FindCamera(ControlName);
        var phases=new List<object>();
        var steps=new[]{new KeyValuePair<string,OCICamera>("loaded",null),new KeyValuePair<string,OCICamera>("control",controlCam),
            new KeyValuePair<string,OCICamera>("control-off",controlCam),new KeyValuePair<string,OCICamera>("mirror-again",mirrorCam),
            new KeyValuePair<string,OCICamera>("mirror-off",mirrorCam)};
        foreach(var step in steps) {
            if(step.Value!=null)studio.ChangeCamera(step.Value);
            var snaps=new List<object>();phase=MirrorPhase(snaps,step.Key);while(phase.MoveNext())yield return phase.Current;
            phases.Add(K("phase",step.Key,"toggled",step.Value==null?null:step.Value.cameraInfo.name,"snapshots",snaps));
        }
        cases["mirrored-camera"]=K("label","mirrored-camera","scene","scene-mirrored-camera.png","afterLoad",afterLoad,
            "settled",((Dictionary<string,object>)((List<object>)((Dictionary<string,object>)phases[0])["snapshots"])[MirrorFrames-1])["record"],"phases",phases);
    }
    OCIItem AddScaledItem(int group,int category,int no,Vector3 position,Vector3 scale) {
        var item=AddObjectItem.Add(group,category,no);if(item==null)throw new Exception("scalable item "+group+"/"+category+"/"+no+" failed to load");
        var ca=item.itemInfo.changeAmount;ca.pos=position;ca.rot=new Vector3(0f,40f,15f);ca.scale=scale;ca.OnChange();
        return item;
    }
    OCICamera FindCamera(string name) {
        OCICamera found=null;
        foreach(var entry in studio.dicObjectCtrl){var cam=entry.Value as OCICamera;if(cam!=null&&cam.cameraInfo.name==name){if(found!=null)throw new Exception("two cameras named "+name);found=cam;}}
        if(found==null)throw new Exception("no camera named "+name);
        return found;
    }
    static string PickScalableItem(out int group,out int category,out int no) { // OriginalCameraObjectProbe's rule: first scalable, non-animated item whose child root is the item itself
        var info=Singleton<Studio.Info>.Instance.dicItemLoadInfo;
        var groups=new List<int>(info.Keys);groups.Sort();
        foreach(var gk in groups){var cats=new List<int>(info[gk].Keys);cats.Sort();
            foreach(var ck in cats){var nos=new List<int>(info[gk][ck].Keys);nos.Sort();
                foreach(var nk in nos){var e=info[gk][ck][nk];if(e.isScale&&!e.isAnime&&String.IsNullOrEmpty(e.childRoot)){group=gk;category=ck;no=nk;return gk+"/"+ck+"/"+nk;}}}}
        throw new Exception("no scalable item without a named child root in the item catalog");
    }
    // MirrorFrames end-of-frame snapshots (after every LateUpdate of the frame) of the render camera and both camera objects.
    IEnumerator MirrorPhase(List<object> sink,string phase) {
        for(int i=0;i<MirrorFrames;i++) {
            yield return new WaitForEndOfFrame();
            var ctrl=studio.cameraCtrl;var main=Camera.main;var data=ctrl.Export();
            var cameras=new List<object>();
            foreach(var entry in studio.dicObjectCtrl){var cam=entry.Value as OCICamera;if(cam!=null)cameras.Add(CameraObject(cam));}
            var snap=K("frame",Time.frameCount,"cameraCtrlEnabled",ctrl.enabled,"viewCameraName",studio.ociCamera==null?null:studio.ociCamera.cameraInfo.name,
                "render",Pose(main.transform),"fov",main.fieldOfView,
                "ctrlData",K("pos",V(data.pos),"rotate",V(data.rotate),"distance",V(data.distance),"parse",data.parse),"cameras",cameras);
            if(phase!=null&&i==MirrorFrames-1)snap["record"]=Record();
            sink.Add(snap);
        }
    }
    // One camera object with Unity's own composition of its parent frame, for comparing the render camera against.
    static Dictionary<string,object> CameraObject(OCICamera cam) {
        var t=cam.objectItem.transform;var p=t.parent;var ca=cam.cameraInfo.changeAmount;
        return K("name",cam.cameraInfo.name,"dicKey",cam.cameraInfo.dicKey,"infoActive",cam.cameraInfo.active,
            "parentKey",cam.parentInfo==null?null:(object)cam.parentInfo.objectInfo.dicKey,
            "changePosition",V(ca.pos),"changeRotation",V(ca.rot),"changeScale",V(ca.scale),
            "object",Pose(t),"objectDeterminant",t.localToWorldMatrix.determinant,
            "parent",p==null?null:Pose(p),"parentDeterminant",p==null?null:(object)p.localToWorldMatrix.determinant,
            "parentTransformPoint",p==null?null:(object)V(p.TransformPoint(ca.pos)),
            "parentRotationTimesEuler",p==null?null:(object)Q(p.rotation*Quaternion.Euler(ca.rot)));
    }
    // localToWorld lists Matrix4x4's sixteen entries in its own index order (column-major: m00, m10, m20, m30, m01, ...).
    static Dictionary<string,object> Pose(Transform t) {
        var m=t.localToWorldMatrix;var entries=new float[16];for(int i=0;i<16;i++)entries[i]=m[i];
        return K("position",V(t.position),"rotation",Q(t.rotation),"euler",V(t.eulerAngles),"lossyScale",V(t.lossyScale),
            "localPosition",V(t.localPosition),"localRotation",Q(t.localRotation),"localEuler",V(t.localEulerAngles),"localScale",V(t.localScale),
            "localToWorld",entries);
    }
    // Each uploaded record is loaded into an emptied scene (the camera probe's InitScene(false)-then-load rule).
    // "afterLoad" is measured as soon as LoadScene returns, "settled" Frames frames later. The ST-T11 route-edit
    // labels first trace every route after the load (RouteSnap): RouteTraceFrames frames, longer if those
    // span less than RouteTraceSeconds, never more than RouteTraceMaxFrames.
    const int RouteTraceFrames=240,RouteTraceMaxFrames=1200;const float RouteTraceSeconds=4f;
    static readonly string[] RouteTraceLabels={"route-edit","route-children-edit"};
    IEnumerator ReloadCase(string path) {
        string label=Path.GetFileNameWithoutExtension(path).Substring("reload-".Length);
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("reload expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        if(!studio.LoadScene(path))throw new Exception("Studio.LoadScene returned false for "+path);
        var afterLoad=Record();
        List<object> routeTrace=null;
        if(Array.IndexOf(RouteTraceLabels,label)>=0) {
            // OriginalRouteProbe.Capture's rule, so compare_route_playback's frame pairing applies: read this frame's
            // deltaTime, resume after the next frame's Update phase (in which StudioTween advanced by that frame's
            // deltaTime), then snapshot. LoadScene played every route saved active; nothing is re-saved.
            routeTrace=new List<object>();float cumulative=0f;
            for(int i=0;i<RouteTraceMaxFrames&&(i<RouteTraceFrames||cumulative<RouteTraceSeconds);i++) {
                float dt=Time.deltaTime;cumulative+=dt;
                yield return null;
                routeTrace.Add(K("frameCount",Time.frameCount,"timeScale",Time.timeScale,"deltaTime",dt,"cumulativeTime",cumulative,"routes",RouteSnap()));
            }
        }
        for(int i=0;i<Frames;i++)yield return new WaitForEndOfFrame();
        var settled=Record();
        cases[label]=K("label",label,"scene",Path.GetFileName(path),"afterLoad",afterLoad,"settled",settled,
            "routeTrace",routeTrace,"routeUi",routeTrace==null?null:RouteUi());
    }
    // Per route, in studio.dicObjectCtrl order: childRoot's world placement, the active flag, and every route child's
    // world placement (guideObject.transformTarget, the transform the record's change amount drives).
    List<object> RouteSnap() {
        var routes=new List<object>();
        foreach(var entry in studio.dicObjectCtrl) {
            var route=entry.Value as OCIRoute;if(route==null)continue;
            var children=new List<object>();
            foreach(var child in route.routeInfo.child) {
                ObjectCtrlInfo ctrl;studio.dicObjectCtrl.TryGetValue(child.dicKey,out ctrl);
                var t=ctrl==null||ctrl.guideObject==null?null:ctrl.guideObject.transformTarget;
                children.Add(K("dicKey",child.dicKey,"position",t==null?null:(object)V(t.position),"rotation",t==null?null:(object)Q(t.rotation)));
            }
            routes.Add(K("dicKey",route.routeInfo.dicKey,"position",V(route.childRoot.position),"rotation",Q(route.childRoot.rotation),
                "active",route.routeInfo.active,"children",children));
        }
        return routes;
    }
    // The route point panel's prefab values the recovered code only reads: the speed slider range OnEndEditSpeed
    // clamps to (MPRoutePointCtrl.inputSpeed.min/max), the ease dropdown's entries and the route point limit option.
    // Everything goes through reflection, so the probe needs no UnityEngine.UI reference.
    static Dictionary<string,object> RouteUi() {
        const System.Reflection.BindingFlags Any=System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance;
        var panels=Resources.FindObjectsOfTypeAll<MPRoutePointCtrl>();
        object min=null,max=null,whole=null,eases=null;
        if(panels.Length>0) {
            var input=typeof(MPRoutePointCtrl).GetField("inputSpeed",Any).GetValue(panels[0]);
            var slider=input==null?null:input.GetType().GetField("slider",Any).GetValue(input);
            if(slider!=null){var type=slider.GetType();min=type.GetProperty("minValue").GetValue(slider,null);max=type.GetProperty("maxValue").GetValue(slider,null);whole=type.GetProperty("wholeNumbers").GetValue(slider,null);}
            var dropdown=typeof(MPRoutePointCtrl).GetField("dropdownEase",Any).GetValue(panels[0]);
            var options=dropdown==null?null:dropdown.GetType().GetProperty("options").GetValue(dropdown,null) as IList;
            if(options!=null)eases=options.Count;
        }
        return K("panels",panels.Length,"speedMin",min,"speedMax",max,"speedWholeNumbers",whole,"easeOptions",eases,
            "routePointLimit",Studio.Studio.optionSystem==null?null:(object)Studio.Studio.optionSystem.routePointLimit);
    }
    // ST-T11: what the player loaded of a route record (OIRouteInfo and each OIRoutePointInfo with its aid), and
    // the line OCIRoute.UpdateLine built: OnVisible shows it only while the route is visible and visibleLine is set.
    static readonly System.Reflection.FieldInfo RouteLine=typeof(OCIRoute).GetField("line",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
    static object Member(object target,string name) { // a Vectrosity VectorLine member, property or field, without a Vectrosity reference
        if(target==null)return null;const System.Reflection.BindingFlags Any=System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance;
        var property=target.GetType().GetProperty(name,Any);if(property!=null)return property.GetValue(target,null);
        var field=target.GetType().GetField(name,Any);return field==null?null:field.GetValue(target);
    }
    static Dictionary<string,object> RouteRecord(OCIRoute route) {
        var info=route.routeInfo;var points=new List<object>();
        for(int i=0;i<info.route.Count;i++) {
            var p=info.route[i];var aid=p.aidInfo;var live=i<route.listPoint.Count?route.listPoint[i]:null;
            points.Add(K("dicKey",p.dicKey,"changePosition",V(p.changeAmount.pos),"changeRotation",V(p.changeAmount.rot),"changeScale",V(p.changeAmount.scale),
                "speed",p.speed,"easeType",(int)p.easeType,"connection",(int)p.connection,"link",p.link,
                "aidKey",aid==null?null:(object)aid.dicKey,"aidChangePosition",aid==null?null:(object)V(aid.changeAmount.pos),
                "aidChangeRotation",aid==null?null:(object)V(aid.changeAmount.rot),"aidInitialized",aid==null?null:(object)aid.isInit,
                "isLink",live==null?null:(object)live.isLink,
                "worldPosition",live==null||live.objectItem==null?null:(object)V(live.objectItem.transform.position)));
        }
        var line=RouteLine==null?null:RouteLine.GetValue(route);
        var lineActive=Member(line,"active");var linePoints=Member(line,"points3") as IList;
        return K("name",info.name,"active",info.active,"loop",info.loop,"visibleLine",info.visibleLine,"orient",(int)info.orient,
            "color",new[]{info.color.r,info.color.g,info.color.b,info.color.a},"pointCount",route.listPoint.Count,"points",points,
            "lineExists",line!=null,"lineActive",lineActive,"linePoints",linePoints==null?null:(object)linePoints.Count,
            "childRootPosition",V(route.childRoot.position),"childRootRotation",Q(route.childRoot.rotation));
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
                "parentKey",ctrl.parentInfo==null?null:(object)ctrl.parentInfo.objectInfo.dicKey,
                "worldPosition",ctrl.guideObject==null||ctrl.guideObject.transformTarget==null?null:(object)V(ctrl.guideObject.transformTarget.position),
                // ST-T03 topology: the world pose, the authored local placement and the record's own child lists in order.
                "worldRotation",ctrl.guideObject==null||ctrl.guideObject.transformTarget==null?null:(object)Q(ctrl.guideObject.transformTarget.rotation),
                "lossyScale",ctrl.guideObject==null||ctrl.guideObject.transformTarget==null?null:(object)V(ctrl.guideObject.transformTarget.lossyScale),
                "changePosition",info.changeAmount==null?null:(object)V(info.changeAmount.pos),
                "changeRotation",info.changeAmount==null?null:(object)V(info.changeAmount.rot),
                "changeScale",info.changeAmount==null?null:(object)V(info.changeAmount.scale),
                "childKeys",ChildKeys(info),
                "routeChildRootPosition",route==null||route.childRoot==null?null:(object)V(route.childRoot.position),
                "character",chr==null?null:CharRecord(chr,(OICharInfo)info),
                "route",route==null?null:RouteRecord(route),
                "content",Content(ctrl)));
        }
        var rootKeys=new List<object>(); // sceneInfo.dicObject in enumeration order: the order SceneInfo.Save writes the roots
        foreach(var root in studio.sceneInfo.dicObject)rootKeys.Add(K("key",root.Key,"dicKey",root.Value.dicKey));
        return K("objectCount",studio.dicObjectCtrl.Count,"rootKeys",rootKeys,"sunCaster",studio.sceneInfo.sunCaster,
            "viewCameraKey",studio.ociCamera==null?null:(object)studio.ociCamera.cameraInfo.dicKey,
            "viewCameraName",studio.ociCamera==null?null:studio.ociCamera.cameraInfo.name,
            "cameraCtrlEnabled",studio.cameraCtrl==null?null:(object)studio.cameraCtrl.enabled,
            "indexKeys",IndexKeys(studio.sceneInfo),
            "objects",objects);
    }
    // ST-T03 duplicate/insert: every key SceneInfo's index holds after the load (object records and their
    // bone, IK, look-at and route point keys; Studio.SetNewIndex hands a key already taken a fresh one),
    // and what each loaded object shows of its catalog content: an item's catalog IDs, whether its prefab
    // loaded and the renderers and mesh vertices under it; a light's loaded values and the Light they drive;
    // a character's card name, sex and the renderers and mesh vertices under it.
    static readonly System.Reflection.FieldInfo HashIndex=typeof(SceneInfo).GetField("hashIndex",
        System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
    static object IndexKeys(SceneInfo info) {
        var set=HashIndex==null||info==null?null:HashIndex.GetValue(info) as HashSet<int>;
        if(set==null)return null;var keys=new List<int>(set);keys.Sort();return keys;
    }
    static Dictionary<string,object> Content(ObjectCtrlInfo ctrl) {
        var item=ctrl as OCIItem;var light=ctrl as OCILight;var chr=ctrl as OCIChar;
        if(item!=null){var ii=item.itemInfo;
            return K("group",ii.group,"category",ii.category,"no",ii.no,"loaded",item.objectItem!=null,"meshes",Meshes(item.objectItem));}
        if(light!=null){var li=light.lightInfo;var l=light.light;
            return K("no",li.no,"color",new[]{li.color.r,li.color.g,li.color.b,li.color.a},"intensity",li.intensity,"range",li.range,
                "spotAngle",li.spotAngle,"shadow",li.shadow,"enable",li.enable,"drawTarget",li.drawTarget,
                "lightType",l==null?null:l.type.ToString(),"lightEnabled",l==null?null:(object)l.enabled,
                "lightIntensity",l==null?null:(object)l.intensity,"lightRange",l==null?null:(object)l.range,
                "lightSpotAngle",l==null?null:(object)l.spotAngle);}
        if(chr!=null){var cha=chr.charInfo;
            return K("fullname",cha==null?null:cha.fileParam.fullname,"sex",cha==null?null:(object)cha.fileParam.sex,
                "meshes",Meshes(cha==null?null:cha.gameObject));}
        return null;
    }
    static object Meshes(GameObject root) {
        if(root==null)return null;int renderers=0,vertices=0;
        foreach(var r in root.GetComponentsInChildren<Renderer>(true)) {
            renderers++;Mesh mesh=null;var skinned=r as SkinnedMeshRenderer;
            if(skinned!=null)mesh=skinned.sharedMesh;else{var filter=r.GetComponent<MeshFilter>();if(filter!=null)mesh=filter.sharedMesh;}
            if(mesh!=null)vertices+=mesh.vertexCount;
        }
        return K("renderers",renderers,"vertices",vertices);
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
        return K("dicKey",info.dicKey,"enableFK",info.enableFK,"enableIK",info.enableIK,"activeFK",groups,"bones",bones,"look",LookRecord(ctrl),"expression",ExpressionRecord(ctrl,info));
    }
    // ST-C04: the original player's loaded Status and OICharInfo face values.
    // Captured only; the probe does not call any expression setters.
    static Dictionary<string,object> ExpressionRecord(OCIChar ctrl,OICharInfo info) {
        var status=ctrl.charFileStatus;
        return K("eyebrowPattern",status.eyebrowPtn,"eyesPattern",status.eyesPtn,"mouthPattern",status.mouthPtn,
            "eyesOpen",status.eyesOpenMax,"blink",status.eyesBlink,"mouthOpen",info.mouthOpen,"lipSync",info.lipSync,
            "eyesLookPattern",status.eyesLookPtn,"neckLookPattern",status.neckLookPtn,"tears",status.tearsLv,"cheek",status.hohoAkaRate,
            "mouthFixedRate",ctrl.charInfo.mouthCtrl==null?null:(object)ctrl.charInfo.mouthCtrl.FixedRate);
    }
    // The saved/live look patterns and the neck/head the look controllers drive, with the signed yaw (degrees,
    // about world up, positive = +Y right-hand turn) of the head's forward and of the head-to-camera
    // direction, each measured from the body root's forward: TARGET turns the head toward the camera's side,
    // AWAY away from it.
    static Dictionary<string,object> LookRecord(OCIChar ctrl) {
        var cha=ctrl.charInfo;var status=ctrl.charFileStatus;
        var root=cha.objBodyBone==null?null:cha.objBodyBone.transform;
        var neck=Find(root,"cf_j_neck");var head=Find(root,"cf_j_head");
        var camera=Camera.main==null?null:Camera.main.transform;
        Vector3 body=cha.transform.forward;
        return K("neckLookPtn",status.neckLookPtn,"eyesLookPtn",status.eyesLookPtn,
            "neckTargetType",status.neckTargetType,"eyesTargetType",status.eyesTargetType,
            "neckControllerPtn",cha.neckLookCtrl==null?null:(object)cha.neckLookCtrl.ptnNo,
            "eyeControllerPtn",cha.eyeLookCtrl==null?null:(object)cha.eyeLookCtrl.ptnNo,
            "bodyWorldRotation",Q(cha.transform.rotation),
            "neckLocalRotation",neck==null?null:(object)Q(neck.localRotation),
            "headLocalRotation",head==null?null:(object)Q(head.localRotation),
            "headWorldPosition",head==null?null:(object)V(head.position),
            "headWorldRotation",head==null?null:(object)Q(head.rotation),
            "cameraWorldPosition",camera==null?null:(object)V(camera.position),
            "headYawFromBody",head==null?null:(object)Yaw(body,head.forward),
            "cameraYawFromBody",head==null||camera==null?null:(object)Yaw(body,camera.position-head.position));
    }
    static float Yaw(Vector3 from,Vector3 to){from.y=0f;to.y=0f;return Vector3.Angle(from,to)*Mathf.Sign(Vector3.Cross(from,to).y);}
    static Transform Find(Transform t,string name) {
        if(t==null)return null;if(t.name==name)return t;
        for(int i=0;i<t.childCount;i++){var found=Find(t.GetChild(i),name);if(found!=null)return found;}
        return null;
    }
    // A record's own child list(s) as saved: folder, item and route children in List order, and a character's
    // non-empty accessory groups (OICharInfo.child, point -> list) in dictionary order.
    static object ChildKeys(ObjectInfo info) {
        var fold=info as OIFolderInfo;if(fold!=null)return Keys(fold.child);
        var item=info as OIItemInfo;if(item!=null)return Keys(item.child);
        var route=info as OIRouteInfo;if(route!=null)return Keys(route.child);
        var chr=info as OICharInfo;
        if(chr!=null){var groups=new List<object>();if(chr.child!=null)foreach(var group in chr.child)if(group.Value!=null&&group.Value.Count>0)groups.Add(K("point",group.Key,"keys",Keys(group.Value)));return groups;}
        return null;
    }
    static List<object> Keys(List<ObjectInfo> list){var keys=new List<object>();if(list!=null)foreach(var child in list)keys.Add(child.dicKey);return keys;}
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
