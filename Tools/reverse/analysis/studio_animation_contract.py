#!/usr/bin/env python3
"""Independent binary32 trace of recovered Studio animation controls."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]


def trace(initial, speed, state_speed, duration, loop, forced, deltas):
    time=f32(initial); records=[]
    for delta in deltas:
        step=f32(f32(f32(f32(delta)*f32(speed))*f32(state_speed))/f32(duration))
        time=f32(time+step)
        if forced and not loop and time>=1: time=0.0
        records.append(dict(deltaTime=delta, normalizedTime=time))
    return dict(initial=initial,speed=speed,stateSpeed=state_speed,duration=duration,loops=loop,forceLoop=forced,frames=records)


def contract(source):
    files={name:(source/name).read_bytes() for name in ['Studio.OCIChar.cs','Studio.CharAnimeCtrl.cs','Studio.AddObjectFemale.cs','Studio.AddObjectMale.cs']}
    text=files['Studio.OCIChar.cs'].decode()
    required=['charInfo.animBody.speed = value;', 'charInfo.setAnimatorParamFloat("motion", oiCharInfo.animePattern);',
              'charAnimeCtrl.Play(value3.clip, _normalizedTime);','charInfo.AnimPlay(value3.clip);',
              'oiCharInfo.animeNormalizedTime = currentAnimatorStateInfo.normalizedTime;']
    if any(part not in text for part in required): raise ValueError('Recovered OCIChar behavior changed; review the adapter')
    loop=files['Studio.CharAnimeCtrl.cs'].decode()
    if '!currentAnimatorStateInfo.loop && currentAnimatorStateInfo.normalizedTime >= 1f' not in loop or 'animator.Play(nameHadh, 0, 0f);' not in loop:
        raise ValueError('Recovered force-loop behavior changed')
    return dict(schemaVersion=1, sourceHashes={n:hashlib.sha256(b).hexdigest() for n,b in files.items()},
        scope='Normal catalog selection; Animator scalar speed; saved normalizedTime; per-LateUpdate force-loop reset. Unity native interpolation is checked separately.',
        scenarios=[trace(.625,1.25,.5,2,True,False,[0,.5,1,4]),
                   trace(.95,1,1,1,False,True,[.1,.4,1.8,0]),
                   trace(1.5,0,1,2,False,True,[0,1,10]),
                   trace(.8,.75,.7,3,True,True,[1/60]*120),
                   trace(.25,2,1,4,False,False,[0,.25,2,5])])


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(contract(a.source),indent=2)+'\n')
