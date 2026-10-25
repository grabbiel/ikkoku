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


# ST-T03 topology: each of our deletion/reparenting/duplicate/insert exports beside the unedited load of its source.
TOPOLOGY_PAIRS=(('topology-delete','topology-delete-source'),('topology-moved','topology-delete-source'),
                ('topology-reparent','topology-reparent-source'),('topology-item-delete','topology-item-source'),
                ('topology-duplicate','topology-reparent-source'),('topology-camera-copy','topology-item-source'))
TOPOLOGY_LABELS=tuple(dict.fromkeys(label for pair in TOPOLOGY_PAIRS for label in pair))
# The tree each scenario left (Tools/verification/scenarios/topology-*.json and reload-*-topology.json),
# parent key (None = the root dictionary) -> children in order, and the camera it must look through.
TOPOLOGY_INTENT={
    'topology-delete':{None:[0]},
    'topology-moved':{None:[0,2]},
    'topology-reparent':{None:[622,962,626,1130,794,1540,1129],962:[963,1127,1128,623],626:[627,791,792,793,65],622:[0,624,625]},
    'topology-item-delete':{None:[0,1],0:[2],1:[]},
    # topology-duplicate.json: Duplicate folder 962 (its copy 113 holds copies of 963 and 1127-1129), item 1540
    # and item 1127 (whose copy 335 joins 962), then add a folder, a camera and a point light at the root.
    'topology-duplicate':{None:[622,65,962,626,1130,794,1298,1540,113,334,336,337,338],
                          962:[963,1127,1128,1129,335],113:[114,331,332,333]},
    # topology-insert-refused.json: Duplicate camera 2 inside item 0; the copy takes the view.
    'topology-camera-copy':{None:[0,1],0:[2,4],1:[3]},
}
TOPOLOGY_VIEW={'topology-delete':None,'topology-moved':2,'topology-reparent':None,'topology-item-delete':2,
               'topology-duplicate':None,'topology-camera-copy':4}
# Each copy's key -> the source record it copies, from the scenario's own GetNewIndex walk (the smallest free key,
# record first, then a character's FK and IK keys, its children, its look-at key; an item's bone keys, then its
# children), and the records the scenario added (AddObjectFolder, AddObjectCamera, AddObjectLight).
TOPOLOGY_COPIES={'topology-duplicate':{113:962,114:963,331:1127,332:1128,333:1129,334:1540,335:1127},
                 'topology-camera-copy':{4:2}}
TOPOLOGY_NEW={'topology-duplicate':(336,337,338)}
POSITION_TOLERANCE=1e-3 # metres: a wrong reparent rule (parent frame ignored or applied twice) is off by decimetres
ROTATION_TOLERANCE=0.1  # degrees
CHANGE_TOLERANCE=1e-5   # the loaded change amount against the float the record stores


def file_tree(data):
    """The record's own tree from the independent Python reader (analysis.studio_scene_contract):
    root order, every child list, every record's transform, and the camera CharaStudio's load order
    selects (ChangeCamera per record in depth-first order; the last active record wins)."""
    from analysis.studio_scene_contract import inspect_scene
    scene=inspect_scene(data)
    roots=[int(key) for key in scene['roots']];children={};groups={};records={};winner=[None];keys=[]
    def visit(obj):
        key=obj['key'];records[key]=obj
        # Every key the record names: its own, a character's FK, IK and look-at keys, an item's bone keys, and
        # a route's point and aid keys (each one SceneInfo.SetNewIndex registers at load).
        keys.append(key)
        keys.extend(bone['key'] for bone in list((obj.get('bones') or {}).values())+list((obj.get('ik') or {}).values()))
        if obj['kind']==0:keys.append(obj['lookAt']['key'])
        for point in obj.get('points') or []:keys.extend((point['bone']['key'],point['aid']['key']))
        if obj['kind']==5 and obj.get('active'):winner[0]=key
        if 'children' in obj:children[key]=[child['key'] for child in obj['children']]
        for child in obj.get('children',[]):visit(child)
        points=sorted((int(point),items) for point,items in (obj.get('accessories') or {}).items())
        if obj['kind']==0:groups[key]=[dict(point=point,keys=[item['key'] for item in items]) for point,items in points if items]
        for _,items in points:
            for item in items:visit(item)
    for key in scene['roots']:visit(scene['roots'][key])
    return dict(roots=roots,rootKeys=[int(key) for key in scene['roots']],children=children,groups=groups,records=records,
                viewCamera=winner[0],sunCaster=scene['settings']['sunCaster'],keys=sorted(keys))


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


