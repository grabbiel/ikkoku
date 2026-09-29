"""Camera-object rule and transform math checks; no VM, capture or private data required."""
import copy, json, math, unittest
from pathlib import Path
import compare_camera_objects as cmp

HERE=Path(__file__).parent
REFERENCE=HERE/'fixtures'/'camera-object-reference.json'
FIXTURE=HERE/'fixtures'/'OriginalCameraObjectProbe.cs'
H=math.sqrt(0.5)

def close(test,a,b,tol=1e-6):
    for x,y in zip(a,b):test.assertAlmostEqual(x,y,delta=tol)

class TransformMathTests(unittest.TestCase):
    def test_single_axis_euler_matches_unity(self):
        close(self,cmp.euler([0,90,0]),[0,H,0,H]);close(self,cmp.euler([90,0,0]),[H,0,0,H]);close(self,cmp.euler([0,0,90]),[0,0,H,H])

    def test_euler_applies_z_then_x_then_y(self):
        # Rotating +Y by Euler(90,0,90): z first sends +Y to -X, x leaves -X, y by 0 -> (-1,0,0).
        close(self,cmp.rotate(cmp.euler([90,0,90]),[0,1,0]),[-1,0,0])
        close(self,cmp.euler([10,70,25]),[0.193374,0.542397,0.127817,0.807512],1e-5) # Unity's Quaternion.Euler(10,70,25)

    def test_compose_scales_the_local_offset_before_rotating_it(self):
        parent=dict(position=[1,0,0],rotation=cmp.euler([0,90,0]),scale=[2,2,2])
        world=cmp.compose(parent,[0,0,1],[0,0,0])
        close(self,world['position'],[3,0,0]);close(self,world['rotation'],cmp.euler([0,90,0]))

    def test_rotation_ignores_parent_scale(self):
        a=dict(position=[0,0,0],rotation=cmp.euler([0,40,15]),scale=[1,2,0.5])
        b=dict(a,scale=[1,1,1])
        self.assertLess(cmp.angle(cmp.compose(a,[0.3,0.6,-0.9],[10,70,25])['rotation'],cmp.compose(b,[0.3,0.6,-0.9],[10,70,25])['rotation']),1e-9)

    def test_angle_is_sign_insensitive(self):
        q=cmp.euler([10,70,25]);self.assertLess(cmp.angle(q,[-x for x in q]),1e-6);self.assertAlmostEqual(cmp.angle([0,0,0,1],[0,H,0,H]),90,places=6)

class LoadRuleTests(unittest.TestCase):
    X=[dict(kind=5,dicKey=0,name='A',active=True,parent=None),dict(kind=3,dicKey=1,name='F',active=None,parent=None),dict(kind=5,dicKey=2,name='B',active=True,parent='F')]
    Y=[X[1],X[2],X[0]]

    def test_last_active_record_in_depth_first_order_wins(self):
        self.assertEqual((cmp.active_by_rule(self.X),cmp.active_by_rule(self.Y)),('B','A'))

    def test_the_two_orders_separate_every_alternative_rule(self):
        for rule in cmp.ALTERNATIVE_RULES:
            with self.subTest(rule=rule):
                self.assertNotEqual((cmp.active_by_rule(self.X,rule),cmp.active_by_rule(self.Y,rule)),('B','A'))

    def test_no_active_record_leaves_no_camera(self):
        self.assertIsNone(cmp.active_by_rule([dict(r,active=False) if r['kind']==5 else r for r in self.X]))

