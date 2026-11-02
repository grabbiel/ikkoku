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
//
// The maps mode (ST-A11 slice 4), when reload-maps-showoff.png is uploaded: one run authors, reads back,
// captures and measures MapCases (phases B and C per case, like map 34) across fifteen maps (twelve until
// slice 4 PR B added maps 30, 32 and 37 and a second map 40 view), then
// "map41-showoff" (the uploaded character scene with map 41 added). An inside case puts the saved camera at
// a map-local pivot near the map root's origin with the table's yaw, pitch and distance (chosen offline from
// the converted geometry so the camera has room behind it). An outside case keeps the pivot and moves the
// camera through one of the map's vanish colliders (Studio.CameraControl.LoadVanish, h/list map_col_XX):
// the nearest listed, enabled collider on the Map/MapNoShadow layers in the map scene at least
// OutsideMinimum from the pivot, the camera looking at the pivot from twice that collider's bounds centre,
// so both the camera-to-pivot segment and its midpoint (CameraUpdate sets the view capsule's height to
// distance.z, which is negative) pass through the centre.
// Every case records the vanish state as the player holds it (CameraControl's config switch, its view
// capsule, the colliders it overlaps, and each list row's renderers with renderer.enabled) and the map
// option (Map.visibleOption, and Manager.Config.AddData.mobColor where the map has mob silhouettes). Every
// map but 33 uses DepthFar34. Renderer classes in the maps mode also separate the converter's skipped
// shaders and render-texture screens ("skipped"), renderers the converter does not read ("unconverted":
// skinned, sprite, particle-system, line, trail and billboard renderers), Particles/Anim Alpha Blended
// (a particle), Custom/Silhouette ("silhouette") and Unlit/Transparent ("unlit"); the oracle renders the
// last two alone like the sky (oracle-<case>-silhouettes.rgba.f32, -unlit.rgba.f32) and skips the
// irradiance pair when the map has no lightmaps or no keyword-free opaque Standard material (recorded).
//
// Slice 4 PR B changes the maps mode's passes; the other modes are unchanged:
// - Culling mask. The map-only passes and the oracle draw with Camera.main's culling mask, not every layer,
//   so a map renderer no Studio camera draws (a layer-0 helper) is left out on this side too. Each renderer
//   record says whether Camera.main's mask holds its layer ("drawnByMain").
// - Per-slot classes. Each material slot is classed on its own ("slots" in the renderer record), and a pass
//   draws only its own slots: the solid passes a renderer's opaque submeshes, the sky, particle, silhouette
//   and unlit passes their own submeshes. Every other slot gets HiddenMaterial, which writes no colour and
//   no depth and whose RenderType no depth-normals subshader has, so the depth-normals pass replaces by
//   "RenderType" (the white material is tagged Opaque, the subshader the "" replacement used). Each case
//   first renders every slot hidden and records that nothing was drawn ("hiddenCheck"; the case fails
//   in compare_original_map.py otherwise).
// - Irradiance template. When a map has no keyword-free opaque Standard material (map 40), the template is
//   a new material on the shader of the map's first opaque Standard material, by name, with no keywords;
//   Albedo neutralises the inputs a keyword variant would read (metallic-gloss and detail mask black, no
//   normal or emission), so whichever variant the player picks draws the same diffuse. Where both exist,
//   the oracle also renders the irradiance with this fallback and records the largest difference
//   ("fallbackTemplateCheck").
// - Realtime GI. Where a map renderer has an Enlighten dynamic lightmap, the oracle adds the term alone
//   (oracle-<case>-irradiance-dynamic.f32: the irradiance pass with every baked colour lightmap black, then
//   the irradiance again with the lightmaps restored, which must equal the first), each renderer's
//   realtimeLightmapIndex and realtimeLightmapScaleOffset, unity_DynamicLightmap_HDR, and the loaded textures
//   that may be the dynamic lightmaps, read back (RealtimeLightmaps) and digested again RealtimeSettleFrames
//   later ("realtimeLightmapsLater"); then, for the other two sun types in turn (Map.sunType, as authored),
//   the same read-back after RealtimeSettleFrames and its digest that many frames later
//   (oracle-<case>-realtime-sun<type>-<n>.rgba.f32, "realtimeLightmapsOtherSunTypes"). Each sun type's entry
//   also records RenderSettings there ("renderSettings"), and the record the restored type's
//   ("restoredRenderSettings"), so the runtime ambient probe is read under every sun type (maps slice 5).
// - Slice 5 read-backs (read only, nothing set): every RenderSettings record carries RenderSettings.ambientProbe
//   as 27 floats in the serialized m_AmbientProbe order ("ambientProbe"); every light record carries its
//   runtime shadowBias, shadowNormalBias, shadowNearPlane, shadowResolution and shadowCustomResolution; and
//   each capture records the quality level's shadow settings ("shadowQuality": level and name, shadows,
//   shadowResolution, shadowProjection, shadowDistance, shadowCascades and both split settings,
//   shadowNearPlaneOffset).
// - Vanish. Each case's vanish record adds what the trigger needs ("physics": the camera object's layer and
//   its collision-matrix row, Time.timeScale and the fixed step, its rigidbody, the LateUpdate gate, and the
//   Map-layer colliders the view capsule overlaps by Physics.OverlapCapsule). After the case's images the
//   probe waits TriggerSteps fixed steps and records the vanish state again ("vanishAfterFixedSteps"), then
//   runs the trigger experiment ("triggerExperiment": test capsules like the view capsule on the camera's
//   layer and on layer 0, and what their own trigger callbacks saw). Every such wait counts fixed steps for
//   at most FixedStepTimeout real seconds, since none runs while Time.timeScale is 0; in that case the
//   vanish state is recorded once more with the time scale at 1 for those steps ("vanishWithTimeScale1").
//
// The lighting mode (maps slice 5), when reload-lighting.png is uploaded (a marker whose content is not read): its
// own exec after the maps mode's, with the maps mode's passes and records, over LightingCases: each MapCases case
// whose map shows a sun, then new inside cases for maps 20 and 28, and no showoff case. Their cameras come from
// .local/sta11d-pr-b/slice5/lighting_cameras.py on the slice-5 export: map 20's yaw has the largest smaller share
// of lit and shadowed sun-facing rays; no view of map 28 from five pivots shows more than 1% shadowed, so its
// yaw sees the most lit surface (a no-shadow control). Only the oracle changes, and only in this mode:
// - A map without baked lightmaps keeps the irradiance pair. Without a lightmap Unity's indirect diffuse is the
//   ambient (UnityGI_Base's SH) or the renderer's dynamic lightmap, which slice 5 gates. The dynamic-lightmap
//   swap runs only where there are baked lightmaps to swap.
// - After the lit pass, the lit pass again with every light's shadows None
//   (oracle-<case>-irradiance-lit-unshadowed.f32, "irradianceLitUnshadowed"), so a pixel's sun visibility is
//   (lit - irradiance) / (unshadowed - irradiance). Each light's shadow type is saved first and put back in a
//   finally block (the oracle's own finally puts it back too). The probe then reads every type back and stops the
//   run if one differs ("shadowsRestored"), and renders the lit pass once more, which must equal the first
//   ("litRepeatMaximumDifference", "litRepeatMatches").
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
    const string Map34Upload="reload-map34-showoff.png",MapsUpload="reload-maps-showoff.png",LightingUpload="reload-lighting.png";
    const float OutsideMinimum=1f;
    const int TriggerSteps=5; // fixed steps the vanish re-record and the trigger experiment wait (PR B)
    const float FixedStepTimeout=3f; // real seconds those waits allow: no fixed step runs while Time.timeScale is 0
    const int RealtimeSettleFrames=120; // frames between the two reads of the dynamic lightmaps (PR B)
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
    // The maps mode's cases (see the header): map, sun type, MapPos/MapRot or reset, inside or outside,
    // map option, map-local pivot, pitch, yaw relative to the map and distance (inside cases).
    sealed class MapCase {
        public string label;public int no,sunType;public bool transformed,outside,option;public Vector3 pivot;public float pitch,yaw,distance;
        public MapCase(string l,int n,int s,bool t,bool o,bool opt,Vector3 p,float pitchDegrees,float yawDegrees,float d){label=l;no=n;sunType=s;transformed=t;outside=o;option=opt;pivot=p;pitch=pitchDegrees;yaw=yawDegrees;distance=d;}
    }
    static readonly Vector3 Pivot=new Vector3(0f,1.1f,0f);
    static readonly MapCase[] MapCases={
        new MapCase("map41",41,0,true,false,true,Pivot,8f,315f,3f),
        new MapCase("map21",21,1,false,false,true,Pivot,8f,240f,3f),
        new MapCase("map11",11,0,false,false,true,Pivot,8f,315f,3f),
        new MapCase("map19",19,2,true,false,true,Pivot,8f,30f,3f),
        new MapCase("map22",22,0,false,false,true,Pivot,8f,120f,3f),
        new MapCase("map29",29,1,false,false,true,Pivot,8f,180f,3f),
        new MapCase("map38",38,0,false,false,true,Pivot,8f,90f,3f),
        new MapCase("map40",40,2,true,false,true,Pivot,8f,150f,3f),
        new MapCase("map15",15,0,false,false,true,Pivot,8f,135f,3f),
        new MapCase("map25",25,1,true,false,true,Pivot,8f,270f,3f),
        new MapCase("map01",1,0,false,false,true,Pivot,8f,75f,3f),
        new MapCase("map27",27,2,false,false,true,Pivot,8f,0f,3f),
        new MapCase("map21-outside",21,0,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map11-outside",11,0,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map19-outside",19,0,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map22-outside",22,1,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map15-outside",15,0,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map25-outside",25,0,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map01-outside",1,0,false,true,true,Pivot,0f,0f,0f),
        new MapCase("map27-outside",27,0,false,true,true,Pivot,0f,0f,0f),
        // PR B: the realtime-GI maps without a case (pivot and yaw by .local/sta11d-pr-b/tools/choose_cameras.py:
        // the yaw with the most free room behind the pivot), and a map 40 view over its Unlit/Transparent road
        // shadows (the densest 4 m cluster of them; 95 % of a 32x24 ray grid lands on them).
        new MapCase("map30",30,0,false,false,true,Pivot,8f,165f,3f),
        new MapCase("map32",32,0,false,false,true,Pivot,8f,60f,3f),
        new MapCase("map37",37,0,false,false,true,Pivot,8f,180f,3f),
        new MapCase("map40-unlit",40,0,false,false,true,new Vector3(13.06f,1.1f,-25.22f),35f,75f,5f)};
    // The lighting mode's cases (see the header): the MapCases labels whose map shows a sun (29, 30, 32, 37 and 38
    // show none), then maps 20 and 28, which have no baked lightmaps and no maps-mode case.
    static readonly string[] LightingLabels={"map41","map21","map11","map19","map22","map40","map15","map25","map01","map27",
        "map21-outside","map11-outside","map19-outside","map22-outside","map15-outside","map25-outside","map01-outside","map27-outside","map40-unlit"};
    static readonly MapCase[] LightingExtraCases={
        new MapCase("map20",20,0,false,false,true,Pivot,8f,LightingYaw20,3f),
        new MapCase("map28",28,0,false,false,true,Pivot,8f,LightingYaw28,3f)};
    const float LightingYaw20=180f,LightingYaw28=180f;
    // LightingLabels' cases in order, then LightingExtraCases; a label MapCases lacks is an error, not a skip.
    static List<MapCase> LightingCases(List<string> errors) {
        var found=new List<MapCase>();
        foreach(var label in LightingLabels) {
            MapCase match=null;foreach(var c in MapCases)if(c.label==label)match=c;
            if(match==null)errors.Add("lighting mode: no MapCases case "+label);else found.Add(match);
        }
        found.AddRange(LightingExtraCases);return found;
    }
    // Shaders export_map_scene.py skips (MAP_SKIPPED_SHADERS): not drawn by the app.
    static readonly string[] SkippedShaders={"FX/MirrorReflection_Transparent","Xffect/heat_distortion","Shader Forge/electricLight",
        "Shader Forge/spotLaser","Shader Forge/spotLight_beam","Shader Forge/spotLight_glow","Shader Forge/volumeLight",
        "UnlitMosaicTextureShader","Particles/VertexLit Blended"};
    int mapNo=33;float depthFar=DepthFar33;bool withOracle,mapsMode,lightingMode;
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
        var map34=Path.Combine(dir,Map34Upload);var maps=Path.Combine(dir,MapsUpload);var lighting=Path.Combine(dir,LightingUpload);
        if(oracles.Length>0) {
            foreach(var scene in oracles) {
                if(errors.Count!=0)break;
                var label=Path.GetFileNameWithoutExtension(scene).Substring("reload-oracle-".Length);
                UseMap(label.StartsWith("map34")?34:33);
                yield return StartCoroutine(Guard(label,LoadAndOracle(scene,label)));
            }
        } else if(File.Exists(lighting)) {
            withOracle=true;mapsMode=true;lightingMode=true;
            foreach(var c in LightingCases(errors))if(errors.Count==0){UseMap(c.no);yield return StartCoroutine(Guard(c.label,AuthorMapCase(c)));}
        } else if(File.Exists(maps)) {
            withOracle=true;mapsMode=true;
            foreach(var c in MapCases)if(errors.Count==0){UseMap(c.no);yield return StartCoroutine(Guard(c.label,AuthorMapCase(c)));}
            if(errors.Count==0){UseMap(41);yield return StartCoroutine(Guard("map41-showoff",AuthorShowoff(maps,"map41-showoff")));}
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
        try{File.WriteAllText(Path.Combine(folder,oracles.Length>0?"oracle-trace.json":"map-trace.json"),J(K("schemaVersion",1,"mapNo",mapsMode?null:(object)mapNo,
            "width",Width,"height",Height,"depthFar",mapsMode?null:(object)depthFar,"mode",lightingMode?"lighting":mapsMode?"maps":null,"cases",cases)));}
        catch(Exception e){errors.Add("trace write: "+e);}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"colorSpace",QualitySettings.activeColorSpace.ToString(),
            "voiceRepair",voiceRepair,"cases",new List<string>(cases.Keys),
            "scope","Original CharaStudio 1.0.4.2 map "+(lightingMode?"(lighting mode: "+(LightingLabels.Length+LightingExtraCases.Length)+" cases across twelve maps with a sun; the oracle adds the lit pass without shadows, and keeps the irradiance pair in maps without lightmaps)":mapsMode?"(maps mode: "+MapCases.Length+" cases across fifteen maps, and map41-showoff)":mapNo.ToString())+" fixtures authored with the player's own writer (Studio.AddMap, caMap through MapCtrl.Reflect, Studio.sceneInfo.Save) and read back through Studio.LoadSceneCoroutine; per case the player's Camera.main colour image, the map scene's renderers as a white silhouette and as Unity depth-normals (linear depth over "+depthFar+" m) from Camera.main's pose and field of view, and a trace of the map root, renderers, lights, lightmaps, RenderSettings, SunLightInfo and cameras; no installed cards, saves or media"+
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
    void UseMap(int no){mapNo=no;depthFar=no==33?DepthFar33:DepthFar34;}
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
    // The maps mode: one case (see the header).
    IEnumerator AuthorMapCase(MapCase c) {
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
        if(map.isOption)map.visibleOption=c.option;
        var root=map.mapRoot.transform;var target=root.TransformPoint(c.pivot);
        var view=new Studio.CameraControl.CameraData();view.pos=target;view.parse=45f;
        object outside=null;
        if(c.outside) {
            var candidates=new List<object>();Collider pick=null;string row=null;float best=float.MaxValue;int layers=LayerMask.GetMask("Map","MapNoShadow");
            foreach(var entry in VanishRows()) {
                var name=(string)Field(entry,"nameCollider");var renderers=Field(entry,"listRender") as IList;
                foreach(var collider in MapColliders(name)) {
                    var offset=collider.bounds.center-target;float distance=offset.magnitude;
                    bool live=collider.enabled&&collider.gameObject.activeInHierarchy&&(layers&(1<<collider.gameObject.layer))!=0;
                    candidates.Add(K("row",name,"path",TPath(collider.transform),"layer",collider.gameObject.layer,"live",live,"center",V(collider.bounds.center),
                        "size",V(collider.bounds.size),"distance",distance,"renderers",renderers==null?0:renderers.Count));
                    if(live&&renderers!=null&&renderers.Count>0&&distance>=OutsideMinimum&&distance<best){best=distance;pick=collider;row=name;}
                }
            }
            if(pick==null)throw new Exception(c.label+": no live listed vanish collider in the map scene at least "+OutsideMinimum+" m from the pivot ("+candidates.Count+" candidates)");
            var centre=pick.bounds.center;var camera=target+2f*(centre-target);
            var euler=Quaternion.LookRotation(target-camera).eulerAngles;
            view.rotate=new Vector3(euler.x,euler.y,0f);view.distance=new Vector3(0f,0f,-(target-camera).magnitude);
            outside=K("row",row,"collider",TPath(pick.transform),"colliderCenter",V(centre),"camera",V(camera),"rule","camera = pivot + 2 (centre - pivot)",
                "minimum",OutsideMinimum,"candidates",candidates);
        } else {
            view.rotate=new Vector3(c.pitch,(c.transformed?MapRot.y:0f)+c.yaw,0f);view.distance=new Vector3(0f,0f,-c.distance);
        }
        studio.cameraCtrl.Import(view);
        for(int i=0;i<2;i++)yield return new WaitForEndOfFrame();
        var authored=K("mapNo",c.no,"addMapFrames",frames,"addMapSeconds",Time.realtimeSinceStartup-start,"afterAddMap",added,"reflected",MapRecord(),
            "requestedPosition",c.transformed?V(MapPos):V(Vector3.zero),"requestedRotation",c.transformed?V(MapRot):V(Vector3.zero),
            "requestedSunType",c.sunType,"requestedMapOption",c.option,"isOption",map.isOption,"mobColor",MobColor(),
            "pivot",V(c.pivot),"target",V(target),"outside",outside,"activeSkies",ActivePaths("sky"),
            "savedCameraData",K("pos",V(view.pos),"rotate",V(view.rotate),"distance",V(view.distance),"parse",view.parse));
        var scene=SaveScene("scene-"+c.label+".png");
        var reload=ReloadAndCapture(scene,c.label,authored);
        while(reload.MoveNext())yield return reload.Current;
    }
    // CameraControl's vanish rows (LoadVanish): private, read by reflection.
    IList VanishRows(){var rows=Field(studio.cameraCtrl,"lstMapVanish") as IList;return rows??new List<object>();}
    // The map scene's colliders named `name` (any layer; the trace records the layer).
    List<Collider> MapColliders(string name) {
        var found=new List<Collider>();
        foreach(var collider in Resources.FindObjectsOfTypeAll<Collider>())
            if(collider!=null&&collider.name==name&&collider.gameObject.scene==map.mapRoot.scene)found.Add(collider);
        return found;
    }
    static object Field(object o,string name) {
        if(o==null)return null;
        for(var t=o.GetType();t!=null;t=t.BaseType) {
            var f=t.GetField(name,System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
            if(f!=null)return f.GetValue(o);
            var p=t.GetProperty(name,System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
            if(p!=null&&p.GetIndexParameters().Length==0)return p.GetValue(o,null);
        }
        return null;
    }
    static object MobColor(){try{return C(Manager.Config.AddData.mobColor);}catch(Exception e){return "unreadable: "+e.Message;}}
    // The vanish state as the player holds it now (see the header).
    Dictionary<string,object> VanishRecord() {
        var ctrl=studio.cameraCtrl;var view=Field(ctrl,"viewCollider") as CapsuleCollider;
        var overlapping=new List<object>();var listed=Field(ctrl,"listCollider") as IList;
        if(listed!=null)foreach(var o in listed){var col=o as Collider;overlapping.Add(col==null?null:K("name",col.name,"path",TPath(col.transform),"layer",col.gameObject.layer));}
        var rows=new List<object>();int hidden=0;
        foreach(var entry in VanishRows()) {
            var renderers=new List<object>();var list=Field(entry,"listRender") as IList;
            if(list!=null)foreach(var o in list){var r=o as Renderer;if(r==null){renderers.Add(null);continue;}if(!r.enabled)hidden++;
                renderers.Add(K("path",TPath(r.transform),"enabled",r.enabled,"active",r.gameObject.activeInHierarchy));}
            var colliders=new List<object>();
            foreach(var col in MapColliders((string)Field(entry,"nameCollider")))colliders.Add(K("path",TPath(col.transform),"layer",col.gameObject.layer,
                "type",col.GetType().Name,"isTrigger",col.isTrigger,"enabled",col.enabled,"active",col.gameObject.activeInHierarchy,
                "boundsMin",V(col.bounds.min),"boundsMax",V(col.bounds.max)));
            rows.Add(K("nameCollider",Field(entry,"nameCollider"),"isVisible",Field(entry,"isVisible"),"delay",Field(entry,"delay"),
                "renderers",renderers,"colliders",colliders));
        }
        return K("configVanish",ctrl.isConfigVanish,"mapLayer",Field(ctrl,"mapLayer"),"isLimitDir",ctrl.isLimitDir,"limitDir",ctrl.limitDir,
            "isLimitPos",ctrl.isLimitPos,"limitPos",ctrl.limitPos,"hiddenRenderers",hidden,"overlapping",overlapping,"rows",rows,
            "viewCollider",view==null?null:K("enabled",view.enabled,"isTrigger",view.isTrigger,"center",V(view.center),"height",view.height,"radius",view.radius,
                "direction",view.direction,"boundsMin",V(view.bounds.min),"boundsMax",V(view.bounds.max),"position",V(view.transform.position),
                "rotation",Q(view.transform.rotation),"lossyScale",V(view.transform.lossyScale)),
            "physics",PhysicsRecord(ctrl,view));
    }
    // What the vanish trigger needs (PR B): the camera object's layer and its row of the layer collision matrix,
    // the time scale and fixed step, the camera's rigidbody, the LateUpdate gate, and which Map-layer colliders
    // the view capsule overlaps geometrically (Physics.OverlapCapsule with |height|, and a sphere of the
    // capsule's radius at its centre for the reading where a negative height collapses the segment).
    Dictionary<string,object> PhysicsRecord(Studio.CameraControl ctrl,CapsuleCollider view) {
        var go=ctrl.gameObject;int layer=go.layer;var body=go.GetComponent<Rigidbody>();int mapMask=LayerMask.GetMask("Map","MapNoShadow");
        var cameraRow=new List<object>();var mapRow=new List<object>();
        for(int i=0;i<32;i++){cameraRow.Add(!Physics.GetIgnoreLayerCollision(layer,i));mapRow.Add(!Physics.GetIgnoreLayerCollision(11,i));}
        object overlap=null;
        if(view!=null) {
            var t=view.transform;float radius=view.radius;float half=Mathf.Max(Mathf.Abs(view.height)*0.5f-radius,0f);
            var centre=t.TransformPoint(view.center);var axis=t.TransformDirection(Vector3.forward); // direction 2: the local Z axis
            overlap=K("centre",V(centre),"halfSegment",half,"radius",radius,
                "capsule",Names(Physics.OverlapCapsule(centre-axis*half,centre+axis*half,radius,mapMask,QueryTriggerInteraction.Collide)),
                "sphereAtCentre",Names(Physics.OverlapSphere(centre,radius,mapMask,QueryTriggerInteraction.Collide)));
        }
        var scene=Singleton<Manager.Scene>.Instance;
        return K("cameraObject",TPath(go.transform),"cameraLayer",layer,"cameraLayerName",LayerMask.LayerToName(layer),"mapMask",mapMask,
            "cameraCollidesWithMap",!Physics.GetIgnoreLayerCollision(layer,11),"cameraLayerRow",cameraRow,"mapLayerRow",mapRow,
            "timeScale",Time.timeScale,"fixedDeltaTime",Time.fixedDeltaTime,"maximumDeltaTime",Time.maximumDeltaTime,
            "frameCount",Time.frameCount,"time",Time.time,"fixedTime",Time.fixedTime,"queriesHitTriggers",Physics.queriesHitTriggers,
            "rigidbody",body==null?null:K("isKinematic",body.isKinematic,"detectCollisions",body.detectCollisions,"useGravity",body.useGravity,
                "isSleeping",body.IsSleeping(),"position",V(body.position),"interpolation",body.interpolation.ToString(),
                "collisionDetectionMode",body.collisionDetectionMode.ToString()),
            "controlEnabled",ctrl.enabled,"isInit",Field(ctrl,"isInit"),"isFlashVisible",ctrl.isFlashVisible,
            "lateUpdateGate",K("addSceneName",scene.AddSceneName,"isNowLoadingFade",scene.IsNowLoadingFade),
            "overlap",overlap);
    }
    static List<object> Names(Collider[] colliders) {
        var list=new List<object>();
        foreach(var c in colliders)if(c!=null)list.Add(K("path",TPath(c.transform),"layer",c.gameObject.layer,"type",c.GetType().Name,"isTrigger",c.isTrigger));
        return list;
    }
    // Frames until `steps` fixed steps have run, at most FixedStepTimeout seconds of real time (WaitForFixedUpdate
    // never returns while Time.timeScale is 0); records the steps seen, the real time and the time scale.
    IEnumerator FixedSteps(int steps,Dictionary<string,object> into) {
        var go=new GameObject("IkkokuFixedStepCounter");var counter=go.AddComponent<IkkokuTriggerTest>();
        float start=Time.realtimeSinceStartup;
        while(counter.fixedSteps<steps&&Time.realtimeSinceStartup-start<FixedStepTimeout)yield return null;
        into["fixedSteps"]=counter.fixedSteps;into["timedOut"]=counter.fixedSteps<steps;
        into["realSeconds"]=Time.realtimeSinceStartup-start;into["timeScale"]=Time.timeScale;
        Destroy(go);
    }
    // The trigger experiment (PR B): kinematic trigger capsules like Studio's view capsule, at its pose, on the
    // camera's layer and on layer 0, with the capsule's own (negative) height and with its absolute value, held
    // for TriggerSteps fixed steps; what each one's OnTriggerEnter/OnTriggerStay saw. It runs after the case's
    // images, and the test objects are destroyed before the next case.
    IEnumerator TriggerExperiment(Dictionary<string,object> result) {
        var ctrl=studio.cameraCtrl;var view=Field(ctrl,"viewCollider") as CapsuleCollider;
        if(view==null){result["skipped"]="no view capsule";yield break;}
        var layers=new List<int>{ctrl.gameObject.layer};if(ctrl.gameObject.layer!=0)layers.Add(0);
        var tests=new List<IkkokuTriggerTest>();
        foreach(var layer in layers)foreach(var negative in new[]{true,false}) {
            var go=new GameObject("IkkokuTriggerTest-"+layer+(negative?"-raw":"-abs"));go.layer=layer;
            go.transform.position=view.transform.position;go.transform.rotation=view.transform.rotation;
            var capsule=go.AddComponent<CapsuleCollider>();capsule.isTrigger=true;capsule.direction=2;capsule.radius=view.radius;
            capsule.height=negative?view.height:Mathf.Abs(view.height);capsule.center=view.center;
            var body=go.AddComponent<Rigidbody>();body.useGravity=false;body.isKinematic=true;
            var test=go.AddComponent<IkkokuTriggerTest>();test.layer=layer;test.rawHeight=negative;tests.Add(test);
        }
        // Frames until every test has seen TriggerSteps fixed steps, at most FixedStepTimeout seconds of real time
        // (WaitForFixedUpdate never returns while Time.timeScale is 0).
        float start=Time.realtimeSinceStartup;
        while(Time.realtimeSinceStartup-start<FixedStepTimeout) {
            int fewest=int.MaxValue;foreach(var test in tests)fewest=Math.Min(fewest,test.fixedSteps);
            if(fewest>=TriggerSteps)break;
            yield return null;
        }
        result["realSeconds"]=Time.realtimeSinceStartup-start;result["timeScale"]=Time.timeScale;
        var records=new List<object>();
        foreach(var test in tests) {
            var capsule=test.GetComponent<CapsuleCollider>();
            records.Add(K("layer",test.layer,"rawHeight",test.rawHeight,"height",capsule.height,"boundsMin",V(capsule.bounds.min),"boundsMax",V(capsule.bounds.max),
                "fixedSteps",test.fixedSteps,"entered",test.entered,"stayed",test.stayed));
            Destroy(test.gameObject);
        }
        result["tests"]=records;result["steps"]=TriggerSteps;
        yield return null;
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
        var vanish=mapsMode?VanishRecord():null; // as the colour frame shows it
        var capture=Capture(label);
        var record=K("label",label,"mapNo",mapNo,"depthFar",depthFar,"scene",Path.GetFileName(scene),"sceneSHA256",Sha256File(scene),"authored",authored,"released",released,
            "loadFrames",frames,"loadSeconds",seconds,"afterLoad",afterLoad,"settled",MapRecord(),"objects",studio.dicObjectCtrl.Count,
            "loadedCameraData",CameraData(studio.cameraCtrl.Export()),"capture",capture);
        if(mapsMode)record["vanish"]=vanish;
        if(withOracle)record["oracle"]=Oracle(label);
        if(mapsMode&&withOracle) {
            // Realtime GI: the candidate dynamic lightmaps again RealtimeSettleFrames later, by digest, to show
            // whether Enlighten had settled when the oracle read them.
            bool hasDynamic=false;foreach(var r in FindObjectsOfType<Renderer>())if(r.gameObject.scene==map.mapRoot.scene&&HasDynamicLightmap(r)){hasDynamic=true;break;}
            if(hasDynamic) {
                for(int i=0;i<RealtimeSettleFrames;i++)yield return null;
                record["realtimeLightmapsLater"]=K("frames",RealtimeSettleFrames,"textures",RealtimeLightmaps(label,"",false));
                // The other two sun types' dynamic lightmaps, read back the same way (no images): the sun type set
                // as the authoring sets it, RealtimeSettleFrames to settle, a read, and a digest that many frames later.
                var current=map.sunType;var others=new Dictionary<string,object>();
                foreach(SunLightInfo.Info.Type type in Enum.GetValues(typeof(SunLightInfo.Info.Type))) {
                    if(type==current)continue;
                    map.sunType=type;
                    for(int i=0;i<RealtimeSettleFrames;i++)yield return null;
                    var read=RealtimeLightmaps(label,"-sun"+(int)type,true);
                    for(int i=0;i<RealtimeSettleFrames;i++)yield return null;
                    others[((int)type).ToString(CultureInfo.InvariantCulture)]=K("sunType",(int)type,"lights",Lights(),"textures",read,"later",RealtimeLightmaps(label,"",false),
                        "renderSettings",RenderSettingsRecord()); // slice 5: the ambient probe under this sun type, settled
                }
                map.sunType=current;
                for(int i=0;i<RealtimeSettleFrames;i++)yield return null;
                record["realtimeLightmapsOtherSunTypes"]=K("restoredSunType",(int)current,"bySunType",others,"restoredRenderSettings",RenderSettingsRecord());
            }
        }
        if(mapsMode) {
            // The vanish state again after explicit physics steps and a LateUpdate, then the trigger experiment.
            var wait=new Dictionary<string,object>();var steps=FixedSteps(TriggerSteps,wait);
            while(steps.MoveNext())yield return steps.Current;
            yield return null;yield return new WaitForEndOfFrame();
            var after=VanishRecord();after["wait"]=wait;record["vanishAfterFixedSteps"]=after;
            var experiment=new Dictionary<string,object>();var run=TriggerExperiment(experiment);
            while(run.MoveNext())yield return run.Current;
            record["triggerExperiment"]=experiment;
            // With Time.timeScale 0 no physics step runs, so no trigger can fire: then the same re-record with the
            // time scale at 1 for those steps, and 0 again after it.
            if(Time.timeScale==0f) {
                Time.timeScale=1f;var scaledWait=new Dictionary<string,object>();var scaledSteps=FixedSteps(TriggerSteps,scaledWait);
                while(scaledSteps.MoveNext())yield return scaledSteps.Current;
                yield return null;yield return new WaitForEndOfFrame();
                var scaled=VanishRecord();scaled["wait"]=scaledWait;
                Time.timeScale=0f;
                record["vanishWithTimeScale1"]=scaled;
            }
        }
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
        var mapRecords=new List<object>();var slots=new Dictionary<Renderer,string[]>();
        foreach(var r in FindObjectsOfType<Renderer>()) {
            if(r.gameObject.scene==mapScene) {
                if(!(r.enabled&&r.gameObject.activeInHierarchy))continue;
                var kind=RendererClass(r);var classes=SlotClasses(r);slots[r]=classes;mapRecords.Add(RendererRecord(r,kind,classes,main.cullingMask));
                if(Array.IndexOf(classes,"solid")>=0)mapRenderers.Add(r);else{r.enabled=false;excluded.Add(r);}
            }
            else if(r.enabled){r.enabled=false;hidden.Add(r);}
        }
        var probeObject=new GameObject("IkkokuMapProbeCamera");var cam=probeObject.AddComponent<Camera>();cam.enabled=false;
        cam.transform.position=main.transform.position;cam.transform.rotation=main.transform.rotation;
        cam.fieldOfView=main.fieldOfView;cam.nearClipPlane=main.nearClipPlane;cam.farClipPlane=depthFar;cam.aspect=(float)Width/Height;
        cam.clearFlags=CameraClearFlags.SolidColor;cam.backgroundColor=Color.black;cam.allowHDR=false;cam.allowMSAA=false;cam.cullingMask=PassMask(main);
        cam.renderingPath=RenderingPath.Forward;cam.useOcclusionCulling=false;cam.targetTexture=target;
        var probeRecord=CameraRecord(cam);
        var saved=new Dictionary<Renderer,Material[]>();
        string whiteShader;var white=WhiteMaterial(out whiteShader);var none=mapsMode?HiddenMaterial():null;
        // The depth-normals replacement: by RenderType in the maps mode (hidden slots match no subshader), every
        // material through the first subshader otherwise (see the header).
        string replacement=mapsMode?"RenderType":"";
        object hiddenCheck=null,coverage=null;int mixed=0,hiddenSlots=0;
        try {
            var depthShader=Shader.Find("Hidden/Internal-DepthNormalsTexture");
            if(depthShader==null)throw new Exception("Hidden/Internal-DepthNormalsTexture is not in this player");
            var depthTarget=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Linear);depthTarget.Create();
            foreach(var r in mapRenderers)saved[r]=r.sharedMaterials;
            if(mapsMode) {
                // Every slot hidden: neither pass may draw anything.
                foreach(var r in mapRenderers){var m=new Material[saved[r].Length];for(int i=0;i<m.Length;i++)m[i]=none;r.sharedMaterials=m;}
                cam.targetTexture=target;cam.backgroundColor=Color.black;cam.Render();int colour=Drawn(target,Color.black);
                cam.targetTexture=depthTarget;cam.backgroundColor=Color.white;cam.RenderWithShader(depthShader,replacement);int depth=Drawn(depthTarget,Color.white);
                hiddenCheck=K("renderers",mapRenderers.Count,"colourPixels",colour,"depthNormalsPixels",depth,"passes",colour==0&&depth==0);
            }
            foreach(var r in mapRenderers) {
                var classes=slots[r];var m=new Material[saved[r].Length];bool partial=false;
                for(int i=0;i<m.Length;i++){bool solid=i<classes.Length&&classes[i]=="solid";m[i]=solid?white:none;if(!solid){partial=true;hiddenSlots++;}}
                if(partial)mixed++;
                r.sharedMaterials=m;
            }
            cam.targetTexture=target;cam.backgroundColor=Color.black;
            cam.Render();SaveTarget(target,"original-"+label+"-map-geometry.png");
            cam.targetTexture=depthTarget;cam.backgroundColor=Color.white;cam.RenderWithShader(depthShader,replacement);
            SaveTarget(depthTarget,"original-"+label+"-map-depth-normals.png");
            // The two passes draw the same slots, so they cover the same pixels (recorded, not enforced).
            if(mapsMode)coverage=K("geometryPixels",Drawn(target,Color.black),"depthNormalsPixels",Drawn(depthTarget,Color.white));
            cam.targetTexture=null;depthTarget.Release();Destroy(depthTarget);
        } finally {
            foreach(var pair in saved)pair.Key.sharedMaterials=pair.Value;
            foreach(var r in hidden)r.enabled=true;
            foreach(var r in excluded)r.enabled=true;
            cam.targetTexture=null;Destroy(probeObject);target.Release();Destroy(target);Destroy(white);if(none!=null)Destroy(none);
        }
        return K("main",mainRecord,"mainRenderMilliseconds",timer.Elapsed.TotalMilliseconds,"cameras",cameras,"mainBehaviours",effects,
            "probe",probeRecord,"whiteShader",whiteShader,"hiddenRenderers",hidden.Count,"mapRenderers",mapRecords,
            "solidRenderers",mapRenderers.Count,"excludedRenderers",ClassCounts(excluded),
            "depthNormalsReplacementTag",replacement,"mixedRenderers",mixed,"hiddenSlots",hiddenSlots,"hiddenCheck",hiddenCheck,"coverage",coverage,
            "mapScene",K("name",mapScene.name,"path",mapScene.path,"isActive",SceneManager.GetActiveScene()==mapScene,"roots",Roots(mapScene)),
            "lights",Lights(),"lightmaps",Lightmaps(),"renderSettings",RenderSettingsRecord(),"sunLightInfo",SunRecord(),
            "quality",K("pixelLightCount",QualitySettings.pixelLightCount,"shadows",QualitySettings.shadows.ToString(),"antiAliasing",QualitySettings.antiAliasing,
                "masterTextureLimit",QualitySettings.masterTextureLimit,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString()),
            "shadowQuality",ShadowQuality(),
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
        var silhouettes=new List<Renderer>();var unlits=new List<Renderer>();
        var saved=new Dictionary<Renderer,Material[]>();var slots=new Dictionary<Renderer,string[]>();
        var lights=FindObjectsOfType<Light>();var intensities=new float[lights.Length];for(int i=0;i<lights.Length;i++)intensities[i]=lights[i].intensity;
        var shadowTypes=new LightShadows[lights.Length];for(int i=0;i<lights.Length;i++)shadowTypes[i]=lights[i].shadows;
        bool runtimeFog=RenderSettings.fog;
        var fogRecord=K("fog",RenderSettings.fog,"fogMode",RenderSettings.fogMode.ToString(),"fogColor",C(RenderSettings.fogColor),
            "fogStartDistance",RenderSettings.fogStartDistance,"fogEndDistance",RenderSettings.fogEndDistance,"fogDensity",RenderSettings.fogDensity);
        Material white=null,black=null,fallback=null,fallbackWhite=null,fallbackBlack=null;var classMaterials=new List<Material>();Texture2D blackLightmap=null;
        var none=mapsMode?HiddenMaterial():null;
        try {
            // The clean colour frame: Camera.main's settings, none of its image-effect components.
            cam.CopyFrom(main);cam.enabled=false;cam.aspect=(float)Width/Height;cam.targetTexture=ldr;
            var cleanRecord=CameraRecord(cam);
            cam.Render();cam.targetTexture=null;SaveTarget(ldr,"oracle-"+label+"-clean-color.png");
            // The measurement passes: fog off, the map's renderers only, the solid ones unless a pass says otherwise.
            RenderSettings.fog=false;
            // Per-slot classes (see the header): a renderer joins the solid set when a slot is solid and each group
            // set (sky, particle, silhouette, unlit) when a slot is of that group; "others" have neither.
            foreach(var r in FindObjectsOfType<Renderer>()) {
                if(r.gameObject.scene==mapScene) {
                    if(!(r.enabled&&r.gameObject.activeInHierarchy))continue;
                    var classes=SlotClasses(r);slots[r]=classes;saved[r]=r.sharedMaterials;bool grouped=false;
                    foreach(var g in new[]{"sky","particle","silhouette","unlit"})
                        if(Array.IndexOf(classes,g)>=0){(g=="sky"?skies:g=="particle"?particles:g=="silhouette"?silhouettes:unlits).Add(r);grouped=true;}
                    if(Array.IndexOf(classes,"solid")>=0)mapRenderers.Add(r);
                    else{r.enabled=false;if(!grouped)others.Add(r);}
                }
                else if(r.enabled){r.enabled=false;hidden.Add(r);}
            }
            // The first (by name) keyword-free opaque Standard material the map draws with, or (maps mode) a new
            // material on the shader of the first opaque Standard material with any keywords (see the header).
            var template=StandardMaterial(mapRenderers,slots,true);
            var fallbackSource=mapsMode?StandardMaterial(mapRenderers,slots,false):null;
            if(fallbackSource!=null)fallback=FallbackTemplate(fallbackSource.shader);
            int bakedMaps=LightmapSettings.lightmaps==null?0:LightmapSettings.lightmaps.Length;
            var used=template??fallback;
            string irradianceSkipped=bakedMaps==0&&!lightingMode?"the map has no baked lightmaps":used==null?"no opaque Standard material on the map's renderers":null;
            if(irradianceSkipped!=null&&!mapsMode)throw new Exception(irradianceSkipped);
            if(irradianceSkipped==null){white=Albedo(used,Color.white);black=Albedo(used,Color.black);}
            if(irradianceSkipped==null&&template!=null&&fallback!=null){fallbackWhite=Albedo(fallback,Color.white);fallbackBlack=Albedo(fallback,Color.black);}
            cam.CopyFrom(main);cam.enabled=false;cam.aspect=(float)Width/Height;
            cam.clearFlags=CameraClearFlags.SolidColor;cam.backgroundColor=Color.black;cam.allowHDR=true;cam.allowMSAA=false;cam.cullingMask=PassMask(main);
            cam.renderingPath=RenderingPath.Forward;cam.useOcclusionCulling=false;
            var probeRecord=CameraRecord(cam);
            var unlitStats=new Dictionary<string,object>();var litStats=new Dictionary<string,object>();double repeatMax=0;object fallbackCheck=null,dynamicRecord=null,unshadowedRecord=null;
            int dynamicRenderers=0;
            if(irradianceSkipped==null) {
                for(int i=0;i<lights.Length;i++)lights[i].intensity=0f;
                var gi=Difference(cam,hdr,mapRenderers,slots,none,white,black,unlitStats);
                var repeat=Difference(cam,hdr,mapRenderers,slots,none,white,black,new Dictionary<string,object>());
                for(int i=0;i<gi.Length;i++)repeatMax=Math.Max(repeatMax,Math.Abs((double)gi[i]-repeat[i]));
                WriteFloats(gi,"oracle-"+label+"-irradiance.f32");
                if(fallbackWhite!=null) {
                    var alternative=Difference(cam,hdr,mapRenderers,slots,none,fallbackWhite,fallbackBlack,new Dictionary<string,object>());
                    double most=0;for(int i=0;i<gi.Length;i++)most=Math.Max(most,Math.Abs((double)gi[i]-alternative[i]));
                    fallbackCheck=K("source",fallbackSource.name,"sourceKeywords",fallbackSource.shaderKeywords,"maximumDifference",most);
                }
                // Realtime GI (see the header): the dynamic lightmaps' term alone, every baked colour lightmap
                // swapped for black for two renders, then the irradiance again with the lightmaps restored.
                foreach(var r in mapRenderers)if(HasDynamicLightmap(r))dynamicRenderers++;
                if(mapsMode&&dynamicRenderers>0&&bakedMaps>0) {
                    var baked=LightmapSettings.lightmaps;var swapped=new LightmapData[baked.Length];blackLightmap=BlackTexture();
                    for(int i=0;i<baked.Length;i++){var d=new LightmapData();d.lightmapColor=blackLightmap;d.lightmapDir=baked[i].lightmapDir;swapped[i]=d;}
                    float[] dynamicOnly;
                    try{LightmapSettings.lightmaps=swapped;dynamicOnly=Difference(cam,hdr,mapRenderers,slots,none,white,black,new Dictionary<string,object>());}
                    finally{LightmapSettings.lightmaps=baked;}
                    var restored=Difference(cam,hdr,mapRenderers,slots,none,white,black,new Dictionary<string,object>());
                    double most=0;for(int i=0;i<gi.Length;i++)most=Math.Max(most,Math.Abs((double)gi[i]-restored[i]));
                    WriteFloats(dynamicOnly,"oracle-"+label+"-irradiance-dynamic.f32");
                    dynamicRecord=K("written",true,"file","oracle-"+label+"-irradiance-dynamic.f32","layout","float32 little-endian RGB, rows top-down",
                        "rule","the irradiance pass with every LightmapData colour map black (direction maps kept), lights at intensity 0",
                        "renderers",dynamicRenderers,"restoredMaximumDifference",most,"restored",most==0);
                }
                for(int i=0;i<lights.Length;i++)lights[i].intensity=intensities[i];
                var lit=Difference(cam,hdr,mapRenderers,slots,none,white,black,litStats);
                WriteFloats(lit,"oracle-"+label+"-irradiance-lit.f32");
                if(lightingMode)unshadowedRecord=Unshadowed(label,lit,lights,shadowTypes,cam,hdr,mapRenderers,slots,none,white,black);
            }
            // Which solid pixels the irradiance gate may compare: Standard on a baked lightmap.
            var lightmapped=ClassMaterial(Color.white,classMaterials);var probeLit=ClassMaterial(Color.red,classMaterials);var other=ClassMaterial(Color.green,classMaterials);
            int lightmapCount=LightmapSettings.lightmaps==null?0:LightmapSettings.lightmaps.Length;
            var classCounts=new Dictionary<string,object>();int lightmappedRenderers=0,probeLitRenderers=0,otherSlots=0;
            foreach(var r in mapRenderers) {
                bool baked=r.lightmapIndex>=0&&r.lightmapIndex<lightmapCount;
                var m=new Material[r.sharedMaterials.Length];var classes=slots[r];
                for(int i=0;i<m.Length;i++){
                    if(!(i<classes.Length&&classes[i]=="solid")){m[i]=none;continue;}
                    var source=saved[r][i];bool standard=source!=null&&source.shader!=null&&(source.shader.name=="Standard"
                    ||(mapsMode&&(source.shader.name=="Custom/StandardDouble"||source.shader.name=="Legacy Shaders/Diffuse")));
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
            foreach(var pass in new[]{"sky","particles","silhouettes","unlit"}) {
                var set=pass=="sky"?skies:pass=="particles"?particles:pass=="silhouettes"?silhouettes:unlits;
                if(set.Count==0){groups[pass]=K("written",false);continue;}
                // Each renderer draws only this group's slots (in the other modes every slot is the renderer's class).
                string group=pass=="particles"?"particle":pass=="silhouettes"?"silhouette":pass;int otherGroupSlots=0;
                foreach(var r in set) {
                    var classes=slots[r];var m=new Material[saved[r].Length];
                    for(int i=0;i<m.Length;i++){bool own=i<classes.Length&&classes[i]==group;m[i]=own?saved[r][i]:none;if(!own)otherGroupSlots++;}
                    r.sharedMaterials=m;r.enabled=true;
                }
                var rgba=RenderAlone(cam,hdr);
                foreach(var r in set){r.enabled=false;r.sharedMaterials=saved[r];}
                var file="oracle-"+label+"-"+pass+".rgba.f32";WriteFloats(rgba,file);
                var materials=new List<object>();foreach(var r in set)materials.Add(K("path",TPath(r.transform),"materials",GroupMaterials(r)));
                groups[pass]=K("written",true,"file",file,"layout","float32 little-endian RGBA, rows top-down","renderers",materials,"farClipPlane",SkyFar,
                    "background","(0,0,0,0)","coveredPixels",Covered(rgba,pass=="sky"),"otherSlotsHidden",otherGroupSlots);
            }
            foreach(var r in mapRenderers)r.enabled=true;
            var lightmapTextures=new List<object>();
            foreach(var d in LightmapSettings.lightmaps)foreach(var t in new[]{d.lightmapColor,d.lightmapDir})
                if(t!=null)lightmapTextures.Add(K("name",t.name,"filterMode",t.filterMode.ToString(),"anisoLevel",t.anisoLevel,"wrapMode",t.wrapMode.ToString(),
                    "mipMapBias",t.mipMapBias,"mipmapCount",t.mipmapCount,"format",t.format.ToString()));
            var record=K("clean",K("camera",cleanRecord,"image","oracle-"+label+"-clean-color.png"),
                "probe",probeRecord,"template",used==null?null:K("name",used.name,"shader",used.shader.name,"keywords",used.shaderKeywords,"renderQueue",used.renderQueue,
                    "source",template!=null?"keyword-free map material":"new material on the shader of "+fallbackSource.name,
                    "shaderIsShaderFindStandard",used.shader==Shader.Find("Standard")),
                "fallbackTemplateCheck",fallbackCheck,
                "irradianceDynamic",dynamicRecord,"realtimeLightmaps",mapsMode&&dynamicRenderers>0?RealtimeLightmaps(label,"",true):null,
                "unity_DynamicLightmap_HDR",V4(Shader.GetGlobalVector("unity_DynamicLightmap_HDR")),
                "overrides",white==null?null:K("albedo","_Color and _MainTex white or black","metallic",0,"glossiness",0,"keywords",white.shaderKeywords),
                "irradianceSkipped",irradianceSkipped,
                "mapRenderers",mapRenderers.Count,"hiddenRenderers",hidden.Count,
                "excludedRenderers",K("sky",skies.Count,"particle",particles.Count,"nonOpaque",others.Count,"silhouette",silhouettes.Count,"unlit",unlits.Count,"other",mapsMode?ClassCounts(others):null),
                "runtimeFog",fogRecord,"measurementFog",false,
                "lights",Lights(),"lightIntensities",intensities,
                "irradiance",irradianceSkipped!=null?K("written",false,"reason",irradianceSkipped):K("written",true,"file","oracle-"+label+"-irradiance.f32","layout","float32 little-endian RGB, rows top-down","width",Width,"height",Height,
                    "lights","all at intensity 0","divisor",OneMinusDielectricSpec,"stats",unlitStats,"repeatMaximumDifference",repeatMax),
                "irradianceLit",irradianceSkipped!=null?K("written",false,"reason",irradianceSkipped):K("written",true,"file","oracle-"+label+"-irradiance-lit.f32","lights","as authored","stats",litStats),
                "classes",K("image","oracle-"+label+"-classes.png","white",(mapsMode?"Standard, Custom/StandardDouble or Legacy Shaders/Diffuse":"Standard")+" on a baked lightmap",
                    "red",(mapsMode?"one of those":"Standard")+" without a lightmap (light probes)",
                    "green","another shader","lightmaps",lightmapCount,"counts",classCounts),
                "sky",groups["sky"],"particles",groups["particles"],"silhouettes",groups["silhouettes"],"unlit",groups["unlit"],
                "quality",K("softParticles",QualitySettings.softParticles,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString()),
                "mainDepthTextureMode",main.depthTextureMode.ToString(),"mainFarClipPlane",main.farClipPlane,
                "unity_Lightmap_HDR",V4(Shader.GetGlobalVector("unity_Lightmap_HDR")),
                "colorSpace",QualitySettings.activeColorSpace.ToString(),"lightmapsMode",LightmapSettings.lightmapsMode.ToString(),
                "lightmapTextures",lightmapTextures,"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString(),
                "renderSettings",RenderSettingsRecord());
            if(lightingMode)record["irradianceLitUnshadowed"]=irradianceSkipped!=null?K("written",false,"reason",irradianceSkipped):unshadowedRecord;
            return record;
        } finally {
            foreach(var pair in saved)pair.Key.sharedMaterials=pair.Value;
            for(int i=0;i<lights.Length;i++)if(lights[i]!=null){lights[i].intensity=intensities[i];if(lights[i].shadows!=shadowTypes[i])lights[i].shadows=shadowTypes[i];}
            RenderSettings.fog=runtimeFog;
            foreach(var r in mapRenderers)if(r!=null)r.enabled=true;
            foreach(var set in new[]{hidden,skies,particles,silhouettes,unlits,others})foreach(var r in set)if(r!=null)r.enabled=true;
            cam.targetTexture=null;Destroy(probeObject);ldr.Release();Destroy(ldr);hdr.Release();Destroy(hdr);
            foreach(var m in new[]{white,black,fallback,fallbackWhite,fallbackBlack,none})if(m!=null)Destroy(m);
            if(blackLightmap!=null)Destroy(blackLightmap);
            foreach(var m in classMaterials)Destroy(m);
        }
    }
    // The lighting mode's lit pass without shadows (see the header). Every light's shadow type goes back in the
    // finally block; a type that does not read back as saved stops the run, and the lit pass rendered again must
    // equal `lit`.
    Dictionary<string,object> Unshadowed(string label,float[] lit,Light[] lights,LightShadows[] authored,Camera cam,RenderTexture hdr,
        List<Renderer> mapRenderers,Dictionary<Renderer,string[]> slots,Material none,Material white,Material black) {
        var stats=new Dictionary<string,object>();float[] unshadowed;
        try{for(int i=0;i<lights.Length;i++)lights[i].shadows=LightShadows.None;unshadowed=Difference(cam,hdr,mapRenderers,slots,none,white,black,stats);}
        finally{for(int i=0;i<lights.Length;i++)if(lights[i]!=null)lights[i].shadows=authored[i];}
        var before=new List<object>();var after=new List<object>();var differing=new List<string>();
        for(int i=0;i<lights.Length;i++) {
            var path=TPath(lights[i].transform);
            before.Add(K("path",path,"shadows",authored[i].ToString()));after.Add(K("path",path,"shadows",lights[i].shadows.ToString()));
            if(lights[i].shadows!=authored[i])differing.Add(path+": "+lights[i].shadows+" instead of "+authored[i]);
        }
        if(differing.Count>0)throw new Exception("the lights' shadow types did not read back as saved: "+String.Join("; ",differing.ToArray()));
        var again=Difference(cam,hdr,mapRenderers,slots,none,white,black,new Dictionary<string,object>());
        double most=0;for(int i=0;i<lit.Length;i++)most=Math.Max(most,Math.Abs((double)lit[i]-again[i]));
        var file="oracle-"+label+"-irradiance-lit-unshadowed.f32";WriteFloats(unshadowed,file);
        return K("written",true,"file",file,"layout","float32 little-endian RGB, rows top-down","lights","as authored, every light's shadows None",
            "stats",stats,"shadowsBefore",before,"shadowsRestored",after,"restored",true,
            "litRepeatMaximumDifference",most,"litRepeatMatches",most==0,
            "rule","sun visibility = (lit - irradiance) / (unshadowed - irradiance) where the denominator is positive");
    }
    static bool HasDynamicLightmap(Renderer r){return r.realtimeLightmapIndex>=0&&r.realtimeLightmapIndex<0xFFFE;}
    static Texture2D BlackTexture() {
        var t=new Texture2D(4,4,TextureFormat.RGBA32,false,true);var c=new Color32[16];for(int i=0;i<16;i++)c[i]=new Color32(0,0,0,0);
        t.SetPixels32(c);t.Apply(false,false);return t;
    }
    // The textures that may be Enlighten's dynamic lightmaps (see the header): every loaded texture whose name
    // holds "realtime", "dynamic" or "enlighten" is read back through Graphics.Blit into a linear float target
    // (what a shader's sample returns) and, when `write`, saved as oracle-<case>-realtime<suffix>-<n>.rgba.f32;
    // unnamed runtime textures are listed (at most 100) so a later run can name them.
    Dictionary<string,object> RealtimeLightmaps(string label,string suffix,bool write) {
        var named=new List<object>();var unnamed=new List<object>();int n=0;
        foreach(var t in Resources.FindObjectsOfTypeAll<Texture>()) {
            if(t==null)continue;var name=t.name??"";var lower=name.ToLowerInvariant();
            var d=K("name",name,"type",t.GetType().Name,"instanceId",t.GetInstanceID(),"width",t.width,"height",t.height,"hideFlags",t.hideFlags.ToString(),
                "filterMode",t.filterMode.ToString(),"wrapMode",t.wrapMode.ToString(),"format",t is Texture2D?((Texture2D)t).format.ToString():t is RenderTexture?((RenderTexture)t).format.ToString():null);
            if((lower.Contains("realtime")||lower.Contains("dynamic")||lower.Contains("enlighten"))&&t.dimension==UnityEngine.Rendering.TextureDimension.Tex2D) {
                var rgba=ReadTexture(t);d["sha256"]=Sha256Floats(rgba);
                if(write){var file="oracle-"+label+"-realtime"+suffix+"-"+n+".rgba.f32";WriteFloats(rgba,file);d["file"]=file;d["layout"]="float32 little-endian RGBA, rows top-down";}
                n++;named.Add(d);
            } else if(name.Length==0&&t.hideFlags!=HideFlags.None&&unnamed.Count<100)unnamed.Add(d);
        }
        return K("named",named,"unnamed",unnamed);
    }
    static float[] ReadTexture(Texture t) {
        var target=new RenderTexture(t.width,t.height,0,RenderTextureFormat.ARGBFloat,RenderTextureReadWrite.Linear);target.Create();
        Graphics.Blit(t,target);
        var previous=RenderTexture.active;RenderTexture.active=target;
        var read=new Texture2D(t.width,t.height,TextureFormat.RGBAFloat,false,true);read.ReadPixels(new Rect(0,0,t.width,t.height),0,0);read.Apply(false,false);
        RenderTexture.active=previous;var pixels=read.GetPixels();Destroy(read);target.Release();Destroy(target);
        var rgba=new float[t.width*t.height*4];
        for(int y=0;y<t.height;y++)for(int x=0;x<t.width;x++){var c=pixels[(t.height-1-y)*t.width+x];int o=(y*t.width+x)*4;rgba[o]=c.r;rgba[o+1]=c.g;rgba[o+2]=c.b;rgba[o+3]=c.a;}
        return rgba;
    }
    static string Sha256Floats(float[] values) {
        var bytes=new byte[values.Length*4];Buffer.BlockCopy(values,0,bytes,0,bytes.Length);
        using(var hash=System.Security.Cryptography.SHA256.Create())return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-",String.Empty).ToLowerInvariant();
    }
    // The maps mode's passes draw with Camera.main's culling mask; the other modes with every layer (see the header).
    int PassMask(Camera main){return mapsMode?main.cullingMask:~0;}
    // Each material slot's class (see the header). Outside the maps mode every slot takes the renderer's class,
    // so a pass draws a renderer whole, as before.
    string[] SlotClasses(Renderer r) {
        var materials=r.sharedMaterials;var classes=new string[materials.Length];
        if(!mapsMode||!(r is MeshRenderer)){var kind=RendererClass(r);for(int i=0;i<classes.Length;i++)classes[i]=kind;return classes;}
        for(int i=0;i<materials.Length;i++)classes[i]=MaterialClass(materials[i]);
        return classes;
    }
    // One slot's class in the maps mode, by the rules RendererClass applies to the whole renderer.
    static string MaterialClass(Material m) {
        if(m==null||m.shader==null)return "nonOpaque";
        var name=m.shader.name;
        if(Array.IndexOf(SkippedShaders,name)>=0||(m.HasProperty("_MainTex")&&m.GetTexture("_MainTex") is RenderTexture))return "skipped";
        if(name=="Skybox/Cubemap")return "sky";
        if(name=="Particles/Alpha Blended"||name=="Particles/Anim Alpha Blended")return "particle";
        if(name=="Custom/Silhouette")return "silhouette";
        if(name=="Unlit/Transparent")return "unlit";
        return m.GetTag("RenderType",true)=="Opaque"?"solid":"nonOpaque";
    }
    // A slot that must not draw (see the header): blend (Zero, One) and no depth write, so a camera pass leaves
    // the target as it was, and a RenderType no depth-normals subshader has, so the replacement skips it.
    static Material HiddenMaterial() {
        var shader=Shader.Find("Hidden/Internal-Colored");
        if(shader==null)throw new Exception("Hidden/Internal-Colored is not in this player");
        var m=new Material(shader);m.name="IkkokuHiddenSlot";m.color=new Color(1f,0f,1f,1f);
        m.SetInt("_SrcBlend",0);m.SetInt("_DstBlend",1);m.SetInt("_ZWrite",0);m.SetInt("_ZTest",8);m.SetInt("_Cull",0);
        m.SetOverrideTag("RenderType","IkkokuHidden");
        return m;
    }
    // How many pixels of `target` differ from the clear colour (8-bit read-back).
    int Drawn(RenderTexture target,Color background) {
        var previous=RenderTexture.active;RenderTexture.active=target;
        var read=new Texture2D(target.width,target.height,TextureFormat.RGBA32,false,true);read.ReadPixels(new Rect(0,0,target.width,target.height),0,0);read.Apply(false,false);
        RenderTexture.active=previous;
        var clear=(Color32)background;int n=0;
        foreach(var c in read.GetPixels32())if(c.r!=clear.r||c.g!=clear.g||c.b!=clear.b||c.a!=clear.a)n++;
        Destroy(read);return n;
    }
    // The first (by name) opaque Standard material on the solid slots: keyword-free, or with any keywords.
    static Material StandardMaterial(List<Renderer> renderers,Dictionary<Renderer,string[]> slots,bool keywordFree) {
        Material found=null;
        foreach(var r in renderers) {
            var materials=r.sharedMaterials;var classes=slots[r];
            for(int i=0;i<materials.Length;i++) {
                var m=materials[i];
                if(i<classes.Length&&classes[i]=="solid"&&m!=null&&m.shader!=null&&m.shader.name=="Standard"&&(!keywordFree||NoKeywords(m))
                   &&m.renderQueue<=2500&&m.HasProperty("_Mode")&&m.GetFloat("_Mode")==0f&&(found==null||String.CompareOrdinal(m.name,found.name)<0))found=m;
            }
        }
        return found;
    }
    // A new opaque material on the map's own Standard shader object, without keywords (see the header).
    static Material FallbackTemplate(Shader shader) {
        var m=new Material(shader);m.name="IkkokuStandardTemplate";m.shaderKeywords=new string[0];
        if(m.HasProperty("_Mode"))m.SetFloat("_Mode",0f);
        m.SetInt("_SrcBlend",1);m.SetInt("_DstBlend",0);m.SetInt("_ZWrite",1);
        return m;
    }
    // A renderer's class for the map-only passes (see the header): "sky", "particle", "solid" (every material
    // RenderType=Opaque) or "nonOpaque"; in the maps mode also "unconverted" (not a MeshRenderer), "skipped"
    // (a shader the converter skips, or a render-texture screen), "silhouette" and "unlit".
    string RendererClass(Renderer r) {
        if(!mapsMode) {
            bool sky0=false,particle0=false,opaque0=r.sharedMaterials.Length>0;
            foreach(var m in r.sharedMaterials) {
                if(m==null||m.shader==null){opaque0=false;continue;}
                if(m.shader.name=="Skybox/Cubemap")sky0=true;else if(m.shader.name=="Particles/Alpha Blended")particle0=true;
                if(m.GetTag("RenderType",true)!="Opaque")opaque0=false;
            }
            return sky0?"sky":particle0?"particle":opaque0?"solid":"nonOpaque";
        }
        if(!(r is MeshRenderer))return "unconverted";
        bool sky=false,particle=false,silhouette=false,unlit=false,skipped=false,opaque=r.sharedMaterials.Length>0;
        foreach(var m in r.sharedMaterials) {
            if(m==null||m.shader==null){opaque=false;continue;}
            var name=m.shader.name;
            if(Array.IndexOf(SkippedShaders,name)>=0||(m.HasProperty("_MainTex")&&m.GetTexture("_MainTex") is RenderTexture))skipped=true;
            else if(name=="Skybox/Cubemap")sky=true;else if(name=="Particles/Alpha Blended"||name=="Particles/Anim Alpha Blended")particle=true;
            else if(name=="Custom/Silhouette")silhouette=true;else if(name=="Unlit/Transparent")unlit=true;
            if(m.GetTag("RenderType",true)!="Opaque")opaque=false;
        }
        return skipped?"skipped":sky?"sky":particle?"particle":silhouette?"silhouette":unlit?"unlit":opaque?"solid":"nonOpaque";
    }
    Dictionary<string,object> ClassCounts(List<Renderer> renderers) {
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
    // player) with the albedo forced and no metallic or smoothness. In the maps mode it also neutralises what a
    // keyword variant would read (see the header): metallic-gloss and detail masks black, the default normal
    // map, no parallax, occlusion strength 0.
    Material Albedo(Material template,Color color) {
        var m=new Material(template);m.shaderKeywords=new string[0];
        m.SetColor("_Color",color);m.SetTexture("_MainTex",Texture2D.whiteTexture);
        m.SetFloat("_Metallic",0f);m.SetFloat("_Glossiness",0f);m.SetColor("_EmissionColor",Color.black);
        if(mapsMode) {
            foreach(var p in new[]{"_MetallicGlossMap","_DetailMask"})if(m.HasProperty(p))m.SetTexture(p,Texture2D.blackTexture);
            foreach(var p in new[]{"_BumpMap","_ParallaxMap","_EmissionMap","_DetailAlbedoMap","_DetailNormalMap"})if(m.HasProperty(p))m.SetTexture(p,null);
            foreach(var p in new[]{"_Parallax","_OcclusionStrength","_GlossMapScale"})if(m.HasProperty(p))m.SetFloat(p,0f);
        }
        return m;
    }
    float[] Difference(Camera cam,RenderTexture target,List<Renderer> renderers,Dictionary<Renderer,string[]> slots,Material none,Material white,Material black,Dictionary<string,object> stats) {
        var a=RenderWith(cam,target,renderers,slots,none,white);var b=RenderWith(cam,target,renderers,slots,none,black);
        var d=new float[a.Length];int nonFinite=0,negative=0,positive=0;double max=0,sum=0;
        for(int i=0;i<a.Length;i++) {
            float v=(a[i]-b[i])/OneMinusDielectricSpec;d[i]=v;
            if(float.IsNaN(v)||float.IsInfinity(v)){nonFinite++;continue;}
            if(v<0)negative++;else if(v>0){positive++;sum+=v;if(v>max)max=v;}
        }
        stats["nonFinite"]=nonFinite;stats["negative"]=negative;stats["positive"]=positive;stats["maximum"]=max;stats["meanPositive"]=positive>0?sum/positive:0;
        return d;
    }
    // `material` on each renderer's solid slots, `none` on the rest (every slot is solid outside the maps mode).
    float[] RenderWith(Camera cam,RenderTexture target,List<Renderer> renderers,Dictionary<Renderer,string[]> slots,Material none,Material material) {
        foreach(var r in renderers){var classes=slots[r];var m=new Material[r.sharedMaterials.Length];
            for(int i=0;i<m.Length;i++)m[i]=i<classes.Length&&classes[i]=="solid"?material:none;r.sharedMaterials=m;}
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
        var white=new Material(shader);white.color=Color.white;white.SetOverrideTag("RenderType","Opaque"); // the depth-normals replacement's first subshader
        white.SetInt("_Cull",2);white.SetInt("_ZWrite",1);white.SetInt("_ZTest",4);white.SetInt("_SrcBlend",1);white.SetInt("_DstBlend",0); // back-face culled, opaque, like the map's Standard materials
        return white;
    }
    Dictionary<string,object> MapRecord() {
        var ca=studio.sceneInfo.caMap;var root=map.mapRoot;
        object rootRecord=null;
        if(root!=null){var t=root.transform;rootRecord=K("name",root.name,"scene",root.scene.name,"parent",t.parent==null?null:t.parent.name,
            "localPosition",V(t.localPosition),"localRotation",Q(t.localRotation),"localEulerAngles",V(t.localEulerAngles),"localScale",V(t.localScale),
            "position",V(t.position),"rotation",Q(t.rotation),"lossyScale",V(t.lossyScale),"localToWorld",M(t.localToWorldMatrix));}
        return K("no",map.no,"isLoading",map.isLoading,"sceneInfoMap",studio.sceneInfo.map,"sunLightType",studio.sceneInfo.sunLightType,"mapOption",studio.sceneInfo.mapOption,"isOption",map.isOption,
            "caMap",K("pos",V(ca.pos),"rot",V(ca.rot),"scale",V(ca.scale)),"expectedRotation",Q(Quaternion.Euler(ca.rot)),"mapRoot",rootRecord,
            "activeScene",SceneManager.GetActiveScene().name);
    }
    static Dictionary<string,object> RendererRecord(Renderer r,string kind,string[] slots,int mainMask) {
        var filter=r.GetComponent<MeshFilter>();var mesh=filter==null?null:filter.sharedMesh;
        var materials=new List<object>();
        foreach(var m in r.sharedMaterials)materials.Add(m==null?null:K("name",m.name,"shader",m.shader==null?null:m.shader.name,"renderQueue",m.renderQueue));
        return K("path",TPath(r.transform),"class",kind,"slots",slots,"drawnByMain",((mainMask>>r.gameObject.layer)&1)!=0,
            "type",r.GetType().Name,"layer",r.gameObject.layer,"localToWorld",M(r.localToWorldMatrix),
            "boundsMin",V(r.bounds.min),"boundsMax",V(r.bounds.max),"lightmapIndex",r.lightmapIndex,"lightmapScaleOffset",V4(r.lightmapScaleOffset),
            "realtimeLightmapIndex",r.realtimeLightmapIndex,"realtimeLightmapScaleOffset",V4(r.realtimeLightmapScaleOffset),
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
            "shadowStrength",l.shadowStrength,"cullingMask",l.cullingMask,"eulerAngles",V(l.transform.eulerAngles),"forward",V(l.transform.forward),"position",V(l.transform.position),
            // Slice 5: the runtime shadow state, to compare with the scene files' m_Shadows.
            "shadowBias",l.shadowBias,"shadowNormalBias",l.shadowNormalBias,"shadowNearPlane",l.shadowNearPlane,
            "shadowResolution",l.shadowResolution.ToString(),"shadowCustomResolution",l.shadowCustomResolution));
        return lights;
    }
    // Slice 5: the quality level's shadow settings (read only), which size and place the sun's shadow map.
    static Dictionary<string,object> ShadowQuality() {
        int level=QualitySettings.GetQualityLevel();var names=QualitySettings.names;
        return K("level",level,"name",level>=0&&level<names.Length?names[level]:null,"shadows",QualitySettings.shadows.ToString(),
            "shadowResolution",QualitySettings.shadowResolution.ToString(),"shadowProjection",QualitySettings.shadowProjection.ToString(),
            "shadowDistance",QualitySettings.shadowDistance,"shadowCascades",QualitySettings.shadowCascades,
            "shadowCascade2Split",QualitySettings.shadowCascade2Split,"shadowCascade4Split",V(QualitySettings.shadowCascade4Split),
            "shadowNearPlaneOffset",QualitySettings.shadowNearPlaneOffset);
    }
    // Slice 5: RenderSettings.ambientProbe as 27 floats in the serialized m_AmbientProbe order (red 0-8, green 9-17, blue 18-26).
    static List<object> AmbientProbe() {
        var sh=RenderSettings.ambientProbe;var values=new List<object>();
        for(int c=0;c<3;c++)for(int i=0;i<9;i++)values.Add(sh[c,i]);
        return values;
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
            "defaultReflectionMode",RenderSettings.defaultReflectionMode.ToString(),"ambientProbe",AmbientProbe());
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
// The trigger experiment's recorder (OriginalMapProbe.TriggerExperiment): every collider its kinematic trigger
// capsule entered or stayed in, by path and layer, and the fixed steps it saw.
public sealed class IkkokuTriggerTest:MonoBehaviour {
    public int layer,fixedSteps;public bool rawHeight;
    public readonly List<string> entered=new List<string>(),stayed=new List<string>();
    void FixedUpdate(){fixedSteps++;}
    void OnTriggerEnter(Collider other){Note(entered,other);}
    void OnTriggerStay(Collider other){Note(stayed,other);}
    static void Note(List<string> list,Collider other) {
        if(other==null)return;
        var name=TransformPath(other.transform)+"@"+other.gameObject.layer;
        if(!list.Contains(name))list.Add(name);
    }
    static string TransformPath(Transform t){return t.parent==null?t.name:TransformPath(t.parent)+"/"+t.name;}
}
