#!/usr/bin/env python3
"""ST-A11 maps: read-only VM phases for the CharaStudio map slice, each in ONE `prlctl exec`.

`fetch` copies named files out of the installed game for local reading and conversion. By
default these are the Studio map scene bundles, every `abdata/studio/info/*.unity3d` (the `Map_XX`
catalogs `Studio.Info.LoadMapLoadInfo` reads) and the `abdata/abdata` AssetBundleManifest (bundle
dependencies); --file, --glob (one directory) and --tree (<label>:<dir>/<pattern>, recursive)
name other sets. The exec command only fetches `run.ps1` from a temporary host-only HTTP endpoint
(original_wear_probe.py's transport). run.ps1, no player run and no junctions:
1. refuses to start while a CharaStudio/Koikatu process runs or the root exists, and scans
   `abdata` and `UserData\\studio\\scene` (counts, bytes, a SHA-256 of the sorted listing);
2. lists every requested set first (count and bytes per set) and copies nothing when a file
   exceeds the per-file bound, a tree exceeds --tree-max-bytes or the total exceeds
   --max-total-bytes (the listing comes back with the reason);
3. otherwise, batch by batch (at most --batch-bytes each): hashes each file in place, copies it
   under an index name (f00000, ...) into a fresh C:\\Temp\\IkkokuMapFetch-<32 hex> folder and
   hashes the copy, zips the batch uncompressed, PUTs it (streamed) and deletes it;
4. PUTs the record (fetch-record.json, UTF-8: per file its path, set, batch, bytes and hash),
   always removes the root, scans again and reports leftover game processes.
Nothing in C:\\Illusion\\Koikatsu is written. Paths travel only in the UTF-8 record, so names
outside ASCII survive; stdout carries an ASCII summary. The Parallels errno-24 count must equal
--errno-baseline before the exec; it is recorded before and after.

Plain files and globs land under <output>/source/<relative path>, a tree's files under
<output>/<label>/<path below the tree's directory>, with a fetch.json that records each file's
guest SHA-256, the local SHA-256 (must match) and its size, the set listing and both scans.

`capture` runs fixtures/OriginalMapProbe.cs in a fresh private player root through
original_scene_reload_probe.py's one-exec transport (`once_script`, served and compiled as
MapProbe.cs / IkkokuMapProbe.dll). The player authors scene-map33.png (an emptied scene, map 33
with a nonzero map transform and a camera inside the room) and, from --showoff (a character scene
without a map, uploaded as reload-showoff.png), scene-map33-showoff.png; it reads each back through
Studio.LoadSceneCoroutine and writes original-<case>-color.png, -map-geometry.png and
-map-depth-normals.png with map-trace.json and status.json. The zip of that folder plus unity.log
and LogOutput.log lands in --output with run.json and a manifest.json of hashes. The player root
is always removed and nothing in C:\\Illusion\\Koikatsu is written.

`oracle` (phase C, ST-A11 slice 2) runs the same probe through the same transport with
already-authored records (--scene <case>=<scene png>, uploaded as reload-oracle-<case>.png), so
the player authors nothing: it reads each record back and writes oracle-<case>-clean-color.png
(Camera.main without its image effects) and Unity's decoded lightmap irradiance per pixel,
oracle-<case>-irradiance.f32 (lights at intensity 0) and -irradiance-lit.f32 (lights as authored),
with oracle-trace.json. The float images are gzipped on arrival (<name>.f32.gz); manifest.json
lists the received files, and run.json each raw image's SHA-256 and size.

`map34` (ST-A11 slice 3) is phases B and C for map 34 in the same single exec: --showoff is uploaded
as reload-map34-showoff.png, which selects the probe's map 34 mode. The player authors
scene-map34-day.png (map transform nonzero, sun type day), scene-map34-evening.png and
scene-map34-night.png (reset transform) and scene-map34-showoff.png (map 34 added to the character
scene), reads each back, and writes per case the phase B images and the oracle images, including
oracle-<case>-classes.png, -sky.rgba.f32 and -particles.rgba.f32, all traced in map-trace.json.
"""
from __future__ import annotations
import argparse, fnmatch, gzip, hashlib, http.server, io, json, re, subprocess, threading, uuid, zipfile
from pathlib import Path, PurePosixPath
from original_wear_probe import Endpoint, bootstrap, errno_count, extract, fresh_root, guarded

