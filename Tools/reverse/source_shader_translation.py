#!/usr/bin/env python3
"""Strict bounded DXBC assembly-to-MSL translation for recovered source shaders.

Recovered instructions/assets remain private .local artifacts. Unknown opcodes
fail closed; the generated program preserves float/bit-mask register semantics.
This is a shader-stage translator, not a claim of complete Unity pass parity.
"""
from __future__ import annotations
import argparse, base64, hashlib, json, re, struct
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]

def operands(text):
 result=[];start=0;depth=0
 for i,c in enumerate(text):
  if c=='(':depth+=1
  elif c==')':depth-=1
  elif c==',' and depth==0:result.append(text[start:i].strip());start=i+1
 result.append(text[start:].strip());return result

def read(value):
 if value.startswith('-'):return '(-'+read(value[1:])+')'
 if value.startswith('|') and value.endswith('|'):return 'abs('+read(value[1:-1])+')'
 if value.startswith('abs('):return 'abs('+read(value[4:-1])+')'
 if value.startswith('l('):
  args=[v.strip() for v in value[2:-1].split(',')]
  if len(args)==1:args*=4
  if len(args)!=4:raise ValueError('Invalid literal vector: '+value)
  def literal(v):
   if v.startswith('0x'):return 'as_type<float>(uint('+v+'))'
   return v+('.0' if '.' not in v and 'e' not in v.lower() else '')+'f'
  return 'float4('+','.join(literal(v) for v in args)+')'
 m=re.fullmatch(r'(?:r\d+|v\d+|o\d+|cb\d+\[\d+\])(?:\.([xyzw]+))?',value)
 if not m:raise ValueError('Unsupported operand: '+value)
 suffix=m.group(1)
 if suffix and len(suffix)<4:return 'float4('+value+')' if len(suffix)==1 else value+suffix[-1]*(4-len(suffix))
 return value

def assign(dest,expression,saturate=False):
 m=re.fullmatch(r'([ro]\d+)(?:\.([xyzw]+))?',dest)
 if not m:raise ValueError('Unsupported destination: '+dest)
 lanes=m.group(2) or 'xyzw';expr='saturate('+expression+')' if saturate else expression
 return f'{m.group(1)}.{lanes} = ({expr}).{lanes};'

def translate(assembly,stage):
 if stage not in ['vertex','fragment']:raise ValueError('Unsupported stage')
 lines=[];constants={};inputs={};outputs={};textures={};samplers={};temps=0
 for raw in assembly.splitlines():
  line=raw.strip()
  if not line or line.startswith('//') or re.fullmatch('[pv]s_4_0',line):continue
  op,_,args=line.partition(' ')
  if op=='dcl_constantbuffer':
   m=re.match(r'CB(\d+)\[(\d+)\], immediateIndexed',args)
   if not m:raise ValueError('Unsupported constant buffer')
   constants[int(m[1])]=int(m[2]);continue
  if op=='dcl_temps':temps=int(args);continue
  if op.startswith('dcl_input'):
   m=re.search(r'\bv(\d+)(?:\.([xyzw]+))?',args)
   if not m:raise ValueError('Unsupported input declaration: '+line)
   inputs[int(m[1])]='front' if 'is_front_face' in args else 'position' if 'position' in args else 'varying';continue
  if op.startswith('dcl_output'):
   m=re.search(r'\bo(\d+)',args)
   if not m:raise ValueError('Unsupported output declaration: '+line)
   outputs[int(m[1])]='position' if 'position' in args else 'varying';continue
  if op=='dcl_sampler':
   m=re.fullmatch(r's(\d+), mode_(default|comparison)',args)
   if not m:raise ValueError('Unsupported sampler declaration')
   samplers[int(m[1])]=m[2];continue
  if op=='dcl_resource_texture2d':
   m=re.search(r'\bt(\d+)$',args)
   if not m:raise ValueError('Unsupported texture declaration')
   textures[int(m[1])]='float';continue
  if op=='ret':continue
  if op.startswith('dcl_'):raise ValueError('Unsupported declaration: '+line)
  a=operands(args);sat=op.endswith('_sat');op=op.removesuffix('_sat')
  if op in ['discard_nz','discard_z']:
   lines.append('if (as_type<uint4>('+read(a[0])+').x '+('!=' if op.endswith('nz') else '==')+' 0u) discard_fragment();');continue
  if op=='if_nz':lines.append('if (as_type<uint4>('+read(a[0])+').x != 0u) {');continue
  if op=='else':lines.append('} else {');continue
  if op=='endif':lines.append('}');continue
  if op=='sincos':
   if len(a)!=3:raise ValueError('Invalid sincos arity')
   # DXBC has two independent destinations, either of which can be null.
   # Evaluate the input first in case it aliases either destination register.
   temporary='sincosInput'+str(len(lines))
   lines.append('float4 '+temporary+' = '+read(a[2])+';')
   if a[0]!='null':lines.append(assign(a[0],'sin('+temporary+')'))
   if a[1]!='null':lines.append(assign(a[1],'cos('+temporary+')'))
   continue
  d=a[0];b=[read(x) for x in a[1:]] if op not in ['sample','sample_l','sample_b'] else []
  if op=='mov':expr=b[0]
  elif op=='add':expr=f'{b[0]} + {b[1]}'
  elif op=='mul':expr=f'{b[0]} * {b[1]}'
  elif op=='mad':expr=f'{b[0]} * {b[1]} + {b[2]}'
  elif op in ['min','max']:expr=f'{op}({b[0]}, {b[1]})'
  elif op in ['lt','ge','eq','ne']:
   operator={'lt':'<','ge':'>=','eq':'==','ne':'!='}[op];expr=f'as_type<float4>(select(uint4(0), uint4(0xffffffffu), {b[0]} {operator} {b[1]}))'
  elif op in ['and','or','xor']:
   operator={'and':'&','or':'|','xor':'^'}[op];expr=f'as_type<float4>(as_type<uint4>({b[0]}) {operator} as_type<uint4>({b[1]}))'
  elif op=='movc':expr=f'select({b[2]}, {b[1]}, as_type<uint4>({b[0]}) != uint4(0))'
  elif op in ['dp2','dp3','dp4']:
   suffix={'dp2':'xy','dp3':'xyz','dp4':'xyzw'}[op];expr=f'float4(dot(({b[0]}).{suffix}, ({b[1]}).{suffix}))'
  elif op in ['rsq','sqrt','exp','log','frc','round_ni','round_ne']:
   fn={'rsq':'rsqrt','sqrt':'sqrt','exp':'exp2','log':'log2','frc':'fract','round_ni':'floor','round_ne':'rint'}[op];expr=f'{fn}({b[0]})'
  elif op=='div':expr=f'{b[0]} / {b[1]}'
  elif op in ['sample','sample_l','sample_b']:
   if len(a) not in [4,5]:raise ValueError('Unsupported sample arity')
   coord=read(a[1]);tex=a[2];samp=a[3]
   m=re.fullmatch(r't(\d+)\.([xyzw]{4})',tex)
   if not m or not re.fullmatch(r's\d+',samp):raise ValueError('Unsupported sample operand')
   lod='' if op=='sample' else ', '+('level' if op=='sample_l' else 'bias')+'(('+read(a[4])+').x)'
   expr=f't{m[1]}.sample({samp}, float2(({coord}).x, 1.0 - ({coord}).y){lod}).{m[2]}'
  else:raise ValueError('Unsupported opcode: '+op)
  lines.append(assign(d,expr,sat))
 return dict(stage=stage,constants=constants,inputs=inputs,outputs=outputs,textures=textures,samplers=samplers,temps=temps,body=lines)

