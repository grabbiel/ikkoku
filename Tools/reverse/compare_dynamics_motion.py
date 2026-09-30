#!/usr/bin/env python3
"""Compare recorded original hair particle motion with the independent float32 replay.

Reads motion.json written by the running original player (OriginalDynamicsProbe
motion mode), rebuilds the oracle contract from the rig inputs and replays the
same seeded state and scripted root path, reporting per-component maxima, the
worst frame and the recorded-vs-predicted transform rigidity of the model
assumptions.
"""
from __future__ import annotations
import argparse, hashlib, json, sys
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent/'analysis'))
from dynamics_motion_replay import compare, original_scene_document
from dynamics_reference import original_document


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--capture',type=Path,required=True);p.add_argument('--rigs',type=Path,default=REPO/'.local/reverse/rigs');p.add_argument('--contract',type=Path,help='Maker-dynamics contract for the hair the fixture actually assembles (requires the matching --maker-library asset rigs); without it the canonical source-avatar document is used');p.add_argument('--maker-library',type=Path,help='Verified Maker library root containing assets/<category>-<id>/rig.json');p.add_argument('--output',type=Path,required=True);p.add_argument('--tolerance',type=float,default=1e-4);p.add_argument('--mode',choices=('full','one-step'),default='full',help='full runs the accumulated recorded-input parity gate; one-step seeds every frame from the capture internal state and predicts one integration step')
    a=p.parse_args()
    if not a.output.resolve().is_relative_to((REPO/'.local').resolve()): raise ValueError('Original-derived reports stay in .local')
    capture=json.loads(a.capture.read_text())
    if (a.contract is None)!=(a.maker_library is None): raise ValueError('--contract and --maker-library belong together')
    if a.contract is not None:
        document=original_scene_document(a.rigs,json.loads(a.contract.read_text()),capture['hairIDs'],a.maker_library)
    else:
        document=original_document(a.rigs)
    result=compare(capture,document,a.tolerance,a.mode)
    result['hierarchyRigs']=document.get('hierarchyRigs')
    inputs=[a.capture,a.rigs/'source-dynamics.json',Path(__file__)]+([a.contract,a.maker_library/'library.json'] if a.contract else [])+[Path(path) for path in document.get('hierarchyRigs',[])]
    result['evidence']=[dict(path=str(path.resolve()),sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for path in inputs]
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    if not result['passed']: raise ValueError(f'Original motion parity failed: {result["maxParticleError"]} m on {result["worstComponent"]} frame {result["worstFrame"]}')


if __name__=='__main__':main()
