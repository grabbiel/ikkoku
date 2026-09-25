#!/usr/bin/env python3
"""Validate translated execution, native card persistence and capture parity.

Supply an explicitly authored fully clothed Studio fixture and local converted
asset environment. No installed card thumbnails or arbitrary windows are read.
"""
import argparse, hashlib, json, os, struct, subprocess
from pathlib import Path
from PIL import Image, ImageChops

ROOT=Path(__file__).resolve().parents[2]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def payload(path):
 data=path.read_bytes();offset=8
 if data[:8]!=b'\x89PNG\r\n\x1a\n':raise ValueError('Expected a native PNG scene')
 while offset+12<=len(data):
  size=struct.unpack_from('>I',data,offset)[0];kind=data[offset+4:offset+8];body=data[offset+8:offset+8+size]
  if offset+12+size>len(data):raise ValueError('Truncated native PNG')
  if kind==b'iTXt' and body.startswith(b'ikkoku:scene\0\0\0\0\0'):return json.loads(body[len(b'ikkoku:scene\0\0\0\0\0'):])
  offset+=12+size
 raise ValueError('Native scene payload absent')
def scalar(field):return struct.unpack('<f',struct.pack('<I',field['float']['_0']))[0]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--executable',type=Path,required=True);p.add_argument('--scene',type=Path,required=True);p.add_argument('--environment',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--native-manifest',type=Path,action='append',default=[]);p.add_argument('--output',type=Path,required=True);p.add_argument('--simulation-frames',type=int,default=30);a=p.parse_args()
 out=a.output.resolve()
 if not out.is_relative_to((ROOT/'.local').resolve()):raise ValueError('Private artifacts must stay under .local')
 out.mkdir(parents=True,exist_ok=False)
 profile=out/'profile.json';profile.write_text(json.dumps(dict(schemaVersion=1,fixedDeltaTime=.02,packages=[dict(manifest=str(a.manifest.resolve()),bindings=[dict(type='StudioMotionFixture',sourceObjectKey=10)])]),indent=2))
 base={k:v for k,v in os.environ.items() if not k.startswith('IKKOKU_')};base.update(json.loads(a.environment.read_text()))
 base.update(IKKOKU_CAPTURE_W='600',IKKOKU_CAPTURE_H='800',IKKOKU_CAPTURE_GRID='0',IKKOKU_CAPTURE_GIZMOS='0')
 for mode in ['run','reload','continue']:
  env=base|dict(IKKOKU_AUTOCAPTURE=str(out/(mode+'.png')))
  if mode=='run':
   env.update(IKKOKU_SOURCE_SCENE=str(a.scene.resolve()),IKKOKU_STUDIO_ANIMATION_TIME='0.5',IKKOKU_SOURCE_PLUGIN_PROFILE=str(profile),IKKOKU_SOURCE_PLUGIN_STEPS='30',IKKOKU_SAVE_SCENE=str(out/'native.png'),IKKOKU_BENCHMARK_OUTPUT=str(out/'benchmark.json'),IKKOKU_BENCHMARK_SIMULATION_FRAMES=str(a.simulation_frames))
   if a.native_manifest:env['IKKOKU_NATIVE_PLUGIN_MANIFESTS']=json.dumps([str(path.resolve()) for path in a.native_manifest])
  else:
   env.update(IKKOKU_CAPTURE_SCENE=str(out/'native.png'))
   if mode=='continue':env.update(IKKOKU_SOURCE_PLUGIN_STEPS='30',IKKOKU_SAVE_SCENE=str(out/'continued-native.png'))
  with (out/(mode+'.log')).open('w') as log:r=subprocess.run([str(a.executable.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=240)
  if r.returncode:raise RuntimeError('Native '+mode+' failed; inspect '+str(out/(mode+'.log')))
 first=Image.open(out/'run.png').convert('RGB');second=Image.open(out/'reload.png').convert('RGB')
 if first.size!=second.size:raise ValueError('Capture dimensions differ')
 difference=ImageChops.difference(first,second).getbbox()
 initial=payload(out/'native.png');continued=payload(out/'continued-native.png')
 state=initial['sourcePluginState'];next_state=continued['sourcePluginState'];fields=state['bindings'][0]['fields'];next_fields=next_state['bindings'][0]['fields']
 identity=state['bindings'][0]['pluginGUID']
 if identity!='Ikkoku.Validation.StudioMotion' or identity!=next_state['bindings'][0]['pluginGUID']:raise ValueError('Plugin identity changed')
 if scalar(fields['starts'])!=1 or scalar(next_fields['starts'])!=1:raise ValueError('Start replayed on reload')
 if abs(scalar(fields['elapsed'])-1)>1e-5 or abs(scalar(next_fields['elapsed'])-2)>1e-5:raise ValueError('Plugin clock did not resume')
 source=next(o for o in initial['objects'] if o.get('sourceObjectKey')==10);target=next(o for o in continued['objects'] if o.get('sourceObjectKey')==10)
 if source['id']!=target['id'] or abs(target['transform']['position'][0]-source['transform']['position'][0]-.125)>1e-5:raise ValueError('Source target identity or world motion differs')
 adapters=initial.get('sourceNativePlugins',[])
 if adapters!=continued.get('sourceNativePlugins',[]):raise ValueError('Original adapter identities changed on reload')
 if {row['manifestFile']:row['manifestSHA256'] for row in adapters}!={str(path.resolve()):digest(path) for path in a.native_manifest}:raise ValueError('Original adapter packages were not retained')
 report=dict(schemaVersion=1,pixelIdentical=difference is None,differenceBounds=difference,pluginGUID=identity,starts=scalar(next_fields['starts']),elapsed=scalar(next_fields['elapsed']),sourceObjectKey=10,nativeObjectID=source['id'],executableSHA256=digest(a.executable),sourceSceneSHA256=digest(a.scene),packageSHA256=digest(a.manifest))
 report['nativeAdapters']=adapters
 (out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
 if difference is not None:raise ValueError('Native save/reload capture differs')
if __name__=='__main__':main()
