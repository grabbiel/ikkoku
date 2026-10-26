// The plug-in (ExtendedSave) data rules of Packages/Engine/Sources/Studio/SourceScenePluginData.swift and
// SourceScenePluginRewrites.swift (KKPE, MaterialEditor and NodesConstraints rewrites), ported to C# 5 for the
// original player's csc, so the scene survey (original_plugin_scene_probe.py phase B, survey 2) judges
// installed scenes as the Swift writer would. It answers only whether an export is refused and which entries a
// refusal names; it writes nothing. The Swift test sourceScenePluginDataWritesTheRuleParityCorpus emits scenes and
// the Swift verdict of every single-target edit of them; Tools/reverse/plugin_rule_parity.py compiles this file
// with a harness and requires the same verdict and the same refused entry IDs for every case before a survey runs.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

// A scene as the rules read it: objects in CharaStudio's dicObject walk (each before its children, a character's
// accessory groups in ascending point order) with kind and parent key (-1 at the root), every key the scene's
// hashIndex holds (objects and sub-infos), for each character whose card names KKAnimationController data the
// object keys NodesConstraints' card fallback attaches to in order (CardSteps; null when the card does not decode),
// and the bytes after the scene's 【KStudio】 marker. For KKPE: every uniqueId and poseControllerId value in the
// scene file's bytes (KkpeIdsIn, KKPEPlan.ids), and for each character whose card holds KKPE data its controller ID
// and 1 when that data is in the card's current Extended Save block (0: the version 2 trailer); null when the card
// or its KKPE data does not read.
public sealed class PluginSceneModel {
    public readonly List<int> Keys=new List<int>(),Kinds=new List<int>(),Parents=new List<int>();
    public readonly HashSet<int> Used=new HashSet<int>();
    public readonly Dictionary<int,List<int>> Cards=new Dictionary<int,List<int>>();
    public readonly HashSet<int> KkpeIds=new HashSet<int>();
    public readonly Dictionary<int,int[]> KkpeCards=new Dictionary<int,int[]>();
    public byte[] Trailer=new byte[0];
}

// One edit: "delete" or "duplicate" an object (with its subtree), "add" a new object of kind Object at the root,
// or "routeAdd"/"routeDelete" a point of route Key.
public sealed class PluginSceneEdit {
    public readonly string Kind;public readonly int Key,Object;
    public PluginSceneEdit(string kind,int key,int obj){Kind=kind;Key=key;Object=obj;}
}

public sealed class PluginSceneVerdict {
    public bool Refused;
    public readonly List<string> Ids=new List<string>(),Reasons=new List<string>();
}

public static class PluginSceneRules {
    public const int Character=0,Item=1,Light=2,Folder=3,Route=4,Camera=5;
    public const string Sideloader="com.bepis.sideloader.universalautoresolver",Kkpe="kkpe",NodesConstraints="nodesConstraints",
        AnimationController="KK_AnimationController",MaterialEditor="com.deathweasel.bepinex.materialeditor",Timeline="timeline";
    public static readonly HashSet<string> Orphans=new HashSet<string>{"KKVMDPlayExtSave","rendererEditor","com.rskoi.particleeditor","vnge_kfa","vnge_sss"};
    static readonly Dictionary<string,long[]> SceneGlobal=new Dictionary<string,long[]>{
        {"com.deathweasel.bepinex.studioscenesettings",new long[]{0}},{"com.deathweasel.bepinex.studioimageembed",new long[]{0}},
        {"TwoLutPlugin",new long[]{0}},{"com.jim60105.kk.studiocharalightlinkedtocamera",new long[]{3}}};
    static readonly HashSet<string> MaterialKeys=new HashSet<string>{"TextureDictionary","RendererPropertyList","ProjectorPropertyList",
        "MaterialNamePropertyList","MaterialFloatPropertyList","MaterialKeywordPropertyList","MaterialColorPropertyList",
        "MaterialTexturePropertyList","MaterialShaderList","MaterialCopyList"};
    static readonly HashSet<string> RecordKeys=new HashSet<string>{"ModID","Slot","LocalSlot","SceneDicKey","SceneObjectOrder",
        "ResolveItem","Group","Category","Author","Website","Name"};
    static readonly HashSet<string> PatternKeys=new HashSet<string>{"SceneDicKey","SceneObjectOrder","ObjectPatternInfo"};
    static readonly HashSet<string> SceneKeys=MakeSceneKeys();
    static HashSet<string> MakeSceneKeys(){var s=new HashSet<string>();foreach(var g in new[]{"map","filter","ramp","bgm"})foreach(var f in new[]{"GUID","Author","Website","Name"})s.Add(g+"Info"+f);return s;}

    // KeyedForm: field readers are "none", "ints", "index" or "named:<key>".
    sealed class Rule {public readonly Dictionary<string,string> Fields;public readonly bool Copies,Lights;public readonly long[] Versions;
        public Rule(bool copies,bool lights,params string[] fields){Copies=copies;Lights=lights;Versions=new long[]{0};Fields=new Dictionary<string,string>();for(int i=0;i<fields.Length;i+=2)Fields[fields[i]]=fields[i+1];}}
    static readonly Dictionary<string,Rule> Keyed=new Dictionary<string,Rule>{
        {"com.deathweasel.bepinex.studiocustommasking",new Rule(true,false,"MaskingFolders","ints")},
        {"keelhauled.itemlayeredit",new Rule(true,false,"SavedLayers","named:ObjectId")},
        {"keelhauled.realpov",new Rule(false,false,"PovData","named:CharaId")},
        {"orange.spork.moarcamzplugin",new Rule(false,false,"MoarCamz","named:CenterTarget","MoarCamzInitial","named:CenterTarget","MoarCamzLastSelection","none")},
        {"BetterScalingData",new Rule(true,false,"BetterScalingData_scaledFoldersFlag","none","BetterScalingData_scaledOCI","ints")},
        {"LightSettingsData",new Rule(true,true,"LightSettingsData_lights","named:ObjectId","LightSettingsData_cookies","none")},
        {"org.njaecha.plugins.StudioItemIK",new Rule(true,false,"activeIKs","ints","objectTargetPairs","ints")},
        {"org.njaecha.plugins.objimport",new Rule(true,false,"version","none","meshes","none","ids","ints")},
        {"com.rikkibalboa.bepinex.savecameraobjectfov",new Rule(false,false,"cameras","ints","mainFov","none","previousCameraIndex","index","cameraIndex","index")}};

    // Whether the ID has a rule in this port (recovered or orphan); everything else is unknown.
    public static bool Known(string id){return Orphans.Contains(id)||SceneGlobal.ContainsKey(id)||Keyed.ContainsKey(id)||id==Sideloader||id==Kkpe||id==NodesConstraints||id==AnimationController||id==MaterialEditor||id==Timeline;}

    // MARK: Edit

