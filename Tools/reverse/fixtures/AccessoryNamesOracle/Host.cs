using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
namespace UnityEngine {
    public class Object {
        public static bool operator ==(Object a,Object b) => ReferenceEquals(a,b);
        public static bool operator !=(Object a,Object b) => !ReferenceEquals(a,b);
        public override bool Equals(object o) => ReferenceEquals(this,o);
        public override int GetHashCode() => base.GetHashCode();
    }
    public struct Vector2 { public float x,y; public Vector2(float x,float y) { this.x=x;this.y=y; } }
    public struct Vector3 { public float x,y,z; public Vector3(float x,float y,float z) { this.x=x;this.y=y;this.z=z; } }
    public class Component:Object {
        public GameObject gameObject;
        public Transform transform => gameObject.transform;
        public T GetComponent<T>() where T:Component => gameObject.GetComponent<T>();
        public T GetComponentInChildren<T>() where T:Component => gameObject.GetComponent<T>();
        public T[] GetComponentsInChildren<T>() where T:Component => gameObject.components.OfType<T>().ToArray();
    }
    public class Transform:Component {
        public Vector3 localPosition;
        public List<Transform> children=new();
        public int childCount=>children.Count;
        public Transform GetChild(int i)=>children[i];
    }
    public class RectTransform:Component { public Vector2 offsetMax; }
    public class GameObject:Object {
        public static GameObject root;
        public bool activeSelf=true;
        public Transform transform;
        public List<Component> components=new();
        public GameObject() { transform=new Transform();Add(transform); }
        public T Add<T>(T c) where T:Component { c.gameObject=this;components.Add(c);return c; }
        public T GetComponent<T>() where T:Component => components.OfType<T>().FirstOrDefault();
        public static GameObject Find(string path)=>root;
    }
    public class MonoBehaviour:Component { public void StartCoroutine(IEnumerator r) {} }
}
namespace UnityEngine.UI { public class Button:UnityEngine.Component {} public class Text:UnityEngine.Component { public string text; } }
namespace BepInEx {
    public class BaseUnityPlugin:UnityEngine.MonoBehaviour {}
    public class BepInPlugin:Attribute { public BepInPlugin(string guid,string name,string version) {} }
    public class BepInProcess:Attribute { public BepInProcess(string name) {} }
}
namespace HarmonyLib { public class Harmony { public Harmony(string id) {} public void PatchAll(Type t) {} } }
namespace Studio { public class OCIChar { public object charInfo; } }
namespace KKAPI.Maker { public static class AccessoriesApi { public static Dictionary<int,UnityEngine.GameObject> accessories=new(); public static UnityEngine.GameObject GetAccessoryObject(object c,int i)=>accessories.GetValueOrDefault(i); } }
public class ChaAccessoryComponent:UnityEngine.Component {}
public class ListInfoComponent:UnityEngine.Component { public class Data { public string Name; } public Data data=new(); }
namespace KK_StudioAccessoryNames { public class Hooks {} }