def _pose_kept(edited,source,copies=None,new=()):
    """Every object of the edited load at its world pose in the unedited source load (settled); a copy at
    the pose of the record it copies, which Studio.Duplicate places beside it with the same local change
    amount. Records the edit added have no source pose and are checked against their own record instead."""
    worst=dict(distance=0.0,degrees=0.0,distanceKey=None,degreesKey=None,missing=[])
    before=_objects(source);copies=copies or {}
    for key,obj in _objects(edited).items():
        if key in new:continue
        base=before.get(copies.get(key,key))
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
                       _pose_kept(case.get('settled') or snapshot,source_case.get('settled') or source_case['afterLoad'],
                                  TOPOLOGY_COPIES.get(label),TOPOLOGY_NEW.get(label,()))))
    if 'indexKeys' in snapshot or label in TOPOLOGY_COPIES or label in TOPOLOGY_NEW:
        # Studio.SetNewIndex hands a key the index already holds a fresh one, so a repeated key in the record
        # shows as an index that is not the record's key list.
        claims.append((label+'/index-keys-match-record',_exact(json.dumps(expected['keys'])),json.dumps(snapshot.get('indexKeys'))))
    if label in TOPOLOGY_COPIES or label in TOPOLOGY_NEW:
        claims.extend(_insert_claims(label,case,source_case,expected,loaded))
    return claims


def _shown(obj):
    """What the player shows of one loaded object besides its placement."""
    return None if obj is None else dict(kind=obj.get('kind'),name=obj.get('name'),content=obj.get('content'))


def _unity_euler(degrees):
    """Quaternion.Euler(x, y, z) as [x, y, z, w]: Z first, then X, then Y (Unity's ZXY order)."""
    def axis(index,angle):
        half=math.radians(angle)/2;q=[0.0,0.0,0.0,math.cos(half)];q[index]=math.sin(half);return q
    def mul(a,b):
        ax,ay,az,aw=a;bx,by,bz,bw=b
        return [aw*bx+ax*bw+ay*bz-az*by,aw*by-ax*bz+ay*bw+az*bx,aw*bz+ax*by-ay*bx+az*bw,aw*bw-ax*bx-ay*by-az*bz]
    x,y,z=degrees
    return mul(mul(axis(1,y),axis(0,x)),axis(2,z))


def _copies_match(actual):
    if not actual:return False
    for entry in actual.values():
        copy,source=entry['copy'],entry['source']
        if copy is None or source is None or copy!=source:return False
        if copy['kind'] in (0,1,2) and not copy['content']:return False
        if copy['kind']==1 and (not copy['content'].get('loaded') or not (copy['content'].get('meshes') or {}).get('renderers')):return False
    return True
_copies_match.claim='every copy loaded with the kind, name and catalog content (item catalog IDs, a loaded prefab with renderers, its renderer and vertex counts; a character\'s card name, sex, renderer and vertex counts) of the record it copies in the source load'