    sealed class Edit {
        public readonly List<int> FinalKeys=new List<int>(),FinalKinds=new List<int>();
        public readonly Dictionary<int,int> Origins=new Dictionary<int,int>(),SourceKinds=new Dictionary<int,int>();
        public readonly HashSet<int> Deleted=new HashSet<int>(),Copied=new HashSet<int>();
        public bool Added,RoutePoints;
        readonly List<int> sourceKeys;
        public Edit(PluginSceneModel scene,PluginSceneEdit edit) {
            sourceKeys=scene.Keys;
            for(int i=0;i<scene.Keys.Count;i++)SourceKinds[scene.Keys[i]]=scene.Kinds[i];
            var subtree=new HashSet<int>();
            if(edit.Kind=="delete"||edit.Kind=="duplicate") {
                subtree.Add(edit.Key);
                for(int i=0;i<scene.Keys.Count;i++)if(subtree.Contains(scene.Parents[i]))subtree.Add(scene.Keys[i]); // parents precede children in the walk
            }
            for(int i=0;i<scene.Keys.Count;i++) {
                int key=scene.Keys[i];
                if(edit.Kind=="delete"&&subtree.Contains(key)){Deleted.Add(key);continue;}
                FinalKeys.Add(key);FinalKinds.Add(scene.Kinds[i]);Origins[key]=key;
            }
            if(edit.Kind=="duplicate") {
                int next=int.MaxValue/2; // copies' keys only need to be new
                for(int i=0;i<scene.Keys.Count;i++)if(subtree.Contains(scene.Keys[i])){int key=next++;FinalKeys.Add(key);FinalKinds.Add(scene.Kinds[i]);Origins[key]=scene.Keys[i];Copied.Add(scene.Keys[i]);}
            } else if(edit.Kind=="add") {
                int key=0;while(scene.Used.Contains(key))key++; // SceneInfo.GetNewIndex: the smallest free key
                FinalKeys.Add(key);FinalKinds.Add(edit.Object);Added=true;
            } else if(edit.Kind=="routeAdd"||edit.Kind=="routeDelete") {
                RoutePoints=true;
            } else if(edit.Kind!="delete") throw new ArgumentException("unknown edit "+edit.Kind);
        }
        public bool KeysChange{get{return Deleted.Count>0||Copied.Count>0||Added||RoutePoints;}}
        public bool Rekeys{get{return Deleted.Count>0||Copied.Count>0;}}
        public List<int> Sorted(IList<int> keys,Func<int,int> kind,int[] kinds) {
            var list=new List<int>();
            for(int i=0;i<keys.Count;i++)if(kinds==null||Array.IndexOf(kinds,kind(i))>=0)list.Add(keys[i]);
            list.Sort();return list;
        }
        public List<int> SourceSorted(int[] kinds){return Sorted(sourceKeys,i=>SourceKinds[sourceKeys[i]],kinds);}
        public List<int> FinalSorted(int[] kinds){return Sorted(FinalKeys,i=>FinalKinds[i],kinds);}
        // Copies in key order (copies' keys rise in walk order): {copy key, template key}.
        public List<int[]> Copies(int kind) {
            var list=new List<int[]>();
            for(int i=0;i<FinalKeys.Count;i++){if(kind>=0&&FinalKinds[i]!=kind)continue;int origin;if(Origins.TryGetValue(FinalKeys[i],out origin)&&origin!=FinalKeys[i])list.Add(new[]{FinalKeys[i],origin});}
            return list;
        }
        public bool Unchanged(params int[] kinds) {
            var a=SourceSorted(kinds);var b=FinalSorted(kinds);
            if(a.Count!=b.Count)return false;for(int i=0;i<a.Count;i++)if(a[i]!=b[i])return false;return true;
        }
        public bool PositionsKept{get{
            if(Copied.Count>0)return false;
            var a=SourceSorted(null);var b=FinalSorted(null);
            if(b.Count<a.Count)return false;for(int i=0;i<a.Count;i++)if(a[i]!=b[i])return false;return true;}}
        public bool Touches(HashSet<int> keys,bool copies) {
            foreach(var k in keys)if(Deleted.Contains(k)||(copies&&Copied.Contains(k)))return true;
            return false;
        }
        public bool LightAddedOrCopied() {
            for(int i=0;i<FinalKeys.Count;i++){if(FinalKinds[i]!=Light)continue;int origin;if(!Origins.TryGetValue(FinalKeys[i],out origin)||origin!=FinalKeys[i])return true;}
            return false;
        }
    }

    // MARK: Judge

    public static PluginSceneVerdict Judge(PluginSceneModel scene,PluginSceneEdit spec) {
        var verdict=new PluginSceneVerdict();
        var edit=new Edit(scene,spec);
        if(scene.Trailer==null||scene.Trailer.Length==0) {
            // No plug-in data, but NodesConstraints still reads the cards.
            string card=CardLinks(edit,scene,"empty");
            if(card!=null){verdict.Refused=true;verdict.Reasons.Add(card);}
            return verdict;
        }
        string error;var trailer=Parsed(scene.Trailer,out error);
        if(trailer==null){if(edit.KeysChange){verdict.Refused=true;verdict.Reasons.Add("unreadable trailer: "+error);}return verdict;}
        foreach(var entry in trailer.Entries) {
            if(entry.IsNil||Orphans.Contains(entry.Id))continue;
            string reason;
            try{reason=Decide(trailer,entry,edit,scene);}
            catch(Exception e){reason=edit.KeysChange?"has data this writer cannot read ("+e.Message+")":null;}
            if(reason!=null){verdict.Ids.Add(entry.Id);verdict.Reasons.Add(entry.Id+" "+reason);}
        }
        // The card check names nodesConstraints, an entry ID only when the scene has that entry.
        string cardReason=CardLinks(edit,scene,SceneControllerForm(trailer));
        if(cardReason!=null) {
            verdict.Reasons.Add(NodesConstraints+" "+cardReason);
            bool present=false;foreach(var entry in trailer.Entries)if(entry.Id==NodesConstraints)present=true;
            if(present&&!verdict.Ids.Contains(NodesConstraints))verdict.Ids.Add(NodesConstraints);
        }
        verdict.Ids.Sort(StringComparer.Ordinal);
        verdict.Refused=verdict.Ids.Count>0||cardReason!=null;
        return verdict;
    }

    // The last trailer parsed, by reference: a survey judges every edit of one scene against the same bytes.
    static byte[] cachedBytes;static Trailer cachedTrailer;static string cachedError;
    static Trailer Parsed(byte[] bytes,out string error) {
        if(!ReferenceEquals(bytes,cachedBytes)) {
            cachedBytes=bytes;cachedTrailer=null;cachedError=null;
            try{cachedTrailer=Trailer.Parse(bytes);}catch(Exception e){cachedError=e.Message;}
        }
        error=cachedError;return cachedTrailer;
    }

    // Each entry's form, for the survey's counts (not a verdict): {ID, form, shape}. The shape (PluginData version
    // and data keys) is given for orphan entries only. Throws when the trailer does not parse.
    public static List<string[]> Forms(byte[] bytes) {
        string error;var trailer=Parsed(bytes,out error);
        if(trailer==null)throw new FormatException(error);
        var result=new List<string[]>();
        foreach(var entry in trailer.Entries) {
            string form,shape="";
            try{form=Form(trailer,entry);}catch(Exception){form="unreadable";}
            if(Orphans.Contains(entry.Id)&&!entry.IsNil) {
                try {
                    var keys=new List<string>();var fields=entry.HasVersion?trailer.Fields(entry):null;
                    if(fields!=null)foreach(var f in fields)keys.Add(f.Key);
                    keys.Sort(StringComparer.Ordinal);
                    shape=(entry.HasVersion?"v"+entry.Version:"shapeless")+":"+String.Join(",",keys.ToArray());
                } catch(Exception){shape="unreadable";}
            }
            result.Add(new[]{entry.Id,form,shape});
        }
        return result;
    }

    static string Form(Trailer trailer,Entry entry) {
        if(entry.IsNil)return "nil";
        if(Orphans.Contains(entry.Id))return "orphan";
        if(!entry.HasVersion)return "shapeless";
        long version=entry.Version;long[] globals;
        if(SceneGlobal.TryGetValue(entry.Id,out globals))return Array.IndexOf(globals,version)>=0?"global":"unknownVersion";
        switch(entry.Id) {
        case Sideloader:return version==0?"records":"unknownVersion";
        case Timeline: {
            if(version!=0)return "unknownVersion";
            string xml=SingleString(trailer,entry,"sceneInfo");
            return xml==null?"unknown":xml.IndexOf("objectIndex",StringComparison.Ordinal)>=0?"objectIndex":"global";}
        case Kkpe:return version==0?"perItem":"unknownVersion";
        case MaterialEditor:return version!=0&&version!=1?"unknownVersion":AllNil(trailer,entry,MaterialKeys)?"allNil":"itemKeyed";
        case NodesConstraints: {
            if(version!=0)return "unknownVersion";
            string xml=SingleString(trailer,entry,"constraints");
            return xml!=null&&ConstraintsEmpty(xml)?"empty":"constraints";}
        case AnimationController:return version!=0?"unknownVersion":ControllerForm(trailer,entry);
        default: {
            Rule rule;if(!Keyed.TryGetValue(entry.Id,out rule))return "unknown";
            if(Array.IndexOf(rule.Versions,version)<0)return "unknownVersion";
            HashSet<int> keys;bool positional;
            if(!References(trailer,entry,rule,out keys,out positional))return "unknown";
            return positional?"positional":keys.Count>0?"references":"noReferences";}
        }
    }

