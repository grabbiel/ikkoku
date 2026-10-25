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
import struct
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


EXPRESSION_LABELS=('expression-edit','expression-source')

def expression_expectations(data):
    """Independent Python scene/card reader, not the native writer or probe values."""
    from analysis.scene_editing_oracle import collect,objects
    from analysis.studio_scene_contract import inspect_scene
    from analysis.card_contract import parse_card
    import msgpack
    cards=collect(data);expected={}
    fields={'eyebrowPattern':('eyebrowPtn',0),'eyesPattern':('eyesPtn',0),'mouthPattern':('mouthPtn',0),
            'eyesOpen':('eyesOpenMax',1.0),'blink':('eyesBlink',True),'eyesLookPattern':('eyesLookPtn',0),
            'neckLookPattern':('neckLookPtn',0),'tears':('tearsLv',0),'cheek':('hohoAkaRate',0.0)}
    for key,obj in objects(inspect_scene(data)['roots']).items():
        if 'card' not in obj:continue
        card=parse_card(cards[obj['card']['sha256']])
        status=msgpack.unpackb(next(b['raw'] for b in card.blocks if b['name']=='Status'),raw=False,strict_map_key=False)
        expected[key]={name:status.get(member,default) for name,(member,default) in fields.items()}
        expected[key].update(mouthOpen=obj['mouthOpen'],lipSync=obj['lipSync'])
    if not expected:raise ValueError('Expression acceptance requires character records')
    return expected


def compare_expression(trace,expected,scene_hashes=None):
    """Every serialized face field of every character, immediately and after settling."""
    if trace.get('schemaVersion')!=1:raise ValueError('Unsupported reload trace schemaVersion')
    reports={}
    for label in EXPRESSION_LABELS:
        claims=[];case=trace.get('cases',{}).get(label,{})
        for phase in ('afterLoad','settled'):
            actual=_objects(case.get(phase,{})) if isinstance(case.get(phase),dict) and 'objects' in case[phase] else {}
            for key,fields in expected[label].items():
                values=(actual.get(key,{}).get('character') or {}).get('expression') or {}
                for field,wanted in fields.items():
                    value=values.get(field)
                    if isinstance(wanted,bool):passed=isinstance(value,bool) and value==wanted
                    else:passed=isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) and abs(value-wanted)<=1e-6
                    claims.append(dict(claim='%s/%s/character%d/%s'%(label,phase,key,field),expected=wanted,actual=value,passed=passed))
        reports[label]=dict(claims=claims,passed=bool(claims) and all(c['passed'] for c in claims),sceneSHA256=(scene_hashes or {}).get(label))
    return dict(schemaVersion=1,cases=reports,passed=all(c['passed'] for c in reports.values()),
                scope='All serialized face fields of all characters from independent Python scene/card decoding versus original CharaStudio afterLoad and settled snapshots; no rendered-image or transition parity claim')


# ST-T03 topology: each of our deletion/reparenting exports beside the unedited load of its source.
TOPOLOGY_PAIRS=(('topology-delete','topology-delete-source'),('topology-moved','topology-delete-source'),
                ('topology-reparent','topology-reparent-source'),('topology-item-delete','topology-item-source'))
TOPOLOGY_LABELS=tuple(dict.fromkeys(label for pair in TOPOLOGY_PAIRS for label in pair))
# The tree each scenario left (Tools/verification/scenarios/topology-*.json and reload-*-topology.json),
# parent key (None = the root dictionary) -> children in order, and the camera it must look through.
TOPOLOGY_INTENT={
    'topology-delete':{None:[0]},
    'topology-moved':{None:[0,2]},
    'topology-reparent':{None:[622,962,626,1130,794,1540,1129],962:[963,1127,1128,623],626:[627,791,792,793,65],622:[0,624,625]},
    'topology-item-delete':{None:[0,1],0:[2],1:[]},
}
TOPOLOGY_VIEW={'topology-delete':None,'topology-moved':2,'topology-reparent':None,'topology-item-delete':2}
POSITION_TOLERANCE=1e-3 # metres: a wrong reparent rule (parent frame ignored or applied twice) is off by decimetres
ROTATION_TOLERANCE=0.1  # degrees
CHANGE_TOLERANCE=1e-5   # the loaded change amount against the float the record stores


