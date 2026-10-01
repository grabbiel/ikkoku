#!/usr/bin/env python3
"""Check the CharaStudio reload capture against the edits our scenarios made to each scene.

Each ST-T03 acceptance scenario exported a probe-authored scene after a documented edit
series; the reload probe loaded exactly those records in the original CharaStudio player and
recorded the state it shows (Tools/reverse/fixtures/OriginalSceneReloadProbe.cs). Every claim
is evaluated on the after-load snapshot, with the loaded record's hash as provenance. Claims
whose expectation is None are pure observations: the original's behaviour (does the tree
cascade a hidden folder onto its child at load?) is recorded verbatim, not asserted.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
from dynamics_contract import REPO

KINDS={0:'character',1:'item',2:'light',3:'folder',4:'route',5:'camera'}
LABELS=('hide-rename','camera-switch','route-stop','route-rename')
# The ST-T01 pair: our FK-edit export beside the CharaStudio-authored source scene it edits.
FK_LABELS=('charastudio-fk-edit','charastudio-fk-source')
FK_BONE=19    # the bone scenario fk-edit rotates to [0,35,0] (the "fk-edit" bone)
HAND_BONE=21  # the left-hand guide whose world position must move when the arm bone is turned
DEGREES_TOLERANCE=1e-3
HAND_MOVE_MIN=0.001 # metres; a 35-degree arm FK edit moves the hand centimetres, so this only
                    # rejects "did not move at all", it is not a pose tolerance


def _objects(snapshot):
    return {obj['dicKey']:obj for obj in snapshot['objects']}


def _close_degrees(target,tolerance):
    def matches(actual):
        return(isinstance(actual,(list,tuple)) and len(actual)==3
               and all(isinstance(v,(int,float)) and abs(v-e)<=tolerance
                       for v,e in zip(actual,target)))
    matches.claim='%s degrees within %g'%(list(target),tolerance) # the report serializes callables as this text
    return matches


def _bone(snapshot,bone_id):
    """One recorded probe bone from a snapshot's character record, or None."""
    character=_fk_character(snapshot) if isinstance(snapshot,dict) else None
    for bone in (character or {}).get('bones') or []:
        if bone.get('boneID')==bone_id and bone.get('found'):return bone
    return None


def _fk_character(snapshot):
    """The one character's recorded FK bookkeeping, or None if the scene is not one character."""
    characters=[obj for obj in snapshot.get('objects') or [] if obj.get('kind')==0]
    if len(characters)!=1 or not isinstance(characters[0].get('character'),dict):return None
    return characters[0]['character']


def _fk_claims(label,snapshot,cases):
    character=_fk_character(snapshot)
    if character is None:
        return [(label+'/one-character-with-fk-state','exactly one character object carrying a "character" record',
                 dict(characterKeys=[obj['dicKey'] for obj in snapshot.get('objects') or [] if obj.get('kind')==0],
                      objectCount=snapshot.get('objectCount')))]
    # "afterLoad" carries the FK bookkeeping (it is the loaded record, live before any
    # frame runs); the world transforms are taken from "settled", the snapshot Frames
    # frames later, as the acceptance demands ("after a few frames").
    settled=cases.get(label,{}).get('settled') if isinstance(cases.get(label),dict) else None
    settled_character=_fk_character(settled) if isinstance(settled,dict) else None
    claims=[(label+'/fk-enabled',label=='charastudio-fk-edit',character['enableFK']),
            (label+'/active-fk-groups',None,character['activeFK'])]
    saved=_bone(snapshot,FK_BONE)
    if label=='charastudio-fk-edit':
        claims.append((label+'/bone19-saved-rotation',_close_degrees([0.0,35.0,0.0],DEGREES_TOLERANCE),
                       saved['savedRotation'] if saved else None))
        edited_hand=_bone(settled,HAND_BONE) if settled_character is not None else None
        baseline=cases.get('charastudio-fk-source')
        baseline_snapshot=baseline.get('settled') if isinstance(baseline,dict) else None
        baseline_hand=_bone(baseline_snapshot,HAND_BONE) if isinstance(baseline_snapshot,dict) else None
        claim=label+'/hand21-moved-relative-to-charastudio-fk-source'
        if edited_hand is None or baseline_hand is None or not all(
                isinstance(v,(int,float)) for v in edited_hand['worldPosition']+baseline_hand['worldPosition']):
            claims.append((claim,'the settled left-hand position of the edited scene further than %g m from the unedited load of the source scene'%HAND_MOVE_MIN,
                           dict(editedHand=edited_hand['worldPosition'] if edited_hand else None,
                                baselineHand=baseline_hand['worldPosition'] if baseline_hand else None)))
        else:
            claims.append((claim,_moved_at_least(HAND_MOVE_MIN),
                           dict(distance=math.dist(edited_hand['worldPosition'],baseline_hand['worldPosition']),
                                editedHand=edited_hand['worldPosition'],
                                baselineHand=baseline_hand['worldPosition'])))
        edited_bone=_bone(settled,FK_BONE) if settled_character is not None else None
        claims.append((label+'/bone19-world-rotation-after-frames',None,
                       edited_bone['worldRotation'] if edited_bone else None))
    else:
        claims.append((label+'/bone19-saved-rotation',None,saved['savedRotation'] if saved else None))
        hand=_bone(settled,HAND_BONE) if settled_character is not None else None
        claims.append((label+'/hand21-world-position',None,hand['worldPosition'] if hand else None))
    return claims


