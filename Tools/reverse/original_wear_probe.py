#!/usr/bin/env python3
"""ST-C03: run OriginalCharacterProbe once in a fresh private CharaStudio root, in ONE
`prlctl exec`, and collect its outputs.

The exec command only fetches `run.ps1` from a temporary host-only HTTP endpoint (the
command stays far below Parallels' command-length limit) and runs it in the signed-in
user's session. run.ps1 then, inside that one exec:
1. refuses to start when a CharaStudio/Koikatu process already runs or the root exists;
2. sets up C:\\Temp\\IkkokuShaderProbe-<32 hex> exactly as original_character_probe.py
   does (copies of CharaStudio.exe, the loader and BepInEx core; junctions to abdata and
   CharaStudio_Data), downloads the probe source, the model variant, the
   character-settings.tsv and shader-properties.tsv (the material properties to record,
   from --shaders as original_character_probe.py builds it), and compiles the probe;
3. starts the player and waits a bounded time for it to exit, then stops anything still
   running from the root by its path;
4. zips the probe folder with the Unity and BepInEx logs and PUTs it back to the
   endpoint;
5. always (finally): removes the two junctions with `rmdir` (link only, after checking
   they are reparse points), then the root, and reports leftover game processes.
Nothing in C:\\Illusion\\Koikatsu is written. The Parallels errno-24 count must equal
--errno-baseline before the exec; it is recorded before and after.

The output folder has the original_character_probe.py collect layout (run.json,
status.json, manifest.json, the probe files, unity.log, LogOutput.log), so
compare_original_model.py and compare_original_frame.py read it unchanged.
"""
from __future__ import annotations
import argparse, hashlib, http.server, io, json, re, subprocess, threading, uuid, zipfile
from pathlib import Path
from original_character_probe import PLAYER_SETUP, PLAYER_ROOT

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name('fixtures') / 'OriginalCharacterProbe.cs'
VARIANTS = ('female00', 'female200', 'male200')
UPLOAD_LIMIT = 1024 * 1024 * 1024
EXTRACT_LIMIT = 2 * UPLOAD_LIMIT


def digest(data): return hashlib.sha256(data).hexdigest()
def dump(path, value): path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def errno_count():
    return int(subprocess.run(['grep', '-c', 'errno: 24', '/Library/Logs/parallels.log'], capture_output=True, text=True).stdout.strip() or 0)


def guarded(baseline):
    count = errno_count()
    if count != baseline:
        raise RuntimeError(f'Parallels errno-24 count is {count}, baseline {baseline}; VM work stopped')
    return count


def shader_properties(folder):
    """original_character_probe.start's shader-properties.tsv: one `shader\tproperty\ttype`
    line per property of each translated program, so the probe records every texture
    and value the translated shaders read (not only its built-in list)."""
    lines = []
    for path in sorted(Path(folder).glob('*/program.json')):
        program = json.loads(path.read_text())
        lines.extend(program['name'] + '\t' + p['m_Name'] + '\t' + str(p['m_Type']) for p in program['properties'])
    if not lines: raise ValueError(f'No translated program properties under {folder}')
    return ('\n'.join(lines) + '\n').encode()


def run_script(root, base, wait_seconds):
    """The whole phase. `base` is the endpoint URL ending in the token and '/'."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root}\n"
            + r"""if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
