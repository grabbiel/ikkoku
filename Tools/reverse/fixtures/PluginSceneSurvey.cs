// Survey 2 of original_plugin_scene_probe.py phase B: which single-target edits of the installed CharaStudio scenes
// the original-scene writer accepts before and after ST-T03i, judged by PluginSceneRules (the parity-gated C# port
// of the Swift rules). Runs inside the original player, last, after PluginSceneRuleParity has agreed with the Swift
// corpus under the player's own compiler. Read-only: each scene is read into memory with sharing read, write and
// delete; nothing is written but the counts the probe puts in survey2.json. No file name, path, hash, object name or
// data value is kept.
//
// A scene whose KKEx block holds at least one entry has its object section read the way SceneInfo.Load reads it
// (PngFile.SkipPng, the version string, then key, kind and ObjectInfo.Load for each root record), but without
// SceneInfo.Load itself, so ExtendedSave's SceneInfo.Load hook does not raise SceneBeingLoaded and no plug-in
// acts on the scene. ObjectInfo.Load registers every key (objects and sub-infos) in Studio.sceneInfo's hashIndex
// through Studio.SetNewIndex, exactly as a load does; that set is cleared before each scene and read afterwards as
// the scene's used keys. Character cards load through ChaFileControl.LoadCharaFile, whose ExtendedSave hook keeps
// each card's plug-in data, which is where KKAnimationController links are read. The session is not saved after
// this survey.
//
// Edits judged per scene, as the Swift corpus enumerates them: delete and duplicate of every object in the walk,
// adding a folder, a light and a camera, and adding and deleting a point of a route (when the scene has a route,
// and one with two points or more). Before ST-T03i the writer refused delete, duplicate and route-point edits in
// any scene whose KKEx map had an entry (nil entries included) and accepted additions in every scene.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using Studio;

public sealed class PluginSceneSurvey {
    static readonly byte[] EndMarker={0x0D,0xE3,0x80,0x90,0x4B,0x53,0x74,0x75,0x64,0x69,0x6F,0xE3,0x80,0x91}; // dotNet string "【KStudio】"
    static readonly byte[] KKEx={0x04,0x4B,0x4B,0x45,0x78};
    public static readonly string[] EditKinds={"delete","duplicate","addFolder","addLight","addCamera","routeAdd","routeDelete"};
    const string CardController="com.deathweasel.bepinex.animationcontroller";
    sealed class Stats {
        public long Scenes;public bool Known,Orphan;
        public readonly SortedDictionary<string,long> Forms=new SortedDictionary<string,long>(StringComparer.Ordinal);
        public readonly SortedDictionary<string,long> Refuses=new SortedDictionary<string,long>(StringComparer.Ordinal);
    }
    readonly Studio.Studio studio;
    readonly HashSet<int> hashIndex;
    readonly MethodInfo cardData;
    readonly double seconds;readonly long bound;
    readonly Stopwatch watch=Stopwatch.StartNew();
    public bool Truncated;
    readonly SortedDictionary<string,long> counts=new SortedDictionary<string,long>(StringComparer.Ordinal);
    readonly SortedDictionary<string,SortedDictionary<string,long>> after=new SortedDictionary<string,SortedDictionary<string,long>>(StringComparer.Ordinal);
    readonly SortedDictionary<string,SortedDictionary<string,long>> before=new SortedDictionary<string,SortedDictionary<string,long>>(StringComparer.Ordinal);
    readonly SortedDictionary<string,long> unknownOnly=new SortedDictionary<string,long>(StringComparer.Ordinal);
    readonly SortedDictionary<string,Stats> ids=new SortedDictionary<string,Stats>(StringComparer.Ordinal);
    readonly SortedDictionary<string,long> orphanShapes=new SortedDictionary<string,long>(StringComparer.Ordinal);
    readonly List<long> objectCounts=new List<long>();
    // The current scene's routes in walk order: key and point count (points are sub-infos, not objects).
    readonly List<KeyValuePair<int,int>> routes=new List<KeyValuePair<int,int>>();

