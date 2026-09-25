#!/usr/bin/env python3
"""Compare original male skinned vertices against recovered C# local destinations.

Source-space world transforms, assembly and skinning are independent NumPy math;
Swift is used only to produce the actual output under test. Source data is ignored.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

from test_avatar_parity import source_reference, compare_avatar
from test_face_rig_parity import source_operations
from test_rig_parity import file_record, verify_provenance, REPO


def run(avatar, reference, inspector, output):
    manifest=json.loads(avatar.read_text());folder=avatar.parent
    contract_path=folder/'character-shape-contract.json';contract=json.loads(contract_path.read_text())
    reference_doc=json.loads(reference.read_text())
    domain=next(d for d in contract['domains'] if d['id']=='face')
    source=REPO/'.local/reverse/decompiled/Character/Koikatu/ShapeHeadInfoFemale.cs'
    operations=source_operations(source,domain)
    files=[manifest['bodySkeleton'],manifest['headSkeleton'],manifest['body']['file'],manifest['head']['file'],
           *[r['file'] for r in manifest['clothes']],*[r['file'] for r in manifest['hair']]]
    for file in files:verify_provenance(json.loads((folder/file).read_text()),contract)
    cases=[c for c in reference_doc['cases'] if c['sex']==0 and not c['corrected'] and c['updateMask']==7 and c['applyAlways']]
    # Original male preset, all 44 individual slots at 0/1 and two mixed cases.
    selected=[cases[0]]+[cases[1+slot*4+offset] for slot in range(44) for offset in [0,3]]+[cases[-2],cases[-1]]
    report=dict(schemaVersion=1,reference='Verbatim recovered C# Update/UpdateAlways final local TRS; independent separate source hierarchies, native reflection and original weighted inverse binds',
                inputs=[file_record(avatar),file_record(contract_path),file_record(reference)],nativeExecutable=file_record(inspector),cases=[])
    with tempfile.TemporaryDirectory(prefix='male-body-reference-',dir=output.parent) as temp:
        directory=Path(temp)
        for file in files:
            if file!=manifest['bodySkeleton']:os.link(folder/file,directory/file)
        original=json.loads((folder/manifest['bodySkeleton']).read_text())
        for number,case in enumerate(selected):
            body=copy.deepcopy(original);destinations={x['name']:x for x in case['destinations']}
            for node in body['nodes']:
                if node['name'] in destinations:
                    target=destinations[node['name']]
                    node.update(translation=target['position'],rotation=target['rotation'],scale=target['scale'])
            (directory/manifest['bodySkeleton']).write_text(json.dumps(body))
            expected_nodes,expected_parts=source_reference(manifest,directory,domain,operations,None)
            rates=','.join(f'{i}={rate}' for i,rate in enumerate(case['values']))
            actual=subprocess.run([str(inspector.resolve()),'body-snapshot',str(avatar.resolve()),str(contract_path.resolve()),rates],check=True,capture_output=True,text=True)
            result=compare_avatar(expected_nodes,expected_parts,json.loads(actual.stdout),2e-5)
            result.update(case=number,values=case['values']);report['cases'].append(result)
    report['passed']=all(c['passed'] for c in report['cases'])
    if file_record(inspector)!=report['nativeExecutable']:raise ValueError('Native executable changed during parity test')
    output.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    print(json.dumps(dict(passed=report['passed'],cases=len(selected),maxNodeError=max(c['nodeMatrixMaxAbsoluteError'] for c in report['cases']),maxVertexError=max(c['vertexMaxAbsoluteError'] for c in report['cases']),report=str(output)),indent=2))
    if not report['passed']:raise SystemExit(1)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--avatar',type=Path,default=REPO/'.local/reverse/male/source-male-avatar.json')
    parser.add_argument('--reference',type=Path,default=REPO/'.local/reverse/male/body-reference/reference.json')
    parser.add_argument('--inspect',type=Path,default=REPO/'Packages/Engine/.build/debug/ikkoku-inspect')
    parser.add_argument('--output',type=Path,default=REPO/'.local/reverse/male/body-vertex-parity-report.json')
    args=parser.parse_args();run(args.avatar,args.reference,args.inspect,args.output)
