#!/usr/bin/env python3
"""Export source vertex channels the converted rigs do not (always) carry —
Unity `TEXCOORD3` (`m_UV3`), `COLOR` (`m_Colors`) and, for meshes whose
converted rig dropped them, `TEXCOORD1`/`TEXCOORD2` (`m_UV1`/`m_UV2`) — for the
opt-in live source-shader path (R1/CMT-04). `main_skin` reads UV3 and COLOR
(UV3 drives the body/face overlay layer, the colour channels mask the detail
and liquid effects); `main_hair` and `main_hair_front` read TEXCOORD1, which
the converted hair rigs do not carry (the native mesh would alias UV0).

For each requested renderer name the tool scans the given bundles for a
SkinnedMeshRenderer or MeshRenderer GameObject of that name, reads its Mesh
with UnityPy's MeshHandler and writes the channels in the mesh's own vertex
order (the order the converted rig keeps): UV3 as float32 pairs, colours as
float32 RGBA (Color32 bytes / 255), UV1/UV2 as float32 pairs. A mesh without a
channel records `null`; the live path then binds the capture fixture's default
for that channel (UV zero, COLOR white) and reports it as a convention. Renderer names
found in several bundles or prefabs are all recorded; the live path picks the
one whose vertex count equals the native mesh and refuses ambiguity, so
`--prefab` should scope bundles that hold several prefabs (hair bundles reuse
renderer names across prefabs with different meshes).

`--verify-frame` compares the export with an original-player capture's
`uv3File` sidecars and frozen-mesh UV1/UV2/colours for renderers of the same
name and vertex count. Outputs must stay under a `.local` folder.
"""
from __future__ import annotations
import argparse, hashlib, json, struct
from pathlib import Path
import numpy as np


def prefab_game_objects(env, prefabs):
    """{GameObject path ID: prefab} for every GameObject under the named
    prefab roots (container paths, case-insensitive) of one bundle."""
    wanted = {p.lower(): p for p in prefabs}
    owned = {}
    for path, reader in env.container.items():
        prefab = wanted.get(path.lower())
        if prefab is None or reader.type.name != 'GameObject':
            continue
        pending = [reader.read()]
        while pending:
            game_object = pending.pop()
            owned[game_object.object_reader.path_id] = prefab
            for component in game_object.m_Component:
                if component.component.type.name in ('Transform', 'RectTransform'):
                    transform = component.component.read()
                    pending += [child.read().m_GameObject.read() for child in transform.m_Children]
    return owned


def renderer_meshes(env, owned=None):
    """(GameObject name, Mesh object reader, prefab) for every mesh renderer
    in a bundle; with `owned`, only renderers under those prefabs."""
    found = []
    for obj in env.objects:
        kind = obj.type.name
        if kind not in ('SkinnedMeshRenderer', 'MeshRenderer'):
            continue
        renderer = obj.read()
        if owned is not None and renderer.m_GameObject.path_id not in owned:
            continue
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
        found.append((game_object.m_Name, mesh.deref(), owned.get(renderer.m_GameObject.path_id) if owned else None))
    return found


def channels(reader):
    from UnityPy.helpers.MeshHelper import MeshHandler
    mesh = reader.read()
    handler = MeshHandler(mesh)
    handler.process()
    count = handler.m_VertexCount
    def uv(values):
        return values if values and len(values) == count else None
    uv1, uv2, uv3 = uv(handler.m_UV1), uv(handler.m_UV2), uv(handler.m_UV3)
    colors = handler.m_Colors if handler.m_Colors and len(handler.m_Colors) == count else None
    if colors is not None:
        colors = np.asarray(colors, dtype=np.float64)
        if color_channel_is_bytes(handler, mesh):
            colors = colors / 255  # Color32 channel: UnityPy returns the raw bytes
        if colors.min() < 0 or colors.max() > 1:
            raise ValueError('%s: vertex colours outside [0, 1] after decoding' % mesh.m_Name)
    return mesh.m_Name, count, dict(uv1=uv1, uv2=uv2, uv3=uv3), colors


def color_channel_is_bytes(handler, mesh):
    """Whether the mesh stores COLOR as an 8-bit channel (Color32), which
    MeshHandler hands back unnormalized; float and compressed paths are /255 already."""
    vertex_data = getattr(mesh, 'm_VertexData', None)
    channels_ = getattr(vertex_data, 'm_Channels', None) or []
    index = 3 if handler.version[0] >= 2018 else 2
    if index >= len(channels_) or channels_[index].dimension == 0:
        return False
    return handler.get_channel_dtype(channels_[index]) in ('B', 'b')


