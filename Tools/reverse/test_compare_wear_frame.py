"""compare_wear_frame: untranslated-mesh exclusion on synthetic frames; no private data."""
import hashlib, json, struct, tempfile, unittest
from pathlib import Path
import numpy as np
from PIL import Image
from compare_wear_frame import compare

IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]


class WearFrameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.folder = Path(self.temp.name)
        # A 4x2 frame. The 'alpha' mesh is a quad over the right half (x > 0) in clip space.
        quad = np.array([[0.01, -1, 0.5], [1, -1, 0.5], [1, 1, 0.5], [0.01, 1, 0.5]], '<f4')
        vertices = np.zeros((4, 20), '<f4'); vertices[:, :3] = quad
        triangles = np.array([0, 1, 2, 0, 2, 3], '<i4')
        data = struct.pack('<ii', 4, 1) + vertices.tobytes() + struct.pack('<i', 6) + triangles.tobytes()
        (self.folder / 'mesh-0.bin').write_bytes(data); (self.folder / 'mesh-0-baked.bin').write_bytes(quad.tobytes())
        alpha = dict(name='alpha', path='root/alpha', file='mesh-0.bin', vertices=4, submeshes=1, lossyScale=[1, 1, 1], rendererMatrix=IDENTITY,
                     sourceVertexNormals=dict(geometrySHA256=hashlib.sha256(data).hexdigest()),
                     bakedPositions=dict(file='mesh-0-baked.bin', sha256=hashlib.sha256(quad.tobytes()).hexdigest()),
                     materials=[dict(shader='Shader Forge/main_alpha')])
        skin = dict(name='skin', path='root/skin', materials=[dict(shader='Shader Forge/main_skin')], submeshes=1)
        self.frame = dict(width=4, height=2, camera=dict(projection=IDENTITY, view=IDENTITY), meshes=[skin, alpha])
        self.live = ['main_skin']
        # Original: skin 100 on the left half, the alpha mesh tints the right half to 160.
        self.images = {'original-color.png': np.full((2, 4, 4), 100, np.uint8)}
        self.images['original-color.png'][:, 2:, :3] = 160
        for name in ('native-translated.png', 'native-translated-main_skin.png'):
            self.images[name] = np.full((2, 4, 4), 255, np.uint8); self.images[name][:, :, :3] = 100

    def tearDown(self): self.temp.cleanup()

    def write(self):
        frame = json.dumps(self.frame).encode(); (self.folder / 'frame.json').write_bytes(frame)
        (self.folder / 'native-report.json').write_text(json.dumps(dict(sourceFrameFile='frame.json', sourceFrameSHA256=hashlib.sha256(frame).hexdigest())))
        (self.folder / 'live-report.json').write_text(json.dumps(dict(liveFamilies=self.live)))
        for name, pixels in self.images.items(): Image.fromarray(pixels, 'RGBA').save(self.folder / name)

    def test_untranslated_mesh_silhouette_is_excluded_with_unchanged_limits(self):
        self.write()
        result = compare(self.folder)
        self.assertEqual([m['name'] for m in result['excludedMeshes']], ['alpha'])
        self.assertEqual(result['excludedPixels'], 4)
        skin = result['translatedFamilies']['main_skin']
        self.assertEqual(skin['comparedPixels'], 4); self.assertTrue(skin['passes'])
        self.assertEqual(skin['tolerance'], dict(maximumMeanAbsoluteChannelBytes=1, maximumP99ChannelBytes=4))

    def test_a_colour_error_outside_the_silhouette_still_fails(self):
        self.images['native-translated.png'][0, 0, :3] = 140; self.images['native-translated-main_skin.png'][0, 0, :3] = 140
        self.write()
        self.assertFalse(compare(self.folder)['translatedFamilies']['main_skin']['passes'])

    def test_nothing_is_excluded_when_every_family_draws_live(self):
        self.live = ['main_skin', 'main_alpha']; self.write()
        result = compare(self.folder)
        self.assertEqual(result['excludedMeshes'], []); self.assertEqual(result['excludedPixels'], 0)
        self.assertFalse(result['translatedFamilies']['main_skin']['passes'])

    def test_changed_capture_or_geometry_is_rejected(self):
        self.write(); (self.folder / 'frame.json').write_text(json.dumps(self.frame) + ' ')
        with self.assertRaisesRegex(ValueError, 'exact source capture'): compare(self.folder)
        self.write(); (self.folder / 'mesh-0.bin').write_bytes(b'\0' * 8)
        with self.assertRaisesRegex(ValueError, 'geometry'): compare(self.folder)


if __name__ == '__main__': unittest.main()
