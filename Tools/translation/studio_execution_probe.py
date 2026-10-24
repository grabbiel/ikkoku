#!/usr/bin/env python3
"""Validate translated execution, native card persistence and capture parity.

Supply an explicitly authored fully clothed Studio fixture and local converted
asset environment. No installed card thumbnails or arbitrary windows are read.
With original adapter manifests, each run/reload/continue launch also delivers
headless focus loss/gain and reports mounts, observers and generated-tone gain.
"""
import argparse, hashlib, json, math, os, struct, subprocess, time
from pathlib import Path

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
def comparable_state(state):
 # Swift encodes [UUID: String] as alternating keys/values. Pair order is not
 # stable across processes, but every UUID and its exact source identity is.
 value=dict(state);pairs=value.get('objectIdentities')
 if not isinstance(pairs,list) or len(pairs)%2 or any(not isinstance(item,str) for item in pairs):raise ValueError('Invalid plugin object identity map')
 identities=dict(zip(pairs[::2],pairs[1::2]))
 if len(identities)*2!=len(pairs) or len(set(identities.values()))!=len(identities):raise ValueError('Duplicate plugin object identity')
 value['objectIdentities']=identities
 return value
def scalar(field):return struct.unpack('<f',struct.pack('<I',field['float']['_0']))[0]
MUTE='bepinex-mute-in-background-v1'
def mute_volumes(enabled,volume,events):
 # Mute In Background 1.1, including the repeated-loss quirk that saves zero.
 original,result=None,[]
 for focus in events:
  if focus:volume,original=(volume if original is None else original),None
  elif enabled:original,volume=volume,0.
  result.append(volume)
 return result
def check_adapter_reports(reports,manifests,events):
 expected={str(path.resolve()):digest(path) for path in manifests};first=enabled=None
 for mode,report in reports.items():
  refs=report['nativePlugins'];mount,final,trace=report['mount'],report['final'],report['focusTrace']
  if {row['manifestFile']:row['manifestSHA256'] for row in refs}!=expected:raise ValueError(mode+': original adapter packages were not retained')
  if first is None:first=refs
  elif refs!=first:raise ValueError(mode+': original adapter identities or settings changed')
  if not any(row['adapterID']==MUTE and row['enabled'] for row in refs):
   if mount['mounted'] or final['mounted'] or events:raise ValueError(mode+': unexpected Mute adapter state')
   continue
  for state in (mount,final):
   if not state['mounted'] or state['focusObservers']!=2:raise ValueError(mode+': Mute adapter must own exactly one focus observer set')
   if state['launchObserver']!=state['awaitingInitialFocus']:raise ValueError(mode+': deferred initial focus observer is inconsistent')
  if not report['launchFinished'] and not mount['awaitingInitialFocus']:raise ValueError(mode+': initial focus was sampled before launching finished')
  if events and final['awaitingInitialFocus']:raise ValueError(mode+': focus events did not supersede the deferred initial sample')
  if final['enabled']!=mount['enabled'] or enabled not in (None,mount['enabled']):raise ValueError(mode+': Mute configuration changed')
  enabled=mount['enabled'];base=trace[0]
  if [row.get('focus') for row in trace]!=[None]+list(events):raise ValueError(mode+': focus trace differs from requested events')
  if not base['toneRMS']>.01 or not base['masterVolume']>0:raise ValueError(mode+': generated tone is silent before focus events')
  for row,volume in zip(trace[1:],mute_volumes(enabled,base['masterVolume'],events)):
   if abs(row['masterVolume']-volume)>1e-6 or row['voiceVolume']!=base['voiceVolume']:raise ValueError(mode+': master or voice gain differs from Mute 1.1')
   if abs(row['toneRMS']-base['toneRMS']*volume/base['masterVolume'])>.002*base['toneRMS']:raise ValueError(mode+': generated-tone gain differs from master gain')
