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
from pathlib import Path
from dynamics_contract import REPO

KINDS={0:'character',1:'item',2:'light',3:'folder',4:'route',5:'camera'}
LABELS=('hide-rename','camera-switch','route-stop')


def _objects(snapshot):
    return {obj['dicKey']:obj for obj in snapshot['objects']}


def _claims(label,snapshot):
    """(claim name, expectation, recorded value) per acceptance claim.

    The expectation is the state the scenario's edits must have written into the record, as
    the original player reads them back; None means "report what the player shows"."""
    objects=_objects(snapshot)
    required={'hide-rename':{0:5,1:3,2:5},'camera-switch':{0:5,2:5},'route-stop':{0:4,3:4}}[label]
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
    return [
        ('route-stop/route-key0-not-playing',False,objects[0]['routePlaying']),
        ('route-stop/route-key3-playing',True,objects[3]['routePlaying'])]


def compare(trace,scene_hashes=None):
    if trace.get('schemaVersion')!=1:
        raise ValueError('Unsupported reload trace schemaVersion: %r'%(trace.get('schemaVersion'),))
    cases=trace.get('cases')
    if not isinstance(cases,dict):
        raise ValueError('Reload trace has no cases object')
    scene_hashes=scene_hashes or {}
    reports={}
    for label in LABELS:
        case=cases.get(label)
        if not isinstance(case,dict) or not isinstance(case.get('afterLoad'),dict):
            claims=[dict(claim=label+'/capture',expected='a reload case with an after-load snapshot',
                         actual='missing from the trace',passed=False)]
        else:
            claims=[]
            for name,expected,actual in _claims(label,case['afterLoad']):
                if expected is None:passed=None  # observation: recorded, never asserted
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
                      'is studio.ociCamera, routes are OCIRoute.isPlay immediately after the load')


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
    for label in LABELS:
        path=arguments.probe/('reload-'+label+'.png')
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
