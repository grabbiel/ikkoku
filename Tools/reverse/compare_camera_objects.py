#!/usr/bin/env python3
"""Recompute Studio camera-object render poses from object transforms and check them.

Rule under test (OCICamera.SetActive, Studio.ChangeCamera, Studio.LoadScene): while a camera object
is active, cameraCtrl is disabled and every LateUpdate copies the object's world position and
rotation onto the render camera (Camera.main); scale is not copied and the FOV stays cameraCtrl's.
Toggling it off re-enables cameraCtrl, which restores the saved view. On scene load the last camera
record in depth-first file order whose active flag is set becomes the active camera.

  compare_camera_objects.py CAPTURE_DIR [--write-reference PATH]   check a private capture
  compare_camera_objects.py --reference PATH                        re-check the committed reference
"""
from __future__ import annotations
import argparse, json, math, sys
from pathlib import Path

POSITION_TOLERANCE=1e-4 # metres; float32 capture against float64 recomputation
ROTATION_TOLERANCE=0.01 # degrees
FOV_TOLERANCE=1e-4
OBJECT_CASES=['root','folder','item-uniform','item-nonuniform']
LOAD_CASES=['x','y','none']
# Authored transform of folder IKKOKU-F in the load cases (mirrors OriginalCameraObjectProbe.LoadCase).
LOAD_FOLDER=dict(position=[-0.5,0.2,0.5],rotation=[0.0,-30.0,10.0])
IDENTITY=dict(position=[0.0,0.0,0.0],rotation=[0.0,0.0,0.0,1.0],scale=[1.0,1.0,1.0])

# --- Unity transform math (quaternions are x, y, z, w) ---
def qmul(a,b):
    ax,ay,az,aw=a;bx,by,bz,bw=b
    return [aw*bx+ax*bw+ay*bz-az*by,aw*by-ax*bz+ay*bw+az*bx,aw*bz+ax*by-ay*bx+az*bw,aw*bw-ax*bx-ay*by-az*bz]

def euler(e):
    """Quaternion.Euler: z, then x, then y rotation (q = qy * qx * qz), angles in degrees."""
    def axis(i,deg):
        h=math.radians(deg)/2;q=[0.0,0.0,0.0,math.cos(h)];q[i]=math.sin(h);return q
    return qmul(qmul(axis(1,e[1]),axis(0,e[0])),axis(2,e[2]))

def rotate(q,v):
    p=qmul(qmul(q,[v[0],v[1],v[2],0.0]),[-q[0],-q[1],-q[2],q[3]]);return p[:3]

def angle(a,b):
    """Angle in degrees between two rotations, insensitive to quaternion sign."""
    na=math.sqrt(sum(x*x for x in a));nb=math.sqrt(sum(x*x for x in b))
    d=abs(sum(x*y for x,y in zip(a,b)))/(na*nb)
    return math.degrees(2*math.acos(min(1.0,d)))

def distance(a,b):return math.sqrt(sum((x-y)**2 for x,y in zip(a,b)))

def compose(parent,local_position,local_euler):
    """World pose of a child whose local position/Euler rotation sit under parent's world TRS."""
    scaled=[s*v for s,v in zip(parent['scale'],local_position)]
    offset=rotate(parent['rotation'],scaled)
    return dict(position=[p+o for p,o in zip(parent['position'],offset)],rotation=qmul(parent['rotation'],euler(local_euler)))

# --- load rule ---
def active_by_rule(records,rule='last-active'):
    """Which camera record a load leaves active, for the source rule and the alternatives it must beat."""
    cams=[r for r in records if r.get('kind',5)==5 and r.get('active')]
    if not cams:return None
    if rule=='last-active':return cams[-1]['name']
    if rule=='first-active':return cams[0]['name']
    if rule=='root-first':
        roots=[r for r in cams if r.get('parent') is None];return (roots or cams)[0]['name']
    if rule=='lowest-key':return min(cams,key=lambda r:r['dicKey'])['name']
    if rule=='highest-key':return max(cams,key=lambda r:r['dicKey'])['name']
    raise ValueError(rule)

