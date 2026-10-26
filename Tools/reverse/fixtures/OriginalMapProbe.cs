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
        if(errors.Count==0)yield return StartCoroutine(Guard("map33",AuthorMapOnly()));
        var showoff=Path.Combine(dir,"reload-showoff.png");
        if(errors.Count==0&&File.Exists(showoff))yield return StartCoroutine(Guard("map33-showoff",AuthorShowoff(showoff)));
        try{File.WriteAllText(Path.Combine(folder,"map-trace.json"),J(K("schemaVersion",1,"mapNo",MapNo,"width",Width,"height",Height,"depthFar",DepthFar,"cases",cases)));}
        catch(Exception e){errors.Add("trace write: "+e);}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"colorSpace",QualitySettings.activeColorSpace.ToString(),
            "voiceRepair",voiceRepair,"cases",new List<string>(cases.Keys),
            "scope","Original CharaStudio 1.0.4.2 map "+MapNo+" fixtures authored with the player's own writer (Studio.AddMap, caMap through MapCtrl.Reflect, Studio.sceneInfo.Save) and read back through Studio.LoadSceneCoroutine; per case the player's Camera.main colour image, the map scene's renderers as a white silhouette and as Unity depth-normals (linear depth over "+DepthFar+" m) from Camera.main's pose and field of view, and a trace of the map root, renderers, lights, lightmaps, RenderSettings, SunLightInfo and cameras; no installed cards, saves or media")));
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
