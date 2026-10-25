"""Synthetic CharaStudio reload records exercise the acceptance comparison; no VM data is read."""
import math, unittest
from compare_scene_reload import compare, compare_expression, compare_topology, file_tree


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
            obj(3,4,name='IKKOKU-B',routePlaying=True)]),
        'route-rename':case('route-rename',[
            obj(0,4,name='IKKOKU-A',routePlaying=True),
            obj(3,4,name='IKKOKU-R3',routePlaying=True)])})


def snapshot(report,label):
    return report['cases'][label]


def fk_char(enable_fk,saved_rot,hand,groups=None):
    return dict(dicKey=0,enableFK=enable_fk,enableIK=False,
                activeFK=groups or [False,True,False,True,False,False,False],
                bones=[dict(boneID=19,found=True,group=8,savedRotation=saved_rot,
                            worldPosition=[0.1,1.3,-0.2],worldRotation=[0.0,0.3,0.0,0.95]),
                       dict(boneID=21,found=True,group=64,savedRotation=[0.0,0.0,0.0],
                            worldPosition=hand,worldRotation=[0.0,0.0,0.0,1.0])])


def fk_case(label,character,hand=None):
    """One ST-T01 trace case: a single character object whose "character" record is the probe's FK snapshot."""
    snapshot=dict(objectCount=1,viewCameraKey=None,viewCameraName=None,cameraCtrlEnabled=True,
                  objects=[obj(0,0,name='IKKOKU-F',character=character)])
    return dict(label=label,scene='reload-'+label+'.png',afterLoad=snapshot,settled=snapshot)


def passing_fk_trace():
    edited=fk_char(True,[0.0,35.0,0.0],[0.32,1.18,-0.05])   # the FK edit turned the arm away from the default pose
    source=fk_char(False,[0.0,0.0,0.0],[0.18,1.20,-0.05])   # the unedited load of the CharaStudio-authored scene
    return dict(schemaVersion=1,framesPerPhase=4,cases={
        'charastudio-fk-edit':fk_case('charastudio-fk-edit',edited),
        'charastudio-fk-source':fk_case('charastudio-fk-source',source)})


