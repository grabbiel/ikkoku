"""Unit tests for the live source-shader input exporters (no game data, no UnityPy).

Covers the pure parts of `source_texture_store.py` and `source_vertex_streams.py`:
identity collection, level sizes, sRGB linearization, sampler settings, the
prefab scoping that keeps hair renderers unambiguous, the frozen-mesh row
layout and both `--verify-frame` comparisons on synthetic files.
"""
import json
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as NS

import numpy as np

import source_texture_store as store
import source_vertex_streams as streams


def kind(name):
    return NS(name=name)


class TextureStoreTests(unittest.TestCase):
    def test_level_bytes_follow_block_and_texel_sizes(self):
        self.assertEqual(store.level_bytes(256, 256, 10), 64 * 64 * 8)   # DXT1
        self.assertEqual(store.level_bytes(256, 128, 12), 64 * 32 * 16)  # DXT5
        self.assertEqual(store.level_bytes(1, 1, 12), 16)                # one partial block
        self.assertEqual(store.level_bytes(2, 2, 4), 16)                 # RGBA32
        self.assertEqual(store.level_bytes(3, 1, 3), 9)                  # RGB24
        with self.assertRaises(ValueError):
            store.level_bytes(4, 4, 63)

    def test_srgb_to_linear_matches_the_gpu_transfer_function(self):
        values = store.srgb_to_linear([0.0, 0.04045, 0.5, 1.0])
        self.assertEqual(values.dtype, np.float32)
        np.testing.assert_allclose(values, [0.0, 0.04045 / 12.92, 0.21404114, 1.0], rtol=1e-6)

    def test_identities_are_unique_assets_with_every_use(self):
        texture = dict(kind='asset', bundle='chara/a.unity3d', pathID='7', name='t')
        bindings = dict(renderers=[
            dict(mesh='o_body', materialSlot=0, material=dict(textures=dict(_MainTex=dict(identity=texture),
                                                                             _Mask=dict(identity=None)))),
            dict(mesh='o_face', materialSlot=1, material=dict(textures=dict(
                _MainTex=dict(identity=texture),
                _Composite=dict(identity=dict(kind='runtimeComposite', creator='CustomTextureControl'))))),
        ], globalTextures=dict(_RampG=dict(identity=dict(kind='asset', bundle='chara/ramp.unity3d', name='gt_ramp'))))
        for report in (bindings, dict(bindings=bindings)):
            found = store.identities(report)
            self.assertEqual([item['identity'].get('name') for item in found], ['t', 'gt_ramp'])
            self.assertEqual(found[0]['uses'], ['o_body slot 0 _MainTex', 'o_face slot 1 _MainTex'])
            self.assertEqual(found[1]['uses'], ['global _RampG'])

    def test_locate_checks_the_root_and_its_abdata_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'abdata' / 'chara').mkdir(parents=True)
            (root / 'abdata' / 'chara' / 'b.unity3d').write_bytes(b'x')
            self.assertEqual(store.locate('chara/b.unity3d', [root]), root / 'abdata' / 'chara' / 'b.unity3d')
            self.assertIsNone(store.locate('chara/c.unity3d', [root]))

    def test_texture_settings_read_wrap_mode_or_wrap_u(self):
        self.assertEqual(store.texture_settings(NS(m_TextureSettings=NS(m_FilterMode=1, m_WrapMode=1, m_Aniso=4))), ('Bilinear', 'Clamp', 4))
        self.assertEqual(store.texture_settings(NS(m_TextureSettings=NS(m_FilterMode=2, m_WrapU=0, m_Aniso=1))), ('Trilinear', 'Repeat', 1))
        self.assertEqual(store.texture_settings(NS(m_TextureSettings=NS(m_FilterMode=9, m_WrapU=7, m_Aniso=0))), (None, None, 0))
        self.assertEqual(store.texture_settings(NS()), (None, None, None))

    def test_verify_compares_base_levels_with_capture_textures_of_the_same_name_and_size(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            pixels = np.linspace(0, 1, 2 * 2 * 4, dtype=np.float32).reshape(2, 2, 4)
            (root / 'store' / 'k').mkdir(parents=True)
            (root / 'store' / 'k' / 'level-0.rgba16f').write_bytes(pixels.astype('<f2').tobytes())
            (root / 'store' / 'manifest.json').write_text(json.dumps(dict(entries=[dict(
                name='t', width=2, height=2, colorSpace='srgb', directory='k', files=['level-0.rgba16f'])])))
            shifted = pixels.copy(); shifted[0, 0, 0] += 0.25
            (root / 'capture.rgba16f').write_bytes(shifted.astype('<f2').tobytes())
            (root / 'frame.json').write_text(json.dumps(dict(textures=[
                dict(textureType='Texture2D', name='t', width=2, height=2, file='capture.rgba16f'),
                dict(textureType='Texture2D', name='t', width=4, height=4, file='other.rgba16f'),
                dict(textureType='RenderTexture', name='t', width=2, height=2, file='rt.rgba16f')])))
            results = store.verify(root / 'store' / 'manifest.json', root / 'frame.json')
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]['captureFile'], 'capture.rgba16f')
            self.assertAlmostEqual(results[0]['maximumError'], 0.25, places=3)


