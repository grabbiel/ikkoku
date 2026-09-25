#!/usr/bin/env python3
"""Execute unchanged recovered FinalIK C# with an independent Unity math host.

All original source, skeleton data, compiled binaries and numerical results are
written only to the supplied ignored local output directory. No images are read.
"""
from __future__ import annotations
import argparse, copy, hashlib, json, subprocess
from pathlib import Path
from studio_ik_bindings import extract

SOLVER_FILES = ['IKSolver','IKSolverFullBody','IKSolverFullBodyBiped','FBIKChain','IKEffector','IKConstraintBend','IKMapping','IKMappingSpine','IKMappingLimb','IKMappingBone','FullBodyBipedChain','FullBodyBipedEffector']
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle',type=Path,required=True);p.add_argument('--recovered-project',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    repo=Path(__file__).resolve().parents[3];out=args.output.resolve()
    if '.local' not in out.parts: raise ValueError('Original derived evidence must remain in ignored .local output')
    host=repo/'Tools/reverse/fixtures/FinalIKOracle';build=out/'oracle';recovered=build/'recovered';recovered.mkdir(parents=True,exist_ok=True)
    source_evidence=[]
    for folder,names in [('RootMotion.FinalIK',SOLVER_FILES),('RootMotion',['V3Tools','QuaTools'])]:
        for name in names:
            source=args.recovered_project/folder/(name+'.cs');(recovered/source.name).write_bytes(source.read_bytes())
            source_evidence.append({'path':str(source.resolve()),'sha256':digest(source)})
    (build/'UnityEngine.csproj').write_text(f'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><AssemblyName>UnityEngine</AssemblyName><AssemblyVersion>0.0.0.0</AssemblyVersion><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup><Compile Include="{host / "UnityShim.cs"}" /></ItemGroup></Project>')
    (build/'Oracle.csproj').write_text(f'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup><Compile Include="{host / "Program.cs"}"/><Compile Include="{host / "RecoverySurface.cs"}"/><Compile Include="recovered/*.cs"/><ProjectReference Include="UnityEngine.csproj"/></ItemGroup></Project>')
    subprocess.run(['dotnet','build',str(build/'Oracle.csproj'),'--nologo','-v:q'],check=True)
    import UnityPy
    env=UnityPy.load(str(args.bundle));binding=extract(args.bundle)
    component=next(o for o in env.objects if o.path_id==binding['source']['componentPathID'])
    raw=component.read_typetree()['solver'];objects={o.path_id:o for o in env.objects if o.assets_file is component.assets_file}
    def pointers(value):
        if isinstance(value,dict):
            if 'm_PathID' in value:
                if value['m_PathID']: yield value['m_PathID']
            else:
                for v in value.values(): yield from pointers(v)
        elif isinstance(value,list):
            for v in value: yield from pointers(v)
    keep=set(pointers(raw))
    for identity in list(keep):
        node=identity
        while node:
            keep.add(node);node=objects[node].read_typetree()['m_Father']['m_PathID']
    nodes=[]
    for identity in sorted(keep):
        t=objects[identity].read_typetree();name=objects[t['m_GameObject']['m_PathID']].read_typetree()['m_Name']
        nodes.append(dict(id=identity,sourceID=f'{component.assets_file.name}:{identity}',name=name,parent=t['m_Father']['m_PathID'],position=[t['m_LocalPosition'][k] for k in 'xyz'],rotation=[t['m_LocalRotation'][k] for k in 'xyzw'],scale=[t['m_LocalScale'][k] for k in 'xyz']))
    target_ids={t['id']:int(t['prefabTarget']['sourceID'].split(':')[-1]) for t in binding['targets']}
    cases=[]
    specs=[('rest',4,[True]*5,{}),('body',4,[True]*5,{0:[.12,.17,-.09]}),('proximal',4,[True]*5,{1:[.10,.07,.05],4:[-.08,.11,-.04],7:[.04,.03,.02],10:[-.05,.04,-.02]}),('reach',4,[False,False,False,True,True],{3:[-.35,.45,.25],6:[.4,.3,-.2]}),('iteration0',0,[True]*5,{0:[.1,.08,.02],3:[.05,.12,.08],9:[.07,.04,.06]}),('iteration1',1,[True]*5,{0:[.12,.17,-.09],3:[-.15,.2,.1]}),('iteration8',8,[True]*5,{0:[.12,.17,-.09],3:[-.15,.2,.1]}),('customized',4,[True]*5,{0:[.08,.13,.06],3:[.09,.08,.05]}),('relative',4,[True,False,False,True,True],{1:[.07,.09,.06],6:[.15,.1,.1]}),('weighted',4,[True]*5,{0:[.12,.17,-.09],3:[-.15,.2,.1]}),('asymmetric',4,[True]*5,{1:[.18,.04,.03],6:[.2,.1,-.1]}),('inactive',4,[False]*5,{0:[.3,.2,.1]})]
    for name,iterations,active,offsets in specs:
        b=copy.deepcopy(binding);s=copy.deepcopy(raw);ns=copy.deepcopy(nodes);s['iterations']=iterations;b['iterations']=iterations
        if name=='customized':
            for n in ns:
                if n['name']=='cf_j_hips':n['scale']=[1.12,.93,1.06]
                if n['name']=='cf_j_arm00_L':n['scale']=[1.03,1.1,.97]
                if n['name']=='cf_j_thigh00_R':n['scale']=[.96,1.08,1.04]
        if name=='relative':
            for i in range(5,9):s['effectors'][i]['maintainRelativePositionWeight']=.65;b['fullBody']['effectors'][i]['maintainRelativePositionWeight']=.65
        if name=='weighted':s['IKPositionWeight']=.6;b['fullBody']['weight']=.6
        if name=='asymmetric':
            for i,value in [(1,.35),(2,.8),(3,.55)]:s['chain'][i]['pull']=value;b['fullBody']['chains'][i]['pull']=value
            for i in (1,2):
                for key,value in [('push',.2),('pushParent',.25),('reach',.3)]:s['chain'][i][key]=value;b['fullBody']['chains'][i][key]=value
        data=dict(nodes=ns,solver=s,pose=[],active=active,targets=[{'id':target_ids[k],'offset':v} for k,v in offsets.items()])
        # Animation after initiation tests default bend directions and shoulder
        # swing axes independently from the sampled frame pose.
        if name=='customized':
            n=copy.deepcopy(next(n for n in ns if n['name']=='cf_j_spine02'));n['rotation']=[0,.087155744,0,.996194698];data['pose']=[n]
        input_path=out/(name+'-input.json');output_path=out/(name+'-output.json');input_path.write_text(json.dumps(data,indent=2)+'\n')
        subprocess.run(['dotnet',str(build/'bin/Debug/net10.0/Oracle.dll'),str(input_path),str(output_path)],check=True)
        cases.append(dict(name=name,bindings=b,nodes=ns,pose=data['pose'],active=active,expected=json.loads(output_path.read_text()),inputSHA256=digest(input_path),outputSHA256=digest(output_path)))
    evidence=dict(schemaVersion=1,kind='recovered-finalik-csharp-numerical-oracle',bundleSHA256=digest(args.bundle),sources=source_evidence,host=[{'path':str(p.relative_to(repo)),'sha256':digest(p)} for p in sorted(host.glob('*.cs'))],cases=cases,limitations=['Unchanged recovered FinalIK solver source executes against independent System.Numerics-backed Unity Transform/math semantics. This is not original Unity player execution.'])
    (out/'reference.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps({'output':str(out/'reference.json'),'cases':len(cases),'transforms':len(nodes),'sourceFiles':len(source_evidence)}))
if __name__=='__main__':main()