ALTERNATIVE_RULES=['first-active','root-first','lowest-key','highest-key']

# --- capture checks ---
class Report:
    def __init__(self):self.maxima={};self.failures=[];self.cases={}
    def deviation(self,kind,value,tolerance,where):
        self.maxima[kind]=max(self.maxima.get(kind,0.0),value)
        if value>tolerance:self.failures.append(f'{where}: {kind} {value:.3g} exceeds {tolerance:g}')
    def expect(self,condition,where,message):
        if not condition:self.failures.append(f'{where}: {message}')

def pose(snapshot_pose):return dict(position=snapshot_pose['position'],rotation=snapshot_pose['rotation'])

def parent_frame(case):
    state=case.get('parentState')
    if state is None:return IDENTITY
    root=state['childRoot'];return dict(position=root['position'],rotation=root['rotation'],scale=root['lossyScale'])

def check_active_frames(report,where,frames,expected,name,fov,main_scale):
    for i,snap in enumerate(frames):
        at=f'{where} frame {i}'
        main,obj=snap['main'],snap['object']
        report.deviation('cameraFromTransformsPosition',distance(main['position'],expected['position']),POSITION_TOLERANCE,at)
        report.deviation('cameraFromTransformsRotation',angle(main['rotation'],expected['rotation']),ROTATION_TOLERANCE,at)
        report.deviation('cameraFromObjectPosition',distance(main['position'],obj['position']),POSITION_TOLERANCE,at)
        report.deviation('cameraFromObjectRotation',angle(main['rotation'],obj['rotation']),ROTATION_TOLERANCE,at)
        report.deviation('objectFromTransformsPosition',distance(obj['position'],expected['position']),POSITION_TOLERANCE,at)
        report.deviation('fov',abs(snap['fov']-fov),FOV_TOLERANCE,at)
        report.deviation('cameraScale',distance(main['lossyScale'],main_scale),POSITION_TOLERANCE,at)
        report.expect(snap['cameraCtrlEnabled'] is False,at,'cameraCtrl stays enabled while the object is active')
        report.expect(obj['meshRendererEnabled'] is False,at,'camera icon renderer stays enabled while active')
        report.expect(snap['activeCamera']==name,at,f"active camera is {snap['activeCamera']!r}, expected {name!r}")

def check_restored(report,where,frames,before):
    for i,snap in enumerate(frames):
        at=f'{where} frame {i}'
        report.deviation('restoredPosition',distance(snap['main']['position'],before['main']['position']),POSITION_TOLERANCE,at)
        report.deviation('restoredRotation',angle(snap['main']['rotation'],before['main']['rotation']),ROTATION_TOLERANCE,at)
        report.deviation('fov',abs(snap['fov']-before['fov']),FOV_TOLERANCE,at)
        report.expect(snap['cameraCtrlEnabled'] is True,at,'cameraCtrl is not re-enabled after toggling off')
        report.expect(snap['activeCamera'] is None,at,'a camera is still active after toggling off')
        if 'object' in snap:report.expect(snap['object']['meshRendererEnabled'] is True,at,'camera icon renderer stays hidden after toggling off')

def check_object_case(report,label,case):
    parent=parent_frame(case)
    expected=compose(parent,case['authoredLocalPosition'],case['authoredLocalRotation'])
    name=case['placed']['object']['name'];before=case['before']
    summary=dict(parent=None if case.get('parentState') is None else dict(authoredScale=case['parentState']['authoredScale'],effectiveScale=parent['scale'],guideEnableScale=case['parentState']['guideEnableScale']))
    report.expect(case['activateSelected'] is True,label,'ChangeCamera did not select the object')
    report.expect(case['cameraCtrlEnabledAfterActivate'] is False,label,'cameraCtrl enabled right after activation')
    report.expect(case['placed']['object']['meshRendererEnabled'] is True,label,'icon hidden before activation')
    check_active_frames(report,label+' active',case['active'],expected,name,before['fov'],before['main']['lossyScale'])
    if case.get('moved'):
        moved=compose(parent,case['movedLocalPosition'],case['movedLocalRotation'])
        check_active_frames(report,label+' moved',case['moved'],moved,name,before['fov'],before['main']['lossyScale'])
    report.expect(case['deactivateCleared'] is True,label,'toggling off left the camera selected')
    check_restored(report,label+' restored',case['restored'],before)
    if case.get('parentState') is not None:
        state=case['parentState']
        authored=dict(parent,scale=state['authoredScale'])
        summary['cameraOffsetIfAuthoredScaleApplied']=distance(compose(authored,case['authoredLocalPosition'],case['authoredLocalRotation'])['position'],case['active'][-1]['main']['position'])
    summary['cameraWorld']=pose(case['active'][-1]['main']);summary['fov']=case['active'][-1]['fov']
    report.cases[label]=summary

