#!/usr/bin/env python3
"""Quiescent native model versus source-player transforms and every selected vertex.

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
from model_shape_input import parse as parse_shapes, canonical as canonical_shapes
from analysis.card_contract import parse_card, mapping as card_mapping, unpack as card_unpack, Limits as CardLimits
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


def shape_values(values, count):
    if (not isinstance(values, list) or len(values) != count
            or any(type(x) not in (int, float) or not np.isfinite(x) or not 0 <= x <= 1 for x in values)):
        raise ValueError('Shape arrays require exactly 44 body / 52 face finite rates in 0...1')
    return np.asarray(values, dtype='<f4')


def recorded_shape_rows(value):
    if not isinstance(value, list): raise ValueError('Recorded shape rows must be an array')
    result = []
    for row in value:
        if (not isinstance(row, dict) or set(row) != {'domain', 'index', 'value'}
                or row['domain'] not in ('body', 'face') or type(row['index']) is not int
                or not 0 <= row['index'] < (44 if row['domain'] == 'body' else 52)
                or type(row['value']) not in (int, float) or not np.isfinite(row['value']) or not 0 <= row['value'] <= 1):
            raise ValueError('Invalid recorded shape row')
        result.append(dict(domain=row['domain'], index=row['index'], value=float(np.float32(row['value']))))
    return result


def shape_readback(mode, native=None):
    coercions = []
    for domain, count in [('Body', 44), ('Face', 52)]:
        requested = shape_values(mode['requested' + domain + 'Values'], count)
        actual = shape_values(mode['actual' + domain + 'Values'], count)
        expected = requested.copy()
        if domain == 'Body' and mode['sex'] == 0:
            expected[0] = np.float32(.6)
            if requested[0] != expected[0]:
                coercions.append(dict(domain='body', index=0, requested=float(requested[0]), actual=float(expected[0]),
                                      reason='ChaControl normal-male saved height coercion'))
        if not np.array_equal(expected, actual):
            raise ValueError('Source unexpectedly changed requested ' + domain.lower() + ' shape values')
        if native is not None and not np.array_equal(actual, shape_values(native[domain.lower() + 'Values'], count)):
            raise ValueError('Source/native shape values differ')
    return coercions


def model_card(folder, frame):
    name = frame['card']
    if Path(name).name != name or not name or name.startswith('.'):
        raise ValueError('Invalid source card path')
    path = folder / name
    return path, parse_card(path.read_bytes())


def custom_records(raw):
    result = {}; offset = 0
    for domain in ('face', 'body', 'hair'):
        if offset + 4 > len(raw): raise ValueError('Truncated Custom record')
        size, = struct.unpack_from('<i', raw, offset); offset += 4
        if size <= 0 or offset + size > len(raw): raise ValueError('Invalid Custom record length')
        result[domain] = raw[offset:offset + size]; offset += size
    result['tail'] = raw[offset:]
    return result


def shape_card_payload(baseline, current, mode, rows=()):
    """Independent raw-token gate: only explicitly requested shape tokens may differ."""
    if [(b['name'], b['version']) for b in baseline.blocks] != [(b['name'], b['version']) for b in current.blocks]:
        raise ValueError('Shape capture changed card block identities')
    if (baseline.report['headerSHA256'] != current.report['headerSHA256']
            or baseline.raw[baseline.report['offsets']['payloadEnd']:] != current.raw[current.report['offsets']['payloadEnd']:]):
        raise ValueError('Shape capture changed card framing or trailing payload')
    if sum(b['name'] == 'Custom' for b in current.blocks) != 1:
        raise ValueError('Shape capture needs exactly one Custom block')
    preserved = []
    for before, after in zip(baseline.blocks, current.blocks):
        name = before['name']
        if name != 'Custom':
            if before['raw'] != after['raw']: raise ValueError('Shape capture changed unedited card block: ' + name)
            preserved.append(name); continue
        old, new = custom_records(before['raw']), custom_records(after['raw'])
        if old['hair'] != new['hair'] or old['tail'] != new['tail']:
            raise ValueError('Shape capture changed hair or trailing Custom bytes')
        for domain, count in [('body', 44), ('face', 52)]:
            key = 'shapeValue' + domain.title()
            a = card_mapping(card_unpack(old[domain], CardLimits()))[key]
            b = card_mapping(card_unpack(new[domain], CardLimits()))[key]
            if a.kind != 'array' or b.kind != 'array': raise ValueError('Missing card shape arrays')
            if old[domain][:a.start] != new[domain][:b.start] or old[domain][a.end:] != new[domain][b.end:]:
                raise ValueError('Shape capture changed an unedited ' + domain + ' token')
            shape_values([x.value for x in a.value], count)
            values = shape_values([x.value for x in b.value], count)
            if old[domain][a.start:a.value[0].start] != new[domain][b.start:b.value[0].start]:
                raise ValueError('Shape capture changed shape array framing')
            allowed = {row['index'] for row in rows if row['domain'] == domain}
            for index, (before_token, after_token) in enumerate(zip(a.value, b.value)):
                if index not in allowed and old[domain][before_token.start:before_token.end] != new[domain][after_token.start:after_token.end]:
                    raise ValueError('Shape capture changed an unrequested ' + domain + ' shape token')
            if not np.array_equal(values, shape_values(mode['actual' + domain.title() + 'Values'], count)):
                raise ValueError('Saved card shapes differ from original-player readback')
    return dict(uneditedBlocks=preserved, hairUnchanged=True, otherBodyFaceTokensUnchanged=True,
                unrequestedShapeTokensUnchanged=True, framingAndTrailingPayloadUnchanged=True, thumbnailsExcluded=True)


HEAD201_CATALOG = dict(Name='タイプ０３', MainManifest='add50', MainAB='chara/bo_head_50.unity3d',
                       MainData='p_cf_head_03', ShapeAnime='cf_anmShapeHead_03')
HEAD200_CATALOG = dict(Name='タイプ０２', MainManifest='add50', MainAB='chara/bo_head_50.unity3d',
                       MainData='p_cf_head_02', ShapeAnime='cf_anmShapeHead_02')
HEAD00_CATALOG = dict(Name='タイプ０１', MainManifest='abdata', MainAB='chara/bo_head_00.unity3d',
                      MainData='p_cf_head_00', ShapeAnime='cf_anmShapeHead_00')


def source_head_identity(mode):
    """Pin the new head's measured catalog; retain old capture compatibility."""
    if mode.get('variant') == 'female200-bone1' or (mode.get('headID') == 200 and mode.get('boneType') == 1):
        if mode.get('variant') != 'female200-bone1':
            raise ValueError('Corrected head200 normal model variant differs')
        expected = dict(sex=1, headID=200, boneType=1, exType=0, requestedSex=1,
                        requestedHeadID=200, requestedBoneType=1, requestedExType=0, loadedHeadCatalogID=200)
        if any(type(mode.get(k)) is not int or mode[k] != v for k, v in expected.items()):
            raise ValueError('Corrected head200 requested/loaded normal model identity differs')
        if mode.get('loadedHeadName') != 'ct_head' or mode.get('loadedHeadCatalog') != HEAD200_CATALOG:
            raise ValueError('Corrected head200 loaded head name or catalog differs from the exact source prefab')
    if mode.get('variant') in ('female00-bone1', 'male00-bone1'):
        sex = 1 if mode['variant'] == 'female00-bone1' else 0
        expected = dict(sex=sex, headID=0, boneType=1, exType=0, requestedSex=sex,
                        requestedHeadID=0, requestedBoneType=1, requestedExType=0, loadedHeadCatalogID=0)
        if any(type(mode.get(k)) is not int or mode[k] != v for k, v in expected.items()):
            raise ValueError('Bone1 requested/loaded normal model identity differs')
        if mode.get('loadedHeadName') != 'ct_head' or mode.get('loadedHeadCatalog') != HEAD00_CATALOG:
            raise ValueError('Bone1 loaded head name or catalog differs from the exact source prefab')
    if mode.get('variant') == 'male00':
        expected = dict(sex=0, headID=0, boneType=0, exType=0, requestedSex=0,
                        requestedHeadID=0, requestedBoneType=0, requestedExType=0, loadedHeadCatalogID=0)
        if any(type(mode.get(k)) is not int or mode[k] != v for k, v in expected.items()):
            raise ValueError('Male00 requested/loaded normal model identity differs')
        if mode.get('loadedHeadName') != 'ct_head' or mode.get('loadedHeadCatalog') != HEAD00_CATALOG:
            raise ValueError('Male00 loaded head name or catalog differs from the exact source prefab')
    if mode.get('variant') in ('female201', 'male201', 'female201-bone1', 'male201-bone1') or mode.get('headID') == 201:
        variant = mode.get('variant')
        if variant not in ('female201', 'male201', 'female201-bone1', 'male201-bone1'):
            raise ValueError('Head201 normal model variant differs')
        sex = 0 if variant in ('male201', 'male201-bone1') else 1
        bone = 1 if variant in ('female201-bone1', 'male201-bone1') else 0
        expected = dict(sex=sex, headID=201, boneType=bone, requestedSex=sex,
                        requestedHeadID=201, requestedBoneType=bone, loadedHeadCatalogID=201)
        if variant in ('male201', 'female201-bone1', 'male201-bone1'): expected.update(exType=0, requestedExType=0)
        if any(type(mode.get(k)) is not int or mode[k] != v for k, v in expected.items()):
            raise ValueError('Head201 requested/loaded normal model identity differs')
        if mode.get('loadedHeadName') != 'ct_head' or mode.get('loadedHeadCatalog') != HEAD201_CATALOG:
            raise ValueError('Head201 loaded head name or catalog differs from the exact source prefab')
    return dict(loadedHeadName=mode.get('loadedHeadName'), loadedHeadCatalog=mode.get('loadedHeadCatalog'))


