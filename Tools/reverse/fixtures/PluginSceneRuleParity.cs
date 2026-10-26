// Parity of PluginSceneRules.cs with the Swift writer: judges every case of the rule corpus that
// Tools/reverse/plugin_rule_parity.py converts from the Swift test sourceScenePluginDataWritesTheRuleParityCorpus,
// and counts the cases whose verdict (accepted or refused) or refused entry IDs differ. C# 5. The corpus text has
// one record per line, fields separated by single spaces, lists by commas ("-" for an empty list or no trailer):
//   scene <trailer hex>                     starts a scene
//   object <key> <kind> <parent key or -1>  the scene's walk, in order
//   used <keys>                             every key the scene's hashIndex holds
//   card <character key> <steps or !>       a character whose card names KKAnimationController data: the object
//                                           keys NodesConstraints' card fallback attaches to, in order, up to its
//                                           first certain abort ("!": the card does not decode)
//   case <scene> <delete|duplicate|add|routeAdd|routeDelete> <key> <object kind> <accepted|refused> <ids>
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
public static class PluginSceneRuleParity {
    public static List<PluginSceneModel> Scenes(string text,List<string[]> cases) {
        var scenes=new List<PluginSceneModel>();PluginSceneModel scene=null;
        foreach(var raw in text.Split('\n')) {
            var line=raw.Trim();if(line.Length==0)continue;
            var f=line.Split(' ');
            switch(f[0]) {
            case "scene":scene=new PluginSceneModel();scene.Trailer=f[1]=="-"?new byte[0]:Hex(f[1]);scenes.Add(scene);break;
            case "object":scene.Keys.Add(Int(f[1]));scene.Kinds.Add(Int(f[2]));scene.Parents.Add(Int(f[3]));break;
            case "used":foreach(var k in List(f[1]))scene.Used.Add(Int(k));break;
            case "card":{List<int> steps=null;if(f[2]!="!"){steps=new List<int>();foreach(var k in List(f[2]))steps.Add(Int(k));}scene.Cards[Int(f[1])]=steps;break;}
            case "case":cases.Add(f);break;
            default:throw new FormatException("unknown corpus line "+f[0]);
            }
        }
        return scenes;
    }
    // The mismatches, one line each; empty when every case agrees.
    public static List<string> Check(string text,out int count) {
        var cases=new List<string[]>();var scenes=Scenes(text,cases);var mismatches=new List<string>();count=cases.Count;
        foreach(var c in cases) {
            var scene=scenes[Int(c[1])];
            var verdict=PluginSceneRules.Judge(scene,new PluginSceneEdit(c[2],Int(c[3]),Int(c[4])));
            string expected=c[5]+" "+c[6],actual=(verdict.Refused?"refused":"accepted")+" "+(verdict.Ids.Count==0?"-":String.Join(",",verdict.Ids.ToArray()));
            if(expected!=actual)mismatches.Add("scene "+c[1]+" "+c[2]+" "+c[3]+" "+c[4]+": Swift "+expected+", C# "+actual+" ("+String.Join("; ",verdict.Reasons.ToArray())+")");
        }
        return mismatches;
    }
    static int Int(string s){return int.Parse(s,NumberStyles.Integer,CultureInfo.InvariantCulture);}
    static string[] List(string s){return s=="-"?new string[0]:s.Split(',');}
    static byte[] Hex(string s){var b=new byte[s.Length/2];for(int i=0;i<b.Length;i++)b[i]=Convert.ToByte(s.Substring(2*i,2),16);return b;}
}
#if PARITY_MAIN
public static class PluginSceneRuleParityMain {
    public static int Main(string[] args) {
        int count;var mismatches=PluginSceneRuleParity.Check(System.IO.File.ReadAllText(args[0]),out count);
        foreach(var m in mismatches)Console.WriteLine(m);
        Console.WriteLine("parity: "+count+" cases, "+mismatches.Count+" mismatches");
        return mismatches.Count==0?0:1;
    }
}
#endif