def _moved_at_least(minimum):
    def matches(actual):
        return isinstance(actual,dict) and isinstance(actual.get('distance'),(int,float)) and actual['distance']>minimum
    matches.claim='a distance greater than %g'%minimum
    return matches


def _claims(label,snapshot,cases=None):
    """(claim name, expectation, recorded value) per acceptance claim.

    The expectation is the state the scenario's edits must have written into the record, as
    the original player reads them back; None means "report what the player shows"."""
    if label in FK_LABELS:
        return _fk_claims(label,snapshot,cases or {})
    objects=_objects(snapshot)
    required={'hide-rename':{0:5,1:3,2:5},'camera-switch':{0:5,2:5},
              'route-stop':{0:4,3:4},'route-rename':{0:4,3:4}}[label]
    missing=sorted(key for key,kind in required.items() if key not in objects or objects[key]['kind']!=kind)
    if missing:
        return [(label+'/scene-objects','exactly the objects the scenario edited, with their recorded kinds',
                 dict(missingOrWrongKind=missing,objectCount=snapshot['objectCount']))]
    if label=='hide-rename':
        camera,folder,child=objects[0],objects[1],objects[2]
        return [
            ('hide-rename/camera-key0-name','IKKOKU-A2',camera['name']),
            ('hide-rename/folder-key1-name','IKKOKU-F2',folder['name']),
            ('hide-rename/folder-key1-hidden-object-info',False,folder['objectInfoVisible']),
            ('hide-rename/folder-key1-hidden-tree-node',False,folder['treeNodeVisible']),
            # What the player shows for the hidden folder's child camera. The scenario exported it
            # visible (the edits only touched the folder), so the flags CharaStudio records after
            # the load show whether the original tree cascades the parent's hidden state at load.
            ('hide-rename/child-camera-key2-visibility-after-load',None,
             dict(objectInfoVisible=child['objectInfoVisible'],treeNodeVisible=child['treeNodeVisible'],
                  exportedVisible=True,exportedTreeNodeVisible=True))]
    if label=='camera-switch':
        camera,other=objects[0],objects[2]
        return [
            ('camera-switch/view-camera-is-key0',0,snapshot['viewCameraKey']),
            ('camera-switch/camera-key0-active',True,camera['cameraActive']),
            ('camera-switch/camera-key2-inactive',False,other['cameraActive'])]
    if label=='route-rename':
        return [
            # The renamed route and the untouched one: the renamed name must
            # read back, the other must keep the name saved in the scene.
            ('route-rename/route-key3-name','IKKOKU-R3',objects[3]['name']),
            ('route-rename/route-key0-keeps-saved-name','IKKOKU-A',objects[0]['name'])]
    return [
        ('route-stop/route-key0-not-playing',False,objects[0]['routePlaying']),
        ('route-stop/route-key3-playing',True,objects[3]['routePlaying'])]


