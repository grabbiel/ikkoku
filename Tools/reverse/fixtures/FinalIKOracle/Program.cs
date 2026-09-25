using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using UnityEngine;
using RootMotion.FinalIK;
class Program {
 static Dictionary<long,Transform> nodes = new();
 static Vector3 V(JsonElement j)=>new(j[0].GetSingle(),j[1].GetSingle(),j[2].GetSingle());
 static Quaternion Q(JsonElement j)=>new(j[0].GetSingle(),j[1].GetSingle(),j[2].GetSingle(),j[3].GetSingle());
 static float[] A(Vector3 v)=>new[]{v.x,v.y,v.z};static float[] A(Quaternion q)=>new[]{q.x,q.y,q.z,q.w};
 static object Read(Type type,JsonElement j,object value=null){
  if(type==typeof(Transform))return j.GetProperty("m_PathID").GetInt64()==0?null:nodes[j.GetProperty("m_PathID").GetInt64()];
  if(type==typeof(float))return j.GetSingle();if(type==typeof(int))return j.GetInt32();if(type==typeof(bool))return j.ValueKind==JsonValueKind.Number?j.GetInt32()!=0:j.GetBoolean();if(type.IsEnum)return Enum.ToObject(type,j.GetInt32());
  if(type.IsArray){var a=Array.CreateInstance(type.GetElementType(),j.GetArrayLength());int i=0;foreach(var el in j.EnumerateArray())a.SetValue(Read(type.GetElementType(),el),i++);return a;}
  if(value==null){try{value=Activator.CreateInstance(type);}catch(MissingMethodException){value=RuntimeHelpers.GetUninitializedObject(type);}}
  foreach(var prop in j.EnumerateObject()){FieldInfo f=null;for(var t=type;t!=null&&f==null;t=t.BaseType)f=t.GetField(prop.Name,BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.DeclaredOnly);if(f!=null)f.SetValue(value,Read(f.FieldType,prop.Value,f.GetValue(value)));}
  return value;
 }
 static void Main(string[] args){
  var input=JsonDocument.Parse(File.ReadAllText(args[0])).RootElement;
  foreach(var n in input.GetProperty("nodes").EnumerateArray())nodes[n.GetProperty("id").GetInt64()]=new Transform{name=n.GetProperty("name").GetString(),localPosition=V(n.GetProperty("position")),localRotation=Q(n.GetProperty("rotation")),localScale=V(n.GetProperty("scale"))};
  foreach(var n in input.GetProperty("nodes").EnumerateArray()){long parent=n.GetProperty("parent").GetInt64();if(parent!=0&&nodes.ContainsKey(parent))nodes[n.GetProperty("id").GetInt64()].parent=nodes[parent];}
  var solver=(IKSolverFullBodyBiped)Read(typeof(IKSolverFullBodyBiped),input.GetProperty("solver"));
  solver.Initiate(solver.GetRoot());if(!solver.initiated)throw new Exception("Original solver did not initiate");
  foreach(var n in input.GetProperty("pose").EnumerateArray()){var t=nodes[n.GetProperty("id").GetInt64()];t.localPosition=V(n.GetProperty("position"));t.localRotation=Q(n.GetProperty("rotation"));t.localScale=V(n.GetProperty("scale"));}
  var active=input.GetProperty("active").EnumerateArray().Select(x=>x.GetBoolean()).ToArray();int[] groups={0,4,3,2,1,4,3,2,1};for(int i=0;i<9;i++){solver.effectors[i].positionWeight=active[groups[i]]?1:0;solver.effectors[i].rotationWeight=active[groups[i]]?1:0;}
  for(int i=0;i<4;i++){solver.limbMappings[i].weight=active[new[]{4,3,2,1}[i]]?1:0;solver.chain[i+1].bendConstraint.weight=1;}
  solver.spineMapping.twistWeight=active[0]?1:0;
  // Studio IKCtrl.InitTargetCoroutine -> IKInfo.CopyBone initializes separate
  // work targets from the sampled character, not prefab guide placeholders.
  var targetObjects=new Dictionary<long,Transform>();
  int[] effectorIDs={0,1,-1,5,2,-1,6,3,-1,7,4,-1,8};
  for(int i=0;i<13;i++){
   var original=effectorIDs[i]>=0?solver.effectors[effectorIDs[i]].target:solver.chain[(i+1)/3].bendConstraint.bendGoal;
   var bone=i==0?solver.spineMapping.spineBones[0]:effectorIDs[i]>=0?solver.effectors[effectorIDs[i]].bone:solver.chain[(i+1)/3].nodes[1].transform;
   var target=new Transform{name=original.name+"(work)",position=bone.position,rotation=new[]{3,6,9,12}.Contains(i)?bone.rotation:Quaternion.identity};
   targetObjects[nodes.First(n=>n.Value==original).Key]=target;
   if(effectorIDs[i]>=0)solver.effectors[effectorIDs[i]].target=target;else solver.chain[(i+1)/3].bendConstraint.bendGoal=target;
  }
  foreach(var n in input.GetProperty("targets").EnumerateArray()){var t=targetObjects[n.GetProperty("id").GetInt64()];if(n.TryGetProperty("offset",out var delta))t.position+=V(delta);if(n.TryGetProperty("position",out var pos))t.position=V(pos);if(n.TryGetProperty("rotation",out var rot))t.rotation=Q(rot);}
  var guides=Enumerable.Range(0,13).Select(i=>{var t=effectorIDs[i]>=0?solver.effectors[effectorIDs[i]].target:solver.chain[(i+1)/3].bendConstraint.bendGoal;return new{id=i,position=A(t.position),rotation=A(t.rotation)};}).ToArray();
  solver.Update();
  var output=nodes.Select(n=>new {id=n.Key,position=A(n.Value.localPosition),rotation=A(n.Value.localRotation),scale=A(n.Value.localScale),worldPosition=A(n.Value.position),worldRotation=A(n.Value.rotation)}).ToArray();
  File.WriteAllText(args[1],JsonSerializer.Serialize(new {nodes=output,guides,solverPositions=solver.chain.Select(c=>c.nodes.Select(n=>A(n.solverPosition)).ToArray()).ToArray()},new JsonSerializerOptions{WriteIndented=true}));
 }
}
