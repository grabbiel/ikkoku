#!/usr/bin/env python3
"""ST-T05a legacy scenes: synthetic older-version scene records, and the original player's reading and saving of them.

`fixtures --output <dir>` writes synthetic scene records in the layouts of older CharaStudio versions, for
the load branches no scene in the corpus exercises. They hold only folders, catalog item 0/0/0 (the
camera-object probe's first scalable item) and routes; no card, game asset or user file goes in. Each layout
follows the 1.0.4.2 loader's version branches (SceneInfo.cs:316-449, OIItemInfo.cs:117-174,
OIRouteInfo.cs:73-99, OIRoutePointInfo.cs:57-81, CameraControl.cs:62-82); the settings are the values
CharaStudio saved for an emptied scene (scene-mirrored-camera.png, ST-A06):
  s005-items   0.0.5:   a folder holding an item, a second item; no emission, panel or dynamic-bone fields;
                        every camera record in version 1 (one dropped float in place of the distance).
  s006-items   0.0.6:   two items, one with a non-default panel; no emission or dynamic-bone fields.
  s100-route   1.0.0:   a route holding a folder, two points without connection, aid or link; no route
                        flags, orientation or color; an item without the dynamic-bone field.
  s103-route   1.0.3:   a route holding an item, flags all false, two points each with the bool only 1.0.3
                        wrote (true, then false); no orientation or color, no aid.
  s104-route   1.0.4:   a route with orientation 1, no color; points without aid.
  s1041-route  1.0.4.1: a route holding a folder, color, two points with connection and aid; no link.

`run` is one VM phase in ONE `prlctl exec` (original_scene_reload_probe.once_script's transport, served and
compiled as LegacySceneProbe.cs / IkkokuLegacySceneProbe.dll, with original_map_probe's junction scans): every
reload-<label>.png in --uploads goes beside fixtures/OriginalLegacySceneProbe.cs in a fresh private player
root (BepInEx core only). For each, the player parses it (SceneInfo.Load) and saves that parse
(parsed-<label>.png), then loads it (Studio.LoadScene) and saves it the way the scene-save button does
(resave-<label>.png); legacy-trace.json records what each step read. The zip of that folder with unity.log
and LogOutput.log lands in --output with run.json and manifest.json. The Parallels errno-24 count must equal
--errno-baseline before the exec; it is recorded before and after. The root is always removed and nothing
in C:\\Illusion\\Koikatsu is written.

Run both with the reverse-tools venv, .local/reverse/unitypy-venv/bin/python (Tools/reverse/README.md): the shared VM
transport imports msgpack.
"""
from __future__ import annotations
import argparse, json, re, struct, subprocess, zlib
from pathlib import Path
from original_map_probe import digest, dump, private, with_junction_scans
from original_wear_probe import Endpoint, bootstrap, errno_count, extract, fresh_root, guarded

PROBE = Path(__file__).with_name('fixtures') / 'OriginalLegacySceneProbe.cs'
PROBE_NAMES = ('LegacySceneProbe.cs', 'IkkokuLegacySceneProbe.dll')
UPLOAD = re.compile(r'reload-[a-z0-9]+(-[a-z0-9]+)*\.png')
MAX_UPLOAD_BYTES = 64 * 1024 * 1024


# --- .NET BinaryWriter encodings --------------------------------------------------------------------------------
def i32(v): return struct.pack('<i', v)
def f32(v): return struct.pack('<f', v)
def flag(v): return b'\x01' if v else b'\x00'
def text(v):
    raw, n, out = v.encode('utf-8'), len(v.encode('utf-8')), bytearray()
    while True:
        byte = n & 0x7f; n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n: return bytes(out) + raw
def unity_float(v):
    """JsonUtility's spelling of the exactly representable values these fixtures use (1 -> 1.0)."""
    if float(v) != struct.unpack('<f', struct.pack('<f', v))[0] or v * 4 != int(v * 4): raise ValueError(f'not a quarter value: {v}')
    return repr(float(v))
