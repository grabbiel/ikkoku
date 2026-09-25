#!/usr/bin/env python3
"""Recover authored texture mip chains for the controlled original frame.

Only textures with an unambiguous asset identity and a decoded base level that
matches the actual original GPU readback are accepted. Derived frame metadata
and decoded pixels stay private; the original capture is never overwritten.
"""
from __future__ import annotations
import argparse,hashlib,json,math
from pathlib import Path
import numpy as np
import UnityPy
from UnityPy.export.Texture2DConverter import parse_image_data
ROOT=Path(__file__).resolve().parents[2]

def level_bytes(width,height,format):
 # Unity 5.6 formats used in these bundles. Unknown encodings fail explicitly.
 if format in [10,12,24,25]:return max(1,(width+3)//4)*max(1,(height+3)//4)*(8 if format==10 else 16)
 if format in [1,3,4,5,7,9]:return width*height*{1:1,3:3,4:4,5:4,7:2,9:2}[format]
 raise ValueError('Unsupported source mip format '+str(format))

def recover(frame_path,bundles):
 frame=json.loads(frame_path.read_text());folder=frame_path.parent;assets={};identities=[]
 for bundle in bundles:
  digest=hashlib.sha256(bundle.read_bytes()).hexdigest()
  identities.append(dict(path=str(bundle),sha256=digest))
  for obj in UnityPy.load(str(bundle)).objects:
   if obj.type.name!='Texture2D':continue
   texture=obj.read();key=(texture.m_Name,texture.m_Width,texture.m_Height)
   assets.setdefault(key,[]).append((texture,digest,obj.path_id))
 records=[]
 for row in frame['textures']:
  if row.get('textureType')!='Texture2D' or row.get('mipLevels',1)<=1:continue
  key=(row['name'],row['width'],row['height']);candidates=assets.get(key,[])
  if not candidates:records.append(dict(file=row['file'],status='source asset not supplied'));continue
  # Duplicated identical source textures in separate bundles are acceptable.
  unique={hashlib.sha256(t.get_image_data()).hexdigest():(t,d,p) for t,d,p in candidates}
  if len(unique)!=1:raise ValueError('Ambiguous authored texture identity '+row['name'])
  texture,bundle_hash,path_id=next(iter(unique.values()));data=texture.get_image_data();format=texture.m_TextureFormat
  original=np.frombuffer((folder/row['file']).read_bytes(),dtype='<f2').reshape(row['height'],row['width'],4).astype(np.float32)
  decoded=np.asarray(parse_image_data(data,row['width'],row['height'],format,texture.object_reader.version,texture.object_reader.platform,flip=False).convert('RGBA'),dtype=np.float32)/255
  linear=decoded.copy();linear[:,:,:3]=np.where(decoded[:,:,:3]<=.04045,decoded[:,:,:3]/12.92,((decoded[:,:,:3]+.055)/1.055)**2.4)
  options=[('linear',decoded),('srgb',linear)]
  errors=[float(np.mean(np.abs(p-original))) for _,p in options];choice=int(np.argmin(errors));space=options[choice][0]
  max_error=float(np.max(np.abs(options[choice][1]-original)))
  if errors[choice]>.002 or max_error>.02:raise ValueError('Authored base does not match original GPU '+row['name']+': '+str((errors,max_error)))
  width,height=row['width'],row['height'];offset=level_bytes(width,height,format);files=[row['file']]
  for level in range(1,row['mipLevels']):
   width=max(1,width//2);height=max(1,height//2);count=level_bytes(width,height,format)
   if offset+count>len(data):raise ValueError('Truncated authored mip chain')
   pixels=np.asarray(parse_image_data(data[offset:offset+count],width,height,format,texture.object_reader.version,texture.object_reader.platform,flip=False).convert('RGBA'),dtype=np.float32)/255
   if space=='srgb':pixels[:,:,:3]=np.where(pixels[:,:,:3]<=.04045,pixels[:,:,:3]/12.92,((pixels[:,:,:3]+.055)/1.055)**2.4)
   name=Path(row['file']).stem+'-mip-'+str(level)+'.rgba16f';(folder/name).write_bytes(pixels.astype('<f2').tobytes());files.append(name);offset+=count
  row['mipFiles']=files
  row['authoredMipSource']=dict(bundleSHA256=bundle_hash,pathID=path_id,dataSHA256=next(iter(unique)),decodedColorSpace=space,baseMeanError=errors[choice],baseMaximumError=max_error)
  records.append(dict(file=row['file'],status='authored mip chain recovered',**row['authoredMipSource']))
 frame['authoredMipProvenance']=dict(originalFrame=frame_path.name,originalFrameSHA256=hashlib.sha256(frame_path.read_bytes()).hexdigest(),bundles=identities,records=records)
 output=folder/'frame-mips.json';output.write_text(json.dumps(frame,indent=2)+'\n');return dict(frame=str(output),textures=records)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('frame',type=Path);p.add_argument('bundles',type=Path,nargs='+');a=p.parse_args()
 if not a.frame.resolve().is_relative_to(ROOT/'.local'):raise ValueError('Derived source artifacts must stay private')
 print(json.dumps(recover(a.frame,a.bundles),indent=2))
if __name__=='__main__':main()