function Fetch($name,$path){Invoke-WebRequest -UseBasicParsing -Uri ($base+$name) -OutFile $path;(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\')})}
try{
""" + PLAYER_SETUP + r"""
$p="$root\BepInEx\plugins";$r.source=Fetch 'CharacterProbe.cs' "$root\CharacterProbe.cs"
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuCharacterProbe.dll" /reference:$($refs -join ',') "$root\CharacterProbe.cs" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
New-Item -ItemType Directory "$p\character" -Force|Out-Null
$r.settings=Fetch 'character-settings.tsv' "$p\character\character-settings.tsv";$r.variant=Fetch 'model-variant.txt' "$p\model-variant.txt"
$r.properties=Fetch 'shader-properties.tsv' "$p\shader-properties.tsv"
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','768','-screen-height','1024','-logFile',"$root\unity.log") -PassThru
$r.processID=$x.Id;$r.exited=$x.WaitForExit(""" + str(int(wait_seconds) * 1000) + r""")
$left=Own;$left|Stop-Process -Force;$r.stopped=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 2
foreach($n in @('unity.log','BepInEx\LogOutput.log')){if(Test-Path -LiteralPath "$root\$n"){Copy-Item -LiteralPath "$root\$n" "$p\character\$(Split-Path $n -Leaf)"}}
Add-Type -AssemblyName System.IO.Compression.FileSystem;$z="$root\character.zip"
[IO.Compression.ZipFile]::CreateFromDirectory("$p\character",$z);$r.zipSHA256=(Get-FileHash -LiteralPath $z -Algorithm SHA256).Hash.ToLower();$r.zipBytes=(Get-Item -LiteralPath $z).Length
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'character.zip')|Out-Null
}catch{$r.error=$_.ToString()}
finally{
$left=Own;$left|Stop-Process -Force -ErrorAction SilentlyContinue;$r.stoppedAtCleanup=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 1
$kept=@()
foreach($j in @("$root\abdata","$root\CharaStudio_Data")){if(Test-Path -LiteralPath $j){if((Get-Item -LiteralPath $j -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd /c rmdir "$j"|Out-Null}if(Test-Path -LiteralPath $j){$kept+=$j}}}
if($kept.Count){$r.cleanupError='junctions not removed: '+($kept -join ', ')}elseif(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
$r.removed=-not(Test-Path -LiteralPath $root);$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 4
""")


def fresh_root():
    """A new private player root for a one-exec run. One-exec runs never reuse a root: they
    refuse an output folder that already holds run.json and always remove the root they made."""
    return r'C:\Temp\IkkokuShaderProbe-' + uuid.uuid4().hex


def bootstrap(base):
    """The only text on the prlctl command line: fetch run.ps1 and run it."""
    return ("$ErrorActionPreference='Stop';$s=Invoke-WebRequest -UseBasicParsing -Uri '" + base + "run.ps1';"
            "Invoke-Expression ([Text.Encoding]::UTF8.GetString($s.RawContentStream.ToArray()))")


class Endpoint:
    """Serves the named inputs and accepts one bounded PUT of `upload` (character.zip by
    default), under a random token."""
    def __init__(self, address, files, upload='character.zip'):
        self.token = uuid.uuid4().hex; self.files = files; self.upload = None; self.upload_name = upload
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
                if self.name() != endpoint.upload_name or endpoint.upload is not None: self.send_error(403); return
                if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                    data = bytearray()
                    while True:
                        size = int(self.rfile.readline().split(b';')[0].strip() or b'0', 16)
                        if size == 0: self.rfile.readline(); break
                        if len(data) + size > UPLOAD_LIMIT: self.send_error(413); return
                        data += self.rfile.read(size); self.rfile.readline()
                    endpoint.upload = bytes(data)
                else:
                    length = int(self.headers.get('Content-Length') or -1)
                    if not 0 < length <= UPLOAD_LIMIT: self.send_error(413); return
                    endpoint.upload = self.rfile.read(length)
                self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
            def log_message(self, *args): pass
        self.server = http.server.ThreadingHTTPServer((address, 0), Handler)
        self.base = f'http://{address}:{self.server.server_port}/{self.token}/'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
    def __enter__(self): self.thread.start(); return self
    def __exit__(self, *args): self.server.shutdown(); self.server.server_close()


def extract(data, output):
    names = []
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if any(Path(n).name != n or not n or n.startswith('.') for n in archive.namelist()): raise ValueError('Unexpected archive paths')
        if sum(i.file_size for i in archive.infolist()) > EXTRACT_LIMIT: raise ValueError('Capture exceeds extraction bound')
        names = archive.namelist(); archive.extractall(output)
    return names


def run(args):
    output = args.output
    if not output.resolve().is_relative_to((ROOT / '.local').resolve()): raise ValueError('Outputs must stay under .local')
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    output.mkdir(parents=True, exist_ok=True)
    settings = args.settings.read_bytes() if args.settings else b''
    properties = shader_properties(args.shaders) if args.shaders else b''
    source = SOURCE.read_bytes()
    root = fresh_root()
    record = dict(vm=args.vm, root=root, processID=0, sourceSHA256=digest(source), settingsSHA256=digest(settings), shaderPropertiesSHA256=digest(properties),
                  shaders=str(args.shaders) if args.shaders else None,
                  modelVariant=args.model_variant, currentUser=True, stopped=False, errnoBaseline=args.errno_baseline,
                  errnoBefore=guarded(args.errno_baseline), transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint')
    dump(output / 'run.json', record)
    files = {'CharacterProbe.cs': source, 'character-settings.tsv': settings, 'model-variant.txt': (args.model_variant + '\n').encode(),
             'shader-properties.tsv': properties}
    with Endpoint(args.host_address, files) as endpoint:
        script = run_script(root, endpoint.base, args.wait_seconds)
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
    record.update(processID=int(guest.get('processID') or 0), stopped=True, guest=guest)
    for name, key in [('CharacterProbe.cs', 'source'), ('character-settings.tsv', 'settings'), ('model-variant.txt', 'variant'),
                      ('shader-properties.tsv', 'properties')]:
        if guest.get(key) not in (None, digest(files[name])): raise ValueError('Guest input hash differs: ' + name)
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    dump(output / 'run.json', record)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, processID=record['processID'], exited=guest.get('exited'), error=guest.get('error'),
                cleanupError=guest.get('cleanupError'), removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance), status=status)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--vm', default='Windows 11'); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--settings', type=Path, help='character-settings.tsv (wear keys: clothes, clothesState, shoesType)')
    p.add_argument('--model-variant', choices=VARIANTS, default='female00')
    p.add_argument('--shaders', type=Path, help='translated programs (<family>/program.json) whose material properties the probe records')
    p.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    p.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    p.add_argument('--wait-seconds', type=int, default=600)
    print(json.dumps(run(p.parse_args()), indent=2))


if __name__ == '__main__': main()
