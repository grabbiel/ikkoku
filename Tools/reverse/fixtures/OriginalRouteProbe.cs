// Authored two-route capture: serialized scene record plus per-frame childRoot world placement. No characters or media.
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
[BepInPlugin("org.ikkoku.validation.routeprobe", "Ikkoku route probe", "1.0.0")]
public sealed class OriginalRouteProbe:BaseUnityPlugin {
    const int Frames=240; string folder; OCIRoute a,b;
    IEnumerator Start() {
        folder=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"route");Directory.CreateDirectory(folder);
        string error=null;
        for(int i=0;i<1200;i++) { // Studio and its scene container are built during scene start-up.
            // Studio is both a namespace and a class, so the singleton type must be qualified from this global-namespace file.
            bool ready=Singleton<Studio.Studio>.IsInstance()&&Singleton<Scene>.IsInstance()&&Singleton<Scene>.Instance.commonSpace!=null&&Singleton<Studio.Studio>.Instance.sceneInfo!=null;
            if(ready)break;
            yield return null;
        }
        try{Build();}catch(Exception e){error=e.ToString();}
        if(error==null) {
            var step=Capture();
            for(;;){bool more=false;object current=null;try{more=step.MoveNext();if(more)current=step.Current;}catch(Exception e){error=e.ToString();}if(error!=null||!more)break;yield return current;}
        }
        if(error==null) { try{Remove();}catch(Exception e){error=e.ToString();} }
        File.WriteAllText(Path.Combine(folder,"status.json"),J(new Dictionary<string,object>{{"error",error},{"unity",Application.unityVersion},{"scope","Two authored routes: scene record saved while playing, and per-frame childRoot world placement; no characters, media or LookUpdate smoothing model"}}));
        Application.Quit();
    }
    void Build() {
        var studio=Singleton<Studio.Studio>.Instance;
        if(studio.sceneInfo==null)throw new Exception("Studio sceneInfo is not ready after startup wait");
        if(studio.dicObjectCtrl.Count!=0)throw new Exception("Route probe expects an empty scene, found "+studio.dicObjectCtrl.Count+" objects");
        studio.cameraCtrl.enabled=false;
        a=AddObjectRoute.Add();b=AddObjectRoute.Add();
        if(a==null||b==null)throw new Exception("Route asset failed to load");
        a.routeInfo.name="IKKOKU-A";b.routeInfo.name="IKKOKU-B";
        a.routeInfo.changeAmount.pos=new Vector3(1.5f,0f,2f);a.routeInfo.changeAmount.OnChange();
        b.routeInfo.changeAmount.pos=new Vector3(-2f,0f,1.5f);b.routeInfo.changeAmount.rot=new Vector3(0f,15f,0f);b.routeInfo.changeAmount.OnChange();
        for(int i=0;i<3;i++){a.AddPoint();b.AddPoint();} // Add() already contains point 0, so each route ends with four points.
        var pa=a.listPoint;var pb=b.listPoint;
        SetPos(pa[0],new Vector3(0f,0f,0f));SetPos(pa[1],new Vector3(0.6f,0.35f,-0.8f));SetPos(pa[2],new Vector3(0.1f,0.9f,0.7f));SetPos(pa[3],new Vector3(-0.9f,0.25f,-0.2f));
        SetPos(pb[0],new Vector3(0f,0f,0f));SetPos(pb[1],new Vector3(0.8f,0.2f,0.6f));SetPos(pb[2],new Vector3(-0.4f,0.55f,0.3f));SetPos(pb[3],new Vector3(-0.7f,0.5f,-0.9f));
        float[] speeds={1.5f,2f,3f};
        StudioTween.EaseType[] eases={StudioTween.EaseType.linear,StudioTween.EaseType.easeInQuad,StudioTween.EaseType.easeOutCubic};
        for(int i=0;i<3;i++){pa[i].speed=speeds[i];pa[i].easeType=eases[i];} // Route A keeps default speed 2 and linear easing on its wrapping point 3.
        for(int i=0;i<4;i++)pb[i].speed=2f;
        pb[1].connection=OIRoutePointInfo.Connection.Curve;pb[2].connection=OIRoutePointInfo.Connection.Curve;
        pb[2].link=true;
        var aid1=pb[1].pointAidInfo;
        aid1.aidInfo.changeAmount.pos=aid1.target.localPosition+new Vector3(0.35f,0.5f,-0.4f);aid1.aidInfo.changeAmount.OnChange(); // Point 2 keeps the auto-initialised aid; point 1 is offset explicitly.
        a.routeInfo.loop=true;b.routeInfo.loop=false;
        b.routeInfo.orient=OIRouteInfo.Orient.XY;
    }
    IEnumerator Capture() {
        var studio=Singleton<Studio.Studio>.Instance;
        bool playA=a.Play();bool playB=b.Play();
        foreach(var entry in studio.dicObjectCtrl)entry.Value.OnSavePreprocessing();
        studio.sceneInfo.cameraSaveData=studio.cameraCtrl.Export();
        if(!studio.sceneInfo.Save(Path.Combine(folder,"route-scene.png")))throw new Exception("SceneInfo.Save returned false"); // Routes stay active=true so the record describes a playing scene.
        var routes=new List<object>{RouteEvidence(a,"IKKOKU-A",playA),RouteEvidence(b,"IKKOKU-B",playB)};
        var trace=new List<object>();
        float cumulative=0f;
        long playFrame=Time.frameCount;
        Time.timeScale=1f;
        for(int i=0;i<240;i++) {
            float dt=Time.deltaTime;cumulative+=dt;
            yield return null; // The snapshot resumes after that frame's Update phase, in which StudioTween advances runningTime by Time.deltaTime.
            trace.Add(K("frameCount",Time.frameCount,"timeScale",Time.timeScale,"deltaTime",dt,"cumulativeTime",cumulative,
                "a",Snap(a),"b",Snap(b)));
        }
        File.WriteAllText(Path.Combine(folder,"route-trace.json"),J(new Dictionary<string,object>{{"schemaVersion",1},{"playFrameCount",playFrame},{"frameCount",240},{"routes",routes},{"trace",trace}}));
    }
    void Remove() { // Leave no scene objects behind; the trace and scene record are already on disk.
        Singleton<Studio.Studio>.Instance.enabled=false;
        a.Stop();b.Stop();a.OnDelete();b.OnDelete();
    }
    static void SetPos(OCIRoutePoint point,Vector3 local) { var ca=point.routePointInfo.changeAmount;ca.pos=local;ca.OnChange(); }
    static Dictionary<string,object> Snap(OCIRoute route) {
        return K("position",V(route.childRoot.position),"rotation",Q(route.childRoot.rotation),"active",route.routeInfo.active);
    }
    static Dictionary<string,object> RouteEvidence(OCIRoute route,string expected,bool played) {
        var info=route.routeInfo;var t=route.objectItem.transform;
        var points=new List<object>();foreach(var p in route.listPoint)points.Add(PointEvidence(p));
        return K("dicKey",info.dicKey,"expectedName",expected,"playReturned",played,"name",info.name,
            "active",info.active,"loop",info.loop,"visibleLine",info.visibleLine,"orientation",(int)info.orient,
            "worldPosition",V(t.position),"worldRotation",Q(t.rotation),"worldScale",V(t.lossyScale),
            "localPosition",V(t.localPosition),"localRotation",Q(t.localRotation),"localScale",V(t.localScale),
            "changePosition",V(info.changeAmount.pos),"changeRotation",V(info.changeAmount.rot),
            "childRootLocalPosition",V(route.childRoot.localPosition),
            "childRootInRouteLocalPosition",V(t.InverseTransformPoint(route.childRoot.position)),
            "points",points);
    }
    static Dictionary<string,object> PointEvidence(OCIRoutePoint point) {
        var info=point.routePointInfo;var aid=point.pointAidInfo;var t=point.objectItem.transform;var at=aid.target;
        var aidWorld=at.position;
        return K("dicKey",info.dicKey,"connection",(int)info.connection,"speed",info.speed,"easeType",(int)info.easeType,
            "link",info.link,"isLink",point.isLink,"aidInitialized",aid.aidInfo.isInit,"aidActive",aid.active,
            "worldPosition",V(t.position),"worldRotation",Q(t.rotation),"localPosition",V(t.localPosition),"localRotation",Q(t.localRotation),
            "changePosition",V(info.changeAmount.pos),"changeRotation",V(info.changeAmount.rot),
            "aidWorldPosition",V(aidWorld),"aidLocalPosition",V(at.localPosition),"aidChangePosition",V(aid.aidInfo.changeAmount.pos),
            "aidInPointLocal",V(t.InverseTransformPoint(aidWorld)),
            "aidInRouteLocal",V(point.route.objectItem.transform.InverseTransformPoint(aidWorld)));
    }
    static Dictionary<string,object> K(params object[] kv){var d=new Dictionary<string,object>();for(int i=0;i<kv.Length;i+=2)d[(string)kv[i]]=kv[i+1];return d;}
    static float[] V(Vector3 v){return new[]{v.x,v.y,v.z};}static float[] Q(Quaternion q){return new[]{q.x,q.y,q.z,q.w};}
    static string J(object value) {
        if(value==null)return "null";var s=value as string;if(s!=null){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        if(value is bool)return (bool)value?"true":"false";
        if(value is float&&(Single.IsNaN((float)value)||Single.IsInfinity((float)value)))return "null";
        var d=value as IDictionary;if(d!=null){var a=new List<string>();foreach(DictionaryEntry e in d)a.Add(J((string)e.Key)+":"+J(e.Value));return "{"+String.Join(",",a.ToArray())+"}";}
        var list=value as IEnumerable;if(list!=null){var a=new List<string>();foreach(var x in list)a.Add(J(x));return "["+String.Join(",",a.ToArray())+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
}