    static string Decide(Trailer trailer,Entry entry,Edit edit,PluginSceneModel scene) {
        string unknown=edit.KeysChange?"has no rule in this writer":null;
        if(!entry.HasVersion)return edit.KeysChange?"is not a [version, data] PluginData value":null;
        long version=entry.Version;
        string unknownVersion=edit.KeysChange?"has version "+version+", which this writer has not recovered":null;
        long[] globals;
        if(SceneGlobal.TryGetValue(entry.Id,out globals))return Array.IndexOf(globals,version)>=0?null:unknownVersion;
        switch(entry.Id) {
        case Sideloader:
            if(version!=0)return unknownVersion;
            try{CheckSideloader(trailer,entry,edit);}catch(SideloaderFailure failure){return edit.KeysChange?failure.Message:null;}
            return null;
        case Timeline: {
            if(version!=0)return unknownVersion;
            string xml=SingleString(trailer,entry,"sceneInfo");
            if(xml==null)return unknown;
            if(xml.IndexOf("objectIndex",StringComparison.Ordinal)<0||edit.PositionsKept)return null;
            return "addresses objects by index";}
        case Kkpe:
            if(version!=0)return unknownVersion;
            if(edit.Unchanged(Item)&&!edit.Touches(new HashSet<int>(edit.SourceSorted(new[]{Character})),true))return null;
            try{CheckKkpe(trailer,entry,edit,scene);}catch(RuleFailure failure){return edit.KeysChange?failure.Message:null;}
            return null;
        case MaterialEditor:
            if(version!=0&&version!=1)return unknownVersion;
            if(AllNil(trailer,entry,MaterialKeys)||edit.Unchanged(Item))return null;
            try{CheckMaterial(trailer,entry,edit,version);}catch(RuleFailure failure){return failure.Message;}
            return null;
        case NodesConstraints: {
            if(version!=0)return unknownVersion;
            string xml=SingleString(trailer,entry,"constraints");
            if(xml!=null&&ConstraintsEmpty(xml))return null;
            if(edit.PositionsKept)return null;
            try{CheckConstraints(trailer,entry,edit);}catch(RuleFailure failure){return failure.Message;}
            return null;}
        case AnimationController:
            if(version!=0)return unknownVersion;
            switch(ControllerForm(trailer,entry)) {
            case "empty":case "emptyList":return null; // CardLinks reads the cards
            case "links":return edit.Rekeys?"links characters to objects by key":null;
            default:return unknown;
            }
        default: {
            Rule rule;if(!Keyed.TryGetValue(entry.Id,out rule))return unknown;
            if(Array.IndexOf(rule.Versions,version)<0)return unknownVersion;
            HashSet<int> keys;bool positional;
            if(!References(trailer,entry,rule,out keys,out positional))return unknown;
            if(edit.Touches(keys,rule.Copies))return "names objects by key";
            if(rule.Lights&&edit.LightAddedOrCopied())return "writes a record for every light";
            if(positional&&!edit.Unchanged(Camera))return "selects a camera by position";
            return null;}
        }
    }

    // NodesConstraints.OnSceneLoad's card fallback (SourceScenePluginData.cardLinks): with no AnimationInfo in the
    // scene's KK_AnimationController entry, each card's KKAnimationController links attach on every load, with or
    // without plug-in data, until the first throw. Steps are live while their keys are source objects. An edit
    // refuses when it deletes a live target, copies a linked character together with a live target, or both deletes
    // and copies (#278) in a scene with any steps; a card that does not decode refuses.
    static string CardLinks(Edit edit,PluginSceneModel scene,string controller) {
        if(!edit.Rekeys||controller!="empty")return null;
        HashSet<int> objects=null;
        for(int i=0;i<edit.FinalKeys.Count;i++) {
            if(edit.FinalKinds[i]!=Character)continue;
            int key=edit.FinalKeys[i],origin;List<int> steps;
            if(!edit.Origins.TryGetValue(key,out origin)||!scene.Cards.TryGetValue(origin,out steps))continue;
            if(steps==null)return "cannot check character "+origin+"'s card links, which do not decode";
            if(steps.Count==0)continue;
            if(edit.Deleted.Count>0&&edit.Copied.Count>0)return "links character "+origin+" to objects by key from its card, and this edit both deletes and copies objects";
            if(objects==null)objects=new HashSet<int>(scene.Keys);
            var live=new List<int>();foreach(var s in steps){if(!objects.Contains(s))break;live.Add(s);}
            foreach(var s in live)if(edit.Deleted.Contains(s))return "links character "+origin+" to object "+s+" from its card, and this edit deletes that object";
            if(origin!=key)foreach(var s in live)if(edit.Copied.Contains(s))return "links character "+origin+" to object "+s+" from its card, and this edit copies both";
        }
        return null;
    }

    // The card rule alone, for the survey's counts: its reason, or null when it does not refuse the edit.
    public static string CardReason(PluginSceneModel scene,PluginSceneEdit spec) {
        string controller="empty";
        if(scene.Trailer!=null&&scene.Trailer.Length>0) {
            string error;var trailer=Parsed(scene.Trailer,out error);
            if(trailer==null)return null;   // an unreadable trailer refuses on its own
            controller=SceneControllerForm(trailer);
        }
        return CardLinks(new Edit(scene,spec),scene,controller);
    }

    // The scene's KK_AnimationController form: its first entry's, "empty" when absent, "unknown" when unreadable
    // (that entry refuses on its own).
    static string SceneControllerForm(Trailer trailer) {
        foreach(var e in trailer.Entries) {
            if(e.Id!=AnimationController)continue;
            try{return ControllerForm(trailer,e);}catch(Exception){return "unknown";}
        }
        return "empty";
    }

    static string ControllerForm(Trailer trailer,Entry entry) {
        if(entry.IsNil)return "empty";
        if(!entry.HasVersion||entry.Version!=0||entry.DataStart<0)return "unknown";
        var fields=trailer.Fields(entry);
        if(fields==null||fields.Count==0)return "empty";
        if(fields.Count!=1||fields[0].Key!="AnimationInfo")return "unknown";
        var c=new Spans(trailer.Bytes,fields[0].ValueStart,fields[0].ValueEnd);var head=c.Head();
        if(head.Type!=MPHead.Array)return "unknown";
        return head.Count==0?"emptyList":"links";
    }

    static string SingleString(Trailer trailer,Entry entry,string key) {
        var fields=trailer.Fields(entry);
        if(fields==null||fields.Count!=1||fields[0].Key!=key)return null;
        var c=new Spans(trailer.Bytes,fields[0].ValueStart,fields[0].ValueEnd);
        if(c.Peek().Type!=MPHead.String)return null;
        return c.String();
    }

    static bool AllNil(Trailer trailer,Entry entry,HashSet<string> keys) {
        var fields=trailer.Fields(entry);if(fields==null)return true;
        foreach(var f in fields){if(!keys.Contains(f.Key))return false;var c=new Spans(trailer.Bytes,f.ValueStart,f.ValueEnd);if(c.Head().Type!=MPHead.Nil)return false;}
        return true;
    }

    static readonly Regex Attributes=new Regex("^(\\s+[A-Za-z_][A-Za-z0-9_.-]*\\s*=\\s*\"[^\"<>]*\")*\\s*$",RegexOptions.CultureInvariant);
    public static bool ConstraintsEmpty(string xml) {
        string text=xml.Trim();
        if(!text.StartsWith("<constraints",StringComparison.Ordinal)||text.IndexOf("<constraint ",StringComparison.Ordinal)>=0||text.IndexOf("<constraint>",StringComparison.Ordinal)>=0)return false;
        text=text.Substring("<constraints".Length);
        int close=text.IndexOf('>');if(close<0)return false;
        string attributes=text.Substring(0,close),rest=text.Substring(close+1);
        if(attributes.EndsWith("/",StringComparison.Ordinal)){if(rest.Length!=0)return false;attributes=attributes.Substring(0,attributes.Length-1);}
        else if(rest.Trim()!="</constraints>")return false;
        return Attributes.IsMatch(attributes);
    }

    static bool References(Trailer trailer,Entry entry,Rule rule,out HashSet<int> keys,out bool positional) {
        keys=new HashSet<int>();positional=false;
        var fields=trailer.Fields(entry);if(fields==null)return true;
        foreach(var f in fields) {
            string reader;if(!rule.Fields.TryGetValue(f.Key,out reader))return false;
            var c=new Spans(trailer.Bytes,f.ValueStart,f.ValueEnd);var head=c.Head();
            if(head.Type==MPHead.Nil)continue;
            if(reader=="none")continue;
            if(reader=="index"){if(!head.IsInteger)return false;if(head.Integer!=0)positional=true;continue;}
            if(head.Type!=MPHead.Binary)return false;
            int start=c.Payload((int)head.Count);
            Value value;
            try{value=Value.Decode(trailer.Bytes,start,(int)head.Count);}catch(Exception){return false;}
            var found=new List<long>();Collect(value,reader,found);
            foreach(var n in found)if(n>=int.MinValue&&n<=int.MaxValue)keys.Add((int)n);
        }
        return true;
    }

    static void Collect(Value v,string reader,List<long> found) {
        switch(v.Type) {
        case Value.TInt:if(reader=="ints")found.Add(v.Integer);break;
        case Value.TUInt:if(reader=="ints"&&v.Unsigned<=(ulong)long.MaxValue)found.Add((long)v.Unsigned);break;
        case Value.TArray:foreach(var x in v.Items)Collect(x,reader,found);break;
        case Value.TMap:
            for(int i=0;i<v.Items.Count;i+=2) {
                var k=v.Items[i];var x=v.Items[i+1];
                if(reader.StartsWith("named:",StringComparison.Ordinal)&&k.Type==Value.TStr&&k.Text==reader.Substring(6)) {
                    if(x.Type==Value.TInt)found.Add(x.Integer);
                    else if(x.Type==Value.TUInt&&x.Unsigned<=(ulong)long.MaxValue)found.Add((long)x.Unsigned);
                }
                Collect(k,reader,found);Collect(x,reader,found);
            }
            break;
        }
    }