def load_expected(loaded,studio_parent):
    """World pose of a loaded camera from its local transform and, when its Studio parent is the
    folder, the authored folder transform. The Studio parent comes from the record order: a root
    object's Unity parent is Scene.commonSpace, not None."""
    local=(loaded['changePosition'],loaded['changeRotation'])
    if studio_parent is None:return compose(IDENTITY,*local)
    folder=dict(compose(IDENTITY,LOAD_FOLDER['position'],LOAD_FOLDER['rotation']),scale=[1.0,1.0,1.0])
    return compose(folder,*local)

def check_load_case(report,label,case):
    where='load-'+label;authored=case['authoredOrder'];cams=[r for r in authored if r['kind']==5]
    predicted=active_by_rule(authored)
    alternatives={rule:active_by_rule(authored,rule) for rule in ALTERNATIVE_RULES}
    report.expect(case['activeAfterLoad']==predicted,where,f"active after load {case['activeAfterLoad']!r}, rule predicts {predicted!r}")
    report.expect(case['cameraCtrlEnabledAfterLoad'] is (predicted is None),where,'cameraCtrl enabled state after load does not match the active camera')
    saved=case['savedCameraData']
    for i,snap in enumerate(case['afterLoad']):
        at=f'{where} after load frame {i}'
        data=snap['ctrlData']
        report.deviation('savedViewImported',max(distance(data['pos'],saved['pos']),distance(data['rotate'],saved['rotate']),distance(data['distance'],saved['distance']),abs(data['parse']-saved['parse'])),POSITION_TOLERANCE,at)
        report.deviation('fov',abs(snap['fov']-saved['parse']),FOV_TOLERANCE,at)
        if predicted is None:
            report.deviation('restoredPosition',distance(snap['main']['position'],case['savedView']['main']['position']),POSITION_TOLERANCE,at)
            report.deviation('restoredRotation',angle(snap['main']['rotation'],case['savedView']['main']['rotation']),ROTATION_TOLERANCE,at)
            continue
        loaded={c['name']:c for c in case['loadedCameras']}
        studio_parent=next(r['parent'] for r in authored if r['name']==predicted)
        expected=load_expected(loaded[predicted],studio_parent)
        report.deviation('cameraFromTransformsPosition',distance(snap['main']['position'],expected['position']),POSITION_TOLERANCE,at)
        report.deviation('cameraFromTransformsRotation',angle(snap['main']['rotation'],expected['rotation']),ROTATION_TOLERANCE,at)
        report.deviation('cameraFromObjectPosition',distance(snap['main']['position'],snap['object']['position']),POSITION_TOLERANCE,at)
        report.deviation('cameraFromObjectRotation',angle(snap['main']['rotation'],snap['object']['rotation']),ROTATION_TOLERANCE,at)
        report.expect(snap['cameraCtrlEnabled'] is False,at,'cameraCtrl enabled while a loaded camera is active')
    if predicted is not None:check_restored(report,where+' restored',case['restored'] or [],case['savedView'])
    report.cases[where]=dict(fileOrder=[(c['name'],c['active'],c['parent']) for c in cams],activeAfterLoad=case['activeAfterLoad'],predicted=predicted,
        alternatives=alternatives,flagsAfterLoad={c['name']:c['infoActive'] for c in case['loadedCameras']})

