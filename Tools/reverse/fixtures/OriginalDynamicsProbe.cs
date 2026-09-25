// Numerical DynamicBone verification only; fresh fully clothed fixture, no media export.
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
    string folder; ChaControl character;
    IEnumerator Start() {
        folder=Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),"character");Directory.CreateDirectory(folder);
        for(int i=0;i<30;i++)yield return null;
        string error=null;
        try{CreateFixture();}catch(Exception e){error=e.ToString();}
        if(error==null){
            var load=character.LoadAsync(false,false);
            for(;;){bool more=false;object step=null;try{more=load.MoveNext();if(more)step=load.Current;}catch(Exception e){error=e.ToString();}if(error!=null||!more)break;yield return step;}
        }
        if(error==null){for(int i=0;i<10;i++)yield return null;try{Capture();}catch(Exception e){error=e.ToString();}}
        File.WriteAllText(Path.Combine(folder,"status.json"),J(new Dictionary<string,object>{{"error",error},{"unity",Application.unityVersion},{"scope","Numeric DynamicBone parameters and curves only; no source media"}}));Application.Quit();
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
        foreach(var dynamics in character.GetComponentsInChildren<DynamicBone>(true)) {
            if(dynamics.m_Root==null)continue;
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