class ReferenceTests(unittest.TestCase):
    def setUp(self):self.reference=json.loads(REFERENCE.read_text())

    def test_committed_reference_satisfies_the_rule(self):
        report=cmp.check_reference(self.reference)
        self.assertEqual(report.failures,[])
        self.assertLess(report.maxima['cameraFromTransformsPosition'],cmp.POSITION_TOLERANCE)

    def test_reference_covers_every_case_and_holds_no_catalog_identity(self):
        self.assertEqual([c['name'] for c in self.reference['objectCases']],['root','root-moved','folder','item-uniform','item-nonuniform'])
        self.assertEqual([c['name'] for c in self.reference['loadCases']],['x','y','none'])
        self.assertNotIn('catalog',REFERENCE.read_text())

    def test_folder_scale_is_not_applied_but_item_scale_is(self):
        cases={c['name']:c for c in self.reference['objectCases']}
        self.assertEqual(cases['folder']['parent']['authoredScale'],[2,2,2]);close(self,cases['folder']['parent']['world']['scale'],[1,1,1])
        close(self,cases['item-nonuniform']['parent']['world']['scale'],[1,2,0.5])

    def test_a_moved_camera_or_wrong_load_winner_is_detected(self):
        moved=copy.deepcopy(self.reference);moved['objectCases'][0]['camera']['position'][0]+=0.01
        self.assertTrue(cmp.check_reference(moved).failures)
        wrong=copy.deepcopy(self.reference);wrong['loadCases'][0]['activeAfterLoad']='IKKOKU-A'
        self.assertTrue(any('rule predicts' in f for f in cmp.check_reference(wrong).failures))

    def test_reference_rounding_is_stable(self):
        self.assertEqual(cmp.r6({'a':[-0.0,1.23456789]}),{'a':[0.0,1.234568]})
        self.assertEqual(str(cmp.r6(-0.0)),'0.0')

    def test_load_folder_constants_match_the_probe_source(self):
        source=FIXTURE.read_text()
        self.assertIn('f.objectInfo.changeAmount.pos=new Vector3(-0.5f,0.2f,0.5f);f.objectInfo.changeAmount.rot=new Vector3(0f,-30f,10f)',source)

class CaptureCheckTests(unittest.TestCase):
    def snap(self,position,rotation,active,enabled,icon,fov=23.0,name='IKKOKU-root'):
        main=dict(position=position,rotation=rotation,lossyScale=[1,1,1])
        return dict(frame=1,cameraCtrlEnabled=enabled,activeCamera=name if active else None,main=main,fov=fov,
            object=dict(name=name,position=position,rotation=rotation,meshRendererEnabled=icon))

    def case(self):
        world=cmp.compose(cmp.IDENTITY,[1,2,3],[10,70,25]);home=([0,2.09,4.21],[0,0.995056,-0.09932,0])
        before=self.snap(*home,False,True,True);before.pop('object')
        return dict(authoredLocalPosition=[1,2,3],authoredLocalRotation=[10,70,25],before=before,placed=self.snap(*home,False,True,True),
            activateSelected=True,cameraCtrlEnabledAfterActivate=False,active=[self.snap(world['position'],world['rotation'],True,False,False)]*2,
            deactivateCleared=True,restored=[self.snap(*home,False,True,True)]*2)

    def test_consistent_object_case_passes(self):
        report=cmp.Report();cmp.check_object_case(report,'root',self.case());self.assertEqual(report.failures,[])

    def test_enabled_camera_control_or_visible_icon_while_active_fails(self):
        case=self.case();case['active']=[dict(s,cameraCtrlEnabled=True) for s in case['active']]
        case['active'][0]['object']=dict(case['active'][0]['object'],meshRendererEnabled=True)
        report=cmp.Report();cmp.check_object_case(report,'root',case)
        self.assertTrue(any('cameraCtrl stays enabled' in f for f in report.failures));self.assertTrue(any('icon renderer' in f for f in report.failures))

    def test_camera_not_returning_to_the_saved_view_fails(self):
        case=self.case();case['restored']=[self.snap([0,2.2,4.21],[0,0.995056,-0.09932,0],False,True,True)]
        report=cmp.Report();cmp.check_object_case(report,'root',case)
        self.assertTrue(any('restoredPosition' in f for f in report.failures))

if __name__=='__main__':unittest.main()
