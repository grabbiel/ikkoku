#!/usr/bin/env python3
"""Add bounded native appearance recipes to exported catalog components."""
from pathlib import Path
import argparse,json,hashlib,struct
import numpy as np
from PIL import Image
from card_appearance_bindings import raw_texture
from clothed_material_contract import PROGRAMS,hair_base,clothes_base
from maker_material_contract import expand,dump,sample

ROOT=Path(__file__).resolve().parents[2]
def sha(data):return hashlib.sha256(data).hexdigest()
def linear(c):return [v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in c[:3]]+[c[3]]

def verify_hair(root,meta):
 from UnityPy.export.ShaderConverter import ShaderProgram
 from UnityPy.helpers import CompressionHelper
 from UnityPy.streams import EndianBinaryReader
 data=(root/meta['file']).read_bytes()
 if sha(data)!=meta['sha256']:raise ValueError('Shader evidence changed')
 tree=json.loads(data);name=tree['m_ParsedForm']['m_Name']
 if tree['platforms']!=[4]:raise ValueError('Unrecovered hair platform')
 raw=CompressionHelper.decompress_lz4(bytes(tree['compressedBlob'])[tree['offsets'][0]:tree['offsets'][0]+tree['compressedLengths'][0]],tree['decompressedLengths'][0])
 program=ShaderProgram(EndianBinaryReader(raw,endian='<'),(5,6,2,1))
 forward=next(p for p in tree['m_ParsedForm']['m_SubShaders'][0]['m_Passes'] if p['m_State']['m_Name']=='FORWARD')
 index=forward['progFragment']['m_SubPrograms'][0]['m_BlobIndex'];code=bytes(program.m_SubPrograms[index].m_ProgramCode);start=code.find(b'DXBC');size=struct.unpack_from('<I',code,start+24)[0]
 if PROGRAMS.get(name)!=sha(code[start:start+size]):raise ValueError('Unknown hair shader program')