ROOT = Path(__file__).resolve().parents[2]
FETCH_ROOT = r'C:\\Temp\\IkkokuMapFetch-[0-9a-f]{32}'
# Map_00 rows 33/34 (studio/info/00.unity3d): the two Studio-only maps, no vanish colliders.
DEFAULT_FILES = ('abdata/studio/map/bushitu.unity3d', 'abdata/studio/map/akikyoushitu.unity3d', 'abdata/abdata')
DEFAULT_GLOBS = ('abdata/studio/info/*.unity3d',)
MAX_FETCH_BYTES = 256 * 1024 * 1024
# One upload (a batch zip): below original_wear_probe's 1 GiB endpoint bound with room for the zip framing.
BATCH_BYTES = 900 * 1024 * 1024
UPLOAD_BOUND = 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
TREE_MAX_BYTES = 4 * 1024 * 1024 * 1024
# The folders the fetch scans before and after (read only): the bundles and the user's scenes.
FETCH_SCANS = (('abdata', 'abdata'), ('scenes', r'UserData\studio\scene'))
RECORD_UPLOAD = 'fetch-record.json'
BATCH_UPLOAD = re.compile(r'fetch-([1-9][0-9]{0,3})\.zip')
TREE_LABEL = re.compile(r'[a-z0-9]+(-[a-z0-9]+)*')
FILE_PATTERN = re.compile(r'[A-Za-z0-9_.*?-]+')


def digest(data): return hashlib.sha256(data).hexdigest()
def dump(path, value): path.write_text(json.dumps(value, indent=2, allow_nan=False, ensure_ascii=False) + '\n')


def private(path):
    """`path` resolved, refused unless it lies in the ignored .local directory or under the
    target of a symlink placed directly in it (a worktree's links to the main checkout)."""
    local = ROOT / '.local'
    roots = [local.resolve()] + ([entry.resolve() for entry in local.iterdir() if entry.is_symlink()] if local.is_dir() else [])
    resolved = Path(path).resolve()
    if not any(resolved.is_relative_to(root) for root in roots): raise ValueError('Outputs must stay under .local')
    return resolved


def checked_relative(value):
    """A game-relative path with forward slashes, no drive, root or '..' segment, and only
    characters that need no quoting inside the PowerShell single-quoted lists."""
    path = PurePosixPath(value)
    if not re.fullmatch(r'[A-Za-z0-9_./ -]+', value or '') or path.is_absolute() or any(p in ('', '.', '..') for p in value.split('/')):
        raise ValueError(f'Not a plain game-relative path: {value!r}')
    return path.as_posix()


def checked_tree(value):
    """--tree <label>:<dir>/<pattern>: a plain label (the local folder), a plain game-relative
    directory and a file-name pattern, e.g. scenes:UserData/studio/scene/*.png."""
    label, sep, rest = (value or '').partition(':')
    directory, _, pattern = rest.rpartition('/')
    if not sep or not TREE_LABEL.fullmatch(label) or label == 'source' or not FILE_PATTERN.fullmatch(pattern or ''):
        raise ValueError(f'--tree wants <label>:<dir>/<pattern>: {value!r}')
    return label, checked_relative(directory), pattern


def checked_found(path, directory, pattern, recursive):
    """A path the guest found under `directory` (forward slashes): below it, no drive, empty,
    '.' or '..' segment, backslash, colon or control character, and a leaf that matches
    `pattern` (case-insensitive, as Windows). One directory deep unless `recursive`. Names
    outside ASCII are allowed (a user's folders); they travel in the UTF-8 record only."""
    prefix = directory + '/'
    below = path[len(prefix):] if isinstance(path, str) and path.startswith(prefix) else None
    parts = below.split('/') if below else []
    if (not parts or any(p in ('', '.', '..') for p in parts) or any(c in path for c in '\\:') or any(ord(c) < 32 for c in path)
            or (not recursive and len(parts) != 1) or not fnmatch.fnmatchcase(parts[-1].casefold(), pattern.casefold())):
        raise ValueError(f'Unexpected fetched path for {directory}/{pattern}')
    return below