def file_tree(data):
    """The record's own tree from the independent Python reader (analysis.studio_scene_contract):
    root order, every child list, every record's transform, and the camera CharaStudio's load order
    selects (ChangeCamera per record in depth-first order; the last active record wins)."""
    from analysis.studio_scene_contract import inspect_scene
    scene=inspect_scene(data)
    roots=[int(key) for key in scene['roots']];children={};groups={};records={};winner=[None]
    def visit(obj):
        key=obj['key'];records[key]=obj
        if obj['kind']==5 and obj.get('active'):winner[0]=key
        if 'children' in obj:children[key]=[child['key'] for child in obj['children']]
        for child in obj.get('children',[]):visit(child)
        points=sorted((int(point),items) for point,items in (obj.get('accessories') or {}).items())
        if obj['kind']==0:groups[key]=[dict(point=point,keys=[item['key'] for item in items]) for point,items in points if items]
        for _,items in points:
            for item in items:visit(item)
    for key in scene['roots']:visit(scene['roots'][key])
    return dict(roots=roots,rootKeys=[int(key) for key in scene['roots']],children=children,groups=groups,records=records,
                viewCamera=winner[0],sunCaster=scene['settings']['sunCaster'])


def loaded_tree(snapshot):
    """The same tree as the original player holds it after Studio.LoadScene."""
    objects=_objects(snapshot);children={};groups={}
    for key,obj in objects.items():
        keys=obj.get('childKeys')
        if obj.get('kind')==0:groups[key]=[dict(point=g['point'],keys=list(g['keys'])) for g in keys or []]
        elif isinstance(keys,list):children[key]=list(keys)
    return dict(roots=[entry['dicKey'] for entry in snapshot.get('rootKeys') or []],
                rootKeys=[entry['key'] for entry in snapshot.get('rootKeys') or []],children=children,groups=groups,objects=objects)


def _degrees(a,b):
    """Angle between two unit quaternions [x,y,z,w], from atan2 of the difference rotation."""
    ax,ay,az,aw=a;bx,by,bz,bw=b
    w=aw*bw+ax*bx+ay*by+az*bz
    x=aw*bx-ax*bw-ay*bz+az*by;y=aw*by+ax*bz-ay*bw-az*bx;z=aw*bz-ax*by+ay*bx-az*bw
    return math.degrees(2*math.atan2(math.sqrt(x*x+y*y+z*z),abs(w)))


def _pose_kept(edited,source):
    """Every object of the edited load at its world pose in the unedited source load (settled)."""
    worst=dict(distance=0.0,degrees=0.0,distanceKey=None,degreesKey=None,missing=[])
    before=_objects(source)
    for key,obj in _objects(edited).items():
        base=before.get(key)
        if base is None or obj.get('worldPosition') is None or base.get('worldPosition') is None or obj.get('worldRotation') is None:
            worst['missing'].append(key);continue
        distance=math.dist(obj['worldPosition'],base['worldPosition']);degrees=_degrees(obj['worldRotation'],base['worldRotation'])
        if distance>worst['distance']:worst.update(distance=distance,distanceKey=key)
        if degrees>worst['degrees']:worst.update(degrees=degrees,degreesKey=key)
    return worst


def _pose_matcher():
    def matches(actual):
        return not actual['missing'] and actual['distance']<=POSITION_TOLERANCE and actual['degrees']<=ROTATION_TOLERANCE
    matches.claim='every object within %g m and %g degrees of its world pose in the source load'%(POSITION_TOLERANCE,ROTATION_TOLERANCE)
    return matches


