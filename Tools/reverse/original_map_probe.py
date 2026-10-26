#!/usr/bin/env python3
"""ST-A11 maps: read-only VM phases for the CharaStudio map slice, each in ONE `prlctl exec`.

`fetch` copies named files out of the installed game for local reading and conversion:
the Studio map scene bundles, every `abdata/studio/info/*.unity3d` (the `Map_XX` catalogs
`Studio.Info.LoadMapLoadInfo` reads) and the `abdata/abdata` AssetBundleManifest (bundle
dependencies). The exec command only fetches `run.ps1` from a temporary host-only HTTP
endpoint (original_wear_probe.py's transport). run.ps1 refuses to start while a
CharaStudio/Koikatu process runs, hashes each source file in place, copies it into a fresh
C:\\Temp\\IkkokuMapFetch-<32 hex> folder, zips and PUTs that folder back, and always removes
it. Nothing in C:\\Illusion\\Koikatsu is written. The Parallels errno-24 count must equal
--errno-baseline before the exec; it is recorded before and after.

The local copies land under <output>/source/<relative path> with a fetch.json that records
each file's guest SHA-256, the local SHA-256 (must match) and its size.

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
"""
from __future__ import annotations
import argparse, gzip, hashlib, io, json, re, subprocess, uuid, zipfile
from pathlib import Path, PurePosixPath
from original_wear_probe import Endpoint, bootstrap, errno_count, extract, fresh_root, guarded

ROOT = Path(__file__).resolve().parents[2]
FETCH_ROOT = r'C:\\Temp\\IkkokuMapFetch-[0-9a-f]{32}'
# Map_00 rows 33/34 (studio/info/00.unity3d): the two Studio-only maps, no vanish colliders.
DEFAULT_FILES = ('abdata/studio/map/bushitu.unity3d', 'abdata/studio/map/akikyoushitu.unity3d', 'abdata/abdata')
DEFAULT_GLOBS = ('abdata/studio/info/*.unity3d',)
MAX_FETCH_BYTES = 256 * 1024 * 1024


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


def fetch_script(root, base, files, globs):
    """The whole fetch phase. `files` are exact relative paths, `globs` one-directory
    wildcards; both resolve under C:\\Illusion\\Koikatsu and are only read there."""
    if not re.fullmatch(FETCH_ROOT, root): raise ValueError('Unknown private fetch root')
    for value in list(files) + list(globs): checked_relative(value.replace('*', 'x'))
    quoted = lambda values: '@(' + ','.join("'" + v.replace('/', '\\') + "'" for v in values) + ')'
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$src='C:\\Illusion\\Koikatsu'\n"
            + "$files=" + quoted(files) + ";$globs=" + quoted(globs) + ";$limit=" + str(MAX_FETCH_BYTES) + "\n"
            + r"""$r=[ordered]@{root=$root;files=@();missing=@()}
if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
try{
New-Item -ItemType Directory $root|Out-Null
$wanted=@($files)
foreach($g in $globs){$d=Split-Path $g -Parent;$f=Split-Path $g -Leaf;foreach($i in @(Get-ChildItem -LiteralPath "$src\$d" -Filter $f -File|Sort-Object Name)){$wanted+="$d\$($i.Name)"}}
foreach($rel in $wanted){
$full="$src\$rel"
if(-not(Test-Path -LiteralPath $full -PathType Leaf)){$r.missing+=$rel;continue}
$item=Get-Item -LiteralPath $full
if($item.Length -gt $limit){throw "Exceeds fetch bound: $rel"}
$hash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
$name=($rel -replace '\\','__')
Copy-Item -LiteralPath $full "$root\$name"
$copy=(Get-FileHash -LiteralPath "$root\$name" -Algorithm SHA256).Hash.ToLower()
if($copy -ne $hash){throw "Copy hash differs: $rel"}
$r.files+=[ordered]@{path=($rel -replace '\\','/');name=$name;bytes=$item.Length;sha256=$hash;lastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}
}
Add-Type -AssemblyName System.IO.Compression.FileSystem;$z="$root.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($root,$z);$r.zipSHA256=(Get-FileHash -LiteralPath $z -Algorithm SHA256).Hash.ToLower();$r.zipBytes=(Get-Item -LiteralPath $z).Length
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'fetch.zip')|Out-Null
}catch{$r.error=$_.ToString()}
finally{
foreach($p in @($root,"$root.zip")){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force}}
$r.removed=-not((Test-Path -LiteralPath $root) -or (Test-Path -LiteralPath "$root.zip"))
$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 4
""")


def place(upload, guest, output):
    """Writes each fetched file to output/source/<relative path> after checking it against the
    guest's hash; returns the fetch records with the local path and hash added."""
    by_name = {record['name']: record for record in guest['files']}
    placed = []
    with zipfile.ZipFile(io.BytesIO(upload)) as archive:
        names = archive.namelist()
        if sorted(names) != sorted(by_name): raise ValueError('Archive does not hold exactly the recorded files')
        for name in names:
            record = dict(by_name[name])
            relative = checked_relative(record['path'])
            data = archive.read(name)
            if len(data) != record['bytes'] or digest(data) != record['sha256']:
                raise ValueError(f'Fetched file differs from the guest record: {relative}')
            destination = output / 'source' / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            record.update(localPath=str(destination), localSHA256=digest(destination.read_bytes()))
            placed.append(record)
    return sorted(placed, key=lambda r: r['path'])