def fetch_script(root, base, files, globs, trees=(), limit=MAX_FETCH_BYTES, batch=BATCH_BYTES, total=MAX_TOTAL_BYTES,
                 tree_max=TREE_MAX_BYTES):
    """The whole fetch phase (see the module docstring). `files` are exact relative paths,
    `globs` one-directory wildcards and `trees` (label, dir, pattern) recursive ones; all resolve
    under C:\\Illusion\\Koikatsu and are only read there."""
    if not re.fullmatch(FETCH_ROOT, root): raise ValueError('Unknown private fetch root')
    for value in list(files) + list(globs): checked_relative(value.replace('*', 'x'))
    for label, directory, pattern in trees:
        checked_tree(f'{label}:{directory}/{pattern}')
    if not 0 < batch < UPLOAD_BOUND or batch < limit: raise ValueError('A batch must hold the largest file and fit one upload')
    quoted = lambda values: '@(' + ','.join("'" + v.replace('/', '\\') + "'" for v in values) + ')'
    tree_list = '@(' + ','.join("@('" + label + "','" + d.replace('/', '\\') + "','" + p + "')" for label, d, p in trees) + ')'
    scans = '@(' + ','.join("@('" + label + "','" + d + "')" for label, d in FETCH_SCANS) + ')'
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$src='C:\\Illusion\\Koikatsu'\n"
            + "$files=" + quoted(files) + ";$globs=" + quoted(globs) + ";$trees=" + tree_list + ";$scans=" + scans + "\n"
            + f"$limit={limit};$batch={batch};$total={total};$treeMax={tree_max}\n"
            + r"""$r=[ordered]@{root=$root;player='none: no player run, no player root, no junctions';sets=[ordered]@{};batches=@()}
$rec=[ordered]@{files=@();missing=@()}
function Scan{$o=[ordered]@{};foreach($s in $scans){$p="$src\$($s[1])";if(-not(Test-Path -LiteralPath $p)){$o[$s[0]]='absent';continue}
$f=@(Get-ChildItem -LiteralPath $p -Recurse -File -Force|Sort-Object FullName);$d=@(Get-ChildItem -LiteralPath $p -Recurse -Directory -Force)
$t=($f|ForEach-Object{$_.FullName.Substring($p.Length+1)+"`t"+$_.Length+"`t"+$_.LastWriteTimeUtc.ToString('o')}) -join "`n"
$h=[Security.Cryptography.SHA256]::Create();$x=($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))|ForEach-Object{$_.ToString('x2')}) -join ''
$o[$s[0]]=[ordered]@{files=$f.Count;dirs=$d.Count;bytes=[int64]($f|Measure-Object Length -Sum).Sum;listingSHA256=$x}};$o}
function Put($path,$name){$q=[Net.HttpWebRequest]::Create($base+$name);$q.Method='PUT';$q.AllowWriteStreamBuffering=$false
$q.ContentType='application/octet-stream';$q.ContentLength=(Get-Item -LiteralPath $path).Length;$q.Timeout=3600000;$q.ReadWriteTimeout=3600000
$s=$q.GetRequestStream();$f=[IO.File]::OpenRead($path);try{$f.CopyTo($s,1048576)}finally{$f.Close();$s.Close()};$q.GetResponse().Close()}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()}
if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
try{
$r.scanBefore=Scan
$items=New-Object Collections.ArrayList
function Want($set,$rel){$full="$src\$rel";if(-not(Test-Path -LiteralPath $full -PathType Leaf)){$rec.missing+=,@($set,$rel);return};[void]$items.Add(@($set,$rel,(Get-Item -LiteralPath $full)))}
foreach($rel in $files){Want 'files' $rel}
foreach($g in $globs){$d=Split-Path $g -Parent;$f=Split-Path $g -Leaf;foreach($i in @(Get-ChildItem -LiteralPath "$src\$d" -Filter $f -File|Where-Object{$_.Name -like $f}|Sort-Object Name)){Want ($g -replace '\\','/') "$d\$($i.Name)"}}
foreach($t in $trees){$d="$src\$($t[1])";if(-not(Test-Path -LiteralPath $d -PathType Container)){$rec.missing+=,@($t[0],$t[1]);continue}
foreach($i in @(Get-ChildItem -LiteralPath $d -Filter $t[2] -File -Recurse -Force|Where-Object{$_.Name -like $t[2]}|Sort-Object FullName)){
if(-not $i.FullName.StartsWith("$src\",[StringComparison]::OrdinalIgnoreCase)){throw 'A tree file lies outside the game folder'};Want $t[0] $i.FullName.Substring($src.Length+1)}}
$sum=[int64]0;$over=@()
foreach($i in $items){$n=$i[0];if(-not $r.sets.Contains($n)){$r.sets[$n]=[ordered]@{files=0;bytes=[int64]0;largest=[int64]0}}
$e=$r.sets[$n];$e.files+=1;$e.bytes+=$i[2].Length;if($i[2].Length -gt $e.largest){$e.largest=$i[2].Length};$sum+=$i[2].Length;if($i[2].Length -gt $limit){$over+=,$i}}
$r.listedFiles=$items.Count;$r.listedBytes=$sum;$r.missing=$rec.missing.Count
if($over.Count){$r.stopped="$($over.Count) file(s) exceed the per-file bound $limit"}
elseif($sum -gt $total){$r.stopped="the listing ($sum bytes) exceeds the total bound $total"}
else{foreach($t in $trees){if($r.sets.Contains($t[0]) -and $r.sets[$t[0]].bytes -gt $treeMax){$r.stopped="tree $($t[0]) ($($r.sets[$t[0]].bytes) bytes) exceeds $treeMax"}}}
New-Item -ItemType Directory $root|Out-Null
Add-Type -AssemblyName System.IO.Compression;Add-Type -AssemblyName System.IO.Compression.FileSystem
$k=0;$i=0
while(-not $r.stopped -and $i -lt $items.Count){
$k++;$dir="$root\b$k";New-Item -ItemType Directory $dir|Out-Null;$size=[int64]0;$n=0
while($i -lt $items.Count -and ($n -eq 0 -or $size+$items[$i][2].Length -le $batch)){
$set=$items[$i][0];$rel=$items[$i][1];$item=$items[$i][2];$full="$src\$rel";$name='f{0:d5}' -f $i
$hash=Hash $full;Copy-Item -LiteralPath $full "$dir\$name";if((Hash "$dir\$name") -ne $hash){throw "Copy hash differs: $rel"}
$rec.files+=[ordered]@{path=($rel -replace '\\','/');set=$set;name=$name;batch=$k;bytes=$item.Length;sha256=$hash;lastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}
$size+=$item.Length;$n++;$i++}
$z="$root\fetch-$k.zip";[IO.Compression.ZipFile]::CreateFromDirectory($dir,$z,[IO.Compression.CompressionLevel]::NoCompression,$false)
$r.batches+=[ordered]@{batch=$k;files=$n;bytes=$size;zipSHA256=(Hash $z);zipBytes=(Get-Item -LiteralPath $z).Length}
Put $z "fetch-$k.zip";Remove-Item -LiteralPath $dir -Recurse -Force;Remove-Item -LiteralPath $z -Force}
$rec.sets=$r.sets;$j="$root\fetch-record.json"
[IO.File]::WriteAllText($j,([PSCustomObject]$rec|ConvertTo-Json -Compress -Depth 6),(New-Object Text.UTF8Encoding $false))
$r.recordSHA256=Hash $j;$r.recordBytes=(Get-Item -LiteralPath $j).Length;Put $j 'fetch-record.json'
}catch{$r.error=$_.ToString()}
finally{
if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
$r.removed=-not(Test-Path -LiteralPath $root)
$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
try{$r.scanAfter=Scan}catch{$r.scanAfterError=$_.ToString()}
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 6
""")