    public PluginSceneSurvey(Studio.Studio studio,double seconds,long bound) {
        this.studio=studio;this.seconds=seconds;this.bound=bound;
        hashIndex=typeof(SceneInfo).GetField("hashIndex",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(studio.sceneInfo) as HashSet<int>;
        if(hashIndex==null)throw new Exception("SceneInfo.hashIndex not found");
        Type save=null;
        foreach(var asm in AppDomain.CurrentDomain.GetAssemblies()){var t=asm.GetType("ExtensibleSaveFormat.ExtendedSave",false);if(t!=null)save=t;}
        if(save==null)throw new Exception("ExtendedSave not found");
        cardData=save.GetMethod("GetExtendedDataById",BindingFlags.Public|BindingFlags.Static,null,new[]{typeof(ChaFile),typeof(string)},null);
        if(cardData==null)throw new Exception("ExtendedSave.GetExtendedDataById(ChaFile, string) not found");
        foreach(var name in new[]{"files","oversize","unreadable","noEndMarker","noTrailer","otherTrailer","unreadableTrailer","emptyMap","entries",
                                  "loaded","loadError","remappedRoots","linkedScenes","linkedCharacters","judgedEdits"})counts[name]=0;
        foreach(var kind in EditKinds){after[kind]=Outcomes();before[kind]=Outcomes();unknownOnly[kind]=0;}
    }
    static SortedDictionary<string,long> Outcomes(){var d=new SortedDictionary<string,long>(StringComparer.Ordinal);foreach(var o in new[]{"all","some","none","notApplicable"})d[o]=0;return d;}
    void Bump(SortedDictionary<string,long> d,string key){long n;d.TryGetValue(key,out n);d[key]=n+1;}

    public bool TimedOut{get{return watch.Elapsed.TotalSeconds>seconds;}}

    public void Add(string path) {
        counts["files"]++;
        byte[] data;
        try {
            using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
                if(stream.Length>bound){counts["oversize"]++;return;}
                data=new byte[stream.Length];int at=0;
                while(at<data.Length){int n=stream.Read(data,at,data.Length-at);if(n<=0)throw new EndOfStreamException();at+=n;}
            }
        } catch(Exception){counts["unreadable"]++;return;}
        int marker=IndexOf(data,EndMarker,KKEx);
        if(marker<0) {
            int end=IndexOf(data,EndMarker,null);
            if(end<0)counts["noEndMarker"]++;else if(end+EndMarker.Length==data.Length)counts["noTrailer"]++;else counts["otherTrailer"]++;
            return;
        }
        var trailer=new byte[data.Length-marker-EndMarker.Length];
        Buffer.BlockCopy(data,marker+EndMarker.Length,trailer,0,trailer.Length);
        List<string[]> forms;
        try{forms=PluginSceneRules.Forms(trailer);}catch(Exception){counts["unreadableTrailer"]++;return;}
        if(forms.Count==0){counts["emptyMap"]++;return;}
        counts["entries"]++;
        PluginSceneModel scene;
        try{scene=Model(data,trailer);}catch(Exception){counts["loadError"]++;return;}
        counts["loaded"]++;
        objectCounts.Add(scene.Keys.Count);
        if(scene.Linked.Count>0){counts["linkedScenes"]++;counts["linkedCharacters"]+=scene.Linked.Count;}
        foreach(var form in forms) {
            Stats s;if(!ids.TryGetValue(form[0],out s)){s=new Stats();s.Known=PluginSceneRules.Known(form[0]);s.Orphan=PluginSceneRules.Orphans.Contains(form[0]);ids[form[0]]=s;}
            s.Scenes++;Bump(s.Forms,form[1]);
            if(form[2].Length>0)Bump(orphanShapes,form[0]+" "+form[2]);
        }
        Judge(scene);
    }

    // The scene's walk, used keys and linked characters.
    PluginSceneModel Model(byte[] data,byte[] trailer) {
        hashIndex.Clear();studio.dicChangeAmount.Clear();routes.Clear();
        var roots=new List<KeyValuePair<int,ObjectInfo>>();
        using(var stream=new MemoryStream(data,false))
        using(var reader=new BinaryReader(stream)) {
            PngFile.SkipPng(reader);
            var version=new Version(reader.ReadString());
            int count=reader.ReadInt32();
            for(int i=0;i<count;i++) {
                int key=reader.ReadInt32(),kind=reader.ReadInt32();
                ObjectInfo info;
                switch(kind) {
                case 0:info=new OICharInfo(null,-1);break;
                case 1:info=new OIItemInfo(-1,-1,-1,-1);break;
                case 2:info=new OILightInfo(-1,-1);break;
                case 3:info=new OIFolderInfo(-1);break;
                case 4:info=new OIRouteInfo(-1);break;
                case 5:info=new OICameraInfo(-1);break;
                default:throw new FormatException("object kind "+kind);
                }
                info.Load(reader,version,false);
                hashIndex.Add(key);
                if(info.dicKey!=key)counts["remappedRoots"]++;
                roots.Add(new KeyValuePair<int,ObjectInfo>(key,info));
            }
        }
        var scene=new PluginSceneModel();scene.Trailer=trailer;
        foreach(var root in roots)Visit(scene,root.Value,root.Key,-1);
        foreach(var key in hashIndex)scene.Used.Add(key);
        return scene;
    }

    void Visit(PluginSceneModel scene,ObjectInfo info,int key,int parent) {
        scene.Keys.Add(key);scene.Kinds.Add(info.kind);scene.Parents.Add(parent);
        var chara=info as OICharInfo;
        if(chara!=null) {
            if(Linked(chara))scene.Linked.Add(key);
            var points=new List<int>(chara.child.Keys);points.Sort();
            foreach(var point in points)foreach(var child in chara.child[point])Visit(scene,child,child.dicKey,key);
            return;
        }
        List<ObjectInfo> children=null;
        var route=info as OIRouteInfo;
        if(route!=null){routes.Add(new KeyValuePair<int,int>(key,route.route.Count));children=route.child;}
        else if(info is OIItemInfo)children=((OIItemInfo)info).child;
        else if(info is OIFolderInfo)children=((OIFolderInfo)info).child;
        if(children!=null)foreach(var child in children)Visit(scene,child,child.dicKey,key);
    }