def _float32(value):return struct.unpack('<f',struct.pack('<f',value))[0]


def _change_amounts(loaded,expected):
    worst=dict(difference=0.0,key=None,missing=[])
    for key,record in expected['records'].items():
        obj=loaded['objects'].get(key)
        if obj is None or obj.get('changePosition') is None:worst['missing'].append(key);continue
        transform=record['transform']
        for field,name in (('changePosition','position'),('changeRotation','rotation'),('changeScale','scale')):
            # Both sides are float32 (the probe prints the player's floats with "R", the shortest round-trip
            # text, so 345.6512 is float32 345.65121459...): compare them at that precision.
            difference=max(abs(_float32(a)-_float32(b)) for a,b in zip(obj[field],transform[name]))
            if difference>worst['difference']:worst.update(difference=difference,key=key)
    return worst


def _topology_claims(label,case,source_case,expected,source_expected):
    snapshot=case['afterLoad'];loaded=loaded_tree(snapshot)
    tree_claims=[
        (label+'/object-count',len(expected['records']),snapshot.get('objectCount')),
        (label+'/keys-kept-from-record',sorted(expected['records']),sorted(loaded['objects'])),
        (label+'/root-dictionary-order-matches-record',expected['roots'],loaded['roots']),
        (label+'/root-dictionary-keys-are-dickeys',loaded['roots'],loaded['rootKeys']),
        (label+'/child-lists-match-record',json.dumps(expected['children'],sort_keys=True),json.dumps({k:loaded['children'].get(k) for k in expected['children']},sort_keys=True)),
        (label+'/accessory-groups-match-record',json.dumps(expected['groups'],sort_keys=True),json.dumps({k:loaded['groups'].get(k) for k in expected['groups']},sort_keys=True)),
        (label+'/view-camera-follows-record-load-order',expected['viewCamera'],snapshot.get('viewCameraKey')),
        (label+'/sun-caster-matches-record',expected['sunCaster'],snapshot.get('sunCaster'))]
    claims=[(name,_exact(want),got) for name,want,got in tree_claims]
    change=_change_amounts(loaded,expected)
    claims.append((label+'/change-amounts-match-record',_within('difference',CHANGE_TOLERANCE),change))
    claims.append((label+'/camera-active-flags',None,{str(k):o.get('cameraActive') for k,o in loaded['objects'].items() if o.get('kind')==5}))
    if label in TOPOLOGY_INTENT:
        intent=TOPOLOGY_INTENT[label]
        actual={str(parent):(loaded['roots'] if parent is None else loaded['children'].get(parent)) for parent in intent}
        claims.append((label+'/scenario-tree',_exact(json.dumps({str(k):v for k,v in intent.items()},sort_keys=True)),json.dumps(actual,sort_keys=True)))
        claims.append((label+'/scenario-view-camera',_exact(TOPOLOGY_VIEW[label]),snapshot.get('viewCameraKey')))
    if source_case is not None and source_expected is not None:
        deleted=sorted(set(source_expected['records'])-set(expected['records']))
        gone=sorted(set(_objects(source_case['afterLoad']))-set(loaded['objects']))
        claims.append((label+'/deleted-records-absent',_exact(json.dumps(deleted)),json.dumps(gone)))
        claims.append((label+'/world-pose-kept-from-source',_pose_matcher(),
                       _pose_kept(case.get('settled') or snapshot,source_case.get('settled') or source_case['afterLoad'])))
    return claims


def _exact(value):
    def matches(actual):return actual==value
    matches.claim=value if isinstance(value,str) else json.dumps(value)
    return matches


def _within(field,tolerance):
    def matches(actual):return not actual['missing'] and actual[field]<=tolerance
    matches.claim='%s at most %g with no missing record'%(field,tolerance)
    return matches


