#!/usr/bin/env python3
"""Run bounded source shader blits in an isolated original Unity player copy.

Only two selected face/clothes materials and explicit RGBA inputs are rendered.
The installed game's saves, mod configuration and plugins are never changed. A
private VM directory has copied executable/loader/core, read-only-use junctions
to assets and managed libraries, and this validation plugin alone. No desktop,
card thumbnail or arbitrary game camera is captured. This is material equation
validation, not full character-frame or lighting parity.
"""
from __future__ import annotations
import argparse,base64,gzip,hashlib,json,re,subprocess,time,uuid,zipfile
from pathlib import Path,PureWindowsPath
import msgpack
from PIL import Image
import numpy as np
from vm_source import powershell,ps_quote
from card_appearance_bindings import parse_card,get_path
from analysis.card_contract import Cursor
ROOT=Path(__file__).resolve().parents[2]

def digest(data):return hashlib.sha256(data).hexdigest()
def dump(path,value):path.write_text(json.dumps(value,indent=2,allow_nan=False)+'\n')
def records(card):
 parsed=parse_card(card.read_bytes());blocks={b['name']:b['raw'] for b in parsed.blocks};r=Cursor(blocks['Custom']);out={}
 for name in ['face','body','hair']:out[name]=msgpack.unpackb(r.take(r.number('<i')),raw=False)
 r=Cursor(msgpack.unpackb(blocks['Coordinate'],raw=False)[0]);out['clothes']=msgpack.unpackb(r.take(r.number('<i')),raw=False);out['makeup']=out['face']['baseMakeup'];return out

def prepare(base,output):
 manifest=json.loads((base/'source-avatar.card-appearance.json').read_text());card=base/'expanded-materials/synthetic-material-card.png';values=records(card)
 inputs=output/'inputs';inputs.mkdir(exist_ok=True);recipes=[];provenance=[];source_assets={}
 def asset(file,bundle,name):
  if '/abdata/' in bundle:bundle=bundle.rsplit('/abdata/',1)[1]
  with Image.open(file) as image:
   rgba=image.convert('RGBA');source_assets[(digest(rgba.tobytes()),rgba.width,rgba.height)]=(bundle,name)
 head=json.loads((base/'head-materials/contract.json').read_text())
 for row in head['defaultInputs']:
  if row.get('texture'):asset(base/'head-materials'/row['texture']['file'],row['bundle'],row['asset'])
 asset(base/'head-materials/cf_face_00_mp.png','chara/mm_base.unity3d','cf_face_00_mp')
 for entry in json.loads((base/'clothed-materials/manifest.json').read_text())['entries']:
  for texture in entry['textures']:asset(base/'clothed-materials'/texture['file'],entry['bundle'],texture['name'])
 for row in json.loads((base/'expanded-materials/source-material-catalog.json').read_text())['entries']:
  meta=row['texture'];source_assets[(meta['sha256'],meta['width'],meta['height'])]=(row['bundle'],row['name'])
 for entry in manifest['entries']:
  if entry['kind']!='head' and not(entry['kind']=='clothes' and entry['colors'][0].startswith('clothes.parts.0.')):continue
  kind=entry['kind'];dimensions=entry['main'];recipe=dict(name=kind,material='cf_m_face_create' if kind=='head' else 'cf_m_clothesN_create',width=dimensions['width'],height=dimensions['height'],textures=[],vectors=[],scalars=[])
  def texture(prop,meta):
   data=(base/meta['file']).read_bytes()
   if digest(data)!=meta['sha256']:raise ValueError('Texture hash changed')
   filename=meta['sha256']+'.rgba';(inputs/filename).write_bytes(data)
   bundle,name=source_assets[(meta['sha256'],meta['width'],meta['height'])]
   recipe['textures'].append(dict(property=prop,file=filename,width=meta['width'],height=meta['height'],wrap=meta.get('wrap','clamp'),linear=False,bundle='C:\\Illusion\\Koikatsu\\abdata\\'+bundle.replace('/','\\'),asset=name))
   provenance.append(dict(property=prop,sha256=meta['sha256'],source=meta['file']))
  def vector(prop,val):recipe['vectors'].append(dict(property=prop,values=list(map(float,val))))
  texture('_MainTex',entry['main']);texture('_ColorMask',entry['mask'])
  for i,path in enumerate(entry['colors']):vector('_Color'+(str(i+1) if i else ''),get_path(values,path))
  if kind=='head':
   order=[('cheek',4),('lipline',5),('paint',3),('paint',7),('mole',6)]
   for layer,(expected,index) in zip(entry['layers'],order,strict=True):
    if layer['kind']!=expected:raise ValueError('Source layer order changed')
    texture('_Texture'+str(index),layer['textures'][str(get_path(values,layer['selection']))]);vector('_Color'+str(index),get_path(values,layer['color']))
    if 'mask' in layer:texture('_paintmask',layer['mask'])
    if 'transform' in layer:vector('_tex'+str(index)+'uv',layer['transform'])
    if 'layout' in layer:
     x,y,z,w=get_path(values,layer['layout']);v=[.25-.5*x,.3-.6*y,0 if expected=='mole' else 1-2*z,.7*w if expected=='mole' else -8+8.7*w]
     vector('_hokuro' if expected=='mole' else '_paint'+str(1 if index==3 else 2),v)
  else:
   for i,pattern in enumerate(entry['patterns'],1):
    texture('_PatternMask'+str(i),pattern['textures'][str(get_path(values,pattern['selection']))]);vector('_Color'+str(i)+'_2',get_path(values,pattern['color']))
    for axis,value in zip('uv',get_path(values,pattern['tiling']),strict=True):recipe['scalars'].append(dict(property='_PatternScale'+str(i)+axis,value=value))
  recipes.append(recipe)
 config=dict(bundle=r'C:\Illusion\Koikatsu\abdata\chara\mm_base.unity3d',recipes=recipes)
 dump(inputs/'config.json',config);dump(output/'inputs-provenance.json',dict(cardSHA256=digest(card.read_bytes()),textures=provenance))
 with zipfile.ZipFile(output/'inputs.zip','w',zipfile.ZIP_DEFLATED) as z:
  for file in inputs.iterdir():z.write(file,file.name)
 return config

