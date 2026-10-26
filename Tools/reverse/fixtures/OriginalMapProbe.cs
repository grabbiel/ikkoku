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
//                                         with Camera.main's pose, field of view and near plane, far = DepthFar;
//   original-<case>-map-depth-normals.png the same renderers through Hidden/Internal-DepthNormalsTexture
//                                         (Unity's EncodeDepthNormal, linear depth over DepthFar).
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
    const int MapNo=33,Width=960,Height=720,SettleFrames=30,LoadFrames=3600;
    const float DepthFar=25f;
    static readonly Vector3 MapPos=new Vector3(0.3f,-0.05f,-0.5f),MapRot=new Vector3(4f,25f,-3f);
    // A mapRoot-local point near the middle of map 33's room (the converted geometry spans x -2.17..1.46,
    // y 0..3.44, Unity z -1.64..4.19): the saved camera's pivot, so the camera stays inside the room.
    static readonly Vector3 RoomPivot=new Vector3(-0.35f,1.2f,1.27f);
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
        if(oracles.Length>0) {
            foreach(var scene in oracles) {
                if(errors.Count!=0)break;
                var label=Path.GetFileNameWithoutExtension(scene).Substring("reload-oracle-".Length);
                yield return StartCoroutine(Guard(label,LoadAndOracle(scene,label)));
            }
        } else {
            if(errors.Count==0)yield return StartCoroutine(Guard("map33",AuthorMapOnly()));
            var showoff=Path.Combine(dir,"reload-showoff.png");
            if(errors.Count==0&&File.Exists(showoff))yield return StartCoroutine(Guard("map33-showoff",AuthorShowoff(showoff)));
        }
        try{File.WriteAllText(Path.Combine(folder,oracles.Length>0?"oracle-trace.json":"map-trace.json"),J(K("schemaVersion",1,"mapNo",MapNo,"width",Width,"height",Height,"depthFar",DepthFar,"cases",cases)));}
        catch(Exception e){errors.Add("trace write: "+e);}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"colorSpace",QualitySettings.activeColorSpace.ToString(),
            "voiceRepair",voiceRepair,"cases",new List<string>(cases.Keys),
            "scope","Original CharaStudio 1.0.4.2 map "+MapNo+" fixtures authored with the player's own writer (Studio.AddMap, caMap through MapCtrl.Reflect, Studio.sceneInfo.Save) and read back through Studio.LoadSceneCoroutine; per case the player's Camera.main colour image, the map scene's renderers as a white silhouette and as Unity depth-normals (linear depth over "+DepthFar+" m) from Camera.main's pose and field of view, and a trace of the map root, renderers, lights, lightmaps, RenderSettings, SunLightInfo and cameras; no installed cards, saves or media"+
            (oracles.Length>0?". Oracle mode: the uploaded records read back, then a clean colour frame and Unity's decoded lightmap irradiance per pixel (white minus black albedo over 0.96, lights at 0 and as authored)":""))));
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
    bool Loaded(){return map.no==MapNo&&!map.isLoading&&map.mapRoot!=null&&studio.sceneInfo.map==MapNo;}
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
        studio.AddMap(MapNo,false,false,true);
        for(;frames<LoadFrames&&!Loaded();frames++)yield return null;
        if(!Loaded())throw new Exception("map "+MapNo+" did not load within "+LoadFrames+" frames (no "+map.no+", isLoading "+map.isLoading+")");
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
    IEnumerator AuthorShowoff(string source) {
        studio.InitScene(false);
        for(int i=0;i<3;i++)yield return null;
        var done=new bool[1];int frames=0;
        StartCoroutine(Track(this,studio.LoadSceneCoroutine(source),done));
        for(;frames<LoadFrames&&!done[0];frames++)yield return null;
        if(!done[0])throw new Exception("the showoff scene did not load within "+LoadFrames+" frames");
        int sourceMap=studio.sceneInfo.map,objects=studio.dicObjectCtrl.Count;
        for(int i=0;i<SettleFrames;i++)yield return null;
        float start=Time.realtimeSinceStartup;int mapFrames=0;
        studio.AddMap(MapNo,false,false,true); // SetupMap resets caMap: a newly added map sits at the origin
        for(;mapFrames<LoadFrames&&!Loaded();mapFrames++)yield return null;
        if(!Loaded())throw new Exception("map "+MapNo+" did not load into the showoff scene within "+LoadFrames+" frames");
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame();
        var authored=K("source",Path.GetFileName(source),"sourceSHA256",Sha256File(source),"sourceMap",sourceMap,"sourceLoadFrames",frames,
            "objects",objects,"addMapFrames",mapFrames,"addMapSeconds",Time.realtimeSinceStartup-start,"afterAddMap",MapRecord(),
            "savedCameraData",CameraData(studio.cameraCtrl.Export()));
        var scene=SaveScene("scene-map33-showoff.png");
        var reload=ReloadAndCapture(scene,"map33-showoff",authored);
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
        if(!(done[0]&&Loaded()))throw new Exception(label+": the saved scene did not load map "+MapNo+" within "+LoadFrames+" frames (done "+done[0]+", no "+map.no+")");
        float seconds=Time.realtimeSinceStartup-start;
        var afterLoad=MapRecord();
        for(int i=0;i<SettleFrames;i++)yield return null;
        yield return new WaitForEndOfFrame();
        var capture=Capture(label);
        cases[label]=K("label",label,"scene",Path.GetFileName(scene),"sceneSHA256",Sha256File(scene),"authored",authored,"released",released,
            "loadFrames",frames,"loadSeconds",seconds,"afterLoad",afterLoad,"settled",MapRecord(),"objects",studio.dicObjectCtrl.Count,
            "loadedCameraData",CameraData(studio.cameraCtrl.Export()),"capture",capture);
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
        var mapRenderers=new List<Renderer>();var hidden=new List<Renderer>();
        foreach(var r in FindObjectsOfType<Renderer>()) {
            if(r.gameObject.scene==mapScene){if(r.enabled&&r.gameObject.activeInHierarchy)mapRenderers.Add(r);}
            else if(r.enabled){r.enabled=false;hidden.Add(r);}
        }
        var probeObject=new GameObject("IkkokuMapProbeCamera");var cam=probeObject.AddComponent<Camera>();cam.enabled=false;
        cam.transform.position=main.transform.position;cam.transform.rotation=main.transform.rotation;
        cam.fieldOfView=main.fieldOfView;cam.nearClipPlane=main.nearClipPlane;cam.farClipPlane=DepthFar;cam.aspect=(float)Width/Height;
        cam.clearFlags=CameraClearFlags.SolidColor;cam.backgroundColor=Color.black;cam.allowHDR=false;cam.allowMSAA=false;cam.cullingMask=~0;
        cam.renderingPath=RenderingPath.Forward;cam.useOcclusionCulling=false;cam.targetTexture=target;
        var probeRecord=CameraRecord(cam);
        var saved=new Dictionary<Renderer,Material[]>();
        string whiteShader;var white=WhiteMaterial(out whiteShader);
        var mapRecords=new List<object>();
        foreach(var r in mapRenderers)mapRecords.Add(RendererRecord(r));
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
            cam.targetTexture=null;Destroy(probeObject);target.Release();Destroy(target);Destroy(white);
        }
        return K("main",mainRecord,"mainRenderMilliseconds",timer.Elapsed.TotalMilliseconds,"cameras",cameras,"mainBehaviours",effects,
            "probe",probeRecord,"whiteShader",whiteShader,"hiddenRenderers",hidden.Count,"mapRenderers",mapRecords,
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
        if(!(done[0]&&Loaded()))throw new Exception(label+": the record did not load map "+MapNo+" within "+LoadFrames+" frames (done "+done[0]+", no "+map.no+")");
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
        var saved=new Dictionary<Renderer,Material[]>();
        var lights=FindObjectsOfType<Light>();var intensities=new float[lights.Length];for(int i=0;i<lights.Length;i++)intensities[i]=lights[i].intensity;
        Material white=null,black=null;
        try {
            // The clean colour frame: Camera.main's settings, none of its image-effect components.
            cam.CopyFrom(main);cam.enabled=false;cam.aspect=(float)Width/Height;cam.targetTexture=ldr;
            var cleanRecord=CameraRecord(cam);
            cam.Render();cam.targetTexture=null;SaveTarget(ldr,"oracle-"+label+"-clean-color.png");
            foreach(var r in FindObjectsOfType<Renderer>()) {
                if(r.gameObject.scene==mapScene){if(r.enabled&&r.gameObject.activeInHierarchy)mapRenderers.Add(r);}
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
            var lightmapTextures=new List<object>();
            foreach(var d in LightmapSettings.lightmaps)foreach(var t in new[]{d.lightmapColor,d.lightmapDir})
                if(t!=null)lightmapTextures.Add(K("name",t.name,"filterMode",t.filterMode.ToString(),"anisoLevel",t.anisoLevel,"wrapMode",t.wrapMode.ToString(),
                    "mipMapBias",t.mipMapBias,"mipmapCount",t.mipmapCount,"format",t.format.ToString()));
            return K("clean",K("camera",cleanRecord,"image","oracle-"+label+"-clean-color.png"),
                "probe",probeRecord,"template",K("name",template.name,"shader",template.shader.name,"keywords",template.shaderKeywords,"renderQueue",template.renderQueue),
                "overrides",K("albedo","_Color and _MainTex white or black","metallic",0,"glossiness",0,"keywords",white.shaderKeywords),
                "mapRenderers",mapRenderers.Count,"hiddenRenderers",hidden.Count,
                "lights",Lights(),"lightIntensities",intensities,
                "irradiance",K("file","oracle-"+label+"-irradiance.f32","layout","float32 little-endian RGB, rows top-down","width",Width,"height",Height,
                    "lights","all at intensity 0","divisor",OneMinusDielectricSpec,"stats",unlitStats,"repeatMaximumDifference",repeatMax),
                "irradianceLit",K("file","oracle-"+label+"-irradiance-lit.f32","lights","as authored","stats",litStats),
                "unity_Lightmap_HDR",V4(Shader.GetGlobalVector("unity_Lightmap_HDR")),
                "colorSpace",QualitySettings.activeColorSpace.ToString(),"lightmapsMode",LightmapSettings.lightmapsMode.ToString(),
                "lightmapTextures",lightmapTextures,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString(),
                "renderSettings",RenderSettingsRecord());
        } finally {
            foreach(var pair in saved)pair.Key.sharedMaterials=pair.Value;
            for(int i=0;i<lights.Length;i++)if(lights[i]!=null)lights[i].intensity=intensities[i];
            foreach(var r in hidden)r.enabled=true;
            cam.targetTexture=null;Destroy(probeObject);ldr.Release();Destroy(ldr);hdr.Release();Destroy(hdr);
            if(white!=null)Destroy(white);if(black!=null)Destroy(black);
        }
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
    static Dictionary<string,object> RendererRecord(Renderer r) {
        var filter=r.GetComponent<MeshFilter>();var mesh=filter==null?null:filter.sharedMesh;
        var materials=new List<object>();
        foreach(var m in r.sharedMaterials)materials.Add(m==null?null:K("name",m.name,"shader",m.shader==null?null:m.shader.name,"renderQueue",m.renderQueue));
        return K("path",TPath(r.transform),"type",r.GetType().Name,"layer",r.gameObject.layer,"localToWorld",M(r.localToWorldMatrix),
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