def color(r, g, b, a=1.0): return text('{"r":%s,"g":%s,"b":%s,"a":%s}' % tuple(map(unity_float, (r, g, b, a))))
def vector4(x, y, z, w): return text('{"x":%s,"y":%s,"z":%s,"w":%s}' % tuple(map(unity_float, (x, y, z, w))))


def version_tuple(value):
    """System.Version ordering: missing build or revision parts compare as -1."""
    parts = [int(p) for p in value.split('.')]
    return tuple(parts + [-1] * (4 - len(parts)))


def png():
    """A 1x1 grey PNG: the thumbnail SceneInfo.Load skips (PngFile.SkipPng)."""
    def chunk(kind, data): return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 0, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b'\x00\x80')) + chunk(b'IEND', b''))


class Layout:
    def __init__(self, version): self.version, self.v = version, version_tuple(version)
    def at_least(self, value): return self.v >= version_tuple(value)
    def exactly(self, value): return self.v == version_tuple(value)


def change(pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)): return b''.join(f32(x) for x in (*pos, *rot, *scale))
def header(kind, key, pos=(0, 0, 0), rot=(0, 0, 0), tree=0, visible=True):
    return i32(kind) + i32(key) + change(pos, rot) + i32(tree) + flag(visible)  # ObjectInfo.Save (ObjectInfo.cs:32-39)
def children(items): return i32(len(items)) + b''.join(items)
def pattern(clamp=True, uv=(0, 0, 1, 1), rot=0.0): return i32(0) + text('') + flag(clamp) + vector4(*uv) + f32(rot)  # PatternInfo.Save


def item(layout, key, pos=(0, 0, 0), kids=(), first_color=(1, 1, 1, 1), alpha=1.0, panel=None):
    """OIItemInfo.Save's fields as OIItemInfo.Load reads them at `layout` (OIItemInfo.cs:117-174), catalog 0/0/0."""
    out = header(1, key, pos) + i32(0) + i32(0) + i32(0) + f32(1.0)
    out += color(*first_color) + color(1, 1, 1) * 7  # eight colors from 0.0.3
    out += pattern() * 3 + f32(alpha)
    out += color(0.5, 0.5, 0.5) + f32(0.5)  # line color and width from 0.0.4
    if layout.at_least('0.0.7'): out += color(1, 1, 1) + f32(0.25) + f32(0.5)  # emission color, power, light cancel
    if layout.at_least('0.0.6'): out += pattern(**(panel or {}))
    out += flag(False) + i32(0)  # enableFK, no bones
    if layout.at_least('1.0.1'): out += flag(False)  # enableDynamicBone (default true when absent)
    return out + f32(0.0) + children(list(kids))


def folder(key, name, kids=(), pos=(0, 0, 0)): return header(3, key, pos) + text(name) + children(list(kids))


def point(layout, key, pos, connection=0, aid=None, discarded=False):
    """OIRoutePointInfo.Save's fields as OIRoutePointInfo.Load reads them (OIRoutePointInfo.cs:57-81); `aid` is
    (key, position, isInit)."""
    out = i32(key) + change(pos) + f32(2.0) + i32(0)
    if layout.exactly('1.0.3'): out += flag(discarded)
    if layout.at_least('1.0.4.1'):
        aid_key, aid_pos, initialized = aid
        out += i32(connection) + i32(aid_key) + change(aid_pos) + flag(initialized)
    if layout.at_least('1.0.4.2'): out += flag(False)
    return out


def route(layout, key, name, kids, points, flags=(False, True, True), orient=0, rgba=(0, 0, 1, 1)):
    """OIRouteInfo.Save's fields as OIRouteInfo.Load reads them (OIRouteInfo.cs:73-99)."""
    out = header(4, key) + text(name) + children(list(kids)) + i32(len(points)) + b''.join(points)
    if layout.at_least('1.0.3'): out += b''.join(flag(f) for f in flags)
    if layout.at_least('1.0.4'): out += i32(orient)
    if layout.at_least('1.0.4.1'): out += color(*rgba)
    return out


