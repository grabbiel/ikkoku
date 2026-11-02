#!/usr/bin/env python3
"""#348: what the original player samples for a texture's filterMode and anisoLevel, and the install's texture settings.

`run` is one VM phase in ONE `prlctl exec` (original_scene_reload_probe.once_script's transport with no upload, served
and compiled as SamplerProbe.cs / IkkokuSamplerProbe.dll, with original_map_probe's junction scans before and after):
fixtures/OriginalSamplerProbe.cs runs in a fresh private CharaStudio root (BepInEx core only, -logFile in the root).
It draws synthetic textures (filter Point/Bilinear/Trilinear x anisoLevel 0/1/2/8/16 x mipmapped or single-level)
in a grazing and a magnified view under the player's own QualitySettings.anisotropicFiltering, then under the two
other modes, and restores the mode; then it records the filter, aniso, mip, size and wrap settings of every Texture2D
in abdata/chara, abdata/studio and abdata/map, read-only, each bundle it loads unloaded with Unload(true). The zip of
its folder with unity.log and LogOutput.log lands in --output with run.json and manifest.json. The Parallels
errno-24 count must equal --errno-baseline before the exec; it is recorded before and after. The root is always
removed, no game process may remain, and nothing in C:\\Illusion\\Koikatsu is written.

`analyse` reads a run's frames and decides, per cell, the filtering the player used: linear min/mag when the
magnified frame's checkerboard channel takes values strictly between 0 and 255, linear mips when the grazing frame's
level channel takes values between the level values, and anisotropy when its rows use finer levels than the same
filter's aniso-0 cell. With --reference (a folder of host Metal renders of the same views, one per candidate sampler,
named <candidate>-<mips|single>-<grazing|magnified>.png) it also gives each cell's nearest candidate and the one
TranslatedSourceProgram.SamplerConfiguration predicts. It summarises the survey as counts.

Run with the reverse-tools venv, .local/reverse/unitypy-venv/bin/python (Tools/reverse/README.md): the shared VM
transport imports msgpack, and analyse reads PNGs with Pillow and numpy.
"""
from __future__ import annotations
import argparse, collections, json, subprocess
from pathlib import Path
from original_map_probe import digest, dump, private, with_junction_scans
from original_wear_probe import Endpoint, bootstrap, errno_count, extract, fresh_root, guarded

PROBE = Path(__file__).with_name('fixtures') / 'OriginalSamplerProbe.cs'
PROBE_NAMES = ('SamplerProbe.cs', 'IkkokuSamplerProbe.dll')
FILTERS = ('Point', 'Bilinear', 'Trilinear')
ANISOS = (0, 1, 2, 8, 16)
MODES = ('ForceEnable', 'Enable', 'Disable')
LEVELS = 9
LEVEL_VALUES = [round(255 * level / (LEVELS - 1)) for level in range(LEVELS)]
# Host Metal candidates: (min/mag, mip, maxAnisotropy). D3D11 has no anisotropic filter with point min/mag
# (D3D11_FILTER_ANISOTROPIC is linear min/mag/mip), so `ours-*` cannot be what a D3D11 player asks for.
CANDIDATES = {'point': ('nearest', 'nearest', 1), 'bilinear': ('linear', 'nearest', 1), 'trilinear': ('linear', 'linear', 1),
              **{f'ours-a{n}': ('nearest', 'linear', n) for n in (2, 8, 9, 16)},
              **{f'aniso-a{n}': ('linear', 'linear', n) for n in (2, 8, 9, 16)}}
LINEAR_G = 0.05      # magnified plane pixels with 8 < G < 247 above this fraction: linear min/mag
BLENDED_R = 0.02     # grazing plane pixels more than 2 off every level value above this fraction: linear mips
FINER_LEVELS = 0.25  # mean row level this much below the aniso-0 cell's: anisotropy on (mipmapped)
SMOOTHER = 0.85     # single-level: grazing checkerboard contrast below this share of the aniso-0 cell's: anisotropy on


def run(args):
    """The VM phase in one `prlctl exec` (see the module docstring)."""
    from original_scene_reload_probe import once_script
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    source = PROBE.read_bytes()
    root = fresh_root()
    record = dict(vm=args.vm, root=root, processID=0, sourceSHA256=digest(source),
                  errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_scene_reload_probe.once_script)')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {PROBE_NAMES[0]: source}
    with Endpoint(args.host_address, files, upload='reload.zip') as endpoint:
        script = with_junction_scans(once_script(root, endpoint.base, args.wait_seconds, [], *PROBE_NAMES, allow_no_uploads=True))
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