class FetchEndpoint:
    """Serves run.ps1 and accepts each fetch upload once: fetch-<k>.zip (the batches) and
    fetch-record.json, each at most UPLOAD_BOUND bytes with a Content-Length, streamed to
    `incoming` with its SHA-256 computed on the way; the total is bounded by `total`."""
    def __init__(self, address, files, incoming, total):
        self.token, self.files, self.incoming, self.total = uuid.uuid4().hex, files, incoming, total
        self.uploads, self.received, self.lock = {}, 0, threading.Lock()
        endpoint = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def name(self):
                prefix = '/' + endpoint.token + '/'
                return self.path[len(prefix):] if self.path.startswith(prefix) else None

            def do_GET(self):
                name = self.name()
                if name not in endpoint.files: self.send_error(404); return
                data = endpoint.files[name]
                self.send_response(200); self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

            def do_PUT(self):
                name = self.name()
                length = int(self.headers.get('Content-Length') or -1)
                with endpoint.lock:
                    allowed = name == RECORD_UPLOAD or (name is not None and BATCH_UPLOAD.fullmatch(name) is not None)
                    if not allowed or name in endpoint.uploads or not 0 < length <= UPLOAD_BOUND \
                            or endpoint.received + length > endpoint.total:
                        self.send_error(403); return
                    endpoint.uploads[name] = None; endpoint.received += length
                path, hasher, left = endpoint.incoming / name, hashlib.sha256(), length
                with open(path, 'wb') as out:
                    while left:
                        chunk = self.rfile.read(min(left, 1 << 20))
                        if not chunk: break
                        hasher.update(chunk); out.write(chunk); left -= len(chunk)
                if left: path.unlink(); self.send_error(400); return
                endpoint.uploads[name] = dict(path=path, bytes=length, sha256=hasher.hexdigest())
                self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()

            def log_message(self, *args): pass

        self.server = http.server.ThreadingHTTPServer((address, 0), Handler)
        self.base = f'http://{address}:{self.server.server_port}/{self.token}/'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self): self.thread.start(); return self
    def __exit__(self, *args): self.server.shutdown(); self.server.server_close()


