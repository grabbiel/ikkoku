#!/usr/bin/env python3
"""Build compact native pose checks from the original player's numeric capture."""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--capture',type=Path,required=True);p.add_argument('--catalog',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if '.local' not in a.output.resolve().parts: raise ValueError('Source evidence must remain in .local')
    catalog=json.loads(a.catalog.read_text());cases=[];used={}
    for source in json.loads(a.capture.read_text())['cases']:
        entry=next(e for e in catalog['entries'] if e['controller']==source['controller'] and e['state']==source['state'])
        path=a.catalog.parent/entry['file'];data=path.read_bytes()
        if hashlib.sha256(data).hexdigest()!=entry['sha256']:raise ValueError('Converted animation changed')
        lib=json.loads(data);mapping={}
        for clip in lib['clips']:
            for binding in clip['bindings']:
                if 'sourcePath' not in binding:continue
                key=binding['sourcePath'];identity=(binding['targetSourceID'],binding['targetName'])
                if key in mapping and mapping[key]!=identity:raise ValueError('Ambiguous binding path')
                mapping[key]=identity
        before={b['path']:b for b in source['baseline'] if b['underAnimator']};after={b['path']:b for b in source['bones'] if b['underAnimator']}
        nodes=[]
        for path,(identity,name) in sorted(mapping.items()):
            if path not in before or path not in after:raise ValueError('Bound path absent from original player')
            def pose(b):return {k:b[k] for k in ['position','rotation','scale']}
            nodes.append(dict(sourceID=identity,name=name,sourcePath=path,baseline=pose(before[path]),expected=pose(after[path])))
        cases.append(dict(group=entry['group'],category=entry['category'],no=entry['no'],file=entry['file'],sha256=entry['sha256'],height=source['height'],inputNormalizedTime=source['inputNormalizedTime'],speed=source['speed'],deltaTime=source['deltaTime'],normalizedTime=source['normalizedTime'],nodes=nodes))
        used[entry['file']]=entry['sha256']
    result=dict(schemaVersion=1,kind='original-unity-animator-numeric-reference',source=dict(captureSHA256=hashlib.sha256(a.capture.read_bytes()).hexdigest(),catalogSHA256=hashlib.sha256(a.catalog.read_bytes()).hexdigest()),cases=cases,scope='Bound local transform channels against original Unity 5.6.2 Animator with original customized baseline; no render media',limitations=['This compares actual Animator application and clock advance, not the full Studio FK/IK/dynamics late-update pipeline.'])
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,separators=(',',':'),allow_nan=False)+'\n')
    print(json.dumps(dict(cases=len(cases),libraries=len(used),nodes=sum(len(c['nodes']) for c in cases),output=str(a.output))))


if __name__=='__main__':main()