def validate_bundles(vm,config,base,output):
 paths={config['bundle']} | {t['bundle'] for r in config['recipes'] for t in r['textures']}
 rows=[]
 for path in sorted(paths):
  relative=PureWindowsPath(path).relative_to(PureWindowsPath(r'C:\Illusion\Koikatsu\abdata'))
  local=base/'source/abdata'/Path(*relative.parts)
  rows.append(dict(path=path,sha256=digest(local.read_bytes())))
 script="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$records=ConvertFrom-Json "+ps_quote(json.dumps(rows))+";foreach($r in $records){$hash=(Get-FileHash -LiteralPath $r.path -Algorithm SHA256).Hash.ToLower();if($hash -ne $r.sha256){throw ('Original source bundle differs: '+$r.path)}}"
 powershell(vm,script);dump(output/'bundle-provenance.json',dict(schemaVersion=1,bundles=rows))

def input_source(config):
 classes={'recipes':'Recipe','textures':'Input','vectors':'Vector','scalars':'Scalar'}
 def emit(value,kind):
  if isinstance(value,dict):return 'new OriginalShaderProbe.'+kind+' { '+', '.join(k+' = '+emit(v,classes.get(k,'float')) for k,v in value.items())+' }'
  if isinstance(value,list):return 'new '+('float' if kind=='float' else 'OriginalShaderProbe.'+kind)+'[] { '+', '.join(emit(v,kind) for v in value)+' }'
  if isinstance(value,str):return json.dumps(value,ensure_ascii=True)
  if isinstance(value,bool):return 'true' if value else 'false'
  if isinstance(value,int):return str(value)
  if isinstance(value,float):return repr(value)+'f'
  raise ValueError('Unsupported probe parameter')
 return ('internal static class OriginalShaderProbeInputs { public static OriginalShaderProbe.Config Create() { return '+emit(config,'Config')+'; } }\n').encode()

