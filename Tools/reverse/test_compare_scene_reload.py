"""Synthetic CharaStudio reload records exercise the acceptance comparison; no VM data is read."""
import unittest
from compare_scene_reload import compare


def obj(key,kind,**over):
    row=dict(dicKey=key,kind=kind,name='O%d'%key,objectInfoVisible=True,objectInfoTreeState=0,
             treeNodeVisible=True,treeNodeTreeState=0,cameraActive=None,viewCamera=None,routePlaying=None)
    row.update(over);return row


def case(label,objects,viewCameraKey=None,viewCameraName=None):
    after=dict(objectCount=len(objects),viewCameraKey=viewCameraKey,viewCameraName=viewCameraName,
               cameraCtrlEnabled=True,objects=objects)
    return dict(label=label,scene='reload-'+label+'.png',afterLoad=after,settled=after)


def passing_trace():
    return dict(schemaVersion=1,framesPerPhase=4,cases={
        'hide-rename':case('hide-rename',[
            obj(0,5,name='IKKOKU-A2',cameraActive=False),
            obj(1,3,name='IKKOKU-F2',objectInfoVisible=False,treeNodeVisible=False),
            obj(2,5,name='IKKOKU-B',cameraActive=True)],viewCameraKey=2,viewCameraName='IKKOKU-B'),
        'camera-switch':case('camera-switch',[
            obj(0,5,name='IKKOKU-A',cameraActive=True),
            obj(1,3,name='IKKOKU-F'),
            obj(2,5,name='IKKOKU-B',cameraActive=False)],viewCameraKey=0,viewCameraName='IKKOKU-A'),
        'route-stop':case('route-stop',[
            obj(0,4,name='IKKOKU-A',routePlaying=False),
            obj(3,4,name='IKKOKU-B',routePlaying=True)])})


def snapshot(report,label):
    return report['cases'][label]


class CompareTests(unittest.TestCase):
    def test_a_record_where_every_edit_survives_the_reload_passes(self):
        report=compare(passing_trace(),{'hide-rename':'h1','camera-switch':'h2','route-stop':'h3'})
        self.assertTrue(report['passed'])
        for label,count in (('hide-rename',5),('camera-switch',3),('route-stop',2)):
            case=snapshot(report,label)
            self.assertTrue(case['passed'],label)
            self.assertEqual(len(case['claims']),count)
            self.assertNotIn(label,[c['claim'] for c in case['claims'] if c['passed'] is False])
        self.assertEqual(snapshot(report,'hide-rename')['sceneSHA256'],'h1')

    def test_the_hidden_folder_child_visibility_is_recorded_not_asserted(self):
        for child in (dict(objectInfoVisible=False,treeNodeVisible=False),   # original cascades at load
                      dict(objectInfoVisible=True,treeNodeVisible=True)):    # original keeps the own flag
            trace=passing_trace()
            for key,value in child.items():
                trace['cases']['hide-rename']['afterLoad']['objects'][2][key]=value
            report=compare(trace)
            self.assertTrue(report['passed'])
            claim=[c for c in snapshot(report,'hide-rename')['claims']
                   if c['claim'].endswith('child-camera-key2-visibility-after-load')][0]
            self.assertIsNone(claim['passed'])
            self.assertEqual(claim['actual']['objectInfoVisible'],child['objectInfoVisible'])

    def test_a_name_the_player_did_not_read_back_fails_only_its_case(self):
        trace=passing_trace()
        trace['cases']['hide-rename']['afterLoad']['objects'][0]['name']='IKKOKU-A'
        report=compare(trace)
        self.assertFalse(report['passed'])
        self.assertFalse(snapshot(report,'hide-rename')['passed'])
        self.assertIn('hide-rename/camera-key0-name',[c['claim'] for c in snapshot(report,'hide-rename')['claims'] if c['passed'] is False])
        self.assertTrue(snapshot(report,'camera-switch')['passed'])

    def test_a_folder_the_player_still_shows_visible_fails(self):
        for path,claim in (((('objectInfoVisible',True)),'hide-rename/folder-key1-hidden-object-info'),
                           ((('treeNodeVisible',True)),'hide-rename/folder-key1-hidden-tree-node')):
            trace=passing_trace()
            trace['cases']['hide-rename']['afterLoad']['objects'][1][path[0]]=path[1]
            report=compare(trace)
            self.assertIn(claim,[c['claim'] for c in snapshot(report,'hide-rename')['claims'] if c['passed'] is False])

    def test_the_view_winner_must_be_the_toggled_camera(self):
        for key in (2,None): # the saved winner, or the orbit view, instead of our toggled key 0
            trace=passing_trace()
            trace['cases']['camera-switch']['afterLoad']['viewCameraKey']=key
            report=compare(trace)
            self.assertIn('camera-switch/view-camera-is-key0',[c['claim'] for c in snapshot(report,'camera-switch')['claims'] if c['passed'] is False])

    def test_the_stopped_route_must_come_back_stopped(self):
        trace=passing_trace()
        trace['cases']['route-stop']['afterLoad']['objects'][0]['routePlaying']=True
        report=compare(trace)
        self.assertIn('route-stop/route-key0-not-playing',[c['claim'] for c in snapshot(report,'route-stop')['claims'] if c['passed'] is False])
        trace=passing_trace()
        trace['cases']['route-stop']['afterLoad']['objects'][1]['routePlaying']=False
        report=compare(trace)
        self.assertIn('route-stop/route-key3-playing',[c['claim'] for c in snapshot(report,'route-stop')['claims'] if c['passed'] is False])

    def test_a_missing_object_reports_the_diagnostic_instead_of_raising(self):
        trace=passing_trace()
        trace['cases']['hide-rename']['afterLoad']['objects']=[o for o in trace['cases']['hide-rename']['afterLoad']['objects'] if o['dicKey']!=2]
        report=compare(trace)
        claims=snapshot(report,'hide-rename')['claims']
        self.assertEqual(len(claims),1)
        self.assertFalse(claims[0]['passed'])
        self.assertEqual(claims[0]['actual']['missingOrWrongKind'],[2])
        self.assertTrue(snapshot(report,'route-stop')['passed'])

    def test_a_case_missing_from_the_trace_fails_its_claim(self):
        trace=passing_trace();del trace['cases']['camera-switch']
        report=compare(trace)
        self.assertFalse(report['passed'])
        self.assertFalse(snapshot(report,'camera-switch')['claims'][0]['passed'])
        self.assertTrue(snapshot(report,'hide-rename')['passed'])

    def test_an_unsupported_schema_is_refused(self):
        for version in (None,2):
            trace=passing_trace()
            if version is None:del trace['schemaVersion']
            else:trace['schemaVersion']=version
            with self.assertRaisesRegex(ValueError,'schemaVersion'):compare(trace)


if __name__=='__main__':unittest.main()