def destination(output, record, files, globs, trees):
    """Where one fetched file lands: <output>/source/<path> for a requested file or a glob's
    match, <output>/<label>/<path below the tree's directory> for a tree's."""
    path, kind = record.get('path'), record.get('set')
    if kind == 'files' and path in files:
        return output / 'source' / checked_relative(path)
    if kind in globs:
        directory, _, pattern = kind.rpartition('/')
        checked_found(path, directory, pattern, recursive=False)
        return output / 'source' / checked_relative(path)
    for label, directory, pattern in trees:
        if kind == label:
            return output / label / checked_found(path, directory, pattern, recursive=True)
    raise ValueError(f'A fetched file names a set that was not requested: {kind!r}')


def place(uploads, guest, record, output, files, globs, trees):
    """Checks every batch zip against the guest summary and every entry against the record
    (exactly the recorded index names, bytes and hashes), writes each file to its destination
    and deletes the zip. Returns the file records with the local path and hash added."""
    by_batch = {}
    for entry in record['files']:
        by_batch.setdefault(entry['batch'], {})[entry['name']] = entry
    if sorted(by_batch) != sorted(b['batch'] for b in guest.get('batches', [])):
        raise ValueError('The record and the guest summary list different batches')
    placed = []
    for batch in guest['batches']:
        upload = uploads.get(f"fetch-{batch['batch']}.zip")
        if upload is None or upload['sha256'] != batch['zipSHA256'] or upload['bytes'] != batch['zipBytes']:
            raise ValueError(f"Batch {batch['batch']}: upload missing or different from the guest zip")
        expected = by_batch[batch['batch']]
        with zipfile.ZipFile(upload['path']) as archive:
            if sorted(archive.namelist()) != sorted(expected): raise ValueError('Archive does not hold exactly the recorded files')
            for name in sorted(expected):
                entry = dict(expected[name])
                target = destination(output, entry, files, globs, trees)
                hasher, size = hashlib.sha256(), 0
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, open(target, 'wb') as out:
                    for chunk in iter(lambda: source.read(1 << 20), b''):
                        hasher.update(chunk); out.write(chunk); size += len(chunk)
                if size != entry['bytes'] or hasher.hexdigest() != entry['sha256']:
                    target.unlink(); raise ValueError(f"Fetched file differs from the guest record: {name}")
                with open(target, 'rb') as check:
                    local = hashlib.file_digest(check, 'sha256').hexdigest()
                entry.update(localPath=str(target), localSHA256=local)
                placed.append(entry)
        upload['path'].unlink()
    return sorted(placed, key=lambda r: (r['set'], r['path']))