    // The card's KKAnimationController data carries Links or Eyes (SourceScenePluginData.cardLinks).
    bool Linked(OICharInfo chara) {
        if(chara.charFile==null)return false;
        var data=cardData.Invoke(null,new object[]{chara.charFile,CardController});
        if(data==null)return false;
        var map=data.GetType().GetField("data").GetValue(data) as IDictionary;
        if(map==null)return false;
        foreach(var name in new[]{"Links","Eyes"})if(map.Contains(name)&&map[name]!=null)return true;
        return false;
    }

    void Judge(PluginSceneModel scene) {
        var edits=new Dictionary<string,List<PluginSceneEdit>>();
        foreach(var kind in EditKinds)edits[kind]=new List<PluginSceneEdit>();
        for(int i=0;i<scene.Keys.Count;i++) {
            edits["delete"].Add(new PluginSceneEdit("delete",scene.Keys[i],-1));
            edits["duplicate"].Add(new PluginSceneEdit("duplicate",scene.Keys[i],-1));
        }
        // A route-point edit's verdict does not depend on the route: the first route, and the first with two points.
        int route=routes.Count>0?routes[0].Key:-1,longRoute=-1;
        foreach(var entry in routes)if(entry.Value>1&&longRoute<0)longRoute=entry.Key;
        edits["addFolder"].Add(new PluginSceneEdit("add",-1,PluginSceneRules.Folder));
        edits["addLight"].Add(new PluginSceneEdit("add",-1,PluginSceneRules.Light));
        edits["addCamera"].Add(new PluginSceneEdit("add",-1,PluginSceneRules.Camera));
        if(route>=0)edits["routeAdd"].Add(new PluginSceneEdit("routeAdd",route,-1));
        if(longRoute>=0)edits["routeDelete"].Add(new PluginSceneEdit("routeDelete",longRoute,-1));
        foreach(var kind in EditKinds) {
            var list=edits[kind];
            if(list.Count==0){after[kind]["notApplicable"]++;before[kind]["notApplicable"]++;continue;}
            int accepted=0;bool onlyUnknown=true,refused=false;
            var refusing=new HashSet<string>(StringComparer.Ordinal);
            foreach(var edit in list) {
                var verdict=PluginSceneRules.Judge(scene,edit);counts["judgedEdits"]++;
                if(!verdict.Refused){accepted++;continue;}
                refused=true;
                if(verdict.Ids.Count==0)onlyUnknown=false; // an unreadable trailer
                foreach(var id in verdict.Ids){refusing.Add(id);if(PluginSceneRules.Known(id))onlyUnknown=false;}
            }
            after[kind][accepted==list.Count?"all":accepted==0?"none":"some"]++;
            before[kind][kind.StartsWith("add",StringComparison.Ordinal)?"all":"none"]++;
            if(refused&&onlyUnknown)unknownOnly[kind]++;
            foreach(var id in refusing)Bump(ids[id].Refuses,kind);
        }
    }

    static int IndexOf(byte[] data,byte[] marker,byte[] next) {
        int length=marker.Length+(next==null?0:next.Length);
        for(int i=0;i+length<=data.Length;i++) {
            bool match=true;
            for(int j=0;j<marker.Length&&match;j++)if(data[i+j]!=marker[j])match=false;
            if(match&&next!=null)for(int j=0;j<next.Length&&match;j++)if(data[i+marker.Length+j]!=next[j])match=false;
            if(match)return i;
        }
        return -1;
    }

    public Dictionary<string,object> Result() {
        var idList=new Dictionary<string,object>();
        foreach(var entry in ids) {
            var s=entry.Value;
            idList[entry.Key]=new Dictionary<string,object>{{"scenes",s.Scenes},{"known",s.Known},{"orphan",s.Orphan},{"forms",s.Forms},{"scenesRefusing",s.Refuses}};
        }
        objectCounts.Sort();
        long total=0;foreach(var n in objectCounts)total+=n;
        return new Dictionary<string,object>{
            {"seconds",Math.Round(watch.Elapsed.TotalSeconds,1)},{"truncated",Truncated},{"perFileByteBound",bound},{"counts",counts},
            {"objects",new Dictionary<string,object>{{"total",total},{"max",objectCounts.Count==0?0:objectCounts[objectCounts.Count-1]},
                {"median",objectCounts.Count==0?0:objectCounts[objectCounts.Count/2]}}},
            {"scenesByEditKindAfter",after},{"scenesByEditKindBefore",before},{"scenesRefusedOnlyByUnknownIDs",unknownOnly},
            {"entryIDs",idList},{"orphanShapes",orphanShapes}};
    }
}
