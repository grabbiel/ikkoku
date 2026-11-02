// #348 sampler probe (original side): what the original CharaStudio player (Unity 5.6.2f1, D3D11) samples for a
// texture's filterMode and anisoLevel under each QualitySettings.anisotropicFiltering mode, and the filter, aniso and
// mip settings of the install's chara, studio and map textures. Driver: Tools/reverse/original_sampler_probe.py run
// (one prlctl exec, private player root, BepInEx core only).
//
// Matrix. Every texture is synthetic and made here: 256x256 RGBA32, linear, Repeat. Mip level l (of 9) holds
// R = round(255 l / 8) everywhere and G = a one-texel checkerboard, B = 0, A = 255; a single-level texture is level 0.
// Each cell (filter Point/Bilinear/Trilinear x anisoLevel 0/1/2/8/16 x mipmapped or single-level) is a fresh texture
// drawn twice into a 128x128 linear ARGB32 target by a probe camera that renders only layer 31, far from the scene:
//   grazing:   a 200x200 plane (32 texels per unit), the camera 1 unit above it and pitched 30 degrees down
//              (60 degree field of view), so the rows run from the horizon (anisotropy ratio above 16) to 60 degrees;
//   magnified: a quad filling the view at distance 1 that shows 4x4 texels of level 0 (32 pixels per texel).
// Each cell runs under the player's own mode first, then the other two modes, set at runtime; the original mode,
// fog and the probe camera's objects are restored or destroyed in a finally block. A control frame with no object
// shows the camera sees nothing else, and one cell is drawn again after the restore and must be byte-identical.
// What the pixels say: G strictly between 0 and 255 in the magnified frame means linear min/mag filtering; R off the
// level values in the grazing frame means linear mip filtering; the rows' R profile against the aniso-1 cell shows
// whether anisotropy is on. The driver's analyse step and a host Metal render of the same views decide each cell.
//
// Survey. Then every *.unity3d under abdata/chara, abdata/studio and abdata/map is opened in turn: a bundle the game
// already holds (AssetBundleManager) is read in place and left loaded; any other is loaded with
// AssetBundle.LoadFromFile, its Texture2D assets are read and it is unloaded with Unload(true). Only each texture's
// name, filterMode, anisoLevel, mipmapCount, size and wrapMode are recorded; no pixels, no other asset type, nothing
// written outside this plug-in's reload folder. No cards, saves, scenes or mods are read.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using BepInEx;
using Manager;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.samplerprobe", "Ikkoku sampler probe", "1.0.0")]
public sealed class OriginalSamplerProbe:BaseUnityPlugin {
    const int TextureSize=256,Levels=9,Target=128,Layer=31,TexelsPerUnit=32;
    const float SurveySeconds=1500f;
    static readonly Vector3 Origin=new Vector3(5000f,-5000f,5000f);
    static readonly string[] Filters={"Point","Bilinear","Trilinear"};
    static readonly int[] Anisos={0,1,2,8,16};
    static readonly string[] SurveyRoots={"chara","studio","map"};
    static readonly string[] ShaderNames={"Unlit/Texture","Unlit/Transparent","Sprites/Default","UI/Default"};
    string folder,abdata;
    readonly List<string> errors=new List<string>();
    readonly List<object> cells=new List<object>();
    Shader shader;string shaderName;
    Camera probeCamera;RenderTexture target;
    IEnumerator Start() {
        var dir=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        folder=Path.Combine(dir,"reload");Directory.CreateDirectory(folder);
        abdata=Path.GetFullPath(Path.Combine(Path.Combine(dir,".."),Path.Combine("..","abdata")));
        int waited=0;
        for(;waited<3600&&!Ready();waited++)yield return null;
        if(waited>=3600)errors.Add("Studio or the scene manager were not ready within 3600 frames");
        for(int i=0;i<60;i++)yield return null;
        object qualityBefore=Quality(),qualityAfter=null,restoredCheck=null,control=null;
        var originalMode=QualitySettings.anisotropicFiltering;bool originalFog=RenderSettings.fog;
        var layerRenderers=0;foreach(var r in FindObjectsOfType<Renderer>())if(r.gameObject.layer==Layer)layerRenderers++;
        var modes=new List<AnisotropicFiltering>{originalMode};
        foreach(AnisotropicFiltering m in new[]{AnisotropicFiltering.ForceEnable,AnisotropicFiltering.Enable,AnisotropicFiltering.Disable})if(m!=originalMode)modes.Add(m);
        if(errors.Count==0) {
            try {
                RenderSettings.fog=false;
                shader=FindShader(out shaderName);
                target=new RenderTexture(Target,Target,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.Linear);
                target.antiAliasing=1;target.useMipMap=false;target.Create();
                probeCamera=MakeCamera();
                control=Draw(null,"control-empty",false);
                foreach(var mode in modes) {
                    QualitySettings.anisotropicFiltering=mode;
                    foreach(var filter in Filters)foreach(var aniso in Anisos)foreach(var mipmapped in new[]{true,false})
                        cells.Add(Cell(filter,aniso,mipmapped,mode));
                }
            } catch(Exception e){errors.Add("matrix: "+e);}
            finally {
                QualitySettings.anisotropicFiltering=originalMode;RenderSettings.fog=originalFog;
            }
            try {
                // The first mode's Bilinear/aniso-1/mipmapped cell again, after the restore: it must be byte-identical.
                if(probeCamera!=null&&target!=null&&cells.Count>0) {
                    RenderSettings.fog=false;
                    var again=Cell("Bilinear",1,true,originalMode,"restored-");
                    restoredCheck=K("cell",again,"matches",SameFiles((Dictionary<string,object>)again,FindCell("Bilinear",1,true,originalMode)));
                }
            } catch(Exception e){errors.Add("restore check: "+e);}
            finally {
                RenderSettings.fog=originalFog;
                if(probeCamera!=null)Destroy(probeCamera.gameObject);
                if(target!=null){target.Release();Destroy(target);}
            }
        }
        qualityAfter=Quality();
        try{File.WriteAllText(Path.Combine(folder,"sampler-trace.json"),J(K("schemaVersion",1,
            "texture",K("size",TextureSize,"levels",Levels,"format","RGBA32","linear",true,"wrap","Repeat",
                "levelValueR","round(255 * level / 8)","checkerG","((x + y) & 1) * 255 per level texel","B",0,"A",255),
            "target",K("size",Target,"format","ARGB32","readWrite","Linear","antiAliasing",1,"clear",new[]{0,0,255,0},"layer",Layer),
            "shader",shaderName,"qualityBefore",qualityBefore,"qualityAfter",qualityAfter,"layerRenderersBefore",layerRenderers,
            "modes",Names(modes),"control",control,"cells",cells,"restoredCheck",restoredCheck)));}
        catch(Exception e){errors.Add("trace write: "+e);}
        object survey=null;
        if(errors.Count==0){var run=Survey();while(true){bool more=false;try{more=run.MoveNext();}catch(Exception e){errors.Add("survey: "+e);}if(!more)break;yield return run.Current;}survey=surveySummary;}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(K("error",errors.Count==0?null:String.Join(" | ",errors.ToArray()),"errors",errors,
            "unity",Application.unityVersion,"device",SystemInfo.graphicsDeviceName,"graphicsAPI",SystemInfo.graphicsDeviceVersion,
            "graphicsDeviceType",SystemInfo.graphicsDeviceType.ToString(),"cells",cells.Count,"survey",survey,
            "qualityRestored",qualityAfter!=null&&J(qualityAfter)==J(qualityBefore),
            "scope","Synthetic textures drawn by a probe camera in the original CharaStudio player under each anisotropicFiltering mode (restored afterwards), and the filter, aniso, mip, size and wrap settings of the Texture2D assets in abdata/chara, abdata/studio and abdata/map; no pixels of game assets, no cards, saves, scenes or mods.")));
        Application.Quit();
        for(int i=0;i<3600;i++){yield return null;if(i%30==29)Application.Quit();}
    }
    static bool Ready() {
        if(!Singleton<Studio.Studio>.IsInstance()||!Singleton<Scene>.IsInstance())return false;
        var scene=Singleton<Scene>.Instance;
        return scene.commonSpace!=null&&Camera.main!=null&&scene.AddSceneName==string.Empty&&!scene.IsNowLoadingFade;
    }
    static Dictionary<string,object> Quality() {
        return K("anisotropicFiltering",QualitySettings.anisotropicFiltering.ToString(),"level",QualitySettings.GetQualityLevel(),
            "names",QualitySettings.names,"masterTextureLimit",QualitySettings.masterTextureLimit,"antiAliasing",QualitySettings.antiAliasing,
            "activeColorSpace",QualitySettings.activeColorSpace.ToString(),"fog",RenderSettings.fog);
    }
    static List<string> Names(List<AnisotropicFiltering> modes){var a=new List<string>();foreach(var m in modes)a.Add(m.ToString());return a;}
    static Shader FindShader(out string name) {
        foreach(var n in ShaderNames){var s=Shader.Find(n);if(s!=null&&s.isSupported){name=n;return s;}}
        throw new Exception("none of "+String.Join(", ",ShaderNames)+" is in this player");
    }
    Camera MakeCamera() {
        var go=new GameObject("IkkokuSamplerProbeCamera");
        var c=go.AddComponent<Camera>();c.enabled=false;c.targetTexture=target;c.clearFlags=CameraClearFlags.SolidColor;
        c.backgroundColor=new Color(0f,0f,1f,0f);c.cullingMask=1<<Layer;c.fieldOfView=60f;c.aspect=1f;c.nearClipPlane=0.05f;c.farClipPlane=500f;
        c.allowHDR=false;c.allowMSAA=false;c.useOcclusionCulling=false;c.renderingPath=RenderingPath.Forward;
        return c;
    }
    static Texture2D MakeTexture(string filter,int aniso,bool mipmapped) {
        var t=new Texture2D(TextureSize,TextureSize,TextureFormat.RGBA32,mipmapped,true);
        int levels=mipmapped?t.mipmapCount:1;
        for(int l=0;l<levels;l++) {
            int s=Math.Max(1,TextureSize>>l);var px=new Color32[s*s];
            byte r=(byte)Math.Round(255.0*l/(Levels-1));
            for(int y=0;y<s;y++)for(int x=0;x<s;x++)px[y*s+x]=new Color32(r,((x+y)&1)==0?(byte)0:(byte)255,0,255);
            t.SetPixels32(px,l);
        }
        t.Apply(false,false);
        t.wrapMode=TextureWrapMode.Repeat;t.filterMode=(FilterMode)Enum.Parse(typeof(FilterMode),filter);t.anisoLevel=aniso;
        return t;
    }
    Dictionary<string,object> Cell(string filter,int aniso,bool mipmapped,AnisotropicFiltering mode,string prefix="cell-") {
        var id=filter.ToLowerInvariant()+"-a"+aniso+"-"+(mipmapped?"mips":"single")+"-"+mode.ToString().ToLowerInvariant();
        var texture=MakeTexture(filter,aniso,mipmapped);
        try {
            var grazing=Draw(texture,prefix+id+"-grazing",true);var magnified=Draw(texture,prefix+id+"-magnified",false);
            return K("id",id,"filter",filter,"aniso",aniso,"mipmapped",mipmapped,"mode",mode.ToString(),
                "readBack",K("filterMode",texture.filterMode.ToString(),"anisoLevel",texture.anisoLevel,"wrapMode",texture.wrapMode.ToString(),"mipmapCount",texture.mipmapCount),
                "modeWhenDrawn",QualitySettings.anisotropicFiltering.ToString(),"grazing",grazing,"magnified",magnified);
        } finally {Destroy(texture);}
    }
    Dictionary<string,object> FindCell(string filter,int aniso,bool mipmapped,AnisotropicFiltering mode) {
        foreach(Dictionary<string,object> c in cells)if((string)c["filter"]==filter&&(int)c["aniso"]==aniso&&(bool)c["mipmapped"]==mipmapped&&(string)c["mode"]==mode.ToString())return c;
        return null;
    }
    static bool SameFiles(Dictionary<string,object> a,Dictionary<string,object> b) {
        if(a==null||b==null)return false;
        foreach(var view in new[]{"grazing","magnified"})if((string)((Dictionary<string,object>)a[view])["sha256"]!=(string)((Dictionary<string,object>)b[view])["sha256"])return false;
        return true;
    }
    // Draws `texture` (or nothing) in the grazing or the magnified view and writes <name>.png.
    Dictionary<string,object> Draw(Texture2D texture,string name,bool grazing) {
        GameObject go=null;Material material=null;Mesh mesh=null;
        try {
            Vector3 cameraAt;Quaternion facing;
            if(grazing){cameraAt=Origin+new Vector3(0f,1f,0f);facing=Quaternion.Euler(30f,0f,0f);}
            else{cameraAt=Origin+new Vector3(0f,0f,-1f);facing=Quaternion.identity;}
            probeCamera.transform.position=cameraAt;probeCamera.transform.rotation=facing;
            if(texture!=null) {
                mesh=new Mesh();
                if(grazing) {
                    mesh.vertices=new[]{new Vector3(-100f,0f,0f),new Vector3(100f,0f,0f),new Vector3(-100f,0f,200f),new Vector3(100f,0f,200f)};
                    float k=(float)TexelsPerUnit/TextureSize;
                    mesh.uv=new[]{new Vector2(-100f*k,0f),new Vector2(100f*k,0f),new Vector2(-100f*k,200f*k),new Vector2(100f*k,200f*k)};
                } else {
                    float h=Mathf.Tan(30f*Mathf.Deg2Rad),u0=0.5f/TextureSize,u1=4.5f/TextureSize;
                    mesh.vertices=new[]{new Vector3(-h,-h,0f),new Vector3(h,-h,0f),new Vector3(-h,h,0f),new Vector3(h,h,0f)};
                    mesh.uv=new[]{new Vector2(u0,u0),new Vector2(u1,u0),new Vector2(u0,u1),new Vector2(u1,u1)};
                }
                mesh.colors32=new[]{new Color32(255,255,255,255),new Color32(255,255,255,255),new Color32(255,255,255,255),new Color32(255,255,255,255)};
                mesh.triangles=new[]{0,2,1,2,3,1};mesh.RecalculateBounds();
                go=new GameObject("IkkokuSamplerProbeSurface");go.layer=Layer;go.transform.position=Origin;
                go.AddComponent<MeshFilter>().sharedMesh=mesh;
                var renderer=go.AddComponent<MeshRenderer>();
                material=new Material(shader);material.mainTexture=texture;if(material.HasProperty("_Color"))material.color=Color.white;
                renderer.sharedMaterial=material;renderer.shadowCastingMode=UnityEngine.Rendering.ShadowCastingMode.Off;renderer.receiveShadows=false;
                renderer.lightProbeUsage=UnityEngine.Rendering.LightProbeUsage.Off;renderer.reflectionProbeUsage=UnityEngine.Rendering.ReflectionProbeUsage.Off;
            }
            probeCamera.Render();
            var previous=RenderTexture.active;RenderTexture.active=target;
            var read=new Texture2D(Target,Target,TextureFormat.RGBA32,false,true);
            read.ReadPixels(new Rect(0,0,Target,Target),0,0);read.Apply(false,false);RenderTexture.active=previous;
            var png=read.EncodeToPNG();Destroy(read);
            var file=name+".png";File.WriteAllBytes(Path.Combine(folder,file),png);
            return K("file",file,"sha256",Sha256(png),"camera",K("position",V(cameraAt),"rotationEuler",V(facing.eulerAngles),
                "worldToCamera",M(probeCamera.worldToCameraMatrix),"projection",M(probeCamera.projectionMatrix)));
        } finally {
            if(go!=null)DestroyImmediate(go);if(material!=null)DestroyImmediate(material);if(mesh!=null)DestroyImmediate(mesh);
        }
    }
    // --- survey ----------------------------------------------------------------------------------------------------
    Dictionary<string,object> surveySummary;
    IEnumerator Survey() {
        var started=Time.realtimeSinceStartup;var bundles=new List<object>();int textures=0,opened=0;bool truncated=false;
        var writer=new StringBuilder();
        foreach(var top in SurveyRoots) {
            var root=Path.Combine(abdata,top);
            if(!Directory.Exists(root)){bundles.Add(K("bundle",top,"status","missing"));continue;}
            var files=new List<string>(Directory.GetFiles(root,"*.unity3d",SearchOption.AllDirectories));files.Sort(StringComparer.Ordinal);
            foreach(var path in files) {
                if(Time.realtimeSinceStartup-started>SurveySeconds){truncated=true;break;}
                var rel=path.Substring(abdata.Length+1).Replace('\\','/');
                var row=SurveyBundle(path,rel,writer);bundles.Add(row);opened++;if(row.ContainsKey("textures"))textures+=(int)row["textures"];
                yield return null;
                if(opened%50==0){yield return Resources.UnloadUnusedAssets();GC.Collect();}
            }
            if(truncated)break;
        }
        File.WriteAllText(Path.Combine(folder,"sampler-survey.json"),"{\"schemaVersion\":1,\"columns\":[\"bundle\",\"name\",\"filter\",\"aniso\",\"mips\",\"width\",\"height\",\"wrap\"],\"textures\":["
            +writer.ToString()+"],\"bundles\":"+J(bundles)+",\"truncated\":"+(truncated?"true":"false")+",\"seconds\":"+J(Time.realtimeSinceStartup-started)+"}");
        surveySummary=K("bundles",opened,"textures",textures,"truncated",truncated);
    }
    static Dictionary<string,object> SurveyBundle(string path,string rel,StringBuilder writer) {
        AssetBundle bundle=null;bool held=false;
        try{string error;var loaded=AssetBundleManager.GetLoadedAssetBundle(rel,out error);if(loaded!=null&&loaded.m_AssetBundle!=null){bundle=loaded.m_AssetBundle;held=true;}}
        catch(Exception){}
        try {
            if(bundle==null)bundle=AssetBundle.LoadFromFile(path);
            if(bundle==null)return K("bundle",rel,"status","loadFailed");
            if(bundle.isStreamedSceneAssetBundle)return K("bundle",rel,"status","scene","held",held);
            int count=0;
            foreach(var t in bundle.LoadAllAssets<Texture2D>()) {
                if(writer.Length>0)writer.Append(',');
                writer.Append('[').Append(J(rel)).Append(',').Append(J(t.name)).Append(',').Append(J(t.filterMode.ToString())).Append(',').Append(t.anisoLevel)
                    .Append(',').Append(t.mipmapCount).Append(',').Append(t.width).Append(',').Append(t.height).Append(',').Append(J(t.wrapMode.ToString())).Append(']');
                count++;
            }
            return K("bundle",rel,"status","read","held",held,"textures",count);
        } catch(Exception e){return K("bundle",rel,"status","error","error",e.GetType().Name+": "+e.Message);}
        finally{if(bundle!=null&&!held)bundle.Unload(true);}
    }
    // --- encoding --------------------------------------------------------------------------------------------------
    static string Sha256(byte[] data){using(var h=SHA256.Create()){var b=new StringBuilder();foreach(var x in h.ComputeHash(data))b.Append(x.ToString("x2"));return b.ToString();}}
    static List<object> V(Vector3 v){return new List<object>{v.x,v.y,v.z};}
    static List<object> M(Matrix4x4 m){var a=new List<object>();for(int r=0;r<4;r++)for(int c=0;c<4;c++)a.Add(m[r,c]);return a;}
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;
        if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('\"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        if(value is float)return ((float)value).ToString("R",CultureInfo.InvariantCulture);
        if(value is double)return ((double)value).ToString("R",CultureInfo.InvariantCulture);
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