class FkEditCompareTests(unittest.TestCase):
    def test_a_record_where_the_fk_edit_survives_the_reload_passes(self):
        report=compare(passing_fk_trace(),{'charastudio-fk-edit':'e1','charastudio-fk-source':'s1'})
        self.assertTrue(report['passed'])
        for label,count,recorded in (('charastudio-fk-edit',5,2),('charastudio-fk-source',4,3)):
            case=snapshot(report,label)
            self.assertTrue(case['passed'],label)
            self.assertEqual(len(case['claims']),count)
            self.assertEqual(len([c for c in case['claims'] if c['passed'] is None]),recorded)
        self.assertEqual(snapshot(report,'charastudio-fk-edit')['sceneSHA256'],'e1')
        # the moved-hand claim carries the distance and both hands as evidence
        moved=[c for c in snapshot(report,'charastudio-fk-edit')['claims']
               if c['claim']=='charastudio-fk-edit/hand21-moved-relative-to-charastudio-fk-source'][0]
        self.assertTrue(moved['passed'])
        self.assertAlmostEqual(moved['actual']['distance'],math.sqrt(0.02),places=9)

    def test_fk_disabled_on_load_fails_only_the_edit_case(self):
        trace=passing_fk_trace()
        trace['cases']['charastudio-fk-edit']['afterLoad']['objects'][0]['character']['enableFK']=False
        report=compare(trace)
        self.assertFalse(report['passed'])
        self.assertIn('charastudio-fk-edit/fk-enabled',
                      [c['claim'] for c in snapshot(report,'charastudio-fk-edit')['claims'] if c['passed'] is False])
        self.assertTrue(snapshot(report,'charastudio-fk-source')['passed'])

    def test_a_saved_rotation_outside_one_thousandth_of_a_degree_fails(self):
        for rot in ([0.0,35.002,0.0],[0.0,0.0,0.0],None):  # drifted, never written, not recorded at all
            trace=passing_fk_trace()
            trace['cases']['charastudio-fk-edit']['afterLoad']['objects'][0]['character']['bones'][0]['savedRotation']=rot
            report=compare(trace)
            claim=[c for c in snapshot(report,'charastudio-fk-edit')['claims']
                   if c['claim']=='charastudio-fk-edit/bone19-saved-rotation'][0]
            self.assertIs(claim['passed'],False,rot)
        # one thousandth of a degree is still within the acceptance
        trace=passing_fk_trace()
        trace['cases']['charastudio-fk-edit']['afterLoad']['objects'][0]['character']['bones'][0]['savedRotation']=[0.0,35.001,0.0]
        self.assertTrue(compare(trace)['passed'])

    def test_a_hand_the_edit_did_not_move_fails(self):
        trace=passing_fk_trace()
        hand=trace['cases']['charastudio-fk-source']['afterLoad']['objects'][0]['character']['bones'][1]['worldPosition']
        trace['cases']['charastudio-fk-edit']['afterLoad']['objects'][0]['character']['bones'][1]['worldPosition']=list(hand)
        report=compare(trace)
        self.assertIn('charastudio-fk-edit/hand21-moved-relative-to-charastudio-fk-source',
                      [c['claim'] for c in snapshot(report,'charastudio-fk-edit')['claims'] if c['passed'] is False])

    def test_a_missing_or_empty_baseline_fails_the_moved_claim_with_evidence_not_a_crash(self):
        for baseline in (None,[None,None,None]):
            trace=passing_fk_trace()
            if baseline is None:del trace['cases']['charastudio-fk-source']
            else:trace['cases']['charastudio-fk-source']['afterLoad']['objects'][0]['character']['bones'][1]['worldPosition']=baseline
            report=compare(trace)
            claim=[c for c in snapshot(report,'charastudio-fk-edit')['claims']
                   if c['claim'].endswith('hand21-moved-relative-to-charastudio-fk-source')][0]
            self.assertIs(claim['passed'],False)
            self.assertIn('editedHand',claim['actual'])

    def test_the_unedited_load_reports_its_fk_state_without_asserting_it(self):
        for trace in (passing_fk_trace(),):
            report=compare(trace)
            recorded=[c['claim'] for c in snapshot(report,'charastudio-fk-source')['claims'] if c['passed'] is None]
            self.assertEqual(recorded,['charastudio-fk-source/active-fk-groups',
                                       'charastudio-fk-source/bone19-saved-rotation',
                                       'charastudio-fk-source/hand21-world-position'])
            self.assertTrue(snapshot(report,'charastudio-fk-source')['passed'])

    def test_a_scene_that_is_not_one_character_reports_the_diagnostic(self):
        trace=passing_fk_trace()
        trace['cases']['charastudio-fk-edit']['afterLoad']['objects'][0].pop('character')
        report=compare(trace)
        self.assertFalse(report['passed'])
        claim=snapshot(report,'charastudio-fk-edit')['claims'][0]
        self.assertEqual(claim['claim'],'charastudio-fk-edit/one-character-with-fk-state')
        self.assertIs(claim['passed'],False)
        self.assertTrue(snapshot(report,'charastudio-fk-source')['passed'])

    def test_a_world_rotation_recorded_after_the_frames_is_kept_as_evidence(self):
        report=compare(passing_fk_trace())
        claim=[c for c in snapshot(report,'charastudio-fk-edit')['claims']
               if c['claim']=='charastudio-fk-edit/bone19-world-rotation-after-frames'][0]
        self.assertIsNone(claim['passed'])
        self.assertEqual(claim['actual'],[0.0,0.3,0.0,0.95])


class CompareTests(unittest.TestCase):
    def test_a_record_where_every_edit_survives_the_reload_passes(self):
        report=compare(passing_trace(),{'hide-rename':'h1','camera-switch':'h2','route-stop':'h3'})
        self.assertTrue(report['passed'])
        for label,count in (('hide-rename',5),('camera-switch',3),('route-stop',2),('route-rename',2)):
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

    def test_the_renamed_route_must_read_back_and_the_other_keep_its_saved_name(self):
        trace=passing_trace()
        trace['cases']['route-rename']['afterLoad']['objects'][1]['name']='IKKOKU-B'  # the rename was not read back
        report=compare(trace)
        self.assertFalse(report['passed'])
        self.assertIn('route-rename/route-key3-name',[c['claim'] for c in snapshot(report,'route-rename')['claims'] if c['passed'] is False])
        trace=passing_trace()
        trace['cases']['route-rename']['afterLoad']['objects'][0]['name']='IKKOKU-R3'  # the untouched route shows the other name
        report=compare(trace)
        self.assertIn('route-rename/route-key0-keeps-saved-name',[c['claim'] for c in snapshot(report,'route-rename')['claims'] if c['passed'] is False])
        self.assertTrue(snapshot(report,'route-stop')['passed'])

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