    // MARK: Rewrites (SourceScenePluginRewrites.swift)

    // A rule's refusal (RuleFailure in Swift); its message is the reason.
    sealed class RuleFailure:Exception{public RuleFailure(string m):base(m){}}

    // KKPEPlan: one itemInfo per item in key order, loaded by position; controller IDs (uniqueId) that lone colliders
    // name (poseControllerId). Deletes drop elements and references; copies take their template's element under a
    // fresh ID; a copied character's card ID is patched in its current Extended Save block.
    static readonly HashSet<string> KkpeReferences=new HashSet<string>{"dynamicBoneData","dynamicBoneData2","ignoredDynamicBone","ignoredDynamicBone2"};
    static void CheckKkpe(Trailer trailer,Entry entry,Edit edit,PluginSceneModel scene) {
        var sourceItems=edit.SourceSorted(new[]{Item});var sourceCharacters=edit.SourceSorted(new[]{Character});
        for(int i=0;i<edit.FinalKeys.Count;i++)if(edit.FinalKinds[i]==Item&&!edit.Origins.ContainsKey(edit.FinalKeys[i]))throw new RuleFailure("adds an item");
        var copies=new List<int[]>();
        foreach(var c in edit.Copies(-1)){int kind=edit.SourceKinds[c[1]];if(kind==Item||kind==Character)copies.Add(c);}
        var deletedItems=new List<int>();foreach(var k in sourceItems)if(edit.Deleted.Contains(k))deletedItems.Add(k);
        var deletedCharacters=new List<int>();foreach(var k in sourceCharacters)if(edit.Deleted.Contains(k))deletedCharacters.Add(k);
        bool itemCopied=false;foreach(var c in copies)if(edit.SourceKinds[c[1]]==Item)itemCopied=true;
        var xml=XmlBytes(trailer,entry,"sceneInfo");
        if(xml==null)throw new RuleFailure("has data other than one 'sceneInfo' XML string");
        bool names=IndexOf(xml,Ascii("poseControllerId"),0)>=0;
        var used=new HashSet<int>(scene.KkpeIds);
        if(deletedItems.Count==0&&!itemCopied&&(!names||(deletedCharacters.Count==0&&copies.Count==0))) {
            foreach(var c in copies)KkpeCharacterCopy(c,scene,used,new HashSet<int>());
            return;
        }
        Xml doc;
        try{doc=new Xml(xml);}catch(FormatException e){throw new RuleFailure("has pose data not in the XML form KKPE writes ("+e.Message+")");}
        if(doc.Elements[0].Name!="root"||doc.Attribute(0,"version")<0)throw new RuleFailure("has pose data whose root is not KKPE's <root version=...>");
        var elements=doc.Elements[0].Children;
        foreach(var e in elements)if(doc.Elements[e].Name!="itemInfo")throw new RuleFailure("has pose data with an element other than itemInfo under its root");
        if(elements.Count!=sourceItems.Count)throw new RuleFailure("has "+elements.Count+" item pose entries for "+sourceItems.Count+" items");
        var idOf=new Dictionary<int,int>();
        for(int i=0;i<elements.Count;i++) {
            int index,id;
            try {
                if(!doc.Integer(elements[i],"index",out index)||index!=sourceItems[i])throw new RuleFailure("has an item pose entry whose index is not item "+sourceItems[i]);
                if(!doc.Integer(elements[i],"uniqueId",out id)||id==0)throw new RuleFailure("has the pose entry of item "+sourceItems[i]+" without a controller ID");
            } catch(FormatException e){throw new RuleFailure("has pose data KKPE does not write ("+e.Message+")");}
            idOf[sourceItems[i]]=id;
        }
        var referenced=new HashSet<int>();
        for(int i=0;i<doc.Elements.Count;i++) {
            if(!KkpeReferences.Contains(doc.Elements[i].Name))continue;
            int id;bool present;
            try{present=doc.Integer(i,"poseControllerId",out id);}catch(FormatException){present=false;id=0;}
            if(!present||id==0)throw new RuleFailure("has a dynamic bone reference without a canonical non-zero poseControllerId");
            referenced.Add(id);
        }
        foreach(var id in idOf.Values)used.Add(id);foreach(var id in referenced)used.Add(id);
        var removed=new HashSet<int>();foreach(var k in deletedItems)removed.Add(idOf[k]);
        if(referenced.Count>0) {
            foreach(var k in deletedCharacters){var card=KkpeCard(scene,k);if(card!=null)removed.Add(card[0]);}
            var dropped=new List<int>();foreach(var id in removed)if(referenced.Contains(id))dropped.Add(id);
            if(dropped.Count>0) {
                var owners=new Dictionary<int,int>();
                foreach(var id in idOf.Values)Bump(owners,id);
                foreach(var k in sourceCharacters){var card=KkpeCard(scene,k);if(card!=null)Bump(owners,card[0]);}
                foreach(var id in dropped)if(owners[id]>1)throw new RuleFailure("names the dynamic bones of controller "+id+", an ID more than one object has");
            }
        }
        if(edit.Deleted.Count>0&&itemCopied)throw new RuleFailure("both deletes objects and copies items, so the copies' keys can differ from CharaStudio's");
        foreach(var c in copies) {
            if(edit.SourceKinds[c[1]]==Item)KkpeFresh(idOf[c[1]],c[1],used,referenced);
            else KkpeCharacterCopy(c,scene,used,referenced);
        }
    }
    static void Bump(Dictionary<int,int> counts,int key){int n;counts.TryGetValue(key,out n);counts[key]=n+1;}
    // A copied character's card patch: a fresh ID for its template's controller, in the current block only.
    static void KkpeCharacterCopy(int[] copy,PluginSceneModel scene,HashSet<int> used,HashSet<int> referenced) {
        var card=KkpeCard(scene,copy[1]);if(card==null)return;
        KkpeFresh(card[0],copy[1],used,referenced);
        if(card[1]==0)throw new RuleFailure("keeps character "+copy[1]+"'s pose data in a card whose Extended Save is not the current block");
    }
    static int[] KkpeCard(PluginSceneModel scene,int key) {
        int[] card;if(!scene.KkpeCards.TryGetValue(key,out card))return null;
        if(card==null)throw new RuleFailure("cannot read character "+key+"'s KKPE card data");
        return card;
    }
    static void KkpeFresh(int template,int key,HashSet<int> used,HashSet<int> referenced) {
        if(referenced.Contains(template))throw new RuleFailure("registers a copy's dynamic bones with every lone collider, and a lone collider names those of object "+key);
        int fresh;if(!FreshId(template,used,out fresh))throw new RuleFailure("has no free controller ID of the length of "+template+" for the copy of object "+key);
        used.Add(fresh);
    }
    // KKPEPlan.freshID: the template's digit count and sign, magnitudes above it up to the largest of that length,
    // then below it; never 0 or a used ID.
    public static bool FreshId(int template,HashSet<int> used,out int fresh) {
        bool negative=template<0;
        ulong magnitude=negative?(ulong)(-(long)template):(ulong)template;
        int digits=magnitude.ToString(CultureInfo.InvariantCulture).Length;
        ulong power=1;for(int i=0;i<digits;i++)power*=10;
        ulong low=digits==1?1UL:power/10,high=Math.Min(power-1,negative?2147483648UL:(ulong)int.MaxValue);
        ulong candidate=magnitude;
        while(candidate<high){candidate++;if(FreshValue(candidate,negative,used,out fresh))return true;}
        candidate=magnitude;
        while(candidate>low){candidate--;if(FreshValue(candidate,negative,used,out fresh))return true;}
        fresh=0;return false;
    }
    static bool FreshValue(ulong candidate,bool negative,HashSet<int> used,out int value) {
        long signed=negative?-(long)candidate:(long)candidate;value=0;
        if(signed<int.MinValue||signed>int.MaxValue)return false;
        value=(int)signed;return !used.Contains(value);
    }
    // KKPEPlan.ids: every uniqueId="..." and poseControllerId="..." value in a scene file's bytes.
    public static void KkpeIdsIn(byte[] data,HashSet<int> result) {
        foreach(var marker in new[]{Ascii("uniqueId=\""),Ascii("poseControllerId=\"")}) {
            int start=0,found;
            while((found=IndexOf(data,marker,start))>=0) {
                int valueStart=found+marker.Length,end=valueStart,value;
                while(end<data.Length&&data[end]!=0x22&&end-valueStart<=11)end++;
                if(end<data.Length&&data[end]==0x22&&Int32Text(data,valueStart,end,out value))result.Add(value);
                start=valueStart;
            }
        }
    }
    // KKPE's characterInfo in a card (KKPEPlan.card): its root's canonical non-zero uniqueId; false when the XML is
    // not KKPE's form.
    public static bool KkpeCardId(string xml,out int id) {
        id=0;
        try {
            var doc=new Xml(Encoding.UTF8.GetBytes(xml));
            return doc.Elements[0].Name=="characterInfo"&&doc.Integer(0,"uniqueId",out id)&&id!=0;
        } catch(FormatException){return false;}
    }