def _insert_claims(label,case,source_case,expected,loaded):
    snapshot=case['afterLoad'];settled=_objects(case.get('settled') or snapshot);claims=[]
    if source_case is not None:
        before=_objects(source_case.get('settled') or source_case['afterLoad'])
        claims.append((label+'/copies-show-their-source-content',_copies_match,
                       {str(key):dict(copy=_shown(settled.get(key)),source=_shown(before.get(template)))
                        for key,template in sorted(TOPOLOGY_COPIES.get(label,{}).items())}))
    names={str(key):[record.get('name'),(loaded['objects'].get(key) or {}).get('name')]
           for key,record in sorted(expected['records'].items()) if record['kind'] in (3,4,5)}
    claims.append((label+'/names-match-record',_exact(json.dumps({k:[v[0],v[0]] for k,v in names.items()},ensure_ascii=False,sort_keys=True)),
                   json.dumps(names,ensure_ascii=False,sort_keys=True)))
    states={str(key):[record['treeState'],record['visible']] for key,record in sorted(expected['records'].items())}
    claims.append((label+'/tree-states-and-visibility-match-record',_exact(json.dumps(states,sort_keys=True)),
                   json.dumps({str(key):[(loaded['objects'].get(key) or {}).get('objectInfoTreeState'),(loaded['objects'].get(key) or {}).get('objectInfoVisible')]
                               for key in sorted(expected['records'])},sort_keys=True)))
    lights={}
    for key,record in sorted(expected['records'].items()):
        if record['kind']!=2:continue
        content=(loaded['objects'].get(key) or {}).get('content') or {}
        want=[record['number'],[_float32(v) for v in record['color']],_float32(record['intensity']),_float32(record['range']),
              _float32(record['spotAngle']),record['shadow'],record['enabled'],record['drawTarget']]
        got=[content.get('no'),[_float32(v) for v in content.get('color') or []],*(None if content.get(f) is None else _float32(content[f]) for f in ('intensity','range','spotAngle')),
             content.get('shadow'),content.get('enable'),content.get('drawTarget')]
        lights[str(key)]=dict(record=want,loaded=got,light=dict(type=content.get('lightType'),enabled=content.get('lightEnabled'),
                                                                 intensity=content.get('lightIntensity'),range=content.get('lightRange'),spotAngle=content.get('lightSpotAngle')))
    def lights_match(actual):return all(entry['record']==entry['loaded'] for entry in actual.values())
    lights_match.claim='every light loaded with its record\'s number, color, intensity, range, spot angle, shadow, enable and draw-target values'
    claims.append((label+'/light-values-match-record',lights_match,lights))
    placed=dict(distance=0.0,degrees=0.0,missing=[])
    for key in TOPOLOGY_NEW.get(label,()):
        obj=settled.get(key);record=expected['records'].get(key)
        if obj is None or record is None or obj.get('worldPosition') is None or obj.get('worldRotation') is None or key not in expected['roots']:
            placed['missing'].append(key);continue
        placed['distance']=max(placed['distance'],math.dist(obj['worldPosition'],record['transform']['position']))
        placed['degrees']=max(placed['degrees'],_degrees(obj['worldRotation'],_unity_euler(record['transform']['rotation'])))
    def placed_match(actual):return not actual['missing'] and actual['distance']<=POSITION_TOLERANCE and actual['degrees']<=ROTATION_TOLERANCE
    placed_match.claim='every added root record at its record\'s position within %g m and rotation within %g degrees'%(POSITION_TOLERANCE,ROTATION_TOLERANCE)
    if label in TOPOLOGY_NEW:claims.append((label+'/added-records-at-record-placement',placed_match,placed))
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
                scope='ST-T03 deletion, reparenting, duplicates and added records: the original CharaStudio player\'s loaded tree '
                      '(sceneInfo.dicObject order, every OI*Info child list), dicKeys, change amounts, view camera and sun caster '
                      'against each record\'s own bytes read by the independent Python reader and against the scenario\'s intended '
                      'tree; each export\'s settled world poses against the unedited load of its source scene, a copy against the '
                      'record it copies; for duplicate and insert exports also the loaded key index, names, tree states, light '
                      'values, added-record placement and each copy\'s loaded catalog content against its source record\'s load; '
                      'no rendered-image claim')


# ST-T11 route edits: our route-edit-export and route-children-edit exports, each traced after its load.
ROUTE_LABELS=('route-edit','route-children-edit')
# What the scenarios left (Tools/verification/scenarios/route-edit-export.json and route-children-edit.json):
# per route key its name, point and aid keys (an added point takes the smallest free key, point then aid; a
# duplicated route's points follow its children's keys), whether it plays after the load, and its children.
ROUTE_INTENT={
    'route-edit':{0:dict(name='IKKOKU-A',keys=[1,6,10,14,18],aidKeys=[2,7,11,15,19],playing=True,children=[]),
                  3:dict(name='IKKOKU-B2',keys=[4,8,12],aidKeys=[5,9,13],playing=False,children=[])},
    'route-children-edit':{0:dict(name='IKKOKU-RC',keys=[1,3,5,7],aidKeys=[2,4,6,8],playing=True,children=[9,10]),
                           157:dict(name='IKKOKU-RC',keys=[306,308,310,312],aidKeys=[307,309,311,313],playing=True,children=[158,159])}}