def camera(version, pos, rot, distance_z, fov):
    """CameraControl.CameraData.Save (version 2) or the version-1 record Load still reads (CameraControl.cs:62-82)."""
    head = i32(version) + b''.join(f32(x) for x in (*pos, *rot))
    return head + (f32(distance_z) if version == 1 else f32(0) + f32(0) + f32(distance_z)) + f32(fov)


def settings(camera_version):
    """The settings CharaStudio 1.0.4.2 saved for an emptied scene (SceneInfo.Save, SceneInfo.cs:239-297); every
    field is read from 0.0.5 on (SceneInfo.cs:356-445)."""
    out = i32(-1) + change() + i32(0) + flag(True) + i32(0) + f32(0.0)  # map, caMap, sun type, map option, ace no, ace blend
    out += flag(True) + text('{"r":0.7058823704719544,"g":0.7058823704719544,"b":0.7058823704719544,"a":1.0}') + f32(0.1)
    out += flag(True) + f32(0.4) + f32(0.8) + f32(0.6) + flag(False) + f32(0.95) + f32(0.6)  # bloom, depth of field
    out += flag(True) + flag(False) + text('{"r":0.5372549295425415,"g":0.7568627595901489,"b":0.8666666746139526,"a":1.0}') + f32(1.0) + f32(0.0)
    out += flag(False) + text('{"r":0.501960813999176,"g":0.501960813999176,"b":0.501960813999176,"a":1.0}') + color(1, 1, 1)
    out += i32(-1) + flag(True) + flag(False) + flag(False) + f32(1.0)  # sun caster, shadow, face normal, face shadow, line color
    out += text('{"r":0.501960813999176,"g":0.501960813999176,"b":0.501960813999176,"a":1.0}') + f32(0.307) + i32(1) + f32(0.26)
    out += camera(camera_version, (0.25, 1.0, 0.5), (15.0, 200.0, 0.0), -3.0, 35.0)  # the saved view
    out += b''.join(camera(camera_version, (0.0, 1.25, 0.0), (10.0, 180.0 - slot, 0.0), -4.0 - slot / 4, 23.0) for slot in range(10))
    out += color(1, 1, 1) + f32(1.0) + f32(0.0) + f32(0.0) + flag(True)  # character light
    out += color(1, 1, 1) + f32(1.0) + f32(0.0) + f32(0.0) + flag(True) + i32(1)  # map light
    out += (i32(1) + i32(0) + flag(False)) * 2 + i32(1) + text('') + flag(False)  # BGM, environment sound, outside sound
    return out + text('') + text('') + text('【KStudio】')


def scene(version, roots, camera_version=2):
    layout = Layout(version)
    body = b''.join(i32(key) + record(layout) for key, record in roots)
    return png() + text(version) + i32(len(roots)) + body + settings(camera_version)


def synthetic():
    """label -> bytes of each synthetic legacy scene (see the module docstring). Roots are (dictionary key,
    record writer given the layout)."""
    pts = ((0, 0, 0), (1.25, 0, 0.5))
    cases = {
        's005-items': ('0.0.5', 1, [(0, lambda l: folder(0, 'IKKOKU-LF', [item(l, 1, (0.5, 0, 0), first_color=(0.5, 0.25, 1, 1), alpha=0.75)])),
                                    (2, lambda l: item(l, 2, (-0.5, 0, 0)))]),
        's006-items': ('0.0.6', 2, [(0, lambda l: item(l, 0, (0.5, 0, 0), panel=dict(clamp=False, uv=(0.25, 0, 0.75, 1), rot=0.5))),
                                    (1, lambda l: item(l, 1, (-0.5, 0, 0)))]),
        's100-route': ('1.0.0', 2, [(0, lambda l: route(l, 0, 'IKKOKU-R100', [folder(1, 'IKKOKU-RF')], [point(l, 2, pts[0]), point(l, 3, pts[1])])),
                                    (4, lambda l: item(l, 4, (0, 0, 1)))]),
        's103-route': ('1.0.3', 2, [(0, lambda l: route(l, 0, 'IKKOKU-R103', [item(l, 1)],
                                                        [point(l, 2, pts[0], discarded=True), point(l, 3, pts[1])], flags=(False, False, False)))]),
        's104-route': ('1.0.4', 2, [(0, lambda l: route(l, 0, 'IKKOKU-R104', [], [point(l, 1, pts[0]), point(l, 2, pts[1])], orient=1))]),
        's1041-route': ('1.0.4.1', 2, [(0, lambda l: route(l, 0, 'IKKOKU-R1041', [folder(1, 'IKKOKU-RF')],
                                                           [point(l, 2, pts[0], connection=1, aid=(3, (0.5, 1, 0.5), True)),
                                                            point(l, 4, pts[1], aid=(5, (1, 1, 1), False))], orient=2, rgba=(1, 0.5, 0, 1)))]),
    }
    return {label: scene(version, roots, cameras) for label, (version, cameras, roots) in cases.items()}