    // MaterialEditorPlan: record lists keyed by item (ID), textures purged when no kept record uses them.
    static readonly Dictionary<string,HashSet<string>> MaterialLists=MakeMaterialLists();
    static Dictionary<string,HashSet<string>> MakeMaterialLists() {
        var property=new[]{"ID","MaterialName","Property","Value","ValueOriginal"};
        var d=new Dictionary<string,HashSet<string>>();
        d["RendererPropertyList"]=new HashSet<string>{"ID","RendererName","Property","Value","ValueOriginal"};
        d["ProjectorPropertyList"]=new HashSet<string>{"ID","ProjectorName","Property","Value","ValueOriginal"};
        d["MaterialNamePropertyList"]=new HashSet<string>{"ID","Renderer","MaterialName","Value","ValueOriginal"};
        foreach(var n in new[]{"MaterialFloatPropertyList","MaterialKeywordPropertyList","MaterialColorPropertyList"})d[n]=new HashSet<string>(property);
        d["MaterialTexturePropertyList"]=new HashSet<string>{"ID","MaterialName","Property","TexID","Offset","OffsetOriginal","Scale","ScaleOriginal","TexAnimationDef"};
        d["MaterialShaderList"]=new HashSet<string>{"ID","MaterialName","ShaderName","ShaderNameOriginal","RenderQueue","RenderQueueOriginal"};
        d["MaterialCopyList"]=new HashSet<string>{"ID","MaterialName","MaterialCopyName"};
        return d;
    }
    sealed class MaterialRecord{public int Id;public readonly List<int> Textures=new List<int>();}
    static void CheckMaterial(Trailer trailer,Entry entry,Edit edit,long version) {
        var fields=trailer.Fields(entry);if(fields==null)return;
        var lists=new Dictionary<string,List<MaterialRecord>>();List<int> textures=null;
        foreach(var f in fields) {
            if(f.Key!="TextureDictionary"&&!MaterialLists.ContainsKey(f.Key))throw new RuleFailure("has a data key '"+f.Key+"' this writer does not read");
            var c=new Spans(trailer.Bytes,f.ValueStart,f.ValueEnd);var h=c.Head();
            if(h.Type==MPHead.Nil)continue;
            if(h.Type!=MPHead.Binary)throw new RuleFailure("has a '"+f.Key+"' value that is not serialized bytes");
            int start=c.Payload((int)h.Count),end=start+(int)h.Count;
            if(f.Key=="TextureDictionary")textures=MaterialTextures(trailer.Bytes,start,end);
            else lists[f.Key]=MaterialRecords(trailer.Bytes,start,end,f.Key);
        }
        var sourceItems=new HashSet<int>(edit.SourceSorted(new[]{Item}));
        var copies=edit.Copies(Item);
        var named=new HashSet<int>();foreach(var l in lists.Values)foreach(var r in l)named.Add(r.Id);
        bool stale=false,deleted=false,copied=false;
        foreach(var id in named){if(!sourceItems.Contains(id))stale=true;if(edit.Deleted.Contains(id))deleted=true;}
        foreach(var c in copies)if(named.Contains(c[1]))copied=true;
        if(!(deleted||copied||(stale&&copies.Count>0)))return;
        if(version!=1)throw new RuleFailure("has version "+version+" data, which CharaStudio's save rewrites in its version 1 form");
        if(edit.Deleted.Count>0&&copied)throw new RuleFailure("both deletes objects and copies items with material edits");
        if(textures==null)return;
        var usedTextures=new HashSet<int>();List<MaterialRecord> records;
        if(lists.TryGetValue("MaterialTexturePropertyList",out records))
            foreach(var r in records)if(sourceItems.Contains(r.Id)&&!edit.Deleted.Contains(r.Id))foreach(var t in r.Textures)usedTextures.Add(t);
        bool purge=false;foreach(var t in textures)if(!usedTextures.Contains(t))purge=true;
        if(purge&&TimelineMentions(trailer,"textureProperty"))throw new RuleFailure("purges textures no item uses except those Timeline's texture tracks use");
    }
    static bool Int32Head(MPHead h){return h.IsInteger&&h.Integer>=int.MinValue&&h.Integer<=int.MaxValue;}
    static List<int> MaterialTextures(byte[] bytes,int start,int end) {
        var malformed=new RuleFailure("has a TextureDictionary that is not MaterialEditor's Bundled int-to-bytes map");
        var c=new Spans(bytes,start,end);var h=c.Head();if(h.Type!=MPHead.Map)throw malformed;
        var keys=new HashSet<int>();var result=new List<int>();
        for(long i=0;i<h.Count;i++) {
            var k=c.Head();if(!Int32Head(k)||!keys.Add((int)k.Integer))throw malformed;
            var v=c.Head();if(v.Type!=MPHead.Binary)throw malformed;
            c.Payload((int)v.Count);result.Add((int)k.Integer);
        }
        if(c.Offset!=end)throw malformed;
        return result;
    }
    static List<MaterialRecord> MaterialRecords(byte[] bytes,int start,int end,string name) {
        var keys=MaterialLists[name];var malformed=new RuleFailure("has a '"+name+"' that is not a list of MaterialEditor records");
        var c=new Spans(bytes,start,end);var h=c.Head();if(h.Type!=MPHead.Array)throw malformed;
        var result=new List<MaterialRecord>();
        for(long i=0;i<h.Count;i++) {
            var fields=c.Fields();if(fields==null)throw malformed;
            var r=new MaterialRecord();bool hasId=false;
            foreach(var f in fields) {
                if(!keys.Contains(f.Key))throw new RuleFailure("has a '"+name+"' record key '"+f.Key+"' this writer does not know");
                var v=new Spans(bytes,f.ValueStart,f.ValueEnd);
                if(f.Key=="ID"){var n=v.Head();if(!Int32Head(n))throw malformed;r.Id=(int)n.Integer;hasId=true;}
                else if(f.Key=="TexID"){var n=v.Head();if(n.Type==MPHead.Nil)continue;if(!Int32Head(n))throw malformed;r.Textures.Add((int)n.Integer);}
                else if(f.Key=="TexAnimationDef")AnimationTextures(bytes,f.ValueStart,f.ValueEnd,r.Textures,malformed);
            }
            if(!hasId)throw malformed;
            result.Add(r);
        }
        if(c.Offset!=end)throw malformed;
        return result;
    }
    // MEAnimationDefine: each frames entry's texID (key 0 of an int-keyed MEAnimationFrame).
    static void AnimationTextures(byte[] bytes,int start,int end,List<int> into,RuleFailure malformed) {
        var fields=new Spans(bytes,start,end).Fields();if(fields==null)return;
        Field frames=null;foreach(var f in fields)if(f.Key=="frames")frames=f;
        if(frames==null)throw malformed;
        var l=new Spans(bytes,frames.ValueStart,frames.ValueEnd);var h=l.Head();if(h.Type!=MPHead.Array)throw malformed;
        for(long i=0;i<h.Count;i++) {
            var a=l.Head();if(a.Type!=MPHead.Array||a.Count<1)throw malformed;
            var n=l.Head();if(!Int32Head(n))throw malformed;
            for(long j=1;j<a.Count;j++)l.Skip(0);
            into.Add((int)n.Integer);
        }
    }

