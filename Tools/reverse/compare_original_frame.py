#!/usr/bin/env python3
"""Compare a controlled original-player fixture against the exact native capture.

Geometry, depth/normals and shaded color are separate gates. A geometry pass does
not imply native rig parity or source lighting parity. No image registration,
resizing, recoloring, or camera fitting is performed during comparison.
"""
from __future__ import annotations
import argparse,hashlib,json
from pathlib import Path
import numpy as np
from PIL import Image

def geometry_metrics(original,native):
 if original.shape!=native.shape:raise ValueError('Matched frames require equal dimensions')
 intersection=original&native;union=original|native
 if not union.any():raise ValueError('Empty silhouette cannot establish parity')
 iou=float(intersection.sum()/union.sum());difference=int((original^native).sum())
 return dict(originalPixels=int(original.sum()),nativePixels=int(native.sum()),intersectionOverUnion=iou,differingPixels=difference,tolerance=dict(minimumIoU=.999),passes=iou>=.999)

def depth_metrics(original,native,mask,far):
 if original.shape!=native.shape or original.shape[:2]!=mask.shape or not mask.any():raise ValueError('Invalid depth comparison extent')
 a=original.astype(np.float64)/255;b=native.astype(np.float64)/255
 source=(a[:,:,2]+a[:,:,3]/255)*far;target=(b[:,:,2]+b[:,:,3]/255)*far
 error=np.abs(source-target)[mask];normals=np.abs(original.astype(np.int16)[:,:,:2]-native.astype(np.int16)[:,:,:2])[mask]
 tolerance=2*far/65025 # Unity EncodeFloatRG quantization, two least-significant steps.
 p99=float(np.percentile(error,99))
 return dict(comparedPixels=int(mask.sum()),meanMetres=float(error.mean()),p99Metres=p99,maximumMetres=float(error.max()),normalMeanChannelBytes=float(normals.mean()),normalP99ChannelBytes=float(np.percentile(normals,99)),tolerance=dict(depthP99Metres=tolerance,normalP99ChannelBytes=2),passes=p99<=tolerance and float(np.percentile(normals,99))<=2)

def color_metrics(original,native,mask):
 if original.shape!=native.shape or not mask.any():raise ValueError('Invalid color comparison extent')
 error=np.abs(original.astype(np.int16)[:,:,:3]-native.astype(np.int16)[:,:,:3])[mask]
 mae=float(error.mean());p99=float(np.percentile(error,99))
 return dict(comparedPixels=int(mask.sum()),meanAbsoluteChannelBytes=mae,p99ChannelBytes=p99,maximumChannelBytes=int(error.max()),withinTwoBytesFraction=float((error<=2).mean()),tolerance=dict(maximumMeanAbsoluteChannelBytes=1,maximumP99ChannelBytes=4),passes=mae<=1 and p99<=4)

def compare(folder):
 native=json.loads((folder/'native-report.json').read_text());filename=native.get('sourceFrameFile','frame.json')
 if Path(filename).name!=filename or filename.startswith('.'):raise ValueError('Invalid source frame path')
 frame_path=folder/filename;frame=json.loads(frame_path.read_text())
 if native.get('sourceFrameSHA256')!=hashlib.sha256(frame_path.read_bytes()).hexdigest():raise ValueError('Native report does not identify this exact source capture')
 def pixels(name):
  result=np.asarray(Image.open(folder/name).convert('RGBA'))
  if result.shape!=(frame['height'],frame['width'],4):raise ValueError('Capture dimensions differ from source camera')
  return result
 a=pixels('original-geometry.png')[:,:,0]>128;b=pixels('native-geometry.png')[:,:,0]>128;mask=a&b
 result=dict(schemaVersion=1,scope='Frozen original source-evaluated clothed geometry and camera. Does not validate native rig/animation evaluation, live card loading, or Studio scene parity.',sourceFrameSHA256=native['sourceFrameSHA256'],geometry=geometry_metrics(a,b),depthNormals=depth_metrics(pixels('original-depth-normals.png'),pixels('native-depth-normals.png'),mask,frame['camera']['far']),color=color_metrics(pixels('original-color.png'),pixels('native-color.png'),mask),materialDiagnostics=native['materialDiagnostics'],nativeBenchmark=json.loads((folder/'native-benchmark.json').read_text()))
 if frame.get('authoredMipProvenance'):
  provenance=frame['authoredMipProvenance'];name=provenance['originalFrame']
  if Path(name).name!=name or name.startswith('.') or hashlib.sha256((folder/name).read_bytes()).hexdigest()!=provenance['originalFrameSHA256']:raise ValueError('Derived mip frame no longer identifies the original capture')
  result['authoredMipProvenance']=provenance
 for label,source_name,native_name in [('translatedGarments','original-main_opaque.png','native-main_opaque.png'),('translatedCharacter','original-color.png','native-translated.png')]:
  if not (folder/native_name).exists():continue
  source=pixels(source_name);target=pixels(native_name);source_alpha=source[:,:,3]>0;target_alpha=target[:,:,3]>0
  result[label]=dict(scope='Original source shader programs, original frozen geometry, source render queues/pass states and material bindings; native rig evaluation not included.',silhouette=geometry_metrics(source_alpha,target_alpha),color=color_metrics(source,target,source_alpha&target_alpha))
  result[label]['passes']=result[label]['silhouette']['passes'] and result[label]['color']['passes']
 result['mipCoverage']=dict(textures=len(frame['textures']),authored=sum(bool(t.get('mipFiles')) for t in frame['textures']),noMips=sum(t.get('mipLevels')==1 for t in frame['textures']),generated=sum(t.get('mipLevels',1)>1 and not t.get('mipFiles') for t in frame['textures']))
 result['passesAllGates']=all(result[k]['passes'] for k in ['geometry','depthNormals','color'])
 (folder/'frame-comparison.json').write_text(json.dumps(result,indent=2)+'\n');return result

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('folder',type=Path);a=p.parse_args();r=compare(a.folder);print(json.dumps({k:v for k,v in r.items() if k not in ['materialDiagnostics','nativeBenchmark']},indent=2))
if __name__=='__main__':main()
