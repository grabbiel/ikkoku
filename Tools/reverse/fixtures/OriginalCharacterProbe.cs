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
    IEnumerator Start()
    {
        folder = Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location), "character");
        Directory.CreateDirectory(folder);
        for (int i=0;i<30;i++) yield return null;
        string error = null;
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
        for(int i=0;i<10;i++) yield return null;
        try { Capture(); } catch(Exception e) { error=e.ToString(); }
        Finish(error);
    }
    void Finish(string error) {
        File.WriteAllText(Path.Combine(folder,"status.json"),J(new Dictionary<string,object>{{"error",error},{"unity",Application.unityVersion},{"device",SystemInfo.graphicsDeviceName},{"graphicsAPI",SystemInfo.graphicsDeviceVersion},{"colorSpace",QualitySettings.activeColorSpace.ToString()}}));
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
        character=Manager.Character.Instance.CreateFemale(null,1,file,true);
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
    static float[] V(Vector2 v){return new[]{v.x,v.y};}static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}static float[] V(Vector4 v){return new[]{v.x,v.y,v.z,v.w};}static float[] V(Quaternion v){return new[]{v.x,v.y,v.z,v.w};}static float[] V(Color v){return new[]{v.r,v.g,v.b,v.a};}
    static float[] M(Matrix4x4 m){var a=new float[16];for(int i=0;i<16;i++)a[i]=m[i];return a;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
