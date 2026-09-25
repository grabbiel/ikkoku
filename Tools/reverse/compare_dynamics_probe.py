#!/usr/bin/env python3
"""Compare original Unity numeric hair setup/curves with the converted contract.

This validates setup and interpolation, not a full running-Unity particle trace.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
from dynamics_contract import distribution, REPO


def compare(probe, contract):
    selected = [c for c in contract['components'] if c.get('sourceAsset') is not None
                and c['sourceAsset']['category'] in (101,102)
                and c['sourceAsset'].get('modGUID') is None
                and c['sourceAsset']['id'] == probe['hairIDs'][c['sourceAsset']['category']-101]]
    by_root = {c['rootName']:c for c in selected}
    if len(by_root) != len(selected): raise ValueError('Ambiguous selected source component root')
    if len(probe['components']) != len(selected) or set(by_root) != {c['rootName'] for c in probe['components']}: raise ValueError('Original/converted component identities differ')
    parameter_error = curve_error = 0.0
    particles = parameters = samples = 0
    for actual in probe['components']:
        expected = by_root[actual['rootName']]
        if len(actual['particles']) != len(expected['particles']): raise ValueError('Particle topology differs')
        if actual['colliders'] != len(expected['colliders']) or actual['updateRate'] != expected['updateRate']:
            raise ValueError('Component update rate or collider count differs')
        for a,b in zip(actual['particles'],expected['particles']):
            if a['name'] != b['nodeName'] or a['parent'] != (-1 if b['parent'] is None else b['parent']):
                raise ValueError('Particle identity/order differs')
            for field in ['damping','elasticity','stiffness','inert','radius']:
                if not math.isfinite(a[field]) or not math.isfinite(b[field]): raise ValueError('Nonfinite particle parameter')
                parameter_error = max(parameter_error,abs(a[field]-b[field])); parameters += 1
            particles += 1
        for curve in actual['curves'].values():
            for sample in curve['samples']:
                if not math.isfinite(sample['value']): raise ValueError('Nonfinite original curve sample')
                curve_error = max(curve_error,abs(distribution({'m_Curve':curve['keys']},sample['time'])-sample['value']))
                samples += 1
    if parameter_error > 1e-6 or curve_error > 1e-6: raise ValueError(f'Unity setup/interpolation parity failed: {parameter_error}, {curve_error}')
    return dict(components=len(selected),particles=particles,parameters=parameters,curveSamples=samples,
                maximumParameterError=parameter_error,maximumCurveError=curve_error,tolerance=1e-6,
                scope='Original Unity DynamicBone setup and AnimationCurve.Evaluate; no claim of original per-frame particle trajectory parity')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe',type=Path,required=True);p.add_argument('--contract',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if not a.output.resolve().is_relative_to((REPO/'.local').resolve()): raise ValueError('Original-derived reports stay in .local')
    result=compare(json.loads(a.probe.read_text()),json.loads(a.contract.read_text()))
    result['evidence']=[dict(path=str(path.resolve()),sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for path in [a.probe,a.contract,Path(__file__)]]
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='evidence'},indent=2))


if __name__=='__main__':main()
