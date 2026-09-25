// Numerical Animator verification only; fresh fully clothed fixture, no media export.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using BepInEx;
using UnityEngine;
[BepInPlugin("org.ikkoku.validation.animationprobe", "Ikkoku animation probe", "1.0.0")]
public sealed class OriginalAnimationProbe:BaseUnityPlugin {
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
        File.WriteAllText(Path.Combine(folder,"status.json"),J(new Dictionary<string,object>{{"error",error},{"unity",Application.unityVersion},{"scope","Numeric Animator transforms only; no source media"}}));Application.Quit();
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
        character.SetClothesStateAll(0);character.fileStatus.visibleSon=false;character.fileStatus.visibleSonAlways=false;character.UpdateForce();
        foreach(int slot in new[]{0,1,7})if(character.objClothes[slot]==null||!character.objClothes[slot].activeInHierarchy)throw new Exception("Clothed fixture garment missing");
        foreach(var r in character.GetComponentsInChildren<Renderer>()){
            if(r.enabled&&r.name.IndexOf("dankon",StringComparison.OrdinalIgnoreCase)>=0)throw new Exception("Clothed fixture privacy guard");r.enabled=false;
        }
        Manager.Character.Instance.enabled=false;
        foreach(var b in character.GetComponentsInChildren<Behaviour>(true))b.enabled=false;
        var animator=character.animBody;
        var transforms=character.GetComponentsInChildren<Transform>(true);
        var initialPosition=new Vector3[transforms.Length];var initialRotation=new Quaternion[transforms.Length];var initialScale=new Vector3[transforms.Length];
        for(int i=0;i<transforms.Length;i++){initialPosition[i]=transforms[i].localPosition;initialRotation[i]=transforms[i].localRotation;initialScale[i]=transforms[i].localScale;}
        var cases=new List<object>();
        foreach(float height in new[]{.2f,.5f,.8f})foreach(string selection in new[]{"tpose:tpose","tachi:f_stand_00_00","adv:Stand_00_00","tachi:f_tachi_00_11","chair:f_suwari_00_14"}){
            var pieces=selection.Split(':');string controller=pieces[0],state=pieces[1];
            for(int i=0;i<transforms.Length;i++){transforms[i].localPosition=initialPosition[i];transforms[i].localRotation=initialRotation[i];transforms[i].localScale=initialScale[i];}
            character.SetShapeBodyValue(0,height);character.SetShapeBodyValue(1,height==.5f?.5f:.35f);character.UpdateShapeBody();
            var baseline=Bones(transforms,animator.transform);
            if(character.LoadAnimation("studio/anime/00.unity3d",controller,"")==null)throw new Exception("Controller missing "+controller);
            animator.enabled=true;animator.cullingMode=AnimatorCullingMode.AlwaysAnimate;
            foreach(float phase in new[]{0f,.25f,.5f,.875f})foreach(float speed in new[]{0f,.75f,1.5f}){
                for(int i=0;i<transforms.Length;i++){ // Restore source customization before each independent Animator sample.
                    var b=(Dictionary<string,object>)baseline[i];transforms[i].localPosition=(Vector3)b["_p"];transforms[i].localRotation=(Quaternion)b["_q"];transforms[i].localScale=(Vector3)b["_s"];
                }
                animator.speed=speed;animator.SetFloat("height",height);animator.Play(state,0,phase);animator.Update(0);
                if(speed>0)animator.Update(1f/60);
                var info=animator.GetCurrentAnimatorStateInfo(0);
                cases.Add(new Dictionary<string,object>{{"controller",controller},{"state",state},{"height",height},{"bodyValues",character.fileBody.shapeValueBody},{"inputNormalizedTime",phase},{"speed",speed},{"deltaTime",speed>0?1f/60:0},{"normalizedTime",info.normalizedTime},{"stateLength",info.length},{"stateSpeed",info.speed},{"loop",info.loop},{"animatorRoot",animator.transform.name},{"isHuman",animator.isHuman},{"baseline",Clean(baseline)},{"bones",Clean(Bones(transforms,animator.transform))}});
            }
            animator.enabled=false;
        }
        var textureProperties=new List<object>();foreach(var type in new[]{typeof(Texture),typeof(Texture2D)})foreach(var property in type.GetProperties(System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.NonPublic))if(property.Name.IndexOf("olor",StringComparison.OrdinalIgnoreCase)>=0||property.Name.IndexOf("inear",StringComparison.OrdinalIgnoreCase)>=0)textureProperties.Add(new Dictionary<string,object>{{"type",type.FullName},{"property",property.Name},{"propertyType",property.PropertyType.FullName}});
        File.WriteAllText(Path.Combine(folder,"animation.json"),J(new Dictionary<string,object>{{"schemaVersion",1},{"cases",cases},{"textureProperties",textureProperties}}));
    }
    List<object> Bones(Transform[] transforms,Transform root){
        var rows=new List<object>();foreach(var t in transforms){
            string path=t.name;var p=t.parent;while(p!=null&&t!=root&&p!=root){path=p.name+"/"+path;p=p.parent;}if(t==root)path="";
            rows.Add(new Dictionary<string,object>{{"name",t.name},{"path",path},{"underAnimator",t==root||t.IsChildOf(root)},{"position",V(t.localPosition)},{"rotation",Q(t.localRotation)},{"scale",V(t.localScale)},{"_p",t.localPosition},{"_q",t.localRotation},{"_s",t.localScale}});
        }return rows;
    }
    List<object> Clean(List<object> input){var rows=new List<object>();foreach(Dictionary<string,object> row in input){var d=new Dictionary<string,object>(row);d.Remove("_p");d.Remove("_q");d.Remove("_s");rows.Add(d);}return rows;}
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