def fixtures(args):
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    written = {}
    for label, data in synthetic().items():
        path = output / f'{label}.png'
        if path.exists() and path.read_bytes() != data: raise RuntimeError(f'{path} exists with other bytes')
        path.write_bytes(data); written[label] = dict(file=path.name, bytes=len(data), sha256=digest(data))
    return written


def uploads_from(folder):
    """Every reload-<label>.png in `folder` (sorted); anything else there is refused."""
    folder = Path(folder)
    names = sorted(p.name for p in folder.iterdir())
    bad = [n for n in names if not UPLOAD.fullmatch(n)]
    if bad or not names: raise ValueError(f'--uploads must hold only reload-<label>.png scene records: {bad or "empty"}')
    uploads = {n: (folder / n).read_bytes() for n in names}
    for name, data in uploads.items():
        if not data.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError(f'{name} is not a PNG scene record')
    if sum(map(len, uploads.values())) > MAX_UPLOAD_BYTES: raise ValueError('uploads exceed the bound')
    return uploads


def run(args):
    """The VM phase in one `prlctl exec` (see the module docstring)."""
    from original_scene_reload_probe import once_script
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    uploads = uploads_from(args.uploads)
    source = PROBE.read_bytes()
    root = fresh_root()
    record = dict(vm=args.vm, root=root, processID=0, sourceSHA256=digest(source), uploads={n: digest(d) for n, d in uploads.items()},
                  errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_scene_reload_probe.once_script)')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {PROBE_NAMES[0]: source, **uploads}
    with Endpoint(args.host_address, files, upload='reload.zip') as endpoint:
        script = with_junction_scans(once_script(root, endpoint.base, args.wait_seconds, list(uploads), *PROBE_NAMES))
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
    dump(output / 'run.json', record)
    if guest.get('source') not in (None, digest(source)): raise ValueError('Guest probe source hash differs')
    for name, data in uploads.items():
        if (guest.get('scenes') or {}).get(name) not in (None, digest(data)): raise ValueError('Guest scene hash differs: ' + name)
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    (output / 'probe-source.cs').write_bytes(source)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json', 'probe-source.cs'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, processID=record['processID'], exited=guest.get('exited'), error=guest.get('error'),
                cleanupError=guest.get('cleanupError'), removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                errno=[record['errnoBefore'], record['errnoAfter']], scansEqual=guest.get('scanBefore') is not None and guest.get('scanBefore') == guest.get('scanAfter'),
                files=len(provenance), status=None if status is None else {k: v for k, v in status.items() if k != 'scope'})


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = p.add_subparsers(dest='command', required=True)
    f = commands.add_parser('fixtures', help='write the synthetic legacy scene records')
    f.add_argument('--output', type=Path, required=True)
    r = commands.add_parser('run', help='the original player parses, loads and saves every uploaded record (one exec)')
    r.add_argument('--vm', default='Windows 11'); r.add_argument('--output', type=Path, required=True)
    r.add_argument('--uploads', type=Path, required=True, help='a folder holding only reload-<label>.png scene records')
    r.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    r.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    r.add_argument('--wait-seconds', type=int, default=1800, help='bound on the player run')
    args = p.parse_args()
    print(json.dumps(dict(fixtures=fixtures, run=run)[args.command](args), indent=2))


if __name__ == '__main__': main()
