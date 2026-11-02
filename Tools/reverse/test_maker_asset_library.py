#!/usr/bin/env python3
"""Catalog safety tests and independent installed Unity geometry audit.

The installed audit reads the selected Unity meshes directly using MeshHandler;
it does not call the exporter to compute the expected positions, binds or nodes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import msgpack
import numpy as np
import UnityPy
from UnityPy.helpers.MeshHelper import MeshHandler

from maker_asset_library import (Builder, MissingCatalogRow, category_row, list_tables, fully_dressed, alternate,
                                  source_file, write_json, IDENTITY, SWITCH_RULES)


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_matrix(position, rotation, scale):
    x, y, z, w = rotation
    result = np.eye(4)
    result[:3, :3] = np.array([
        [1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
        [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
        [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)],
    ]) @ np.diag(scale)
    result[:3, 3] = position
    return result


def audit_library(path):
    """Audits the dressed meshes and the half-state alternates of every entry."""
    directory = path.parent; library = json.loads(path.read_text())
    reports = []; environments = {}
    for entry in library['entries']:
        if 'rig' not in entry:
            continue
        rig_path = directory / entry['rig']['file']
        if not rig_path.resolve().is_relative_to(directory.resolve()) or file_hash(rig_path) != entry['rig']['sha256']:
            raise ValueError('Untrusted rig reference')
        rig = json.loads(rig_path.read_text()); source = Path(rig['sources'][0]['path'])
        if file_hash(source) != entry['source']['bundleSHA256']:
            raise ValueError('Original bundle changed')
        if source not in environments:
            environments[source] = UnityPy.load(str(source))
        environment = environments[source]
        game_object = environment.container[rig['sourcePrefab']].read()
        source_nodes = []; source_meshes = {}
        alternates = [a['meshName'] for a in entry.get('alternates', [])]
        audited = set(entry['meshNames']) | set(alternates)
        if len(audited) != len(entry['meshNames']) + len(alternates):
            raise ValueError('Alternate and dressed mesh names overlap')

        def visit(go, parent):
            transform = next(c.component.read() for c in go.m_Component if c.component.type.name == 'Transform')
            index = len(source_nodes)
            v, q, s = transform.m_LocalPosition, transform.m_LocalRotation, transform.m_LocalScale
            local = local_matrix([v.x, v.y, v.z], [q.x, q.y, q.z, q.w], [s.x, s.y, s.z])
            world = local if parent is None else source_nodes[parent]['world'] @ local
            source_nodes.append(dict(name=go.m_Name, parent=parent, local=local, world=world))
            for component in go.m_Component:
                kind = component.component.type.name
                if kind not in ('SkinnedMeshRenderer', 'MeshRenderer'):
                    continue
                renderer = component.component.read()
                mesh = renderer.m_Mesh.read() if kind == 'SkinnedMeshRenderer' else next(
                    c.component.read().m_Mesh.read() for c in go.m_Component if c.component.type.name == 'MeshFilter')
                if mesh.m_Name not in audited:
                    continue
                handler = MeshHandler(mesh); handler.process()
                source_meshes[mesh.m_Name] = dict(handler=handler, mesh=mesh, node=index, kind=kind)
            for child in transform.m_Children:
                visit(child.read().m_GameObject.read(), index)
        visit(game_object, None)
        if len(source_nodes) != len(rig['nodes']):
            raise ValueError('Exported transform count differs from original')
        transform_error = 0
        for expected, actual in zip(source_nodes, rig['nodes'], strict=True):
            if expected['name'] != actual['name'] or expected['parent'] != actual['parent']:
                raise ValueError('Exported hierarchy differs from original')
            transform_error = max(transform_error, float(np.max(np.abs(expected['local'] - local_matrix(
                actual['translation'], actual['rotation'], actual['scale'])))))
        vertices = 0; static_vertices = 0; static_error = 0
        for mesh in rig['meshes']:
            if mesh['name'] not in audited:
                continue
            original = source_meshes[mesh['name']]; handler = original['handler']
            for actual, expected in [(mesh['positions'], handler.m_Vertices),
                                     (mesh['normals'], [n[:3] for n in handler.m_Normals]),
                                     (mesh['uv0'], handler.m_UV0 or []),
                                     (mesh['tangents'], handler.m_Tangents or [])]:
                if not np.array_equal(np.asarray(actual), np.asarray(expected)):
                    raise ValueError('Exported vertex attributes differ from original')
            expected_faces = list(handler.get_triangles())
            if len(expected_faces) != len(mesh['submeshes']) or any(
                [i for face in faces for i in face] != submesh['indices']
                for faces, submesh in zip(expected_faces, mesh['submeshes'])):
                raise ValueError('Exported topology differs from original')
            skin = rig['skins'][mesh['skin']]
            if original['kind'] == 'SkinnedMeshRenderer':
                binds = [[getattr(m, f'e{row}{column}') for column in range(4) for row in range(4)]
                         for m in original['mesh'].m_BindPose]
                if binds != skin['inverseBindMatrices']:
                    raise ValueError('Exported inverse binds differ from original')
            else:
                if skin['joints'] != [mesh['node']] or skin['inverseBindMatrices'] != [IDENTITY]:
                    raise ValueError('Static accessory does not use an exact identity joint')
                p = np.c_[handler.m_Vertices, np.ones(handler.m_VertexCount)]
                # Exercise attachment with arbitrary translation, rotation and
                # nonuniform scale; source MeshRenderer is the independent RHS.
                for angle in [0, .3, -.9]:
                    parent = local_matrix([.27, 1.1, -.4], [0, np.sin(angle/2), 0, np.cos(angle/2)], [.7, 1.2, 1.1])
                    world = parent @ source_nodes[original['node']]['world']
                    palette = np.linalg.inv(world) @ world @ np.asarray(skin['inverseBindMatrices'][0]).reshape(4, 4, order='F')
                    actual = (world @ palette @ p.T).T
                    expected = (world @ p.T).T
                    static_error = max(static_error, float(np.max(np.abs(actual - expected))))
                static_vertices += handler.m_VertexCount
            vertices += handler.m_VertexCount
        if set(source_meshes) != audited:
            raise ValueError('A selected mesh is missing or ambiguous')
        reports.append(dict(category=entry['category'], id=entry['id'], selectedMeshes=len(source_meshes),
                            alternateMeshes=len(alternates),
                            vertices=vertices, originalAttributeDifference=0,
                            nodeMatrixMaxAbsoluteError=transform_error,
                            staticVertices=static_vertices, staticWorldMaxAbsoluteError=static_error))
    return dict(schemaVersion=1, librarySHA256=file_hash(path), entries=reports,
                geometryEntries=len(reports), selectedVertices=sum(x['vertices'] for x in reports),
                alternateMeshes=sum(x['alternateMeshes'] for x in reports),
                passed=all(x['nodeMatrixMaxAbsoluteError'] < 1e-12 and x['staticWorldMaxAbsoluteError'] < 1e-12 for x in reports))


def list_table(category, *rows):
    """A synthetic ChaListData table: rows of (ID, MainData)."""
    return dict(categoryNo=category, lstKey=['ID', 'MainData'],
                dictList={str(i): [str(item), data] for i, (item, data) in enumerate(rows)})


class MakerAssetLibraryTests(unittest.TestCase):
    def test_zero_is_not_intrinsically_empty(self):
        tables = [('00', 'hair_b_00', list_table(101, (0, 'p_long_hair')))]
        self.assertEqual(category_row(tables, 101, 0)[2]['MainData'], 'p_long_hair')

    def test_duplicate_identity_is_rejected(self):
        tables = [('00', 'hair_b_00', list_table(101, (7, 'a'), (7, 'b')))]
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            category_row(tables, 101, 7)

    def test_missing_identity_is_rejected(self):
        with self.assertRaises(MissingCatalogRow):
            category_row([('00', 'hair_b_00', list_table(101, (0, 'p_dummy')))], 101, 3)

    def test_row_is_found_in_a_second_list_table(self):
        # The table's categoryNo selects it, not its name; another category's
        # row with the same ID is not a match.
        tables = [('00', 'hair_b_00', list_table(101, (0, 'p_b0'), (2, 'p_b2'))),
                  ('06', 'hair_f_06', list_table(102, (28, 'p_f28'))),
                  ('06', 'hair_b_06', list_table(101, (28, 'p_b28')))]
        self.assertEqual(category_row(tables, 101, 28), ('06', 'hair_b_06', dict(ID='28', MainData='p_b28')))
        self.assertEqual(category_row(tables, 102, 28)[:2], ('06', 'hair_f_06'))
        self.assertEqual(category_row(tables, 101, 2)[:2], ('00', 'hair_b_00'))

    def test_id_in_two_tables_of_a_category_is_rejected(self):
        tables = [('00', 'hair_b_00', list_table(101, (5, 'a'))), ('06', 'hair_b_06', list_table(101, (5, 'b')))]
        with self.assertRaisesRegex(ValueError, 'Ambiguous original catalog ID 101:5 in tables hair_b_00, hair_b_06') as caught:
            category_row(tables, 101, 5)
        # build() skips only a missing zero row; an ambiguous one stays an error.
        self.assertNotIsInstance(caught.exception, MissingCatalogRow)

    def test_id_missing_from_every_table_is_rejected(self):
        tables = [('00', 'hair_b_00', list_table(101, (0, 'a'))), ('06', 'hair_b_06', list_table(101, (28, 'b'))),
                  ('06', 'hair_o_06', list_table(104, (9, 'c')))]
        with self.assertRaisesRegex(MissingCatalogRow, '101:9'):
            category_row(tables, 101, 9)

    def test_list_tables_reads_only_list_data(self):
        def asset(data):
            return SimpleNamespace(read=lambda: SimpleNamespace(m_Script=data))
        table = list_table(101, (28, 'p_b28'))
        container = {'abdata/list/characustom/06/hair_b_06.bytes': asset(msgpack.packb(table)),
                     'abdata/list/characustom/06/notes.bytes': asset('hello'),  # not msgpack
                     'abdata/list/characustom/06/array.bytes': asset(msgpack.packb([1, 2])),
                     'abdata/list/characustom/06/other.bytes': asset(msgpack.packb(dict(lstKey=[], dictList={}))),
                     'abdata/list/characustom/06/hair_b_06.prefab': asset(msgpack.packb(table))}
        self.assertEqual(list_tables(SimpleNamespace(container=container)), [('hair_b_06', table)])

    @staticmethod
    def merge_fixture(root):
        entries = [dict(category=101, id=0, name='a', rig=dict(file='assets/101-0/rig.json', sha256='0' * 64)),
                   dict(category=103, id=0, name='b', empty=True)]
        index = dict(schemaVersion=1, entries=entries, limitations=['x'], assemblies=[dict(sex=1, headID=0)])
        write_json(root / 'library.json', index)
        write_json(root / 'material-inputs.json', dict(schemaVersion=1, files=['assets/101-0/materials.json']))
        builder = Builder.__new__(Builder); builder.output = root; builder.converted = []

        def entry(category, item_id):
            if (category, item_id) == (104, 99):
                raise ValueError('conversion failed')
            builder.converted.append((category, item_id))
            evidence = f'assets/{category}-{item_id}/materials.json'
            return dict(category=category, id=item_id, materialEvidence=dict(file=evidence, sha256='1' * 64)), dict(schemaVersion=1)
        builder.entry = entry
        return builder

    def test_add_appends_entries_and_keeps_the_retained_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); builder = self.merge_fixture(root)
            before = (root / 'library.json').read_bytes(); old = json.loads(before)
            builder.add([(101, 28), (102, 48), (101, 28)])
            library = json.loads((root / 'library.json').read_text())
            self.assertEqual(builder.converted, [(101, 28), (102, 48)])
            self.assertEqual([(e['category'], e['id']) for e in library['entries']], [(101, 0), (103, 0), (101, 28), (102, 48)])
            self.assertEqual(json.loads((root / 'material-inputs.json').read_text())['files'],
                             ['assets/101-0/materials.json', 'assets/101-28/materials.json', 'assets/102-48/materials.json'])
            # Without the new entries the index serializes to its old bytes.
            library['entries'] = library['entries'][:2]
            write_json(root / 'retained.json', library)
            self.assertEqual((root / 'retained.json').read_bytes(), before)
            self.assertEqual(library, old)

    def test_add_refuses_an_existing_identity_or_asset_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); builder = self.merge_fixture(root)
            files = {name: (root / name).read_bytes() for name in ('library.json', 'material-inputs.json')}
            with self.assertRaisesRegex(ValueError, 'already has 103:0'):
                builder.add([(101, 28), (103, 0)])
            (root / 'assets/104-7').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'Asset directory already exists: 104-7'):
                builder.add([(104, 7)])
            self.assertEqual(builder.converted, [])
            self.assertEqual({name: (root / name).read_bytes() for name in files}, files)

    def test_add_writes_nothing_when_an_entry_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); builder = self.merge_fixture(root)
            files = {name: (root / name).read_bytes() for name in ('library.json', 'material-inputs.json')}
            with self.assertRaisesRegex(ValueError, 'conversion failed'):
                builder.add([(101, 28), (104, 99)])
            self.assertEqual({name: (root / name).read_bytes() for name in files}, files)

    def test_source_path_escape_is_rejected(self):
        for path in ['../secret', '/tmp/file', 'C:/file', 'chara\\file']:
            with self.assertRaises(ValueError):
                source_file(Path('/tmp'), path)

    def test_source_hash_is_required(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); path = root / 'source/abdata/test'
            path.parent.mkdir(parents=True); path.write_bytes(b'changed')
            path.with_name('test.provenance.json').write_text(json.dumps(dict(sha256='0'*64)))
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                source_file(root, 'test')

    def test_active_half_off_prefab_is_not_selected(self):
        nodes = [dict(name='root', parent=None, active=True), dict(name='n_top_a', parent=0, active=True),
                 dict(name='n_top_b', parent=0, active=True), dict(name='meshA', parent=1, active=True),
                 dict(name='meshB', parent=2, active=True)]
        self.assertTrue(fully_dressed(nodes, dict(node=3), 105))
        self.assertFalse(fully_dressed(nodes, dict(node=4), 105))
        self.assertFalse(fully_dressed(nodes, dict(node=3, rendererEnabled=False), 105))

    @staticmethod
    def garment(*switches):
        """root, then one switch chain per mesh: ('n_top_b',) or ('n_bot_b', 'n_top_b')."""
        nodes = [dict(name='root', parent=None, active=True)]; meshes = []
        for chain in switches:
            parent = 0
            for name in reversed(chain):
                nodes.append(dict(name=name, parent=parent, active=True)); parent = len(nodes) - 1
            nodes.append(dict(name='mesh%d' % len(meshes), parent=parent, active=True))
            meshes.append(dict(name='mesh%d' % len(meshes), node=len(nodes) - 1))
        return nodes, meshes

    def test_alternate_meshes_are_tagged_with_their_states(self):
        nodes, meshes = self.garment(('n_top_a',), ('n_top_b',), ('n_bot_b',), ('n_top_b', 'n_bot_a'))
        self.assertIsNone(alternate(nodes, meshes[0], 105))
        self.assertEqual(alternate(nodes, meshes[1], 105),
                         dict(meshName='mesh1', switches=['n_top_b'], activeWhen=[dict(kind=0, states=[1])]))
        # A top's n_bot_b reads the bottom: bottom not on and top not off.
        self.assertEqual(alternate(nodes, meshes[2], 105)['activeWhen'],
                         [dict(kind=0, states=[0, 1, 2]), dict(kind=1, states=[1, 2, 3])])
        # Nested switches conjoin: top half and bottom on.
        self.assertEqual(alternate(nodes, meshes[3], 105),
                         dict(meshName='mesh3', switches=['n_top_b', 'n_bot_a'],
                              activeWhen=[dict(kind=0, states=[1]), dict(kind=1, states=[0])]))
        shorts, parts = self.garment(('n_bot_a',), ('n_bot_b',), ('n_bot_c',))
        self.assertEqual([alternate(shorts, m, 108) and alternate(shorts, m, 108)['activeWhen'] for m in parts],
                         [None, [dict(kind=3, states=[1])], [dict(kind=3, states=[2])]])
        panst, legs = self.garment(('n_panst_a',), ('n_panst_b',))
        self.assertEqual(alternate(panst, legs[1], 110)['activeWhen'], [dict(kind=5, states=[1])])
        # Hair, shoes and accessories have no clothes-state alternates.
        self.assertIsNone(alternate(nodes, meshes[1], 112))

    def test_alternate_requires_a_drawable_renderer_and_a_recovered_rule(self):
        nodes, meshes = self.garment(('n_top_b',))
        self.assertIsNone(alternate(nodes, dict(meshes[0], rendererEnabled=False), 105))
        nodes[0]['active'] = False
        self.assertIsNone(alternate(nodes, meshes[0], 105))
        # UpdateVisible never switches a shorts n_top_b (S_UWB_T_NUGE).
        shorts, parts = self.garment(('n_top_b',))
        with self.assertRaisesRegex(ValueError, 'no recovered UpdateVisible rule'):
            alternate(shorts, parts[0], 108)
        # A top mesh under both n_top_a and n_top_b is never shown.
        both, part = self.garment(('n_top_b', 'n_top_a'))
        with self.assertRaisesRegex(ValueError, 'never active together'):
            alternate(both, part[0], 105)

    def test_switch_rules_follow_update_visible(self):
        # Independent restatement of ChaControl.UpdateVisible per (kind, node).
        def active(kind, node, s):
            return {(0, 'n_top_a'): s[0] == 0, (0, 'n_top_b'): s[0] == 1,
                    (0, 'n_bot_a'): s[1] == 0 and s[0] != 3, (0, 'n_bot_b'): s[1] != 0 and s[0] != 3,
                    (1, 'n_bot_a'): s[1] == 0, (1, 'n_bot_b'): s[1] == 1,
                    (1, 'n_top_a'): s[0] == 0 and s[1] != 2, (1, 'n_top_b'): s[0] != 0 and s[1] != 2,
                    (2, 'n_top_a'): s[2] == 0, (2, 'n_top_b'): s[2] == 1,
                    (2, 'n_bot_a'): s[3] == 0 and s[2] != 3, (2, 'n_bot_b'): s[3] != 0 and s[2] != 3,
                    (3, 'n_bot_a'): s[3] == 0, (3, 'n_bot_b'): s[3] == 1, (3, 'n_bot_c'): s[3] == 2,
                    (5, 'n_panst_a'): s[5] == 0, (5, 'n_panst_b'): s[5] == 1}[(kind, node)]
        import itertools
        for (kind, node), clauses in SWITCH_RULES.items():
            for a, b in itertools.product(range(4), repeat=2):
                s = [0] * 9; related = sorted({kind} | {k for k, _ in clauses}) + [kind]
                s[related[0]] = a; s[related[1]] = b
                self.assertEqual(all(s[k] in states for k, states in clauses), active(kind, node, s), (kind, node, s))

    def test_compact_rig_writer_keeps_the_retained_form(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'rig.json'
            write_json(path, dict(sources=[dict(path='p', sha256='0', bytes=1)], nodes=[1, 2]), compact=True)
            self.assertEqual(path.read_text(), '{"sources":[{"path":"p","sha256":"0","bytes":1}],"nodes":[1,2]}\n')

    def test_inactive_parent_suppresses_renderer(self):
        nodes = [dict(name='root', parent=None, active=False), dict(name='mesh', parent=0, active=True)]
        self.assertFalse(fully_dressed(nodes, dict(node=1), 101))

    @unittest.skipUnless(os.environ.get('IKKOKU_MAKER_LIBRARY'), 'installed original library not selected')
    def test_original_selected_library_geometry(self):
        report = audit_library(Path(os.environ['IKKOKU_MAKER_LIBRARY']))
        self.assertTrue(report['passed'])
        self.assertGreaterEqual(report['geometryEntries'], 15)
        library = json.loads(Path(os.environ['IKKOKU_MAKER_LIBRARY']).read_text())
        self.assertEqual(report['alternateMeshes'], sum(len(e.get('alternates', [])) for e in library['entries']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--audit', type=Path)
    parser.add_argument('--output', type=Path)
    args, rest = parser.parse_known_args()
    if args.audit:
        result = audit_library(args.audit)
        if args.output:
            args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
        print(json.dumps(result, indent=2, allow_nan=False))
        if not result['passed']:
            raise SystemExit(1)
    else:
        unittest.main(argv=[__file__, *rest])