class ExpressionTests(unittest.TestCase):
    def inputs(self):
        labels=('expression-edit','expression-source')
        state=dict(eyebrowPattern=3,eyesPattern=2,mouthPattern=6,eyesOpen=.5,blink=True,
                   mouthOpen=.75,lipSync=False,eyesLookPattern=4,neckLookPattern=0,tears=2,cheek=.5)
        expected={label:{65:dict(state)} for label in labels}
        trace=dict(schemaVersion=1,cases={label:case(label,[obj(65,0,character={'expression':dict(state)})]) for label in labels})
        return trace,expected

    def test_every_field_matches_at_load_and_settled(self):
        trace,expected=self.inputs();report=compare_expression(trace,expected)
        self.assertTrue(report['passed'])
        self.assertEqual(sum(len(c['claims']) for c in report['cases'].values()),44)

    def test_wrong_missing_and_nonfinite_fields_fail(self):
        for value in (None,True,float('nan'),.25):
            trace,expected=self.inputs()
            trace['cases']['expression-edit']['settled']['objects'][0]['character']['expression']['mouthOpen']=value
            self.assertFalse(compare_expression(trace,expected)['passed'])
        trace,expected=self.inputs();del trace['cases']['expression-source']
        self.assertFalse(compare_expression(trace,expected)['passed'])


def topo_tree(roots,children,kinds,view=None,sun=-1):
    """A file_tree as the independent reader returns it, for synthetic records."""
    transform=lambda key:dict(position=[key*0.1,0.0,0.0],rotation=[0.0,key*1.0,0.0],scale=[1.0,1.0,1.0])
    return dict(roots=list(roots),rootKeys=list(roots),children={k:list(v) for k,v in children.items()},groups={},
                records={key:dict(kind=kind,transform=transform(key)) for key,kind in kinds.items()},viewCamera=view,sunCaster=sun)


def topo_case(label,tree,world,view=None):
    """The probe's snapshot of a load that holds exactly `tree`, with `world` key -> (position, quaternion)."""
    objects=[]
    for key,record in tree['records'].items():
        t=record['transform'];position,rotation=world[key]
        objects.append(obj(key,record['kind'],childKeys=tree['children'].get(key),worldPosition=position,worldRotation=rotation,
                           changePosition=t['position'],changeRotation=t['rotation'],changeScale=t['scale'],
                           cameraActive=(key==view) if record['kind']==5 else None))
    after=dict(objectCount=len(objects),viewCameraKey=view,viewCameraName=None,cameraCtrlEnabled=True,objects=objects,
               rootKeys=[dict(key=k,dicKey=k) for k in tree['roots']],sunCaster=tree['sunCaster'])
    return dict(label=label,scene='reload-'+label+'.png',afterLoad=after,settled=after)


