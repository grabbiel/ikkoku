import unittest
from compare_draw_overlays import compare

def _frame(overrides=None):
 """Synthetic frame: face/body bind slots 1-3/1-2; left+right eye bind slots 1-2."""
 materials={'cf_m_face_00':{'_overtex1':['cw_t_lip_001',3],'_overtex2':['idol_khohoaka',2],
   '_overtex3':['cw_t_eyeshadow_002',3],'_overcolor1':[0.9,0.1,0.2,1],'_overcolor2':[1,0.69,0.69,0.1],
   '_overcolor3':[0.2,0.3,0.9,1],'_Color':[1,1,1,1],'_LineColor':[0,0,0,1]},
  'cf_m_body':{'_overtex1':['cw_t_nip_002',3],'_overtex2':['cf_mnpk_02_t',3],
   '_overcolor1':[0.8,0.4,0.5,1],'_overcolor2':[0.1,0.1,0.1,1],'_overcolor3':[1,1,1,1]},
  'cf_m_hitomi_00':{'_overtex1':['cw_t_hitomi_hi_u_005',3],'_overtex2':['cw_t_hitomi_hi_d_004',3],
   '_overcolor1':[1,1,0.8,1],'_overcolor2':[0.9,0.9,1,1]}}
 if overrides:
  for name,properties in materials.items():
   if name in overrides:properties.update(overrides[name])
 meshes=[];textures=[]
 def file(name):
  for entry in textures:
   if entry['name']==name:return entry['file']
  name_only='texture-'+str(len(textures));textures.append({'file':name_only,'name':name});return name_only
 for name,properties in materials.items():
  meshes.append({'materials':[{'name':name,'properties':
   {key:({'file':file(value[0]),'scale':[value[1],0,0],'offset':[0,0]}
          if key.startswith('_overtex') else value) for key,value in properties.items()}}]})
 return {'meshes':meshes,'textures':textures}

def _bindings(overrides=None):
 bindings=[{'material':'face','slot':'overtex1','category':'mt_lip','id':2,
            'rgba':[0.9,0.1,0.2,1],'rgbFromPrefab':False},
           {'material':'face','slot':'overtex2','category':'prefab','id':None,
            'rgba':[1,1,1,0.1],'rgbFromPrefab':True},
           {'material':'face','slot':'overtex3','category':'mt_eyeshadow','id':3,
            'rgba':[0.2,0.3,0.9,1],'rgbFromPrefab':False},
           {'material':'body','slot':'overtex1','category':'mt_nip','id':2,
            'rgba':[0.8,0.4,0.5,1],'rgbFromPrefab':False},
           {'material':'body','slot':'overtex2','category':'mt_underhair','id':2,
            'rgba':[0.1,0.1,0.1,1],'rgbFromPrefab':False},
           {'material':'eye','slot':'overtex1','category':'mt_eye_hi_up','id':5,
            'rgba':[1,1,0.8,1],'rgbFromPrefab':False},
           {'material':'eye','slot':'overtex2','category':'mt_eye_hi_down','id':4,
            'rgba':[0.9,0.9,1,1],'rgbFromPrefab':False}]
 if overrides is not None:
  for key,value in overrides.items():
   if value is None:
    bindings=[b for b in bindings if (b['material'],b['slot'])!=tuple(key.split('.'))]
   else:
    for b in bindings:
     if (b['material'],b['slot'])==tuple(key.split('.')):b.update(value)
 return {'bindings':bindings,'hohoAkaRate':0.5,'diagnostics':[]}

def _catalog():
 tables={'mt_lip_00':{'id':2,'texture':'cw_t_lip_001','category':'mt_lip','setting':'lipId'},
  'mt_eyeshadow_00':{'id':3,'texture':'cw_t_eyeshadow_002','category':'mt_eyeshadow','setting':'eyeshadowId'},
  'mt_nip_00':{'id':2,'texture':'cw_t_nip_002','category':'mt_nip','setting':'nipId'},
  'mt_underhair_00':{'id':2,'texture':'cf_mnpk_02_t','category':'mt_underhair','setting':'underhairId'},
  'mt_eye_hi_up_00':{'id':5,'texture':'cw_t_hitomi_hi_u_005','category':'mt_eye_hi_up','setting':'hlUpId'},
  'mt_eye_hi_down_00':{'id':4,'texture':'cw_t_hitomi_hi_d_004','category':'mt_eye_hi_down','setting':'hlDownId'}}
 return {'tables':tables}

