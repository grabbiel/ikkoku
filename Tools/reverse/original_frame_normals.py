#!/usr/bin/env python3
"""Recover lossless shader NORMAL inputs for a retained original-frame capture.

Requires hash-identified Maker rigs and original source bundles. Reconstructs the
captured skinning inputs, validates positions and normal directions against the
frozen geometry, then writes only renderer-local normal sidecars and a derived
frame in a NEW directory. Other inputs are linked read-only by convention; no
original capture or renderer output is overwritten. No player/VM is executed.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import struct
from pathlib import Path
import numpy as np

POSITION_TOLERANCE = 1e-5
DIRECTION_TOLERANCE = 1e-5


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def local_file(folder, name):
    require(isinstance(name, str) and name and not name.startswith('.') and
            Path(name).name == name, 'Invalid capture filename')
    return folder / name


def world_matrices(bones):
    rows = {}
    for bone in bones:
        path = bone['path']
        require(path not in rows or rows[path] == bone, 'Conflicting duplicate bone path')
        rows[path] = bone
    world = {}
    for path, bone in sorted(rows.items(), key=lambda pair: pair[0].count('/')):
        x, y, z, w = bone['rotation']
        matrix = np.eye(4)
        matrix[:3, :3] = np.array([
            [1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
            [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
            [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]) @ np.diag(bone['scale'])
        matrix[:3, 3] = bone['position']
        parent = path.rsplit('/', 1)[0] if '/' in path else None
        require(parent is None or parent in world, 'Missing captured bone parent')
        world[path] = (world[parent] if parent else np.eye(4)) @ matrix
        require(np.isfinite(world[path]).all(), 'Nonfinite captured bone matrix')
    return world


def reconstruct(frame, capture_mesh, rig, source_mesh, frozen):
    """Return original weighted local normals; never normalize their magnitude."""
    require(rig['coordinateSpace'] == 'unity-left-handed-y-up' and
            rig['matrixLayout'] == 'column-major', 'Unsupported source rig coordinates')
    require(not any(source_mesh['initialMorphWeights']),
            'Active morphs require their original normal deltas; reconstruction is unsupported')
    world = world_matrices(frame['bones'])
    by_name = {}
    for path, matrix in world.items():
        by_name.setdefault(path.rsplit('/', 1)[-1], []).append((path, matrix))
    skin = rig['skins'][source_mesh['skin']]
    require(len(skin['joints']) == len(skin['inverseBindMatrices']), 'Incomplete bind palette')
    palette, paths = [], []
    for joint, inverse_bind in zip(skin['joints'], skin['inverseBindMatrices']):
        candidates = by_name.get(rig['nodes'][joint]['name'], [])
        require(len(candidates) == 1, 'Missing or ambiguous captured source joint')
        paths.append(candidates[0][0])
        palette.append(candidates[0][1] @ np.array(inverse_bind).reshape(4, 4, order='F'))
    palette = np.array(palette)
    positions = np.array(source_mesh['positions'], dtype=float)
    normals = np.array(source_mesh['normals'], dtype=float)
    joints = np.array(source_mesh['joints'])
    weights = np.array(source_mesh['weights'], dtype=float)
    count = len(positions)
    require(0 < count <= 1_000_000 and positions.shape == normals.shape == (count, 3),
            'Invalid source vertex arrays')
    require(joints.shape == weights.shape == (count, 4) and
            np.issubdtype(joints.dtype, np.integer) and (joints >= 0).all() and
            (joints < len(palette)).all(), 'Invalid skin joint indices')
    require(np.isfinite(weights).all() and (weights >= 0).all() and
            np.max(abs(weights.sum(axis=1)-1)) <= 1e-5, 'Invalid skin weights')
    require(frozen.shape == (count, 20) and np.isfinite(frozen).all(), 'Invalid frozen vertex arrays')
    wp, wn = np.zeros_like(positions), np.zeros_like(normals)
    for lane in range(4):
        matrices = palette[joints[:, lane]]
        wp += (np.einsum('nij,nj->ni', matrices[:, :3, :3], positions) +
               matrices[:, :3, 3]) * weights[:, lane, None]
        wn += np.einsum('nij,nj->ni', matrices[:, :3, :3], normals) * weights[:, lane, None]
    lengths = np.linalg.norm(wn, axis=1)
    require(np.isfinite(lengths).all() and (lengths > 0).all(), 'Invalid weighted source normals')
    renderer = np.array(capture_mesh['rendererMatrix']).reshape(4, 4, order='F')
    require(np.isfinite(renderer).all() and abs(np.linalg.det(renderer)) > 1e-8,
            'Invalid captured renderer matrix')
    local = wn @ np.linalg.inv(renderer[:3, :3]).T
    position_error = float(np.max(np.linalg.norm(wp-frozen[:, :3], axis=1)))
    direction_error = float(np.max(np.linalg.norm(wn/lengths[:, None]-frozen[:, 3:6], axis=1)))
    require(position_error <= POSITION_TOLERANCE, 'Source rig does not reproduce frozen positions')
    require(direction_error <= DIRECTION_TOLERANCE, 'Source rig does not reproduce frozen normal directions')
    result = local.astype('<f4')
    require(np.isfinite(result).all(), 'Unrepresentable source normal')
    return result, dict(vertexCount=count, jointPaths=paths,
                       maxPositionErrorMetres=position_error, maxNormalDirectionError=direction_error,
                       weightedLocalNormalLengths=np.quantile(np.linalg.norm(local, axis=1), [0, .5, 1]).tolist(),
                       legacyLocalNormalLengths=np.quantile(np.linalg.norm(frozen[:, 3:6] @ renderer[:3, :3], axis=1), [0, .5, 1]).tolist())


def derive(frame_path, library_path, entries, families, output):
    frame_path, library_path, output = Path(frame_path).resolve(), Path(library_path).resolve(), Path(output).resolve()
    require(not output.exists(), 'Output directory must be new')
    require(output != frame_path.parent and frame_path.parent not in output.parents,
            'Output must be outside the input capture directory')
    frame = json.loads(frame_path.read_text())
    require(frame['schemaVersion'] == 1, 'Unsupported frame schema')
    library = json.loads(library_path.read_text())
    sidecars, reports = {}, []
    for category, entry_id in entries:
        candidates = [e for e in library['entries'] if (e['category'], e['id']) == (category, entry_id)]
        require(len(candidates) == 1, 'Missing or ambiguous Maker entry')
        entry = candidates[0]
        rig_path = (library_path.parent / entry['rig']['file']).resolve()
        require(sha(rig_path) == entry['rig']['sha256'], 'Maker rig SHA256 mismatch')
        rig = json.loads(rig_path.read_text())
        require(bool(rig['sources']), 'Missing original rig provenance')
        for source in rig['sources']:
            require(sha(source['path']) == source['sha256'] == entry['source']['bundleSHA256'],
                    'Original rig bundle SHA256 mismatch')
        for mesh in rig['meshes']:
            matches = [m for m in frame['meshes'] if m['name'] == mesh['name']]
            if not matches:
                continue
            require(len(matches) == 1, 'Ambiguous captured source mesh')
            row = matches[0]
            if families and not any(m['shader'].split('/')[-1] in families for m in row['materials']):
                continue
            require('sourceVertexNormals' not in row, 'Source normals already present')
            geometry = local_file(frame_path.parent, row['file'])
            blob = geometry.read_bytes()
            require(len(blob) >= 8, 'Truncated frozen geometry')
            count, _ = struct.unpack_from('<II', blob)
            require(0 < count <= 1_000_000 and len(blob) >= 8+count*80, 'Invalid frozen geometry extent')
            frozen = np.frombuffer(blob, dtype='<f4', count=count*20, offset=8).reshape(count, 20)
            local, report = reconstruct(frame, row, rig, mesh, frozen)
            filename = Path(row['file']).stem+'-source-normals.bin'
            require(filename not in sidecars, 'Duplicate normal output')
            data = local.tobytes()
            # geometrySHA256 binds the sidecar to the frozen mesh it was validated
            # against; the Swift loader rejects it for any other geometry file.
            row['sourceVertexNormals'] = dict(file=filename, count=count, space='unity-renderer-local',
                                             sha256=hashlib.sha256(data).hexdigest(),
                                             geometrySHA256=hashlib.sha256(blob).hexdigest())
            sidecars[filename] = data
            reports.append(dict(mesh=row['name'], sourceGeometrySHA256=sha(geometry),
                                rigFile=str(rig_path), rigSHA256=sha(rig_path),
                                sourceBundleSHA256=entry['source']['bundleSHA256'],
                                sidecar=row['sourceVertexNormals'], **report))
    require(bool(reports), 'No selected captured meshes were reconstructed')
    provenance = dict(sourceFrameFile=frame_path.name, sourceFrameSHA256=sha(frame_path),
                      librarySHA256=sha(library_path), positionToleranceMetres=POSITION_TOLERANCE,
                      normalDirectionTolerance=DIRECTION_TOLERANCE,
                      reconstruction='captured bone world matrices * original bind poses; weighted normals; renderer inverse linear transform; no normalization',
                      meshes=reports)
    frame['sourceVertexNormalProvenance'] = provenance
    reserved = {'frame-with-source-normals.json', 'source-normal-reconstruction.json'} | set(sidecars)
    require(not any((frame_path.parent/name).exists() for name in reserved), 'Derived output would shadow an input')
    output.mkdir(parents=True)
    for path in frame_path.parent.iterdir():
        if path.name.startswith('native-') or path.name == 'frame-comparison.json':
            continue
        (output/path.name).symlink_to(path, target_is_directory=path.is_dir())
    for name, data in sidecars.items():
        (output/name).write_bytes(data)
    (output/'source-normal-reconstruction.json').write_text(json.dumps(provenance, indent=2)+'\n')
    (output/'frame-with-source-normals.json').write_text(json.dumps(frame, indent=2)+'\n')
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frame', required=True, type=Path)
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--entry', action='append', required=True, help='Maker category:id; repeat for each selected rig')
    parser.add_argument('--family', action='append', default=[], help='Optional captured shader family filter')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    entries = [tuple(map(int, item.split(':'))) for item in args.entry]
    require(all(len(entry) == 2 for entry in entries) and len(set(entries)) == len(entries), 'Invalid or duplicate Maker entry')
    result = derive(args.frame, args.library, entries, set(args.family), args.output)
    print(json.dumps(result, indent=2))

if __name__ == '__main__':
    main()