class TopologyTests(unittest.TestCase):
    """scene-x: camera 0 and folder 1 holding camera 2 (the load winner); the delete export drops
    folder 1 with camera 2 and clears camera 0's flag, so nothing is looked through."""
    def inputs(self):
        q=[0.0,0.0,0.0,1.0]
        world={0:([1.0,2.0,3.0],q),1:([-0.5,0.2,0.5],q),2:([0.1,0.8,0.0],[0.0,0.38268343,0.0,0.92387953])}
        source=topo_tree([0,1],{1:[2]},{0:5,1:3,2:5},view=2)
        edited=topo_tree([0],{},{0:5})
        trace=dict(schemaVersion=1,framesPerPhase=4,cases={
            'topology-delete':topo_case('topology-delete',edited,world),
            'topology-delete-source':topo_case('topology-delete-source',source,world,view=2)})
        return trace,{'topology-delete':edited,'topology-delete-source':source}

    def test_matching_load_passes_every_claim(self):
        trace,trees=self.inputs();report=compare_topology(trace,trees)
        self.assertTrue(report['passed'],[c for case in report['cases'].values() for c in case['claims'] if c['passed'] is False])
        claims={c['claim']:c for c in report['cases']['topology-delete']['claims']}
        self.assertEqual(claims['topology-delete/deleted-records-absent']['actual'],'[1, 2]')
        self.assertTrue(claims['topology-delete/world-pose-kept-from-source']['passed'])
        self.assertTrue(claims['topology-delete/scenario-view-camera']['passed'])

    def test_wrong_tree_pose_camera_or_missing_source_fail(self):
        def failed(mutate):
            trace,trees=self.inputs();mutate(trace,trees)
            report=compare_topology(trace,trees)
            return sorted(c['claim'] for case in report['cases'].values() for c in case['claims'] if c['passed'] is False)
        def leftover(trace,trees): # the deleted folder survived the load
            after=trace['cases']['topology-delete']['afterLoad']
            after['objects'].append(obj(1,3,childKeys=[],worldPosition=[-0.5,0.2,0.5],worldRotation=[0,0,0,1],
                                        changePosition=[0.1,0,0],changeRotation=[0,1,0],changeScale=[1,1,1]))
            after['rootKeys'].append(dict(key=1,dicKey=1));after['objectCount']=2
        self.assertIn('topology-delete/deleted-records-absent',failed(leftover))
        self.assertIn('topology-delete/root-dictionary-order-matches-record',failed(leftover))
        def moved(trace,trees): # the kept camera reloads 1 cm away
            trace['cases']['topology-delete']['afterLoad']['objects'][0]['worldPosition']=[1.01,2.0,3.0]
        self.assertEqual(failed(moved),['topology-delete/world-pose-kept-from-source'])
        def turned(trace,trees):
            trace['cases']['topology-delete']['afterLoad']['objects'][0]['worldRotation']=[0.0,0.0087265,0.0,0.99996192]
        self.assertEqual(failed(turned),['topology-delete/world-pose-kept-from-source'])
        def looked(trace,trees): # camera 0's stale active flag selected it at load
            trace['cases']['topology-delete']['afterLoad']['viewCameraKey']=0
        self.assertEqual(failed(looked),['topology-delete/scenario-view-camera','topology-delete/view-camera-follows-record-load-order'])
        def renumbered(trace,trees):
            trace['cases']['topology-delete']['afterLoad']['rootKeys']=[dict(key=0,dicKey=5)]
        self.assertIn('topology-delete/root-dictionary-keys-are-dickeys',failed(renumbered))
        def printed(trace,trees): # the probe's shortest round-trip text of a float32 is that float32 exactly
            trees['topology-delete']['records'][0]['transform']['rotation']=[0.0,345.65121459960938,0.0]
            trace['cases']['topology-delete']['afterLoad']['objects'][0]['changeRotation']=[0.0,345.6512,0.0]
        self.assertEqual(failed(printed),[])
        def rotated(trace,trees): # one float32 step (3.05e-5 at 345 degrees) further is a different value
            trees['topology-delete']['records'][0]['transform']['rotation']=[0.0,345.65121459960938,0.0]
            trace['cases']['topology-delete']['afterLoad']['objects'][0]['changeRotation']=[0.0,345.6513,0.0]
        self.assertEqual(failed(rotated),['topology-delete/change-amounts-match-record'])
        def unsourced(trace,trees):del trace['cases']['topology-delete-source']
        self.assertIn('topology-delete/source-load',failed(unsourced))

    def test_file_tree_reads_the_record_with_the_independent_reader(self):
        from analysis.studio_scene_contract import scene_fixture
        raw,_=scene_fixture();tree=file_tree(raw)
        self.assertEqual(tree['roots'],[10,20])
        self.assertEqual(tree['groups'][10],[dict(point=7,keys=[11])])
        self.assertEqual(tree['children'][20],[21])
        self.assertEqual(sorted(tree['records']),[10,11,20,21])
        self.assertIsNone(tree['viewCamera'])