class DrawOverlayComparisonTests(unittest.TestCase):
 def test_matching_bindings_and_recordings_pass(self):
  report=compare(_bindings(),_frame(),_catalog(),{'frame.json':'a','fixture-card.png':'b'})
  self.assertTrue(report['passes'])
  self.assertEqual({slot['slot'] for slot in report['slots']},
                   {'overtex1','overtex2','overtex3'})
  blush=[slot for slot in report['slots'] if slot['category']=='prefab']
  self.assertEqual(blush[0]['expectedTexture'],'prefab')
  self.assertTrue(blush[0]['alphaOnlyComparison'])
 def test_wrong_color_or_wrong_texture_name_fails_one_slot(self):
  report=compare(_bindings(),_frame({'cf_m_body':{'_overcolor1':[0.8,0.4,0.5,0.9]}}),
                 _catalog(),{'frame.json':'a','fixture-card.png':'b'})
  failed=[slot for slot in report['slots'] if not slot['passes']]
  self.assertEqual(len(failed),1);self.assertEqual(failed[0]['category'],'mt_nip')
  self.assertFalse(report['passes'])
  report=compare(_bindings(),_frame({'cf_m_face_00':{'_overtex1':['wrong_lip',3]}}),
                 _catalog(),{'frame.json':'a','fixture-card.png':'b'})
  failed=[slot for slot in report['slots'] if not slot['passes']]
  self.assertEqual([slot['slot'] for slot in failed],['overtex1'])
  self.assertFalse(report['passes'])
 def test_wrong_native_id_fails_even_when_texture_name_matches(self):
  report=compare(_bindings({'face.overtex1':{'id':99}}),_frame(),_catalog(),
                 {'frame.json':'a','fixture-card.png':'b'})
  failed=[slot for slot in report['slots'] if not slot['passes']]
  self.assertEqual(len(failed),1)
  self.assertEqual(failed[0]['reason'],
                   'native binding id 99 differs from the captured catalog id 2')
  self.assertEqual(failed[0]['expectedTexture'],failed[0]['capturedTexture'])
  self.assertFalse(failed[0]['textureMatch'])
  self.assertFalse(report['passes'])
 def test_blush_compares_alpha_only(self):
  # The recorded blush RGB comes from the prefab material, so only alpha is gated.
  report=compare(_bindings(),_frame({'cf_m_face_00':{'_overcolor2':[0,0,0,0.1]}}),
                 _catalog(),{'frame.json':'a','fixture-card.png':'b'})
  blush=[slot for slot in report['slots'] if slot['category']=='prefab'][0]
  self.assertTrue(blush['passes'])
  report=compare(_bindings(),_frame({'cf_m_face_00':{'_overcolor2':[1,1,1,0.5]}}),
                 _catalog(),{'frame.json':'a','fixture-card.png':'b'})
  blush=[slot for slot in report['slots'] if slot['category']=='prefab'][0]
  self.assertFalse(blush['passes'])
 def test_missing_native_binding_reports_unmatched_slot(self):
  report=compare(_bindings({'body.overtex2':None}),_frame(),_catalog(),
                 {'frame.json':'a','fixture-card.png':'b'})
  self.assertFalse(report['passes'])
  self.assertEqual([slot['slot'] for slot in report['unmatchedSlots']],['overtex2'])
 def test_both_sides_unbound_slot_stays_out_of_gates(self):
  bindings={k:v for k,v in [('bindings',_bindings()['bindings'])]}
  bindings['bindings']=[b for b in bindings['bindings'] if b['category'] not in ('mt_underhair','mt_eye_hi_down')]
  frame=_frame()
  frame['meshes'][1]['materials'][0]['properties'].pop('_overcolor2')
  frame['meshes'][2]['materials'][0]['properties'].pop('_overcolor2')
  report=compare(bindings,frame,_catalog(),{'frame.json':'a','fixture-card.png':'b'})
  self.assertTrue(report['passes'])
  self.assertEqual([(slot['material'],slot['slot']) for slot in report['slots']],
                   [('face','overtex1'),('face','overtex2'),('face','overtex3'),
                    ('body','overtex1'),('eye','overtex1')])

if __name__=='__main__':
 unittest.main()