def game_object(path_id, name, children=(), filters=()):
    """A fake UnityPy GameObject with a Transform holding `children`."""
    obj = NS(m_Name=name, object_reader=NS(path_id=path_id), m_Component=[])
    transform = NS(m_Children=[NS(read=lambda child=child: NS(m_GameObject=NS(read=lambda child=child: child))) for child in children])
    obj.m_Component.append(NS(component=NS(type=kind('Transform'), read=lambda: transform)))
    for mesh in filters:
        obj.m_Component.append(NS(component=NS(type=kind('MeshFilter'), read=lambda mesh=mesh: NS(m_Mesh=mesh))))
    return obj


def pointer(target, path_id):
    return NS(path_id=path_id, read=lambda: target)


def mesh_pointer(path_id):
    return NS(path_id=path_id, deref=lambda: 'mesh#%d' % path_id)


class VertexStreamTests(unittest.TestCase):
    def fake_bundle(self):
        # Two prefabs in one bundle, each with a renderer named cf_hair_b_03_00
        # drawing a different mesh (the hair bundle shape), plus a MeshRenderer.
        hair_a = game_object(11, 'cf_hair_b_03_00')
        hair_b = game_object(21, 'cf_hair_b_03_00')
        item = game_object(22, 'o_item', filters=[mesh_pointer(500)])
        root_a = game_object(10, 'p_cf_hair_b_03', children=[hair_a])
        root_b = game_object(20, 'p_cf_hair_b_04', children=[hair_b, item])
        container = {
            'assets/x/p_cf_hair_b_03/P_CF_HAIR_B_03.prefab': NS(type=kind('GameObject'), read=lambda: root_a),
            'assets/x/p_cf_hair_b_04/p_cf_hair_b_04.prefab': NS(type=kind('GameObject'), read=lambda: root_b),
        }
        renderers = [
            NS(type=kind('SkinnedMeshRenderer'), read=lambda: NS(m_GameObject=pointer(hair_a, 11), m_Mesh=mesh_pointer(100))),
            NS(type=kind('SkinnedMeshRenderer'), read=lambda: NS(m_GameObject=pointer(hair_b, 21), m_Mesh=mesh_pointer(200))),
            NS(type=kind('MeshRenderer'), read=lambda: NS(m_GameObject=pointer(item, 22))),
            NS(type=kind('Texture2D'), read=lambda: self.fail('textures are not read')),
        ]
        return NS(container=container, objects=renderers)

    def test_prefab_scoping_keeps_one_renderer_per_name(self):
        env = self.fake_bundle()
        prefab = 'assets/x/p_cf_hair_b_03/p_cf_hair_b_03.prefab'
        owned = streams.prefab_game_objects(env, [prefab])
        self.assertEqual(owned, {10: prefab, 11: prefab})
        self.assertEqual(streams.renderer_meshes(env, owned), [('cf_hair_b_03_00', 'mesh#100', prefab)])
        # Unscoped, the name is ambiguous: both meshes (and the MeshFilter item) are found.
        self.assertEqual(streams.renderer_meshes(env), [('cf_hair_b_03_00', 'mesh#100', None), ('cf_hair_b_03_00', 'mesh#200', None),
                                                        ('o_item', 'mesh#500', None)])
        self.assertEqual(streams.prefab_game_objects(env, ['assets/elsewhere.prefab']), {})

    def test_color_channel_bytes_are_detected_from_the_vertex_layout(self):
        def handler(version, dtype):
            return NS(version=(version,), get_channel_dtype=lambda channel: dtype)
        def mesh(dimensions):
            return NS(m_VertexData=NS(m_Channels=[NS(dimension=d) for d in dimensions]))
        self.assertTrue(streams.color_channel_is_bytes(handler(2017, 'B'), mesh([3, 3, 4, 2])))
        self.assertFalse(streams.color_channel_is_bytes(handler(2017, 'f'), mesh([3, 3, 4, 2])))
        self.assertFalse(streams.color_channel_is_bytes(handler(5, 'B'), mesh([3, 3, 0, 2])))
        self.assertTrue(streams.color_channel_is_bytes(handler(2018, 'B'), mesh([3, 3, 4, 4])))
        self.assertFalse(streams.color_channel_is_bytes(handler(2018, 'B'), mesh([3, 3, 4])))
        self.assertFalse(streams.color_channel_is_bytes(handler(5, 'B'), NS()))

    def write_frozen(self, path, rows):
        rows = np.asarray(rows, dtype='<f4')
        path.write_bytes(struct.pack('<II', len(rows), 0) + rows.tobytes())

    def test_frozen_rows_and_verify_compare_every_exported_channel(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            count = 3
            rows = np.zeros((count, 20), dtype=np.float32)
            rows[:, 12:14] = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]       # UV1
            rows[:, 16:20] = [[1, 0.5, 0.25, 1]] * count                 # colour
            self.write_frozen(root / 'mesh-0.bin', rows)
            np.testing.assert_array_equal(streams.frozen_rows(root / 'mesh-0.bin'), rows)
            uv3 = np.asarray([[0.7, 0.8]] * count, dtype='<f4')
            (root / 'mesh-0-uv3.bin').write_bytes(uv3.tobytes())
            (root / 'frame.json').write_text(json.dumps(dict(meshes=[
                dict(name='o_body_a', file='mesh-0.bin', uv3File='mesh-0-uv3.bin'),
                dict(name='o_other', file='mesh-0.bin')])))
            (root / 'streams').mkdir()
            (root / 'streams' / 's-uv1.bin').write_bytes(rows[:, 12:14].astype('<f4').tobytes())
            (root / 'streams' / 's-uv3.bin').write_bytes(uv3.tobytes())
            colors = rows[:, 16:20].copy(); colors[2, 1] = 0.75
            (root / 'streams' / 's-colors.bin').write_bytes(colors.astype('<f4').tobytes())
            (root / 'streams' / 'manifest.json').write_text(json.dumps(dict(entries=[dict(
                mesh='o_body_a', bundle='chara/b.unity3d', vertexCount=count, uv1File='s-uv1.bin', uv2File=None,
                uv3File='s-uv3.bin', colorsFile='s-colors.bin')])))
            [result] = streams.verify(root / 'streams' / 'manifest.json', root / 'frame.json')
            self.assertEqual(result['uv1MaximumError'], 0.0)
            self.assertEqual(result['uv2'], 'absent in the source mesh; capture all zero: True')
            self.assertEqual(result['uv3MaximumError'], 0.0)
            self.assertAlmostEqual(result['colorsMaximumError'], 0.25)
            self.assertEqual(result['captureVertexCount'], count)


if __name__ == '__main__':
    unittest.main()