def export(names, bundles, output, prefabs=None):
    import UnityPy
    output.mkdir(parents=True, exist_ok=True)
    entries, missing = [], set(names)
    for bundle in bundles:
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
        relative = 'chara/' + bundle.name if bundle.parent.name == 'chara' else bundle.name
        env = UnityPy.load(str(bundle))
        owned = prefab_game_objects(env, prefabs) if prefabs else {}
        for name, reader, prefab in renderer_meshes(env, owned or None):
            if name not in names:
                continue
            mesh_name, count, uvs, colors = channels(reader)
            stem = hashlib.sha256(('%s#%s#%s' % (relative, reader.path_id, name)).encode()).hexdigest()[:16]
            record = dict(mesh=name, meshAsset=mesh_name, bundle=relative, bundleSHA256=digest, pathID=str(reader.path_id),
                          prefab=prefab, vertexCount=count)
            for channel in ('uv1', 'uv2', 'uv3'):
                record[channel + 'File'] = record[channel + 'SHA256'] = None
                if uvs[channel] is not None:
                    data = np.asarray(uvs[channel], dtype='<f4').reshape(count, 2).tobytes()
                    record[channel + 'File'] = '%s-%s.bin' % (stem, channel); record[channel + 'SHA256'] = hashlib.sha256(data).hexdigest()
                    (output / record[channel + 'File']).write_bytes(data)
            record['colorsFile'] = record['colorsSHA256'] = None
            if colors is not None:
                data = np.asarray(colors, dtype='<f4').reshape(count, 4).tobytes()
                record['colorsFile'] = stem + '-colors.bin'; record['colorsSHA256'] = hashlib.sha256(data).hexdigest()
                (output / record['colorsFile']).write_bytes(data)
            entries.append(record)
            missing.discard(name)
    manifest = dict(schemaVersion=2, scope='Unity m_UV1, m_UV2, m_UV3 and m_Colors of source renderer meshes, in source vertex '
                                         'order, for the live source-shader path. Values are as stored (no V flip, colours /255).',
                    bundles=[str(b) for b in bundles], prefabs=sorted(prefabs) if prefabs else None, entries=entries,
                    notFound=sorted(missing))
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def frozen_rows(path):
    """Per-vertex rows of a probe frozen mesh (`mesh-N.bin`): position 3,
    normal 3, tangent 4, UV0–UV2 2 each, colour 4."""
    data = path.read_bytes()
    count = struct.unpack_from('<I', data, 0)[0]
    stride = 4 * (3 + 3 + 4 + 6 + 4)
    return np.frombuffer(data, dtype='<f4', count=count * stride // 4, offset=8).reshape(count, stride // 4)


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
            rows = frozen_rows(frame_path.parent / mesh['file'])
            for channel, columns in (('uv1', slice(12, 14)), ('uv2', slice(14, 16))):
                if entry.get(channel + 'File') and len(rows) == entry['vertexCount']:
                    ours = np.frombuffer((manifest_path.parent / entry[channel + 'File']).read_bytes(), dtype='<f4').reshape(-1, 2)
                    row[channel + 'MaximumError'] = float(np.abs(ours - rows[:, columns]).max())
                elif len(rows) == entry['vertexCount']:
                    row[channel] = 'absent in the source mesh; capture all zero: %s' % (not rows[:, columns].any())
            colors = rows[:, 16:20]
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
    parser.add_argument('--prefab', action='append', help='in a bundle that holds this prefab container path, only renderers '
                        'under it (repeatable; a converted rig records it as sourcePrefab; bundles holding none of the named '
                        'prefabs stay unscoped). Bundles holding several prefabs reuse renderer names for different meshes, '
                        'which the live path refuses as ambiguous.')
    parser.add_argument('--verify-frame', type=Path)
    args = parser.parse_args()
    if '.local' not in args.output.resolve().parts:
        raise SystemExit('Exported source vertex data must stay under a .local folder')
    manifest = export(set(args.mesh), args.bundle, args.output, args.prefab)
    summary = dict(entries=[(e['mesh'], e['bundle'], e['vertexCount'], [c for c in ('uv1', 'uv2', 'uv3', 'colors') if e[c + 'File']])
                            for e in manifest['entries']],
                   notFound=manifest['notFound'])
    if args.verify_frame:
        summary['verification'] = verify(args.output / 'manifest.json', args.verify_frame)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