def fetch(args):
    output = private(args.output)
    if (output / 'fetch.json').exists(): raise RuntimeError(f'{output}/fetch.json exists: fetch into a new output folder')
    named = args.file or args.glob or args.tree
    files = [checked_relative(f) for f in (args.file or ([] if named else DEFAULT_FILES))]
    globs = list(args.glob or ([] if named else DEFAULT_GLOBS))
    for g in globs: checked_relative(g.replace('*', 'x'))
    trees = [checked_tree(t) for t in (args.tree or [])]
    if len({t[0] for t in trees}) != len(trees): raise ValueError('--tree labels must differ')
    root = r'C:\Temp\IkkokuMapFetch-' + uuid.uuid4().hex
    script_bounds = dict(limit=MAX_FETCH_BYTES, batch=args.batch_bytes, total=args.max_total_bytes, tree_max=args.tree_max_bytes)
    fetch_script(root, 'http://check/', files, globs, trees, **script_bounds)  # refuses bad arguments before any VM call
    record = dict(vm=args.vm, root=root, errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  requestedFiles=files, requestedGlobs=globs, requestedTrees=[f'{l}:{d}/{p}' for l, d, p in trees],
                  bounds=script_bounds, source=r'C:\Illusion\Koikatsu (read only)', player='none (no player root, no junctions)',
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint; batch zips and the record PUT back')
    incoming = output / 'incoming'
    incoming.mkdir(parents=True, exist_ok=True)
    with FetchEndpoint(args.host_address, {}, incoming, args.max_total_bytes + UPLOAD_BOUND) as endpoint:
        script = fetch_script(root, endpoint.base, files, globs, trees, **script_bounds)
        endpoint.files['run.ps1'] = script.encode()
        (output / 'run.ps1').write_text(script.replace(endpoint.base, '<endpoint>/'))
        result = subprocess.run(['prlctl', 'exec', args.vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive',
                                 '-Command', bootstrap(endpoint.base)], text=True, capture_output=True, timeout=args.timeout)
        uploads = dict(endpoint.uploads)
    record['errnoAfter'] = errno_count()
    if result.returncode:
        record['execError'] = (result.stderr or result.stdout)[-4000:]; dump(output / 'fetch.json', record)
        raise RuntimeError('VM exec failed: ' + record['execError'])
    guest = json.loads(result.stdout.lstrip('\ufeff').strip())
    record['guest'] = guest
    upload = uploads.get(RECORD_UPLOAD)
    if upload is not None and (upload['sha256'] != guest.get('recordSHA256') or upload['bytes'] != guest.get('recordBytes')):
        dump(output / 'fetch.json', record); raise ValueError('The uploaded record differs from the guest summary')
    guest_record = json.loads(upload['path'].read_text(encoding='utf-8')) if upload else None
    if guest_record is not None:
        record['listing'] = dict(sets=guest_record.get('sets'), missing=guest_record.get('missing'))
    if guest.get('error'):
        dump(output / 'fetch.json', record); raise RuntimeError('Guest fetch failed: ' + guest['error'])
    if guest_record is None:
        dump(output / 'fetch.json', record); raise ValueError('The guest record was not uploaded')
    record['files'] = place(uploads, guest, guest_record, output, files, globs, trees)
    upload['path'].unlink()
    incoming.rmdir()
    dump(output / 'fetch.json', record)
    return dict(sets=guest.get('sets'), stopped=guest.get('stopped'), files=len(record['files']),
                bytes=sum(f['bytes'] for f in record['files']), missing=guest.get('missing'), batches=len(guest.get('batches', [])),
                removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                scansEqual=guest.get('scanBefore') is not None and guest.get('scanBefore') == guest.get('scanAfter'),
                errno=[record['errnoBefore'], record['errnoAfter']])


MAP_PROBE = Path(__file__).with_name('fixtures') / 'OriginalMapProbe.cs'
MAP_PROBE_NAMES = ('MapProbe.cs', 'IkkokuMapProbe.dll')
SHOWOFF_UPLOAD = 'reload-showoff.png'


MAP34_UPLOAD = 'reload-map34-showoff.png'
# The player root's junction targets, read only: file and directory counts, bytes and the newest write
# time of each, taken in the same run.ps1 before the player is set up and after the root is removed.
JUNCTION_SCAN = (r"""function Scan{$o=[ordered]@{};foreach($n in @('abdata','CharaStudio_Data')){$p="C:\Illusion\Koikatsu\$n";"""
                 r"""$f=@(Get-ChildItem -LiteralPath $p -Recurse -File -Force);$d=@(Get-ChildItem -LiteralPath $p -Recurse -Directory -Force);"""
                 r"""$o[$n]=[ordered]@{files=$f.Count;dirs=$d.Count;bytes=[int64]($f|Measure-Object Length -Sum).Sum;"""
                 r"""latestWriteUtc=($f|Sort-Object LastWriteTimeUtc|Select-Object -Last 1).LastWriteTimeUtc.ToString('o')}};$o}""")


def with_junction_scans(script):
    """`script` (once_script's run.ps1) with JUNCTION_SCAN recorded as scanBefore at the start and
    scanAfter after its cleanup, both in the guest's JSON."""
    head, sep, rest = script.partition('$r=[ordered]@{root=$root}\n')
    tail = '[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 4\n'
    if not sep or not rest.endswith(tail): raise ValueError('Unexpected run.ps1 layout')
    return head + sep + JUNCTION_SCAN + '\n$r.scanBefore=Scan\n' + rest[:-len(tail)] + 'try{$r.scanAfter=Scan}catch{$r.scanAfterError=$_.ToString()}\n' + tail


def scene_record(path, what):
    """A scene record's bytes; refused unless it is a PNG."""
    data = Path(path).read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError(f'{what} is not a PNG scene record: {path}')
    return data


def run_probe(args, uploads, record, floats, scans=False):
    """One `prlctl exec` of fixtures/OriginalMapProbe.cs with `uploads` ({reload-*.png name: bytes})
    placed next to the plug-in (original_scene_reload_probe.once_script). `record` adds to run.json;
    with `floats`, the received *.f32 images are gzipped (gzip_floats). Every guest hash is checked;
    manifest.json lists what arrived."""
    from original_scene_reload_probe import once_script  # the reload probe's one-exec transport
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    source = MAP_PROBE.read_bytes()
    root = fresh_root()
    record = dict(vm=args.vm, root=root, processID=0, sourceSHA256=digest(source), **record,
                  errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_scene_reload_probe.once_script)')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {MAP_PROBE_NAMES[0]: source, **uploads}
    with Endpoint(args.host_address, files, upload='reload.zip') as endpoint:
        script = once_script(root, endpoint.base, args.wait_seconds, list(uploads), *MAP_PROBE_NAMES)
        if scans: script = with_junction_scans(script)
        files['run.ps1'] = script.encode()
        (output / 'run.ps1').write_text(script.replace(endpoint.base, '<endpoint>/'))
        result = subprocess.run(['prlctl', 'exec', args.vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive',
                                 '-Command', bootstrap(endpoint.base)], text=True, capture_output=True, timeout=args.wait_seconds + 900)
        upload = endpoint.upload
    record['errnoAfter'] = errno_count()
    if result.returncode:
        record['execError'] = (result.stderr or result.stdout)[-4000:]; dump(output / 'run.json', record)
        raise RuntimeError('VM exec failed: ' + record['execError'])
    guest = json.loads(result.stdout.lstrip('\ufeff').strip())
    record.update(processID=int(guest.get('processID') or 0), guest=guest)
    if guest.get('source') not in (None, digest(source)): raise ValueError('Guest probe source hash differs')
    for name, data in uploads.items():
        if (guest.get('scenes') or {}).get(name) not in (None, digest(data)):
            raise ValueError('Guest showoff hash differs' if name == SHOWOFF_UPLOAD else 'Guest scene hash differs: ' + name)
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    if floats:
        record['floatImages'] = gzip_floats(output, names)
        names = [record['floatImages'][n]['file'] if n in record['floatImages'] else n for n in names]
    (output / 'probe-source.cs').write_bytes(source)
    dump(output / 'run.json', record)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json', 'probe-source.cs'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, processID=record['processID'], exited=guest.get('exited'), error=guest.get('error'),
                cleanupError=guest.get('cleanupError'), removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance), status=status)


