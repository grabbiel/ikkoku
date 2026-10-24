"""Authored neutral capture corruption/control tests; no proprietary fixture required."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
import numpy as np
import compare_original_model as model

class ModelComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.folder = Path(self.temp.name)
        self.identity = np.eye(4).T.reshape(-1).tolist()
        rest = np.asarray([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype='<f4')
        def sidecar(name, values):
            data = values.tobytes(); (self.folder / name).write_bytes(data)
            return dict(file=name, sha256=hashlib.sha256(data).hexdigest())
        vertices = np.zeros((3, 20), dtype='<f4'); vertices[:, :3] = rest
        data = struct.pack('<ii', 3, 1) + vertices.tobytes() + struct.pack('<iiii', 3, 0, 1, 2)
        (self.folder / 'geometry.bin').write_bytes(data); (self.folder / 'card.png').write_bytes(b'authored test card identity')
        mesh = dict(sourceVertexNormals=dict(geometrySHA256=hashlib.sha256(data).hexdigest()), name='mesh', path='root/mesh', vertices=3, submeshes=1, file='geometry.bin',
            restPositions=sidecar('rest.bin', rest), bakedPositions=sidecar('baked.bin', rest),
            lossyScale=[1, 1, 1], rendererMatrix=self.identity, morphNames=['mouth'], morphWeights=[0],
            skinBones=[dict(name='p_cf_body_bone', path='root/p_cf_body_bone', worldMatrix=self.identity)], inverseBindMatrices=[self.identity])
        self.frame = dict(card='card.png', meshes=[mesh], bones=[dict(path=p, position=[0,0,0], rotation=[0,0,0,1], scale=[1,1,1]) for p in ['root','root/p_cf_body_bone']],
            neutralModel=dict(variant='female00', sex=1, headID=0, boneType=0, requestedSex=1, requestedHeadID=0, requestedBoneType=0,
                loadedHeadCatalogID=0, handControllerCounts={'L':1,'R':1}, eyeAngleHRate=0, eyeAngleVRate=0, assemblySHA256='test-assembly', handPatterns=[0,0], elapsedFramesAfterLoad=0, hiPoly=True, enableCorrectArmSize=False,
                enableCorrectHandSize=True, requestedBodyValues=[.5]*44, requestedFaceValues=[.5]*52, actualBodyValues=[.5]*44, actualFaceValues=[.5]*52, animators=[]))
        native_rest = rest.copy(); native_rest[:, 2] *= -1
        self.native = dict(kind='ikkoku-neutral-source-model', identity=dict(sex=1, headID=0, boneType=0, exType=0),
            inputs=dict(cardSHA256=hashlib.sha256(b'authored test card identity').hexdigest()), bodyValues=[.5]*44, faceValues=[.5]*52,
            lateCorrectionOptions=dict(hiPoly=True, enableCorrectArmSize=False, enableCorrectHandSize=True),
            nodeNames=['p_cf_body_bone'], nodeParents=[-1], nodeWorldMatrices=[self.identity],
            parts=[dict(name='mesh/0', selected=True, active=True, hasCloth=False, restPositions=native_rest.tolist(),
                vertexCount=3, indices=[0,2,1], positions=native_rest.tolist(), morphNames=['mouth'], morphWeights=[],
                nodeSourceID='mesh-source-id', jointNodes=[0], inverseBindMatrices=[self.identity])])
        self.write()
        self.run = dict(vm='authored VM', root='C:\\Temp\\IkkokuShaderProbe-'+'a'*32, processID=100,
                        sourceSHA256='b'*64, currentUser=True, stopped=True)
        (self.folder/'run.json').write_text(json.dumps(self.run))
    def tearDown(self): self.temp.cleanup()
    def write(self): (self.folder / 'frame.json').write_text(json.dumps(self.frame))
    def test_all_vertices_and_ordered_skin_bones_pass_without_alignment(self):
        result = model.compare(self.folder, self.native)
        self.assertTrue(result['gatePassed']); self.assertEqual(result['selectedVertexEntries'], 3)
        self.assertEqual(result['selectedSkinBindings'], 1); self.assertEqual(result['omittedOriginalComponents'], [])
    def test_extra_original_visible_mesh_and_missing_native_mesh_fail(self):
        extra=copy.deepcopy(self.frame['meshes'][0]);extra['path']='root/extra';extra['name']='extra'
        # Distinct rest identity avoids the separate ambiguity rejection.
        extra['restPositions']=dict(file='rest.bin',sha256='1'*64)
        self.frame['meshes'].append(extra);self.write()
        self.assertFalse(model.compare(self.folder,self.native)['gatePassed'])
        self.frame['meshes'].pop();self.write()
        self.native['parts'][0].update(selected=False,selectionReason='test dropped visible renderer')
        self.assertFalse(model.compare(self.folder,self.native)['gatePassed'])
    def test_missing_driven_hand_controller_rejected(self):
        self.frame['neutralModel']['handControllerCounts']['R']=0;self.write()
        with self.assertRaises(ValueError):model.compare(self.folder,self.native)
    def test_only_exact_shadow_identity_is_excluded(self):
        shadow=copy.deepcopy(self.frame['meshes'][0]);shadow.update(path='root/shadow',name='o_shadowcaster',vertices=1360)
        shadow['restPositions']['sha256']='f71b0f52dfe393634b5b8a67f5650f728b666e06cc95357c38c5ee9c09fd95f7'
        self.frame['meshes'].append(shadow);self.write()
        self.assertTrue(model.compare(self.folder,self.native)['gatePassed'])
        shadow['restPositions']['sha256']='1'*64;self.write()
        self.assertFalse(model.compare(self.folder,self.native)['gatePassed'])
    def test_missing_native_inverse_bind_cannot_skip_bone_gate(self):
        self.native['parts'][0]['inverseBindMatrices']=[]
        with self.assertRaises(ValueError):model.compare(self.folder,self.native)
    def test_last_vertex_mutation_fails_even_when_first_two_match(self):
        self.native['parts'][0]['positions'][2][0] += .01
        self.assertFalse(model.compare(self.folder, self.native)['gatePassed'])
    def test_changed_bone_fails_independently_of_vertex_output(self):
        self.native['nodeWorldMatrices'] = [list(self.identity)]; self.native['nodeWorldMatrices'][0][12] = .01
        self.assertFalse(model.compare(self.folder, self.native)['gatePassed'])
    def test_morph_and_bake_are_separate_gates(self):
        self.native['parts'][0]['morphWeights'] = [dict(index=0,weight=1)]
        self.assertFalse(model.compare(self.folder, self.native)['gatePassed'])
        self.native['parts'][0]['morphWeights'] = []
        baked = np.asarray([[0,0,0],[1,0,0],[.01,1,0]],dtype='<f4').tobytes()
        (self.folder/'baked.bin').write_bytes(baked)
        self.frame['meshes'][0]['bakedPositions']['sha256']=hashlib.sha256(baked).hexdigest(); self.write()
        result=model.compare(self.folder,self.native)
        self.assertFalse(result['gatePassed']); self.assertEqual(result['parts'][0]['vertices']['overTolerance'],0)
    def test_identity_shape_and_context_mismatches_rejected(self):
        mutations=[('headID',200),('requestedHeadID',200),('loadedHeadCatalogID',200),('enableCorrectHandSize',False),('actualBodyValues',[.6])]
        for key,value in mutations:
            with self.subTest(key=key):
                before=copy.deepcopy(self.frame); self.frame['neutralModel'][key]=value;self.write()
                with self.assertRaises(ValueError):model.compare(self.folder,self.native)
                self.frame=before;self.write()
    def test_corrupt_rest_hash_topology_card_and_inverse_bind_rejected(self):
        for mutation in ['hash','topology','card','bind']:
            with self.subTest(mutation=mutation):
                n=copy.deepcopy(self.native); f=copy.deepcopy(self.frame)
                if mutation=='hash':self.frame['meshes'][0]['restPositions']['sha256']='0'*64
                elif mutation=='topology':n['parts'][0]['indices']=[0,1,2]
                elif mutation=='card':n['inputs']['cardSHA256']='0'*64
                else:n['parts'][0]['inverseBindMatrices']=[list(self.identity)];n['parts'][0]['inverseBindMatrices'][0][12]=.01
                self.write()
                with self.assertRaises(ValueError):model.compare(self.folder,n)
                self.frame=f;self.write()
    def test_sidecar_path_and_geometry_boundary_rejected(self):
        with self.assertRaises(ValueError):model.sidecar(self.folder,dict(file='../elsewhere',sha256='0'*64),3)
        path=self.folder/'geometry.bin';path.write_bytes(path.read_bytes()+b'x')
        with self.assertRaises(ValueError):model.compare(self.folder,self.native)
    def test_repeat_is_exact_and_detects_loaded_pose_drift(self):
        with self.assertRaises(ValueError):model.compare_repeat(self.folder,self.folder)
        with tempfile.TemporaryDirectory() as tmp:
            other=Path(tmp)
            for file in self.folder.iterdir():(other/file.name).write_bytes(file.read_bytes())
            with self.assertRaises(ValueError):model.compare_repeat(self.folder,other)
            run=copy.deepcopy(self.run);run['processID']=101
            (other/'run.json').write_text(json.dumps(run))
            # Identical frame data is valid when a separate source run produced it.
            repeat=model.compare_repeat(self.folder,other)
            self.assertTrue(repeat['gatePassed']);self.assertNotEqual(repeat['producerRuns'][0]['file']['sha256'],repeat['producerRuns'][1]['file']['sha256'])
            frame=copy.deepcopy(self.frame);frame['bones'][1]['position'][0]=1e-7
            (other/'frame.json').write_text(json.dumps(frame))
            self.assertFalse(model.compare_repeat(self.folder,other)['gatePassed'])

if __name__=='__main__':unittest.main()