def emit_stage(program):
 """Stage body with a stable register ABI; native host supplies cb0...cbN."""
 p=program;stage=p['stage'];parameters=[]
 for index in p['constants']:parameters.append(f'constant float4 *cb{index} [[buffer({index+8})]]')
 for index in p['textures']:parameters.append(f'texture2d<float> t{index} [[texture({index})]]')
 for index in p['samplers']:parameters.append(f'sampler s{index} [[sampler({index})]]')
 params=', '.join(parameters);locals=[]
 for i in range(p['temps']):locals.append(f'float4 r{i} = float4(0);')
 for i in p['outputs']:locals.append(f'float4 o{i} = float4(0);')
 for i,kind in p['inputs'].items():
  source=f'in.v{i}' if stage=='fragment' else f'input[vid].v{i}'
  if kind=='front':source='as_type<float4>(uint4(isFront ? 0xffffffffu : 0u))'
  locals.append(f'float4 v{i} = {source};')
 if stage=='vertex':
  fields=' '.join(f'float4 v{i};' for i in p['inputs'])
  output=' '.join(f'float4 v{i} [[{"position" if kind=="position" else "user(locn"+str(i)+")"}]];' for i,kind in p['outputs'].items())
  text=f'struct SourceInput {{ {fields} }};\nstruct SourceOutput {{ {output} }};\nvertex SourceOutput source_vertex(uint vid [[vertex_id]], device const SourceInput *input [[buffer(0)]], {params}) {{\n'
  end='SourceOutput out; '+ ' '.join(f'out.v{i} = o{i};' for i in p['outputs'])+' return out;'
 else:
  fields=' '.join(f'float4 v{i} [[{"position" if k=="position" else "user(locn"+str(i)+")"}]];' for i,k in p['inputs'].items() if k!='front')
  text=f'struct SourceFragmentInput {{ {fields} }};\nfragment float4 source_fragment(SourceFragmentInput in [[stage_in]], bool isFront [[front_facing]], {params}) {{\n';end='return o0;'
 return text+'\n'.join('    '+s for s in locals+p['body']+[end])+'\n}\n'