# The route point panel the app offers (SourceStudioRouteState.easeChoices, pointLimit, speedRange).
APP_ROUTE_UI=dict(easeOptions=6,routePointLimit=True,speedMin=0.1,speedMax=10.0)
ROUTE_SAMPLE_SECONDS=(0.5,1.0,1.5,2.0,3.0)
ROUTE_MOVED_MIN=0.05 # metres a playing route's childRoot must travel over the trace: rejects "never moved", not a pose tolerance


def _rotate(q,v):
    """Unity quaternion [x, y, z, w] applied to a vector."""
    x,y,z,w=q;vx,vy,vz=v
    tx,ty,tz=2*(y*vz-z*vy),2*(z*vx-x*vz),2*(x*vy-y*vx)
    return [vx+w*tx+(y*tz-z*ty),vy+w*ty+(z*tx-x*tz),vz+w*tz+(x*ty-y*tx)]


def _route_record_claims(label,key,record,loaded):
    """One route's loaded OIRouteInfo and point records against the record bytes (independent reader)."""
    name='%s/route-%d/'%(label,key);route=(loaded or {}).get('route') or {}
    want=[[p['bone']['key'],_float32(p['speed']),p['ease'],p['connection'],p['linked'],p['aid']['key'],p['initialized']] for p in record['points']]
    got=[[p.get('dicKey'),None if p.get('speed') is None else _float32(p['speed']),p.get('easeType'),p.get('connection'),p.get('link'),
          p.get('aidKey'),p.get('aidInitialized')] for p in route.get('points') or []]
    change=dict(difference=0.0,point=None,missing=[]);rows=route.get('points') or []
    for index,point in enumerate(record['points']):
        row=rows[index] if index<len(rows) else None
        if row is None:change['missing'].append(index);continue
        pairs=[(row.get('changePosition'),point['bone']['transform']['position']),(row.get('changeRotation'),point['bone']['transform']['rotation']),
               (row.get('changeScale'),point['bone']['transform']['scale']),(row.get('aidChangePosition'),point['aid']['transform']['position']),
               (row.get('aidChangeRotation'),point['aid']['transform']['rotation'])]
        if any(a is None for a,_ in pairs):change['missing'].append(index);continue
        difference=max(abs(_float32(a)-_float32(b)) for got_value,want_value in pairs for a,b in zip(got_value,want_value))
        if difference>change['difference']:change.update(difference=difference,point=index)
    color=record['color'];settings_want=[record['name'],record['active'],record['loop'],record['visibleLine'],record['orientation'],
                                          [_float32(color[c]) for c in 'rgba']]
    settings_got=[route.get('name'),route.get('active'),route.get('loop'),route.get('visibleLine'),route.get('orient'),
                  [_float32(v) for v in route.get('color') or []]]
    intent=ROUTE_INTENT.get(label,{}).get(key)
    claims=[(name+'points-match-record',_exact(json.dumps(want)),json.dumps(got)),
            (name+'point-change-amounts-match-record',_within('difference',CHANGE_TOLERANCE),change),
            (name+'settings-match-record',_exact(json.dumps(settings_want,ensure_ascii=False)),json.dumps(settings_got,ensure_ascii=False)),
            # OCIRoute.UpdateLine builds the line for two or more points and shows it as visibleLine says (OnVisible, SetVisible).
            (name+'line-shown-as-visible-line',_exact(json.dumps([True,record['visibleLine']])),json.dumps([route.get('lineExists'),route.get('lineActive')])),
            (name+'line-points',None,route.get('linePoints'))]
    if intent is not None:
        actual=dict(name=(loaded or {}).get('name'),keys=[p.get('dicKey') for p in route.get('points') or []],
                    aidKeys=[p.get('aidKey') for p in route.get('points') or []],playing=(loaded or {}).get('routePlaying'),
                    children=(loaded or {}).get('childKeys'))
        claims.append((name+'scenario-route',_exact(json.dumps(intent,sort_keys=True)),json.dumps(actual,sort_keys=True)))
    return claims


