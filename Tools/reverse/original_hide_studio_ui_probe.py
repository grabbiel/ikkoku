#!/usr/bin/env python3
"""Observe one exact installed UI plugin in an owned isolated original player.

Only the copied player is started/stopped. Installed plugins/configuration stay
unchanged. Metadata and all observed state remain in ignored private evidence.
Run only with the shared original-player/app slot and orchestration lock.
"""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

from vm_source import powershell, ps_quote

ROOT = Path(__file__).resolve().parents[2]
SOURCE_SHA256 = 'ec11d03060502b60bf15742ef8e56b6bc804c10067e5a78ba368c7b62e3b117e'
SOURCE = r'C:\Illusion\Koikatsu\BepInEx\plugins\HideAllUI.Koikatu.dll'
OWNED_ROOT = re.compile(r'C:\\Temp\\IkkokuHideUIProbe-[0-9a-f]{32}')


def save(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def write_small(vm: str, path: str, data: bytes) -> None:
    """Idempotent bounded chunks, each comfortably below Parallels' command limit."""
    encoded = base64.b64encode(gzip.compress(data)).decode('ascii')
    chunks = [encoded[n:n + 800] for n in range(0, len(encoded), 800)]
    for index, chunk in enumerate(chunks):
        powershell(vm, '[IO.File]::WriteAllText(' + ps_quote(path + '.part' + str(index)) + ',' + ps_quote(chunk) + ')')
    script = "$encoded='';for($i=0;$i -lt " + str(len(chunks)) + ";$i++){$encoded += [IO.File]::ReadAllText(" + ps_quote(path + '.part') + "+$i)};"
    script += "$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String($encoded));$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);"
    script += "$o=[IO.File]::Create(" + ps_quote(path) + ");try{$g.CopyTo($o)}finally{$o.Dispose();$g.Dispose();$m.Dispose()}"
    powershell(vm, script)


def launch_owned(vm: str, root: str) -> int:
    if not OWNED_ROOT.fullmatch(root):
        raise ValueError('Unknown owned probe directory')
    script = "$ErrorActionPreference='Stop';$root=" + ps_quote(root) + r''' ;(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id'''
    result = subprocess.run(['prlctl', 'exec', vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive',
                             '-EncodedCommand', base64.b64encode(script.encode('utf-16le')).decode('ascii')],
                            text=True, capture_output=True, timeout=45)
    if result.returncode:
        raise RuntimeError(f'Owned-player launch failed ({result.returncode}): {result.stderr or result.stdout}')
    return int(result.stdout.lstrip('\ufeff').strip())


def stop_owned(vm: str, run: dict) -> dict:
    root = run['root']
    if not OWNED_ROOT.fullmatch(root):
        raise ValueError('Unknown owned probe directory')
    # The exact executable path prevents stopping an unrelated original player,
    # including when a PID was reused or a launch response was lost.
    script = "$ErrorActionPreference='Stop';$root=" + ps_quote(root) + r";$p=@(Get-Process | Where-Object {$_.ProcessName -eq 'CharaStudio' -and $_.Path -eq ($root+'\CharaStudio.exe')});$p|Stop-Process -Force;$remaining=@(Get-Process | Where-Object {$_.ProcessName -eq 'CharaStudio' -and $_.Path -eq ($root+'\CharaStudio.exe')});if($remaining.Count){throw 'Owned player remains'};[PSCustomObject]@{stopped=@($p|ForEach-Object{$_.Id});remaining=$remaining.Count}|ConvertTo-Json -Compress;exit 0"
    return json.loads(powershell(vm, script))


def fetch_report(vm: str, root: str) -> bytes:
    path = root + r'\BepInEx\plugins\hide-ui.json'
    script = "$ErrorActionPreference='Stop';$p=" + ps_quote(path) + ";$f=Get-Item -LiteralPath $p;if($f.Length -gt 2097152){throw 'Report exceeds 2 MiB'};"
    script += "$b=[IO.File]::ReadAllBytes($p);[PSCustomObject]@{length=$b.Length;data=[Convert]::ToBase64String($b)}|ConvertTo-Json -Compress"
    value = json.loads(powershell(vm, script))
    data = base64.b64decode(value['data'], validate=True)
    if len(data) != value['length'] or len(data) > 2 * 1024 * 1024:
        raise ValueError('Report transfer length changed')
    return data



def validate_report(report: dict) -> dict:
    """Fail closed on the bounded real-Unity trace; do not fit observed behavior."""
    def require(value, detail):
        if not value:
            raise ValueError('Original HideAllUI oracle: ' + detail)
    require(report.get('schemaVersion') == 1 and report.get('kind') == 'original-unity-hide-studio-ui', 'report identity')
    require(report.get('productName') == 'CharaStudio' and report.get('originalStartupHandlerObserved') is True
            and not report.get('error') and report.get('unityVersion') == '5.6.2f1', 'original Studio startup')
    names = ['original-startup', 'controlled-init', 'toggle-1', 'late-targets', 'toggle-2', 'toggle-3',
             'destroyed-targets', 'toggle-after-destroy', 'controlled-reinit', 'toggle-after-reinit']
    phases = report.get('phases', [])
    require([p.get('name') for p in phases] == names, 'exact phase sequence')
    by_name = dict(zip(names, phases))
    rows = {}
    identities = {}
    for phase in phases:
        targets = phase.get('targets', [])
        mapping = {r.get('key'): r for r in targets}
        require(len(mapping) == len(targets) and all(isinstance(k, str) and k for k in mapping), 'unique target keys')
        for key, row in mapping.items():
            identity = (row.get('instanceID'), row.get('canvasInstanceID'))
            require(type(identity[0]) is int and identity[0] != 0 and type(identity[1]) is int, 'target identity')
            require(key not in identities or identities[key] == identity, 'retained target changed identity')
            identities[key] = identity
            require(row.get('existence') in ('alive', 'destroyed'), 'target existence')
            require(all(type(row.get(k)) is bool for k in ('activeSelf', 'activeInHierarchy', 'hasCanvas', 'canvasEnabled')), 'target booleans')
        rows[phase['name']] = mapping
        if phase['name'] not in ('destroyed-targets', 'toggle-after-destroy'):
            require(not phase.get('invocationError') and not phase.get('capturedEnumerationError'), 'unexpected callback/enumeration error')
            ids = phase.get('capturedCanvasIDs')
            require(isinstance(ids, list) and len(ids) == len(set(ids)) and all(type(i) is int and i for i in ids), 'captured identity list')
    def row(phase, key):
        require(key in rows[phase], 'missing ' + phase + '/' + key)
        return rows[phase][key]
    def state(phase, key, active, enabled):
        value = row(phase, key)
        require(value['existence'] == 'alive' and value['activeSelf'] == active and value['hasCanvas']
                and value['canvasEnabled'] == enabled, 'state ' + phase + '/' + key)
    def captured(phase, key, expected):
        require((row(phase, key)['canvasInstanceID'] in by_name[phase]['capturedCanvasIDs']) == expected,
                'capture membership ' + phase + '/' + key)
    expected_visibility = [True, True, False, False, True, False, False, True, True, False]
    require([p.get('handlerVisible') for p in phases] == expected_visibility, 'handler visibility transitions')
    for before, after in [('original-startup', 'controlled-init'), ('toggle-after-destroy', 'controlled-reinit')]:
        for key, value in rows[before].items():
            require(row(after, key) == value, 'initialization changed host target ' + key)
    state('controlled-init', 'captured-disabled-canvas', True, False)
    state('controlled-init', 'inactive-at-capture', False, True)
    state('controlled-init', 'dynamic-plugin-before', True, False)
    state('controlled-init', 'dynamic-plugin-inactive', False, True)
    captured('controlled-init', 'captured-disabled-canvas', True)
    captured('controlled-init', 'inactive-at-capture', False)
    captured('controlled-init', 'captured-renamed-later', False)
    for phase, visible in [('toggle-1', False), ('toggle-2', True), ('toggle-3', False)]:
        state(phase, 'captured-disabled-canvas', visible, False)
        state(phase, 'inactive-at-capture', False, True)
        state(phase, 'dynamic-plugin-before', True, visible)
    state('toggle-1', 'dynamic-plugin-inactive', False, True)
    state('toggle-2', 'dynamic-plugin-inactive', False, True)
    state('toggle-3', 'dynamic-plugin-inactive', True, False)
    gizmos = [key for key in rows['controlled-init'] if key in ('owned-gizmo', 'original-gizmo')]
    require(len(gizmos) == 1, 'controlled main-camera gizmo')
    for phase, active in [('toggle-1', False), ('toggle-2', True), ('toggle-3', False)]:
        require(row(phase, gizmos[0])['activeSelf'] == active, 'main-camera gizmo toggle')
    captured('late-targets', 'captured-renamed-later', True)
    captured('late-targets', 'late-game', False)
    for phase, visible in [('toggle-2', True), ('toggle-3', False)]:
        state(phase, 'captured-renamed-later', visible, True)
        state(phase, 'late-game', True, True)
        state(phase, 'dynamic-plugin-late', True, visible)
    require(row('destroyed-targets', 'captured-disabled-canvas')['existence'] == 'destroyed'
            and row('destroyed-targets', 'dynamic-plugin-before')['existence'] == 'destroyed', 'destroyed retained references')
    # The retained exact-player oracle observes NullReferenceException from the
    # deferred name getter, not the editor's often-used MissingReferenceException.
    require('System.NullReferenceException:' in (by_name['toggle-after-destroy'].get('invocationError') or ''), 'deferred name predicate exception')
    for phase in ('destroyed-targets', 'toggle-after-destroy'):
        require('System.NullReferenceException:' in (by_name[phase].get('capturedEnumerationError') or ''), 'destroyed deferred enumeration')
    state('toggle-after-destroy', 'dynamic-plugin-late', True, False)
    captured('controlled-reinit', 'late-game', True)
    captured('controlled-reinit', 'inactive-at-capture', False)
    state('toggle-after-reinit', 'late-game', False, True)
    state('toggle-after-reinit', 'dynamic-plugin-late', True, False)
    return {'passed': True, 'phases': len(phases), 'retainedTargets': len(identities),
            'scope': 'Captured game GameObject.active, dynamic Canvas.enabled, deferred name/lifetime behavior; controlled callback reinitialization'}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stop', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if '.local' not in output.parts:
        parser.error('Original evidence must remain under ignored .local')
    if args.stop:
        run = json.loads((output / 'run.json').read_text())
        stop_owned(args.vm, run)
        return
    output.mkdir(parents=True, exist_ok=False)
    fixture = Path(__file__).with_name('fixtures') / 'OriginalHideStudioUIProbe.cs'
    (output / 'probe-source.cs').write_bytes(fixture.read_bytes())
    root = r'C:\Temp\IkkokuHideUIProbe-' + uuid.uuid4().hex
    run = {'schemaVersion': 1, 'root': root, 'vm': args.vm, 'sourceFile': SOURCE,
           'sourceSHA256': SOURCE_SHA256, 'probeSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
           'processID': None, 'stopped': False, 'status': 'preparing'}
    save(output / 'run.json', run)
    prefix = "$ErrorActionPreference='Stop';$root=" + ps_quote(root) + ";"
    try:
        script = prefix + "$source=" + ps_quote(SOURCE) + ";if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower() -ne " + ps_quote(SOURCE_SHA256) + "){throw 'Original plugin hash changed'};"
        script += r'''$original='C:\Illusion\Koikatsu';if(Test-Path $root){throw 'Owned directory already exists'};New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};Copy-Item -LiteralPath $source -Destination "$root\BepInEx\plugins\HideAllUI.Koikatu.dll";[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n");[IO.File]::WriteAllText("$root\BepInEx\config\keelhauled.hideallui.cfg","[Keyboard shortcuts]`nHide UI = Space`n");(Get-FileHash -LiteralPath "$root\BepInEx\plugins\HideAllUI.Koikatu.dll" -Algorithm SHA256).Hash.ToLower()'''
        copied = powershell(args.vm, script)
        if copied != SOURCE_SHA256:
            raise ValueError('Copied plugin hash changed')
        write_small(args.vm, root + r'\Probe.cs', fixture.read_bytes())
        compiler = powershell(args.vm, prefix + r'''$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\Probe.dll" /reference:$($refs -join ',') "$root\Probe.cs";if($LASTEXITCODE -ne 0){throw 'Probe compilation failed'}''')
        (output / 'compiler.txt').write_text(compiler + '\n')
        run['processID'] = launch_owned(args.vm, root)
        run['status'] = 'running'; save(output / 'run.json', run)
        print(json.dumps({'processID': run['processID'], 'root': root}), flush=True)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if powershell(args.vm, prefix + r'''Test-Path -LiteralPath "$root\BepInEx\plugins\complete.txt"''') == 'True':
                break
            time.sleep(2)
        else:
            raise TimeoutError('Original Studio UI probe did not complete within 180 seconds')
        data = fetch_report(args.vm, root)
        (output / 'hide-ui.json').write_bytes(data)
        report = json.loads(data.decode('utf-8-sig'))
        run['reportSHA256'] = hashlib.sha256(data).hexdigest()
        expected_assembly = root + r'\BepInEx\plugins\HideAllUI.Koikatu.dll'
        if report.get('assemblyPath', '').lower() != expected_assembly.lower():
            raise ValueError('Original plugin was not loaded from the owned copy')
        save(output / 'validation.json', validate_report(report))
        run['status'] = 'validated'
    except BaseException as error:
        run['status'] = 'failed'; run['error'] = str(error)
        raise
    finally:
        try:
            run['cleanup'] = stop_owned(args.vm, run); run['stopped'] = True
        finally:
            save(output / 'run.json', run)
    print(json.dumps(run))


if __name__ == '__main__':
    main()
