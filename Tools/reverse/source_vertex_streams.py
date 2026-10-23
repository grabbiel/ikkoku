#!/usr/bin/env python3
"""Export the source vertex channels the converted rigs do not carry — Unity
`TEXCOORD3` (`m_UV3`) and `COLOR` (`m_Colors`) — for the opt-in live
source-shader path (R1/CMT-04). `main_skin` reads both (UV3 drives the body/face
overlay layer, the colour channels mask the detail and liquid effects).

For each requested renderer name the tool scans the given bundles for a
SkinnedMeshRenderer or MeshRenderer GameObject of that name, reads its Mesh
with UnityPy's MeshHandler and writes the channels in the mesh's own vertex
order (the order the converted rig keeps): UV3 as float32 pairs, colours as
float32 RGBA (Color32 bytes / 255). A mesh without a channel records `null`;
the live path then keeps any program that reads it on toon. Renderer names
found in several bundles are all recorded; the live path picks the one whose
vertex count equals the native mesh and refuses ambiguity.

`--verify-frame` compares the export with an original-player capture's
`uv3File` sidecars and frozen-mesh colours for renderers of the same name and
vertex count. Outputs must stay under a `.local` folder.
"""
from __future__ import annotations
import argparse, hashlib, json, struct
from pathlib import Path
import numpy as np


def renderer_meshes(env):
    """(GameObject name, Mesh object reader) for every mesh renderer in a bundle."""
    found = []
    for obj in env.objects:
        kind = obj.type.name
        if kind not in ('SkinnedMeshRenderer', 'MeshRenderer'):
            continue
        renderer = obj.read()
        game_object = renderer.m_GameObject.read()
        if kind == 'SkinnedMeshRenderer':
            mesh = renderer.m_Mesh
        else:
            filters = [c.component for c in game_object.m_Component if c.component.type.name == 'MeshFilter']
            if len(filters) != 1:
                continue
            mesh = filters[0].read().m_Mesh
        if not mesh or not mesh.path_id:
            continue
        found.append((game_object.m_Name, mesh.deref()))
    return found


def channels(reader):
    from UnityPy.helpers.MeshHelper import MeshHandler
    mesh = reader.read()
    handler = MeshHandler(mesh)
    handler.process()
    count = handler.m_VertexCount
    uv3 = handler.m_UV3 if handler.m_UV3 and len(handler.m_UV3) == count else None
    colors = handler.m_Colors if handler.m_Colors and len(handler.m_Colors) == count else None
    if colors is not None:
        colors = np.asarray(colors, dtype=np.float64)
        if color_channel_is_bytes(handler, mesh):
            colors = colors / 255  # Color32 channel: UnityPy returns the raw bytes
        if colors.min() < 0 or colors.max() > 1:
            raise ValueError('%s: vertex colours outside [0, 1] after decoding' % mesh.m_Name)
    return mesh.m_Name, count, uv3, colors


def color_channel_is_bytes(handler, mesh):
    """Whether the mesh stores COLOR as an 8-bit channel (Color32), which
    MeshHandler hands back unnormalized; float and compressed paths are /255 already."""
    vertex_data = getattr(mesh, 'm_VertexData', None)
    channels_ = getattr(vertex_data, 'm_Channels', None) or []
    index = 3 if handler.version[0] >= 2018 else 2
    if index >= len(channels_) or channels_[index].dimension == 0:
        return False
    return handler.get_channel_dtype(channels_[index]) in ('B', 'b')