def _route_trace_claims(label,case,tree,payload):
    """The original's per-frame childRoot and route-children placement after the load against our stepper
    (`ikkoku-inspect route-steps` over the trace's own deltaTimes, compare_route_playback.compare_stepped's
    pairing: row 0's delta is the load frame's and only seeds LookUpdate, capture row k is stepped frame k)."""
    from compare_route_playback import angle_degrees,unity_from_euler_zxy
    trace=case.get('routeTrace') or [];claims=[]
    if len(trace)<2 or payload is None:
        return [(label+'/route-trace','a route trace of at least two frames and a stepped run',dict(frames=len(trace),stepped=payload is not None))]
    deltas=[row['deltaTime'] for row in trace];since=[0.0]
    for delta in deltas[1:]:since.append(since[-1]+delta)
    stepped={route['sourceKey']:route for route in payload.get('routes') or []}
    for key in sorted(k for k,r in tree['records'].items() if r['kind']==4):
        name='%s/route-%d/'%(label,key);run=stepped.get(key);record=tree['records'][key]
        frames=(run or {}).get('frames') or []
        if run is None or len(frames)!=len(deltas)-1:
            claims.append((name+'stepped-frames',_exact(len(deltas)-1),len(frames)));continue
        scale=record['transform']['scale']
        if key not in tree['roots'] or max(scale)-min(scale)>1e-6:
            claims.append((name+'root-route-with-uniform-scale',_exact(True),False));continue
        root=dict(distance=0.0,degrees=0.0,frame=None,activeMismatch=0,missing=[]);children=dict(distance=0.0,frame=None,child=None,missing=[])
        start=None;travel=0.0;samples=[]
        for index,cell in enumerate(frames):
            row=next((r for r in trace[index]['routes'] if r['dicKey']==key),None)
            if row is None:root['missing'].append(index);continue
            if start is None:start=row['position']
            travel=max(travel,math.dist(row['position'],start))
            rotation=unity_from_euler_zxy(cell['childRootWorldRotationEulerZXY'])
            distance=math.dist(row['position'],cell['childRootWorldPosition']);degrees=angle_degrees(row['rotation'],rotation)
            if distance>root['distance']:root.update(distance=distance,frame=index)
            root['degrees']=max(root['degrees'],degrees)
            if cell['active']!=row['active']:root['activeMismatch']+=1
            for child in row['children']:
                local=(tree['records'].get(child['dicKey']) or {}).get('transform')
                if local is None or child.get('position') is None:children['missing'].append(child['dicKey']);continue
                offset=_rotate(rotation,[component*scale[0] for component in local['position']])
                world=[a+b for a,b in zip(cell['childRootWorldPosition'],offset)]
                distance=math.dist(child['position'],world)
                if distance>children['distance']:children.update(distance=distance,frame=index,child=child['dicKey'])
        for seconds in ROUTE_SAMPLE_SECONDS:
            index=min(range(len(frames)),key=lambda i:abs(since[i]-seconds))
            if abs(since[index]-seconds)>0.05:continue # the trace ended before this time
            row=next((r for r in trace[index]['routes'] if r['dicKey']==key),None)
            if row is not None:samples.append(dict(seconds=round(since[index],4),original=row['position'],stepped=frames[index]['childRootWorldPosition'],
                                                  children={str(c['dicKey']):c['position'] for c in row['children']}))
        def placed(actual):return not actual['missing'] and actual['distance']<=POSITION_TOLERANCE and actual['degrees']<=ROTATION_TOLERANCE and actual['activeMismatch']==0
        placed.claim='every traced frame\'s childRoot within %g m and %g degrees of the stepped frame, with the same active flag'%(POSITION_TOLERANCE,ROTATION_TOLERANCE)
        claims.append((name+'childroot-matches-stepper',placed,root))
        def followed(actual):return not actual['missing'] and actual['distance']<=POSITION_TOLERANCE
        followed.claim='every route child within %g m of the stepped childRoot placement composed with its record\'s local position'%POSITION_TOLERANCE
        if record.get('children'):claims.append((name+'children-follow-stepper',followed,children))
        playing=bool(record['active'])
        def moved(actual,playing=playing):return actual>=ROUTE_MOVED_MIN if playing else actual<=POSITION_TOLERANCE
        moved.claim=('childRoot travels at least %g m over the trace (the route plays)'%ROUTE_MOVED_MIN if playing
                     else 'childRoot stays within %g m of point 0 (the route is stopped)'%POSITION_TOLERANCE)
        claims.append((name+'childroot-travel',moved,travel))
        claims.append((name+'samples',None,samples))
    claims.append((label+'/trace-seconds',None,dict(frames=len(trace),seconds=round(since[-1],4))))
    return claims