def _expected_labels(cases):
    """A trace carries one acceptance run's cases: the four ST-T03 reloads, or the ST-T01
    FK pair (our FK export plus the unedited load of its CharaStudio-authored source scene).
    Which run it is, we learn from the labels the probe actually recorded."""
    return FK_LABELS if any(label in cases for label in FK_LABELS) else LABELS


def compare(trace,scene_hashes=None):
    if trace.get('schemaVersion')!=1:
        raise ValueError('Unsupported reload trace schemaVersion: %r'%(trace.get('schemaVersion'),))
    cases=trace.get('cases')
    if not isinstance(cases,dict):
        raise ValueError('Reload trace has no cases object')
    scene_hashes=scene_hashes or {}
    reports={}
    for label in _expected_labels(cases):
        case=cases.get(label)
        if not isinstance(case,dict) or not isinstance(case.get('afterLoad'),dict):
            claims=[dict(claim=label+'/capture',expected='a reload case with an after-load snapshot',
                         actual='missing from the trace',passed=False)]
        else:
            claims=[]
            for name,expected,actual in _claims(label,case['afterLoad'],cases):
                if expected is None:passed=None  # observation: recorded, never asserted
                elif callable(expected):
                    try:passed=bool(actual is not None and expected(actual))
                    except(TypeError,ValueError):passed=False # a null coordinate is a failed claim, never a crash
                    expected=expected.claim # the report serializes the matcher as its claim text
                elif isinstance(actual,dict)or not isinstance(expected,(str,bool,int,float)) or isinstance(expected,bool)!=isinstance(actual,bool):
                    passed=False
                else:passed=actual==expected
                claims.append(dict(claim=name,expected=expected,actual=actual,passed=passed))
        reports[label]=dict(claims=claims,passed=all(c['passed'] is not False for c in claims),
                            sceneSHA256=scene_hashes.get(label),
                            afterLoad=case['afterLoad'] if isinstance(case,dict) else None,
                            settled=case.get('settled') if isinstance(case,dict) else None)
    return dict(schemaVersion=1,framesPerPhase=trace.get('framesPerPhase'),cases=reports,
                passed=all(c['passed'] for c in reports.values()),
                scope='Edits our scenarios applied to the probe-authored scenes versus the state the original '
                      'CharaStudio player records after Studio.LoadScene of our exported records; the hidden '
                      "folder's child is reported as the player records it, its view camera "
                      'is studio.ociCamera, routes are OCIRoute.isPlay immediately after the load; the '
                      'charastudio-fk pair checks the FK bookkeeping of our FK export against the unedited '
                      'load of its CharaStudio-authored source scene, with world transforms settled frames later')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe',type=Path,default=REPO/'.local/stt03e/probe')
    parser.add_argument('--output',type=Path,default=REPO/'.local/stt03e/scene-reload-comparison.json')
    arguments=parser.parse_args()
    if not arguments.output.resolve().is_relative_to((REPO/'.local').resolve()):
        raise ValueError('Original-derived reports stay in .local')
    trace_path=arguments.probe/'reload-trace.json'
    trace=json.loads(trace_path.read_text())
    scene_hashes={}
    for label in LABELS+FK_LABELS:
        path=arguments.probe/('reload-'+label+'.png') # the FK pair runs upload both records under these names
        if path.is_file():scene_hashes[label]=hashlib.sha256(path.read_bytes()).hexdigest()
    report=compare(trace,scene_hashes)
    evidence=[dict(path=str(p.resolve()),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
              for p in [trace_path,Path(__file__)]+[arguments.probe/('reload-%s.png'%l) for l in LABELS] if p.is_file()]
    report['evidence']=evidence
    arguments.output.parent.mkdir(parents=True,exist_ok=True)
    arguments.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({label:{'passed':case['passed'],
                             'failed':[c['claim'] for c in case['claims'] if c['passed'] is False],
                             'recorded':[c['claim'] for c in case['claims'] if c['passed'] is None]}
                      for label,case in report['cases'].items()},indent=2))


if __name__=='__main__':
    main()