def disassemble(blob,path,vm):
 from original_shader_probe import write_small
 from vm_source import powershell,ps_quote
 remote=r'C:\Temp\IkkokuShaderStage-'+hashlib.sha256(blob).hexdigest()+'.dxbc'
 write_small(vm,remote,blob)
 bridge="""using System;using System.Runtime.InteropServices;
public static class IkkokuStageDisasm {
[DllImport("d3dcompiler_47.dll")] static extern int D3DDisassemble(byte[] b,UIntPtr n,uint f,string c,out IntPtr o);
[UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr PtrFunc(IntPtr p);
[UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate UIntPtr SizeFunc(IntPtr p);
public static string Read(byte[] b){IntPtr p;int hr=D3DDisassemble(b,(UIntPtr)b.Length,0,null,out p);if(hr<0)Marshal.ThrowExceptionForHR(hr);try{IntPtr vt=Marshal.ReadIntPtr(p);var ptr=(PtrFunc)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt,3*IntPtr.Size),typeof(PtrFunc));var size=(SizeFunc)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt,4*IntPtr.Size),typeof(SizeFunc));int n=(int)size(p).ToUInt64();byte[] o=new byte[n];Marshal.Copy(ptr(p),o,0,n);return Convert.ToBase64String(o);}finally{Marshal.Release(p);}}}"""
 script="$ErrorActionPreference='Stop';Add-Type -TypeDefinition "+ps_quote(bridge)+";[IkkokuStageDisasm]::Read([IO.File]::ReadAllBytes("+ps_quote(remote)+"))"
 for attempt in range(3):
  try:result=powershell(vm,script);break
  except RuntimeError:
   if attempt==2:raise
   time.sleep(.5)
 path.write_text(base64.b64decode(result,validate=True).decode('ascii').rstrip('\x00'))
 powershell(vm,'[IO.File]::Delete('+ps_quote(remote)+')')

def extract(bundle,material,output,vm,pass_name="FORWARD"):
 import UnityPy
 from UnityPy.export.ShaderConverter import ShaderProgram
 from UnityPy.helpers import CompressionHelper
 from UnityPy.streams import EndianBinaryReader
 env=UnityPy.load(str(bundle));materials=[o for o in env.objects if o.type.name=='Material' and o.peek_name()==material]
 if len(materials)!=1:raise ValueError('Expected exact material identity')
 pointer=materials[0].read().m_Shader;shader=pointer.read();tree=pointer.read_typetree()
 raw=CompressionHelper.decompress_lz4(bytes(shader.compressedBlob)[shader.offsets[0]:shader.offsets[0]+shader.compressedLengths[0]],shader.decompressedLengths[0])
 program=ShaderProgram(EndianBinaryReader(raw,endian='<'),shader.object_reader.version)
 forward=next(p for p in tree['m_ParsedForm']['m_SubShaders'][0]['m_Passes'] if p['m_State']['m_Name']==pass_name)
 names={index:name for name,index in forward['m_NameIndices']};result=dict(schemaVersion=1,name=tree['m_ParsedForm']['m_Name'],bundleSHA256=hashlib.sha256(bundle.read_bytes()).hexdigest(),material=material,passState=forward['m_State'],properties=tree['m_ParsedForm']['m_PropInfo']['m_Props'],programs={},names=names)
 source='#include <metal_stdlib>\nusing namespace metal;\n'
 for stage,key in [('vertex','progVertex'),('fragment','progFragment')]:
  sub=forward[key]['m_SubPrograms'][0];index=sub['m_BlobIndex'];code=bytes(program.m_SubPrograms[index].m_ProgramCode);start=code.find(b'DXBC');length=struct.unpack_from('<I',code,start+24)[0];blob=code[start:start+length]
  path=output/(stage+'.asm');binary_path=output/(stage+'.dxbc')
  cached_identity=binary_path.exists() and binary_path.read_bytes()==blob
  binary_path.write_bytes(blob)
  sha=hashlib.sha256(blob).hexdigest()
  if not path.exists() or not cached_identity:disassemble(blob,path,vm)
  translated=translate(path.read_text(),stage);source+=emit_stage(translated)
  semantics={};signature=path.read_text().split('// Input signature:',1)[1].split('// Output signature:',1)[0]
  for match in re.finditer(r'^//\s+(\w+)\s+(\d+)\s+([xyzw]+)\s+(\d+)\s+',signature,re.MULTILINE):semantics[int(match[4])]=dict(name=match[1],index=int(match[2]),mask=match[3])
  result['programs'][stage]=dict(metadata=sub,sha256=sha,inputSemantics=semantics,registers={k:v for k,v in translated.items() if k!='body'},keywords=program.m_SubPrograms[index].m_Keywords)
 (output/'source.metal').write_text(source);result['sourceMSLSHA256']=hashlib.sha256(source.encode()).hexdigest();(output/'program.json').write_text(json.dumps(result,indent=2)+'\n')
 return result

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bundle',type=Path,required=True);p.add_argument('--material',required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--vm',default='Windows 11');p.add_argument('--pass-name',default='FORWARD');a=p.parse_args()
 if not a.output.resolve().is_relative_to(ROOT/'.local'):raise ValueError('Derived shaders must remain private .local')
 a.output.mkdir(parents=True,exist_ok=True);r=extract(a.bundle,a.material,a.output,a.vm,a.pass_name);print(json.dumps({'shader':r['name'],'programs':{k:v['sha256'] for k,v in r['programs'].items()}},indent=2))
if __name__=='__main__':main()