def fetch(args):
    output = private(args.output)
    if (output / 'fetch.json').exists(): raise RuntimeError(f'{output}/fetch.json exists: fetch into a new output folder')
    files = [checked_relative(f) for f in (args.file or DEFAULT_FILES)]
    globs = list(args.glob if args.glob is not None else DEFAULT_GLOBS)
    root = r'C:\Temp\IkkokuMapFetch-' + uuid.uuid4().hex
    record = dict(vm=args.vm, root=root, errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  requestedFiles=files, requestedGlobs=globs, source=r'C:\Illusion\Koikatsu (read only)',
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint')
    output.mkdir(parents=True, exist_ok=True)
    with Endpoint(args.host_address, {}, upload='fetch.zip') as endpoint:
        script = fetch_script(root, endpoint.base, files, globs)
        endpoint.files['run.ps1'] = script.encode()
        result = subprocess.run(['prlctl', 'exec', args.vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive',
                                 '-Command', bootstrap(endpoint.base)], text=True, capture_output=True, timeout=args.timeout)
        upload = endpoint.upload
    record['errnoAfter'] = errno_count()
    if result.returncode:
        record['execError'] = (result.stderr or result.stdout)[-4000:]; dump(output / 'fetch.json', record)
        raise RuntimeError('VM exec failed: ' + record['execError'])
    guest = json.loads(result.stdout.lstrip('\ufeff').strip())
    record['guest'] = {k: v for k, v in guest.items() if k != 'files'}
    if guest.get('error'):
        dump(output / 'fetch.json', record); raise RuntimeError('Guest fetch failed: ' + guest['error'])
    if upload is None or digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'):
        dump(output / 'fetch.json', record); raise ValueError('Upload missing or different from the guest zip')
    record['files'] = place(upload, guest, output)
    dump(output / 'fetch.json', record)
    return dict(files=len(record['files']), bytes=sum(f['bytes'] for f in record['files']), missing=guest.get('missing'),
                removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                errno=[record['errnoBefore'], record['errnoAfter']])


MAP_PROBE = Path(__file__).with_name('fixtures') / 'OriginalMapProbe.cs'
MAP_PROBE_NAMES = ('MapProbe.cs', 'IkkokuMapProbe.dll')
SHOWOFF_UPLOAD = 'reload-showoff.png'


def capture(args):
    """The whole VM phase B in one `prlctl exec` (see the module docstring)."""
    from original_scene_reload_probe import once_script  # the reload probe's one-exec transport
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: capture into a new output folder')
    source = MAP_PROBE.read_bytes(); showoff = args.showoff.read_bytes()
    if not showoff.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError(f'--showoff is not a PNG scene record: {args.showoff}')
    root = fresh_root()
    record = dict(vm=args.vm, root=root, processID=0, sourceSHA256=digest(source), showoff=str(args.showoff), showoffSHA256=digest(showoff),
                  errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_scene_reload_probe.once_script)')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {MAP_PROBE_NAMES[0]: source, SHOWOFF_UPLOAD: showoff}
    with Endpoint(args.host_address, files, upload='reload.zip') as endpoint:
        script = once_script(root, endpoint.base, args.wait_seconds, [SHOWOFF_UPLOAD], *MAP_PROBE_NAMES)
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
    if (guest.get('scenes') or {}).get(SHOWOFF_UPLOAD) not in (None, digest(showoff)): raise ValueError('Guest showoff hash differs')
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    (output / 'probe-source.cs').write_bytes(source)
    dump(output / 'run.json', record)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json', 'probe-source.cs'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, processID=record['processID'], exited=guest.get('exited'), error=guest.get('error'),
                cleanupError=guest.get('cleanupError'), removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance), status=status)


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
    """Replaces each received *.f32 image by <name>.gz; returns {name: raw sha256, bytes}."""
    raw = {}
    for name in sorted(n for n in names if n.endswith('.f32')):
        data = (output / name).read_bytes()
        if len(data) % 12: raise ValueError(f'{name} is not float32 RGB')
        raw[name] = dict(sha256=digest(data), bytes=len(data), file=name + '.gz')
        (output / (name + '.gz')).write_bytes(gzip.compress(data, compresslevel=9, mtime=0)); (output / name).unlink()
    return raw


def oracle(args):
    """Phase C in one `prlctl exec` (see the module docstring)."""
    from original_scene_reload_probe import once_script  # the reload probe's one-exec transport
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the oracle into a new output folder')
    source = MAP_PROBE.read_bytes(); scenes = oracle_scenes(args.scene)
    uploads = {f'reload-oracle-{label}.png': data for label, data in scenes.items()}
    root = fresh_root()
    record = dict(vm=args.vm, root=root, processID=0, sourceSHA256=digest(source), scenes={label: digest(data) for label, data in scenes.items()},
                  errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_scene_reload_probe.once_script)')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {MAP_PROBE_NAMES[0]: source, **uploads}
    with Endpoint(args.host_address, files, upload='reload.zip') as endpoint:
        script = once_script(root, endpoint.base, args.wait_seconds, list(uploads), *MAP_PROBE_NAMES)
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
        if (guest.get('scenes') or {}).get(name) not in (None, digest(data)): raise ValueError('Guest scene hash differs: ' + name)
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
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


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = p.add_subparsers(dest='command', required=True)
    f = commands.add_parser('fetch', help='copy named game files out for local reading (read only)')
    f.add_argument('--vm', default='Windows 11'); f.add_argument('--output', type=Path, required=True)
    f.add_argument('--file', action='append', help='exact game-relative path (repeatable); default: the two Studio maps and abdata/abdata')
    f.add_argument('--glob', action='append', help='one-directory wildcard (repeatable); default: abdata/studio/info/*.unity3d')
    f.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    f.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    f.add_argument('--timeout', type=int, default=900)
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
    args = p.parse_args()
    run = dict(fetch=fetch, capture=capture, oracle=oracle)[args.command]
    print(json.dumps(run(args), indent=2))


if __name__ == '__main__': main()
