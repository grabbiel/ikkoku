#!/usr/bin/env python3
"""Neutral native model versus source-player transforms and every selected vertex.

No alignment, fitted animation phase or native-seeded reference. Raw BakeMesh
and independently evaluated source-runtime skin geometry remain separate gates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import numpy as np
from compare_original_pose import compose_original_worlds, build_native_tree, match_bones, file_record


def sidecar(folder, record, count):
    name = record['file']
    if Path(name).name != name or not name or name.startswith('.'):
        raise ValueError('Invalid model sidecar path')
    data = (folder / name).read_bytes()
    if len(data) != count * 12 or hashlib.sha256(data).hexdigest() != record['sha256']:
        raise ValueError('Changed or malformed model sidecar')
    result = np.frombuffer(data, dtype='<f4').reshape(count, 3).astype(np.float64)
    if not np.isfinite(result).all(): raise ValueError('Nonfinite model sidecar')
    return result


def geometry(folder, mesh):
    name = mesh['file']
    if Path(name).name != name or not name or name.startswith('.'): raise ValueError('Invalid geometry path')
    data = (folder / name).read_bytes()
    if len(data) < 8: raise ValueError('Truncated geometry')
    if hashlib.sha256(data).hexdigest() != mesh['sourceVertexNormals']['geometrySHA256']:
        raise ValueError('Changed original geometry hash')
    count, submeshes = struct.unpack_from('<ii', data)
    if count != mesh['vertices'] or submeshes != mesh['submeshes'] or not 0 < count <= 2_000_000 or not 0 < submeshes <= 256:
        raise ValueError('Invalid geometry counts')
    offset = 8 + count * 80
    if offset > len(data): raise ValueError('Truncated geometry vertices')
    positions = np.frombuffer(data, dtype='<f4', count=count * 20, offset=8).reshape(count, 20)[:, :3].astype(np.float64)
    indices = []
    for _ in range(submeshes):
        if offset + 4 > len(data): raise ValueError('Truncated geometry indices')
        size, = struct.unpack_from('<i', data, offset); offset += 4
        if size <= 0 or size % 3 or offset + size * 4 > len(data): raise ValueError('Invalid geometry indices')
        values = np.frombuffer(data, dtype='<i4', count=size, offset=offset).copy(); offset += size * 4
        if np.any(values < 0) or np.any(values >= count): raise ValueError('Geometry index outside vertex buffer')
        indices.append(values)
    if offset != len(data) or not np.isfinite(positions).all(): raise ValueError('Malformed geometry boundary')
    return positions, indices


def errors(a, b, tolerance):
    if a.shape != b.shape or a.ndim != 2 or a.shape[1] != 3 or not len(a) or not np.isfinite(a).all() or not np.isfinite(b).all():
        raise ValueError('Invalid vertex comparison arrays')
    distances = np.linalg.norm(a - b, axis=1)
    return dict(count=len(distances), p50=float(np.quantile(distances, .5)), p99=float(np.quantile(distances, .99)),
                maximum=float(distances.max()), overTolerance=int(np.count_nonzero(distances > tolerance)), tolerance=tolerance)


def compare(folder, native, tolerance=2e-5):
    frame_path = folder / 'frame.json'; frame = json.loads(frame_path.read_text())
    mode = frame.get('neutralModel')
    if not mode or native.get('kind') != 'ikkoku-neutral-source-model': raise ValueError('Requires neutral source and native model captures')
    identity = native['identity']
    variants = {'female00': (1, 0), 'female200': (1, 200), 'male200': (0, 200)}
    if mode.get('variant') not in variants or (mode['sex'], mode['headID']) != variants[mode['variant']]:
        raise ValueError('Unsupported source neutral model identity')
    for key in ('Sex', 'HeadID', 'BoneType'):
        if mode['requested' + key] != mode[key[0].lower() + key[1:]]: raise ValueError('Source silently changed requested identity')
    if mode['loadedHeadCatalogID'] != mode['headID'] or mode['boneType'] != 0 or identity['exType'] != 0:
        raise ValueError('Loaded head or normal body identity differs')
    if mode.get('handControllerCounts') != {'L': 1, 'R': 1}: raise ValueError('Expected exactly two driven hand controllers')
    if mode['handPatterns'] != [0, 0] or mode['elapsedFramesAfterLoad'] != 0:
        raise ValueError('Requires quiescent pattern-zero capture')
    if mode['eyeAngleHRate'] != 0 or mode['eyeAngleVRate'] != 0:
        raise ValueError('Neutral model gate requires measured zero eye angle rates')
    for key, value in native['lateCorrectionOptions'].items():
        if mode[key] != value: raise ValueError('Source/native late correction options differ')
    for key in ('sex', 'headID', 'boneType'):
        if mode[key] != identity[key]: raise ValueError('Source/native model identity mismatch: ' + key)
    card_hash = file_record(folder / frame['card'])['sha256']
    if native['inputs']['cardSHA256'] != card_hash: raise ValueError('Source/native card identity differs')
    for key in ('Body', 'Face'):
        if not np.array_equal(np.asarray(mode['actual' + key + 'Values'], dtype='<f4'), np.asarray(native[key.lower() + 'Values'], dtype='<f4')):
            raise ValueError('Source/native shape values differ')
    original_tree = compose_original_worlds(frame['bones']); tree = build_native_tree(native)
    matching = match_bones(tree, original_tree)
    hierarchy = {key: value for key, value in matching.items() if key != 'pairs'}
    hierarchy.update(matchedUniquePaths=len(matching['pairs']), nativeNodes=len(native['nodeNames']), sourceRecords=len(frame['bones']))
    candidates = {}
    for mesh in frame['meshes']:
        if 'restPositions' not in mesh: continue
        key = mesh['restPositions']['sha256']
        candidates.setdefault(key, []).append(mesh)
    rows, omitted, matched = [], [], set()
    for part in native['parts']:
        if not part['selected']:
            omitted.append(dict(name=part['name'], reason=part['selectionReason'])); continue
        if part['hasCloth']: raise ValueError('Neutral model gate does not approximate Unity Cloth')
        rest = np.asarray(part['restPositions'], dtype='<f4'); rest[:, 2] *= -1
        key = hashlib.sha256(rest.tobytes()).hexdigest()
        matches = candidates.get(key, [])
        if len(matches) != 1: raise ValueError('Missing or ambiguous exact source vertex identity: ' + part['name'])
        mesh = matches[0]; name = part['name'].split('/')[-2]; submesh = int(part['name'].split('/')[-1])
        if name != mesh['name']: raise ValueError('Source mesh name differs despite matching rest geometry')
        sidecar(folder, mesh['restPositions'], part['vertexCount'])
        world, indices = geometry(folder, mesh)
        native_indices = np.asarray(part['indices'], dtype=np.int64).reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)
        if submesh >= len(indices) or not np.array_equal(native_indices, indices[submesh]): raise ValueError('Source mesh topology differs')
        baked = sidecar(folder, mesh['bakedPositions'], part['vertexCount'])
        scale = np.asarray(mesh['lossyScale'], dtype=np.float64)
        if not np.isfinite(scale).all() or np.any(scale <= 0): raise ValueError('Unsupported BakeMesh renderer scale')
        transform = np.asarray(mesh['rendererMatrix'], dtype=np.float64).reshape(4, 4).T
        baked_world = np.c_[baked / scale, np.ones(len(baked))] @ transform.T
        source_check = errors(baked_world[:, :3], world, tolerance)
        native_world = np.asarray(part['positions'], dtype=np.float64); native_world[:, 2] *= -1
        vertex_check = errors(native_world, world, tolerance)
        baked_check = errors(native_world, baked_world[:, :3], tolerance)
        if part['morphNames'] != mesh['morphNames']: raise ValueError('Source morph channel identity differs')
        morphs = np.zeros(len(mesh['morphNames']), dtype=np.float64)
        for entry in part['morphWeights']: morphs[entry['index']] = entry['weight']
        morph_error = float(np.max(np.abs(morphs - mesh['morphWeights']))) if len(morphs) else 0.
        joints = part['jointNodes']; source_joints = mesh['skinBones']
        if len(joints) > len(source_joints) or len(joints) != len(mesh['inverseBindMatrices']) or len(joints) != len(part['inverseBindMatrices']):
            raise ValueError('Source/native skin bone counts differ')
        bone_rows = []
        reflection = np.diag([1., 1., -1., 1.])
        for joint, source_joint, inverse, source_inverse in zip(joints, source_joints, part['inverseBindMatrices'], mesh['inverseBindMatrices']):
            if native['nodeNames'][joint] != source_joint['name']: raise ValueError('Source/native ordered skin bone names differ')
            actual = np.asarray(native['nodeWorldMatrices'][joint], dtype=np.float64).reshape(4, 4).T
            expected = reflection @ np.asarray(source_joint['worldMatrix'], dtype=np.float64).reshape(4, 4).T @ reflection
            inverse = np.asarray(inverse, dtype=np.float64).reshape(4, 4).T
            source_inverse = reflection @ np.asarray(source_inverse, dtype=np.float64).reshape(4, 4).T @ reflection
            if not np.isfinite(actual).all() or not np.isfinite(expected).all() or not np.isfinite(inverse).all() or not np.isfinite(source_inverse).all():
                raise ValueError('Nonfinite skin bone matrix')
            if np.max(np.abs(inverse - source_inverse)) > 2e-6: raise ValueError('Source/native inverse-bind identity differs')
            bone_rows.append(dict(nativeNode=joint, sourcePath=source_joint['path'], maximumMatrixError=float(np.max(np.abs(actual - expected)))))
        matched.add(mesh['path'])
        rows.append(dict(name=part['name'], sourcePath=mesh['path'], sourceNodeID=part['nodeSourceID'], restSHA256=key,
                         submesh=submesh, skinBones=bone_rows, unboundSourceBoneTail=source_joints[len(joints):], vertices=vertex_check, nativeVersusBakeMesh=baked_check,
                         bakeMeshVersusSourceMatrix=source_check, morphWeightMaxError=morph_error))
    original_omitted = [dict(path=m['path'], name=m['name'], vertices=m['vertices']) for m in frame['meshes'] if m['path'] not in matched]
    # Original shadow-only geometry is outside the selected drawable assembly.
    # Pin both identity and rest data: any other missing visible mesh fails.
    shadow = ('o_shadowcaster', 'f71b0f52dfe393634b5b8a67f5650f728b666e06cc95357c38c5ee9c09fd95f7') if mode['sex'] == 1 else ('o_shadowcaster_cm', '8fada7d7e00f98d1d4f507a164ac34bd75829380242a54f6d2f3bb8855be0d9b')
    for row in original_omitted:
        mesh = next(m for m in frame['meshes'] if m['path'] == row['path'])
        row['reason'] = 'known source shadow-only mesh excluded from selected drawable assembly' if (mesh['name'], mesh.get('restPositions', {}).get('sha256')) == shadow and mesh['vertices'] == 1360 else 'unaccounted original visible mesh'
    passed = all(row['reason'] != 'unaccounted original visible mesh' for row in original_omitted) and bool(rows) and all(b['maximumMatrixError'] <= tolerance for r in rows for b in r['skinBones'])
    passed &= all(r['vertices']['overTolerance'] == 0 and r['nativeVersusBakeMesh']['overTolerance'] == 0
                  and r['bakeMeshVersusSourceMatrix']['overTolerance'] == 0 and r['morphWeightMaxError'] <= 1e-4 for r in rows)
    return dict(schemaVersion=1, gatePassed=bool(passed), reference='original Unity player transforms, raw BakeMesh and separately calculated source matrix skinning',
                scope='Exact selected rest-position SHA and triangle order; selected skin-joint world matrices and all selected vertices; local/full hierarchy parity is not gated. No fitted time or alignment. Only hash-bound source shadow meshes excluded; color not compared.',
                sourceFrame=file_record(frame_path), nativeInputs=native['inputs'], identity=identity, neutralModel=mode,
                hierarchyDiagnostics=hierarchy, selectedSkinBindings=sum(len(r['skinBones']) for r in rows),
                selectedUniqueNativeBones=len({b['nativeNode'] for r in rows for b in r['skinBones']}),
                skinBoneMatrixTolerance=tolerance, skinBoneMaximumMatrixError=max((b['maximumMatrixError'] for r in rows for b in r['skinBones']), default=0), parts=rows, selectedParts=len(rows), selectedVertexEntries=sum(r['vertices']['count'] for r in rows),
                originalVisibleMeshes=len(frame['meshes']), omittedOriginalComponents=original_omitted, omittedNativeComponents=omitted)


def producer_run(folder):
    path = folder / 'run.json'; run = json.loads(path.read_text())
    if (not isinstance(run.get('vm'), str) or not run['vm']
            or not re.fullmatch(r'C:\\Temp\\IkkokuShaderProbe-[0-9a-f]{32}', run.get('root', ''))
            or type(run.get('processID')) is not int or run['processID'] <= 0
            or not re.fullmatch('[0-9a-f]{64}', run.get('sourceSHA256', ''))
            or run.get('currentUser') is not True or run.get('stopped') is not True):
        raise ValueError('Repeat requires a collected owned source-player run')
    return dict(file=file_record(path), vm=run['vm'], root=run['root'], processID=run['processID'], sourceSHA256=run['sourceSHA256'])


def compare_repeat(first, second):
    if first.resolve() == second.resolve(): raise ValueError('Repeat needs a separate independent capture')
    runs = [producer_run(folder) for folder in (first, second)]
    identities = [(run['vm'], run['root'], run['processID']) for run in runs]
    if identities[0] == identities[1]: raise ValueError('Repeat captures have the same producer run')
    if runs[0]['sourceSHA256'] != runs[1]['sourceSHA256']: raise ValueError('Repeated probe source differs')
    a = json.loads((first / 'frame.json').read_text()); b = json.loads((second / 'frame.json').read_text())
    for key in ('variant', 'sex', 'headID', 'boneType', 'requestedSex', 'requestedHeadID', 'requestedBoneType', 'loadedHeadCatalogID',
                'requestedBodyValues', 'requestedFaceValues', 'actualBodyValues', 'actualFaceValues', 'assemblySHA256', 'animators',
                'hiPoly', 'enableCorrectArmSize', 'enableCorrectHandSize', 'handControllerCounts', 'handPatterns', 'elapsedFramesAfterLoad', 'eyeAngleHRate', 'eyeAngleVRate'):
        if a['neutralModel'][key] != b['neutralModel'][key]: raise ValueError('Repeated source input identity differs')
    ma = {m['path']: m for m in a['meshes']}; mb = {m['path']: m for m in b['meshes']}
    if len(ma) != len(a['meshes']) or len(mb) != len(b['meshes']): raise ValueError('Duplicate renderer paths in repeat')
    if ma.keys() != mb.keys(): raise ValueError('Repeated source renderer identity differs')
    meshes = []
    for key, mesh in ma.items():
        other = mb[key]
        world_a, indices_a = geometry(first, mesh); world_b, indices_b = geometry(second, other)
        if mesh['restPositions']['sha256'] != other['restPositions']['sha256'] or mesh['morphNames'] != other['morphNames']: raise ValueError('Repeated source rest or morph identity differs')
        sidecar(first, mesh['restPositions'], mesh['vertices']); sidecar(second, other['restPositions'], other['vertices'])
        same = all(np.array_equal(x, y) for x, y in zip(indices_a, indices_b)) and len(indices_a) == len(indices_b)
        baked_a = sidecar(first, mesh['bakedPositions'], mesh['vertices']); baked_b = sidecar(second, other['bakedPositions'], other['vertices'])
        meshes.append(dict(path=key, sameTopology=same, matrixPositions=errors(world_a, world_b, 0), bakeMeshPositions=errors(baked_a, baked_b, 0), sameMorphWeights=mesh['morphWeights'] == other['morphWeights']))
    bones_equal = a['bones'] == b['bones']
    passed = bones_equal and all(m['sameTopology'] and m['sameMorphWeights'] and m['matrixPositions']['overTolerance'] == 0 and m['bakeMeshPositions']['overTolerance'] == 0 for m in meshes)
    return dict(gatePassed=passed, first=file_record(first / 'frame.json'), second=file_record(second / 'frame.json'),
                producerRuns=runs, originalOnly=True, bonesByteEqual=bones_equal, boneRecords=len(a['bones']), meshes=meshes,
                animatorsFirst=a['neutralModel']['animators'], animatorsSecond=b['neutralModel']['animators'])


def visual(folder, native, report, output):
    """Matched camera CPU silhouette of selected meshes; this does not test Metal shading."""
    from PIL import Image, ImageDraw
    frame = json.loads((folder / 'frame.json').read_text())
    width, height = frame['width'], frame['height']
    if not 0 < width <= 4096 or not 0 < height <= 4096: raise ValueError('Invalid diagnostic image size')
    camera = frame['camera']
    transform = np.asarray(camera['projection']).reshape(4,4).T @ np.asarray(camera['view']).reshape(4,4).T
    images = [Image.new('1', (width, height)), Image.new('1', (width, height))]
    source_meshes = {mesh['path']: mesh for mesh in frame['meshes']}
    native_parts = {part['name']: part for part in native['parts']}
    for part in report['parts']:
        mesh = source_meshes[part['sourcePath']]; native_part = native_parts[part['name']]
        _, indices = geometry(folder, mesh)
        baked = sidecar(folder, mesh['bakedPositions'], mesh['vertices'])
        matrix = np.asarray(mesh['rendererMatrix']).reshape(4,4).T
        source_positions = (np.c_[baked / mesh['lossyScale'], np.ones(len(baked))] @ matrix.T)[:, :3]
        native_positions = np.asarray(native_part['positions']).copy(); native_positions[:,2] *= -1
        for image, positions in zip(images, (source_positions, native_positions)):
            clip = np.c_[positions, np.ones(len(positions))] @ transform.T
            if np.any(clip[:,3] <= 0): raise ValueError('Diagnostic silhouette requires unclipped fixture geometry')
            xy = clip[:,:2] / clip[:,3:4]
            xy = (xy * [1,-1] + 1) * [width/2,height/2]
            draw = ImageDraw.Draw(image)
            for triangle in indices[part['submesh']].reshape(-1,3): draw.polygon([tuple(p) for p in xy[triangle]], fill=1)
    a,b = (np.asarray(image,dtype=bool) for image in images)
    union = int(np.count_nonzero(a|b)); intersection = int(np.count_nonzero(a&b))
    canvas = Image.new('RGB', (width*2,height+40), 'black'); draw = ImageDraw.Draw(canvas)
    canvas.paste(images[0].convert('RGB'), (0,40));canvas.paste(images[1].convert('RGB'), (width,40))
    draw.text((10,10),'Original BakeMesh / controlled CPU projection',fill='white')
    draw.text((width+10,10),'Native pose + morph + skin / same projection',fill='white')
    canvas.save(output)
    return dict(path=str(output), source='actual original BakeMesh', renderer='controlled CPU triangle union, no shading, no backface culling; not production Metal parity',
                intersection=intersection, union=union, iou=intersection/union if union else 1, differentPixels=int(np.count_nonzero(a!=b)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe_folder', type=Path); parser.add_argument('native_snapshot', type=Path)
    parser.add_argument('--repeat', type=Path, help='independent same-input source capture; exact transform and vertex repeat gate')
    parser.add_argument('--visual-output', type=Path, help='matched-camera diagnostic silhouette PNG (no material/rendering parity claim)')
    args = parser.parse_args()
    result = compare(args.probe_folder, json.loads(args.native_snapshot.read_text()))
    if args.repeat:
        if args.repeat.resolve() == args.probe_folder.resolve(): raise ValueError('Repeat needs a separate independent capture')
        result['repeat'] = compare_repeat(args.probe_folder, args.repeat)
        result['gatePassed'] &= result['repeat']['gatePassed']
    if args.visual_output:
        result['visual'] = visual(args.probe_folder, json.loads(args.native_snapshot.read_text()), result, args.visual_output)
    result['nativeSnapshot'] = file_record(args.native_snapshot)
    print(json.dumps(result, indent=2, allow_nan=False))
    if not result['gatePassed']: raise SystemExit(1)


if __name__ == '__main__': main()
