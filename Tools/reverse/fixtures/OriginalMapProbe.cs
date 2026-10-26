// ST-A11 maps (original side): the original CharaStudio player authors the map fixture scenes with its own
// writer and is captured after loading them, so our app can render the same records from the same saved
// camera. Driver: Tools/reverse/original_map_probe.py capture (one prlctl exec, private player root).
//
// Case "map33": an emptied scene, Studio.AddMap(33), then caMap = MapPos/MapRot (all three Euler angles
// nonzero, so the ZXY order shows) applied with MapCtrl.Reflect, and a saved camera inside the room. It is
// saved as scene-map33.png.
// Case "map33-showoff": the uploaded reload-showoff.png (a character scene without a map) loaded through
// Studio.LoadSceneCoroutine, then Studio.AddMap(33) with the reset (zero) map transform the player gives a
// newly added map. The scene keeps its own camera and is saved as scene-map33-showoff.png.
// Each saved scene is read back the way the scene-load UI does it (SceneLoadScene: Studio.LoadSceneCoroutine,
// whose InitScene first releases the loaded map), waited on until Map.isLoading clears, settled, and then
// captured:
//   original-<case>-color.png             Camera.main rendered into a Width x Height target (what the player
//                                         draws, without UI canvases);
//   original-<case>-map-geometry.png      the map scene's renderers only, white on black, from a probe camera
//                                         with Camera.main's pose, field of view and near plane, far = DepthFar33 (map 33) or DepthFar34;
//   original-<case>-map-depth-normals.png the same renderers through Hidden/Internal-DepthNormalsTexture
//                                         (Unity's EncodeDepthNormal, linear depth over the same far plane).
// map-trace.json records the map root pose, every map renderer (world matrix and bounds, lightmap index and
// scale/offset, materials and shaders), all lights, lightmaps, RenderSettings, the SunLightInfo entries and
// both cameras' matrices. Nothing outside this plug-in's folder is written; no installed cards, saves or
// media are read.
//
// Phase C, the baked-lightmap oracle (original_map_probe.py oracle): when reload-oracle-<case>.png records are
// uploaded, nothing is authored. Each record is read back the same way, settled, and rendered from a probe
// camera with Camera.main's pose and field of view:
//   oracle-<case>-clean-color.png       Camera.main's settings without its image-effect components;
//   oracle-<case>-irradiance.f32        the map scene's renderers only, every map material replaced by a copy
//                                       of the map's keyword-free Standard material (white or black _Color and
//                                       _MainTex, _Metallic 0, _Glossiness 0), every light at intensity 0, into
//                                       a linear ARGBFloat target: (white - black) / (1 - 0.04) per pixel, RGB
//                                       float32, rows top-down. At metallic 0 the specular terms do not depend on
//                                       the albedo and cancel, so this is Unity's own gi.indirect.diffuse: the
//                                       decoded directional lightmap (UnityGI_Base, occlusion 1);
//   oracle-<case>-irradiance-lit.f32    the same with the lights at their authored intensities (adds the
//                                       realtime lights' diffuse term with its shadows).
// The irradiance pair is rendered twice; oracle-trace.json records the repeat's largest difference.
//
// Map 34 (ST-A11 slice 3), when reload-map34-showoff.png is uploaded: one run authors, reads back, captures
// and measures four cases (no separate oracle phase). "map34-day": an emptied scene, Studio.AddMap(34) with
// caMap = MapPos/MapRot through MapCtrl.Reflect and Map.sunType = DayTime; "map34-evening" and "map34-night":
// the reset map transform with Map.sunType = Evening or Night (the sun-type button's path, MapCtrl
// .OnClickSunLightType); each with a saved camera inside the classroom facing its window wall (map-local
// -X). "map34-showoff": the uploaded character scene with map 34 added at the reset transform and its own
// camera. Each case gets the phase B images and, from the same loaded scene, the phase C oracle, both in
// map-trace.json. Map 34's far plane is DepthFar34: its outside geometry (hills, buildings) reaches about
// 800 m through the windows, so the 25 m of map 33 would clip it in the probe camera and not in ours.
//
// The map-only passes (phase B geometry and depth-normals, phase C irradiance) draw the map's solid
// renderers: every material RenderType=Opaque (Material.GetTag with fallbacks, the tag the depth-normals
// replacement selects by). Sky (Skybox/Cubemap), particle (Particles/Alpha Blended) and other non-opaque
// renderers (Standard Fade/Transparent/Cutout) are disabled for those passes and listed by class; map 33 has
// none. The oracle also records the runtime fog and draws its measurement passes with RenderSettings.fog off,
// and adds, rows top-down, at Width x Height:
//   oracle-<case>-classes.png        the solid renderers in Unlit/Color by class: white = Standard on a baked
//                                    lightmap, red = Standard without one (light-probe lit), green = any
//                                    other shader; black = none (the irradiance gate's lightmapped pixels);
//   oracle-<case>-sky.rgba.f32       only the active sky renderers, their own materials, into a cleared
//                                    (0,0,0,0) linear ARGBFloat target, far plane SkyFar: Unity's sky radiance
//                                    and coverage (alpha), float32 RGBA;
//   oracle-<case>-particles.rgba.f32 only the active particle renderers, the same way (ColorMask RGB leaves
//                                    alpha 0; RGB is the blended radiance over black).
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
using UnityEngine.SceneManagement;
[BepInPlugin("org.ikkoku.validation.mapprobe", "Ikkoku map probe", "1.0.0")]
public sealed class OriginalMapProbe:BaseUnityPlugin {
    const int Width=960,Height=720,SettleFrames=30,LoadFrames=3600;
    const float DepthFar33=25f,DepthFar34=1000f,SkyFar=10000f;
    const string Map34Upload="reload-map34-showoff.png";
    static readonly Vector3 MapPos=new Vector3(0.3f,-0.05f,-0.5f),MapRot=new Vector3(4f,25f,-3f);
    // A mapRoot-local point near the middle of map 33's room (the converted geometry spans x -2.17..1.46,
    // y 0..3.44, Unity z -1.64..4.19): the saved camera's pivot, so the camera stays inside the room.
    static readonly Vector3 RoomPivot=new Vector3(-0.35f,1.2f,1.27f);
    // Map 34's classroom spans x -4..4, y 0..3.48, Unity z -4.64..4.77 (map-local); its windows are the -X
    // wall. Per case: sun type, transformed (MapPos/MapRot) or reset, pivot, pitch, yaw relative to the map,
    // camera distance behind the pivot.
    sealed class Map34Case {
        public string label;public int sunType;public bool transformed;public Vector3 pivot;public float pitch,yaw,distance;
        public Map34Case(string l,int s,bool t,Vector3 p,float pitchDegrees,float yawDegrees,float d){label=l;sunType=s;transformed=t;pivot=p;pitch=pitchDegrees;yaw=yawDegrees;distance=d;}
    }
    static readonly Map34Case[] Map34Cases={
        new Map34Case("map34-day",0,true,new Vector3(0.5f,1.3f,0.2f),-4f,-70f,2.5f),
        new Map34Case("map34-evening",1,false,new Vector3(0.5f,1.3f,-0.8f),-6f,-105f,2.5f),
        new Map34Case("map34-night",2,false,new Vector3(0.3f,1.4f,0.6f),-8f,-80f,2f)};
    int mapNo=33;float depthFar=DepthFar33;bool withOracle;
    string folder,voiceRepair;
    Studio.Studio studio;
    Map map;
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
            studio=Singleton<Studio.Studio>.Instance;map=Singleton<Map>.Instance;
            try{voiceRepair=RepairVoice();}catch(Exception e){errors.Add("voice repair: "+e);}
        }
        var oracles=Directory.GetFiles(dir,"reload-oracle-*.png");Array.Sort(oracles,StringComparer.Ordinal);
        var map34=Path.Combine(dir,Map34Upload);
        if(oracles.Length>0) {
            foreach(var scene in oracles) {
                if(errors.Count!=0)break;
                var label=Path.GetFileNameWithoutExtension(scene).Substring("reload-oracle-".Length);
                UseMap(label.StartsWith("map34")?34:33);
                yield return StartCoroutine(Guard(label,LoadAndOracle(scene,label)));
            }
        } else if(File.Exists(map34)) {
            UseMap(34);withOracle=true;
            foreach(var c in Map34Cases)if(errors.Count==0)yield return StartCoroutine(Guard(c.label,AuthorMap34(c)));
            if(errors.Count==0)yield return StartCoroutine(Guard("map34-showoff",AuthorShowoff(map34,"map34-showoff")));
        } else {
            UseMap(33);
            if(errors.Count==0)yield return StartCoroutine(Guard("map33",AuthorMapOnly()));
            var showoff=Path.Combine(dir,"reload-showoff.png");
            if(errors.Count==0&&File.Exists(showoff))yield return StartCoroutine(Guard("map33-showoff",AuthorShowoff(showoff,"map33-showoff")));
        }
        try{File.WriteAllText(Path.Combine(folder,oracles.Length>0?"oracle-trace.json":"map-trace.json"),J(K("schemaVersion",1,"mapNo",mapNo,"width",Width,"height",Height,"depthFar",depthFar,"cases",cases)));}
        catch(Exception e){errors.Add("trace write: "+e);}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"colorSpace",QualitySettings.activeColorSpace.ToString(),
            "voiceRepair",voiceRepair,"cases",new List<string>(cases.Keys),
            "scope","Original CharaStudio 1.0.4.2 map "+mapNo+" fixtures authored with the player's own writer (Studio.AddMap, caMap through MapCtrl.Reflect, Studio.sceneInfo.Save) and read back through Studio.LoadSceneCoroutine; per case the player's Camera.main colour image, the map scene's renderers as a white silhouette and as Unity depth-normals (linear depth over "+depthFar+" m) from Camera.main's pose and field of view, and a trace of the map root, renderers, lights, lightmaps, RenderSettings, SunLightInfo and cameras; no installed cards, saves or media"+
            (oracles.Length>0||withOracle?". Oracle"+(withOracle?" (in the same run, per case)":" mode: the uploaded records read back")+": a clean colour frame, Unity's decoded lightmap irradiance per pixel (white minus black albedo over 0.96, lights at 0 and as authored), the solid renderers' lightmap classes, and the sky and particle renderers alone as linear float radiance":""))));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    // Runs one case, recording an exception instead of ending the probe (the reload probe's pattern).
    IEnumerator Guard(string label,IEnumerator run) {
        while(true) {
            bool more=false;object current=null;
            try{more=run.MoveNext();if(more)current=run.Current;}catch(Exception e){errors.Add(label+": "+e);yield break;}
            if(!more)yield break;
            yield return current;
        }
    }
    static IEnumerator Track(MonoBehaviour host,IEnumerator inner,bool[] done){yield return host.StartCoroutine(inner);done[0]=true;}
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Manager.Scene>.IsInstance()||!Singleton<Map>.IsInstance())return false;
        var s=Singleton<Studio.Studio>.Instance;var scene=Singleton<Manager.Scene>.Instance;
        return scene.commonSpace!=null&&s.sceneInfo!=null&&s.cameraCtrl!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    void UseMap(int no){mapNo=no;depthFar=no==34?DepthFar34:DepthFar33;}
    bool Loaded(){return map.no==mapNo&&!map.isLoading&&map.mapRoot!=null&&studio.sceneInfo.map==mapNo;}
    // The reload probe's environment repair: this player copy's Manager.Voice.Awake() threw during start-up,
    // so a character load's range check throws on the null voice table unless it is replaced by an empty one.
    static string RepairVoice() {
        if(!Singleton<Voice>.IsInstance())return "no Manager.Voice singleton";
        var voice=Singleton<Voice>.Instance;
        if(voice.voiceInfoList!=null)return "voiceInfoList already holds "+voice.voiceInfoList.Count+" voice entries: nothing to repair";
        var property=typeof(Voice).GetProperty("voiceInfoList",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
        var setter=property==null?null:property.GetSetMethod(true);
        if(setter==null)throw new Exception("the null Manager.Voice.voiceInfoList has no accessible private setter to repair");
        setter.Invoke(voice,new object[]{new List<VoiceInfo.Param>()});
        return "Manager.Voice.Awake() had died before assigning voiceInfoList: replaced the null voice table with an empty one so a character load's range check runs";
    }
    IEnumerator AuthorMapOnly() {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("map33 expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        float start=Time.realtimeSinceStartup;int frames=0;
        studio.AddMap(mapNo,false,false,true);
        for(;frames<LoadFrames&&!Loaded();frames++)yield return null;
        if(!Loaded())throw new Exception("map "+mapNo+" did not load within "+LoadFrames+" frames (no "+map.no+", isLoading "+map.isLoading+")");
        var added=MapRecord();
        var ca=studio.sceneInfo.caMap;ca.pos=MapPos;ca.rot=MapRot;Singleton<MapCtrl>.Instance.Reflect();
        var root=map.mapRoot.transform;
        var view=new Studio.CameraControl.CameraData();
        view.pos=root.TransformPoint(RoomPivot);view.rotate=new Vector3(12f,MapRot.y+20f,0f);view.distance=new Vector3(0f,0f,-2f);view.parse=45f;
        studio.cameraCtrl.Import(view);
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame();
        var authored=K("addMapFrames",frames,"addMapSeconds",Time.realtimeSinceStartup-start,"afterAddMap",added,"reflected",MapRecord(),
            "requestedPosition",V(MapPos),"requestedRotation",V(MapRot),
            "savedCameraData",K("pos",V(view.pos),"rotate",V(view.rotate),"distance",V(view.distance),"parse",view.parse));
        var scene=SaveScene("scene-map33.png");
        var reload=ReloadAndCapture(scene,"map33",authored);
        while(reload.MoveNext())yield return reload.Current;
    }
    // Map 34: one sun-type case (see the header).
    IEnumerator AuthorMap34(Map34Case c) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        if(studio.dicObjectCtrl.Count!=0)throw new Exception(c.label+" expects an empty scene after InitScene(false), found "+studio.dicObjectCtrl.Count+" objects");
        float start=Time.realtimeSinceStartup;int frames=0;
        studio.AddMap(mapNo,false,false,true);
        for(;frames<LoadFrames&&!Loaded();frames++)yield return null;
        if(!Loaded())throw new Exception("map "+mapNo+" did not load within "+LoadFrames+" frames (no "+map.no+", isLoading "+map.isLoading+")");
        var added=MapRecord();
        if(c.transformed){var ca=studio.sceneInfo.caMap;ca.pos=MapPos;ca.rot=MapRot;Singleton<MapCtrl>.Instance.Reflect();}
        map.sunType=(SunLightInfo.Info.Type)c.sunType;
        var root=map.mapRoot.transform;
        var view=new Studio.CameraControl.CameraData();
        view.pos=root.TransformPoint(c.pivot);view.rotate=new Vector3(c.pitch,(c.transformed?MapRot.y:0f)+c.yaw,0f);view.distance=new Vector3(0f,0f,-c.distance);view.parse=45f;
        studio.cameraCtrl.Import(view);
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame();
        var authored=K("addMapFrames",frames,"addMapSeconds",Time.realtimeSinceStartup-start,"afterAddMap",added,"reflected",MapRecord(),
            "requestedPosition",c.transformed?V(MapPos):V(Vector3.zero),"requestedRotation",c.transformed?V(MapRot):V(Vector3.zero),
            "requestedSunType",c.sunType,"activeSkies",ActivePaths("sky"),
            "savedCameraData",K("pos",V(view.pos),"rotate",V(view.rotate),"distance",V(view.distance),"parse",view.parse));
        var scene=SaveScene("scene-"+c.label+".png");
        var reload=ReloadAndCapture(scene,c.label,authored);
        while(reload.MoveNext())yield return reload.Current;
    }
    IEnumerator AuthorShowoff(string source,string label) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        var done=new bool[1];int frames=0;
        StartCoroutine(Track(this,studio.LoadSceneCoroutine(source),done));
        for(;frames<LoadFrames&&!done[0];frames++)yield return null;
        if(!done[0])throw new Exception("the showoff scene did not load within "+LoadFrames+" frames");
        int sourceMap=studio.sceneInfo.map,objects=studio.dicObjectCtrl.Count;
        for(int i=0;i<SettleFrames;i++)yield return null;
        float start=Time.realtimeSinceStartup;int mapFrames=0;
        studio.AddMap(mapNo,false,false,true); // SetupMap resets caMap: a newly added map sits at the origin
        for(;mapFrames<LoadFrames&&!Loaded();mapFrames++)yield return null;
        if(!Loaded())throw new Exception("map "+mapNo+" did not load into the showoff scene within "+LoadFrames+" frames");
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame();
        var authored=K("source",Path.GetFileName(source),"sourceSHA256",Sha256File(source),"sourceMap",sourceMap,"sourceLoadFrames",frames,
            "objects",objects,"addMapFrames",mapFrames,"addMapSeconds",Time.realtimeSinceStartup-start,"afterAddMap",MapRecord(),
            "savedCameraData",CameraData(studio.cameraCtrl.Export()));
        var scene=SaveScene("scene-"+label+".png");
        var reload=ReloadAndCapture(scene,label,authored);
        while(reload.MoveNext())yield return reload.Current;
    }
    // The reload probe's save rule: every object's save preprocessing, and the view belongs to the record.
    string SaveScene(string name) {
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        string scene=Path.Combine(folder,name);
        if(!studio.sceneInfo.Save(scene))throw new Exception("Studio.sceneInfo.Save returned false for "+scene);
        return scene;
    }
    IEnumerator ReloadAndCapture(string scene,string label,Dictionary<string,object> authored) {
        studio.InitScene(false); // releases the map, so the read-back loads it from its bundle again
        for(int i=0;i<3;i++)yield return null;
        var released=K("no",map.no,"mapRootNull",map.mapRoot==null,"objects",studio.dicObjectCtrl.Count);
        var done=new bool[1];int frames=0;float start=Time.realtimeSinceStartup;
        StartCoroutine(Track(this,studio.LoadSceneCoroutine(scene),done));
        for(;frames<LoadFrames&&!(done[0]&&Loaded());frames++)yield return null;
        if(!(done[0]&&Loaded()))throw new Exception(label+": the saved scene did not load map "+mapNo+" within "+LoadFrames+" frames (done "+done[0]+", no "+map.no+")");
        float seconds=Time.realtimeSinceStartup-start;
        var afterLoad=MapRecord();
        for(int i=0;i<SettleFrames;i++)yield return null;
        yield return new WaitForEndOfFrame();
        var capture=Capture(label);
        var record=K("label",label,"scene",Path.GetFileName(scene),"sceneSHA256",Sha256File(scene),"authored",authored,"released",released,
            "loadFrames",frames,"loadSeconds",seconds,"afterLoad",afterLoad,"settled",MapRecord(),"objects",studio.dicObjectCtrl.Count,
            "loadedCameraData",CameraData(studio.cameraCtrl.Export()),"capture",capture);
        if(withOracle)record["oracle"]=Oracle(label);
        cases[label]=record;
    }
    Dictionary<string,object> Capture(string label) {
        var main=Camera.main;if(main==null)throw new Exception("no Camera.main to capture");
        var target=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Default);target.antiAliasing=1;target.Create();
        var previous=main.targetTexture;
        main.targetTexture=target;main.aspect=(float)Width/Height;
        var mainRecord=CameraRecord(main);
        var timer=System.Diagnostics.Stopwatch.StartNew();main.Render();timer.Stop();
        SaveTarget(target,"original-"+label+"-color.png");
        main.targetTexture=previous;main.ResetAspect();
        var cameras=new List<object>();
        foreach(var c in Camera.allCameras)cameras.Add(K("name",c.name,"enabled",c.enabled,"depth",c.depth,"clearFlags",c.clearFlags.ToString(),"cullingMask",c.cullingMask,
            "targetTexture",c.targetTexture==null?null:c.targetTexture.name,"isMain",c==main));
        var effects=new List<object>();
        foreach(var b in main.GetComponents<Behaviour>())effects.Add(K("type",b.GetType().FullName,"enabled",b.enabled));
        var mapScene=map.mapRoot.scene;
        var mapRenderers=new List<Renderer>();var hidden=new List<Renderer>();var excluded=new List<Renderer>();
        var mapRecords=new List<object>();
        foreach(var r in FindObjectsOfType<Renderer>()) {
            if(r.gameObject.scene==mapScene) {
                if(!(r.enabled&&r.gameObject.activeInHierarchy))continue;
                var kind=RendererClass(r);mapRecords.Add(RendererRecord(r,kind));
                if(kind=="solid")mapRenderers.Add(r);else{r.enabled=false;excluded.Add(r);}
            }
            else if(r.enabled){r.enabled=false;hidden.Add(r);}
        }
        var probeObject=new GameObject("IkkokuMapProbeCamera");var cam=probeObject.AddComponent<Camera>();cam.enabled=false;
        cam.transform.position=main.transform.position;cam.transform.rotation=main.transform.rotation;
        cam.fieldOfView=main.fieldOfView;cam.nearClipPlane=main.nearClipPlane;cam.farClipPlane=depthFar;cam.aspect=(float)Width/Height;
        cam.clearFlags=CameraClearFlags.SolidColor;cam.backgroundColor=Color.black;cam.allowHDR=false;cam.allowMSAA=false;cam.cullingMask=~0;
        cam.renderingPath=RenderingPath.Forward;cam.useOcclusionCulling=false;cam.targetTexture=target;
        var probeRecord=CameraRecord(cam);
        var saved=new Dictionary<Renderer,Material[]>();
        string whiteShader;var white=WhiteMaterial(out whiteShader);
        try {
            foreach(var r in mapRenderers){saved[r]=r.sharedMaterials;var m=new Material[r.sharedMaterials.Length];for(int i=0;i<m.Length;i++)m[i]=white;r.sharedMaterials=m;}
            cam.Render();SaveTarget(target,"original-"+label+"-map-geometry.png");
            var depthShader=Shader.Find("Hidden/Internal-DepthNormalsTexture");
            if(depthShader==null)throw new Exception("Hidden/Internal-DepthNormalsTexture is not in this player");
            var depthTarget=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Linear);depthTarget.Create();
            cam.targetTexture=depthTarget;cam.backgroundColor=Color.white;cam.RenderWithShader(depthShader,"");
            SaveTarget(depthTarget,"original-"+label+"-map-depth-normals.png");
            cam.targetTexture=null;depthTarget.Release();Destroy(depthTarget);
        } finally {
            foreach(var pair in saved)pair.Key.sharedMaterials=pair.Value;
            foreach(var r in hidden)r.enabled=true;
            foreach(var r in excluded)r.enabled=true;
            cam.targetTexture=null;Destroy(probeObject);target.Release();Destroy(target);Destroy(white);
        }
        return K("main",mainRecord,"mainRenderMilliseconds",timer.Elapsed.TotalMilliseconds,"cameras",cameras,"mainBehaviours",effects,
            "probe",probeRecord,"whiteShader",whiteShader,"hiddenRenderers",hidden.Count,"mapRenderers",mapRecords,
            "solidRenderers",mapRenderers.Count,"excludedRenderers",ClassCounts(excluded),
            "mapScene",K("name",mapScene.name,"path",mapScene.path,"isActive",SceneManager.GetActiveScene()==mapScene,"roots",Roots(mapScene)),
            "lights",Lights(),"lightmaps",Lightmaps(),"renderSettings",RenderSettingsRecord(),"sunLightInfo",SunRecord(),
            "quality",K("pixelLightCount",QualitySettings.pixelLightCount,"shadows",QualitySettings.shadows.ToString(),"antiAliasing",QualitySettings.antiAliasing,
                "masterTextureLimit",QualitySettings.masterTextureLimit,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString()),
            "images",new[]{"original-"+label+"-color.png","original-"+label+"-map-geometry.png","original-"+label+"-map-depth-normals.png"});
    }
    // Phase C: one uploaded record read back and measured (see the header).
    IEnumerator LoadAndOracle(string scene,string label) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        var done=new bool[1];int frames=0;float start=Time.realtimeSinceStartup;
        StartCoroutine(Track(this,studio.LoadSceneCoroutine(scene),done));
        for(;frames<LoadFrames&&!(done[0]&&Loaded());frames++)yield return null;
        if(!(done[0]&&Loaded()))throw new Exception(label+": the record did not load map "+mapNo+" within "+LoadFrames+" frames (done "+done[0]+", no "+map.no+")");
        float seconds=Time.realtimeSinceStartup-start;
        for(int i=0;i<SettleFrames;i++)yield return null;
        yield return new WaitForEndOfFrame();
        cases[label]=K("label",label,"scene",Path.GetFileName(scene),"sceneSHA256",Sha256File(scene),"loadFrames",frames,"loadSeconds",seconds,
            "settled",MapRecord(),"objects",studio.dicObjectCtrl.Count,"loadedCameraData",CameraData(studio.cameraCtrl.Export()),"oracle",Oracle(label));
    }
    const float OneMinusDielectricSpec=1f-0.04f; // unity_ColorSpaceDielectricSpec.a in Linear (UnityCG.cginc)
    Dictionary<string,object> Oracle(string label) {
        var main=Camera.main;if(main==null)throw new Exception("no Camera.main to measure");
        var probeObject=new GameObject("IkkokuMapOracleCamera");var cam=probeObject.AddComponent<Camera>();
        var ldr=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Default);ldr.antiAliasing=1;ldr.Create();
        var hdr=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGBFloat,RenderTextureReadWrite.Linear);hdr.antiAliasing=1;hdr.Create();
        var mapScene=map.mapRoot.scene;
        var mapRenderers=new List<Renderer>();var hidden=new List<Renderer>();
        var skies=new List<Renderer>();var particles=new List<Renderer>();var others=new List<Renderer>();
        var saved=new Dictionary<Renderer,Material[]>();
        var lights=FindObjectsOfType<Light>();var intensities=new float[lights.Length];for(int i=0;i<lights.Length;i++)intensities[i]=lights[i].intensity;
        bool runtimeFog=RenderSettings.fog;
        var fogRecord=K("fog",RenderSettings.fog,"fogMode",RenderSettings.fogMode.ToString(),"fogColor",C(RenderSettings.fogColor),
            "fogStartDistance",RenderSettings.fogStartDistance,"fogEndDistance",RenderSettings.fogEndDistance,"fogDensity",RenderSettings.fogDensity);
        Material white=null,black=null;var classMaterials=new List<Material>();
        try {
            // The clean colour frame: Camera.main's settings, none of its image-effect components.
            cam.CopyFrom(main);cam.enabled=false;cam.aspect=(float)Width/Height;cam.targetTexture=ldr;
            var cleanRecord=CameraRecord(cam);
            cam.Render();cam.targetTexture=null;SaveTarget(ldr,"oracle-"+label+"-clean-color.png");
            // The measurement passes: fog off, the map's renderers only, the solid ones unless a pass says otherwise.
            RenderSettings.fog=false;
            foreach(var r in FindObjectsOfType<Renderer>()) {
                if(r.gameObject.scene==mapScene) {
                    if(!(r.enabled&&r.gameObject.activeInHierarchy))continue;
                    var kind=RendererClass(r);
                    if(kind=="solid")mapRenderers.Add(r);
                    else{r.enabled=false;(kind=="sky"?skies:kind=="particle"?particles:others).Add(r);}
                }
                else if(r.enabled){r.enabled=false;hidden.Add(r);}
            }
            // The first (by name) keyword-free opaque Standard material the map draws with.
            Material template=null;
            foreach(var r in mapRenderers)foreach(var m in r.sharedMaterials)
                if(m!=null&&m.shader!=null&&m.shader.name=="Standard"&&NoKeywords(m)&&m.renderQueue<=2500&&m.HasProperty("_Mode")&&m.GetFloat("_Mode")==0f
                   &&(template==null||String.CompareOrdinal(m.name,template.name)<0))template=m;
            if(template==null)throw new Exception("no keyword-free opaque Standard material on the map's renderers to copy");
            white=Albedo(template,Color.white);black=Albedo(template,Color.black);
            foreach(var r in mapRenderers)saved[r]=r.sharedMaterials;
            cam.CopyFrom(main);cam.enabled=false;cam.aspect=(float)Width/Height;
            cam.clearFlags=CameraClearFlags.SolidColor;cam.backgroundColor=Color.black;cam.allowHDR=true;cam.allowMSAA=false;cam.cullingMask=~0;
            cam.renderingPath=RenderingPath.Forward;cam.useOcclusionCulling=false;
            var probeRecord=CameraRecord(cam);
            for(int i=0;i<lights.Length;i++)lights[i].intensity=0f;
            var unlitStats=new Dictionary<string,object>();
            var gi=Difference(cam,hdr,mapRenderers,white,black,unlitStats);
            var repeat=Difference(cam,hdr,mapRenderers,white,black,new Dictionary<string,object>());
            double repeatMax=0;for(int i=0;i<gi.Length;i++)repeatMax=Math.Max(repeatMax,Math.Abs((double)gi[i]-repeat[i]));
            WriteFloats(gi,"oracle-"+label+"-irradiance.f32");
            for(int i=0;i<lights.Length;i++)lights[i].intensity=intensities[i];
            var litStats=new Dictionary<string,object>();
            var lit=Difference(cam,hdr,mapRenderers,white,black,litStats);
            WriteFloats(lit,"oracle-"+label+"-irradiance-lit.f32");
            // Which solid pixels the irradiance gate may compare: Standard on a baked lightmap.
            var lightmapped=ClassMaterial(Color.white,classMaterials);var probeLit=ClassMaterial(Color.red,classMaterials);var other=ClassMaterial(Color.green,classMaterials);
            int lightmapCount=LightmapSettings.lightmaps==null?0:LightmapSettings.lightmaps.Length;
            var classCounts=new Dictionary<string,object>();int lightmappedRenderers=0,probeLitRenderers=0,otherSlots=0;
            foreach(var r in mapRenderers) {
                bool baked=r.lightmapIndex>=0&&r.lightmapIndex<lightmapCount;
                var m=new Material[r.sharedMaterials.Length];
                for(int i=0;i<m.Length;i++){var source=saved[r][i];bool standard=source!=null&&source.shader!=null&&source.shader.name=="Standard";
                    m[i]=standard?(baked?lightmapped:probeLit):other;if(!standard)otherSlots++;}
                if(baked)lightmappedRenderers++;else probeLitRenderers++;
                r.sharedMaterials=m;
            }
            classCounts["lightmappedRenderers"]=lightmappedRenderers;classCounts["probeLitRenderers"]=probeLitRenderers;classCounts["otherShaderSlots"]=otherSlots;
            cam.allowHDR=false;cam.targetTexture=ldr;cam.Render();cam.targetTexture=null;cam.allowHDR=true;
            SaveTarget(ldr,"oracle-"+label+"-classes.png");
            foreach(var pair in saved)pair.Key.sharedMaterials=pair.Value;
            // The sky and the particles, each alone with its own materials, over (0,0,0,0).
            var groups=new Dictionary<string,object>();
            cam.backgroundColor=new Color(0f,0f,0f,0f);cam.farClipPlane=SkyFar;
            foreach(var r in mapRenderers)r.enabled=false;
            foreach(var pass in new[]{"sky","particles"}) {
                var set=pass=="sky"?skies:particles;
                if(set.Count==0){groups[pass]=K("written",false);continue;}
                foreach(var r in set)r.enabled=true;
                var rgba=RenderAlone(cam,hdr);
                foreach(var r in set)r.enabled=false;
                var file="oracle-"+label+"-"+pass+".rgba.f32";WriteFloats(rgba,file);
                var materials=new List<object>();foreach(var r in set)materials.Add(K("path",TPath(r.transform),"materials",GroupMaterials(r)));
                groups[pass]=K("written",true,"file",file,"layout","float32 little-endian RGBA, rows top-down","renderers",materials,"farClipPlane",SkyFar,
                    "background","(0,0,0,0)","coveredPixels",Covered(rgba,pass=="sky"));
            }
            foreach(var r in mapRenderers)r.enabled=true;
            var lightmapTextures=new List<object>();
            foreach(var d in LightmapSettings.lightmaps)foreach(var t in new[]{d.lightmapColor,d.lightmapDir})
                if(t!=null)lightmapTextures.Add(K("name",t.name,"filterMode",t.filterMode.ToString(),"anisoLevel",t.anisoLevel,"wrapMode",t.wrapMode.ToString(),
                    "mipMapBias",t.mipMapBias,"mipmapCount",t.mipmapCount,"format",t.format.ToString()));
            return K("clean",K("camera",cleanRecord,"image","oracle-"+label+"-clean-color.png"),
                "probe",probeRecord,"template",K("name",template.name,"shader",template.shader.name,"keywords",template.shaderKeywords,"renderQueue",template.renderQueue),
                "overrides",K("albedo","_Color and _MainTex white or black","metallic",0,"glossiness",0,"keywords",white.shaderKeywords),
                "mapRenderers",mapRenderers.Count,"hiddenRenderers",hidden.Count,
                "excludedRenderers",K("sky",skies.Count,"particle",particles.Count,"nonOpaque",others.Count),
                "runtimeFog",fogRecord,"measurementFog",false,
                "lights",Lights(),"lightIntensities",intensities,
                "irradiance",K("file","oracle-"+label+"-irradiance.f32","layout","float32 little-endian RGB, rows top-down","width",Width,"height",Height,
                    "lights","all at intensity 0","divisor",OneMinusDielectricSpec,"stats",unlitStats,"repeatMaximumDifference",repeatMax),
                "irradianceLit",K("file","oracle-"+label+"-irradiance-lit.f32","lights","as authored","stats",litStats),
                "classes",K("image","oracle-"+label+"-classes.png","white","Standard on a baked lightmap","red","Standard without a lightmap (light probes)",
                    "green","another shader","lightmaps",lightmapCount,"counts",classCounts),
                "sky",groups["sky"],"particles",groups["particles"],
                "quality",K("softParticles",QualitySettings.softParticles,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString()),
                "mainDepthTextureMode",main.depthTextureMode.ToString(),"mainFarClipPlane",main.farClipPlane,
                "unity_Lightmap_HDR",V4(Shader.GetGlobalVector("unity_Lightmap_HDR")),
                "colorSpace",QualitySettings.activeColorSpace.ToString(),"lightmapsMode",LightmapSettings.lightmapsMode.ToString(),
                "lightmapTextures",lightmapTextures,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString(),
                "renderSettings",RenderSettingsRecord());
        } finally {
            foreach(var pair in saved)pair.Key.sharedMaterials=pair.Value;
            for(int i=0;i<lights.Length;i++)if(lights[i]!=null)lights[i].intensity=intensities[i];
            RenderSettings.fog=runtimeFog;
            foreach(var r in mapRenderers)if(r!=null)r.enabled=true;
            foreach(var set in new[]{hidden,skies,particles,others})foreach(var r in set)if(r!=null)r.enabled=true;
            cam.targetTexture=null;Destroy(probeObject);ldr.Release();Destroy(ldr);hdr.Release();Destroy(hdr);
            if(white!=null)Destroy(white);if(black!=null)Destroy(black);
            foreach(var m in classMaterials)Destroy(m);
        }
    }
    // A renderer's class for the map-only passes (see the header): "sky", "particle", "solid" (every material
    // RenderType=Opaque) or "nonOpaque".
    static string RendererClass(Renderer r) {
        bool sky=false,particle=false,opaque=r.sharedMaterials.Length>0;
        foreach(var m in r.sharedMaterials) {
            if(m==null||m.shader==null){opaque=false;continue;}
            if(m.shader.name=="Skybox/Cubemap")sky=true;else if(m.shader.name=="Particles/Alpha Blended")particle=true;
            if(m.GetTag("RenderType",true)!="Opaque")opaque=false;
        }
        return sky?"sky":particle?"particle":opaque?"solid":"nonOpaque";
    }
    static Dictionary<string,object> ClassCounts(List<Renderer> renderers) {
        var d=new Dictionary<string,object>();
        foreach(var r in renderers){var k=RendererClass(r);d[k]=(d.ContainsKey(k)?(int)d[k]:0)+1;}
        return d;
    }
    List<object> ActivePaths(string kind) {
        var paths=new List<object>();
        foreach(var r in FindObjectsOfType<Renderer>())if(r.gameObject.scene==map.mapRoot.scene&&r.enabled&&r.gameObject.activeInHierarchy&&RendererClass(r)==kind)paths.Add(TPath(r.transform));
        return paths;
    }
    // The material inputs the sky and particle formulas read, as the player holds them.
    static List<object> GroupMaterials(Renderer r) {
        var list=new List<object>();
        foreach(var m in r.sharedMaterials) {
            if(m==null){list.Add(null);continue;}
            var d=K("name",m.name,"shader",m.shader==null?null:m.shader.name,"renderQueue",m.renderQueue,"keywords",m.shaderKeywords,"renderType",m.GetTag("RenderType",true));
            foreach(var p in new[]{"_Tint","_TintColor","_Color"})if(m.HasProperty(p))d[p]=C(m.GetColor(p));
            foreach(var p in new[]{"_Exposure","_Rotation","_InvFade"})if(m.HasProperty(p))d[p]=m.GetFloat(p);
            d["_Tex_HDR"]=V4(m.GetVector("_Tex_HDR"));
            foreach(var p in new[]{"_Tex","_MainTex"})if(m.HasProperty(p)){var t=m.GetTexture(p);d[p]=t==null?null:K("name",t.name,"dimension",t.dimension.ToString(),"width",t.width,"height",t.height,
                "filterMode",t.filterMode.ToString(),"anisoLevel",t.anisoLevel,"wrapMode",t.wrapMode.ToString(),"mipMapBias",t.mipMapBias,
                "format",t is Cubemap?((Cubemap)t).format.ToString():t is Texture2D?((Texture2D)t).format.ToString():null,
                "mipmapCount",t is Cubemap?((Cubemap)t).mipmapCount:t is Texture2D?((Texture2D)t).mipmapCount:0);}
            list.Add(d);
        }
        return list;
    }
    static Material ClassMaterial(Color color,List<Material> owned) {
        string name;var m=WhiteMaterial(out name);m.color=color;owned.Add(m);return m;
    }
    float[] RenderAlone(Camera cam,RenderTexture target) {
        cam.targetTexture=target;cam.Render();cam.targetTexture=null;
        var previous=RenderTexture.active;RenderTexture.active=target;
        var read=new Texture2D(Width,Height,TextureFormat.RGBAFloat,false,true);read.ReadPixels(new Rect(0,0,Width,Height),0,0);read.Apply(false,false);
        RenderTexture.active=previous;
        var pixels=read.GetPixels();Destroy(read);
        var rgba=new float[Width*Height*4];
        for(int y=0;y<Height;y++)for(int x=0;x<Width;x++){var c=pixels[(Height-1-y)*Width+x];int o=(y*Width+x)*4;rgba[o]=c.r;rgba[o+1]=c.g;rgba[o+2]=c.b;rgba[o+3]=c.a;}
        return rgba;
    }
    // Sky coverage is its alpha (the fragment writes 1); a particle pixel is covered when its RGB is not 0.
    static int Covered(float[] rgba,bool byAlpha) {
        int n=0;
        for(int i=0;i<rgba.Length;i+=4)if(byAlpha?rgba[i+3]>0.5f:(rgba[i]!=0f||rgba[i+1]!=0f||rgba[i+2]!=0f))n++;
        return n;
    }
    static bool NoKeywords(Material m){foreach(var k in m.shaderKeywords)if(!String.IsNullOrEmpty(k))return false;return true;}
    // A copy of the map's keyword-free Standard material (so its compiled lightmapped variants exist in this
    // player) with the albedo forced and no metallic or smoothness.
    static Material Albedo(Material template,Color color) {
        var m=new Material(template);m.shaderKeywords=new string[0];
        m.SetColor("_Color",color);m.SetTexture("_MainTex",Texture2D.whiteTexture);
        m.SetFloat("_Metallic",0f);m.SetFloat("_Glossiness",0f);m.SetColor("_EmissionColor",Color.black);
        return m;
    }
    float[] Difference(Camera cam,RenderTexture target,List<Renderer> renderers,Material white,Material black,Dictionary<string,object> stats) {
        var a=RenderWith(cam,target,renderers,white);var b=RenderWith(cam,target,renderers,black);
        var d=new float[a.Length];int nonFinite=0,negative=0,positive=0;double max=0,sum=0;
        for(int i=0;i<a.Length;i++) {
            float v=(a[i]-b[i])/OneMinusDielectricSpec;d[i]=v;
            if(float.IsNaN(v)||float.IsInfinity(v)){nonFinite++;continue;}
            if(v<0)negative++;else if(v>0){positive++;sum+=v;if(v>max)max=v;}
        }
        stats["nonFinite"]=nonFinite;stats["negative"]=negative;stats["positive"]=positive;stats["maximum"]=max;stats["meanPositive"]=positive>0?sum/positive:0;
        return d;
    }
    float[] RenderWith(Camera cam,RenderTexture target,List<Renderer> renderers,Material material) {
        foreach(var r in renderers){var m=new Material[r.sharedMaterials.Length];for(int i=0;i<m.Length;i++)m[i]=material;r.sharedMaterials=m;}
        cam.targetTexture=target;cam.Render();cam.targetTexture=null;
        var previous=RenderTexture.active;RenderTexture.active=target;
        var read=new Texture2D(Width,Height,TextureFormat.RGBAFloat,false,true);read.ReadPixels(new Rect(0,0,Width,Height),0,0);read.Apply(false,false);
        RenderTexture.active=previous;
        var pixels=read.GetPixels();Destroy(read);
        var rgb=new float[Width*Height*3];
        for(int y=0;y<Height;y++)for(int x=0;x<Width;x++){var c=pixels[(Height-1-y)*Width+x];int o=(y*Width+x)*3;rgb[o]=c.r;rgb[o+1]=c.g;rgb[o+2]=c.b;}
        return rgb;
    }
    void WriteFloats(float[] values,string file) {
        var bytes=new byte[values.Length*4];Buffer.BlockCopy(values,0,bytes,0,bytes.Length);
        File.WriteAllBytes(Path.Combine(folder,file),bytes);
    }
    static Material WhiteMaterial(out string name) {
        var shader=Shader.Find("Unlit/Color");name="Unlit/Color";
        if(shader==null){shader=Shader.Find("Hidden/Internal-Colored");name="Hidden/Internal-Colored";}
        if(shader==null)throw new Exception("neither Unlit/Color nor Hidden/Internal-Colored is in this player");
        var white=new Material(shader);white.color=Color.white;
        white.SetInt("_Cull",2);white.SetInt("_ZWrite",1);white.SetInt("_ZTest",4);white.SetInt("_SrcBlend",1);white.SetInt("_DstBlend",0); // back-face culled, opaque, like the map's Standard materials
        return white;
    }
    Dictionary<string,object> MapRecord() {
        var ca=studio.sceneInfo.caMap;var root=map.mapRoot;
        object rootRecord=null;
        if(root!=null){var t=root.transform;rootRecord=K("name",root.name,"scene",root.scene.name,"parent",t.parent==null?null:t.parent.name,
            "localPosition",V(t.localPosition),"localRotation",Q(t.localRotation),"localEulerAngles",V(t.localEulerAngles),"localScale",V(t.localScale),
            "position",V(t.position),"rotation",Q(t.rotation),"lossyScale",V(t.lossyScale),"localToWorld",M(t.localToWorldMatrix));}
        return K("no",map.no,"isLoading",map.isLoading,"sceneInfoMap",studio.sceneInfo.map,"sunLightType",studio.sceneInfo.sunLightType,"mapOption",studio.sceneInfo.mapOption,
            "caMap",K("pos",V(ca.pos),"rot",V(ca.rot),"scale",V(ca.scale)),"expectedRotation",Q(Quaternion.Euler(ca.rot)),"mapRoot",rootRecord,
            "activeScene",SceneManager.GetActiveScene().name);
    }
    static Dictionary<string,object> RendererRecord(Renderer r,string kind) {
        var filter=r.GetComponent<MeshFilter>();var mesh=filter==null?null:filter.sharedMesh;
        var materials=new List<object>();
        foreach(var m in r.sharedMaterials)materials.Add(m==null?null:K("name",m.name,"shader",m.shader==null?null:m.shader.name,"renderQueue",m.renderQueue));
        return K("path",TPath(r.transform),"class",kind,"type",r.GetType().Name,"layer",r.gameObject.layer,"localToWorld",M(r.localToWorldMatrix),
            "boundsMin",V(r.bounds.min),"boundsMax",V(r.bounds.max),"lightmapIndex",r.lightmapIndex,"lightmapScaleOffset",V4(r.lightmapScaleOffset),
            "isPartOfStaticBatch",r.isPartOfStaticBatch,"shadowCasting",r.shadowCastingMode.ToString(),"receiveShadows",r.receiveShadows,"materials",materials,
            "mesh",mesh==null?null:mesh.name,"vertexCount",mesh==null?0:mesh.vertexCount,"subMeshCount",mesh==null?0:mesh.subMeshCount,
            "meshBoundsCenter",mesh==null?null:V(mesh.bounds.center),"meshBoundsSize",mesh==null?null:V(mesh.bounds.size));
    }
    static List<object> Roots(UnityEngine.SceneManagement.Scene scene) {
        var roots=new List<object>();
        foreach(var g in scene.GetRootGameObjects())roots.Add(K("name",g.name,"activeSelf",g.activeSelf,"position",V(g.transform.position),"rotation",Q(g.transform.rotation),
            "lossyScale",V(g.transform.lossyScale),"renderers",g.GetComponentsInChildren<Renderer>(true).Length));
        return roots;
    }
    static List<object> Lights() {
        var lights=new List<object>();
        foreach(var l in FindObjectsOfType<Light>())lights.Add(K("path",TPath(l.transform),"scene",l.gameObject.scene.name,"type",l.type.ToString(),"enabled",l.enabled,
            "active",l.gameObject.activeInHierarchy,"color",C(l.color),"intensity",l.intensity,"range",l.range,"spotAngle",l.spotAngle,"shadows",l.shadows.ToString(),
            "shadowStrength",l.shadowStrength,"cullingMask",l.cullingMask,"eulerAngles",V(l.transform.eulerAngles),"forward",V(l.transform.forward),"position",V(l.transform.position)));
        return lights;
    }
    static Dictionary<string,object> Lightmaps() {
        var maps=new List<object>();
        foreach(var d in LightmapSettings.lightmaps)maps.Add(K("color",d.lightmapColor==null?null:K("name",d.lightmapColor.name,"width",d.lightmapColor.width,"height",d.lightmapColor.height,"format",d.lightmapColor.format.ToString()),
            "dir",d.lightmapDir==null?null:K("name",d.lightmapDir.name,"width",d.lightmapDir.width,"height",d.lightmapDir.height,"format",d.lightmapDir.format.ToString())));
        return K("mode",LightmapSettings.lightmapsMode.ToString(),"count",maps.Count,"maps",maps);
    }
    static Dictionary<string,object> RenderSettingsRecord() {
        return K("ambientMode",RenderSettings.ambientMode.ToString(),"ambientLight",C(RenderSettings.ambientLight),"ambientSkyColor",C(RenderSettings.ambientSkyColor),
            "ambientEquatorColor",C(RenderSettings.ambientEquatorColor),"ambientGroundColor",C(RenderSettings.ambientGroundColor),"ambientIntensity",RenderSettings.ambientIntensity,
            "fog",RenderSettings.fog,"fogMode",RenderSettings.fogMode.ToString(),"fogColor",C(RenderSettings.fogColor),"fogDensity",RenderSettings.fogDensity,
            "fogStartDistance",RenderSettings.fogStartDistance,"fogEndDistance",RenderSettings.fogEndDistance,
            "skybox",RenderSettings.skybox==null?null:K("name",RenderSettings.skybox.name,"shader",RenderSettings.skybox.shader==null?null:RenderSettings.skybox.shader.name),
            "sun",RenderSettings.sun==null?null:TPath(RenderSettings.sun.transform),"reflectionIntensity",RenderSettings.reflectionIntensity,
            "defaultReflectionMode",RenderSettings.defaultReflectionMode.ToString());
    }
    object SunRecord() {
        var info=map.sunLightInfo;if(info==null)return null;
        var entries=new List<object>();
        foreach(var e in info.infos){var visible=new List<object>();foreach(var g in e.visibleList)visible.Add(g==null?null:K("path",TPath(g.transform),"activeSelf",g.activeSelf));
            entries.Add(K("type",(int)e.type,"angle",V(e.angle),"color",C(e.color),"intensity",e.intensity,"fogUse",e.fogUse,"fogStart",e.fogStart,"fogEnd",e.fogEnd,"visibleList",visible));}
        return K("selected",studio.sceneInfo.sunLightType,"entries",entries);
    }
    static Dictionary<string,object> CameraRecord(Camera c) {
        return K("name",c.name,"position",V(c.transform.position),"rotation",Q(c.transform.rotation),"eulerAngles",V(c.transform.eulerAngles),
            "fieldOfView",c.fieldOfView,"near",c.nearClipPlane,"far",c.farClipPlane,"aspect",c.aspect,"orthographic",c.orthographic,
            "worldToCamera",M(c.worldToCameraMatrix),"projection",M(c.projectionMatrix),"clearFlags",c.clearFlags.ToString(),"backgroundColor",C(c.backgroundColor),
            "cullingMask",c.cullingMask,"useOcclusionCulling",c.useOcclusionCulling,"actualRenderingPath",c.actualRenderingPath.ToString(),"allowHDR",c.allowHDR,"allowMSAA",c.allowMSAA);
    }
    static Dictionary<string,object> CameraData(Studio.CameraControl.CameraData d) {
        return d==null?null:K("pos",V(d.pos),"rotate",V(d.rotate),"distance",V(d.distance),"parse",d.parse);
    }
    void SaveTarget(RenderTexture target,string file) {
        var previous=RenderTexture.active;RenderTexture.active=target;
        var readback=new Texture2D(target.width,target.height,TextureFormat.RGBA32,false,true);readback.ReadPixels(new Rect(0,0,target.width,target.height),0,0);readback.Apply(false,false);
        File.WriteAllBytes(Path.Combine(folder,file),readback.EncodeToPNG());Destroy(readback);RenderTexture.active=previous;
    }
    static string TPath(Transform t){return t.parent==null?t.name:TPath(t.parent)+"/"+t.name;}
    static string Sha256File(string path){using(var hash=System.Security.Cryptography.SHA256.Create())return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(path))).Replace("-",String.Empty).ToLowerInvariant();}
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}static float[] V4(Vector4 v){return new[]{v.x,v.y,v.z,v.w};}
    static float[] Q(Quaternion q){return new[]{q.x,q.y,q.z,q.w};}static float[] C(Color c){return new[]{c.r,c.g,c.b,c.a};}
    static float[] M(Matrix4x4 m){var a=new float[16];for(int i=0;i<16;i++)a[i]=m[i];return a;} // column-major, Unity's m[i]
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        if(value is float)return ((float)value).ToString("R",CultureInfo.InvariantCulture);
        if(value is double)return ((double)value).ToString("R",CultureInfo.InvariantCulture);
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