def write_small(vm,path,data):
 encoded=base64.b64encode(gzip.compress(data)).decode();temp=path+'.gzip-base64'
 def run(script):
  for attempt in range(3):
   try:return powershell(vm,script)
   except RuntimeError as error:
    if 'Invalid argument' not in str(error) or attempt==2:raise
    time.sleep(.25)
 for index,start in enumerate(range(0,len(encoded),800)):
  run('[IO.File]::WriteAllText('+ps_quote(temp+'.'+str(index))+','+ps_quote(encoded[start:start+800])+')')
 script="$encoded='';for($i=0;$i -lt "+str((len(encoded)+799)//800)+";$i++){$encoded += [IO.File]::ReadAllText("+ps_quote(temp+'.')+"+$i)};"
 script+="$memory=New-Object IO.MemoryStream(,[Convert]::FromBase64String($encoded));$gzip=New-Object IO.Compression.GZipStream($memory,[IO.Compression.CompressionMode]::Decompress);$file=[IO.File]::Create("+ps_quote(path)+");$gzip.CopyTo($file);$file.Dispose();$gzip.Dispose();$memory.Dispose()"
 run(script)

def user_powershell(vm,script):
 result=subprocess.run(['prlctl','exec',vm,'--current-user','powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],text=True,capture_output=True)
 if result.returncode:raise RuntimeError('Guest user launch failed: '+(result.stderr or result.stdout))
 return result.stdout.lstrip('\ufeff').strip()

def execute(vm,output):
 token=uuid.uuid4().hex;root=r'C:\Temp\IkkokuShaderProbe-'+token;plugin=root+r'\BepInEx\plugins'
 setup="$ErrorActionPreference='Stop';$root="+ps_quote(root)+r";$original='C:\Illusion\Koikatsu';"
 setup+=r'''New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;
foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;
foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};
[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")'''
 powershell(vm,setup);source=Path(__file__).with_name('fixtures')/'OriginalShaderProbe.cs';write_small(vm,root+r'\ShaderProbe.cs',source.read_bytes());write_small(vm,root+r'\ShaderInputs.cs',input_source(json.loads((output/'inputs/config.json').read_text())))
 powershell(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll","$root\CharaStudio_Data\Managed\UnityEngine.dll","$root\CharaStudio_Data\Managed\mscorlib.dll","$root\CharaStudio_Data\Managed\System.dll","$root\CharaStudio_Data\Managed\System.Core.dll");& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuShaderProbe.dll" /reference:$($refs -join ',') "$root\ShaderProbe.cs" "$root\ShaderInputs.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'}''')
 write_small(vm,plugin+r'\config.json',(output/'inputs/config.json').read_bytes())
 pid=int(user_powershell(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','1024','-screen-height','768','-logFile',"$root\unity.log") -PassThru).Id'''))
 dump(output/'run.json',dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),inputConfigSHA256=digest((output/'inputs/config.json').read_bytes()),currentUser=True))
 return root,pid

def fetch(vm,path,limit=32*1024*1024):
 response=json.loads(powershell(vm,"$ErrorActionPreference='Stop';$p="+ps_quote(path)+";$f=Get-Item -LiteralPath $p;if($f.Length -gt "+str(limit)+r'''){throw 'Result exceeds bound'};[PSCustomObject]@{sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower();data=[Convert]::ToBase64String([IO.File]::ReadAllBytes($p))}|ConvertTo-Json -Compress'''))
 data=base64.b64decode(response['data'],validate=True)
 if digest(data)!=response['sha256']:raise ValueError('Transfer hash changed')
 return data

def stop_probe(vm,run):
 root=run['root']
 if not re.fullmatch(r'C:\\Temp\\IkkokuShaderProbe-[0-9a-f]{32}',root):raise ValueError('Unknown probe directory')
 script='$p=Get-Process -Id '+str(int(run['processID']))+' -ErrorAction SilentlyContinue;if($p){if($p.Path -ne '+ps_quote(root+r'\CharaStudio.exe')+"){throw 'Probe process identity changed'};$p|Stop-Process -Force};exit 0"
 for attempt in range(3):
  try:powershell(vm,script);return
  except RuntimeError as error:
   if 'Invalid argument' not in str(error) or attempt==2:raise
   time.sleep(.25)

def collect(vm,root,output):
 plugin=root+r'\BepInEx\plugins';report=json.loads(fetch(vm,plugin+r'\report.json'));dump(output/'original-report.json',report)
 stop_probe(vm,json.loads((output/'run.json').read_text()))
 for result in report.get('results') or []:(output/result['file']).write_bytes(fetch(vm,plugin+'\\'+result['file']))
 for name in ['unity.log',r'BepInEx\LogOutput.log']:
  try:(output/Path(name.replace('\\','/')).name).write_bytes(fetch(vm,root+'\\'+name))
  except RuntimeError:pass
 return report

def compare(output,base):
 oracle=json.loads((base/'expanded-materials/image-oracle.json').read_text());report=json.loads((output/'original-report.json').read_text());rows=[]
 if len(report.get('results') or []) != 2:raise ValueError('Expected both original material captures')
 for source in report.get('results') or []:
  expected=next(r for r in oracle['recipes'] if r['file'].startswith(source['name']+'-'))
  native=np.frombuffer((base/'expanded-materials'/expected['file']).read_bytes(),dtype=np.uint8).reshape(expected['height'],expected['width'],4)
  actual=np.asarray(Image.open(output/source['file']).convert('RGBA'))
  if native.shape!=actual.shape:raise ValueError('Pixel dimensions differ')
  error=np.abs(native.astype(np.int16)-actual.astype(np.int16));rows.append(dict(name=source['name'],pixels=int(native.shape[0]*native.shape[1]),maximumChannelError=int(error.max()),meanAbsoluteChannelError=float(error.mean()),withinOneByteFraction=float((error<=1).mean()),matches=(int(error.max())<=1)))
 result=dict(scope='Exact source catalog textures and settings; original filtering/mips active, sourceLinear native material equation oracle; not character lighting or whole-frame parity',originalColorSpace=report['colorSpace'],results=rows);dump(output/'comparison.json',result);return result

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--base',type=Path,default=ROOT/'.local/reverse/rigs');p.add_argument('--output',type=Path,default=ROOT/'.local/reverse/original-shader-probe');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');args=p.parse_args()
 if not args.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Probe outputs must stay under .local/')
 args.output.mkdir(parents=True,exist_ok=True)
 if args.stop:
  stop_probe(args.vm,json.loads((args.output/'run.json').read_text()));print('Stopped recorded private probe process.');return
 if not args.collect:
  config=prepare(args.base,args.output);validate_bundles(args.vm,config,args.base,args.output);root,pid=execute(args.vm,args.output);print(json.dumps(dict(started=True,root=root,processID=pid)),flush=True);return
 run=json.loads((args.output/'run.json').read_text());report=collect(args.vm,run['root'],args.output)
 if report.get('error'):raise RuntimeError(report['error'])
 print(json.dumps(compare(args.output,args.base),indent=2))
if __name__=='__main__':main()
