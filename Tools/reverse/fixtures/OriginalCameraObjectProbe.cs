// Camera-object capture (ST-A06): Studio OCICamera objects driving the render camera, their load
// rule and the toggle back to the saved view. Only synthetic authored objects; the optional look-at
// case adds one default-file character. No installed cards, saves, media or screenshots are read.
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
[BepInPlugin("org.ikkoku.validation.cameraobjectprobe", "Ikkoku camera object probe", "1.0.0")]
public sealed class OriginalCameraObjectProbe:BaseUnityPlugin {
    const int Frames=4;
    string folder;
    Studio.Studio studio;
    readonly Dictionary<string,object> cases=new Dictionary<string,object>();
    readonly Dictionary<string,object> lookAt=new Dictionary<string,object>();
    IEnumerator Start() {
        folder=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"camera");Directory.CreateDirectory(folder);
        string error=null;
        int waited=0;
        for(;waited<3600;waited++) { // Studio, its scene container and the scene camera are built during start-up.
            if(Ready())break;
            yield return null;
        }
        if(waited>=3600)error="Studio, the scene container, cameraCtrl or Camera.main were not ready within 3600 frames";
        for(int i=0;i<60&&error==null;i++)yield return null; // settled frames before the first measurement
        var steps=new List<KeyValuePair<string,Func<IEnumerator>>>{
            new KeyValuePair<string,Func<IEnumerator>>("environment",Environment),
            new KeyValuePair<string,Func<IEnumerator>>("root",()=>ObjectCase("root",null,null,null,new Vector3(1f,2f,3f),new Vector3(10f,70f,25f),true)),
            new KeyValuePair<string,Func<IEnumerator>>("folder",FolderCase),
            new KeyValuePair<string,Func<IEnumerator>>("item-uniform",()=>ItemCase("item-uniform",new Vector3(2f,2f,2f))),
            new KeyValuePair<string,Func<IEnumerator>>("item-nonuniform",()=>ItemCase("item-nonuniform",new Vector3(1f,2f,0.5f))),
            new KeyValuePair<string,Func<IEnumerator>>("load-x",()=>LoadCase("x",false,true)),
            new KeyValuePair<string,Func<IEnumerator>>("load-y",()=>LoadCase("y",true,true)),
            new KeyValuePair<string,Func<IEnumerator>>("load-none",()=>LoadCase("none",false,false))};
        foreach(var step in steps) {
            if(error!=null)break;
            IEnumerator run=null;
            try{run=step.Value();}catch(Exception e){error=step.Key+": "+e;}
            while(error==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){error=step.Key+": "+e;}if(error!=null||!more)break;yield return current;}
        }
        // Optional look-at case: its failure is recorded beside it and never fails the run.
        if(error!=null)lookAt["skipped"]="an earlier case failed";
        else {
            string lookError=null;
            IEnumerator run=null;
            try{run=LookAtCase();}catch(Exception e){lookError=e.ToString();}
            while(lookError==null){bool more=false;object current=null;try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){lookError=e.ToString();}if(lookError!=null||!more)break;yield return current;}
            lookAt["error"]=lookError;
        }
        cases["look-at"]=lookAt;
        try{File.WriteAllText(Path.Combine(folder,"camera-trace.json"),J(K("schemaVersion",1,"framesPerPhase",Frames,"cases",cases)));}catch(Exception e){if(error==null)error="trace write: "+e;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",error,"unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,
            "scope","Studio camera objects: activation, nesting under folder and scalable item parents, load rule over hand-authored scene records, toggle back to the saved view, optional look-at target")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();} // repeat until the player exits
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Scene>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    IEnumerator Environment() {
        studio=Singleton<Studio.Studio>.Instance;
        yield return new WaitForEndOfFrame();
        var ctrl=studio.cameraCtrl;var main=Camera.main;
        cases["environment"]=K("frame",Time.frameCount,"cameraMainIsCtrlCamera",main==ctrl.mainCmaera,"cameraMainTransformIsCtrlTransform",main.transform==ctrl.transform,
            "ctrlParent",ctrl.transform.parent==null?null:ctrl.transform.parent.name,"transBase",ctrl.transBase==null?null:ctrl.transBase.name,
            "initialPosition",Studio.Studio.optionSystem.initialPosition,"objectCount",studio.dicObjectCtrl.Count,"snapshot",Snap(null));
    }
    // One camera object: placed, activated through the tree-node toggle, optionally moved while active, toggled off.
    IEnumerator ObjectCase(string label,ObjectCtrlInfo parent,string parentLabel,Transform parentRoot,Vector3 pos,Vector3 rot,bool move) {
        yield return new WaitForEndOfFrame();
        var before=Snap(null);
        OCICamera cam;
        if(parent==null) {
            cam=AddObjectCamera.Add();if(cam==null)throw new Exception("camera icon asset failed to load");
            cam.cameraInfo.changeAmount.pos=pos;cam.cameraInfo.changeAmount.rot=rot;cam.cameraInfo.changeAmount.OnChange();
        } else { // Same path as loading a nested record: OnLoadAttach parents with worldPositionStays false, so changeAmount is local.
            var info=new OICameraInfo(Studio.Studio.GetNewIndex());info.changeAmount.pos=pos;info.changeAmount.rot=rot;
            cam=AddObjectCamera.Load(info,parent,null,true,-1);if(cam==null)throw new Exception("camera icon asset failed to load");
        }
        cam.name="IKKOKU-"+label;
        studio.cameraSelector.Init(); // as Studio.AddCamera and the parenting panel do; SetCamera needs its camera list
        yield return new WaitForEndOfFrame();
        var placed=Snap(cam);
        if(parentRoot!=null)placed["parentRoot"]=Pose(parentRoot);
        studio.ChangeCamera(cam); // the tree-node right-click toggle
        bool selected=studio.ociCamera==cam;bool ctrlAfterActivate=studio.cameraCtrl.enabled;
        var active=new List<object>();var run=Phase(cam,active);while(run.MoveNext())yield return run.Current;
        List<object> moved=null;
        if(move) { // the copy runs every LateUpdate, so moving the active object moves the render camera
            cam.cameraInfo.changeAmount.pos=pos+new Vector3(0.5f,-0.25f,0.75f);cam.cameraInfo.changeAmount.rot=rot+new Vector3(5f,-20f,10f);cam.cameraInfo.changeAmount.OnChange();
            moved=new List<object>();run=Phase(cam,moved);while(run.MoveNext())yield return run.Current;
        }
        studio.ChangeCamera(cam); // toggle off
        bool cleared=studio.ociCamera==null;bool ctrlAfterDeactivate=studio.cameraCtrl.enabled;
        var restored=new List<object>();run=Phase(cam,restored);while(run.MoveNext())yield return run.Current;
        cases[label]=K("label",label,"parent",parentLabel,"authoredLocalPosition",V(pos),"authoredLocalRotation",V(rot),
            "before",before,"placed",placed,"activateSelected",selected,"cameraCtrlEnabledAfterActivate",ctrlAfterActivate,"active",active,
            "movedLocalPosition",move?V(cam.cameraInfo.changeAmount.pos):null,"movedLocalRotation",move?V(cam.cameraInfo.changeAmount.rot):null,"moved",moved,
            "deactivateCleared",cleared,"cameraCtrlEnabledAfterDeactivate",ctrlAfterDeactivate,"restored",restored);
    }
    IEnumerator Phase(OCICamera cam,List<object> sink) { // Frames end-of-frame snapshots, after every LateUpdate of the frame
        for(int i=0;i<Frames;i++){yield return new WaitForEndOfFrame();sink.Add(Snap(cam));}
    }
    IEnumerator FolderCase() {
        var f=AddObjectFolder.Add();if(f==null)throw new Exception("folder failed to load");
        f.name="IKKOKU-FOLDER";
        var ca=f.objectInfo.changeAmount;ca.pos=new Vector3(0.5f,0.25f,-0.75f);ca.rot=new Vector3(0f,40f,15f);ca.scale=new Vector3(2f,2f,2f);ca.OnChange();
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame(); // GuideObject.LateUpdate enforces the target's lossy scale
        var parentState=ParentState(f.objectItem.transform,f.childRoot,ca,f.guideObject.enableScale);
        var inner=ObjectCase("folder",f,"IKKOKU-FOLDER",f.childRoot,new Vector3(0.3f,0.6f,-0.9f),new Vector3(10f,70f,25f),false);
        while(inner.MoveNext())yield return inner.Current;
        ((Dictionary<string,object>)cases["folder"])["parentState"]=parentState;
    }
    IEnumerator ItemCase(string label,Vector3 scale) {
        int g,c,n;string picked=PickScalableItem(out g,out c,out n);
        var item=AddObjectItem.Add(g,c,n);if(item==null)throw new Exception("scalable item "+picked+" failed to load");
        var ca=item.itemInfo.changeAmount;ca.pos=new Vector3(-0.4f,0.3f,0.6f);ca.rot=new Vector3(0f,40f,15f);ca.scale=scale;ca.OnChange();
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame();
        var parentState=ParentState(item.objectItem.transform,item.childRoot,ca,item.guideObject.enableScale);
        parentState["catalogItem"]=picked; // private capture only; the committed reference omits catalog identities
        var inner=ObjectCase(label,item,"IKKOKU-ITEM",item.childRoot,new Vector3(0.3f,0.6f,-0.9f),new Vector3(10f,70f,25f),false);
        while(inner.MoveNext())yield return inner.Current;
        ((Dictionary<string,object>)cases[label])["parentState"]=parentState;
    }
    static string PickScalableItem(out int group,out int category,out int no) { // first scalable, non-animated item whose child root is the item itself
        var info=Singleton<Studio.Info>.Instance.dicItemLoadInfo;
        var groups=new List<int>(info.Keys);groups.Sort();
        foreach(var gk in groups){var cats=new List<int>(info[gk].Keys);cats.Sort();
            foreach(var ck in cats){var nos=new List<int>(info[gk][ck].Keys);nos.Sort();
                foreach(var nk in nos){var e=info[gk][ck][nk];if(e.isScale&&!e.isAnime&&String.IsNullOrEmpty(e.childRoot)){group=gk;category=ck;no=nk;return gk+"/"+ck+"/"+nk;}}}}
        throw new Exception("no scalable item without a named child root in the item catalog");
    }
    static Dictionary<string,object> ParentState(Transform item,Transform childRoot,ChangeAmount ca,bool enableScale) {
        return K("authoredPosition",V(ca.pos),"authoredRotation",V(ca.rot),"authoredScale",V(ca.scale),"guideEnableScale",enableScale,
            "object",Pose(item),"childRoot",Pose(childRoot),"childRootIsObject",childRoot==item);
    }
    // Load rule over a hand-authored record: camera A at the root and camera B inside folder F, both flagged
    // active (the UI never leaves two cameras active). "y" rebuilds the root order to F, A; "none" clears both flags.
    IEnumerator LoadCase(string label,bool reorder,bool activeFlags) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        var view=new Studio.CameraControl.CameraData();
        view.pos=new Vector3(0.2f,1.1f,0.3f);view.rotate=new Vector3(15f,200f,0f);view.distance=new Vector3(0f,0f,-3f);view.parse=35f;
        studio.cameraCtrl.Import(view); // becomes the record's cameraSaveData
        for(int i=0;i<3;i++)yield return new WaitForEndOfFrame();
        var savedView=Snap(null);
        var a=AddObjectCamera.Add();if(a==null)throw new Exception("camera icon asset failed to load");
        a.cameraInfo.changeAmount.pos=new Vector3(1f,2f,3f);a.cameraInfo.changeAmount.rot=new Vector3(10f,70f,25f);a.cameraInfo.changeAmount.OnChange();a.name="IKKOKU-A";
        var f=AddObjectFolder.Add();if(f==null)throw new Exception("folder failed to load");
        f.objectInfo.changeAmount.pos=new Vector3(-0.5f,0.2f,0.5f);f.objectInfo.changeAmount.rot=new Vector3(0f,-30f,10f);f.objectInfo.changeAmount.OnChange();f.name="IKKOKU-F";
        var bi=new OICameraInfo(Studio.Studio.GetNewIndex());bi.changeAmount.pos=new Vector3(0.3f,0.6f,-0.9f);bi.changeAmount.rot=new Vector3(5f,-40f,0f);
        var b=AddObjectCamera.Load(bi,f,null,true,-1);if(b==null)throw new Exception("camera icon asset failed to load");b.name="IKKOKU-B";
        studio.cameraSelector.Init();
        a.cameraInfo.active=activeFlags;b.cameraInfo.active=activeFlags; // written into the record only; neither is activated before the save
        var d=studio.sceneInfo.dicObject;
        if(d.Count!=2||!d.ContainsKey(a.objectInfo.dicKey)||!d.ContainsKey(f.objectInfo.dicKey))throw new Exception("root dictionary is not exactly A and F");
        if(reorder){var fe=d[f.objectInfo.dicKey];var ae=d[a.objectInfo.dicKey];d.Clear();d.Add(f.objectInfo.dicKey,fe);d.Add(a.objectInfo.dicKey,ae);}
        var authored=Order(d,null);
        yield return new WaitForEndOfFrame();
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing(); // Studio.SaveScene's steps, into the private folder
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        string path=Path.Combine(folder,"scene-"+label+".png");
        if(!studio.sceneInfo.Save(path))throw new Exception("SceneInfo.Save returned false");
        if(!studio.LoadScene(path))throw new Exception("Studio.LoadScene returned false");
        string activeAfterLoad=studio.ociCamera==null?null:studio.ociCamera.cameraInfo.name;bool ctrlAfterLoad=studio.cameraCtrl.enabled;
        var loaded=Order(studio.sceneInfo.dicObject,null);
        var afterLoad=new List<object>();
        for(int i=0;i<Frames;i++){yield return new WaitForEndOfFrame();afterLoad.Add(Snap(studio.ociCamera));}
        var loadedObjects=new List<object>();
        foreach(var entry in studio.dicObjectCtrl){var cam=entry.Value as OCICamera;if(cam!=null)loadedObjects.Add(ObjectState(cam));}
        List<object> restored=null;
        var activeCam=studio.ociCamera;
        if(activeCam!=null){studio.ChangeCamera(activeCam);restored=new List<object>();for(int i=0;i<Frames;i++){yield return new WaitForEndOfFrame();restored.Add(Snap(activeCam));}}
        cases["load-"+label]=K("label",label,"rootOrderRebuilt",reorder,"authoredActiveFlags",activeFlags,"savedCameraData",K("pos",V(view.pos),"rotate",V(view.rotate),"distance",V(view.distance),"parse",view.parse),
            "savedView",savedView,"authoredOrder",authored,"loadedOrder",loaded,"activeAfterLoad",activeAfterLoad,"cameraCtrlEnabledAfterLoad",ctrlAfterLoad,
            "afterLoad",afterLoad,"loadedCameras",loadedObjects,"restored",restored);
    }
    static List<object> Order(Dictionary<int,ObjectInfo> root,string parentName) { // depth-first, file order
        var list=new List<object>();
        foreach(var entry in root)Walk(entry.Value,parentName,list);
        return list;
    }
    static void Walk(ObjectInfo info,string parentName,List<object> list) {
        var cam=info as OICameraInfo;var fold=info as OIFolderInfo;
        list.Add(K("kind",info.kind,"dicKey",info.dicKey,"name",cam!=null?cam.name:fold!=null?fold.name:null,"active",cam!=null?(object)cam.active:null,"parent",parentName));
        if(fold!=null)foreach(var child in fold.child)Walk(child,fold.name,list);
    }
    // Optional: a default-file character looking at the camera (targetType 0 resolves to Camera.main.transform).
    IEnumerator LookAtCase() {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        var file=new ChaFileControl();file.parameter.sex=1;
        var chara=Singleton<Manager.Character>.Instance.CreateFemale(null,0,file,true);if(chara==null)throw new Exception("CreateFemale returned null");
        var load=chara.LoadAsync(false,false);while(load.MoveNext())yield return load.Current;
        chara.ChangeLookNeckTarget(0);chara.ChangeLookEyesTarget(0);chara.ChangeLookNeckPtn(1);chara.ChangeLookEyesPtn(1);
        var cam=AddObjectCamera.Add();if(cam==null)throw new Exception("camera icon asset failed to load");
        cam.cameraInfo.changeAmount.pos=new Vector3(0.9f,1.45f,1.1f);cam.cameraInfo.changeAmount.rot=new Vector3(5f,-140f,0f);cam.cameraInfo.changeAmount.OnChange();cam.name="IKKOKU-LOOK";
        studio.cameraSelector.Init();
        Transform head=null;foreach(var t in chara.GetComponentsInChildren<Transform>(true))if(t.name=="cf_j_head"){head=t;break;}
        if(head==null)throw new Exception("cf_j_head missing");
        for(int i=0;i<30;i++)yield return null;
        var control=new List<object>();for(int i=0;i<60;i++){yield return new WaitForEndOfFrame();control.Add(LookSnap(chara,head,cam));}
        studio.ChangeCamera(cam);
        var objectPhase=new List<object>();for(int i=0;i<90;i++){yield return new WaitForEndOfFrame();objectPhase.Add(LookSnap(chara,head,cam));}
        studio.ChangeCamera(cam);
        var restored=new List<object>();for(int i=0;i<90;i++){yield return new WaitForEndOfFrame();restored.Add(LookSnap(chara,head,cam));}
        lookAt["neckPattern"]=1;lookAt["eyesPattern"]=1;lookAt["control"]=control;lookAt["object"]=objectPhase;lookAt["restored"]=restored;
    }
    static Dictionary<string,object> LookSnap(ChaControl chara,Transform head,OCICamera cam) {
        var main=Camera.main;
        var neck=Member(Member(chara,"neckLookCtrl"),"target") as Transform;var eyes=Member(Member(chara,"eyeLookCtrl"),"target") as Transform;
        return K("frame",Time.frameCount,"neckTargetIsCameraMain",neck!=null&&neck==main.transform,"eyesTargetIsCameraMain",eyes!=null&&eyes==main.transform,
            "neckTarget",neck==null?null:V(neck.position),"eyesTarget",eyes==null?null:V(eyes.position),"cameraMain",V(main.transform.position),
            "object",V(cam.objectItem.transform.position),"headPosition",V(head.position),"headRotation",Q(head.rotation));
    }
    static object Member(object target,string name) {
        if(target==null)return null;
        var flags=System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance;
        for(var type=target.GetType();type!=null;type=type.BaseType){
            var field=type.GetField(name,flags|System.Reflection.BindingFlags.DeclaredOnly);if(field!=null)return field.GetValue(target);
            var prop=type.GetProperty(name,flags|System.Reflection.BindingFlags.DeclaredOnly);if(prop!=null)return prop.GetValue(target,null);
        }
        return null;
    }
    Dictionary<string,object> Snap(OCICamera cam) {
        var ctrl=studio.cameraCtrl;var main=Camera.main;var data=ctrl.Export();
        var d=K("frame",Time.frameCount,"cameraCtrlEnabled",ctrl.enabled,"activeCamera",studio.ociCamera==null?null:studio.ociCamera.cameraInfo.name,
            "main",main==null?null:(object)Pose(main.transform),"fov",main==null?null:(object)main.fieldOfView,"ctrlFov",ctrl.fieldOfView,
            "ctrlData",K("pos",V(data.pos),"rotate",V(data.rotate),"distance",V(data.distance),"parse",data.parse));
        if(cam!=null)d["object"]=ObjectState(cam);
        return d;
    }
    static Dictionary<string,object> ObjectState(OCICamera cam) {
        var t=cam.objectItem.transform;var d=Pose(t);
        d["name"]=cam.cameraInfo.name;d["dicKey"]=cam.cameraInfo.dicKey;d["infoActive"]=cam.cameraInfo.active;d["meshRendererEnabled"]=cam.meshRenderer.enabled;
        d["parent"]=t.parent==null?null:t.parent.name;d["changePosition"]=V(cam.cameraInfo.changeAmount.pos);d["changeRotation"]=V(cam.cameraInfo.changeAmount.rot);d["changeScale"]=V(cam.cameraInfo.changeAmount.scale);
        return d;
    }
    static Dictionary<string,object> Pose(Transform t) {
        return K("position",V(t.position),"rotation",Q(t.rotation),"euler",V(t.eulerAngles),"lossyScale",V(t.lossyScale),
            "localPosition",V(t.localPosition),"localRotation",Q(t.localRotation),"localEuler",V(t.localEulerAngles),"localScale",V(t.localScale));
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