def animation_environment(explicit_time, phase):
 if explicit_time is not None:
  if not math.isfinite(explicit_time) or not 0 <= explicit_time <= 86400:raise ValueError('--animation-time must be finite and within 0...86400 seconds')
  return {'IKKOKU_STUDIO_ANIMATION_TIME': str(explicit_time)}
 # Preserve the old probe's import-only 0.5-second clock by default.
 return {'IKKOKU_STUDIO_ANIMATION_TIME': '0.5'} if phase=='run' else {}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--executable',type=Path,required=True);p.add_argument('--scene',type=Path,required=True);p.add_argument('--environment',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--native-manifest',type=Path,action='append',default=[]);p.add_argument('--output',type=Path,required=True);p.add_argument('--simulation-frames',type=int,default=30);p.add_argument('--focus-events',default='0,1',help='Comma-separated 0/1 focus loss/gain delivered when a Mute manifest is mounted');p.add_argument('--mute-config',type=Path,help='Replacement BepInEx config applied after mounts in every phase, e.g. an enabled copy');p.add_argument('--library-selection',type=Path,help='Pinned library selection and scene binding request, replacing profile/manifest mounts');p.add_argument('--animation-time',type=float,help='Hold this explicit source-hand/animation clock in every phase; default preserves the historical import-only 0.5 seconds');a=p.parse_args()
 events=[value=='1' for value in a.focus_events.split(',')] if a.focus_events else []
 if a.focus_events and set(a.focus_events.split(','))-{'0','1'} or len(events)>64:raise ValueError('--focus-events must list at most 64 comma-separated 0/1 values')
 request=json.loads(a.library_selection.read_text()) if a.library_selection else None
 if request:
  selection=request['selection'];library=Path(selection['libraryFile']);generation=library.parent/'generations'/f"{selection['generation']:06d}.json"
  if digest(generation)!=selection['generationSHA256']:raise ValueError('Pinned library generation hash differs')
  a.native_manifest=[library.parent/'revisions'/r['manifestSHA256']/'manifest.json' for r in selection['revisions'] if r['kind']=='ikkoku-native-plugin-adapter']
 mute=any(json.loads(path.read_text()).get('adapterID')==MUTE for path in a.native_manifest)
 if a.mute_config and not mute:raise ValueError('--mute-config requires a Mute --native-manifest')
 out=a.output.resolve()
 if not out.is_relative_to((ROOT/'.local').resolve()):raise ValueError('Private artifacts must stay under .local')
 out.mkdir(parents=True,exist_ok=False)
 profile=out/'profile.json';profile.write_text(json.dumps(dict(schemaVersion=1,fixedDeltaTime=.02,packages=[dict(manifest=str(a.manifest.resolve()),bindings=[dict(type='StudioMotionFixture',sourceObjectKey=10)])]),indent=2))
 base={k:v for k,v in os.environ.items() if not k.startswith('IKKOKU_')};base.update(json.loads(a.environment.read_text()))
 base.update(IKKOKU_CAPTURE_W='600',IKKOKU_CAPTURE_H='800',IKKOKU_CAPTURE_GRID='0',IKKOKU_CAPTURE_GIZMOS='0')
 app_pids={};process_wall={}
 for mode in ['run','reload','continue']:
  env=base|dict(IKKOKU_AUTOCAPTURE=str(out/(mode+'.png')))|animation_environment(a.animation_time,mode)
  if a.native_manifest or a.animation_time is not None:env['IKKOKU_NATIVE_PLUGIN_REPORT']=str(out/(mode+'-adapters.json'))
  if a.native_manifest and mute and events:env['IKKOKU_APPLICATION_FOCUS']=','.join('1' if value else '0' for value in events)
  if a.mute_config:env['IKKOKU_MUTE_BACKGROUND_CONFIG']=str(a.mute_config.resolve())
  if mode=='run':
   env.update(IKKOKU_SOURCE_SCENE=str(a.scene.resolve()),IKKOKU_SOURCE_PLUGIN_PROFILE=str(profile),IKKOKU_SOURCE_PLUGIN_STEPS='30',IKKOKU_SAVE_SCENE=str(out/'native.png'),IKKOKU_BENCHMARK_OUTPUT=str(out/'benchmark.json'),IKKOKU_BENCHMARK_SIMULATION_FRAMES=str(a.simulation_frames))
   if request:
    env.pop('IKKOKU_SOURCE_PLUGIN_PROFILE',None);env['IKKOKU_STUDIO_PLUGIN_SELECTION']=str(a.library_selection.resolve())
   elif a.native_manifest:env['IKKOKU_NATIVE_PLUGIN_MANIFESTS']=json.dumps([str(path.resolve()) for path in a.native_manifest])
  else:
   env.update(IKKOKU_CAPTURE_SCENE=str(out/'native.png'))
   if mode=='reload' and request:env['IKKOKU_SAVE_SCENE']=str(out/'reloaded-native.png')
   if mode=='continue':env.update(IKKOKU_SOURCE_PLUGIN_STEPS='30',IKKOKU_SAVE_SCENE=str(out/'continued-native.png'))
  with (out/(mode+'.log')).open('w') as log:
   started=time.monotonic()
   process=subprocess.Popen([str(a.executable.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT)
   app_pids[mode]=process.pid;print('[plugin-probe]',mode,'PID',process.pid,flush=True)
   try:code=process.wait(timeout=240)
   except subprocess.TimeoutExpired:process.kill();process.wait();raise
   process_wall[mode]=time.monotonic()-started
  if code:raise RuntimeError('Native '+mode+' failed; inspect '+str(out/(mode+'.log')))
 from PIL import Image, ImageChops
 first=Image.open(out/'run.png').convert('RGB');second=Image.open(out/'reload.png').convert('RGB')
 if first.size!=second.size:raise ValueError('Capture dimensions differ')
 difference=ImageChops.difference(first,second).getbbox()
 initial=payload(out/'native.png');continued=payload(out/'continued-native.png')
 if request:
  reopened=payload(out/'reloaded-native.png')
  for phase,document in [('run',initial),('reload',reopened),('continue',continued)]:
   if document.get('sourcePluginLibrary')!=request['selection'] or document.get('sourcePluginLibraryConfiguration')!=request['configuration']:raise ValueError(phase+': pinned library selection or bindings changed')
   if document['sourcePluginState'].get('profileFile') is not None or not document['sourcePluginState'].get('libraryConfigurationSHA256'):raise ValueError(phase+': library state is not explicit')
  if comparable_state(initial['sourcePluginState'])!=comparable_state(reopened['sourcePluginState']):raise ValueError('Fresh reload changed library fields, clocks, object identities or clone serial')
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
 focus={mode:json.loads((out/(mode+'-adapters.json')).read_text()) for mode in ['run','reload','continue']} if a.native_manifest or a.animation_time is not None else {}
 if focus:
  check_adapter_reports(focus,a.native_manifest,events if mute else [])
  if focus['run']['nativePlugins']!=adapters:raise ValueError('Mounted adapters differ from the saved native scene')
 report=dict(schemaVersion=1,pixelIdentical=difference is None,differenceBounds=difference,pluginGUID=identity,starts=scalar(next_fields['starts']),elapsed=scalar(next_fields['elapsed']),sourceObjectKey=10,nativeObjectID=source['id'],executableSHA256=digest(a.executable),sourceSceneSHA256=digest(a.scene),packageSHA256=digest(a.manifest))
 if request:report['librarySelection']=request['selection'];report['libraryConfiguration']=request['configuration'];report['reloadStateIdentical']=True
 report['appPIDs']=app_pids
 report['processWallSeconds']=process_wall
 report['processWallScope']='Whole process: startup, asset loading, plugin preparation/restore, rendering, PNG I/O and exit; not isolated UI scene-open or plugin-only cost.'
 report['requestedSourceAnimationTime']=a.animation_time
 report['effectiveSourceAnimationTimes']={mode:value.get('sourceAnimationTime') for mode,value in focus.items()}
 if a.animation_time is not None and any(value!=a.animation_time for value in report['effectiveSourceAnimationTimes'].values()):raise ValueError('Effective source animation clock differs from its explicit control')
 if request:report['availableGeneration']=json.loads(Path(request['selection']['libraryFile']).read_text())['current']
 report['nativeAdapters']=adapters;report['focusEvents']=events if mute else [];report['adapterReports']=focus
 if a.mute_config:report['muteConfigSHA256']=digest(a.mute_config)
 (out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
 if difference is not None:raise ValueError('Native save/reload capture differs')
if __name__=='__main__':main()