# --- analysis ----------------------------------------------------------------------------------------------------
def rule_candidate(filter, aniso, mode):
    """The candidate TranslatedSourceProgram.SamplerConfiguration builds (its Swift rule, restated)."""
    min_mag = 'nearest' if filter == 'Point' else 'linear'
    mip = 'linear' if filter == 'Trilinear' else 'nearest'
    effective = max(1, min(16, aniso))
    if mode == 'Disable': effective = 1
    elif mode == 'ForceEnable' and aniso > 0 and filter != 'Point': effective = max(9, effective)
    if effective > 1: mip = 'linear'
    if effective == 1: return 'point' if min_mag == 'nearest' and mip == 'nearest' else 'bilinear' if mip == 'nearest' else 'trilinear'
    return ('ours-a' if min_mag == 'nearest' else 'aniso-a') + str(effective)


def image(path):
    import numpy as np
    from PIL import Image
    with Image.open(path) as png: return np.asarray(png.convert('RGBA'), dtype=np.int16)


def plane_mask(pixels):
    """Pixels the textured surface covers (texture B is 0 and A 255; the clear colour is B 255, A 0)."""
    return (pixels[..., 2] == 0) & (pixels[..., 3] == 255)


def frame_metrics(grazing, magnified, mipmapped):
    """Filtering evidence from one cell's two frames (top row first, as Pillow reads them)."""
    import numpy as np
    g_mask, m_mask = plane_mask(grazing), plane_mask(magnified)
    if not g_mask.any() or not m_mask.any(): raise ValueError('a frame shows no textured surface')
    if g_mask[0].any() or not g_mask[-1].all(): raise ValueError('the grazing frame is not horizon-up (top row background, bottom row surface)')
    green = magnified[..., 1][m_mask]
    red = grazing[..., 0]
    offsets = np.min(np.abs(red[..., None] - np.array(LEVEL_VALUES)[None, None, :]), axis=-1)
    level = np.interp(red, LEVEL_VALUES, np.arange(LEVELS))  # the level each R value stands for (blends in between)
    rows = [None if not g_mask[y].any() else round(float(level[y][g_mask[y]].mean()), 3) for y in range(grazing.shape[0])]
    contrast = [None if not g_mask[y].any() else round(float(grazing[y, :, 1][g_mask[y]].std()), 2) for y in range(grazing.shape[0])]
    return dict(magnifiedLinearFraction=round(float(((green > 8) & (green < 247)).mean()), 4),
                grazingBlendedFraction=round(float((offsets[g_mask] > 2).mean()), 4) if mipmapped else None,
                magnifiedLevels=sorted({int(v) for v in np.round(np.interp(magnified[..., 0][m_mask], LEVEL_VALUES, np.arange(LEVELS)))}),
                surfaceFraction=round(float(g_mask.mean()), 4), rowLevels=rows, rowContrast=contrast)


def finer_by(rows, baseline):
    pairs = [(a, b) for a, b in zip(rows, baseline) if a is not None and b is not None]
    return round(sum(b - a for a, b in pairs) / len(pairs), 3) if pairs else None


def contrast_share(rows, baseline):
    """Mean grazing checkerboard contrast over the rows both frames cover, as a share of the baseline's."""
    pairs = [(a, b) for a, b in zip(rows, baseline) if a is not None and b is not None]
    total = sum(b for _, b in pairs)
    return round(sum(a for a, _ in pairs) / total, 3) if total else None


def difference(a, b):
    import numpy as np
    d = np.abs(a - b)
    return dict(mean=round(float(d.mean()), 4), p99=float(np.percentile(d, 99)), max=int(d.max()))