def body_correction_identity(folder, mode, native=None):
    """Measured source SaveCorrectInfo bytes versus the native decoder input."""
    if mode.get('variant') not in ('female00-bone1', 'male00-bone1', 'female200-bone1', 'female201-bone1', 'male201-bone1'): return None
    source_head_identity(mode)
    record = mode.get('bodyCorrection')
    if (not isinstance(record, dict) or record.get('file') != 'body-correction.bytes'
            or not isinstance(record.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', record['sha256'])
            or any(type(record.get(k)) is not int or record[k] != v
                   for k, v in [('entries', 32), ('sourceBodyType', 1), ('sourceFaceType', 1)])):
        raise ValueError('Invalid corrected body table metadata')
    path = folder / record['file']
    if not path.is_file(): raise ValueError('Missing corrected body table sidecar')
    data = path.read_bytes()
    if (len(data) != 4 + 32 * 9 * 4 or struct.unpack_from('<i', data)[0] != 32
            or hashlib.sha256(data).hexdigest() != record['sha256']):
        raise ValueError('Changed or malformed corrected body table')
    values = np.frombuffer(data, dtype='<f4', offset=4).reshape(32, 9)
    if not np.isfinite(values).all(): raise ValueError('Nonfinite corrected body table')
    # Original Float32 evaluation order, including the addition before division.
    denominator = np.float32(1) + values[2, 7]
    if not np.isfinite(denominator) or denominator <= 0:
        raise ValueError('Invalid corrected head scale denominator')
    expected = float(np.float32(1) / denominator)
    measured = record.get('headCorrectValue')
    if type(measured) not in (int, float):
        raise ValueError('Measured head correction must be finite numeric')
    try: measured = float(measured)
    except OverflowError: raise ValueError('Measured head correction must be finite numeric')
    if (not np.isfinite(measured)
            or not np.isfinite(expected) or abs(measured - expected) > 2e-7):
        raise ValueError('Measured head correction differs from the active body table')
    if native is not None:
        inputs = native.get('inputs')
        if not isinstance(inputs, dict) or inputs.get('bodyCorrectionSHA256') != record['sha256']:
            raise ValueError('Source/native corrected body table identity differs')
    return dict(sha256=record['sha256'], entries=32, sourceBodyType=1, sourceFaceType=1,
                headCorrectValue=expected, measuredHeadCorrectValue=float(np.float32(measured)),
                encoding='LE Int32 count; positionXYZ, rotationXYZ, scaleXYZ Float32 per entry')


def head_collider_scale(frame, native, matching, tolerance):
    """Gate one collider's local column scales, independently of drawable skin."""
    targets = [i for i, name in enumerate(native['nodeNames']) if name == 'cf_hit_head']
    originals = [b for b in frame['bones'] if b['path'].rsplit('/', 1)[-1] == 'cf_hit_head']
    if len(targets) != 1 or len(originals) != 1:
        raise ValueError('Corrected model requires exactly one source and native cf_hit_head')
    index, source = targets[0], originals[0]
    if matching['pairs'].get(index) != source['path']:
        raise ValueError('Corrected cf_hit_head hierarchy identity differs')
    locals_ = native.get('nodeLocalMatrices')
    if not isinstance(locals_, list) or len(locals_) != len(native['nodeNames']):
        raise ValueError('Corrected collider needs aligned native local matrices')
    def vector(values, size):
        if (not isinstance(values, list) or len(values) != size
                or any(type(x) not in (int, float) for x in values)):
            raise ValueError('Corrected collider needs finite numeric local matrix/scale dimensions')
        try: result = np.asarray(values, dtype=np.float64)
        except (ValueError, OverflowError): raise ValueError('Corrected collider needs finite numeric matrix/scale')
        if not np.isfinite(result).all(): raise ValueError('Corrected collider needs finite numeric matrix/scale')
        return result
    local = vector(locals_[index], 16).reshape(4, 4).T
    source_scale = vector(source['scale'], 3)
    actual = np.linalg.norm(local[:3, :3], axis=0)
    if (np.any(source_scale <= 0) or np.any(actual <= 0) or not np.isfinite(actual).all()
            or not np.allclose(local[3], [0, 0, 0, 1], rtol=0, atol=1e-7)
            or np.linalg.det(local[:3, :3]) <= 0):
        raise ValueError('Corrected collider needs positive affine local scales')
    required = float(np.float32(1.08))
    # Both already-evaluated scales must equal 1.08; never multiply the source
    # scale by the correction again or derive it from drawable vertices.
    error = float(max(np.max(np.abs(actual - source_scale)), np.max(np.abs(actual - required)),
                      np.max(np.abs(source_scale - required))))
    return dict(gatePassed=error <= tolerance, target='cf_hit_head', nativeNode=index, sourcePath=source['path'],
                nativeColumnScales=actual.tolist(), sourceLocalScale=source_scale.tolist(), requiredScale=required,
                maximumScaleError=error, tolerance=tolerance,
                scope='Unique cf_hit_head local column scales only; no general local hierarchy parity')


def shape_request_gate(folder, frame, baseline_folder):
    mode = frame['neutralModel']; request = mode.get('shapeRequest')
    if request is None:
        if baseline_folder is not None: raise ValueError('A shape baseline requires a recorded shape request')
        return None
    if baseline_folder is None: raise ValueError('Non-neutral shapes require an independent --shape-baseline')
    if folder.resolve() == baseline_folder.resolve(): raise ValueError('Shape baseline must be a separate neutral capture')
    if request.get('file') != 'model-shapes.tsv' or request.get('stage') != 'saved arrays before LoadAsync':
        raise ValueError('Unsupported model shape request context')
    data = (folder / 'model-shapes.tsv').read_bytes()
    if canonical_shapes(data) != data or hashlib.sha256(data).hexdigest() != request['sha256']:
        raise ValueError('Changed or noncanonical shape request')
    rows = parse_shapes(data)
    if rows != recorded_shape_rows(request.get('rows')): raise ValueError('Shape request rows differ from canonical input')
    run = json.loads((folder / 'run.json').read_text())
    if run.get('modelShapes') != dict(file=request['file'], sha256=request['sha256']):
        raise ValueError('Shape input differs from owned producer request')
    baseline_path = baseline_folder / 'frame.json'; baseline = json.loads(baseline_path.read_text()); base = baseline['neutralModel']
    if base.get('shapeRequest') is not None: raise ValueError('Shape baseline must be an unmodified model capture')
    base_run = json.loads((baseline_folder / 'run.json').read_text())
    if 'modelShapes' in base_run or (baseline_folder / 'model-shapes.tsv').exists():
        raise ValueError('Shape baseline retains producer shape input')
    if source_head_identity(base) != source_head_identity(mode):
        raise ValueError('Shape baseline loaded head context differs')
    for key in ('variant', 'sex', 'headID', 'boneType', 'requestedSex', 'requestedHeadID', 'requestedBoneType',
                'loadedHeadCatalogID', 'assemblySHA256', 'hiPoly', 'enableCorrectArmSize', 'enableCorrectHandSize',
                'handControllerCounts', 'handPatterns', 'elapsedFramesAfterLoad', 'eyeAngleHRate', 'eyeAngleVRate', 'animators'):
        if base[key] != mode[key]: raise ValueError('Shape baseline source identity/context differs: ' + key)
    if body_correction_identity(baseline_folder, base) != body_correction_identity(folder, mode):
        raise ValueError('Shape baseline corrected body table differs')
    if baseline['schemaVersion'] != frame['schemaVersion']: raise ValueError('Shape fixture version differs')
    status = [json.loads((p / 'status.json').read_text()) for p in (baseline_folder, folder)]
    if any(s.get('error') is not None for s in status): raise ValueError('Source capture reported an error')
    for key in ('unity', 'graphicsAPI', 'colorSpace'):
        if not status[0].get(key) or status[0][key] != status[1].get(key): raise ValueError('Shape baseline player context differs: ' + key)
    shape_readback(base)
    for domain, count in [('body', 44), ('face', 52)]:
        expected = shape_values(base['requested' + domain.title() + 'Values'], count).copy()
        for row in rows:
            if row['domain'] == domain: expected[row['index']] = row['value']
        if not np.array_equal(expected, shape_values(mode['requested' + domain.title() + 'Values'], count)):
            raise ValueError('Recorded requested shapes differ from baseline plus explicit input')
        if np.array_equal(expected, shape_values(base['requested' + domain.title() + 'Values'], count)):
            raise ValueError('Mixed-shape gate requires an actual requested change in both domains')
    def geometry_identity(capture):
        return sorted((m['path'], m['name'], m['vertices'], m['submeshes'], m['restPositions']['sha256']) for m in capture['meshes'])
    if geometry_identity(baseline) != geometry_identity(frame): raise ValueError('Shape capture changed selected original geometry')
    base_card_path, base_card = model_card(baseline_folder, baseline)
    card_path, card = model_card(folder, frame)
    payload = shape_card_payload(base_card, card, mode, rows)
    # The baseline's own saved arrays must match its independently recorded readback.
    shape_card_payload(base_card, base_card, base)
    runs = [producer_run(baseline_folder), producer_run(folder)]
    producer_ids = [(r['vm'], r['root'], r['processID']) for r in runs]
    if producer_ids[0] == producer_ids[1]:
        raise ValueError('Shape baseline and capture have the same producer run')
    return dict(input=file_record(folder / 'model-shapes.tsv'), overrides=rows,
                baselineFrame=file_record(baseline_path), baselineCard=file_record(base_card_path), card=file_record(card_path),
                producerRuns=runs, payload=payload,
                scope='Same source assembly/context; only requested body/face arrays may change; thumbnails excluded')


def morph_weight_error(names, sparse, dense):
    """Validate the two producer formats before indexing or broadcasting."""
    count = len(names)
    if not isinstance(dense, list) or len(dense) != count:
        raise ValueError('Source dense morph weights must match the channel count')
    if not isinstance(sparse, list):
        raise ValueError('Native sparse morph weights must be a list')

    def weight(value):
        if type(value) not in (int, float):
            raise ValueError('Morph weight must be a finite numeric value')
        try:
            result = float(value)
        except OverflowError:
            raise ValueError('Morph weight must be a finite numeric value')
        if not np.isfinite(result):
            raise ValueError('Morph weight must be a finite numeric value')
        return result

    expected = np.asarray([weight(value) for value in dense], dtype=np.float64)
    actual = np.zeros(count, dtype=np.float64)
    seen = set()
    for entry in sparse:
        if not isinstance(entry, dict):
            raise ValueError('Native sparse morph weight must be an index/weight record')
        index = entry.get('index')
        if type(index) is not int or not 0 <= index < count:
            raise ValueError('Native sparse morph index must be an integer within the channel count')
        if index in seen:
            raise ValueError('Duplicate native sparse morph index')
        seen.add(index)
        actual[index] = weight(entry.get('weight'))
    return float(np.max(np.abs(actual - expected))) if count else 0.


def compare(folder, native, tolerance=2e-5, shape_baseline=None):
    frame_path = folder / 'frame.json'; frame = json.loads(frame_path.read_text())
    mode = frame.get('neutralModel')
    if not mode or native.get('kind') != 'ikkoku-neutral-source-model': raise ValueError('Requires neutral source and native model captures')
    identity = native['identity']
    variants = {'female00': (1, 0), 'female00-bone1': (1, 0), 'female200': (1, 200), 'female200-bone1': (1, 200), 'female201': (1, 201), 'female201-bone1': (1, 201), 'male00': (0, 0), 'male00-bone1': (0, 0), 'male200': (0, 200), 'male201': (0, 201), 'male201-bone1': (0, 201)}
    if mode.get('variant') not in variants or (mode['sex'], mode['headID']) != variants[mode['variant']]:
        raise ValueError('Unsupported source neutral model identity')
    for key in ('Sex', 'HeadID', 'BoneType'):
        if mode['requested' + key] != mode[key[0].lower() + key[1:]]: raise ValueError('Source silently changed requested identity')
    expected_bone = 1 if mode['variant'] in ('female00-bone1', 'male00-bone1', 'female200-bone1', 'female201-bone1', 'male201-bone1') else 0
    if mode['variant'] == 'male00' and any(type(identity.get(k)) is not int or identity[k] != 0
                                         for k in ('sex', 'headID', 'boneType', 'exType')):
        raise ValueError('Native normal male00 model identity differs')
    if expected_bone == 1 and any(type(identity.get(k)) is not int or identity[k] != v
                                  for k, v in [('sex', variants[mode['variant']][0]), ('headID', variants[mode['variant']][1]), ('boneType', 1), ('exType', 0)]):
        raise ValueError('Native corrected model identity differs')
    if mode['loadedHeadCatalogID'] != mode['headID'] or mode['boneType'] != expected_bone or identity['exType'] != 0:
        raise ValueError('Loaded head or normal body identity differs')
    source_head_identity(mode)
    correction = body_correction_identity(folder, mode, native)
    if mode.get('handControllerCounts') != {'L': 1, 'R': 1}: raise ValueError('Expected exactly two driven hand controllers')
    if mode['handPatterns'] != [0, 0] or mode['elapsedFramesAfterLoad'] != 0:
        raise ValueError('Requires quiescent pattern-zero capture')
    if mode['eyeAngleHRate'] != 0 or mode['eyeAngleVRate'] != 0:
        raise ValueError('Neutral model gate requires measured zero eye angle rates')
    for key, value in native['lateCorrectionOptions'].items():
        if mode[key] != value: raise ValueError('Source/native late correction options differ')
    for key in ('sex', 'headID', 'boneType'):
        if mode[key] != identity[key]: raise ValueError('Source/native model identity mismatch: ' + key)
    if Path(frame['card']).name != frame['card'] or not frame['card'] or frame['card'].startswith('.'):
        raise ValueError('Invalid source card path')
    card_hash = file_record(folder / frame['card'])['sha256']
    if native['inputs']['cardSHA256'] != card_hash: raise ValueError('Source/native card identity differs')
    coercions = shape_readback(mode, native)
    shape_request = shape_request_gate(folder, frame, shape_baseline)
    original_tree = compose_original_worlds(frame['bones']); tree = build_native_tree(native)
    matching = match_bones(tree, original_tree)
    collider = head_collider_scale(frame, native, matching, tolerance) if expected_bone == 1 else None
    hierarchy = {key: value for key, value in matching.items() if key != 'pairs'}
    hierarchy.update(matchedUniquePaths=len(matching['pairs']), nativeNodes=len(native['nodeNames']), sourceRecords=len(frame['bones']))
    candidates = {}
    for mesh in frame['meshes']:
        if 'restPositions' not in mesh: continue
        # Head201's upper/lower eyeline renderers share the same rest vertices.
        # Bind both exact geometry and renderer name; duplicate pairs still fail.
        key = (mesh['restPositions']['sha256'], mesh['name'])
        candidates.setdefault(key, []).append(mesh)
    rows, omitted, matched = [], [], set()
    for part in native['parts']:
        if not part['selected']:
            omitted.append(dict(name=part['name'], reason=part['selectionReason'])); continue
        if part['hasCloth']: raise ValueError('Neutral model gate does not approximate Unity Cloth')
        rest = np.asarray(part['restPositions'], dtype='<f4'); rest[:, 2] *= -1
        name = part['name'].split('/')[-2]; submesh = int(part['name'].split('/')[-1])
        key = (hashlib.sha256(rest.tobytes()).hexdigest(), name)
        matches = candidates.get(key, [])
        if len(matches) != 1: raise ValueError('Missing or ambiguous exact source vertex identity: ' + part['name'])
        mesh = matches[0]
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
        morph_error = morph_weight_error(mesh['morphNames'], part['morphWeights'], mesh['morphWeights'])
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
        rows.append(dict(name=part['name'], sourcePath=mesh['path'], sourceNodeID=part['nodeSourceID'], restSHA256=key[0],
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
    if collider is not None: passed &= collider['gatePassed']
    return dict(schemaVersion=1, gatePassed=bool(passed), reference='original Unity player transforms, raw BakeMesh and separately calculated source matrix skinning',
                scope='Exact selected rest-position SHA and triangle order; selected skin-joint world matrices and all selected vertices. Apart from the separately reported cf_hit_head local-scale gate for bone1, local/full hierarchy parity is not gated. No fitted time or alignment. Only hash-bound source shadow meshes excluded; color not compared.',
                sourceFrame=file_record(frame_path), shapeRequest=shape_request, shapeCoercions=coercions, nativeInputs=native['inputs'], identity=identity, neutralModel=mode,
                bodyCorrection=correction, headColliderScale=collider,
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
    if source_head_identity(a['neutralModel']) != source_head_identity(b['neutralModel']):
        raise ValueError('Repeated loaded head context differs')
    if body_correction_identity(first, a['neutralModel']) != body_correction_identity(second, b['neutralModel']):
        raise ValueError('Repeated corrected body table differs')
    for key in ('variant', 'sex', 'headID', 'boneType', 'requestedSex', 'requestedHeadID', 'requestedBoneType', 'loadedHeadCatalogID',
                'requestedBodyValues', 'requestedFaceValues', 'actualBodyValues', 'actualFaceValues', 'assemblySHA256', 'animators',
                'hiPoly', 'enableCorrectArmSize', 'enableCorrectHandSize', 'handControllerCounts', 'handPatterns', 'elapsedFramesAfterLoad', 'eyeAngleHRate', 'eyeAngleVRate'):
        if a['neutralModel'][key] != b['neutralModel'][key]: raise ValueError('Repeated source input identity differs')
    if a['neutralModel'].get('shapeRequest') != b['neutralModel'].get('shapeRequest'):
        raise ValueError('Repeated shape request differs')
    for folder, frame in [(first, a), (second, b)]:
        request = frame['neutralModel'].get('shapeRequest')
        if request is not None:
            data = (folder / 'model-shapes.tsv').read_bytes()
            if canonical_shapes(data) != data or hashlib.sha256(data).hexdigest() != request['sha256']:
                raise ValueError('Changed repeated shape input')
            run = json.loads((folder / 'run.json').read_text())
            if run.get('modelShapes') != dict(file=request['file'], sha256=request['sha256']):
                raise ValueError('Repeated producer shape input differs')
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
    parser.add_argument('--shape-baseline', type=Path, help='independent same-model neutral capture; required for mixed shape input and unedited-card gate')
    parser.add_argument('--repeat', type=Path, help='independent same-input source capture; exact transform and vertex repeat gate')
    parser.add_argument('--visual-output', type=Path, help='matched-camera diagnostic silhouette PNG (no material/rendering parity claim)')
    args = parser.parse_args()
    result = compare(args.probe_folder, json.loads(args.native_snapshot.read_text()), shape_baseline=args.shape_baseline)
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