    // NodesConstraintsPlan: constraints by object index in key order (-2 the main camera), numbered by position.
    static void CheckConstraints(Trailer trailer,Entry entry,Edit edit) {
        var xml=XmlBytes(trailer,entry,"constraints");
        if(xml==null)throw new RuleFailure("has data other than one 'constraints' XML string");
        Xml doc;
        try{doc=new Xml(xml);}catch(FormatException e){throw new RuleFailure("has constraints not in the XML form NodesConstraints writes ("+e.Message+")");}
        if(doc.Elements[0].Name!="constraints"||doc.Attribute(0,"version")<0)throw new RuleFailure("has constraints whose root is not <constraints version=...>");
        var sourceKeys=edit.SourceSorted(null);
        var parents=new List<int>();var children=new List<int>();var loads=new List<int>();var pairs=new HashSet<string>();
        foreach(var el in doc.Elements[0].Children) {
            var node=doc.Elements[el];
            if(node.Name!="constraint"||node.Children.Count>0)throw new RuleFailure("has an element other than an empty constraint under its root");
            int parent,child,load;bool hasParent,hasChild,hasLoad;
            try{hasParent=doc.Integer(el,"parentObjectIndex",out parent);hasChild=doc.Integer(el,"childObjectIndex",out child);hasLoad=doc.Integer(el,"uniqueLoadId",out load);}
            catch(FormatException e){throw new RuleFailure("has constraints NodesConstraints does not write ("+e.Message+")");}
            if(!hasParent||!hasChild||!hasLoad)throw new RuleFailure("has a constraint without parentObjectIndex, childObjectIndex and uniqueLoadId");
            if(!(parent==-2||(parent>=0&&parent<sourceKeys.Count)))throw new RuleFailure("has a constraint on object index "+parent+", which this scene does not have");
            if(!(child>=0&&child<sourceKeys.Count))throw new RuleFailure("has a constraint on object index "+child+", which this scene does not have");
            string parentEnd=ConstraintEnd(doc,el,parent,"parentPath"),childEnd=ConstraintEnd(doc,el,child,"childPath");
            if(pairs.Contains(childEnd+"\u0001"+parentEnd)||!pairs.Add(parentEnd+"\u0001"+childEnd))throw new RuleFailure("has two constraints between the same transforms");
            parents.Add(parent==-2?int.MinValue:sourceKeys[parent]);children.Add(sourceKeys[child]);loads.Add(load);
        }
        if(edit.Copied.Count>0)
            for(int i=0;i<parents.Count;i++) {
                if(parents[i]==int.MinValue)break; // the duplicate patch throws at the first camera-parented constraint
                if(edit.Copied.Contains(parents[i])&&edit.Copied.Contains(children[i]))throw new RuleFailure("gives the copies of objects "+parents[i]+" and "+children[i]+" a copy of their constraint");
            }
        var kept=new List<int>();
        for(int i=0;i<parents.Count;i++)if(!(parents[i]!=int.MinValue&&edit.Deleted.Contains(parents[i]))&&!edit.Deleted.Contains(children[i]))kept.Add(loads[i]);
        if(edit.Deleted.Count>0&&edit.Copied.Count>0&&kept.Count>0)throw new RuleFailure("both deletes and copies objects, so the copies' keys and the positions after them can differ from CharaStudio's");
        bool renumbered=kept.Count!=parents.Count;for(int i=0;i<kept.Count;i++)if(kept[i]!=i)renumbered=true;
        if(renumbered&&TimelineMentions(trailer,"NodesConstraints"))throw new RuleFailure("numbers its constraints by position, and this edit renumbers constraints Timeline data may animate by number");
    }
    // A constraint end: its object index and path (its bytes in hex).
    static string ConstraintEnd(Xml doc,int el,int index,string path) {
        int a=doc.Attribute(el,path);var e=doc.Elements[el];
        string bytes=a<0?"-":"p"+BitConverter.ToString(doc.B,e.ValueStarts[a],e.ValueEnds[a]-e.ValueStarts[a]);
        return index.ToString(CultureInfo.InvariantCulture)+" "+bytes;
    }

    // Whether the scene's Timeline data may name `word`: its sceneInfo contains it, or it is there but not readable.
    static bool TimelineMentions(Trailer trailer,string word) {
        foreach(var e in trailer.Entries) {
            if(e.Id!=Timeline||e.IsNil)continue;
            string xml;
            try{xml=SingleString(trailer,e,"sceneInfo");}catch(Exception){return true;}
            return xml==null||xml.IndexOf(word,StringComparison.Ordinal)>=0;
        }
        return false;
    }

    // The entry's one field `key` as the raw bytes of its string (xmlField); null for any other shape.
    static byte[] XmlBytes(Trailer trailer,Entry entry,string key) {
        var fields=trailer.Fields(entry);
        if(fields==null||fields.Count!=1||fields[0].Key!=key)return null;
        var c=new Spans(trailer.Bytes,fields[0].ValueStart,fields[0].ValueEnd);var h=c.Head();
        if(h.Type!=MPHead.String)return null;
        int start=c.Payload((int)h.Count);
        if(c.Offset!=fields[0].ValueEnd)return null;
        var result=new byte[h.Count];Buffer.BlockCopy(trailer.Bytes,start,result,0,(int)h.Count);return result;
    }
    static byte[] Ascii(string s){return Encoding.ASCII.GetBytes(s);}
    static int IndexOf(byte[] data,byte[] needle,int start) {
        for(int i=start;i+needle.Length<=data.Length;i++) {
            if(data[i]!=needle[0])continue;
            int j=1;while(j<needle.Length&&data[i+j]==needle[j])j++;
            if(j==needle.Length)return i;
        }
        return -1;
    }
    // XmlConvert.ToString(int): -?[0-9]+ without a leading zero or "-0", within Int32.
    static bool Int32Text(byte[] b,int start,int end,out int value) {
        value=0;int i=start;bool negative=false;
        if(i<end&&b[i]==0x2d){negative=true;i++;}
        if(i>=end)return false;
        if(b[i]==0x30){if(end-i==1&&!negative)return true;return false;}
        long v=0;
        for(;i<end;i++){if(b[i]<0x30||b[i]>0x39)return false;v=v*10+(b[i]-0x30);if(v>2147483648L)return false;}
        long signed=negative?-v:v;
        if(signed<int.MinValue||signed>int.MaxValue)return false;
        value=(int)signed;return true;
    }

    // PluginXML: XML in the form XmlTextWriter writes with default settings (one root, double-quoted attributes,
    // single spaces, " />" for empty elements, no text, whitespace, comments, declarations or instructions).
    sealed class XmlElement {
        public string Name;public int Start,AttributesEnd,HeadEnd,End,Parent;public bool SelfClosing;
        public readonly List<string> Names=new List<string>();public readonly List<int> ValueStarts=new List<int>(),ValueEnds=new List<int>();
        public readonly List<int> Children=new List<int>();
    }
    sealed class Xml {
        public readonly byte[] B;public readonly List<XmlElement> Elements=new List<XmlElement>();
        static bool NameStart(byte c){return (c>=0x41&&c<=0x5a)||(c>=0x61&&c<=0x7a)||c==0x5f;}
        static bool NameChar(byte c){return NameStart(c)||(c>=0x30&&c<=0x39)||c==0x2d||c==0x2e||c==0x3a;}
        static FormatException Fail(string what,int offset){return new FormatException(what+" at byte "+offset);}
        string Name(ref int offset) {
            int start=offset;
            if(offset>=B.Length||!NameStart(B[offset]))throw Fail("a missing name",offset);
            offset++;while(offset<B.Length&&NameChar(B[offset]))offset++;
            return Encoding.ASCII.GetString(B,start,offset-start);
        }
        public Xml(byte[] b) {
            B=b;int offset=0;var open=new List<int>();
            if(b.Length==0)throw new FormatException("it is empty");
            while(offset<b.Length) {
                if(b[offset]!=0x3c)throw Fail("text outside a tag",offset);
                offset++;
                if(offset>=b.Length)throw Fail("a truncated tag",offset);
                if(b[offset]==0x2f) {
                    offset++;string closing=Name(ref offset);
                    if(offset>=b.Length||b[offset]!=0x3e)throw Fail("a malformed end tag",offset);
                    offset++;
                    if(open.Count==0||Elements[open[open.Count-1]].Name!=closing)throw Fail("an unmatched end tag",offset);
                    Elements[open[open.Count-1]].End=offset;open.RemoveAt(open.Count-1);
                    continue;
                }
                if(open.Count==0&&Elements.Count>0)throw Fail("a second root element",offset);
                var e=new XmlElement();e.Start=offset-1;e.Name=Name(ref offset);
                while(offset+1<b.Length&&b[offset]==0x20&&NameStart(b[offset+1])) {
                    offset++;string attribute=Name(ref offset);
                    if(!(offset+1<b.Length&&b[offset]==0x3d&&b[offset+1]==0x22))throw Fail("an attribute that is not name=\"value\"",offset);
                    offset+=2;int valueStart=offset;
                    while(offset<b.Length&&b[offset]!=0x22){if(b[offset]==0x3c)throw Fail("'<' in an attribute value",offset);offset++;}
                    if(offset>=b.Length)throw Fail("an unterminated attribute value",offset);
                    if(e.Names.Contains(attribute))throw Fail("a repeated attribute",offset);
                    e.Names.Add(attribute);e.ValueStarts.Add(valueStart);e.ValueEnds.Add(offset);offset++;
                }
                e.AttributesEnd=offset;
                if(b.Length-offset>=3&&b[offset]==0x20&&b[offset+1]==0x2f&&b[offset+2]==0x3e){e.SelfClosing=true;offset+=3;}
                else if(offset<b.Length&&b[offset]==0x3e)offset++;
                else throw Fail("a malformed start tag",offset);
                e.HeadEnd=offset;e.End=offset;e.Parent=open.Count>0?open[open.Count-1]:-1;
                int index=Elements.Count;Elements.Add(e);
                if(e.Parent>=0)Elements[e.Parent].Children.Add(index);
                if(!e.SelfClosing)open.Add(index);
                if(open.Count>256||Elements.Count>1000000)throw Fail("more nesting or elements than this writer reads",offset);
            }
            if(open.Count>0)throw new FormatException("it ends inside an element");
        }
        public int Attribute(int el,string name){return Elements[el].Names.IndexOf(name);}
        // False when absent; FormatException when not XmlConvert.ToString(int)'s form.
        public bool Integer(int el,string name,out int value) {
            value=0;int a=Attribute(el,name);if(a<0)return false;
            var e=Elements[el];
            if(!Int32Text(B,e.ValueStarts[a],e.ValueEnds[a],out value))throw new FormatException(e.Name+" has a "+name+" that is not a canonical Int32");
            return true;
        }
    }