def check_look_at(report,look):
    if not look or look.get('skipped'):report.cases['look-at']=dict(skipped=(look or {}).get('skipped','absent'));return
    if look.get('error'):report.cases['look-at']=dict(error=look['error'].splitlines()[0]);return
    for phase in ['control','object','restored']:
        for i,snap in enumerate(look[phase]):
            at=f'look-at {phase} frame {i}'
            report.expect(snap['neckTargetIsCameraMain'] and snap['eyesTargetIsCameraMain'],at,'look targets are not Camera.main.transform')
            report.deviation('lookTargetFromCamera',max(distance(snap['neckTarget'],snap['cameraMain']),distance(snap['eyesTarget'],snap['cameraMain'])),POSITION_TOLERANCE,at)
            if phase=='object':report.deviation('lookTargetFromObject',distance(snap['neckTarget'],snap['object']),POSITION_TOLERANCE,at)
    head=lambda phase:look[phase][-1]['headRotation']
    report.cases['look-at']=dict(headTurnTowardObjectDegrees=angle(head('control'),head('object')),headReturnAfterToggleDegrees=angle(head('control'),head('restored')))

def check_capture(trace):
    report=Report();cases=trace['cases'];env=cases['environment']
    report.expect(env['cameraMainIsCtrlCamera'] and env['cameraMainTransformIsCtrlTransform'],'environment','Camera.main is not cameraCtrl\'s camera')
    for label in OBJECT_CASES:check_object_case(report,label,cases[label])
    for label in LOAD_CASES:check_load_case(report,label,cases['load-'+label])
    check_look_at(report,cases.get('look-at'))
    return report

# --- committed reference ---
def r6(value):
    if isinstance(value,float):return round(value,6)+0.0
    if isinstance(value,list):return [r6(v) for v in value]
    if isinstance(value,dict):return {k:r6(v) for k,v in value.items()}
    return value

def camera(snap):return dict(position=snap['main']['position'],rotation=snap['main']['rotation'],fov=snap['fov'])

def build_reference(trace):
    cases=trace['cases'];objects=[]
    for label in OBJECT_CASES:
        case=cases[label];state=case.get('parentState')
        parent=None if state is None else dict(authoredPosition=state['authoredPosition'],authoredRotation=state['authoredRotation'],authoredScale=state['authoredScale'],
            scaleApplied=state['guideEnableScale'],world=dict(position=state['childRoot']['position'],rotation=state['childRoot']['rotation'],scale=state['childRoot']['lossyScale']))
        entry=dict(name=label,parent=parent,local=dict(position=case['authoredLocalPosition'],rotation=case['authoredLocalRotation']),
            cameraBefore=camera(case['before']),camera=camera(case['active'][-1]),restoredCamera=camera(case['restored'][-1]))
        objects.append(entry)
        if case.get('moved'):objects.append(dict(entry,name=label+'-moved',local=dict(position=case['movedLocalPosition'],rotation=case['movedLocalRotation']),camera=camera(case['moved'][-1])))
    loads=[]
    for label in LOAD_CASES:
        case=cases['load-'+label];loaded={c['name']:c for c in case['loadedCameras']}
        records=[]
        for r in case['authoredOrder']:
            rec=dict(name=r['name'],kind=r['kind'],dicKey=r['dicKey'],parent=r['parent'])
            if r['kind']==5:rec.update(active=r['active'],local=dict(position=loaded[r['name']]['changePosition'],rotation=loaded[r['name']]['changeRotation']))
            else:rec.update(local=dict(position=LOAD_FOLDER['position'],rotation=LOAD_FOLDER['rotation']))
            records.append(rec)
        saved=case['savedCameraData']
        loads.append(dict(name=label,records=records,savedCamera=dict(position=saved['pos'],rotate=saved['rotate'],distance=saved['distance'],fov=saved['parse']),
            activeAfterLoad=case['activeAfterLoad'],flagsAfterLoad={c['name']:c['infoActive'] for c in case['loadedCameras']},
            camera=camera(case['afterLoad'][-1]),savedViewCamera=camera(case['savedView']),restoredCamera=None if not case.get('restored') else camera(case['restored'][-1])))
    return r6(dict(schemaVersion=1,
        source='Original CharaStudio capture of synthetic Studio camera objects (ST-A06); inputs are authored test values, outputs rounded to 1e-6',
        conventions='Unity left-handed axes; positions in metres; rotations as quaternion x,y,z,w; local.rotation and authoredRotation are Unity Euler degrees applied z, x, then y',
        tolerances=dict(position=POSITION_TOLERANCE,rotationDegrees=ROTATION_TOLERANCE,fov=FOV_TOLERANCE),
        objectCases=objects,loadCases=loads))

