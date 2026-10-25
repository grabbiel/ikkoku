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
"""
from __future__ import annotations
import argparse, hashlib, io, json, re, subprocess, uuid, zipfile
from pathlib import Path, PurePosixPath
from original_wear_probe import Endpoint, bootstrap, errno_count, guarded

ROOT = Path(__file__).resolve().parents[2]
FETCH_ROOT = r'C:\\Temp\\IkkokuMapFetch-[0-9a-f]{32}'
# Map_00 rows 33/34 (studio/info/00.unity3d): the two Studio-only maps, no vanish colliders.
DEFAULT_FILES = ('abdata/studio/map/bushitu.unity3d', 'abdata/studio/map/akikyoushitu.unity3d', 'abdata/abdata')
DEFAULT_GLOBS = ('abdata/studio/info/*.unity3d',)
MAX_FETCH_BYTES = 256 * 1024 * 1024


def digest(data): return hashlib.sha256(data).hexdigest()
def dump(path, value): path.write_text(json.dumps(value, indent=2, allow_nan=False, ensure_ascii=False) + '\n')


def checked_relative(value):
    """A game-relative path with forward slashes, no drive, root or '..' segment."""
    path = PurePosixPath(value)
    if not value or '\\' in value or ':' in value or path.is_absolute() or any(p in ('', '.', '..') for p in path.parts):
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
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / '.local').resolve()): raise ValueError('Outputs must stay under .local')
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
    args = p.parse_args()
    print(json.dumps(fetch(args), indent=2))


if __name__ == '__main__': main()
