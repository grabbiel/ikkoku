#!/usr/bin/env python3
"""Recover exact normal Studio catalog → Animator state/clip bindings locally.

This reads serialized assets only. It never renders or decodes source media.
Unsupported motions stay explicit catalog rows with diagnostics.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
from animation_assets import convert_clip, project_states, rig_paths, sample_curve, f32

REPO = Path(__file__).resolve().parents[2]


def catalog_rows(tables):
    rows = []
    for table in sorted(tables, key=lambda t: t.get('m_Name', '')):
        if not re.fullmatch(r'Anime_\d+_\d+_\d+', table.get('m_Name', '')): continue
        for entry in table['list'][2:]:
            row = entry['list']
            if not row or not re.fullmatch(r'-?\d+', row[0]): continue
            if len(row) < 7: raise ValueError('Truncated normal animation catalog row')
            rows.append(dict(group=int(row[1]), category=int(row[2]), no=int(row[0]),
                bundle=row[4], controller=row[5], state=row[6], optionItems=any(row[7:]),
                sourceTable=table['m_Name']))
    keys = [(r['group'], r['category'], r['no']) for r in rows]
    if len(keys) != len(set(keys)): raise ValueError('Ambiguous catalog identities; apply source load precedence explicitly')
    return rows


def low_detail_paths(avatars, targets):
    """Only classify paths proven absent from the selected high-detail rig."""
    by_name = {a['m_Name']: dict(a['m_TOS']) for a in avatars}
    high, low = by_name['cf_body_00Avatar'], by_name['cf_body_lowAvatar']
    import zlib
    for mapping in [high, low]:
        if any(zlib.crc32(path.encode('utf-8')) != key for key, path in mapping.items()):
            raise ValueError('Avatar path/hash identity mismatch')
    return {key: path for key,path in low.items() if key not in high and key not in targets}


def extract(info_bundle, animation_bundle, rig_file, output, avatar_bundle=None):
    import UnityPy
    output = output.resolve()
    if not output.is_relative_to(REPO / '.local'): raise ValueError('Original animation output must stay in .local')
    output.mkdir(parents=True, exist_ok=True)
    tables = [o.read_typetree() for o in UnityPy.load(str(info_bundle)).objects if o.type.name == 'MonoBehaviour']
    rows = catalog_rows(tables)
    env = UnityPy.load(str(animation_bundle)); objects = {o.path_id: o for o in env.objects}
    if len(objects) != len(env.objects): raise ValueError('Ambiguous serialized file identities')
    controllers = {o.peek_name(): o for o in env.objects if o.type.name == 'AnimatorController'}
    pointers = {o.path_id: f'{o.assets_file.name}:{o.path_id}' for o in env.objects if o.type.name == 'AnimationClip'}
    targets = rig_paths(json.loads(rig_file.read_bytes()), 'body-master/')
    low_paths = {}
    if avatar_bundle:
        avatars = [o.read_typetree() for o in UnityPy.load(str(avatar_bundle)).objects if o.type.name == 'Avatar']
        low_paths = low_detail_paths(avatars, targets)
    bundle_hash = hashlib.sha256(animation_bundle.read_bytes()).hexdigest()
    rig_hash = hashlib.sha256(rig_file.read_bytes()).hexdigest()
    converted = {}; failures = {}; raw_cache = {}; clip_cache = {}; reports = []
    for row in rows:
        identity = (row['controller'], row['state'])
        if identity in converted or identity in failures: continue
        try:
            if row['bundle'] != 'studio/anime/00.unity3d': raise ValueError('Catalog bundle is not the selected original bundle')
            obj = controllers[row['controller']]
            raw = raw_cache.setdefault(row['controller'], obj.read_typetree())
            if len(raw['m_Controller']['m_LayerArray']) != 1: raise ValueError('Multiple Animator layers require a layer adapter')
            states, parameters = project_states(raw, [row['state']], pointers)
            clips = []
            for motion in states[0]['motions']:
                key = motion['clipID']
                if key not in clip_cache:
                    clip_cache[key] = convert_clip(objects[int(key.split(':')[-1])].read_typetree(), key, targets)
                if not any(c['id'] == key for c in clips): clips.append(clip_cache[key])
            document = dict(schemaVersion=1, converterVersion='1.0.0', kind='ikkoku-source-animation',
                coordinateSpace='unity-left-handed-y-up', scope='explicit-state-base-layer-generic-transforms',
                source=dict(bundleSHA256=bundle_hash, rigSHA256=rig_hash,
                    controllerID=f'{obj.assets_file.name}:{obj.path_id}', controllerName=row['controller']),
                parameters=parameters, states=states, clips=clips,
                diagnostics=['Catalog-selected normal Studio base-layer state; unmapped paths are explicitly reported.'])
            filename = f"{row['controller']}-{states[0]['id']}.json"
            data = (json.dumps(document, separators=(',', ':'), allow_nan=False)+'\n').encode()
            if len(data) > 64*1024*1024: raise ValueError('Converted state exceeds native animation limit')
            (output/filename).write_bytes(data)
            converted[identity] = dict(file=filename, sha256=hashlib.sha256(data).hexdigest(), stateID=states[0]['id'],
                unboundPaths=sorted({h for c in clips for h in c['unboundPathHashes']}))
            # Independent serialized-curve samples for native regression.
            for clip in clips:
                for fraction in [0, .37, 1]:
                    time = f32(clip['startTime'] + fraction*(clip['stopTime']-clip['startTime']))
                    reports.append(dict(file=filename, clipID=clip['id'], time=time,
                        values=[sample_curve(c,time) for c in clip['curves']]))
        except (ValueError, KeyError) as error: failures[identity] = str(error)
    for row in rows:
        identity = (row['controller'],row['state'])
        if identity in converted:
            row.update(converted[identity])
            if avatar_bundle: row['lowDetailOnlyPaths'] = [h for h in row['unboundPaths'] if h in low_paths]
        else: row['diagnostic'] = failures[identity]
    manifest = dict(schemaVersion=1, kind='ikkoku-studio-animation-catalog',
        catalogSHA256=hashlib.sha256(info_bundle.read_bytes()).hexdigest(), entries=rows)
    if avatar_bundle:
        used = sorted({h for row in rows for h in row.get('lowDetailOnlyPaths',[])})
        manifest['bindingContext'] = dict(avatarBundleSHA256=hashlib.sha256(avatar_bundle.read_bytes()).hexdigest(),
            targetAvatar='cf_body_00Avatar', alternateAvatar='cf_body_lowAvatar',
            lowDetailOnlyPaths=[dict(pathHash=h,sourcePath=low_paths[h]) for h in used])
    (output/'catalog.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (output/'sample-reference.json').write_text(json.dumps(dict(schemaVersion=1,samples=reports),separators=(',',':'))+'\n')
    summary=dict(catalogRows=len(rows),convertedRows=sum('file' in r for r in rows),
        convertedStates=len(converted), convertedClips=len(clip_cache),
        fullyBoundRows=sum('file' in r and not r['unboundPaths'] for r in rows),
        unsupported=[dict(controller=a,state=b,reason=why) for (a,b),why in failures.items()])
    if avatar_bundle:
        summary['highDetailCompatibleRows'] = sum('file' in r and set(r['unboundPaths']) == set(r.get('lowDetailOnlyPaths',[])) for r in rows)
        summary['lowDetailOnlyRows'] = sum(bool(r.get('lowDetailOnlyPaths')) for r in rows)
        summary['unexplainedUnboundRows'] = sum('file' in r and bool(set(r['unboundPaths']) - set(r.get('lowDetailOnlyPaths',[]))) for r in rows)
    (output/'coverage.json').write_text(json.dumps(summary,indent=2)+'\n')
    return summary


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ['info-bundle','animation-bundle','rig','output']: parser.add_argument('--'+key,type=Path,required=True)
    parser.add_argument('--avatar-bundle',type=Path,help='Original body bundle for exact low-detail-only track classification')
    args=parser.parse_args()
    print(json.dumps(extract(args.info_bundle,args.animation_bundle,args.rig,args.output,args.avatar_bundle),indent=2))
