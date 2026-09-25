using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using UnityEngine;
using UnityEngine.UI;
class Program {
    static void Main(string[] args) {
        var input=JsonDocument.Parse(File.ReadAllText(args[0])).RootElement;
        var results=new List<object>();
        foreach(var item in input.GetProperty("cases").EnumerateArray()) {
            var root=GameObject.root=new GameObject();
            KKAPI.Maker.AccessoriesApi.accessories.Clear();
            foreach(var entry in item.GetProperty("names").EnumerateObject()) {
                var a=new GameObject();a.Add(new ChaAccessoryComponent());a.Add(new ListInfoComponent()).data.Name=entry.Value.GetString();
                KKAPI.Maker.AccessoriesApi.accessories[int.Parse(entry.Name)]=a;
            }
            foreach(var row in item.GetProperty("rows").EnumerateArray()) {
                var obj=new GameObject();obj.activeSelf=row.GetProperty("active").GetBoolean();root.transform.children.Add(obj.transform);
                foreach(var x in row.GetProperty("buttonX").EnumerateArray()) { var b=new GameObject();b.transform.localPosition=new Vector3(x.GetSingle(),3,4);obj.components.Add(b.Add(new Button())); }
                if(row.GetProperty("text").ValueKind!=JsonValueKind.Null) { obj.Add(new Text()).text=row.GetProperty("text").GetString();obj.Add(new RectTransform()).offsetMax=new Vector2(42,17); }
            }
            var coroutine=KK_StudioAccessoryNames.KK_StudioAccessoryNames.UpdateStudioLabelsDelayed(new Studio.OCIChar());
            bool deferred=coroutine.MoveNext() && coroutine.Current==null;
            var before=root.transform.children.Select(c=>c.GetComponent<Text>()?.text).ToArray();
            bool completed=!coroutine.MoveNext();
            var rows=root.transform.children.Select(c=>new {text=c.GetComponent<Text>()?.text,active=c.gameObject.activeSelf,buttonX=c.GetComponentsInChildren<Button>().Select(b=>b.transform.localPosition.x).ToArray(),offsetMaxX=c.GetComponent<RectTransform>()?.offsetMax.x}).ToArray();
            results.Add(new {name=item.GetProperty("name").GetString(),deferred,completed,before,rows});
        }
        File.WriteAllText(args[1],JsonSerializer.Serialize(results,new JsonSerializerOptions{WriteIndented=true}));
    }
}
