// Numerical DynamicBone verification; optional scripted particle-motion capture; fresh fully clothed fixture, no media export.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using BepInEx;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.dynamicsprobe", "Ikkoku dynamics probe", "1.0.0")]
public sealed class OriginalDynamicsProbe:BaseUnityPlugin {
    string folder; ChaControl character; DynamicBone[] hairDynamics;
    List<DynamicBoneCollider> snapshotColliders; List<bool> snapshotEnabled;
    void SnapshotColliders() {
        snapshotColliders=new List<DynamicBoneCollider>();snapshotEnabled=new List<bool>();
        foreach(var collider in character.GetComponentsInChildren<DynamicBoneCollider>(true))
            if(!snapshotColliders.Contains(collider)) {snapshotColliders.Add(collider);snapshotEnabled.Add(collider.enabled);}
    }
    // Scripted motion inputs: 90 frames at a fixed 60 Hz step; root sway plus yaw plus
    // a deterministic sub-millimetre jitter sequence so owner motion is never axis-aligned.
    const int MotionFrames=90;
    static readonly int[] MotionSeed={11,23,37,41};
    static int NextMotionValue(ref int state) {state=state*1103515245+12345;return(state>>16)&0x7fff;}
    static Vector3 MotionJitter(int i) {
        int state=MotionSeed[i&3];
        for(int k=0;k<=i;k++)NextMotionValue(ref state);
        return new Vector3(((state%41)-20)*1e-5f,(state>>7%13)*1e-5f,((state>>4%37)-18)*1e-5f);
    }
    static Vector3 MotionPosition(int i,float x,float z,float yaw) {return new Vector3(x+0.34f*Mathf.Sin(i*0.11f),0,z+0.55f*Mathf.Sin(i*0.165f)) + MotionJitter(i);}
    static float MotionYaw(int i) {return 32f*Mathf.Sin(i*0.14f)+4f*Mathf.Sin(i*0.43f);}
    IEnumerator Motion() {
        var lines=File.ReadAllLines(Path.Combine(folder,"motion.tsv"));
        double parsed;
        if(lines.Length<2||!double.TryParse(lines[0].Split('\t')[0],out parsed)||parsed!=MotionFrames||!double.TryParse(lines[1].Split('\t')[0],out parsed)||parsed!=60)throw new Exception("Motion request frame count or fixed step differs from the scripted capture");
        var start=character.transform.position;var startRotation=character.transform.rotation;
        var characterRoot=character.transform;var avatarRoot=characterRoot;
        foreach(var dynamics in hairDynamics) {
            string path="";
            for(var node=dynamics.transform;node!=null&&node.parent!=null;node=node.parent)path=node.name+"/"+path;
            var child=characterRoot;Transform first=null;
            foreach(string part in path.Split('/')) {
                if(part.Length==0)continue;
                int index=0;while(index<child.childCount&&child.GetChild(index).name!=part)index++;
                if(index==child.childCount)throw new Exception("Avatar hierarchy broken under "+character.name);
                child=child.GetChild(index);
                if(first==null)first=child;
            }
            if(first!=null&&avatarRoot==characterRoot)avatarRoot=first;
            if(first!=avatarRoot)throw new Exception("Hair components are not under one shared avatar root");
        }
        if(avatarRoot==characterRoot)throw new Exception("No avatar hierarchy below the fixture root");
        Time.captureFramerate=60;
        // Cross one WaitForEndOfFrame boundary before enabling anything so the
        // first original LateUpdate happens on a locked 1/60 frame; enabling
        // mid-Update would integrate one frame with the unlocked step first.
        yield return new WaitForEndOfFrame();
        // Capture() disabled every behaviour. Re-enable only the seven hair
        // components and their colliders: ChaControl refuses its own animated
        // motion on this direct-created fixture (null AnimeLayer), so the
        // deterministic root path below drives the hierarchy and the original
        // DynamicBone LateUpdate integrates the real particle motion on top of
        // it. Their serialized m_Weight keeps the per-frame InitTransforms
        // active, so every LateUpdate sees bind locals plus the recorded root
        // override - exactly the replay input contract. The m_Weight and
        // m_DistantDisable guards make a wrong assumption fail the capture.
        foreach(var dynamics in hairDynamics) {
            dynamics.enabled=true;
            if((float)Read(dynamics,"m_Weight")<=0f)throw new Exception("Hair DynamicBone weight is not positive, LateUpdate would not integrate");
            if((bool)Read(dynamics,"m_DistantDisable"))throw new Exception("Distance disabling is outside the motion capture scope");
        }
        var colliders=new List<DynamicBoneCollider>();
        foreach(var dynamics in hairDynamics)foreach(var collider in dynamics.m_Colliders)if(!colliders.Contains(collider))colliders.Add(collider);
        var colliderNames=new List<object>();
        var colliderEnabled=new List<object>();
        foreach(var collider in colliders) {
            var name=(object)collider.name;if(!colliderNames.Contains(name))colliderNames.Add(name);
            int index=snapshotColliders.IndexOf(collider);
            if(index<0)throw new Exception("Hair collider is outside the pre-disable collider snapshot");
            object state=snapshotEnabled[index];
            if(!(bool)state)throw new Exception("Hair collider is disabled in its serialized state; enabling it would diverge from the recorded contract");
            colliderEnabled.Add(state);collider.enabled=true;
        }
        // Integrator state right after the end-of-frame enable, before any
        // original LateUpdate step ran: OnEnable reset m_Position to the bind
        // world positions and m_Time to zero; the replay seeds from it.
        var states=new List<object>();
        foreach(var dynamics in hairDynamics) {
            var particleRows=new List<object>();
            foreach(var particle in Read(dynamics,"m_Particles") as IList) {
                var transform=(Transform)Read(particle,"m_Transform");
                if(transform==null)throw new Exception("Virtual hair end particle in motion capture seed");
                particleRows.Add(new Dictionary<string,object>{{"name",transform.name},
                    {"position",V((Vector3)Read(particle,"m_Position"))},{"previousPosition",V((Vector3)Read(particle,"m_PrevPosition"))}});}
            states.Add(new Dictionary<string,object>{{"rootName",dynamics.m_Root.name},{"owner",V(dynamics.transform.position)},
                {"weight",(float)Read(dynamics,"m_Weight")},{"time",(float)Read(dynamics,"m_Time")},
                {"objectMove",V((Vector3)Read(dynamics,"m_ObjectMove"))},{"objectScale",(float)Read(dynamics,"m_ObjectScale")},{"particles",particleRows}});
        }
        var framesJson=new List<object>();
        var delta=float.NaN;
        for(int frame=0;frame<MotionFrames;frame++) {
            character.transform.position=MotionPosition(frame,start.x,start.z,MotionYaw(frame));
            character.transform.rotation=startRotation*Quaternion.Euler(0,MotionYaw(frame),0);
            yield return new WaitForEndOfFrame();
            delta=Time.deltaTime;
            var componentRows=new List<object>();
            foreach(var dynamics in hairDynamics) {
                var particles=new List<object>();
                foreach(var particle in Read(dynamics,"m_Particles") as IList) {
                    var transform=(Transform)Read(particle,"m_Transform");
                    if(transform==null)throw new Exception("Virtual hair end particle in motion capture");
                    particles.Add(new Dictionary<string,object>{{"name",transform.name},{"position",V(transform.position)},{"rotation",Q(transform.rotation)}});
                }
                var colliderRows=new List<object>();
                foreach(var collider in dynamics.m_Colliders)colliderRows.Add(new Dictionary<string,object>{{"name",collider.name},{"position",V(collider.transform.position)},{"rotation",Q(collider.transform.rotation)}});
                componentRows.Add(new Dictionary<string,object>{
                    {"ownerName",dynamics.transform.name},{"rootName",dynamics.m_Root.name},{"owner",V(dynamics.transform.position)},
                    {"root",new Dictionary<string,object>{{"position",V(dynamics.m_Root.position)},{"rotation",Q(dynamics.m_Root.rotation)}}},
                    {"particles",particles},{"colliders",colliderRows}});
            }
            var colliderFrames=new List<object>();
            foreach(var collider in colliders)colliderFrames.Add(new Dictionary<string,object>{{"name",collider.name},{"position",V(collider.transform.position)},{"rotation",Q(collider.transform.rotation)}});
            framesJson.Add(new Dictionary<string,object>{{"deltaTime",delta},{"character",V(character.transform.position)},
                {"avatar",new Dictionary<string,object>{{"position",V(avatarRoot.position)},{"rotation",Q(avatarRoot.rotation)}}},
                {"components",componentRows},{"colliders",colliderFrames}});
        }
        if(!float.IsNaN(delta)&&Math.Abs(delta-1f/60f)>1e-6f)throw new Exception("Recorded frame step drifted from the fixed capture step");
        File.WriteAllText(Path.Combine(folder,"motion.json"),J(new Dictionary<string,object>{{"schemaVersion",1},
            {"scope","Original Unity hair particle motion under a scripted root path; the original DynamicBone integrates on top of it and the float32 replay replays the same seeded state; positions compared, rotations recorded as context only"},
            {"components",states},
            {"hairIDs",new[]{0,2}},
            {"frameCount",MotionFrames},{"fixedRateHz",60},{"startPosition",V(start)},{"startRotation",Q(startRotation)},
            {"avatarNode","child of the fixture root on every hair component ancestor chain, matching dynamics_reference original_document root 'avatar:root'"},
            {"colliders",new Dictionary<string,object>{{"count",colliders.Count},{"uniqueCount",colliderNames.Count},{"names",colliderNames},{"enabled",colliderEnabled}}},
            {"frames",framesJson}}));
    }
    IEnumerator Start() {
        folder=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"character");Directory.CreateDirectory(folder);
        for(int i=0;i<30;i++)yield return null;
        string error=null;
        try{CreateFixture();}catch(Exception e){error=e.ToString();}
        if(error==null){
            var load=character.LoadAsync(false,false);
            for(;;){bool more=false;object step=null;try{more=load.MoveNext();if(more)step=load.Current;}catch(Exception e){error=e.ToString();}if(error!=null||!more)break;yield return step;}
        }
        bool motion=File.Exists(Path.Combine(folder,"motion.tsv"));
        if(error==null&&motion)try{SnapshotColliders();}catch(Exception e){error=e.ToString();}
        if(error==null){for(int i=0;i<10;i++)yield return null;try{Capture();}catch(Exception e){error=e.ToString();}}
        string motionError=null;
        if(error==null&&motion) {
            var motionLoop=Motion();
            for(;;){bool more=false;object step=null;try{more=motionLoop.MoveNext();if(more)step=motionLoop.Current;}catch(Exception e){motionError=e.ToString();}if(motionError!=null||!more)break;yield return step;}
        }
        string status=error!=null?error:motionError;
        var statusData=new Dictionary<string,object>{{"error",status},{"unity",Application.unityVersion},{"scope","Numeric DynamicBone parameters and curves only; no source media"}};
        if(motion)statusData["motion"]=motionError==null?"captured":"requested but not reached";
        File.WriteAllText(Path.Combine(folder,"status.json"),J(statusData));Application.Quit();
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
        int[] hair={0,2,0,0};
        for(int i=0;i<hair.Length;i++) {
            var part=file.custom.hair.parts[i];part.id=hair[i];part.noShake=false;
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
        character.SetClothesStateAll(0);character.fileStatus.visibleSon=false;character.fileStatus.visibleSonAlways=false;character.UpdateForce();
        foreach(int slot in new[]{0,1,7})if(character.objClothes[slot]==null||!character.objClothes[slot].activeInHierarchy)throw new Exception("Clothed fixture garment missing");
        foreach(var r in character.GetComponentsInChildren<Renderer>()){
            if(r.enabled&&r.name.IndexOf("dankon",StringComparison.OrdinalIgnoreCase)>=0)throw new Exception("Clothed fixture privacy guard");r.enabled=false;
        }
        Manager.Character.Instance.enabled=false;
        foreach(var b in character.GetComponentsInChildren<Behaviour>(true))b.enabled=false;
        var components=new List<object>();
        var dynamicsList=new List<DynamicBone>();
        foreach(var dynamics in character.GetComponentsInChildren<DynamicBone>(true)) {
            if(dynamics.m_Root==null)continue;
            dynamicsList.Add(dynamics);
            var particles=Read(dynamics,"m_Particles") as IList;
            if(particles==null)throw new Exception("Missing DynamicBone particle list");
            var rows=new List<object>();
            foreach(var particle in particles) {
                var transform=(Transform)Read(particle,"m_Transform");
                rows.Add(new Dictionary<string,object>{{"name",transform==null?null:transform.name},{"parent",Read(particle,"m_ParentIndex")},
                    {"damping",Read(particle,"m_Damping")},{"elasticity",Read(particle,"m_Elasticity")},{"stiffness",Read(particle,"m_Stiffness")},
                    {"inert",Read(particle,"m_Inert")},{"radius",Read(particle,"m_Radius")},{"length",Read(particle,"m_BoneLength")}});
            }
            var curves=new Dictionary<string,object>();
            foreach(string name in new[]{"Damping","Elasticity","Stiffness","Inert","Radius"}) {
                var curve=(AnimationCurve)typeof(DynamicBone).GetField("m_"+name+"Distrib").GetValue(dynamics);
                if(curve==null||curve.length==0)continue;
                var keys=new List<object>();foreach(var key in curve.keys)keys.Add(new Dictionary<string,object>{{"time",key.time},{"value",key.value},{"inSlope",key.inTangent},{"outSlope",key.outTangent}});
                var values=new List<object>();for(int i=0;i<=64;i++){float t=(float)i/64;values.Add(new Dictionary<string,object>{{"time",t},{"value",curve.Evaluate(t)}});}
                curves[name]=new Dictionary<string,object>{{"keys",keys},{"samples",values},{"preWrap",curve.preWrapMode.ToString()},{"postWrap",curve.postWrapMode.ToString()}};
            }
            components.Add(new Dictionary<string,object>{{"ownerName",dynamics.transform.name},{"rootName",dynamics.m_Root.name},{"particles",rows},{"curves",curves},
                {"colliders",dynamics.m_Colliders==null?0:dynamics.m_Colliders.Count},{"updateRate",dynamics.m_UpdateRate}});
        }
        hairDynamics=dynamicsList.ToArray();
        File.WriteAllText(Path.Combine(folder,"dynamics.json"),J(new Dictionary<string,object>{{"schemaVersion",1},{"hairIDs",new[]{0,2}},{"components",components}}));
    }
    static object Read(object instance,string name){var field=instance.GetType().GetField(name,System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic);if(field==null)throw new Exception("Missing field "+name);return field.GetValue(instance);}
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