    // MARK: Sideloader

    sealed class SideloaderFailure:Exception{public SideloaderFailure(string m):base(m){}}

    // UniversalAutoResolver's records must each name one object of their kind in the scene, once; the rewrite
    // itself always succeeds after that.
    static void CheckSideloader(Trailer trailer,Entry entry,Edit edit) {
        List<Field> fields;
        try{fields=trailer.Fields(entry);}catch(Exception){throw new SideloaderFailure("has a data value that is not a map");}
        if(fields==null)return;
        foreach(var f in fields) {
            if(f.Key=="itemInfo"||f.Key=="patternInfo") {
                bool pattern=f.Key=="patternInfo";
                var records=Records(trailer.Bytes,f.ValueStart,f.ValueEnd,pattern?PatternKeys:RecordKeys);
                var seen=new HashSet<int>();
                foreach(var key in records) {
                    int kind;
                    if(key<int.MinValue||key>int.MaxValue||!edit.SourceKinds.TryGetValue((int)key,out kind))throw new SideloaderFailure("names object "+key+", which is not in this scene, so CharaStudio also loads this scene partly unresolved");
                    if(pattern?kind!=Item:(kind!=Item&&kind!=Light&&kind!=Character))throw new SideloaderFailure("has a record for object "+key+" of the wrong kind");
                    if(!seen.Add((int)key))throw new SideloaderFailure("has two records for object "+key);
                }
            } else if(!SceneKeys.Contains(f.Key)) throw new SideloaderFailure("has a data key '"+f.Key+"' this writer does not know");
        }
    }

    static List<long> Records(byte[] bytes,int start,int end,HashSet<string> keys) {
        var c=new Spans(bytes,start,end);var head=c.Head();
        if(head.Type!=MPHead.Array)throw new SideloaderFailure("has a record list that is not an array");
        var result=new List<long>();
        for(long i=0;i<head.Count;i++) {
            var h=c.Head();if(h.Type!=MPHead.Binary)throw new SideloaderFailure("has a record that is not bytes");
            int payload=c.Payload((int)h.Count);
            var r=new Spans(bytes,payload,payload+(int)h.Count);
            var fields=r.Fields();
            if(fields==null||r.Offset!=payload+(int)h.Count)throw new SideloaderFailure("has a record that is not one map");
            bool hasKey=false,hasOrder=false;long key=0;
            foreach(var f in fields) {
                if(!keys.Contains(f.Key))throw new SideloaderFailure("has a record key '"+f.Key+"' this writer does not know");
                if(f.Key!="SceneDicKey"&&f.Key!="SceneObjectOrder")continue;
                var n=new Spans(bytes,f.ValueStart,f.ValueEnd).Head();
                if(!n.IsInteger||n.Integer<int.MinValue||n.Integer>int.MaxValue)throw new SideloaderFailure("has a record whose "+f.Key+" is not an Int32");
                if(f.Key=="SceneDicKey"){key=n.Integer;hasKey=true;}else hasOrder=true;
            }
            if(!hasKey||!hasOrder)throw new SideloaderFailure("has a record without SceneDicKey and SceneObjectOrder");
            result.Add(key);
        }
        if(c.Offset!=end)throw new SideloaderFailure("has a malformed record list");
        return result;
    }

    // MARK: KKEx

    sealed class Entry {public string Id;public bool IsNil,HasVersion;public long Version;public int DataStart=-1,DataEnd=-1;}
    sealed class Field {public string Key;public int ValueStart,ValueEnd;}

    // ExtendedSave's scene trailer: the dotNet string "KKEx", an Int32 data version, an Int32 length and exactly
    // that many bytes of MessagePack Dictionary<string, PluginData> (or nil).
    sealed class Trailer {
        public byte[] Bytes;public readonly List<Entry> Entries=new List<Entry>();
        public static Trailer Parse(byte[] bytes) {
            if(bytes.Length<13||bytes[0]!=4||bytes[1]!=(byte)'K'||bytes[2]!=(byte)'K'||bytes[3]!=(byte)'E'||bytes[4]!=(byte)'x')throw new FormatException("the trailer is not ExtendedSave's KKEx block");
            int length=BitConverter.ToInt32(bytes,9);
            if(length<=0||length!=bytes.Length-13)throw new FormatException("the KKEx length does not match its payload");
            var t=new Trailer();t.Bytes=bytes;
            var c=new Spans(bytes,13,bytes.Length);var ids=new HashSet<string>();
            var head=c.Head();
            if(head.Type==MPHead.Map) {
                for(long i=0;i<head.Count;i++) {
                    var e=new Entry();e.Id=c.String();
                    if(!ids.Add(e.Id))throw new FormatException("the plug-in ID '"+e.Id+"' appears twice");
                    var shape=c.Clone();var h=shape.Head();
                    if(h.Type==MPHead.Nil)e.IsNil=true;
                    else if(h.Type==MPHead.Array&&h.Count==2) {
                        var v=shape.Head();if(v.IsInteger){e.HasVersion=true;e.Version=v.Integer;}
                        e.DataStart=shape.Offset;shape.Skip(0);e.DataEnd=shape.Offset;
                        if(!e.HasVersion){e.DataStart=-1;e.DataEnd=-1;}
                    }
                    c.Skip(0);
                    t.Entries.Add(e);
                }
            } else if(head.Type!=MPHead.Nil) throw new FormatException("the KKEx payload is not a map");
            if(c.Offset!=bytes.Length)throw new FormatException("bytes follow the KKEx map");
            return t;
        }
        public List<Field> Fields(Entry entry) {
            if(entry.DataStart<0)throw new FormatException("'"+entry.Id+"' has no data value");
            return new Spans(Bytes,entry.DataStart,entry.DataEnd).Fields();
        }
    }

    // MARK: MessagePack

    struct MPHead {
        public const int Map=1,Array=2,String=3,Binary=4,Ext=5,Int=6,UInt=7,Nil=8,Bool=9,Float=10;
        public int Type;public long Count;public long Integer;public ulong Unsigned;
        public bool IsInteger{get{return Type==Int||(Type==UInt&&Unsigned<=(ulong)long.MaxValue);}}
    }

