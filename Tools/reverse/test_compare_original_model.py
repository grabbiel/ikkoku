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
    def test_shared_rest_geometry_requires_unique_renderer_name_and_full_coverage(self):
        extra=copy.deepcopy(self.frame['meshes'][0]);extra.update(name='mesh_low',path='root/mesh_low')
        self.frame['meshes'].append(extra);self.write()
        other=copy.deepcopy(self.native['parts'][0]);other['name']='mesh_low/0';self.native['parts'].append(other)
        result=model.compare(self.folder,self.native)
        self.assertTrue(result['gatePassed']);self.assertEqual(result['selectedVertexEntries'],6)
        self.assertEqual({r['sourcePath'] for r in result['parts']},{'root/mesh','root/mesh_low'})
        for row in result['parts']:
            self.assertEqual(row['restSHA256'],extra['restPositions']['sha256'])
            self.assertRegex(row['restSHA256'],r'^[0-9a-f]{64}$')
        self.native['parts'].pop()
        self.assertFalse(model.compare(self.folder,self.native)['gatePassed'])
        self.frame['meshes'][0]['name']='renamed';self.write()
        with self.assertRaisesRegex(ValueError,'Missing or ambiguous exact source vertex identity'):
            model.compare(self.folder,self.native)
        self.frame['meshes'][0]['name']='mesh'
        extra['name']='mesh';self.write()
        with self.assertRaisesRegex(ValueError,'ambiguous exact source vertex identity'):
            model.compare(self.folder,self.native)
    def head201(self):
        self.frame['neutralModel'].update(variant='female201', headID=201, requestedHeadID=201, loadedHeadCatalogID=201,
                                         loadedHeadName='ct_head', loadedHeadCatalog=copy.deepcopy(model.HEAD201_CATALOG))
        self.native['identity']['headID']=201;self.write()

    def bone1(self, sex=1, head_id=0):
        assert head_id in (0, 200, 201) and sex in (0, 1)
        assert head_id != 200 or sex == 1
        variant = ('female' if sex else 'male') + (str(head_id) if head_id else '00') + '-bone1'
        catalog = {0:model.HEAD00_CATALOG,200:model.HEAD200_CATALOG,201:model.HEAD201_CATALOG}[head_id]
        self.frame['neutralModel'].update(variant=variant, sex=sex,requestedSex=sex,boneType=1,requestedBoneType=1,
            headID=head_id,requestedHeadID=head_id,loadedHeadCatalogID=head_id,
            exType=0,requestedExType=0,loadedHeadName='ct_head',loadedHeadCatalog=copy.deepcopy(catalog))
        self.native['identity'].update(sex=sex,headID=head_id)
        if sex == 0:
            self.frame['neutralModel']['actualBodyValues'][0]=.6
            self.native['bodyValues'][0]=.6
        table=np.zeros((32,9),dtype='<f4');table[0,0]=-.25;table[2,7]=.25
        data=struct.pack('<i',32)+table.tobytes();sha=hashlib.sha256(data).hexdigest()
        (self.folder/'body-correction.bytes').write_bytes(data)
        self.frame['neutralModel']['bodyCorrection']=dict(file='body-correction.bytes',sha256=sha,entries=32,
            sourceBodyType=1,sourceFaceType=1,headCorrectValue=.8)
        self.native['identity']['boneType']=1;self.native['inputs']['bodyCorrectionSHA256']=sha
        local=np.diag([1.08,1.08,1.08,1.]).T.reshape(-1).tolist()
        self.frame['bones'].append(dict(path='root/p_cf_body_bone/cf_hit_head',position=[0,0,0],rotation=[0,0,0,1],scale=[1.08]*3))
        self.native['nodeNames'].append('cf_hit_head');self.native['nodeParents'].append(0)
        self.native['nodeWorldMatrices'].append(local);self.native['nodeLocalMatrices']=[self.identity,local]
        self.write()

    def test_corrected_head200_requires_table_and_non_skin_collider(self):
        self.bone1(head_id=200);result=model.compare(self.folder,self.native)
        self.assertTrue(result['gatePassed']);self.assertEqual(result['shapeCoercions'],[])
        self.assertEqual(result['bodyCorrection']['sha256'],self.native['inputs']['bodyCorrectionSHA256'])
        self.assertTrue(result['headColliderScale']['gatePassed'])
        valid=copy.deepcopy(self.frame)
        for field,index in [('actualBodyValues',0),('actualBodyValues',1),('actualFaceValues',0)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][field][index]=.6;self.write()
            with self.subTest(field=field,index=index),self.assertRaisesRegex(ValueError,'shape'):
                model.compare(self.folder,self.native)
        self.frame=valid;self.write()
        self.native['nodeLocalMatrices'][1][0]=1.2
        result=model.compare(self.folder,self.native)
        self.assertFalse(result['gatePassed']);self.assertEqual(result['parts'][0]['vertices']['maximum'],0)
        self.native['nodeLocalMatrices'][1][0]=1.08
        self.native['inputs']['bodyCorrectionSHA256']='0'*64
        with self.assertRaisesRegex(ValueError,'table identity'):model.compare(self.folder,self.native)
        self.native['inputs']['bodyCorrectionSHA256']=self.frame['neutralModel']['bodyCorrection']['sha256']
        path=self.folder/'body-correction.bytes';original=path.read_bytes()
        changed=bytearray(original);changed[-1]^=1;path.write_bytes(changed)
        with self.assertRaisesRegex(ValueError,'Changed or malformed corrected body table'):
            model.compare(self.folder,self.native)
        path.write_bytes(original)
        valid=copy.deepcopy(self.frame)
        for key in ('sourceBodyType','sourceFaceType'):
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['bodyCorrection'][key]=0;self.write()
            with self.subTest(controller=key),self.assertRaisesRegex(ValueError,'table metadata'):
                model.compare(self.folder,self.native)
        self.frame=valid;del self.frame['neutralModel']['bodyCorrection'];self.write()
        with self.assertRaisesRegex(ValueError,'table metadata'):model.compare(self.folder,self.native)

    def test_corrected_head200_rejects_typed_source_native_and_catalog_mismatches(self):
        self.bone1(head_id=200);valid=copy.deepcopy(self.frame);native=copy.deepcopy(self.native)
        for key,wrong in [('sex',0),('requestedSex',0),('headID',0),('requestedHeadID',0),
                          ('boneType',0),('requestedBoneType',0),('exType',1),('requestedExType',1),
                          ('loadedHeadCatalogID',0)]:
            for value in (False,True,None,float(valid['neutralModel'][key]),wrong):
                self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
                with self.subTest(source=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key,value in [('variant','female200'),('variant','female00-bone1'),('variant','female201-bone1'),('variant','unknown'),
                          ('loadedHeadName','p_cf_head_02'),('loadedHeadCatalog',None)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(source=key),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for field in model.HEAD200_CATALOG:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['loadedHeadCatalog'][field]='wrong';self.write()
            with self.subTest(catalog=field),self.assertRaisesRegex(ValueError,'exact source prefab'):
                model.compare(self.folder,self.native)
        self.frame=valid;self.write()
        for key,wrong in [('sex',0),('headID',0),('boneType',0),('exType',1)]:
            for value in (False,True,None,float(native['identity'][key]),wrong):
                self.native=copy.deepcopy(native);self.native['identity'][key]=value
                with self.subTest(native=key,value=value),self.assertRaisesRegex(ValueError,'Native corrected model identity'):
                    model.compare(self.folder,self.native)

    def test_corrected_head200_repeat_requires_independent_run_and_exact_catalog_table(self):
        self.bone1(head_id=200)
        with self.assertRaises(ValueError):model.compare_repeat(self.folder,self.folder)
        with tempfile.TemporaryDirectory() as tmp:
            other=Path(tmp)
            for path in self.folder.iterdir():(other/path.name).write_bytes(path.read_bytes())
            with self.assertRaisesRegex(ValueError,'same producer'):model.compare_repeat(self.folder,other)
            run=copy.deepcopy(self.run);run.update(processID=101,root='C:\\Temp\\IkkokuShaderProbe-'+'c'*32)
            (other/'run.json').write_text(json.dumps(run))
            self.assertTrue(model.compare_repeat(self.folder,other)['gatePassed'])
            valid=copy.deepcopy(self.frame)
            for variant in ('female200','male200-bone1','unknown'):
                self.frame=copy.deepcopy(valid);self.frame['neutralModel']['variant']=variant;self.write()
                (other/'frame.json').write_text(json.dumps(self.frame))
                with self.subTest(variant=variant),self.assertRaisesRegex(ValueError,'variant differs'):
                    model.compare_repeat(self.folder,other)
            self.frame=copy.deepcopy(valid)
            self.frame['neutralModel']['loadedHeadCatalog']['MainData']='p_cf_head_wrong';self.write()
            (other/'frame.json').write_text(json.dumps(self.frame))
            with self.assertRaisesRegex(ValueError,'exact source prefab'):model.compare_repeat(self.folder,other)
            self.frame=valid;self.write();(other/'frame.json').write_text(json.dumps(valid))
            data=bytearray((other/'body-correction.bytes').read_bytes());struct.pack_into('<f',data,4,-.5)
            (other/'body-correction.bytes').write_bytes(data)
            changed=copy.deepcopy(valid);changed['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(data).hexdigest()
            (other/'frame.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'Repeated corrected body table differs'):model.compare_repeat(self.folder,other)

    def test_legacy_head200_without_catalog_retains_prior_compare_path(self):
        valid,native=copy.deepcopy(self.frame),copy.deepcopy(self.native)
        for sex in (1,0):
            self.frame=copy.deepcopy(valid);self.native=copy.deepcopy(native)
            mode=self.frame['neutralModel']
            mode.update(variant='female200' if sex else 'male200',sex=sex,requestedSex=sex,
                        headID=200,requestedHeadID=200,loadedHeadCatalogID=200)
            self.native['identity'].update(sex=sex,headID=200)
            self.assertNotIn('loadedHeadCatalog',mode);self.assertNotIn('exType',mode)
            if sex==0:
                mode['actualBodyValues'][0]=.6;self.native['bodyValues'][0]=.6
            self.write();result=model.compare(self.folder,self.native)
            with self.subTest(sex=sex):
                self.assertTrue(result['gatePassed']);self.assertIsNone(result['bodyCorrection'])
                self.assertIsNone(result['headColliderScale'])

    def test_corrected_head201_requires_table_and_non_skin_collider(self):
        self.bone1(head_id=201);result=model.compare(self.folder,self.native)
        self.assertTrue(result['gatePassed']);self.assertEqual(result['shapeCoercions'],[])
        self.assertEqual(result['bodyCorrection']['sha256'],self.native['inputs']['bodyCorrectionSHA256'])
        self.assertTrue(result['headColliderScale']['gatePassed'])
        self.native['nodeLocalMatrices'][1][0]=1.2
        result=model.compare(self.folder,self.native)
        self.assertFalse(result['gatePassed']);self.assertEqual(result['parts'][0]['vertices']['maximum'],0)
        self.native['nodeLocalMatrices'][1][0]=1.08
        self.native['inputs']['bodyCorrectionSHA256']='0'*64
        with self.assertRaisesRegex(ValueError,'table identity'):model.compare(self.folder,self.native)
        self.native['inputs']['bodyCorrectionSHA256']=self.frame['neutralModel']['bodyCorrection']['sha256']
        valid=copy.deepcopy(self.frame)
        for key in ('sourceBodyType','sourceFaceType'):
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['bodyCorrection'][key]=0;self.write()
            with self.subTest(controller=key),self.assertRaisesRegex(ValueError,'table metadata'):
                model.compare(self.folder,self.native)
        self.frame=valid;del self.frame['neutralModel']['bodyCorrection'];self.write()
        with self.assertRaisesRegex(ValueError,'table metadata'):model.compare(self.folder,self.native)

    def test_corrected_head201_rejects_typed_source_native_and_catalog_mismatches(self):
        self.bone1(head_id=201);valid=copy.deepcopy(self.frame);native=copy.deepcopy(self.native)
        for key,wrong in [('sex',0),('requestedSex',0),('headID',0),('requestedHeadID',0),
                          ('boneType',0),('requestedBoneType',0),('exType',1),('requestedExType',1),
                          ('loadedHeadCatalogID',0)]:
            for value in (False,True,None,wrong):
                self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
                with self.subTest(source=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key,value in [('variant','female201'),('variant','female00-bone1'),
                          ('loadedHeadName','p_cf_head_03'),('loadedHeadCatalog',None)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(source=key),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for field in model.HEAD201_CATALOG:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['loadedHeadCatalog'][field]='wrong';self.write()
            with self.subTest(catalog=field),self.assertRaisesRegex(ValueError,'exact source prefab'):
                model.compare(self.folder,self.native)
        self.frame=valid;self.write()
        for key,wrong in [('sex',0),('headID',0),('boneType',0),('exType',1)]:
            for value in (False,True,None,wrong):
                self.native=copy.deepcopy(native);self.native['identity'][key]=value
                with self.subTest(native=key,value=value),self.assertRaisesRegex(ValueError,'Native corrected model identity'):
                    model.compare(self.folder,self.native)

    def test_corrected_head201_repeat_requires_independent_run_and_exact_catalog_table(self):
        self.bone1(head_id=201)
        with self.assertRaises(ValueError):model.compare_repeat(self.folder,self.folder)
        with tempfile.TemporaryDirectory() as tmp:
            other=Path(tmp)
            for path in self.folder.iterdir():(other/path.name).write_bytes(path.read_bytes())
            with self.assertRaisesRegex(ValueError,'same producer'):model.compare_repeat(self.folder,other)
            run=copy.deepcopy(self.run);run.update(processID=101,root='C:\\Temp\\IkkokuShaderProbe-'+'c'*32)
            (other/'run.json').write_text(json.dumps(run))
            self.assertTrue(model.compare_repeat(self.folder,other)['gatePassed'])
            valid=copy.deepcopy(self.frame)
            self.frame['neutralModel']['loadedHeadCatalog']['MainData']='p_cf_head_wrong';self.write()
            (other/'frame.json').write_text(json.dumps(self.frame))
            with self.assertRaisesRegex(ValueError,'exact source prefab'):model.compare_repeat(self.folder,other)
            self.frame=valid;self.write();(other/'frame.json').write_text(json.dumps(valid))
            data=bytearray((other/'body-correction.bytes').read_bytes());struct.pack_into('<f',data,4,-.5)
            (other/'body-correction.bytes').write_bytes(data)
            changed=copy.deepcopy(valid);changed['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(data).hexdigest()
            (other/'frame.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'Repeated corrected body table differs'):model.compare_repeat(self.folder,other)

    def test_corrected_male_head201_requires_table_collider_and_only_height_coercion(self):
        self.bone1(sex=0,head_id=201);result=model.compare(self.folder,self.native)
        self.assertTrue(result['gatePassed'])
        self.assertEqual([(r['domain'],r['index']) for r in result['shapeCoercions']],[('body',0)])
        self.assertEqual(result['shapeCoercions'][0]['requested'],.5)
        self.assertEqual(result['shapeCoercions'][0]['actual'],float(np.float32(.6)))
        self.assertEqual(result['bodyCorrection']['sourceBodyType'],1)
        self.assertTrue(result['headColliderScale']['gatePassed'])
        valid=copy.deepcopy(self.frame);native=copy.deepcopy(self.native)
        # A second changed rate must fail even when native/readback agree.
        for domain,index,value in [('Body',0,.5),('Body',1,.6),('Face',0,.6)]:
            self.frame=copy.deepcopy(valid);self.native=copy.deepcopy(native)
            self.frame['neutralModel']['actual'+domain+'Values'][index]=value
            self.native[domain.lower()+'Values'][index]=value;self.write()
            with self.subTest(domain=domain,index=index),self.assertRaises(ValueError):
                model.compare(self.folder,self.native)
        self.frame=valid;self.native=native;self.write()
        self.native['nodeLocalMatrices'][1][0]=1.2
        result=model.compare(self.folder,self.native)
        self.assertFalse(result['gatePassed']);self.assertEqual(result['parts'][0]['vertices']['maximum'],0)
        self.native['nodeLocalMatrices'][1][0]=1.08
        self.native['inputs']['bodyCorrectionSHA256']='0'*64
        with self.assertRaisesRegex(ValueError,'table identity'):model.compare(self.folder,self.native)
        self.native['inputs']['bodyCorrectionSHA256']=valid['neutralModel']['bodyCorrection']['sha256']
        table=self.folder/'body-correction.bytes';data=table.read_bytes();table.write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError,'Changed or malformed corrected body table'):
            model.compare(self.folder,self.native)
        table.write_bytes(data)
        del self.frame['neutralModel']['bodyCorrection'];self.write()
        with self.assertRaisesRegex(ValueError,'table metadata'):model.compare(self.folder,self.native)

    def test_corrected_male_head201_rejects_typed_identity_catalog_and_table_mutations(self):
        self.bone1(sex=0,head_id=201);valid=copy.deepcopy(self.frame);native=copy.deepcopy(self.native)
        for key,wrong in [('sex',1),('requestedSex',1),('headID',0),('requestedHeadID',0),
                          ('boneType',0),('requestedBoneType',0),('exType',1),('requestedExType',1),
                          ('loadedHeadCatalogID',0)]:
            for value in (False,True,None,float(valid['neutralModel'][key]),wrong):
                self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
                with self.subTest(source=key,value=value),self.assertRaises(ValueError):
                    model.compare(self.folder,self.native)
        for key,value in [('variant','male201'),('variant','male00-bone1'),('variant','female201-bone1'),
                          ('variant','male201-bone1-wrong'),
                          ('loadedHeadName','p_cf_head_03'),('loadedHeadCatalog',None)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(source=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for field in model.HEAD201_CATALOG:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['loadedHeadCatalog'][field]='wrong';self.write()
            with self.subTest(catalog=field),self.assertRaisesRegex(ValueError,'exact source prefab'):
                model.compare(self.folder,self.native)
        for key in ('sourceBodyType','sourceFaceType'):
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['bodyCorrection'][key]=0;self.write()
            with self.subTest(controller=key),self.assertRaisesRegex(ValueError,'table metadata'):
                model.compare(self.folder,self.native)
        self.frame=valid;self.write()
        for key,wrong in [('sex',1),('headID',0),('boneType',0),('exType',1)]:
            for value in (False,True,None,float(native['identity'][key]),wrong):
                self.native=copy.deepcopy(native);self.native['identity'][key]=value
                with self.subTest(native=key,value=value),self.assertRaisesRegex(ValueError,'Native corrected model identity'):
                    model.compare(self.folder,self.native)

    def test_corrected_male_head201_repeat_rejects_copied_producer_and_changed_table(self):
        self.bone1(sex=0,head_id=201)
        with self.assertRaises(ValueError):model.compare_repeat(self.folder,self.folder)
        with tempfile.TemporaryDirectory() as tmp:
            other=Path(tmp)
            for path in self.folder.iterdir():(other/path.name).write_bytes(path.read_bytes())
            with self.assertRaisesRegex(ValueError,'same producer'):model.compare_repeat(self.folder,other)
            run=copy.deepcopy(self.run);run.update(processID=101,root='C:\\Temp\\IkkokuShaderProbe-'+'c'*32)
            (other/'run.json').write_text(json.dumps(run))
            self.assertTrue(model.compare_repeat(self.folder,other)['gatePassed'])
            changed=copy.deepcopy(self.frame)
            changed['neutralModel'].update(variant='female201-bone1',sex=1,requestedSex=1)
            (other/'frame.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'Repeated source input identity differs'):model.compare_repeat(self.folder,other)
            changed=copy.deepcopy(self.frame);changed['neutralModel']['loadedHeadCatalog']['MainData']='wrong'
            (other/'frame.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'exact source prefab'):model.compare_repeat(self.folder,other)
            data=bytearray((other/'body-correction.bytes').read_bytes());struct.pack_into('<f',data,4,-.5)
            (other/'body-correction.bytes').write_bytes(data)
            changed=copy.deepcopy(self.frame);changed['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(data).hexdigest()
            (other/'frame.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'Repeated corrected body table differs'):model.compare_repeat(self.folder,other)

    def test_corrected_male_requires_table_and_collider_with_only_height_coercion(self):
        self.bone1(sex=0);result=model.compare(self.folder,self.native)
        self.assertTrue(result['gatePassed'])
        self.assertEqual([(r['domain'],r['index']) for r in result['shapeCoercions']],[('body',0)])
        self.assertEqual(result['bodyCorrection']['sourceBodyType'],1) # typeBone, not sex
        self.assertTrue(result['headColliderScale']['gatePassed'])
        self.native['nodeLocalMatrices'][1][0]=1
        result=model.compare(self.folder,self.native)
        self.assertFalse(result['gatePassed']);self.assertEqual(result['parts'][0]['vertices']['maximum'],0)
        self.native['nodeLocalMatrices'][1][0]=1.08
        self.native['inputs']['bodyCorrectionSHA256']='0'*64
        with self.assertRaisesRegex(ValueError,'table identity'):model.compare(self.folder,self.native)
        self.native['inputs']['bodyCorrectionSHA256']=self.frame['neutralModel']['bodyCorrection']['sha256']
        self.frame['neutralModel']['actualBodyValues'][1]=.6;self.write()
        with self.assertRaisesRegex(ValueError,'unexpectedly changed requested body'):model.compare(self.folder,self.native)
        self.frame['neutralModel']['actualBodyValues'][1]=.5
        del self.frame['neutralModel']['bodyCorrection'];self.write()
        with self.assertRaisesRegex(ValueError,'table metadata'):model.compare(self.folder,self.native)

    def test_corrected_male_rejects_typed_source_native_and_controller_identity_mismatches(self):
        self.bone1(sex=0);valid=copy.deepcopy(self.frame);native=copy.deepcopy(self.native)
        for key,wrong in [('sex',1),('requestedSex',1),('headID',200),('requestedHeadID',200),
                          ('boneType',0),('requestedBoneType',0),('exType',1),('requestedExType',1),
                          ('loadedHeadCatalogID',200)]:
            for value in (False,True,None,wrong):
                self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
                with self.subTest(source=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key,value in [('variant','female00-bone1'),('variant','male00'),('loadedHeadName','p_cf_head_00'),
                          ('loadedHeadCatalog',{})]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(source=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key in ('sourceBodyType','sourceFaceType'):
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['bodyCorrection'][key]=0;self.write()
            with self.subTest(controller=key),self.assertRaisesRegex(ValueError,'table metadata'):model.compare(self.folder,self.native)
        self.frame=valid;self.write()
        for key,wrong in [('sex',1),('headID',200),('boneType',0),('exType',1)]:
            for value in (False,True,None,wrong):
                self.native=copy.deepcopy(native);self.native['identity'][key]=value
                with self.subTest(native=key,value=value),self.assertRaisesRegex(ValueError,'Native corrected model identity'):
                    model.compare(self.folder,self.native)

    def test_corrected_model_table_and_collider_pass_independently_of_skin(self):
        self.bone1();result=model.compare(self.folder,self.native)
        self.assertTrue(result['gatePassed']);self.assertEqual(result['selectedSkinBindings'],1)
        self.assertTrue(result['headColliderScale']['gatePassed'])
        self.assertEqual(result['bodyCorrection']['sha256'],self.native['inputs']['bodyCorrectionSHA256'])
        # The collider is not a skin joint: corrupting only its local scale
        # must fail even when every selected world vertex still matches.
        self.native['nodeLocalMatrices'][1][0]=1.2
        result=model.compare(self.folder,self.native)
        self.assertFalse(result['gatePassed']);self.assertEqual(result['parts'][0]['vertices']['maximum'],0)
        self.native['nodeLocalMatrices'][1][0]=1.08
        self.frame['bones'][-1]['scale']=[1.2]*3;self.write()
        self.assertFalse(model.compare(self.folder,self.native)['gatePassed'])

    def test_corrected_model_rejects_identity_and_table_metadata(self):
        self.bone1();valid=copy.deepcopy(self.frame)
        for key,value in [('boneType',0),('boneType',True),('requestedBoneType',True),('sex',0),
                          ('requestedHeadID',200),('exType',False),('requestedExType',1),('variant','female00'),
                          ('loadedHeadName','p_cf_head_00'),('loadedHeadCatalog',{}),('bodyCorrection',None),('bodyCorrection',[])]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key,value in [('file','../body-correction.bytes'),('sha256','x'*64),('entries',None),('entries',True),
                          ('sourceBodyType',True),('sourceFaceType',0),('headCorrectValue',True),
                          ('headCorrectValue',float('nan')),('headCorrectValue',10**1000),('headCorrectValue',.9)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['bodyCorrection'][key]=value;self.write()
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        self.frame=valid;self.write();identity=copy.deepcopy(self.native['identity'])
        for key,value in [('boneType',True),('exType',False),('sex',True),('headID',False)]:
            self.native['identity']=dict(identity,**{key:value})
            with self.subTest(nativeKey=key),self.assertRaisesRegex(ValueError,'Native corrected model identity'):
                model.compare(self.folder,self.native)
        self.native['identity']=identity;self.native['inputs'].pop('bodyCorrectionSHA256')
        with self.assertRaisesRegex(ValueError,'table identity'):model.compare(self.folder,self.native)

    def test_corrected_model_rejects_changed_truncated_count_and_nonfinite_table(self):
        self.bone1();path=self.folder/'body-correction.bytes';valid=path.read_bytes()
        changed=bytearray(valid);struct.pack_into('<f',changed,4,-.5)
        path.write_bytes(changed)
        with self.assertRaisesRegex(ValueError,'Changed or malformed'):model.compare(self.folder,self.native)
        nonfinite=bytearray(valid);struct.pack_into('<f',nonfinite,4,float('nan'))
        denominator=bytearray(valid);struct.pack_into('<f',denominator,4+(2*9+7)*4,-1)
        for data in (valid[:-1],struct.pack('<i',31)+valid[4:],bytes(nonfinite),bytes(denominator)):
            path.write_bytes(data);sha=hashlib.sha256(data).hexdigest()
            self.frame['neutralModel']['bodyCorrection']['sha256']=sha;self.native['inputs']['bodyCorrectionSHA256']=sha;self.write()
            with self.subTest(bytes=len(data)),self.assertRaises(ValueError):model.compare(self.folder,self.native)

    def test_corrected_collider_requires_unique_hierarchy_and_finite_local_matrix(self):
        self.bone1();frame,native=copy.deepcopy(self.frame),copy.deepcopy(self.native)
        mutations=[lambda: self.frame['bones'].pop(),lambda: self.frame['bones'].append(copy.deepcopy(self.frame['bones'][-1])),
            lambda: self.frame['bones'][-1].update(path='root/cf_hit_head'),
            lambda: self.native['nodeNames'].__setitem__(1,'other'),
            lambda: self.native['nodeNames'].__setitem__(0,'cf_hit_head'),
            lambda: self.native.pop('nodeLocalMatrices'),
            lambda: self.native['nodeLocalMatrices'].__setitem__(1,[0]*15),
            lambda: self.native['nodeLocalMatrices'][1].__setitem__(0,True),
            lambda: self.native['nodeLocalMatrices'][1].__setitem__(0,float('nan')),
            lambda: self.native['nodeLocalMatrices'][1].__setitem__(0,0),
            lambda: self.native['nodeLocalMatrices'][1].__setitem__(0,-1.08)]
        for index,mutate in enumerate(mutations):
            self.frame,self.native=copy.deepcopy(frame),copy.deepcopy(native);mutate();self.write()
            with self.subTest(index=index),self.assertRaises(ValueError):model.compare(self.folder,self.native)

    def test_corrected_repeat_validates_each_table_and_detects_different_table(self):
        self.bone1()
        with tempfile.TemporaryDirectory() as tmp:
            other=Path(tmp)
            for path in self.folder.iterdir():(other/path.name).write_bytes(path.read_bytes())
            run=copy.deepcopy(self.run);run['processID']=101;(other/'run.json').write_text(json.dumps(run))
            self.assertTrue(model.compare_repeat(self.folder,other)['gatePassed'])
            data=bytearray((other/'body-correction.bytes').read_bytes());struct.pack_into('<f',data,4,-.5)
            (other/'body-correction.bytes').write_bytes(data)
            with self.assertRaisesRegex(ValueError,'Changed or malformed'):model.compare_repeat(self.folder,other)
            changed=copy.deepcopy(self.frame);changed['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(data).hexdigest()
            (other/'frame.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'Repeated corrected body table differs'):model.compare_repeat(self.folder,other)

    def test_head201_requires_exact_measured_catalog_and_loaded_identity(self):
        self.head201();self.assertTrue(model.compare(self.folder,self.native)['gatePassed'])
        valid=copy.deepcopy(self.frame)
        for key,value in [('loadedHeadCatalog',None),('loadedHeadCatalog',{}),('loadedHeadCatalog',[]),
                          ('loadedHeadName','p_cf_head_03'),('sex',True),('requestedHeadID',200)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for field in model.HEAD201_CATALOG:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['loadedHeadCatalog'][field]='wrong';self.write()
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'exact source prefab'):
                model.compare(self.folder,self.native)

    def test_head201_repeat_rejects_matching_forged_catalogs(self):
        self.head201()
        with tempfile.TemporaryDirectory() as tmp:
            other=Path(tmp)
            for path in self.folder.iterdir():(other/path.name).write_bytes(path.read_bytes())
            run=copy.deepcopy(self.run);run['processID']=101;(other/'run.json').write_text(json.dumps(run))
            self.assertTrue(model.compare_repeat(self.folder,other)['gatePassed'])
            self.frame['neutralModel']['loadedHeadCatalog']['MainData']='p_cf_head_wrong';self.write()
            (other/'frame.json').write_text(json.dumps(self.frame))
            with self.assertRaisesRegex(ValueError,'exact source prefab'):model.compare_repeat(self.folder,other)

    def test_male201_requires_requested_sex_identity_and_normal_height(self):
        self.head201();mode=self.frame['neutralModel']
        mode.update(variant='male201',sex=0,requestedSex=0,exType=0,requestedExType=0)
        mode['actualBodyValues'][0]=.6
        self.native['identity']['sex']=0;self.native['bodyValues'][0]=.6;self.write()
        # Manager flags remain enabled; the source late setter itself is sex-gated.
        result=model.compare(self.folder,self.native);self.assertTrue(result['gatePassed'])
        self.assertEqual([(r['domain'],r['index']) for r in result['shapeCoercions']],[('body',0)])
        valid=copy.deepcopy(self.frame)
        for key,value in [('sex',1),('sex',False),('requestedSex',1),('requestedSex',False),
                          ('variant','female201'),('headID',200),('requestedHeadID',200),
                          ('boneType',False),('loadedHeadCatalogID',200),('loadedHeadCatalog',None),
                          ('exType',1),('exType',False),('requestedExType',1),('requestedExType',None)]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for field in model.HEAD201_CATALOG:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['loadedHeadCatalog'][field]='wrong';self.write()
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'exact source prefab'):
                model.compare(self.folder,self.native)
        missing=copy.deepcopy(valid['neutralModel']);del missing['exType']
        with self.assertRaisesRegex(ValueError,'normal model identity'):model.source_head_identity(missing)

    def test_male00_requires_exact_identity_catalog_and_only_height_coercion(self):
        mode=self.frame['neutralModel']
        mode.update(variant='male00',sex=0,requestedSex=0,exType=0,requestedExType=0,
                    loadedHeadName='ct_head',loadedHeadCatalog=copy.deepcopy(model.HEAD00_CATALOG))
        mode['actualBodyValues'][0]=.6
        self.native['identity']['sex']=0;self.native['bodyValues'][0]=.6;self.write()
        result=model.compare(self.folder,self.native);self.assertTrue(result['gatePassed'])
        self.assertEqual([(r['domain'],r['index']) for r in result['shapeCoercions']],[('body',0)])
        self.assertIsNone(result['headColliderScale']);self.assertIsNone(result['bodyCorrection'])
        valid=copy.deepcopy(self.frame)
        for key in ('sex','requestedSex','headID','requestedHeadID','boneType','requestedBoneType',
                    'exType','requestedExType','loadedHeadCatalogID'):
            for value in (False,True,None,1,201):
                self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
                with self.subTest(key=key,value=value),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key,value in [('variant','female00'),('variant','male201'),('loadedHeadName','p_cf_head_00'),('loadedHeadCatalog',{})]:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel'][key]=value;self.write()
            with self.subTest(key=key),self.assertRaises(ValueError):model.compare(self.folder,self.native)
        for key in model.HEAD00_CATALOG:
            self.frame=copy.deepcopy(valid);self.frame['neutralModel']['loadedHeadCatalog'][key]='wrong';self.write()
            with self.subTest(catalog=key),self.assertRaisesRegex(ValueError,'exact source prefab'):model.compare(self.folder,self.native)
        self.frame=valid;self.write()
        for key in ('sex','headID','boneType','exType'):
            self.native['identity'][key]=False
            with self.subTest(native=key),self.assertRaisesRegex(ValueError,'Native normal male00'):model.compare(self.folder,self.native)
            self.native['identity'][key]=0
        self.frame['neutralModel']['actualBodyValues'][1]=.6;self.write()
        with self.assertRaisesRegex(ValueError,'unexpectedly changed requested body'):model.compare(self.folder,self.native)

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
    def test_valid_signed_sparse_and_empty_morph_channels(self):
        part, mesh = self.native['parts'][0], self.frame['meshes'][0]
        part['morphNames'] = mesh['morphNames'] = ['mouth', 'eye']
        mesh['morphWeights'] = [-0.5, 0]
        part['morphWeights'] = [dict(index=0, weight=-0.5)]
        self.write(); self.assertTrue(model.compare(self.folder, self.native)['gatePassed'])
        mesh['morphWeights'] = [0, 0]; part['morphWeights'] = []
        self.write(); self.assertTrue(model.compare(self.folder, self.native)['gatePassed'])
        part['morphNames'] = mesh['morphNames'] = []
        mesh['morphWeights'] = []
        self.write(); self.assertTrue(model.compare(self.folder, self.native)['gatePassed'])

    def test_malformed_sparse_morph_entries_rejected(self):
        cases = [([dict(index=-1, weight=0)], 'integer within'),
                 ([dict(index=True, weight=0)], 'integer within'),
                 ([dict(index=0.0, weight=0)], 'integer within'),
                 ([dict(index=1, weight=0)], 'integer within'),
                 ([dict(index=0, weight=1), dict(index=0, weight=0)], 'Duplicate'),
                 ([0], 'index/weight record'),
                 ([dict(index=0, weight=0), None], 'index/weight record'),
                 (None, 'must be a list')]
        for entries, message in cases:
            self.native['parts'][0]['morphWeights'] = entries
            with self.subTest(entries=entries), self.assertRaisesRegex(ValueError, message):
                model.compare(self.folder, self.native)

    def test_source_dense_morph_length_rejected_before_broadcasting(self):
        self.native['parts'][0]['morphNames'] = self.frame['meshes'][0]['morphNames'] = ['mouth', 'eye']
        for weights in ([0], [], [0, 0, 0], None):
            self.frame['meshes'][0]['morphWeights'] = weights; self.write()
            with self.subTest(weights=weights), self.assertRaisesRegex(ValueError, 'Source dense morph weights'):
                model.compare(self.folder, self.native)

    def test_nonfinite_and_mistyped_morph_values_rejected(self):
        for value in (True, '0', None, float('nan'), float('inf'), -float('inf'), 10 ** 1000):
            for source in (False, True):
                self.frame['meshes'][0]['morphWeights'] = [value if source else 0]
                self.native['parts'][0]['morphWeights'] = [] if source else [dict(index=0, weight=value)]
                self.write()
                with self.subTest(value=value, source=source), self.assertRaisesRegex(ValueError, 'finite numeric'):
                    model.compare(self.folder, self.native)

    def test_zero_channel_weights_must_be_empty(self):
        part, mesh = self.native['parts'][0], self.frame['meshes'][0]
        part['morphNames'] = mesh['morphNames'] = []
        mesh['morphWeights'] = [0]; self.write()
        with self.assertRaisesRegex(ValueError, 'Source dense morph weights'):
            model.compare(self.folder, self.native)
        mesh['morphWeights'] = []; self.write()
        part['morphWeights'] = [dict(index=0, weight=0)]
        with self.assertRaisesRegex(ValueError, 'integer within'):
            model.compare(self.folder, self.native)

    def test_morph_error_threshold_is_unchanged(self):
        part = self.native['parts'][0]
        part['morphWeights'] = [dict(index=0, weight=1e-4)]
        within = model.compare(self.folder, self.native)
        self.assertTrue(within['gatePassed'])
        self.assertEqual(within['parts'][0]['morphWeightMaxError'], 1e-4)
        part['morphWeights'] = [dict(index=0, weight=1.0001e-4)]
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
