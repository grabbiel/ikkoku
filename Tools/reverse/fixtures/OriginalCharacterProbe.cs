// Private validation player only. This creates a fresh fully clothed fixture;
// no installed card, thumbnail, save, plug-in, or arbitrary camera is captured.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using BepInEx;
using UnityEngine;
using UnityEngine.Rendering;

[BepInPlugin("org.ikkoku.validation.characterprobe", "Ikkoku character probe", "1.0.0")]
public sealed class OriginalCharacterProbe : BaseUnityPlugin
{
    const int Layer = 30, Width = 768, Height = 1024;
    string folder; ChaControl character;
    readonly List<object> textures = new List<object>();
    readonly Dictionary<int,string> textureFiles = new Dictionary<int,string>();
    readonly List<object> fingerRecords = new List<object>();
    // ST-T07f optional hand-pattern mode. Non-null only when hand-patterns.tsv
    // (rows "L<TAB>k" and "R<TAB>k") sits in the plugin folder; every output
    // stays as before when the file is absent.
    Dictionary<string,int> handPatterns;
    readonly List<object> handAnimeRecords = new List<object>();
    // ST-T07i optional look-pattern mode. Non-null only when look-patterns.tsv
    // (rows "neckPtn<TAB>eyesPtn<TAB>frames<TAB>x,y,z") sits in the plugin
    // folder; every existing output stays as before when the file is absent.
    readonly List<int[]> lookPhases = new List<int[]>();
    readonly List<Vector3> lookTargetPositions = new List<Vector3>();
    readonly List<object> lookRecords = new List<object>();
    string lookError;
    // ST-T07x: the card-driven EyeLookMaterialControll inputs the load-time
    // ChangeSettingEye*/ChangeSettingEyeTilt calls read, recorded once into
    // the look trace header; like every other look field it stays unwritten
    // when no look-patterns.tsv is present.
    Dictionary<string,object> irisCard;
    Transform lookTarget; // dedicated target transform the look controllers follow; Studio owns Camera.main
    IEnumerator Start()
    {
        folder = Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location), "character");
        Directory.CreateDirectory(folder);
        // A malformed optional tsv ends the run through status.json instead of
        // killing this coroutine silently. Without either file both loaders
        // return at once, so the no-tsv frame sequence and outputs are unchanged.
        string error = null;
        try { TryLoadHandPatterns(); TryLoadLookPatterns(); }
        catch(Exception e) {
            // Drop any rows read before the bad one so Finish writes no partial look trace.
            handPatterns=null; lookPhases.Clear(); lookTargetPositions.Clear();
            error="Probe input rejected: "+e.Message;
        }
        for (int i=0;i<30;i++) yield return null;
        // CharaStudio ignored Application.Quit when Finish ran on the first frame
        // (the player kept running on the VM), so a rejected input is reported
        // after the usual 30-frame wait and the quit repeats until the player exits.
        if(error != null) {
            Finish(error);
            for(int i=0;i<3600;i++) { yield return null; if(i%30==29) Application.Quit(); }
            yield break;
        }
        // ST-T07i: CharaStudio's main scene load destroys freshly created
        // objects, so look mode waits for the scene camera and then 60 more
        // settled frames before it builds the fixture; without the tsv this
        // block never runs and every existing output stays byte-identical.
        if(lookPhases.Count>0) {
            for(int i=0;i<3600&&Camera.main==null;i++) yield return null;
            if(Camera.main==null) { Finish("Camera.main did not appear within 3600 frames; the look capture needs Studio's loaded scene"); yield break; }
            for(int i=0;i<60;i++) yield return null;
        }
        try { CreateFixture(); } catch(Exception e) { error=e.ToString(); }
        if(error != null) { Finish(error); yield break; }
        var load=character.LoadAsync(false,false);
        for(;;) {
            bool more=false; object step=null;
            try { more=load.MoveNext(); if(more) step=load.Current; } catch(Exception e) { error=e.ToString(); }
            if(error != null || !more) break;
            yield return step;
        }
        if(error != null) { Finish(error); yield break; }
        // ST-T07f: recovered Studio behavior is HandAnimeCtrl.Init(sex) then
        // ptn=k, where the ptn setter calls LoadAnime, which for patterns 1-21
        // enables the hand Animator and Play()s the named clip. Play() writes
        // bones on the next Animator update, so the moment-(b) snapshot below
        // still holds the default-state pose and frame0 starts the pattern.
        if(handPatterns!=null)ApplyHandPatterns();
        // Moment (b): right after LoadAsync finishes, before the 10-frame wait.
        RecordFingers("afterLoadAsync");
        // ST-T07i: the look phases run before the 10-frame wait and the capture.
        // The controllers' own LateUpdate runs after the Animator and after a
        // plain "yield return null" resume, so each frame is recorded at
        // WaitForEndOfFrame, once both LateUpdates have run.
        if(lookPhases.Count>0) {
            // ST-T07x: the card values the load-time ChangeSettingEye* and
            // ChangeSettingEyeTilt calls read, recorded once after LoadAsync
            // (which applied them) and before the phases start.
            RecordIrisCard();
            if(lookError!=null) { Finish(lookError); yield break; }
            yield return RunLookPhases();
            if(lookError!=null) { Finish(lookError); yield break; }
        }
        // ST-T07c: record every frame of the wait so the first frame whose
        // rotations match sample-list index 1 can be pinned to a frame number.
        for(int i=0;i<10;i++){yield return null;RecordFingers("frame"+i);if(handPatterns!=null)RecordHandAnime("frame"+i);}
        try { Capture(); } catch(Exception e) { error=e.ToString(); }
        Finish(error!=null?error:lookError); // a look failure must not be reported as a clean run
    }
    void Finish(string error) {
        File.WriteAllText(Path.Combine(folder,"status.json"),J(new Dictionary<string,object>{{"error",error},{"unity",Application.unityVersion},{"device",SystemInfo.graphicsDeviceName},{"graphicsAPI",SystemInfo.graphicsDeviceVersion},{"colorSpace",QualitySettings.activeColorSpace.ToString()}}));
        // ST-T07i: written only in look mode (also when a phase failed, so the
        // partial trace reaches --collect); absent otherwise.
        if(lookPhases.Count>0) {
            var phases=new List<object>();
            for(int i=0;i<lookPhases.Count;i++)phases.Add(new Dictionary<string,object>{{"neckPattern",lookPhases[i][0]},{"eyesPattern",lookPhases[i][1]},{"frames",lookPhases[i][2]},{"targetPosition",V(lookTargetPositions[i])}});
            File.WriteAllText(Path.Combine(folder,"look-trace.json"),J(new Dictionary<string,object>{{"error",lookError},{"frameCount",Time.frameCount},{"camera","Studio Camera.main"},{"target",lookTarget!=null?"probe IkkokuLookTarget":"none"},{"irisCard",irisCard},{"phases",phases},{"frames",lookRecords}}));
        }
        Application.Quit();
    }
    void CreateFixture() {
        var file=new ChaFileControl();
        file.parameter.sex=1;
        var body=file.custom.body;
        body.skinMainColor=new Color(.95f,.75f,.65f,1);
        body.skinSubColor=new Color(.80f,.45f,.40f,1);
        var face=file.custom.face;
        face.eyebrowColor=new Color(.12f,.07f,.045f,1);
        face.eyelineColor=new Color(.07f,.03f,.025f,1);
        int[] hair={2,1,0,0};
        for(int i=0;i<hair.Length;i++) {
            var part=file.custom.hair.parts[i];part.id=hair[i];part.noShake=true;
            part.baseColor=new Color(.18f,.09f,.045f,1);part.startColor=part.baseColor;part.endColor=part.baseColor;
        }
        foreach(var coordinate in file.coordinate) {
            int[] clothes={38,3,0,0,0,0,0,3,3};
            for(int i=0;i<clothes.Length;i++) {
                coordinate.clothes.parts[i].id=clothes[i];
                foreach(var color in coordinate.clothes.parts[i].colorInfo)
                    color.baseColor=i==0 ? new Color(.12f,.28f,.50f,1) : new Color(.12f,.13f,.16f,1);
            }
        }
        var settingsFile=Path.Combine(folder,"character-settings.tsv");
        if(File.Exists(settingsFile)) foreach(string line in File.ReadAllLines(settingsFile)) {
            var fields=line.Split('\t');
            if(fields.Length!=2) throw new Exception("Unparsable character-settings line: "+line);
            switch(fields[0]) {
                case "lipId": file.custom.face.baseMakeup.lipId=Int32.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "lipColor": file.custom.face.baseMakeup.lipColor=ParseColor(fields[1]);break;
                case "eyeshadowId": file.custom.face.baseMakeup.eyeshadowId=Int32.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "eyeshadowColor": file.custom.face.baseMakeup.eyeshadowColor=ParseColor(fields[1]);break;
                case "hohoAkaRate": file.status.hohoAkaRate=Single.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "nipId": body.nipId=Int32.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "nipColor": body.nipColor=ParseColor(fields[1]);break;
                case "underhairId": body.underhairId=Int32.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "underhairColor": body.underhairColor=ParseColor(fields[1]);break;
                case "hlUpId": face.hlUpId=Int32.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "hlUpColor": face.hlUpColor=ParseColor(fields[1]);break;
                case "hlDownId": face.hlDownId=Int32.Parse(fields[1],CultureInfo.InvariantCulture);break;
                case "hlDownColor": face.hlDownColor=ParseColor(fields[1]);break;
                default: throw new Exception("Unknown character-settings key: "+fields[0]);
            }
        }
        character=Manager.Character.Instance.CreateFemale(null,1,file,true);
        // Moment (a): right after CreateFemale returns, before LoadAsync starts.
        RecordFingers("afterCreateFemale");
        character.name="IkkokuControlledClothedFixture";
        file.status.visibleSon=false;file.status.visibleSonAlways=false;
    }
    void Capture() {
        character.SetClothesStateAll(0);
        character.fileStatus.visibleSon=false;character.fileStatus.visibleSonAlways=false;character.UpdateForce();
        foreach(var renderer in character.GetComponentsInChildren<Renderer>())
            if(renderer.enabled && renderer.name.IndexOf("dankon",StringComparison.OrdinalIgnoreCase)>=0)
                throw new Exception("Fixture privacy guard: non-clothed anatomy renderer still visible");
        ChaShader.ChangeLineColor(1);ChaShader.ChangeLineWidth(.307f);
        Shader.SetGlobalColor(ChaShader._ambientshadowG,new Color(.5f,.5f,.5f,.74f));
        var rampInfo=Manager.Character.Instance.chaListCtrl.GetListInfo(ChaListDefine.CategoryNo.mt_ramp,1);
        if(rampInfo==null)throw new Exception("Source ramp catalog entry missing");
        var rampTexture=CommonLib.LoadAsset<Texture2D>(rampInfo.GetInfo(ChaListDefine.KeyType.MainTexAB),rampInfo.GetInfo(ChaListDefine.KeyType.MainTex),false,String.Empty);
        if(rampTexture==null)throw new Exception("Source ramp asset missing");
        ChaShader.ChangeRampTexture(rampTexture);
        // A missing garment fails before ANY scene image is made.
        foreach(int slot in new int[]{0,1,7}) {
            var garment=character.objClothes[slot];
            if(garment==null || !garment.activeInHierarchy || garment.GetComponentsInChildren<Renderer>().Length==0)
                throw new Exception("Required fully clothed fixture garment missing at slot "+slot);
        }
        // Freeze the exact evaluated source pose. The manager manually updates
        // ChaControl as well, so it must be disabled before native pose export.
        Manager.Character.Instance.enabled=false;
        foreach(var b in character.GetComponentsInChildren<Behaviour>(true)) b.enabled=false;
        // Animator state info is read-only observation, so sampling it here,
        // while the frozen pose is still the one frame.json will write, gives
        // the playhead that produced the exported bone rotations.
        if(handPatterns!=null)RecordHandAnime("frozenPose");
        foreach(var t in character.GetComponentsInChildren<Transform>(true)) t.gameObject.layer=Layer;
        foreach(var light in FindObjectsOfType<Light>()) light.enabled=false;
        var lightObject=new GameObject("IkkokuProbeKey");var key=lightObject.AddComponent<Light>();
        key.type=LightType.Directional;key.color=Color.white;key.intensity=1;key.shadows=LightShadows.None;
        key.transform.rotation=Quaternion.Euler(35,145,0);key.cullingMask=1<<Layer;
        RenderSettings.ambientMode=AmbientMode.Flat;RenderSettings.ambientLight=new Color(.2f,.2f,.2f,1);RenderSettings.ambientIntensity=1;
        RenderSettings.fog=false;QualitySettings.antiAliasing=0;
        var renderers=character.GetComponentsInChildren<Renderer>();
        var visible=new List<Renderer>();Bounds bounds=new Bounds();bool first=true;
        foreach(var renderer in renderers) {
            if(!renderer.enabled || !renderer.gameObject.activeInHierarchy) continue;
            if(!(renderer is SkinnedMeshRenderer) && renderer.GetComponent<MeshFilter>()==null) continue;
            visible.Add(renderer);if(first){bounds=renderer.bounds;first=false;}else bounds.Encapsulate(renderer.bounds);
        }
        if(visible.Count<5 || bounds.size.y<.5f || bounds.size.y>5) throw new Exception("Invalid controlled character bounds");
        var camObject=new GameObject("IkkokuProbeCamera");var camera=camObject.AddComponent<Camera>();camera.enabled=false;
        camera.cullingMask=1<<Layer;camera.clearFlags=CameraClearFlags.SolidColor;camera.backgroundColor=new Color(.06f,.06f,.06f,0);
        camera.allowHDR=false;camera.allowMSAA=false;camera.fieldOfView=30;camera.nearClipPlane=.05f;camera.farClipPlane=100;
        camera.aspect=(float)Width/Height;
        float radius=Mathf.Max(bounds.extents.y,bounds.extents.x/camera.aspect);
        float distance=radius/Mathf.Tan(camera.fieldOfView*Mathf.Deg2Rad*.5f)*1.15f+bounds.extents.z;
        bounds=new Bounds(new Vector3(0,.8f,0),new Vector3(1.3f,1.6f,.3f));distance=3.8f;
        camera.transform.position=bounds.center+new Vector3(0,0,distance);camera.transform.LookAt(bounds.center,Vector3.up);
        var target=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Default);target.antiAliasing=1;target.Create();camera.targetTexture=target;
        var timer=System.Diagnostics.Stopwatch.StartNew();camera.Render();timer.Stop();
        SaveTarget(target,"original-color.png");
        // Shader-family isolation uses the identical clothed source fixture and
        // camera, with only garment renderers enabled; no hidden anatomy is shown.
        foreach(var renderer in visible)renderer.enabled=Array.TrueForAll(renderer.sharedMaterials,m=>m.shader.name=="Shader Forge/main_opaque");
        camera.Render();SaveTarget(target,"original-main_opaque.png");
        foreach(var renderer in visible)renderer.enabled=true;
        // The newly generated card receives only this controlled clothed image.
        character.chaFile.pngData=File.ReadAllBytes(Path.Combine(folder,"original-color.png"));character.chaFile.facePngData=null;
        if(!character.chaFile.SaveCharaFile(Path.Combine(folder,"fixture-card.png"),1)) throw new Exception("Generated card save failed");
        var meshes=new List<object>();int meshIndex=0;
        foreach(var renderer in visible) meshes.Add(ExportMesh(renderer,meshIndex++));
        // Moment (c): after the 10-frame wait, immediately before collecting
        // the bone transforms written to frame.json.
        RecordFingers("frameJsonCapture");
        if(handPatterns!=null)RecordHandAnime("frameJsonCapture");
        var bones=new List<object>();
        foreach(var t in character.GetComponentsInChildren<Transform>(true)) bones.Add(new Dictionary<string,object>{{"path",RelativePath(t)},{"position",V(t.localPosition)},{"rotation",V(t.localRotation)},{"scale",V(t.localScale)}});
        var globals=new Dictionary<string,object>();
        foreach(string name in new[]{"_ambientshadowG","_LineColorG"}) globals[name]=V(Shader.GetGlobalColor(name));
        foreach(string name in new[]{"_FaceShadowG","_FaceNormalG"})globals[name]=Shader.GetGlobalFloat(name);
        globals["_TimeEditor"]=V(Shader.GetGlobalVector("_TimeEditor"));
        globals["_Time"]=new[]{Time.time/20,Time.time,Time.time*2,Time.time*3};
        globals["_linewidthG"]=Shader.GetGlobalFloat("_linewidthG");globals["_rimG"]=Shader.GetGlobalFloat("_rimG");
        var ramp=Shader.GetGlobalTexture("_RampG");if(ramp!=null) globals["_RampG"]=ExportTexture(ramp);
        var report=new Dictionary<string,object>{{"schemaVersion",1},{"anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString()},{"masterTextureLimit",QualitySettings.masterTextureLimit},{"lodBias",QualitySettings.lodBias},{"fixedDeltaTime",Time.fixedDeltaTime},{"maximumDeltaTime",Time.maximumDeltaTime},{"width",Width},{"height",Height},{"scope","Frozen original clothed character; source-evaluated geometry, source materials, dedicated camera/light; no Studio post-processing"},{"card","fixture-card.png"},{"color","original-color.png"},{"camera",new Dictionary<string,object>{{"position",V(camera.transform.position)},{"target",V(bounds.center)},{"rotation",V(camera.transform.rotation)},{"fov",camera.fieldOfView},{"near",camera.nearClipPlane},{"far",camera.farClipPlane},{"view",M(camera.worldToCameraMatrix)},{"projection",M(camera.projectionMatrix)}}},{"light",new Dictionary<string,object>{{"direction",V(key.transform.forward)},{"color",V(key.color)},{"intensity",key.intensity},{"ambient",V(RenderSettings.ambientLight)}}},{"bounds",new Dictionary<string,object>{{"min",V(bounds.min)},{"max",V(bounds.max)}}},{"background",V(camera.backgroundColor)},{"globals",globals},{"textures",textures},{"meshes",meshes},{"bones",bones},{"renderCPUMilliseconds",timer.Elapsed.TotalMilliseconds}};
        File.WriteAllText(Path.Combine(folder,"frame.json"),J(report));
        File.WriteAllText(Path.Combine(folder,"fingers.json"),J(fingerRecords));
        if(handPatterns!=null)File.WriteAllText(Path.Combine(folder,"hand-anime.json"),J(handAnimeRecords));
        // White-material silhouette is a geometry diagnostic; alpha cutouts are
        // deliberately excluded and therefore reported separately from color alpha.
        var whiteShader=Shader.Find("Unlit/Color");
        if(whiteShader!=null) {
            var white=new Material(whiteShader);white.color=Color.white;
            foreach(var renderer in visible) { var replacements=new Material[renderer.sharedMaterials.Length];for(int i=0;i<replacements.Length;i++)replacements[i]=white;renderer.sharedMaterials=replacements; }
            camera.backgroundColor=Color.black;camera.Render();SaveTarget(target,"original-geometry.png");
            var depthShader=Shader.Find("Hidden/Internal-DepthNormalsTexture");
            if(depthShader!=null) {
                var depthTarget=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Linear);depthTarget.Create();camera.targetTexture=depthTarget;
                camera.backgroundColor=Color.white;camera.RenderWithShader(depthShader,"");SaveTarget(depthTarget,"original-depth-normals.png");camera.targetTexture=target;depthTarget.Release();Destroy(depthTarget);
            }
        }
        camera.targetTexture=null;target.Release();Destroy(target);Destroy(camObject);Destroy(lightObject);
    }
    string RelativePath(Transform t) { if(t==character.transform)return t.name;return RelativePath(t.parent)+"/"+t.name; }
    object ExportMesh(Renderer renderer,int index) {
        var skinned=renderer as SkinnedMeshRenderer;Mesh mesh;
        if(skinned!=null){mesh=new Mesh();skinned.BakeMesh(mesh);}else mesh=renderer.GetComponent<MeshFilter>().sharedMesh;
        var positions=mesh.vertices;var normals=mesh.normals;
        var worldPositions=new Vector3[positions.Length];var worldNormals=new Vector3[positions.Length];
        if(skinned!=null) {
            // Unity 5.6 BakeMesh embeds the renderer scale in its local output.
            // Evaluate the original skin matrices directly to avoid applying
            // that scale twice when exporting world-space diagnostics.
            var source=skinned.sharedMesh;var sourcePositions=source.vertices;var sourceNormals=source.normals;
            for(int shape=0;shape<source.blendShapeCount;shape++) {
                float weight=skinned.GetBlendShapeWeight(shape);if(weight==0)continue;
                if(source.GetBlendShapeFrameCount(shape)!=1)throw new Exception("Unsupported active multi-frame blend shape");
                var delta=new Vector3[sourcePositions.Length];var normalDelta=new Vector3[sourcePositions.Length];var tangentDelta=new Vector3[sourcePositions.Length];
                source.GetBlendShapeFrameVertices(shape,0,delta,normalDelta,tangentDelta);
                float factor=weight/source.GetBlendShapeFrameWeight(shape,0);
                for(int i=0;i<sourcePositions.Length;i++){sourcePositions[i]+=delta[i]*factor;sourceNormals[i]+=normalDelta[i]*factor;}
            }
            var bind=source.bindposes;var bones=skinned.bones;var weights=source.boneWeights;var palette=new Matrix4x4[bind.Length];
            for(int i=0;i<palette.Length;i++)palette[i]=bones[i].localToWorldMatrix*bind[i];
            for(int i=0;i<sourcePositions.Length;i++) {
                var weight=weights[i];int[] indices={weight.boneIndex0,weight.boneIndex1,weight.boneIndex2,weight.boneIndex3};float[] values={weight.weight0,weight.weight1,weight.weight2,weight.weight3};
                for(int lane=0;lane<4;lane++)if(values[lane]!=0){worldPositions[i]+=palette[indices[lane]].MultiplyPoint3x4(sourcePositions[i])*values[lane];worldNormals[i]+=palette[indices[lane]].MultiplyVector(sourceNormals[i])*values[lane];}
                worldNormals[i]=worldNormals[i].normalized;
            }
        } else for(int i=0;i<positions.Length;i++){worldPositions[i]=renderer.transform.TransformPoint(positions[i]);worldNormals[i]=renderer.transform.localToWorldMatrix.inverse.transpose.MultiplyVector(normals[i]).normalized;}
        var tangents=mesh.tangents;var uv=mesh.uv;var uv1=mesh.uv2;var uv2=mesh.uv3;var uv3=mesh.uv4;var colors=mesh.colors;
        string file="mesh-"+index+".bin";
        using(var output=new BinaryWriter(File.Create(Path.Combine(folder,file)))) {
            output.Write(positions.Length);output.Write(mesh.subMeshCount);
            for(int i=0;i<positions.Length;i++) {
                Write(output,worldPositions[i]);Write(output,worldNormals[i]);
                var tangent=tangents.Length==positions.Length?tangents[i]:new Vector4(1,0,0,1);
                Write(output,renderer.transform.TransformDirection(new Vector3(tangent.x,tangent.y,tangent.z)).normalized);output.Write(tangent.w);
                Write(output,uv.Length==positions.Length?uv[i]:Vector2.zero);Write(output,uv1.Length==positions.Length?uv1[i]:Vector2.zero);Write(output,uv2.Length==positions.Length?uv2[i]:Vector2.zero);
                var color=colors.Length==positions.Length?colors[i]:Color.white;output.Write(color.r);output.Write(color.g);output.Write(color.b);output.Write(color.a);
            }
            for(int s=0;s<mesh.subMeshCount;s++){var indices=mesh.GetTriangles(s);output.Write(indices.Length);foreach(var i in indices)output.Write(i);}
        }
        string uv3File="mesh-"+index+"-uv3.bin";
        using(var output=new BinaryWriter(File.Create(Path.Combine(folder,uv3File))))for(int i=0;i<positions.Length;i++)Write(output,uv3.Length==positions.Length?uv3[i]:Vector2.zero);
        var materials=new List<object>();foreach(var material in renderer.sharedMaterials)materials.Add(ExportMaterial(material));
        var result=new Dictionary<string,object>{{"name",renderer.name},{"path",RelativePath(renderer.transform)},{"mesh",skinned!=null?skinned.sharedMesh.name:mesh.name},{"lossyScale",V(renderer.transform.lossyScale)},{"rendererMatrix",M(renderer.transform.localToWorldMatrix)},{"geometryMethod",skinned!=null?"original mesh blend shapes and bone world matrices times bind poses":"original static world matrix"},{"file",file},{"vertices",positions.Length},{"submeshes",mesh.subMeshCount},{"materials",materials}};
        result["uv3File"]=uv3File;
        if(skinned!=null)Destroy(mesh);return result;
    }
    object ExportMaterial(Material material) {
        if(material==null)throw new Exception("Missing source material");
        var properties=new Dictionary<string,object>();
        string propertyList=Path.Combine(Path.GetDirectoryName(folder),"shader-properties.tsv");
        if(File.Exists(propertyList)) foreach(string line in File.ReadAllLines(propertyList)) {
            var fields=line.Split('\t');if(fields.Length!=3 || fields[0]!=material.shader.name || !material.HasProperty(fields[1]))continue;
            string property=fields[1];int type=Int32.Parse(fields[2]);
            if(type==0 || type==1)properties[property]=V(material.GetVector(property));
            else if(type==2 || type==3)properties[property]=material.GetFloat(property);
            else if(type==4) {var texture=material.GetTexture(property);if(texture!=null)properties[property]=new Dictionary<string,object>{{"file",ExportTexture(texture)},{"scale",V(material.GetTextureScale(property))},{"offset",V(material.GetTextureOffset(property))}};}
        }
        foreach(string name in new[]{"_Color","_Color2","_Color3","_LineColor","_overcolor1","_overcolor2","_overcolor3","_ShadowColor","_SpecColor"}) if(material.HasProperty(name))properties[name]=V(material.GetVector(name));
        foreach(string name in new[]{"_SpecularPower","_SpecularPowerNail","_Cutoff","_alpha_a","_alpha_b","_exppower","_expression","_isHighLight","_rim","_LineWidth","_Cull","_ZWrite","_ZTest","_StencilRef","_StencilComp","_StencilOp","_SrcBlend","_DstBlend","_linetexon"})if(material.HasProperty(name))properties[name]=material.GetFloat(name);
        foreach(string name in new[]{"_MainTex","_DetailMask","_AlphaMask","_NormalMap","_NormalMapDetail","_LineMask","_HairGloss","_overtex1","_overtex2","_overtex3","_Texture2","_ColorMask","_Ramp"}) if(material.HasProperty(name)) {
            var texture=material.GetTexture(name);if(texture!=null)properties[name]=new Dictionary<string,object>{{"file",ExportTexture(texture)},{"scale",V(material.GetTextureScale(name))},{"offset",V(material.GetTextureOffset(name))}};
        }
        return new Dictionary<string,object>{{"name",material.name},{"shader",material.shader.name},{"supported",material.shader.isSupported},{"queue",material.renderQueue},{"keywords",material.shaderKeywords},{"properties",properties}};
    }
    string ExportTexture(Texture texture) {
        string existing;if(textureFiles.TryGetValue(texture.GetInstanceID(),out existing))return existing;
        string file="texture-"+textures.Count+".rgba16f";textureFiles[texture.GetInstanceID()]=file;
        var target=new RenderTexture(texture.width,texture.height,0,RenderTextureFormat.ARGBHalf,RenderTextureReadWrite.Linear);target.Create();
        bool previous=GL.sRGBWrite;var previousTarget=RenderTexture.active;GL.sRGBWrite=false;Graphics.Blit(texture,target);
        RenderTexture.active=target;var readback=new Texture2D(texture.width,texture.height,TextureFormat.RGBAHalf,false,true);
        readback.ReadPixels(new Rect(0,0,texture.width,texture.height),0,0);readback.Apply(false,false);
        File.WriteAllBytes(Path.Combine(folder,file),readback.GetRawTextureData());Destroy(readback);
        RenderTexture.active=previousTarget;GL.sRGBWrite=previous;target.Release();Destroy(target);
        var source2D=texture as Texture2D;var sourceRT=texture as RenderTexture;
        int mipLevels=source2D!=null?source2D.mipmapCount:(sourceRT!=null&&sourceRT.useMipMap?1+(int)Math.Floor(Math.Log(Math.Max(texture.width,texture.height),2)):1);
        textures.Add(new Dictionary<string,object>{{"file",file},{"name",texture.name},{"textureType",texture.GetType().Name},{"width",texture.width},{"height",texture.height},{"mipLevels",mipLevels},{"filter",texture.filterMode.ToString()},{"wrap",texture.wrapMode.ToString()},{"aniso",texture.anisoLevel},{"exportEncoding","linear-rgba16f-little-endian-bottom-up"}});return file;
    }
    void SaveTarget(RenderTexture target,string file) {
        var previous=RenderTexture.active;RenderTexture.active=target;
        var readback=new Texture2D(target.width,target.height,TextureFormat.RGBA32,false,true);readback.ReadPixels(new Rect(0,0,target.width,target.height),0,0);readback.Apply(false,false);
        File.WriteAllBytes(Path.Combine(folder,file),readback.EncodeToPNG());Destroy(readback);RenderTexture.active=previous;
    }
    static void Write(BinaryWriter w,Vector3 v){w.Write(v.x);w.Write(v.y);w.Write(v.z);}static void Write(BinaryWriter w,Vector2 v){w.Write(v.x);w.Write(v.y);}
    static Color ParseColor(string value) { var parts=value.Split(',');if(parts.Length!=4)throw new Exception("Invalid RGBA color: "+value);return new Color(float.Parse(parts[0],CultureInfo.InvariantCulture),float.Parse(parts[1],CultureInfo.InvariantCulture),float.Parse(parts[2],CultureInfo.InvariantCulture),float.Parse(parts[3],CultureInfo.InvariantCulture)); }
    static float[] V(Vector2 v){return new[]{v.x,v.y};}static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}static float[] V(Vector4 v){return new[]{v.x,v.y,v.z,v.w};}static float[] V(Quaternion v){return new[]{v.x,v.y,v.z,v.w};}static float[] V(Color v){return new[]{v.r,v.g,v.b,v.a};}
    static float[] M(Matrix4x4 m){var a=new float[16];for(int i=0;i<16;i++)a[i]=m[i];return a;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
    // ST-T07b diagnostic recorder. It only observes: every existing output stays
    // byte-identical and no game method is invoked here, so this records the
    // decompiled behavior facts instead of re-deriving them.
    object Member(object target,string name) {
        // null result = member not found OR member present with a null value;
        // every caller records that explicitly, never guesses.
        if(target==null)return null;
        var flags=System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.DeclaredOnly|System.Reflection.BindingFlags.Instance;
        for(var type=target.GetType();type!=null;type=type.BaseType) {
            var property=type.GetProperty(name,flags);
            if(property!=null){try{return property.GetValue(target,null);}catch(Exception){return "unreadable";}}
            var field=type.GetField(name,flags);
            if(field!=null){try{return field.GetValue(target);}catch(Exception){return "unreadable";}}
        }
        return null;
    }
    object Flatten(object value) { // 1-D array -> flat list; 2-D array -> row-major list of rows
        if(value is Vector2)return V((Vector2)value);
        if(value is Vector3)return V((Vector3)value);
        if(value is Vector4)return V((Vector4)value);
        if(value is Quaternion)return V((Quaternion)value);
        if(value is Color)return V((Color)value);
        var array=value as System.Array;
        if(array==null)return value;
        var list=new List<object>();
        if(array.Rank==1)foreach(var item in array)list.Add(Flatten(item));
        else if(array.Rank==2){
            for(int i=0;i<array.GetLength(0);i++) {
                var row=new List<object>();
                for(int j=0;j<array.GetLength(1);j++)row.Add(Flatten(array.GetValue(i,j)));
                list.Add(row);
            }
        }
        else return "unexpected array rank "+array.Rank;
        return list;
    }
    object FingerBoneSamples() {
        var bones=new Dictionary<string,object>();
        foreach(string name in new[]{"cf_j_middle01_L","cf_j_middle02_L","cf_j_thumb01_R"}) {
            var samples=new List<object>();
            foreach(var t in character.GetComponentsInChildren<Transform>(true))
                if(t.name==name) samples.Add(new Dictionary<string,object>{{"path",RelativePath(t)},{"localRotation",V(t.localRotation)},{"localEulerAngles",V(t.localRotation.eulerAngles)}});
            bones[name]=samples; // empty = not instantiated yet; more than one = same-named bones on several objects
        }
        return bones;
    }
    void RecordFingers(string moment) {
        var bones=FingerBoneSamples();
        var status=Member(character,"fileStatus");
        var hand=Member(character,"sibHand");
        var animator=Member(character,"animBody");
        var controller=Member(animator,"runtimeAnimatorController");
        var chain=new List<object>();
        var handBone=FindBone("cf_j_hand_L");
        if(handBone==null)chain.Add(new Dictionary<string,object>{{"path","cf_j_hand_L"},{"found",false}});
        else {
            var current=handBone;
            for(;;) {
                var behaviours=new List<object>();
                foreach(var behaviour in current.gameObject.GetComponents<MonoBehaviour>()) behaviours.Add(behaviour.GetType().FullName);
                chain.Add(new Dictionary<string,object>{{"path",RelativePath(current)},{"monoBehaviours",behaviours}});
                if(current.name=="p_cf_body_bone" || current.parent==null || chain.Count>=64) break;
                current=current.parent;
            }
        }
        // ST-T07c: every Behaviour under the character root (not only MonoBehaviour)
        // so the writer that curls the fingers can be attributed or excluded.
        var flags=System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.DeclaredOnly|System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.Static;
        var rootBehaviours=new List<object>();
        foreach(var behaviour in character.GetComponentsInChildren<Behaviour>(true)) {
            var entry=new Dictionary<string,object>{{"type",behaviour.GetType().FullName},{"path",RelativePath(behaviour.transform)},{"enabled",Member(behaviour,"enabled")}};
            if(behaviour.GetType().Name=="Animator") {
                var boneController=Member(behaviour,"runtimeAnimatorController");
                entry["runtimeAnimatorController"]=boneController==null?null:(object)new Dictionary<string,object>{{"name",Member(boneController,"name")}};
                var avatar=Member(behaviour,"avatar");
                entry["avatar"]=avatar==null?null:(object)new Dictionary<string,object>{{"name",Member(avatar,"name")}};
                entry["isActiveAndEnabled"]=Member(behaviour,"isActiveAndEnabled");
            } else if(behaviour.GetType().Name=="Animation") {
                var clip=Member(behaviour,"clip");
                entry["clip"]=clip==null?null:(object)new Dictionary<string,object>{{"name",Member(clip,"name")}};
                entry["clips"]=Flatten(Member(behaviour,"clips")); // null = the member is not found; list of all clip names when it is
                entry["isPlaying"]=Member(behaviour,"isPlaying");
            }
            rootBehaviours.Add(entry);
        }
        // ShapeHandInfo internals via reflection: whichever nested enum declares
        // the bone names (ShapeBodyInfo calls it SrcName, ShapeHeadInfoFemale
        // calls it SrcBoneName) maps them to plain dictSrc keys, so the recorded
        // dictSrc/<index>/vctRot pair shows whether it holds index 0 or index 1.
        var shapeRots=new Dictionary<string,object>();
        Type srcEnum=null;
        if(hand!=null) foreach(var nested in hand.GetType().GetNestedTypes(flags)) {
            if(nested.GetField("cf_j_middle01_L",flags)!=null) { srcEnum=nested; break; }
        }
        var srcDict=hand==null?null:(Member(hand,"dictSrc") as IDictionary);
        foreach(string boneName in new[]{"cf_j_middle01_L","cf_j_middle02_L","cf_j_thumb01_R"}) {
            var srcField=srcEnum==null?null:srcEnum.GetField(boneName,flags);
            var srcIndex=srcField==null?null:(object)Convert.ToInt32(srcField.GetValue(null)); // dictionary keys are plain ints
            var boneInfo=srcIndex==null||srcDict==null?null:srcDict[srcIndex];
            shapeRots[boneName]=new Dictionary<string,object>{{"sourceIndex",srcIndex},{"vctRot",Flatten(Member(boneInfo,"vctRot"))}};
        }
        var record=new Dictionary<string,object>{{"moment",moment},{"frame",Time.frameCount},{"bones",bones},
            {"fileStatus",new Dictionary<string,object>{{"enableShapeHand",Flatten(Member(status,"enableShapeHand"))},{"shapeHandPtn",Flatten(Member(status,"shapeHandPtn"))},{"shapeHandBlendValue",Flatten(Member(status,"shapeHandBlendValue"))}}},
            {"sibHand",hand==null?null:new Dictionary<string,object>{{"type",hand.GetType().Name},{"updateMask",Flatten(Member(hand,"updateMask"))}}},
            {"animBody",new Dictionary<string,object>{{"exists",animator!=null},{"type",animator==null?null:(object)animator.GetType().Name},{"runtimeAnimatorController",controller==null?null:(object)new Dictionary<string,object>{{"name",Member(controller,"name")}}},{"enabled",Member(animator,"enabled")}}},
            {"behaviours",rootBehaviours},
            {"shapeHand",new Dictionary<string,object>{{"dictSrcRotations",shapeRots},{"InitEnd",hand==null?null:(object)Member(hand,"InitEnd")}}},
            {"handBoneChain",chain}};
        // The pattern IDs are recorded only in pattern mode, so a capture
        // without hand-patterns.tsv keeps its previous bytes exactly.
        if(handPatterns!=null)record["handPatterns"]=handPatterns;
        fingerRecords.Add(record);
    }
    // ST-T07f optional hand-pattern mode. CharaStudio.dll is not referenced,
    // so the Studio type is located by type name and its recovered members
    // are invoked reflectively: Init(sex) then ptn=k, the same sequence
    // AddObjectAssist and OCIChar.ChangeHandAnime run in Studio.
    void TryLoadHandPatterns() {
        var file=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"hand-patterns.tsv");
        if(!File.Exists(file))return;
        var patterns=new Dictionary<string,int>();
        foreach(var line in File.ReadAllLines(file)) {
            if(line.Length==0)continue;
            var fields=line.Split('\t');
            if(fields.Length!=2 || (fields[0]!="L"&&fields[0]!="R"))throw new Exception("hand-patterns.tsv rows need an L or R side and one pattern number");
            int pattern;
            if(!Int32.TryParse(fields[1],out pattern)||pattern<0||pattern>21||patterns.ContainsKey(fields[0]))
                throw new Exception("hand-patterns.tsv repeats a side or holds a pattern outside the converted 0-21 range");
            patterns[fields[0]]=pattern;
        }
        if(patterns.Count!=2)throw new Exception("hand-patterns.tsv needs one L and one R row");
        handPatterns=patterns;
    }
    void ApplyHandPatterns() {
        var flags=System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.DeclaredOnly|System.Reflection.BindingFlags.Instance;
        foreach(var component in character.GetComponentsInChildren<MonoBehaviour>(true)) {
            if(component.GetType().FullName!="Studio.HandAnimeCtrl")continue;
            var side=component.transform.name=="cf_s_hand_L"?"L":component.transform.name=="cf_s_hand_R"?"R":null;
            if(side==null)continue; // a HandAnimeCtrl of another object; only the character's two are driven
            int pattern;
            if(!handPatterns.TryGetValue(side,out pattern))throw new Exception("hand-patterns.tsv has no row for "+component.transform.name);
            System.Reflection.MethodInfo init=null;
            System.Reflection.PropertyInfo property=null;
            for(var type=component.GetType();type!=null&&(init==null||property==null);type=type.BaseType) {
                if(init==null)init=type.GetMethod("Init",flags);
                if(property==null)property=type.GetProperty("ptn",flags);
            }
            if(init==null||property==null)throw new Exception("Studio.HandAnimeCtrl is missing the recovered Init or ptn member");
            try {
                init.Invoke(component,new object[]{1}); // the fixture's sex; Studio passes ChaControl.parameter.sex
                property.SetValue(component,pattern,null); // setter runs LoadAnime, which enables and Play()s patterns 1-21
            } catch(Exception e) { throw new Exception("HandAnimeCtrl pattern "+pattern+" setup failed on "+component.transform.name+": "+e.Message,e); }
        }
    }
    Animator FindHandAnimator(string side) {
        foreach(var animator in character.GetComponentsInChildren<Animator>(true))
            if(animator.name=="cf_s_hand_"+side)return animator;
        return null;
    }
    void RecordHandAnime(string moment) {
        var hands=new Dictionary<string,object>();
        foreach(string side in new[]{"L","R"}) {
            var animator=FindHandAnimator(side);
            if(animator==null) { hands[side]=new Dictionary<string,object>{{"exists",false}}; continue; }
            var state=animator.GetCurrentAnimatorStateInfo(0);
            hands[side]=new Dictionary<string,object>{{"exists",true},{"isActiveAndEnabled",Member(animator,"isActiveAndEnabled")},
                {"frameCount",Time.frameCount},{"deltaTime",Time.deltaTime},
                {"normalizedTime",state.normalizedTime},{"length",state.length},{"shortNameHash",state.shortNameHash}};
        }
        handAnimeRecords.Add(new Dictionary<string,object>{{"moment",moment},{"bones",FingerBoneSamples()},{"hands",hands}});
    }
    // ST-T07i optional look-pattern mode. The fixture only calls the public
    // ChaControl.ChangeLookNeck*/ChangeLookEyes* API; the controller internals
    // (internal fixAngle/angleH/angleV, private lookType) sit outside this
    // assembly, so the existing Member helper (public+nonpublic walk) reads
    // them and Required fails the run when a recovered member is missing.
    void TryLoadLookPatterns() {
        var file=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"look-patterns.tsv");
        if(!File.Exists(file))return;
        foreach(var line in File.ReadAllLines(file)) {
            if(line.Length==0)continue;
            var fields=line.Split('\t');
            if(fields.Length!=4)throw new Exception("look-patterns.tsv rows need neckPtn, eyesPtn, frames and x,y,z camera position");
            int neckPtn,eyesPtn,frames;
            if(!Int32.TryParse(fields[0],out neckPtn)||!Int32.TryParse(fields[1],out eyesPtn)||!Int32.TryParse(fields[2],out frames))
                throw new Exception("look-patterns.tsv pattern and frame fields must be integers");
            if(neckPtn<0||neckPtn>4||eyesPtn<0||eyesPtn>3||frames<1||frames>600)
                throw new Exception("look-patterns.tsv holds a pattern outside neck 0-4 / eyes 0-3 or a frame count outside 1-600");
            var parts=fields[3].Split(',');
            if(parts.Length!=3)throw new Exception("look-patterns.tsv camera position needs x,y,z");
            // Same number styles as float.Parse(value, InvariantCulture), but a bad
            // value names the tsv field instead of a bare FormatException.
            var position=new float[3];
            for(int axis=0;axis<3;axis++)
                if(!Single.TryParse(parts[axis],NumberStyles.Float|NumberStyles.AllowThousands,CultureInfo.InvariantCulture,out position[axis]))
                    throw new Exception("look-patterns.tsv camera position \""+fields[3]+"\" is not three invariant-culture numbers x,y,z");
            lookPhases.Add(new[]{neckPtn,eyesPtn,frames});
            lookTargetPositions.Add(new Vector3(position[0],position[1],position[2]));
        }
        if(lookPhases.Count==0)throw new Exception("look-patterns.tsv has no phase rows");
    }
    IEnumerator RunLookPhases() {
        // The VM compiles C# 5, which forbids a yield inside a try with a catch
        // clause, so the setup and the per-frame recording catch in ordinary
        // helper methods and this iterator only watches lookError. The scene
        // camera already exists: Start() waited for it before CreateFixture().
        if(lookTarget==null)lookTarget=new GameObject("IkkokuLookTarget").transform;
        for(int phase=0;phase<lookPhases.Count&&lookError==null;phase++) {
            StartLookPhase(phase);
            if(lookError!=null)yield break;
            for(int frame=0;frame<lookPhases[phase][2];frame++) {
                // A coroutine resuming after "yield return null" runs before
                // the controllers' own LateUpdate; end-of-frame is after it.
                yield return new WaitForEndOfFrame();
                if(lookError==null)RecordLookSafe(phase);
            }
        }
    }
    void StartLookPhase(int phase) {
        try {
            if(lookTarget==null)throw new Exception("the probe look target is missing");
            var head=FindBone("cf_j_head");
            if(head==null)throw new Exception("cf_j_head is missing before the look phases start");
            lookTarget.position=lookTargetPositions[phase];
            lookTarget.LookAt(head.position);
            // The trfTarg parameter makes both controllers follow this
            // transform instead of Camera.main, which Studio's own camera
            // controller owns and repositions.
            character.ChangeLookNeckTarget(0,lookTarget);
            character.ChangeLookEyesTarget(0,lookTarget);
            character.ChangeLookNeckPtn(lookPhases[phase][0]);
            character.ChangeLookEyesPtn(lookPhases[phase][1]);
        } catch(Exception e) { lookError=e.ToString(); }
    }
    void RecordLookSafe(int phase) {
        try { RecordLook(phase); } catch(Exception e) { lookError=e.ToString(); }
    }
    void RecordIrisCard() {
        // The values ChangeSettingEye* Lerps its offset/scale/highlight edits
        // from and ChangeSettingEyeTilt reads for shape 33; the identity says
        // whether those methods apply at all (they return early on sex 0 with
        // exType 1). fileFace is a public ChaInfo property, sex/exType too.
        try {
            var face=Required(character,"fileFace");
            var shape=Flatten(Required(face,"shapeValueFace")) as List<object>;
            if(shape==null||shape.Count<=33)throw new Exception("fileFace.shapeValueFace has no entry 33");
            irisCard=new Dictionary<string,object>{
                {"pupilX",Required(face,"pupilX")},{"pupilY",Required(face,"pupilY")},
                {"pupilWidth",Required(face,"pupilWidth")},{"pupilHeight",Required(face,"pupilHeight")},
                {"hlUpY",Required(face,"hlUpY")},{"hlDownY",Required(face,"hlDownY")},
                {"shapeValueFace33",shape[33]},
                {"sex",Required(character,"sex")},{"exType",Required(character,"exType")}};
        } catch(Exception e) { lookError=e.ToString(); }
    }
    object Required(object target,string name) {
        var value=Member(target,name);
        if(value==null)throw new Exception("the recovered look member "+name+" is missing");
        return value;
    }
    static string ClassifyMember(object value) {
        // Member() cannot distinguish "field absent" from "present but null",
        // so the two look-layout diagnostics record the distinction here.
        if(value==null)return "null";
        if("unreadable".Equals(value))return "unreadable";
        var transform=value as Transform;
        if(transform!=null)return transform.name;
        return "non-transform "+value.GetType().Name;
    }
    Transform RequiredTransform(object target,string name) {
        var transform=Required(target,name) as Transform;
        if(transform==null)throw new Exception("the recovered look member "+name+" is missing or not a Transform");
        return transform;
    }
    Dictionary<string,object> Geometry(Transform transform) {
        // End-of-frame world pose in the exact space the recovered
        // GetAngleToTarget/limit-check formulas read.
        return new Dictionary<string,object>{{"name",transform.name},{"position",V(transform.position)},
            {"rotation",V(transform.rotation)},{"lossyScale",V(transform.lossyScale)}};
    }
    void RecordLook(int phase) {
        var record=new Dictionary<string,object>{
            {"phase",phase},{"frameCount",Time.frameCount},{"deltaTime",Time.deltaTime},
            // Studio owns and may move Camera.main, so it is recorded only as
            // information; the driven target position is the control input.
            {"cameraPosition",Camera.main!=null?(object)V(Camera.main.transform.position):"gone"},
            {"targetPosition",V(lookTarget.position)}};
        var neckCtrl=Member(character,"neckLookCtrl");
        var eyeCtrl=Member(character,"eyeLookCtrl");
        if(neckCtrl==null||eyeCtrl==null)throw new Exception("the fixture character has no neckLookCtrl/eyeLookCtrl");
        var neckScript=Required(neckCtrl,"neckLookScript");
        var bones=Flatten(Required(neckScript,"aBones")) as List<object>;
        // The two look bones are taken by name, aBones[0] driving cf_j_neck
        // and aBones[1] cf_j_head, because that mapping held under the
        // scene-load capture condition; each aBones[i].neckBone slot is still
        // recorded as a diagnostic string per entry.
        string[] lookBoneNames={"cf_j_neck","cf_j_head"};
        var neckRecord=new List<object>();
        for(int i=0;i<bones.Count;i++) {
            var bone=bones[i];
            var angles=new Dictionary<string,object>{
                {"neckBone",ClassifyMember(Member(bone,"neckBone"))},
                {"angleH",Required(bone,"angleH")},{"angleV",Required(bone,"angleV")},
                {"fixAngle",V((Quaternion)Required(bone,"fixAngle"))}};
            if(i<lookBoneNames.Length) {
                var neckBone=FindBone(lookBoneNames[i]);
                if(neckBone==null)throw new Exception("the fixture character has no "+lookBoneNames[i]+" transform");
                angles["bone"]=neckBone.name;
                angles["localRotation"]=V(neckBone.localRotation);
                angles["worldRotation"]=V(neckBone.rotation);
            }
            neckRecord.Add(angles);
        }
        // neckLookScript IS the NeckLookCalcVer2 component (decompiled
        // NeckLookControllerVer2.neckLookScript), so solver state reads directly.
        var neckCalcRecord=new List<object>{new Dictionary<string,object>{
            {"nowAngle",V((Vector2)Required(neckScript,"nowAngle"))},
            {"calcLerp",Required(neckScript,"calcLerp")},
            // lookType is a NECK_LOOK_TYPE_VER2 enum; the JSON helper's final
            // fallback would write it unquoted, so the name is taken here.
            {"lookType",Required(neckScript,"lookType").ToString()}}};
        // StartLookPhase passed lookTarget as trfTarg before every phase, so
        // each controller's target is the probe look target at every frame.
        record["neck"]=new Dictionary<string,object>{{"ptnNo",Required(neckCtrl,"ptnNo")},{"target",V(((Transform)Required(neckCtrl,"target")).position)},{"bones",neckRecord},{"calculators",neckCalcRecord}};
        var eyeScript=Required(eyeCtrl,"eyeLookScript");
        var eyes=Flatten(Required(eyeScript,"eyeObjs")) as List<object>;
        var eyeRecord=new List<object>();
        var eyeGeometry=new List<object>();
        for(int i=0;i<eyes.Count;i++) {
            var eye=eyes[i];
            var diagnosed=ClassifyMember(Member(eye,"eyeTransform"));
            var eyeTransform=Member(eye,"eyeTransform") as Transform;
            if(eyeTransform==null) {
                // Same fallback as the neck bones: the cf_J_Eye_rz_* bones are
                // the ones the look controller drives; eyeObjs[0] is the left.
                string fallback=i==0?"cf_J_Eye_rz_L":"cf_J_Eye_rz_R";
                eyeTransform=FindBone(fallback);
                if(eyeTransform==null)throw new Exception("eyeObjs["+i+"] eyeTransform is "+diagnosed+" and no fallback bone "+fallback+" was found");
            }
            eyeRecord.Add(new Dictionary<string,object>{{"eye",eyeTransform.name},{"eyeTransform",diagnosed},{"localRotation",V(eyeTransform.localRotation)},{"angleH",Required(eye,"angleH")},{"angleV",Required(eye,"angleV")}});
            // ST-T07m: the EyeObject internals EyeLookCalc keeps per eye; the
            // eye reference dirs are only read by this recorder, never set.
            eyeGeometry.Add(new Dictionary<string,object>{
                {"eye",(object)eyeTransform.name},{"target",Geometry(eyeTransform)},
                {"origRotation",V((Quaternion)Required(eye,"origRotation"))},
                {"referenceLookDir",V((Vector3)Required(eye,"referenceLookDir"))},
                {"referenceUpDir",V((Vector3)Required(eye,"referenceUpDir"))},
                {"dirUp",V((Vector3)Required(eye,"dirUp"))}});
        }
        var eyeCalcRecord=new List<object>{new Dictionary<string,object>{
            {"angleHRate",Flatten(Required(eyeScript,"angleHRate"))},
            {"angleVRate",Flatten(Required(eyeScript,"angleVRate"))}}};
        record["eyes"]=new Dictionary<string,object>{{"ptnNo",Required(eyeCtrl,"ptnNo")},{"target",V(((Transform)Required(eyeCtrl,"target")).position)},{"eyes",eyeRecord},{"calculators",eyeCalcRecord}};
        // ST-T07x: what EyeLookMaterialControll.Update left on the eye
        // materials at end of frame — the material's three texture transforms
        // and _rotation, plus the private offset/scale/hl inputs Update reads.
        // eyeLookMatCtrl is a private ChaControl field assigned from
        // objEyeL/objEyeR after LoadAsync; _material is private too, and
        // ReSetupMaterial only ever fills it from GetComponent<Renderer>(),
        // so that is the equivalent fallback here.
        var matCtrls=Flatten(Required(character,"eyeLookMatCtrl")) as List<object>;
        if(matCtrls==null||matCtrls.Count!=2)throw new Exception("eyeLookMatCtrl is missing or does not hold two controllers");
        var irisRecord=new List<object>();
        for(int i=0;i<2;i++) {
            var ctrl=matCtrls[i];
            var component=ctrl as Component;
            if(component==null)throw new Exception("eyeLookMatCtrl["+i+"] is "+ClassifyMember(ctrl));
            var material=Member(ctrl,"_material") as Material;
            if(material==null) {
                var renderer=component.GetComponent<Renderer>();
                if(renderer==null)throw new Exception("eyeLookMatCtrl["+i+"] has no _material and no Renderer");
                material=renderer.material;
            }
            var texRecord=new Dictionary<string,object>();
            foreach(string texName in new[]{"_MainTex","_overtex1","_overtex2"})texRecord[texName]=new Dictionary<string,object>{{"offset",V(material.GetTextureOffset(texName))},{"scale",V(material.GetTextureScale(texName))}};
            irisRecord.Add(new Dictionary<string,object>{
                {"gameObject",(object)component.gameObject.name},{"materialName",material.name},
                {"offset",Flatten(Required(ctrl,"offset"))},{"scale",Flatten(Required(ctrl,"scale"))},
                {"hlUpOffsetY",Required(ctrl,"hlUpOffsetY")},{"hlDownOffsetY",Required(ctrl,"hlDownOffsetY")},
                {"rotation",material.GetFloat("_rotation")},{"textures",texRecord}});
        }
        record["iris"]=irisRecord;
        // ST-T07m: world geometry of every transform the recovered
        // GetAngleToTarget/limit-check formulas read (transformAim,
        // boneCalcAngle, the last bone's neckBone and referenceCalc), the
        // nearby neck/spine bones, the EyeLookCalc nodes and the solver
        // members the limit check consults, so the formulas can be re-run
        // offline against the recorded nowAngle.
        var ptnNoValue=Convert.ToInt32(Required(neckCtrl,"ptnNo"));
        var typeStates=Flatten(Required(neckScript,"neckTypeStates")) as List<object>;
        if(typeStates==null||ptnNoValue<0||ptnNoValue>=typeStates.Count)throw new Exception("neckTypeStates has no entry for ptnNo "+ptnNoValue);
        var lastBone=bones[bones.Count-1];
        var geometryRecord=new Dictionary<string,object>{
            {"aim",Geometry(RequiredTransform(neckScript,"transformAim"))},
            {"neckRef",Geometry(RequiredTransform(neckScript,"boneCalcAngle"))},
            {"headRef",Geometry(RequiredTransform(lastBone,"referenceCalc"))},
            {"headBone",Geometry(RequiredTransform(lastBone,"neckBone"))},
            {"changeTypeTimer",Required(neckScript,"changeTypeTimer")},
            {"backupPos",V((Vector3)Required(neckScript,"backupPos"))},
            {"isLimitBreakBackup",Required(typeStates[ptnNoValue],"isLimitBreakBackup")},
            {"eyeCalc",new Dictionary<string,object>{
                {"rootNode",Geometry(RequiredTransform(eyeScript,"rootNode"))},
                {"trfCenter",Geometry(RequiredTransform(eyeScript,"trfCenter"))}}},
            {"eyes",eyeGeometry}};
        foreach(string lookBoneName in new[]{"cf_j_neck","cf_j_head","cf_j_spine03"}) {
            var lookBone=FindBone(lookBoneName);
            if(lookBone==null)throw new Exception("the fixture character has no "+lookBoneName+" transform");
            geometryRecord[lookBoneName]=Geometry(lookBone);
        }
        record["geometry"]=geometryRecord;
        lookRecords.Add(record);
    }
    Transform FindBone(string name) {
        foreach(var t in character.GetComponentsInChildren<Transform>(true)) if(t.name==name) return t;
        return null;
    }
}
