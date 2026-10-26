// Read-only survey of the KKEx (ExtendedSave) trailers of the installed CharaStudio scenes, for ranking which
// plug-in adapters the original-scene writer needs next (original_plugin_scene_probe.py phase A). Usage:
//   KKExSceneSurvey.exe <scene folder> <output json> <seconds bound> <per-file byte bound>
// Every *.png under the folder is opened read-only (sharing read, write and delete). The trailer is the KKEx block
// ExtendedSave writes straight after the scene's "【KStudio】" end marker: the dotNet string "KKEx", an Int32 data
// version, an Int32 length, then a MessagePack map of entry ID -> PluginData [version, data]. The output holds
// counts only: per entry ID the number of scenes, the PluginData versions and the entry sizes in bytes, and the
// number of scenes per combination of entry IDs. No file name, path, hash or data value is written.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
static class KKExSceneSurvey {
    // dotNet string "【KStudio】" (13 UTF-8 bytes) followed by dotNet string "KKEx".
    static readonly byte[] Block={0x0D,0xE3,0x80,0x90,0x4B,0x53,0x74,0x75,0x64,0x69,0x6F,0xE3,0x80,0x91,0x04,0x4B,0x4B,0x45,0x78};
    static readonly byte[] EndMarker={0x0D,0xE3,0x80,0x90,0x4B,0x53,0x74,0x75,0x64,0x69,0x6F,0xE3,0x80,0x91};
    sealed class Entry{public int Scenes;public readonly SortedDictionary<string,int> Versions=new SortedDictionary<string,int>();public readonly List<long> Sizes=new List<long>();}
    static int Main(string[] args) {
        string dir=args[0],output=args[1];double seconds=double.Parse(args[2],CultureInfo.InvariantCulture);long bound=long.Parse(args[3],CultureInfo.InvariantCulture);
        var watch=Stopwatch.StartNew();
        var counts=new SortedDictionary<string,long>();
        foreach(var name in new[]{"files","kkex","noTrailer","otherTrailer","noEndMarker","unparsable","oversize","unreadable","bytesAfterKKEx","emptyMap"})counts[name]=0;
        var dataVersions=new SortedDictionary<string,int>();
        var entries=new SortedDictionary<string,Entry>(StringComparer.Ordinal);
        var combinations=new Dictionary<string,int>(StringComparer.Ordinal);
        long bytesRead=0;bool truncated=false,exists=Directory.Exists(dir);
        if(exists) foreach(var path in Directory.EnumerateFiles(dir,"*.png",SearchOption.AllDirectories)) {
            if(watch.Elapsed.TotalSeconds>seconds){truncated=true;break;}
            counts["files"]++;
            byte[] data;
            try {
                using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
                    if(stream.Length>bound){counts["oversize"]++;continue;}
                    data=new byte[stream.Length];int at=0;
                    while(at<data.Length){int n=stream.Read(data,at,data.Length-at);if(n<=0)throw new EndOfStreamException();at+=n;}
                }
            } catch(Exception){counts["unreadable"]++;continue;}
            bytesRead+=data.Length;
            int block=IndexOf(data,Block);
            if(block<0) {
                int end=IndexOf(data,EndMarker);
                if(end<0)counts["noEndMarker"]++;else if(end+EndMarker.Length==data.Length)counts["noTrailer"]++;else counts["otherTrailer"]++;
                continue;
            }
            int p=block+Block.Length;
            if(p+8>data.Length){counts["unparsable"]++;continue;}
            int version=BitConverter.ToInt32(data,p),length=BitConverter.ToInt32(data,p+4);p+=8;
            if(length<0||(long)p+length>data.Length){counts["unparsable"]++;continue;}
            var found=new List<KeyValuePair<string,KeyValuePair<string,long>>>();
            try {
                var r=new Reader(data,p,p+length);
                long count=r.MapHeader();
                for(long i=0;i<count;i++) {
                    string id=r.Str();int start=r.At;string pdVersion="?";
                    if(r.IsArray()){var save=r.At;long n=r.ArrayHeader();pdVersion=n>0?r.IntText():"empty";r.At=save;}
                    r.Skip();
                    found.Add(new KeyValuePair<string,KeyValuePair<string,long>>(id,new KeyValuePair<string,long>(pdVersion,r.At-start)));
                }
                if(r.At!=p+length)throw new InvalidDataException("map ends before the KKEx length");
            } catch(Exception){counts["unparsable"]++;continue;}
            counts["kkex"]++;
            if(p+length!=data.Length)counts["bytesAfterKKEx"]++;
            if(found.Count==0)counts["emptyMap"]++;
            Bump(dataVersions,version.ToString(CultureInfo.InvariantCulture));
            var ids=new List<string>();
            foreach(var f in found) {
                Entry e;if(!entries.TryGetValue(f.Key,out e)){e=new Entry();entries[f.Key]=e;}
                e.Scenes++;Bump(e.Versions,f.Value.Key);e.Sizes.Add(f.Value.Value);ids.Add(f.Key);
            }
            ids.Sort(StringComparer.Ordinal);
            string combo=String.Join("\n",ids.ToArray());int c;combinations.TryGetValue(combo,out c);combinations[combo]=c+1;
        }
        var b=new StringBuilder();
        b.Append("{\"schemaVersion\":1,\"folderExists\":").Append(exists?"true":"false").Append(",\"truncated\":").Append(truncated?"true":"false");
        b.Append(",\"seconds\":").Append(watch.Elapsed.TotalSeconds.ToString("0.0",CultureInfo.InvariantCulture)).Append(",\"bytesRead\":").Append(bytesRead);
        b.Append(",\"perFileByteBound\":").Append(bound).Append(",\"counts\":{");
        bool first=true;foreach(var kv in counts){if(!first)b.Append(',');first=false;b.Append(S(kv.Key)).Append(':').Append(kv.Value);}
        b.Append("},\"kkexDataVersions\":").Append(Map(dataVersions)).Append(",\"entries\":[");
        first=true;
        foreach(var kv in entries) {
            if(!first)b.Append(',');first=false;var s=kv.Value.Sizes;s.Sort();long total=0;foreach(var x in s)total+=x;
            b.Append("{\"id\":").Append(S(kv.Key)).Append(",\"scenes\":").Append(kv.Value.Scenes).Append(",\"versions\":").Append(Map(kv.Value.Versions));
            b.Append(",\"bytes\":{\"min\":").Append(s[0]).Append(",\"median\":").Append(s[s.Count/2]).Append(",\"p90\":").Append(s[Math.Min(s.Count-1,(int)(s.Count*0.9))]);
            b.Append(",\"max\":").Append(s[s.Count-1]).Append(",\"total\":").Append(total).Append("}}");
        }
        b.Append("],\"combinations\":[");
        var combos=new List<KeyValuePair<string,int>>(combinations);
        combos.Sort((x,y)=>x.Value!=y.Value?y.Value.CompareTo(x.Value):String.CompareOrdinal(x.Key,y.Key));
        first=true;
        foreach(var kv in combos) {
            if(!first)b.Append(',');first=false;
            b.Append("{\"scenes\":").Append(kv.Value).Append(",\"ids\":[");
            var ids=kv.Key.Length==0?new string[0]:kv.Key.Split('\n');
            for(int i=0;i<ids.Length;i++){if(i>0)b.Append(',');b.Append(S(ids[i]));}
            b.Append("]}");
        }
        b.Append("]}");
        File.WriteAllText(output,b.ToString(),new UTF8Encoding(false));
        return 0;
    }
    static void Bump(SortedDictionary<string,int> d,string key){int c;d.TryGetValue(key,out c);d[key]=c+1;}
    static string Map(SortedDictionary<string,int> d){var b=new StringBuilder("{");bool first=true;foreach(var kv in d){if(!first)b.Append(',');first=false;b.Append(S(kv.Key)).Append(':').Append(kv.Value);}return b.Append('}').ToString();}
    static string S(string s){var b=new StringBuilder("\"");foreach(char c in s){if(c=='\\'||c=='"')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
    static int IndexOf(byte[] data,byte[] pattern) {
        for(int i=Array.IndexOf(data,pattern[0]);i>=0&&i<=data.Length-pattern.Length;i=Array.IndexOf(data,pattern[0],i+1)) {
            int j=1;while(j<pattern.Length&&data[i+j]==pattern[j])j++;
            if(j==pattern.Length)return i;
        }
        return -1;
    }
    // A bounded MessagePack reader: headers, strings, integers, and Skip over any value (nesting bounded at 64).
    sealed class Reader {
        readonly byte[] d;readonly int end;public int At;
        public Reader(byte[] data,int start,int stop){d=data;At=start;end=stop;}
        byte U8(){if(At>=end)throw new InvalidDataException("truncated");return d[At++];}
        long Be(int n){long v=0;for(int i=0;i<n;i++)v=(v<<8)|U8();return v;}
        void Take(long n){if(n<0||At+n>end)throw new InvalidDataException("truncated");At+=(int)n;}
        public bool IsArray(){if(At>=end)return false;byte b=d[At];return (b&0xf0)==0x90||b==0xdc||b==0xdd;}
        public long MapHeader(){byte b=U8();if((b&0xf0)==0x80)return b&0x0f;if(b==0xde)return Be(2);if(b==0xdf)return Be(4);throw new InvalidDataException("not a map");}
        public long ArrayHeader(){byte b=U8();if((b&0xf0)==0x90)return b&0x0f;if(b==0xdc)return Be(2);if(b==0xdd)return Be(4);throw new InvalidDataException("not an array");}
        public string Str() {
            byte b=U8();long n;
            if((b&0xe0)==0xa0)n=b&0x1f;else if(b==0xd9)n=Be(1);else if(b==0xda)n=Be(2);else if(b==0xdb)n=Be(4);else throw new InvalidDataException("key is not a string");
            int start=At;Take(n);return Encoding.UTF8.GetString(d,start,(int)n);
        }
        public string IntText() {
            byte b=U8();
            if(b<=0x7f)return b.ToString(CultureInfo.InvariantCulture);
            if(b>=0xe0)return ((sbyte)b).ToString(CultureInfo.InvariantCulture);
            switch(b) {
                case 0xcc:return Be(1).ToString(CultureInfo.InvariantCulture);case 0xcd:return Be(2).ToString(CultureInfo.InvariantCulture);
                case 0xce:return Be(4).ToString(CultureInfo.InvariantCulture);case 0xcf:return ((ulong)Be(8)).ToString(CultureInfo.InvariantCulture);
                case 0xd0:return ((sbyte)Be(1)).ToString(CultureInfo.InvariantCulture);case 0xd1:return ((short)Be(2)).ToString(CultureInfo.InvariantCulture);
                case 0xd2:return ((int)Be(4)).ToString(CultureInfo.InvariantCulture);case 0xd3:return Be(8).ToString(CultureInfo.InvariantCulture);
                case 0xc0:return "nil";
            }
            return "non-integer";
        }
        public void Skip(){Skip(0);}
        void Skip(int depth) {
            if(depth>64)throw new InvalidDataException("nesting");
            byte b=U8();
            if(b<=0x7f||b>=0xe0||b==0xc0||b==0xc2||b==0xc3)return;
            if((b&0xf0)==0x80){long n=b&0x0f;for(long i=0;i<2*n;i++)Skip(depth+1);return;}
            if((b&0xf0)==0x90){long n=b&0x0f;for(long i=0;i<n;i++)Skip(depth+1);return;}
            if((b&0xe0)==0xa0){Take(b&0x1f);return;}
            switch(b) {
                case 0xc4:case 0xd9:Take(Be(1));return;case 0xc5:case 0xda:Take(Be(2));return;case 0xc6:case 0xdb:Take(Be(4));return;
                case 0xc7:Take(Be(1)+1);return;case 0xc8:Take(Be(2)+1);return;case 0xc9:Take(Be(4)+1);return;
                case 0xca:Take(4);return;case 0xcb:Take(8);return;
                case 0xcc:case 0xd0:Take(1);return;case 0xcd:case 0xd1:Take(2);return;case 0xce:case 0xd2:Take(4);return;case 0xcf:case 0xd3:Take(8);return;
                case 0xd4:Take(2);return;case 0xd5:Take(3);return;case 0xd6:Take(5);return;case 0xd7:Take(9);return;case 0xd8:Take(17);return;
                case 0xdc:{long n=Be(2);for(long i=0;i<n;i++)Skip(depth+1);return;}
                case 0xdd:{long n=Be(4);for(long i=0;i<n;i++)Skip(depth+1);return;}
                case 0xde:{long n=Be(2);for(long i=0;i<2*n;i++)Skip(depth+1);return;}
                case 0xdf:{long n=Be(4);for(long i=0;i<2*n;i++)Skip(depth+1);return;}
            }
            throw new InvalidDataException("reserved byte 0xc1");
        }
    }
}