def compare_topology(trace,trees,scene_hashes=None):
    """Each topology export and source load against its record's own tree (`trees`: label ->
    file_tree of the uploaded record), the scenario's intended tree, and, for an export, the world
    poses of the unedited source load."""
    if trace.get('schemaVersion')!=1:raise ValueError('Unsupported reload trace schemaVersion')
    cases=trace.get('cases') or {};reports={}
    sources=dict(TOPOLOGY_PAIRS)
    for label in TOPOLOGY_LABELS:
        if label not in trees:continue
        case=cases.get(label)
        if not isinstance(case,dict) or not isinstance(case.get('afterLoad'),dict):
            claims=[dict(claim=label+'/capture',expected='a reload case with an after-load snapshot',actual='missing from the trace',passed=False)]
        else:
            source=sources.get(label);source_case=cases.get(source) if source else None
            claims=[]
            for name,expected,actual in _topology_claims(label,case,source_case if isinstance(source_case,dict) else None,
                                                          trees[label],trees.get(source)):
                if expected is None:passed=None
                else:
                    try:passed=bool(expected(actual))
                    except(TypeError,ValueError,KeyError):passed=False
                    expected=expected.claim
                claims.append(dict(claim=name,expected=expected,actual=actual,passed=passed))
            if source and (source not in cases or source not in trees):
                claims.append(dict(claim=label+'/source-load',expected='the unedited load of '+source,actual='missing from the trace',passed=False))
        reports[label]=dict(claims=claims,passed=all(c['passed'] is not False for c in claims),sceneSHA256=(scene_hashes or {}).get(label))
    return dict(schemaVersion=1,framesPerPhase=trace.get('framesPerPhase'),cases=reports,passed=bool(reports) and all(c['passed'] for c in reports.values()),
                scope='ST-T03 deletion and reparenting: the original CharaStudio player\'s loaded tree (sceneInfo.dicObject order, '
                      'every OI*Info child list), dicKeys, change amounts, view camera and sun caster against each record\'s own bytes '
                      'read by the independent Python reader and against the scenario\'s intended tree; each export\'s settled world '
                      'poses against the unedited load of its source scene; no rendered-image claim')


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
    for label in LABELS+FK_LABELS+EXPRESSION_LABELS+TOPOLOGY_LABELS:
        path=arguments.probe/('reload-'+label+'.png') # the FK pair runs upload both records under these names
        if path.is_file():scene_hashes[label]=hashlib.sha256(path.read_bytes()).hexdigest()
    if any(label in trace.get('cases',{}) for label in TOPOLOGY_LABELS):
        trees={label:file_tree((arguments.probe/('reload-'+label+'.png')).read_bytes()) for label in TOPOLOGY_LABELS
               if (arguments.probe/('reload-'+label+'.png')).is_file()}
        report=compare_topology(trace,trees,scene_hashes)
    elif any(label in trace.get('cases',{}) for label in EXPRESSION_LABELS):
        expected={label:expression_expectations((arguments.probe/('reload-'+label+'.png')).read_bytes()) for label in EXPRESSION_LABELS}
        report=compare_expression(trace,expected,scene_hashes)
    else:report=compare(trace,scene_hashes)
    evidence=[dict(path=str(p.resolve()),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
              for p in [trace_path,Path(__file__)]+[arguments.probe/('reload-%s.png'%l) for l in LABELS+FK_LABELS+EXPRESSION_LABELS+TOPOLOGY_LABELS] if p.is_file()]
    report['evidence']=evidence
    arguments.output.parent.mkdir(parents=True,exist_ok=True)
    arguments.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({label:{'passed':case['passed'],
                             'failed':[c['claim'] for c in case['claims'] if c['passed'] is False],
                             'recorded':[c['claim'] for c in case['claims'] if c['passed'] is None]}
                      for label,case in report['cases'].items()},indent=2))


if __name__=='__main__':
    main()
