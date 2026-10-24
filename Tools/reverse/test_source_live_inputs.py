"""Unit tests for the live source-shader input exporters (no game data, no UnityPy).

Covers the pure parts of `source_texture_store.py` and `source_vertex_streams.py`:
identity collection, level sizes, sRGB linearization, sampler settings, the
prefab scoping that keeps hair renderers unambiguous, the frozen-mesh row
layout and both `--verify-frame` comparisons on synthetic files.
"""
import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import patch

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

    def test_conflicting_identity_requirements_are_not_merged_away(self):
        asset = dict(kind='asset', bundle='chara/a.unity3d', pathID='7', name='t')
        report = dict(globalTextures={key: dict(identity=dict(asset, mipLevels=mips)) for key, mips in [('a', 1), ('b', 2)]})
        self.assertEqual(len(store.identities(report)), 2)

    def test_build_validates_identity_and_records_actual_file_and_input_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'chara').mkdir()
            (root / 'chara/a.unity3d').write_bytes(b'bundle')
            digest = hashlib.sha256(b'bundle').hexdigest()
            texture = NS(m_Name='ramp', m_Width=2, m_Height=2, m_MipCount=2, m_ColorSpace=0, m_TextureFormat=4)
            obj = NS(path_id=7, assets_file=NS(name='CAB-source'), type=kind('Texture2D'), read=lambda: texture)
            base = dict(kind='asset', bundle='chara/a.unity3d', pathID='7', name='ramp', mipLevels=2, bundleSHA256=digest)
            variants = [base, dict(base, serializedFile='CAB-source'), dict(base, name='wrong'), dict(base, mipLevels=1),
                        dict(base, serializedFile='CAB-other'), dict(base, bundleSHA256='wrong'), dict(base, width=4)]
            report = dict(globalTextures={str(i): dict(identity=identity) for i, identity in enumerate(variants)})
            levels = [(2, 2, np.ones((2, 2, 4))), (1, 1, np.zeros((1, 1, 4)))]
            with patch.dict('sys.modules', UnityPy=NS(load=lambda path: NS(objects=[obj]))), patch.object(store, 'decode_levels', return_value=levels) as decode:
                manifest = store.build(report, [root], root / 'out', source=dict(file='bindings.json', sha256='input-hash'))
            self.assertEqual(len(manifest['entries']), 1)
            self.assertEqual(len(manifest['unavailable']), 5)
            self.assertEqual(decode.call_count, 1)
            entry = manifest['entries'][0]
            self.assertEqual(entry['serializedFile'], 'CAB-source')
            self.assertEqual(entry['bundleSHA256'], digest)
            self.assertEqual(entry['mipLevels'], 2)
            self.assertEqual(len(entry['uses']), 2)
            self.assertEqual(manifest['source']['sha256'], 'input-hash')
            for name, expected in zip(entry['files'], entry['sha256']):
                self.assertEqual(hashlib.sha256((root / 'out' / entry['directory'] / name).read_bytes()).hexdigest(), expected)

    def composite_report(self, **recipe_overrides):
        main = dict(kind='asset', bundle='chara/mt_eye_00.unity3d', pathID='1', name='eye')
        mask = dict(kind='asset', bundle='chara/mt_eye_gradation_00.unity3d', pathID='2', name='grad')
        recipe = dict(method='ChaControl.ChangeSettingEye(0, ...)', material='cf_m_eye_create', bundle='chara/mm_base.unity3d',
                      bundleSHA256=hashlib.sha256(b'base').hexdigest(), serializedFile='CAB-base', pathID='9',
                      shader='Shader Forge/create_eye', programSHA256='c' * 64,
                      textures=dict(_MainTex=dict(identity=main), _ColorMask=dict(identity=mask)), vectors={})
        recipe.update(recipe_overrides)
        composite = dict(kind='runtimeComposite', creator='ctCreateEyeL', composite=recipe)
        return dict(renderers=[dict(mesh=mesh, materialSlot=0, material=dict(textures=dict(_MainTex=dict(identity=composite))))
                               for mesh in ('cf_Ohitomi_L02', 'cf_Ohitomi_R02')])

    def test_composite_recipe_inputs_are_store_assets_and_recipes_are_shared(self):
        report = self.composite_report()
        found = store.identities(report)
        self.assertEqual([item['identity']['name'] for item in found], ['eye', 'grad'])
        self.assertEqual(found[0]['uses'], ['cf_Ohitomi_L02 slot 0 _MainTex composite _MainTex', 'cf_Ohitomi_R02 slot 0 _MainTex composite _MainTex'])
        recipes = store.recipes(report)
        self.assertEqual(len(recipes), 1)
        self.assertEqual(recipes[0]['uses'], ['cf_Ohitomi_L02 slot 0 _MainTex', 'cf_Ohitomi_R02 slot 0 _MainTex'])
        self.assertEqual(recipes[0]['recipe']['programSHA256'], 'c' * 64)
        # A recipe-less composite (body, face) has no inputs and no program.
        bare = dict(renderers=[dict(mesh='o_body_a', materialSlot=0, material=dict(textures=dict(
            _MainTex=dict(identity=dict(kind='runtimeComposite', creator='CustomTextureControl body'))))) ])
        self.assertEqual((store.identities(bare), store.recipes(bare)), ([], []))

    def test_composite_programs_export_only_verified_recipes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'chara').mkdir()
            (root / 'chara/mm_base.unity3d').write_bytes(b'base')

            def extract(bundle, path_id, material, output, caches, expected_sha=None):
                output.mkdir(parents=True)
                (output / 'program.json').write_text('{}')
                (output / 'source.metal').write_text('metal')
                if material == 'missing-disassembly':
                    raise ValueError('No retained disassembly of fragment')
                return dict(name='Shader Forge/create_eye', serializedFile='CAB-base', bundleSHA256=hashlib.sha256(b'base').hexdigest(),
                            programs=dict(fragment=dict(sha256=expected_sha)))

            with patch('source_shader_translation.extract_fragment', side_effect=extract) as call:
                composites, unavailable = store.export_composites(self.composite_report(), [root], root / 'out', [root / 'cache'])
                self.assertEqual(unavailable, [])
                self.assertEqual(call.call_count, 1)
                entry = composites[0]
                self.assertEqual((entry['pathID'], entry['programSHA256'], entry['files']), ('9', 'c' * 64, ['program.json', 'source.metal']))
                self.assertEqual(entry['sha256'], [hashlib.sha256(b'{}').hexdigest(), hashlib.sha256(b'metal').hexdigest()])
                self.assertEqual(len(entry['uses']), 2)
                for overrides, reason in [(dict(unresolved='create material not converted'), 'recipe unresolved'),
                                          (dict(programSHA256=None), 'no verified program'),
                                          (dict(bundle='chara/other.unity3d'), 'not in the local bundle roots'),
                                          (dict(bundleSHA256='0' * 64), 'SHA-256 differs'),
                                          (dict(shader='Shader Forge/create_head'), 'shader or serialized file differs'),
                                          (dict(material='missing-disassembly'), 'No retained disassembly')]:
                    output = root / ('out-%d' % len(reason))
                    composites, unavailable = store.export_composites(self.composite_report(**overrides), [root], output, [])
                    self.assertEqual(composites, [])
                    self.assertIn(reason, unavailable[0]['reason'])
                    self.assertEqual(len(unavailable[0]['uses']), 2)
                    # Nothing half-exported is left behind for a failed recipe.
                    self.assertEqual(list(output.glob('create-*')), [])

    def test_build_reports_path_id_collisions_across_serialized_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'bundle').write_bytes(b'bundle')
            texture = NS(m_Name='ramp', m_Width=1, m_Height=1, m_MipCount=1, m_ColorSpace=0, m_TextureFormat=4)
            objects = [NS(path_id=7, assets_file=NS(name=file), type=kind('Texture2D'), read=lambda: texture) for file in ['CAB-a', 'CAB-b']]
            report = dict(globalTextures={file: dict(identity=dict(kind='asset', bundle='bundle', pathID='7', name='ramp', serializedFile=file))
                                          for file in ['CAB-a', 'CAB-b']})
            with patch.dict('sys.modules', UnityPy=NS(load=lambda path: NS(objects=objects))), patch.object(store, 'decode_levels', return_value=[(1, 1, np.ones((1, 1, 4)))]):
                manifest = store.build(report, [root], root / 'out')
            self.assertEqual(len(manifest['entries']), 1)
            self.assertEqual(len(manifest['unavailable']), 1)
            self.assertIn('different serialized files', manifest['unavailable'][0]['reason'])

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

    def test_verify_compares_retained_mips_and_reports_missing_or_nonindependent_levels(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'k').mkdir()
            files = []
            for level, count in enumerate([4 * 2 * 4, 2 * 1 * 4, 1 * 1 * 4]):
                name = 'level-%d.rgba16f' % level; files.append(name)
                (root / 'k' / name).write_bytes(np.zeros(count, dtype='<f2').tobytes())
                if level < 2:
                    (root / name).write_bytes(np.full(count, level * 0.5, dtype='<f2').tobytes())
            entry = dict(name='gloss', width=4, height=2, colorSpace='linear', directory='k', files=files)
            (root / 'manifest.json').write_text(json.dumps(dict(entries=[entry])))
            (root / 'frame.json').write_text(json.dumps(dict(textures=[dict(textureType='Texture2D', name='gloss', width=4,
                height=2, file=files[0], mipFiles=files[:2], authoredMipSource=dict(decodedColorSpace='linear'))])))
            [result] = store.verify(root / 'manifest.json', root / 'frame.json')
            self.assertEqual(result['comparedMipLevels'], 2)
            self.assertEqual(result['independentlyComparedMipLevels'], 1)
            self.assertEqual(result['offlineComparedMipLevels'], 1)
            self.assertEqual(result['uncomparedMipLevels'], [2])
            self.assertEqual(result['unverifiedMipLevels'], [1, 2])
            self.assertEqual(result['levels'][0]['referenceKind'], 'GPU base readback')
            self.assertEqual(result['levels'][1]['referenceKind'], 'offline authored mip decode')
            self.assertEqual(result['levels'][1]['maximumError'], 0.5)
            (root / files[1]).write_bytes(b'short')
            with self.assertRaisesRegex(ValueError, 'mip 1.*byte count'):
                store.verify(root / 'manifest.json', root / 'frame.json')

    def test_verify_does_not_silently_omit_assets_without_reference_pixels(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'manifest.json').write_text(json.dumps(dict(entries=[dict(
                name='missing', width=1, height=1, colorSpace='linear', directory='k', files=['level-0.rgba16f'])])))
            (root / 'frame.json').write_text(json.dumps(dict(textures=[])))
            [result] = store.verify(root / 'manifest.json', root / 'frame.json')
            self.assertEqual(result['comparedMipLevels'], 0)
            self.assertEqual(result['independentlyComparedMipLevels'], 0)
            self.assertEqual(result['offlineComparedMipLevels'], 0)
            self.assertEqual(result['uncomparedMipLevels'], [0])
            self.assertEqual(result['unverifiedMipLevels'], [0])


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
