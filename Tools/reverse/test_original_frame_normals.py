"""Synthetic reconstruction and provenance controls; no original data or VM."""
import copy
import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path
import numpy as np
import original_frame_normals as normals


def fixture(blended=False):
    identity = np.eye(4).flatten(order='F').tolist()
    renderer = np.diag([2., 2., 2., 1.]).flatten(order='F').tolist()
    bones = [dict(path='root', position=[0, 0, 0], rotation=[0, 0, 0, 1], scale=[2, 2, 2])]
    nodes = [dict(name='root')]
    if blended:
        bones.append(dict(path='root/other', position=[0, 0, 0], rotation=[0, 0, 2**-.5, 2**-.5], scale=[1, 1, 1]))
        nodes.append(dict(name='other'))
    mesh = dict(name='sample', skin=0, positions=[[1., 0, 0]], normals=[[1., 0, 0]],
                joints=[[0, 1 if blended else 0, 0, 0]],
                weights=[[.5, .5, 0, 0]] if blended else [[1., 0, 0, 0]], initialMorphWeights=[])
    rig = dict(coordinateSpace='unity-left-handed-y-up', matrixLayout='column-major', nodes=nodes,
               skins=[dict(joints=list(range(len(nodes))), inverseBindMatrices=[identity]*len(nodes))], meshes=[mesh])
    row = dict(name='sample', file='mesh.bin', rendererMatrix=renderer, materials=[dict(shader='Shader Forge/test')])
    frame = dict(schemaVersion=1, bones=bones, meshes=[row])
    frozen = np.zeros((1, 20), dtype=np.float32)
    frozen[0, :3] = [1, 1, 0] if blended else [2, 0, 0]
    frozen[0, 3:6] = [2**-.5, 2**-.5, 0] if blended else [1, 0, 0]
    return frame, row, rig, mesh, frozen


class ReconstructionTests(unittest.TestCase):
    def test_renderer_scale_does_not_become_normal_magnitude(self):
        values, report = normals.reconstruct(*fixture())
        np.testing.assert_array_equal(values, [[1, 0, 0]])
        self.assertEqual(report['legacyLocalNormalLengths'], [2, 2, 2])

    def test_weighted_nonunit_normal_is_not_normalized(self):
        values, report = normals.reconstruct(*fixture(blended=True))
        np.testing.assert_allclose(values, [[.5, .5, 0]], atol=1e-7)
        self.assertAlmostEqual(report['weightedLocalNormalLengths'][1], 2**-.5)

    def test_wrong_geometry_and_normal_direction_are_rejected(self):
        for channel, message in ((0, 'positions'), (3, 'normal directions')):
            args = fixture(); args[-1][0, channel] += 1
            with self.assertRaisesRegex(ValueError, message):
                normals.reconstruct(*args)

    def test_ambiguous_joint_and_active_morph_are_rejected(self):
        args = fixture()
        other = copy.deepcopy(args[0]['bones'][0]); other['path'] = 'elsewhere/root'
        parent = copy.deepcopy(other); parent['path'] = 'elsewhere'
        args[0]['bones'] += [parent, other]
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            normals.reconstruct(*args)
        args = fixture(); args[3]['initialMorphWeights'] = [50]
        with self.assertRaisesRegex(ValueError, 'Active morph'):
            normals.reconstruct(*args)

    def test_duplicate_bone_rows_must_be_identical(self):
        args = fixture(); args[0]['bones'].append(copy.deepcopy(args[0]['bones'][0]))
        normals.reconstruct(*args)
        args[0]['bones'][-1]['scale'] = [3, 3, 3]
        with self.assertRaisesRegex(ValueError, 'Conflicting duplicate'):
            normals.reconstruct(*args)

    def test_derived_inputs_preserve_source_and_validate_rig_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root/'capture'; source.mkdir()
            frame, row, rig, mesh, frozen = fixture()
            (source/'mesh.bin').write_bytes(struct.pack('<II', 1, 1)+frozen.astype('<f4').tobytes()+struct.pack('<IIII', 3, 0, 0, 0))
            frame_path = source/'frame.json'; frame_path.write_text(json.dumps(frame))
            original = frame_path.read_bytes()
            bundle = root/'bundle'; bundle.write_bytes(b'synthetic original bundle')
            bundle_hash = normals.sha(bundle)
            rig['sources'] = [dict(path=str(bundle), sha256=bundle_hash)]
            rig_path = root/'rig.json'; rig_path.write_text(json.dumps(rig))
            library_path = root/'library.json'
            library = dict(entries=[dict(category=1, id=2, rig=dict(file='rig.json', sha256=normals.sha(rig_path)), source=dict(bundleSHA256=bundle_hash))])
            library_path.write_text(json.dumps(library))
            with self.assertRaisesRegex(ValueError, 'outside the input'):
                normals.derive(frame_path, library_path, [(1, 2)], set(), source/'nested')
            self.assertFalse((source/'nested').exists())
            output = root/'derived'
            report = normals.derive(frame_path, library_path, [(1, 2)], {'test'}, output)
            self.assertEqual(frame_path.read_bytes(), original)
            derived = json.loads((output/'frame-with-source-normals.json').read_text())
            descriptor = derived['meshes'][0]['sourceVertexNormals']
            data = (output/descriptor['file']).read_bytes()
            self.assertEqual(struct.unpack('<fff', data), (1, 0, 0))
            self.assertEqual(descriptor['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(descriptor['geometrySHA256'], normals.sha(source/'mesh.bin'))
            self.assertEqual(set(descriptor), {'file', 'count', 'space', 'sha256', 'geometrySHA256'})
            self.assertEqual(report['sourceFrameSHA256'], normals.sha(frame_path))
            self.assertEqual((output/'mesh.bin').resolve(), (source/'mesh.bin').resolve())
            with self.assertRaisesRegex(ValueError, 'must be new'):
                normals.derive(frame_path, library_path, [(1, 2)], set(), output)
            rig_path.write_text(rig_path.read_text()+' ')
            with self.assertRaisesRegex(ValueError, 'rig SHA256 mismatch'):
                normals.derive(frame_path, library_path, [(1, 2)], set(), root/'invalid')
            self.assertFalse((root/'invalid').exists())


if __name__ == '__main__':
    unittest.main()