def export(names, bundles, output):
    import UnityPy
    output.mkdir(parents=True, exist_ok=True)
    entries, missing = [], set(names)
    for bundle in bundles:
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
        relative = 'chara/' + bundle.name if bundle.parent.name == 'chara' else bundle.name
        for name, reader in renderer_meshes(UnityPy.load(str(bundle))):
            if name not in names:
                continue
            mesh_name, count, uv3, colors = channels(reader)
            stem = hashlib.sha256(('%s#%s#%s' % (relative, reader.path_id, name)).encode()).hexdigest()[:16]
            record = dict(mesh=name, meshAsset=mesh_name, bundle=relative, bundleSHA256=digest, pathID=str(reader.path_id),
                          vertexCount=count, uv3File=None, uv3SHA256=None, colorsFile=None, colorsSHA256=None)
            if uv3 is not None:
                data = np.asarray(uv3, dtype='<f4').reshape(count, 2).tobytes()
                record['uv3File'] = stem + '-uv3.bin'; record['uv3SHA256'] = hashlib.sha256(data).hexdigest()
                (output / record['uv3File']).write_bytes(data)
            if colors is not None:
                data = np.asarray(colors, dtype='<f4').reshape(count, 4).tobytes()
                record['colorsFile'] = stem + '-colors.bin'; record['colorsSHA256'] = hashlib.sha256(data).hexdigest()
                (output / record['colorsFile']).write_bytes(data)
            entries.append(record)
            missing.discard(name)
    manifest = dict(schemaVersion=1, scope='Unity m_UV3 and m_Colors of source renderer meshes, in source vertex order, '
                                         'for the live source-shader path. Values are as stored (no V flip, colours /255).',
                    bundles=[str(b) for b in bundles], entries=entries, notFound=sorted(missing))
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def frozen_colors(path):
    """Per-vertex colours of a probe frozen mesh (`mesh-N.bin`)."""
    data = path.read_bytes()
    count = struct.unpack_from('<I', data, 0)[0]
    stride = 4 * (3 + 3 + 4 + 6 + 4)
    rows = np.frombuffer(data, dtype='<f4', count=count * stride // 4, offset=8).reshape(count, stride // 4)
    return rows[:, 16:20]


def verify(manifest_path, frame_path):
    manifest = json.loads(manifest_path.read_text())
    frame = json.loads(frame_path.read_text())
    results = []
    for mesh in frame['meshes']:
        for entry in manifest['entries']:
            if entry['mesh'] != mesh['name']:
                continue
            row = dict(mesh=entry['mesh'], bundle=entry['bundle'], vertexCount=entry['vertexCount'])
            if mesh.get('uv3File'):
                capture = np.frombuffer((frame_path.parent / mesh['uv3File']).read_bytes(), dtype='<f4').reshape(-1, 2)
                row['captureVertexCount'] = len(capture)
                if entry['uv3File'] and len(capture) == entry['vertexCount']:
                    ours = np.frombuffer((manifest_path.parent / entry['uv3File']).read_bytes(), dtype='<f4').reshape(-1, 2)
                    row['uv3MaximumError'] = float(np.abs(ours - capture).max())
                else:
                    row['uv3'] = 'not comparable (absent or vertex count differs)'
            colors = frozen_colors(frame_path.parent / mesh['file'])
            if entry['colorsFile'] and len(colors) == entry['vertexCount']:
                ours = np.frombuffer((manifest_path.parent / entry['colorsFile']).read_bytes(), dtype='<f4').reshape(-1, 4)
                row['colorsMaximumError'] = float(np.abs(ours - colors).max())
            else:
                row['colors'] = 'not comparable (absent or vertex count differs)'
                row['captureColorsUnique'] = [list(map(float, c)) for c in np.unique(colors, axis=0)[:4]]
            results.append(row)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='stream folder (under .local)')
    parser.add_argument('--bundle', type=Path, action='append', required=True)
    parser.add_argument('--mesh', action='append', required=True, help='source renderer GameObject name')
    parser.add_argument('--verify-frame', type=Path)
    args = parser.parse_args()
    if '.local' not in args.output.resolve().parts:
        raise SystemExit('Exported source vertex data must stay under a .local folder')
    manifest = export(set(args.mesh), args.bundle, args.output)
    summary = dict(entries=[(e['mesh'], e['bundle'], e['vertexCount'], bool(e['uv3File']), bool(e['colorsFile'])) for e in manifest['entries']],
                   notFound=manifest['notFound'])
    if args.verify_frame:
        summary['verification'] = verify(args.output / 'manifest.json', args.verify_frame)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
