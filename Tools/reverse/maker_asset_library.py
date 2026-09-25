#!/usr/bin/env python3
"""Export explicitly selected Maker catalog geometry into a hash-addressed library.

The library does not rewrite card identities. Only exact installed catalog rows are
accepted; original data and derived images stay under ignored .local/. No card
thumbnail is decoded. The default selection consists of ordinary hair, shirts,
long trousers, shoes and glasses, with clothes fixed to their fully dressed state.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

import msgpack
import UnityPy

from head_material_contract import material
from rig_inventory import Inspector, identity, uv_channel

ROOT = Path(__file__).resolve().parents[2]
TABLES = {101: 'bo_hair_b_00', 102: 'bo_hair_f_00', 103: 'bo_hair_s_00',
          104: 'bo_hair_o_00', 105: 'co_top_00', 106: 'co_bot_00',
          107: 'co_bra_00', 108: 'co_shorts_00', 109: 'co_gloves_00',
          110: 'co_panst_00', 111: 'co_socks_00', 112: 'co_shoes_00',
          123: 'ao_face_00'}
DEFAULT_SELECTION = [(101, i) for i in (0, 2, 9)] + [(102, i) for i in (1, 2, 5)] + [
    (105, 38), (105, 3), (105, 39), (105, 13), (106, 3), (106, 25),
    (112, 1), (112, 3), (123, 0)]
IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value, compact=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=None if compact else 2, allow_nan=False) + '\n')


def local_output(path: Path):
    if not path.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Original and derived game data must remain under ignored .local/')


def source_file(shared: Path, relative: str):
    p = PurePosixPath(relative)
    if p.is_absolute() or '..' in p.parts or '\\' in relative or ':' in relative:
        raise ValueError('Invalid relative source bundle path')
    path = shared / 'source/abdata' / Path(*p.parts)
    record = json.loads(path.with_name(path.name + '.provenance.json').read_text())
    if digest(path) != record['sha256']:
        raise ValueError('Source SHA-256 differs from VM transfer: ' + relative)
    return path


def catalog_table(environment, name):
    matches = [r for k, r in environment.container.items() if k.endswith('/' + name + '.bytes')]
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous catalog table: ' + name)
    data = matches[0].read().m_Script
    if isinstance(data, str):
        data = data.encode('utf-8', 'surrogateescape')
    return msgpack.unpackb(bytes(data), raw=False, strict_map_key=False)


def select_row(table, item_id):
    rows = [dict(zip(table['lstKey'], r, strict=True)) for r in table['dictList'].values()
            if int(r[0]) == item_id]
    if len(rows) != 1:
        raise ValueError('Missing or ambiguous original catalog ID: ' + str(item_id))
    return rows[0]


def ancestors(nodes, index):
    visited = set()
    while index is not None:
        if index in visited:
            raise ValueError('Cyclic original transform hierarchy')
        visited.add(index)
        yield nodes[index]
        index = nodes[index]['parent']


def fully_dressed(nodes, mesh, category):
    """Source clothing switch *_DEF is state 0; *_NUGE is state 1.

    The selected shirt prefabs use n_top_a / n_top_b, both serialized active.
    Retaining the second merely because it is active would overlay the half-off
    mesh. ChaReference maps the same top/bottom switch names for clothes 0–3.
    """
    chain = list(ancestors(nodes, mesh['node']))
    if not mesh.get('rendererEnabled', True) or any(not n.get('active', True) for n in chain):
        return False
    hidden = {'n_top_b', 'n_bot_b', 'n_bot_c'} if 105 <= category <= 108 else {'n_panst_b'} if category == 110 else set()
    if any(n['name'] in hidden for n in chain):
        return False
    return True


def static_mesh_record(inspector, nodes, node_index, mesh_reader, renderer, skin_index):
    """Represent a static renderer by its own node as a single identity joint.

    Native skinning then evaluates inverse(meshWorld)*meshWorld*I, followed by
    meshWorld, exactly matching the original MeshRenderer transform.
    """
    summary, handler, shapes = inspector.mesh(mesh_reader)
    count = handler.m_VertexCount
    if count <= 0 or shapes.get('channels') or len(handler.m_Normals or []) != count:
        raise ValueError('Static accessory needs complete normals and no blend shapes')
    triangles = list(handler.get_triangles())
    if any(len(t) != 3 or any(i < 0 or i >= count for i in t) for faces in triangles for t in faces):
        raise ValueError('Invalid static accessory triangles')
    skin = dict(name=summary['name'], meshNode=node_index, joints=[node_index],
                rootJoint=node_index, inverseBindMatrices=[IDENTITY])
    mesh = dict(name=summary['name'], node=node_index, skin=skin_index,
                rendererEnabled=renderer.m_Enabled, hasCloth=False,
                positions=handler.m_Vertices, normals=[v[:3] for v in handler.m_Normals],
                tangents=handler.m_Tangents or [],
                uv0=uv_channel(handler.m_UV0, count, 'UV0'),
                uv1=uv_channel(handler.m_UV1, count, 'UV1'),
                uv2=uv_channel(handler.m_UV2, count, 'UV2'),
                joints=[[0, 0, 0, 0] for _ in range(count)],
                weights=[[1, 0, 0, 0] for _ in range(count)],
                submeshes=[dict(indices=[i for t in faces for i in t]) for faces in triangles],
                morphChannels=[], morphFrames=[], initialMorphWeights=[])
    return skin, mesh


def prefab_renderers(environment, prefab, inspector, neutral):
    nodes = neutral['nodes']; indices = {n['sourceID']: i for i, n in enumerate(nodes)}
    renderers = []

    def visit(go):
        transform = next(c.component.read() for c in go.m_Component if c.component.type.name == 'Transform')
        index = indices[identity(transform.object_reader)]
        for component in go.m_Component:
            kind = component.component.type.name
            if kind not in ('SkinnedMeshRenderer', 'MeshRenderer'):
                continue
            renderer = component.component.read()
            if kind == 'MeshRenderer':
                filters = [c.component.read() for c in go.m_Component if c.component.type.name == 'MeshFilter']
                if len(filters) != 1:
                    raise ValueError('Static accessory requires exactly one MeshFilter')
                mesh_reader = filters[0].m_Mesh.deref()
                skin, mesh = static_mesh_record(inspector, nodes, index, mesh_reader, renderer, len(neutral['skins']))
                neutral['skins'].append(skin); neutral['meshes'].append(mesh)
            else:
                mesh_reader = renderer.m_Mesh.deref()
            renderers.append((index, renderer, mesh_reader.peek_name(), kind))
        for child in transform.m_Children:
            visit(child.read().m_GameObject.read())
    visit(environment.container[prefab].read())
    return renderers


class Builder:
    def __init__(self, shared: Path, output: Path):
        local_output(output); output.mkdir(parents=True, exist_ok=True)
        self.shared, self.output = shared, output
        self.catalog_path = source_file(shared, 'list/characustom/00.unity3d')
        self.catalog = UnityPy.load(str(self.catalog_path))
        self.environments = {}

    def environment(self, relative):
        if relative not in self.environments:
            path = source_file(self.shared, relative)
            self.environments[relative] = (path, UnityPy.load(str(path)))
        return self.environments[relative]

    def texture(self, texture, directory):
        # Only the selected prefab's appearance inputs are decoded, never cards.
        image = texture.image.convert('RGBA')
        if image.width > 4096 or image.height > 4096 or image.width * image.height > 4_194_304:
            raise ValueError('Selected material texture exceeds native bound')
        pixels = image.tobytes(); key = hashlib.sha256(pixels).hexdigest()[:16]
        name = ''.join(c if c.isalnum() or c in '_.-' else '_' for c in texture.m_Name)
        path = directory / 'textures' / (name + '-' + key + '.png')
        path.parent.mkdir(exist_ok=True); image.save(path)
        return dict(file=str(path.relative_to(self.output)), sha256=digest(path),
                    width=image.width, height=image.height, name=texture.m_Name)

    def named_texture(self, bundle, name, directory):
        _, environment = self.environment(bundle)
        matches = [r for r in environment.objects if r.type.name == 'Texture2D' and r.peek_name() == name]
        if len(matches) != 1:
            raise ValueError('Missing or ambiguous catalog texture: ' + name)
        return self.texture(matches[0].read(), directory)

    def entry(self, category, item_id):
        table_name = TABLES[category]
        row = select_row(catalog_table(self.catalog, table_name), item_id)
        source = dict(bundle=row['MainAB'], asset=row['MainData'],
                      catalogSHA256=digest(self.catalog_path), catalogTable=table_name)
        entry = dict(category=category, id=item_id, name=row['Name'], source=source)
        if row['MainData'] == 'p_dummy':
            entry['empty'] = True
            return entry, None
        directory = self.output / 'assets' / f'{category}-{item_id}'
        directory.mkdir(parents=True, exist_ok=True)
        path, environment = self.environment(row['MainAB']); source['bundleSHA256'] = digest(path)
        prefabs = [k for k in environment.container if k.endswith('/' + row['MainData'] + '.prefab')]
        if len(prefabs) != 1:
            raise ValueError('Missing or ambiguous catalog prefab: ' + row['MainData'])
        inspector = Inspector(environment)
        neutral = inspector.neutral(prefabs[0], False, True)
        renderers = prefab_renderers(environment, prefabs[0], inspector, neutral)
        selected = [m for m in neutral['meshes'] if fully_dressed(neutral['nodes'], m, category)]
        if not selected or len({m['name'] for m in selected}) != len(selected):
            raise ValueError('Selected catalog prefab requires nonempty unique drawable meshes')
        entry['meshNames'] = [m['name'] for m in selected]
        neutral['sources'] = [dict(path=str(path.resolve()), bytes=path.stat().st_size, sha256=digest(path))]
        rig_path = directory / 'rig.json'; write_json(rig_path, neutral, compact=True)
        entry['rig'] = dict(file=str(rig_path.relative_to(self.output)), sha256=digest(rig_path))
        if category >= 120:
            parent = row['Parent']
            if parent in ('0', 'null', 'none') or not parent.startswith('a_n_'):
                raise ValueError('This library only exports ordinary bone-parented accessories')
            entry['attachment'] = dict(parent=parent, positionScale=.01,
                                       moveNodes=['N_move', 'N_move2'],
                                       ignoreMoves=row.get('HideHair', '0') == '1')
        materials = []
        for node, renderer, mesh_name, kind in renderers:
            if mesh_name not in entry['meshNames']:
                continue
            for slot, pointer in enumerate(renderer.m_Materials):
                reader = pointer.deref(); info = material(reader)
                textures = {}
                for prop, saved in reader.read().m_SavedProperties.m_TexEnvs:
                    if prop not in ('_MainTex', '_ColorMask', '_AlphaMask', '_LineMask') or not saved.m_Texture.path_id:
                        continue
                    if saved.m_Texture.type.name != 'Texture2D':
                        raise ValueError('Selected appearance texture is not Texture2D')
                    textures[prop] = dict(self.texture(saved.m_Texture.read(), directory),
                                          scale=[saved.m_Scale.x, saved.m_Scale.y],
                                          offset=[saved.m_Offset.x, saved.m_Offset.y])
                shader_tree = reader.read().m_Shader.read_typetree()
                shader_path = directory / ('shader-' + hashlib.sha256(info['shader'].encode()).hexdigest()[:12] + '.json')
                write_json(shader_path, shader_tree)
                materials.append(dict(meshName=mesh_name, nodeName=neutral['nodes'][node]['name'],
                                      materialSlot=slot, rendererKind=kind, material=info,
                                      materialTree=reader.read_typetree(), textures=textures,
                                      shaderTree=dict(file=str(shader_path.relative_to(self.output)), sha256=digest(shader_path))))
        component_trees = [c.component.read_typetree() for c in environment.container[prefabs[0]].read().m_Component
                           if c.component.type.name == 'MonoBehaviour']
        catalog_textures = {}
        if 105 <= category <= 112:
            for role, name_key, ab_key in [('main', 'MainTex', 'MainTexAB'), ('mask', 'ColorMaskTex', 'ColorMaskAB'),
                                         ('bodyMask', 'OverBodyMask', 'OverBodyMaskAB')]:
                name = row.get(name_key, '0')
                if name and name != '0':
                    bundle = row.get(ab_key, '0')
                    catalog_textures[role] = self.named_texture(bundle if bundle != '0' else row['MainAB'], name, directory)
        evidence = dict(schemaVersion=1, category=category, id=item_id, source=source,
                        catalog=row, meshNames=entry['meshNames'], renderers=materials,
                        catalogTextures=catalog_textures, componentTrees=component_trees,
                        limits=['Only fully dressed state 0 meshes are selected; alternate clothes states remain unimplemented.',
                                'Skin binding data are preserved; this exporter does not implement original cloth or accessory dynamics.'])
        material_path = directory / 'materials.json'; write_json(material_path, evidence)
        entry['materialEvidence'] = dict(file=str(material_path.relative_to(self.output)), sha256=digest(material_path))
        return entry, evidence

    def build(self, selections):
        entries = []; material_inputs = []
        requested = list(dict.fromkeys(selections))
        # An ID of zero is not intrinsically empty (hair-back and glasses prove
        # this). Include removal only when an exact catalog row says p_dummy.
        for category in TABLES:
            try:
                row = select_row(catalog_table(self.catalog, TABLES[category]), 0)
                if row['MainData'] == 'p_dummy' and (category, 0) not in requested:
                    requested.append((category, 0))
            except ValueError:
                pass
        for category, item_id in requested:
            entry, material_input = self.entry(category, item_id)
            entries.append(entry)
            if material_input:
                material_inputs.append(entry['materialEvidence']['file'])
            print(f'Exported catalog {category}:{item_id}', flush=True)
        index = dict(schemaVersion=1, entries=entries, limitations=[
            'Explicit installed vanilla catalog selection only; unknown and modded identities are never replaced by numeric-ID guesses.',
            'Source geometry and attachment semantics only; material and behavior coverage are tracked by per-entry sidecars.'])
        old_index = self.output / 'library.json'
        if old_index.exists():
            old = json.loads(old_index.read_text())
            if 'assemblies' in old:
                index['assemblies'] = old['assemblies']
        assemblies = self.output / 'heads/assemblies.json'
        if assemblies.exists():
            index['assemblies'] = json.loads(assemblies.read_text())['assemblies']
        write_json(old_index, index)
        write_json(self.output / 'material-inputs.json', dict(schemaVersion=1, files=material_inputs))
        return index


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared', type=Path, default=ROOT / '.local/reverse/rigs')
    parser.add_argument('--output', type=Path, default=ROOT / '.local/reverse/maker-library')
    parser.add_argument('--select', action='append', help='Exact vanilla CATEGORY:ID (repeatable); default explicit clothed reference expansion')
    args = parser.parse_args()
    selections = [tuple(map(int, s.split(':'))) for s in args.select] if args.select else DEFAULT_SELECTION
    if any(len(s) != 2 or s[0] not in TABLES or s[1] < 0 for s in selections):
        parser.error('Each selection must be a supported CATEGORY:ID')
    result = Builder(args.shared, args.output).build(selections)
    print(json.dumps(dict(index=str(args.output / 'library.json'), entries=len(result['entries'])), indent=2))


if __name__ == '__main__':
    main()