def check_reference(reference):
    """Recompute every camera pose in the committed reference from its transforms and the load rule."""
    report=Report()
    for case in reference['objectCases']:
        where=case['name'];parent=IDENTITY if case['parent'] is None else case['parent']['world']
        expected=compose(parent,case['local']['position'],case['local']['rotation'])
        report.deviation('cameraFromTransformsPosition',distance(case['camera']['position'],expected['position']),POSITION_TOLERANCE,where)
        report.deviation('cameraFromTransformsRotation',angle(case['camera']['rotation'],expected['rotation']),ROTATION_TOLERANCE,where)
        report.deviation('fov',abs(case['camera']['fov']-case['cameraBefore']['fov']),FOV_TOLERANCE,where)
        report.deviation('restoredPosition',distance(case['restoredCamera']['position'],case['cameraBefore']['position']),POSITION_TOLERANCE,where)
        report.deviation('restoredRotation',angle(case['restoredCamera']['rotation'],case['cameraBefore']['rotation']),ROTATION_TOLERANCE,where)
    for case in reference['loadCases']:
        where='load-'+case['name'];records=case['records']
        predicted=active_by_rule(records)
        report.expect(case['activeAfterLoad']==predicted,where,f"active after load {case['activeAfterLoad']!r}, rule predicts {predicted!r}")
        report.deviation('fov',abs(case['camera']['fov']-case['savedCamera']['fov']),FOV_TOLERANCE,where)
        target=case['savedViewCamera'] if predicted is None else None
        if predicted is not None:
            record=next(r for r in records if r['name']==predicted)
            folder=next((r for r in records if r['name']==record['parent']),None)
            parent=IDENTITY if folder is None else dict(compose(IDENTITY,folder['local']['position'],folder['local']['rotation']),scale=[1.0,1.0,1.0])
            target=compose(parent,record['local']['position'],record['local']['rotation'])
            report.deviation('restoredPosition',distance(case['restoredCamera']['position'],case['savedViewCamera']['position']),POSITION_TOLERANCE,where)
            report.deviation('restoredRotation',angle(case['restoredCamera']['rotation'],case['savedViewCamera']['rotation']),ROTATION_TOLERANCE,where)
        report.deviation('cameraFromTransformsPosition',distance(case['camera']['position'],target['position']),POSITION_TOLERANCE,where)
        report.deviation('cameraFromTransformsRotation',angle(case['camera']['rotation'],target['rotation']),ROTATION_TOLERANCE,where)
    return report

def main():
    p=argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('capture',type=Path,nargs='?',help='capture folder holding camera-trace.json')
    p.add_argument('--reference',type=Path,help='check this committed reference instead of a capture')
    p.add_argument('--write-reference',type=Path,help='write the rounded reference built from the capture')
    a=p.parse_args()
    if (a.capture is None)==(a.reference is None):p.error('give either a capture folder or --reference')
    if a.reference is not None:
        report=check_reference(json.loads(a.reference.read_text()))
    else:
        trace=json.loads((a.capture/'camera-trace.json').read_text())
        report=check_capture(trace)
        if a.write_reference is not None and not report.failures:
            a.write_reference.write_text(json.dumps(build_reference(trace),indent=1,sort_keys=True)+'\n')
    print(json.dumps(dict(maxima=report.maxima,cases=report.cases,failures=report.failures),indent=2,default=str))
    return 1 if report.failures else 0

if __name__=='__main__':sys.exit(main())