    // MessagePack located rather than decoded (SourceMessagePackSpans).
    sealed class Spans {
        readonly byte[] b;readonly int end;public int Offset;int budget=1000000;
        public Spans(byte[] bytes,int start,int end){b=bytes;Offset=start;this.end=end;}
        public Spans Clone(){var s=new Spans(b,Offset,end);s.budget=budget;return s;}
        byte Byte(){if(Offset>=end)throw new FormatException("truncated value");return b[Offset++];}
        ulong Word(int n){if(n>end-Offset)throw new FormatException("truncated numeric value");ulong r=0;for(int i=0;i<n;i++)r=r<<8|b[Offset++];return r;}
        public int Payload(int n){if(n<0||n>end-Offset)throw new FormatException("truncated byte payload");int s=Offset;Offset+=n;return s;}
        public MPHead Peek(){return Clone().Head();}
        static MPHead H(int type,long count){var h=new MPHead();h.Type=type;h.Count=count;return h;}
        static MPHead I(long v){var h=new MPHead();h.Type=MPHead.Int;h.Integer=v;return h;}
        static MPHead U(ulong v){var h=new MPHead();h.Type=MPHead.UInt;h.Unsigned=v;if(v<=(ulong)long.MaxValue)h.Integer=(long)v;return h;}
        public MPHead Head() {
            if(budget<=0)throw new FormatException("decoded value limit exceeded");budget--;
            byte code=Byte();
            if(code<=0x7f)return I(code);
            if(code>=0x80&&code<=0x8f)return H(MPHead.Map,code&15);
            if(code>=0x90&&code<=0x9f)return H(MPHead.Array,code&15);
            if(code>=0xa0&&code<=0xbf)return H(MPHead.String,code&31);
            if(code>=0xe0)return I((sbyte)code);
            switch(code) {
            case 0xc0:return H(MPHead.Nil,0);
            case 0xc2:case 0xc3:{var h=H(MPHead.Bool,0);h.Integer=code==0xc3?1:0;return h;}
            case 0xc4:return H(MPHead.Binary,(long)Word(1));
            case 0xc5:return H(MPHead.Binary,(long)Word(2));
            case 0xc6:return H(MPHead.Binary,(long)Word(4));
            case 0xc7:case 0xc8:case 0xc9:{long n=(long)Word(code==0xc7?1:code==0xc8?2:4);Byte();return H(MPHead.Ext,n);}
            case 0xca:Payload(4);return H(MPHead.Float,0);
            case 0xcb:Payload(8);return H(MPHead.Float,0);
            case 0xcc:return U(Word(1));
            case 0xcd:return U(Word(2));
            case 0xce:return U(Word(4));
            case 0xcf:return U(Word(8));
            case 0xd0:return I((sbyte)Word(1));
            case 0xd1:return I((short)Word(2));
            case 0xd2:return I((int)Word(4));
            case 0xd3:return I((long)Word(8));
            case 0xd4:case 0xd5:case 0xd6:case 0xd7:case 0xd8:Byte();return H(MPHead.Ext,1<<(code-0xd4));
            case 0xd9:return H(MPHead.String,(long)Word(1));
            case 0xda:return H(MPHead.String,(long)Word(2));
            case 0xdb:return H(MPHead.String,(long)Word(4));
            case 0xdc:return H(MPHead.Array,(long)Word(2));
            case 0xdd:return H(MPHead.Array,(long)Word(4));
            case 0xde:return H(MPHead.Map,(long)Word(2));
            case 0xdf:return H(MPHead.Map,(long)Word(4));
            }
            throw new FormatException("reserved code 0xc1");
        }
        public void Skip(int depth) {
            var h=Head();
            switch(h.Type) {
            case 1:Children(h.Count*2,depth);break;
            case 2:Children(h.Count,depth);break;
            case 3:case 4:case 5:Payload((int)h.Count);break;
            }
        }
        void Children(long count,int depth) {
            if(depth>=64)throw new FormatException("container nesting exceeds 64");
            if(count>end-Offset)throw new FormatException("truncated container");
            for(long i=0;i<count;i++)Skip(depth+1);
        }
        static readonly UTF8Encoding Strict=new UTF8Encoding(false,true);
        public string String() {
            var h=Head();if(h.Type!=MPHead.String)throw new FormatException("expected a string");
            int s=Payload((int)h.Count);return Strict.GetString(b,s,(int)h.Count);
        }
        public List<Field> Fields() {
            var h=Head();if(h.Type==MPHead.Nil)return null;
            if(h.Type!=MPHead.Map)throw new FormatException("expected a map");
            if(h.Count>end-Offset)throw new FormatException("truncated container");
            var result=new List<Field>();var keys=new HashSet<string>();
            for(long i=0;i<h.Count;i++) {
                var f=new Field();f.Key=String();
                if(!keys.Add(f.Key))throw new FormatException("duplicate string map key '"+f.Key+"'");
                f.ValueStart=Offset;Skip(1);f.ValueEnd=Offset;result.Add(f);
            }
            return result;
        }
    }

    // MessagePack decoded (SourceMessagePack.decode): exactly one value, 64 container levels, 1,000,000 values.
    sealed class Value {
        public const int TNil=0,TBool=1,TInt=2,TUInt=3,TFloat=4,TStr=5,TBin=6,TArray=7,TMap=8,TExt=9;
        public int Type;public long IntegerValue;public ulong UnsignedValue;public string Text;public List<Value> Items;
        public long Integer{get{return IntegerValue;}}
        public ulong Unsigned{get{return UnsignedValue;}}
        sealed class Reader {public byte[] B;public int Offset,End,Remaining=1000000;}
        public static Value Decode(byte[] bytes,int start,int count) {
            if(count<=0)throw new FormatException("empty input");
            var r=new Reader();r.B=bytes;r.Offset=start;r.End=start+count;
            var v=Read(r,0);
            if(r.Offset!=r.End)throw new FormatException("trailing bytes");
            return v;
        }
        static byte Byte(Reader r){if(r.Offset>=r.End)throw new FormatException("truncated value");return r.B[r.Offset++];}
        static ulong Word(Reader r,int n){if(n>r.End-r.Offset)throw new FormatException("truncated numeric value");ulong x=0;for(int i=0;i<n;i++)x=x<<8|r.B[r.Offset++];return x;}
        static int Data(Reader r,long n){if(n<0||n>r.End-r.Offset)throw new FormatException("truncated byte payload");int s=r.Offset;r.Offset+=(int)n;return s;}
        static Value V(int type){var v=new Value();v.Type=type;return v;}
        static Value I(long x){var v=V(TInt);v.IntegerValue=x;return v;}
        static Value U(ulong x){var v=V(TUInt);v.UnsignedValue=x;return v;}
        static readonly UTF8Encoding Strict=new UTF8Encoding(false,true);
        static Value S(Reader r,long n){int s=Data(r,n);var v=V(TStr);v.Text=Strict.GetString(r.B,s,(int)n);return v;}
        static Value Container(Reader r,int type,long count,int depth) {
            long children=type==TMap?count*2:count;
            if(depth>=64)throw new FormatException("container nesting exceeds 64");
            if(children>r.Remaining)throw new FormatException("decoded value limit exceeded");
            if(children>r.End-r.Offset)throw new FormatException("truncated container");
            var v=V(type);v.Items=new List<Value>();
            for(long i=0;i<children;i++)v.Items.Add(Read(r,depth+1));
            return v;
        }
        static Value Read(Reader r,int depth) {
            if(r.Remaining<=0)throw new FormatException("decoded value limit exceeded");r.Remaining--;
            byte code=Byte(r);
            if(code<=0x7f)return I(code);
            if(code>=0x80&&code<=0x8f)return Container(r,TMap,code&15,depth);
            if(code>=0x90&&code<=0x9f)return Container(r,TArray,code&15,depth);
            if(code>=0xa0&&code<=0xbf)return S(r,code&31);
            if(code>=0xe0)return I((sbyte)code);
            switch(code) {
            case 0xc0:return V(TNil);
            case 0xc2:case 0xc3:return V(TBool);
            case 0xc4:Data(r,(long)Word(r,1));return V(TBin);
            case 0xc5:Data(r,(long)Word(r,2));return V(TBin);
            case 0xc6:Data(r,(long)Word(r,4));return V(TBin);
            case 0xc7:case 0xc8:case 0xc9:{long n=(long)Word(r,code==0xc7?1:code==0xc8?2:4);Byte(r);Data(r,n);return V(TExt);}
            case 0xca:Word(r,4);return V(TFloat);
            case 0xcb:Word(r,8);return V(TFloat);
            case 0xcc:return U(Word(r,1));
            case 0xcd:return U(Word(r,2));
            case 0xce:return U(Word(r,4));
            case 0xcf:return U(Word(r,8));
            case 0xd0:return I((sbyte)Word(r,1));
            case 0xd1:return I((short)Word(r,2));
            case 0xd2:return I((int)Word(r,4));
            case 0xd3:return I((long)Word(r,8));
            case 0xd4:case 0xd5:case 0xd6:case 0xd7:case 0xd8:Byte(r);Data(r,1<<(code-0xd4));return V(TExt);
            case 0xd9:return S(r,(long)Word(r,1));
            case 0xda:return S(r,(long)Word(r,2));
            case 0xdb:return S(r,(long)Word(r,4));
            case 0xdc:return Container(r,TArray,(long)Word(r,2),depth);
            case 0xdd:return Container(r,TArray,(long)Word(r,4),depth);
            case 0xde:return Container(r,TMap,(long)Word(r,2),depth);
            case 0xdf:return Container(r,TMap,(long)Word(r,4),depth);
            }
            throw new FormatException("reserved code 0xc1");
        }
    }
}