def analyse(args):
    capture = Path(args.capture)
    trace = json.loads((capture / 'sampler-trace.json').read_text())
    cells = {c['id']: c for c in trace['cells']}
    frames = {cid: (image(capture / c['grazing']['file']), image(capture / c['magnified']['file'])) for cid, c in cells.items()}
    reference = {}
    if args.reference:
        for name in CANDIDATES:
            for variant in ('mips', 'single'):
                g, m = Path(args.reference) / f'{name}-{variant}-grazing.png', Path(args.reference) / f'{name}-{variant}-magnified.png'
                if g.is_file() and m.is_file(): reference[(name, variant)] = (image(g), image(m))
    results = []
    for cid, cell in cells.items():
        grazing, magnified = frames[cid]
        metrics = frame_metrics(grazing, magnified, cell['mipmapped'])
        variant = 'mips' if cell['mipmapped'] else 'single'
        base = f"{cell['filter'].lower()}-a0-{variant}-{cell['mode'].lower()}"
        baseline = frame_metrics(*frames[base], cell['mipmapped']) if base in frames else None
        finer = finer_by(metrics['rowLevels'], baseline['rowLevels']) if baseline and cell['mipmapped'] else None
        smoother = contrast_share(metrics['rowContrast'], baseline['rowContrast']) if baseline and not cell['mipmapped'] else None
        anisotropic = finer > FINER_LEVELS if finer is not None else smoother < SMOOTHER if smoother is not None else None
        verdict = dict(minMag='linear' if metrics['magnifiedLinearFraction'] > LINEAR_G else 'point',
                       mips=None if not cell['mipmapped'] else 'linear' if metrics['grazingBlendedFraction'] > BLENDED_R else 'point',
                       anisotropic=anisotropic, finerThanAniso0=finer, contrastShareOfAniso0=smoother)
        row = dict(id=cid, filter=cell['filter'], aniso=cell['aniso'], mipmapped=cell['mipmapped'], mode=cell['mode'],
                   readBack=cell['readBack'], verdict=verdict, rule=rule_candidate(cell['filter'], cell['aniso'], cell['mode']),
                   metrics={k: v for k, v in metrics.items() if k not in ('rowLevels', 'rowContrast')})
        if reference:
            scores = {}
            for (name, v), (g, m) in reference.items():
                if v != variant: continue
                dg, dm = difference(grazing, g), difference(magnified, m)
                scores[name] = dict(mean=round((dg['mean'] + dm['mean']) / 2, 4), grazing=dg, magnified=dm)
            # Candidates the host GPU renders identically (Apple GPUs give aniso 9 and 16 the same frames) tie.
            best = min(s['mean'] for s in scores.values())
            nearest = [n for n in CANDIDATES if n in scores and scores[n]['mean'] <= best + 1e-9]
            others = [s['mean'] for n, s in scores.items() if n not in nearest]
            row.update(nearest=nearest, margin=round(min(others) - best, 4) if others else None,
                       ruleMatches=row['rule'] in nearest, scores=scores)
        results.append(row)
    restored = trace.get('restoredCheck') or {}
    report = dict(schemaVersion=1, capture=str(capture), shader=trace.get('shader'), qualityBefore=trace.get('qualityBefore'),
                  qualityAfter=trace.get('qualityAfter'), qualityRestored=trace.get('qualityBefore') == trace.get('qualityAfter'),
                  restoredCellMatches=restored.get('matches'), modes=trace.get('modes'), cells=results,
                  pointCells=[dict(id=r['id'], verdict=r['verdict'], nearest=r.get('nearest'), rule=r['rule']) for r in results if r['filter'] == 'Point'],
                  ruleMismatches=[r['id'] for r in results if r.get('ruleMatches') is False])
    survey = capture / 'sampler-survey.json'
    if survey.is_file(): report['survey'] = survey_summary(json.loads(survey.read_text()))
    dump(private(args.output), report)
    return dict(cells=len(results), ruleMismatches=len(report['ruleMismatches']), pointCells=report['pointCells'],
                qualityRestored=report['qualityRestored'], restoredCellMatches=report['restoredCellMatches'],
                survey=None if 'survey' not in report else {k: v for k, v in report['survey'].items() if k != 'pointAnisoAbove1'})


def survey_summary(survey):
    """Counts only: textures by (filter, aniso bucket, mipmapped), the Point ones by aniso, and bundle statuses."""
    columns = survey['columns']
    rows = [dict(zip(columns, values)) for values in survey['textures']]
    bucket = lambda a: 'aniso 0' if a == 0 else 'aniso 1' if a == 1 else 'aniso >1'
    counts = collections.Counter((r['filter'], bucket(r['aniso']), r['mips'] > 1) for r in rows)
    point = [r for r in rows if r['filter'] == 'Point']
    return dict(bundles=len(survey['bundles']), textures=len(rows), truncated=survey.get('truncated'),
                bundleStatus=dict(collections.Counter(b['status'] for b in survey['bundles'])),
                heldByGame=sum(1 for b in survey['bundles'] if b.get('held')),
                byTop={top: sum(1 for r in rows if r['bundle'].split('/')[0] == top) for top in sorted({r['bundle'].split('/')[0] for r in rows})},
                counts=[dict(filter=f, aniso=a, mipmapped=m, textures=n) for (f, a, m), n in sorted(counts.items())],
                point=dict(collections.Counter(bucket(r['aniso']) for r in point)),
                pointAnisoAbove1=sorted({r['bundle'] for r in point if r['aniso'] > 1}))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = p.add_subparsers(dest='command', required=True)
    r = commands.add_parser('run', help='the original player draws the sampler matrix and surveys the texture settings (one exec)')
    r.add_argument('--vm', default='Windows 11'); r.add_argument('--output', type=Path, required=True)
    r.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    r.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    r.add_argument('--wait-seconds', type=int, default=2400, help='bound on the player run (the survey stops itself at 1500 s)')
    a = commands.add_parser('analyse', help="decide each cell's filtering from a run's frames and summarise the survey")
    a.add_argument('--capture', type=Path, required=True); a.add_argument('--output', type=Path, required=True)
    a.add_argument('--reference', type=Path, help='host Metal renders, <candidate>-<mips|single>-<grazing|magnified>.png')
    args = p.parse_args()
    print(json.dumps(dict(run=run, analyse=analyse)[args.command](args), indent=2))


if __name__ == '__main__': main()