def capture(args):
    """The whole VM phase B in one `prlctl exec` (see the module docstring)."""
    if (private(args.output) / 'run.json').exists(): raise RuntimeError(f'{args.output}/run.json exists: capture into a new output folder')
    showoff = scene_record(args.showoff, '--showoff')
    return run_probe(args, {SHOWOFF_UPLOAD: showoff}, dict(showoff=str(args.showoff), showoffSHA256=digest(showoff)), floats=False)


def map34(args):
    """Map 34's phases B and C in one `prlctl exec` (see the module docstring)."""
    if (private(args.output) / 'run.json').exists(): raise RuntimeError(f'{args.output}/run.json exists: run map34 into a new output folder')
    showoff = scene_record(args.showoff, '--showoff')
    result = run_probe(args, {MAP34_UPLOAD: showoff}, dict(mode='map34', showoff=str(args.showoff), showoffSHA256=digest(showoff)),
                       floats=True, scans=True)
    guest = json.loads((private(args.output) / 'run.json').read_text()).get('guest') or {}
    result.update(scanBefore=guest.get('scanBefore'), scanAfter=guest.get('scanAfter'),
                  scansEqual=guest.get('scanBefore') is not None and guest.get('scanBefore') == guest.get('scanAfter'))
    return result


ORACLE_CASE = re.compile(r'[a-z0-9]+(-[a-z0-9]+)*')


