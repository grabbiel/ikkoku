// Independently implemented Unity surface for executing the installed FinalIK DLL.
// This is a numerical oracle host, not a replacement Unity runtime.
using System;
using Numerics = System.Numerics;
namespace UnityEngine;
public class Object { public string name {get;set;} = ""; public static implicit operator bool(Object o)=>o is not null; }
public class Component : Object { public Transform transform => this as Transform; public T GetComponent<T>() where T:class => null; }
public class Behaviour : Component { public bool enabled {get;set;} }
public class MonoBehaviour : Behaviour {}
[AttributeUsage(AttributeTargets.All)] public class SerializeField:Attribute {}
[AttributeUsage(AttributeTargets.All)] public class HideInInspector:Attribute {}
[AttributeUsage(AttributeTargets.All)] public class RangeAttribute:Attribute { public RangeAttribute(float a,float b){} }
[AttributeUsage(AttributeTargets.All)] public class TooltipAttribute:Attribute { public TooltipAttribute(string s){} }
[AttributeUsage(AttributeTargets.All)] public class AddComponentMenu:Attribute { public AddComponentMenu(string s){} }
[AttributeUsage(AttributeTargets.All)] public class HelpURLAttribute:Attribute { public HelpURLAttribute(string s){} }
public static class Application { public static bool isPlaying => false; }
public static class Debug { public static void LogError(object o,Object c)=>LogError(o); public static void LogError(object o)=>throw new InvalidOperationException(o.ToString()); public static void LogWarning(object o)=>Console.Error.WriteLine(o); public static void LogWarning(object o,Object c)=>Console.Error.WriteLine(o); public static void Log(object o)=>Console.Error.WriteLine(o); }
public struct Vector3 {
 public float x,y,z; public Vector3(float x,float y,float z){this.x=x;this.y=y;this.z=z;}
 public static Vector3 zero=>new(0,0,0);public static Vector3 one=>new(1,1,1);public static Vector3 right=>new(1,0,0);public static Vector3 up=>new(0,1,0);public static Vector3 forward=>new(0,0,1);public static Vector3 back=>new(0,0,-1);
 internal Numerics.Vector3 N=>new(x,y,z);internal static Vector3 From(Numerics.Vector3 v)=>new(v.X,v.Y,v.Z);
 public float sqrMagnitude=>x*x+y*y+z*z;public float magnitude=>MathF.Sqrt(sqrMagnitude);public Vector3 normalized=>magnitude>1e-5f?this/magnitude:zero;
 public void Normalize(){this=normalized;}public static Vector3 Normalize(Vector3 v)=>v.normalized;
 public static Vector3 operator +(Vector3 a,Vector3 b)=>new(a.x+b.x,a.y+b.y,a.z+b.z);public static Vector3 operator -(Vector3 a,Vector3 b)=>new(a.x-b.x,a.y-b.y,a.z-b.z);public static Vector3 operator -(Vector3 a)=>a*-1;
 public static Vector3 operator *(Vector3 a,float b)=>new(a.x*b,a.y*b,a.z*b);public static Vector3 operator *(float b,Vector3 a)=>a*b;public static Vector3 operator /(Vector3 a,float b)=>a*(1/b);
 public static bool operator ==(Vector3 a,Vector3 b)=>(a-b).sqrMagnitude<9.99999944e-11f;public static bool operator !=(Vector3 a,Vector3 b)=>!(a==b);public override bool Equals(object o)=>o is Vector3 v&&this==v;public override int GetHashCode()=>HashCode.Combine(x,y,z);
 public static float Dot(Vector3 a,Vector3 b)=>a.x*b.x+a.y*b.y+a.z*b.z; public static Vector3 Cross(Vector3 a,Vector3 b)=>new(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x);
 public static float Distance(Vector3 a,Vector3 b)=>(a-b).magnitude;public static Vector3 Lerp(Vector3 a,Vector3 b,float t)=>a+(b-a)*Mathf.Clamp01(t);public static Vector3 Scale(Vector3 a,Vector3 b)=>new(a.x*b.x,a.y*b.y,a.z*b.z);
 public static Vector3 Project(Vector3 v,Vector3 n)=>n.sqrMagnitude<float.Epsilon?zero:n*(Dot(v,n)/n.sqrMagnitude);
 public static float Angle(Vector3 a,Vector3 b){float d=MathF.Sqrt(a.sqrMagnitude*b.sqrMagnitude);return d<1e-15f?0:MathF.Acos(Math.Clamp(Dot(a,b)/d,-1,1))*57.29578f;}
 internal static Vector3 Perp(Vector3 n)=>MathF.Abs(n.z)>0.70710678f?new Vector3(0,-n.z,n.y).normalized:new Vector3(-n.y,n.x,0).normalized;
 public static void OrthoNormalize(ref Vector3 n,ref Vector3 t){n=n.magnitude>1e-5f?n.normalized:right;t-=n*Dot(n,t);t=t.magnitude>1e-5f?t.normalized:Perp(n);}
 public static Vector3 Slerp(Vector3 a,Vector3 b,float t){t=Mathf.Clamp01(t);float la=a.magnitude,lb=b.magnitude;if(la<1e-6f||lb<1e-6f)return Lerp(a,b,t);var an=a/la;var bn=b/lb;float dot=Math.Clamp(Dot(an,bn),-1,1);float angle=MathF.Acos(dot);Vector3 dir;if(dot>0.9995f)dir=Lerp(an,bn,t).normalized;else if(dot<-.9995f)dir=Quaternion.AngleAxis(angle*t*57.29578f,Perp(an))*an;else dir=(an*MathF.Sin((1-t)*angle)+bn*MathF.Sin(t*angle))/MathF.Sin(angle);return dir*(la+(lb-la)*t);}
}
public struct Quaternion {
 public float x,y,z,w;public Quaternion(float x,float y,float z,float w){this.x=x;this.y=y;this.z=z;this.w=w;}public void ToAngleAxis(out float angle,out Vector3 axis){var q=Numerics.Quaternion.Normalize(N);angle=2*MathF.Acos(Math.Clamp(q.W,-1,1))*57.29578f;float d=MathF.Sqrt(MathF.Max(0,1-q.W*q.W));axis=d<1e-6f?Vector3.right:new Vector3(q.X,q.Y,q.Z)/d;}public static Quaternion identity=>new(0,0,0,1);
 internal Numerics.Quaternion N=>new(x,y,z,w);internal static Quaternion From(Numerics.Quaternion q)=>new(q.X,q.Y,q.Z,q.W);public static Quaternion operator *(Quaternion a,Quaternion b)=>From(a.N*b.N);public static Vector3 operator *(Quaternion q,Vector3 v)=>Vector3.From(Numerics.Vector3.Transform(v.N,q.N));
 public static bool operator ==(Quaternion a,Quaternion b)=>Dot(a,b)>0.999999f;public static bool operator !=(Quaternion a,Quaternion b)=>!(a==b);public override bool Equals(object o)=>o is Quaternion q&&this==q;public override int GetHashCode()=>HashCode.Combine(x,y,z,w);
 public static float Dot(Quaternion a,Quaternion b)=>Numerics.Quaternion.Dot(a.N,b.N); public static Quaternion Inverse(Quaternion q)=>From(Numerics.Quaternion.Inverse(q.N));public static Quaternion Lerp(Quaternion a,Quaternion b,float t)=>From(Numerics.Quaternion.Lerp(a.N,b.N,Mathf.Clamp01(t)));public static Quaternion Slerp(Quaternion a,Quaternion b,float t)=>From(Numerics.Quaternion.Slerp(a.N,b.N,Mathf.Clamp01(t)));
 public static Quaternion AngleAxis(float a,Vector3 axis)=>axis.sqrMagnitude<1e-12f?identity:From(Numerics.Quaternion.CreateFromAxisAngle(axis.normalized.N,a/57.29578f));
 public static Quaternion FromToRotation(Vector3 a,Vector3 b){if(a.sqrMagnitude<1e-12f||b.sqrMagnitude<1e-12f)return identity;a=a.normalized;b=b.normalized;float d=Math.Clamp(Vector3.Dot(a,b),-1,1);if(d>.999999f)return identity;if(d<-.999999f)return AngleAxis(180,Vector3.Perp(a));var c=Vector3.Cross(a,b);return From(Numerics.Quaternion.Normalize(new(c.x,c.y,c.z,1+d)));}
 public static Quaternion LookRotation(Vector3 f,Vector3 u){if(f.sqrMagnitude<1e-12f)return identity;f=f.normalized;Vector3 r=Vector3.Cross(u,f).normalized;if(r.sqrMagnitude<1e-12f)return FromToRotation(Vector3.forward,f);u=Vector3.Cross(f,r);return From(Numerics.Quaternion.CreateFromRotationMatrix(new Numerics.Matrix4x4(r.x,r.y,r.z,0,u.x,u.y,u.z,0,f.x,f.y,f.z,0,0,0,0,1)));}
 public static Quaternion LookRotation(Vector3 f)=>LookRotation(f,Vector3.up);
}
public class Transform:Component {
 public Transform parent {get;set;} public Vector3 localPosition{get;set;} public Quaternion localRotation{get;set;}=Quaternion.identity; public Vector3 localScale{get;set;}=Vector3.one;
 internal Numerics.Matrix4x4 World=>Numerics.Matrix4x4.CreateScale(localScale.N)*Numerics.Matrix4x4.CreateFromQuaternion(localRotation.N)*Numerics.Matrix4x4.CreateTranslation(localPosition.N)*(parent?.World??Numerics.Matrix4x4.Identity);
 public Vector3 position {get=>Vector3.From(Numerics.Vector3.Transform(Numerics.Vector3.Zero,World));set=>localPosition=parent==null?value:parent.InverseTransformPoint(value);}
 public Quaternion rotation {get=>parent==null?localRotation:parent.rotation*localRotation;set=>localRotation=parent==null?value:Quaternion.Inverse(parent.rotation)*value;}
 public Vector3 up=>rotation*Vector3.up;public Vector3 forward=>rotation*Vector3.forward;public Vector3 right=>rotation*Vector3.right;
 public Vector3 TransformPoint(Vector3 v)=>Vector3.From(Numerics.Vector3.Transform(v.N,World));public Vector3 InverseTransformPoint(Vector3 v){if(!Numerics.Matrix4x4.Invert(World,out var inv))throw new Exception("Singular transform");return Vector3.From(Numerics.Vector3.Transform(v.N,inv));}
 public bool IsChildOf(Transform p){for(var t=this;t!=null;t=t.parent)if(t==p)return true;return false;}
}
public static class Mathf {
 public const float PI=MathF.PI,Deg2Rad=MathF.PI/180,Rad2Deg=180/MathF.PI,Infinity=float.PositiveInfinity;
 public static float Clamp(float a,float lo,float hi)=>Math.Clamp(a,lo,hi);public static int Clamp(int a,int lo,int hi)=>Math.Clamp(a,lo,hi);public static float Clamp01(float a)=>Math.Clamp(a,0,1);
 public static float Sqrt(float a)=>MathF.Sqrt(a);public static float Abs(float a)=>MathF.Abs(a);public static float Min(float a,float b)=>MathF.Min(a,b);public static float Max(float a,float b)=>MathF.Max(a,b);public static float Sin(float a)=>MathF.Sin(a);public static float Cos(float a)=>MathF.Cos(a);public static float Acos(float a)=>MathF.Acos(a);public static float Atan2(float a,float b)=>MathF.Atan2(a,b);public static float Pow(float a,float b)=>MathF.Pow(a,b);public static float Lerp(float a,float b,float t)=>a+(b-a)*Clamp01(t);public static float Sign(float a)=>a<0?-1:1;
 public static float Repeat(float t,float length)=>Clamp(t-MathF.Floor(t/length)*length,0,length);public static float DeltaAngle(float a,float b){float d=Repeat(b-a,360);return d>180?d-360:d;}
}
