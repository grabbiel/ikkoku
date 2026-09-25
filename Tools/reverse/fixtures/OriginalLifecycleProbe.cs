// Inert components in a private validation player. No card, image or audio IO.
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using BepInEx;
using UnityEngine;

[BepInPlugin("org.ikkoku.validation.lifecycle", "Ikkoku lifecycle probe", "1.0.0")]
public sealed class OriginalLifecycleProbe : BaseUnityPlugin
{
    public static readonly List<string> Events = new List<string>();
    public static void Log(string message) { Events.Add(Time.frameCount + "\t" + Time.fixedTime.ToString("R", System.Globalization.CultureInfo.InvariantCulture) + "\t" + message); }
    IEnumerator Start() {
        for (int i=0;i<5;i++) yield return null;
        Time.fixedDeltaTime=.02f; Time.captureFramerate=30;
        var parent=new GameObject("original");parent.SetActive(false);
        var component=parent.AddComponent<LifecycleSubject>();
        component.publicValue=20; component.SetPrivate(30);
        Log("host:before-enable");parent.SetActive(true);Log("host:after-enable");
        for(int i=0;i<6;i++) yield return null;
        Log("host:before-reactivate");parent.SetActive(true);Log("host:after-reactivate");
        for(int i=0;i<3;i++) yield return null;
        Log("host:before-destroy-original");Destroy(parent);Log("host:after-destroy-original");
        for(int i=0;i<2;i++) yield return null;
        var folder=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        File.WriteAllLines(Path.Combine(folder,"lifecycle.tsv"),Events.ToArray());
        File.WriteAllText(Path.Combine(folder,"complete.txt"),Application.unityVersion);
        Application.Quit();
    }
}
public sealed class LifecycleSubject : MonoBehaviour
{
    public float publicValue=1;
    [SerializeField] float serializedValue=2;
    float privateValue=3;
    int updates;
    public void SetPrivate(float value) { privateValue=value;serializedValue=40; }
    void Log(string stage) { OriginalLifecycleProbe.Log(name+":"+stage+":"+publicValue+","+serializedValue+","+privateValue+","+updates); }
    void Awake(){Log("Awake");}
    void OnEnable(){Log("OnEnable");}
    void Start(){Log("Start");}
    void FixedUpdate(){Log("FixedUpdate");}
    void Update(){
        Log("Update.begin");updates++;
        if(name=="original" && updates==1){
            publicValue=21;serializedValue=41;privateValue=31;
            Log("before-Instantiate");var clone=Instantiate(gameObject);Log("after-Instantiate");
            Log("before-deactivate");gameObject.SetActive(false);Log("after-deactivate");
        } else if(name!="original" && updates==1){Log("before-Destroy");Destroy(gameObject);Log("after-Destroy");}
        Log("Update.end");
    }
    void LateUpdate(){Log("LateUpdate");}
    void OnDisable(){Log("OnDisable");}
    void OnDestroy(){Log("OnDestroy");}
}