def oracle_scenes(items):
    """--scene <case>=<png> pairs: distinct plain case labels, each a PNG scene record."""
    scenes = {}
    for item in items:
        label, sep, path = item.partition('=')
        if not sep or not ORACLE_CASE.fullmatch(label) or label in scenes: raise ValueError(f'--scene wants a new <case>=<scene png>: {item!r}')
        data = Path(path).read_bytes()
        if not data.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError(f'--scene {label} is not a PNG scene record: {path}')
        scenes[label] = data
    if not scenes: raise ValueError('oracle needs at least one --scene')
    return scenes


def gzip_floats(output, names):
    """Replaces each received *.f32 image (float32 RGB, or RGBA for *.rgba.f32) by <name>.gz;
    returns {name: raw sha256, bytes}."""
    raw = {}
    for name in sorted(n for n in names if n.endswith('.f32')):
        data = (output / name).read_bytes()
        rgba = name.endswith('.rgba.f32')
        if len(data) % (16 if rgba else 12): raise ValueError(f'{name} is not float32 {"RGBA" if rgba else "RGB"}')
        raw[name] = dict(sha256=digest(data), bytes=len(data), file=name + '.gz')
        (output / (name + '.gz')).write_bytes(gzip.compress(data, compresslevel=9, mtime=0)); (output / name).unlink()
    return raw


def oracle(args):
    """Phase C in one `prlctl exec` (see the module docstring)."""
    if (private(args.output) / 'run.json').exists(): raise RuntimeError(f'{args.output}/run.json exists: run the oracle into a new output folder')
    scenes = oracle_scenes(args.scene)
    uploads = {f'reload-oracle-{label}.png': data for label, data in scenes.items()}
    return run_probe(args, uploads, dict(scenes={label: digest(data) for label, data in scenes.items()}), floats=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = p.add_subparsers(dest='command', required=True)
    f = commands.add_parser('fetch', help='copy named game files out for local reading (read only)')
    f.add_argument('--vm', default='Windows 11'); f.add_argument('--output', type=Path, required=True)
    f.add_argument('--file', action='append', help='exact game-relative path (repeatable); with no --file, --glob or --tree: '
                                                    'the two Studio maps and abdata/abdata')
    f.add_argument('--glob', action='append', help='one-directory wildcard (repeatable); with no --file, --glob or --tree: '
                                                    'abdata/studio/info/*.unity3d')
    f.add_argument('--tree', action='append', help='<label>:<dir>/<pattern>, recursive (repeatable); lands in <output>/<label>/')
    f.add_argument('--batch-bytes', type=int, default=BATCH_BYTES, help='bytes per uploaded batch zip (below 1 GiB)')
    f.add_argument('--max-total-bytes', type=int, default=MAX_TOTAL_BYTES, help='copy nothing when the listing exceeds this')
    f.add_argument('--tree-max-bytes', type=int, default=TREE_MAX_BYTES, help='copy nothing when one tree exceeds this')
    f.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    f.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    f.add_argument('--timeout', type=int, default=3600)
    c = commands.add_parser('capture', help='author the map fixtures in the original player and capture them (phase B)')
    c.add_argument('--vm', default='Windows 11'); c.add_argument('--output', type=Path, required=True)
    c.add_argument('--showoff', type=Path, required=True, help='a character scene record without a map; the player adds map 33 to it')
    c.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    c.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    c.add_argument('--wait-seconds', type=int, default=900, help='bound on the player run')
    o = commands.add_parser('oracle', help="read authored records back and measure Unity's lightmap irradiance (phase C)")
    o.add_argument('--vm', default='Windows 11'); o.add_argument('--output', type=Path, required=True)
    o.add_argument('--scene', action='append', required=True, help='<case>=<scene png> (repeatable), e.g. map33=scene-map33.png')
    o.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    o.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    o.add_argument('--wait-seconds', type=int, default=900, help='bound on the player run')
    m = commands.add_parser('map34', help='author, capture and measure the map 34 cases in the original player (phases B and C, slice 3)')
    m.add_argument('--vm', default='Windows 11'); m.add_argument('--output', type=Path, required=True)
    m.add_argument('--showoff', type=Path, required=True, help='a character scene record without a map; the player adds map 34 to it')
    m.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    m.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    m.add_argument('--wait-seconds', type=int, default=1800, help='bound on the player run')
    args = p.parse_args()
    run = dict(fetch=fetch, capture=capture, oracle=oracle, map34=map34)[args.command]
    print(json.dumps(run(args), indent=2))


if __name__ == '__main__': main()