def compare_route_edit(trace,trees,steps,scene_hashes=None):
    """Each route-edit export's loaded routes against its record's own bytes and the scenario's intent, the
    traced playback against `steps(label, deltas, play_delta)` (our stepper over the trace's deltaTimes), and
    the route point panel's prefab values against the panel the app offers."""
    if trace.get('schemaVersion')!=1:raise ValueError('Unsupported reload trace schemaVersion')
    cases=trace.get('cases') or {};reports={}
    for label in ROUTE_LABELS:
        if label not in trees:continue
        case=cases.get(label)
        if not isinstance(case,dict) or not isinstance(case.get('afterLoad'),dict):
            claims=[dict(claim=label+'/capture',expected='a reload case with an after-load snapshot',actual='missing from the trace',passed=False)]
        else:
            tree=trees[label];snapshot=case['afterLoad'];objects=_objects(snapshot);raw=[]
            raw.append((label+'/index-keys-match-record',_exact(json.dumps(tree['keys'])),json.dumps(snapshot.get('indexKeys'))))
            raw.append((label+'/change-amounts-match-record',_within('difference',CHANGE_TOLERANCE),_change_amounts(loaded_tree(snapshot),tree)))
            for key in sorted(k for k,r in tree['records'].items() if r['kind']==4):
                raw.extend(_route_record_claims(label,key,tree['records'][key],objects.get(key)))
            missing=sorted(set(ROUTE_INTENT.get(label,{}))-{k for k,r in tree['records'].items() if r['kind']==4})
            raw.append((label+'/scenario-routes-present',_exact('[]'),json.dumps(missing)))
            deltas=[row['deltaTime'] for row in case.get('routeTrace') or []]
            payload=steps(label,deltas[1:],deltas[0]) if len(deltas)>=2 else None
            raw.extend(_route_trace_claims(label,case,tree,payload))
            ui=case.get('routeUi') or {}
            raw.append((label+'/route-point-panel-matches-app',_exact(json.dumps(APP_ROUTE_UI,sort_keys=True)),
                        json.dumps({field:ui.get(field) for field in APP_ROUTE_UI},sort_keys=True)))
            raw.append((label+'/route-point-panel',None,ui))
            claims=[]
            for name,expected,actual in raw:
                if expected is None:passed=None
                elif isinstance(expected,str):passed=False # a diagnostic row: the expectation text itself
                else:
                    try:passed=bool(expected(actual))
                    except(TypeError,ValueError,KeyError):passed=False
                    expected=expected.claim
                claims.append(dict(claim=name,expected=expected,actual=actual,passed=passed))
        reports[label]=dict(claims=claims,passed=all(c['passed'] is not False for c in claims),sceneSHA256=(scene_hashes or {}).get(label))
    return dict(schemaVersion=1,cases=reports,passed=bool(reports) and all(c['passed'] for c in reports.values()),
                tolerances=dict(positionMetres=POSITION_TOLERANCE,rotationDegrees=ROTATION_TOLERANCE,changeAmount=CHANGE_TOLERANCE),
                scope='ST-T11 route edits: the original CharaStudio player\'s loaded routes (every OIRoutePointInfo key, change amount, '
                      'speed, ease, connection, link, aid key, aid change amount and aid flag; the route\'s name, active, loop, '
                      'visibleLine, orientation and color; the line UpdateLine built) against each record\'s own bytes read by the '
                      'independent Python reader and against the scenario\'s intended keys, play states and children; the key index; '
                      'every traced frame\'s childRoot placement and active flag against ikkoku-inspect route-steps over the trace\'s '
                      'own deltaTimes, and each route child\'s world position against that stepped childRoot composed with the '
                      'child\'s record placement; the route point panel\'s ease list, point limit option and speed slider range '
                      'against the app\'s; no rendered-image claim')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe',type=Path,default=REPO/'.local/stt03e/probe')
    parser.add_argument('--output',type=Path,default=REPO/'.local/stt03e/scene-reload-comparison.json')
    parser.add_argument('--cli',type=Path,default=REPO/'Packages/Engine/.build/debug/ikkoku-inspect',
                        help='ikkoku-inspect for the route-edit labels\' route-steps runs')
    arguments=parser.parse_args()
    if not arguments.output.resolve().is_relative_to((REPO/'.local').resolve()):
        raise ValueError('Original-derived reports stay in .local')
    trace_path=arguments.probe/'reload-trace.json'
    trace=json.loads(trace_path.read_text())
    scene_hashes={}
    for label in LABELS+FK_LABELS+EXPRESSION_LABELS+TOPOLOGY_LABELS+ROUTE_LABELS:
        path=arguments.probe/('reload-'+label+'.png') # the FK pair runs upload both records under these names
        if path.is_file():scene_hashes[label]=hashlib.sha256(path.read_bytes()).hexdigest()
    if any(label in trace.get('cases',{}) for label in ROUTE_LABELS):
        import subprocess
        trees={label:file_tree((arguments.probe/('reload-'+label+'.png')).read_bytes()) for label in ROUTE_LABELS
               if (arguments.probe/('reload-'+label+'.png')).is_file()}
        def steps(label,deltas,play_delta):
            path=arguments.output.parent/('route-steps-deltas-'+label+'.json')
            if not path.resolve().is_relative_to((REPO/'.local').resolve()):raise ValueError('Original-derived reports stay in .local')
            path.write_text(json.dumps(list(deltas))+'\n')
            result=subprocess.run([str(arguments.cli),'route-steps',str(arguments.probe/('reload-'+label+'.png')),str(path),'%.9g'%play_delta],
                                  capture_output=True,text=True)
            if result.returncode:raise RuntimeError(result.stderr.strip() or result.stdout.strip())
            return json.loads(result.stdout)
        arguments.output.parent.mkdir(parents=True,exist_ok=True)
        report=compare_route_edit(trace,trees,steps,scene_hashes)
    elif any(label in trace.get('cases',{}) for label in TOPOLOGY_LABELS):
        trees={label:file_tree((arguments.probe/('reload-'+label+'.png')).read_bytes()) for label in TOPOLOGY_LABELS
               if (arguments.probe/('reload-'+label+'.png')).is_file()}
        report=compare_topology(trace,trees,scene_hashes)
    elif any(label in trace.get('cases',{}) for label in EXPRESSION_LABELS):
        expected={label:expression_expectations((arguments.probe/('reload-'+label+'.png')).read_bytes()) for label in EXPRESSION_LABELS}
        report=compare_expression(trace,expected,scene_hashes)
    else:report=compare(trace,scene_hashes)
    evidence=[dict(path=str(p.resolve()),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
              for p in [trace_path,Path(__file__)]+[arguments.probe/('reload-%s.png'%l) for l in LABELS+FK_LABELS+EXPRESSION_LABELS+TOPOLOGY_LABELS+ROUTE_LABELS] if p.is_file()]
    report['evidence']=evidence
    arguments.output.parent.mkdir(parents=True,exist_ok=True)
    arguments.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({label:{'passed':case['passed'],
                             'failed':[c['claim'] for c in case['claims'] if c['passed'] is False],
                             'recorded':[c['claim'] for c in case['claims'] if c['passed'] is None]}
                      for label,case in report['cases'].items()},indent=2))


if __name__=='__main__':
    main()