def build(root):
 index_path=root/'library.json';index=json.loads(index_path.read_text());updates={}
 # Original pattern catalog was independently extracted by maker_material_contract.
 catalog=json.loads((ROOT/'.local/reverse/rigs/expanded-materials/source-material-catalog.json').read_text())
 textures={};inputs=root/'material-inputs';inputs.mkdir(exist_ok=True)
 for row in catalog['entries']:
  if row['kind']!='pattern':continue
  meta=dict(row['texture']);data=(ROOT/'.local/reverse/rigs/expanded-materials'/meta['file']).read_bytes()
  if sha(data)!=meta['sha256']:raise ValueError('Pattern evidence changed')
  name=Path(meta['file']).name;(inputs/name).write_bytes(data);meta['file']='material-inputs/'+name;textures[str(row['id'])]=meta
 for entry in index['entries']:
  if 'materialEvidence' not in entry:continue
  evidence=(root/entry['materialEvidence']['file']).read_bytes()
  if sha(evidence)!=entry['materialEvidence']['sha256']:raise ValueError('Material evidence changed')
  source=json.loads(evidence);category=entry['category'];identifier=entry['id'];parts=[];bindings=[];limits=[]
  for renderer in source['renderers']:
   part=renderer['meshName']+'/0';material=renderer['material'];shader=material['shader'];colors=material['colors'];slot=renderer['materialSlot']
   native=dict(part=part,kind='unlit',color=linear(colors.get('_Color',[1,1,1,1])),alphaMode='OPAQUE',outline=False,pass_=slot)
   native['pass']=native.pop('pass_')
   recipe=dict(parts=[part],pass_=slot,requirements={},resolverProperties=[]);recipe['pass']=recipe.pop('pass_')
   def texture(meta):
    path=root/meta['file'];result=raw_texture(path,meta['sha256'],root);return result
   def pixels(meta):return np.asarray(Image.open(root/meta['file']).convert('RGBA'),dtype=np.float32)/255
   bake=None
   if category in [101,102] and shader in ['Shader Forge/main_hair','Shader Forge/main_hair_front']:
    verify_hair(root,renderer['shaderTree']);hair_slot=category-101
    mask=renderer['textures'].get('_ColorMask')
    if not mask:raise ValueError('Hair color mask unavailable')
    if mask['scale']!=[1.0,1.0] or mask['offset']!=[0.0,0.0]:raise ValueError('Unrecovered hair UV transform')
    if any(renderer['textures'].get(k) for k in ['_MainTex','_AlphaMask']):raise ValueError('Non-white hair texture requires conversion')
    tint=np.asarray([colors.get(k,[1,1,1,1]) for k in ['_Color','_Color2','_Color3']],dtype=np.float32);bake=hair_base(pixels(mask),tint)
    recipe.update(kind='hair',colors=[f'hair.parts.{hair_slot}.{k}' for k in ['baseColor','startColor','endColor']],mask=texture(mask),requirements={f'hair.parts.{hair_slot}.id':identifier},resolverProperties=['ChaFileHair.'+['HairBack','HairFront'][hair_slot]])
    native.update(kind='hair',color=[1,1,1,1],outline=True)
   elif category in [105,106,112] and shader=='Shader Forge/main_opaque':
    clothes_slot={105:0,106:1,112:8}[category];scope={105:'ClothesTop',106:'ClothesBot',112:'ClothesShoesOuter'}[category]
    main=source['catalogTextures'].get('main');mask=source['catalogTextures'].get('mask')
    if not main or not mask:raise ValueError('Clothing create inputs missing')
    tint=np.asarray([colors.get(k,[1,1,1,1]) for k in ['_Color','_Color2','_Color3']],dtype=np.float32)
    main_pixels=pixels(main);mask_pixels=pixels(mask)
    if main_pixels.shape!=mask_pixels.shape:
     h,w,_=main_pixels.shape;xx,yy=np.meshgrid((np.arange(w)+.5)/w,1-(np.arange(h)+.5)/h);mask_pixels=sample(mask_pixels,np.stack([xx,yy],axis=-1))
    bake=clothes_base(main_pixels,mask_pixels,tint)
    prefix=f'clothes.parts.{clothes_slot}.colorInfo.'
    recipe.update(kind='clothes',colors=[prefix+f'{i}.baseColor' for i in range(3)],main=texture(main),mask=texture(mask),requirements={f'clothes.parts.{clothes_slot}.id':identifier,f'clothes.parts.{clothes_slot}.emblemeId':0},resolverProperties=['outfit{coordinate}.ChaFileClothes.'+scope],patterns=[dict(selection=prefix+f'{i}.pattern',color=prefix+f'{i}.patternColor',tiling=prefix+f'{i}.tiling',resolverProperties=['outfit{coordinate}.ChaFileClothes.'+scope+'Pattern'+str(i)],textures=textures) for i in range(3)])
    native.update(kind='cloth',color=[1,1,1,1],specularStrength=0,rimStrength=0)
   else:
    limits.append(f'{part}: {shader} retained as authored flat-color preview; original shader and accessory coloring not converted.')
    if 'lens' in renderer['meshName']:
     native['color'][3]=.25;native['alphaMode']='BLEND'
   if bake is not None:
    filename=f'material-inputs/{category}-{identifier}-{renderer["meshName"]}-{slot}.png';Image.fromarray(np.rint(np.clip(bake,0,1)*255).astype(np.uint8)).save(root/filename);native['texture']=filename;bindings.append(recipe)
   parts.append(native)
  # Component evidence can have repeated records for material slots; reject actual collisions.
  if len({(p['part'],p['pass']) for p in parts})!=len(parts):raise ValueError('Duplicate component material slot')
  appearance=root/f'appearance-{category}-{identifier}.json';card=root/f'bindings-{category}-{identifier}.json'
  dump(appearance,dict(schemaVersion=1,parts=parts))
  dump(card,dict(schemaVersion=1,entries=bindings,limitations=limits+['Recovered albedo and catalog IDs only; source lighting and arbitrary plugin shaders remain incomplete.']))
  fields=dict(appearance=dict(file=appearance.name,sha256=sha(appearance.read_bytes())),cardBindings=dict(file=card.name,sha256=sha(card.read_bytes())))
  if 'bodyMask' in source['catalogTextures']:
   body=source['catalogTextures']['bodyMask'];fields['bodyMask']={k:body[k] for k in ['file','sha256']}
  updates[(category,identifier)]=fields
 # Re-read to retain concurrently completed rig hashes and assembly records.
 current=json.loads(index_path.read_text())
 for entry in current['entries']:entry.update(updates.get((entry['category'],entry['id']),{}))
 dump(index_path,current)
 print(json.dumps(dict(materialEntries=len(updates),library=str(index_path))))
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',nargs='?',type=Path,default=ROOT/'.local/reverse/maker-library');args=p.parse_args()
 if not args.root.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Source-derived outputs must stay in .local/')
 build(args.root)
