#!/usr/bin/env python3
"""Compare source-player draw-material bindings against the native derivation.

Native side: the JSON emitted by `ikkoku-inspect draw-overlays` (catalog IDs and
colors derived from the card alone). Original side: the controlled capture's
`frame.json` materials `cf_m_face_00`, `cf_m_body` and `cf_m_hitomi_00`.
Per slot: color must be exact within 1e-6, texture identity must name the same
asset, and the blush slot compares alpha only because its RGB is prefab data.
This compares recorded evidence; it neither loads the textures nor renders them.
"""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path

# Source record slots keyed by binding material; the eye material appears twice
# (left and right eye), so every material that binds a slot must agree.
SEARCH={'face':'cf_m_face_00','body':'cf_m_body','eye':'cf_m_hitomi_00'}
SLOTS=[('face','overtex1'),('face','overtex2'),('face','overtex3'),
       ('body','overtex1'),('body','overtex2'),
       ('eye','overtex1'),('eye','overtex2')]

def original_values(frame,material,slot):
 """Collect (texture name, [r,g,b,a]) per original material binding this slot."""
 name=SEARCH[material];slot_number=int(slot[len('overtex'):])
 texture_key=f'_overtex{slot_number}';color_key=f'_overcolor{slot_number}'
 textures={entry['file']:entry['name'] for entry in frame['textures']}
 values=[]
 for mesh in frame['meshes']:
  for material_data in mesh['materials']:
   if not material_data['name'].startswith(name):continue
   properties=material_data.get('properties') or {}
   if color_key not in properties:continue
   texture=(textures.get(properties[texture_key]['file'])
            if texture_key in properties else 'prefab')
   values.append((texture,[float(v) for v in properties[color_key]]))
 return values

def compare(draw,frame,catalog,provenance):
 """Report each record slot plus the hashes of the inputs compared."""
 result={'schemaVersion':1,'provenance':provenance,'slots':[],'unmatchedSlots':[]}
 for material,slot in SLOTS:
  binding=next((b for b in draw['bindings'] if b['material']==material and b['slot']==slot),None)
  original=original_values(frame,material,slot)
  if binding is None:
   if original:
    result['unmatchedSlots'].append({'material':material,'slot':slot,
     'reason':'the original material binds this slot but the native derivation does not'})
   continue
  if not original:
   result['unmatchedSlots'].append({'material':material,'slot':slot,'id':binding['id'],
    'reason':'the native derivation binds this slot but no original material does'})
   continue
  native_color=[float(v) for v in binding['rgba']]
  if binding.get('rgbFromPrefab'):
   # The comparison uses the recorded binding: RGB comes from the same prefab
   # material on both sides, so only the card-sourced alpha is gated and the
   # prefab texture name in the capture is preserved as evidence only.
   result['slots'].append({'material':material,'slot':slot,'category':binding['category'],
    'id':binding['id'],'rgbSource':'prefab','alphaOnlyComparison':True,
    'expectedColor':native_color,'capturedColor':original[0][1],
    'expectedTexture':'prefab','capturedTexture':original[0][0],
    'textureMatch':True,'colorMatch':all(abs(native_color[3]-c[3])<=1e-6 for _,c in original),
    'passes':all(abs(native_color[3]-c[3])<=1e-6 for _,c in original)})
   continue
  entry=next((entry for key,entry in catalog['tables'].items()
              if key.startswith(binding['category']+'_')),None)
  if entry is None:
   result['slots'].append({'material':material,'slot':slot,'category':binding['category'],
    'id':binding['id'],'rgbSource':'card','alphaOnlyComparison':False,
    'reason':'the source catalog lists no entry for this binding id',
    'expectedTexture':None,'capturedTexture':original[0][0],'textureMatch':False,
    'expectedColor':native_color,'capturedColor':original[0][1],'colorMatch':True,
    'passes':False})
   continue
  if int(entry['id']) != int(binding['id']):
   result['slots'].append({'material':material,'slot':slot,'category':binding['category'],
    'id':binding['id'],'rgbSource':'card','alphaOnlyComparison':False,
    'reason':f"native binding id {int(binding['id'])} differs from the captured catalog id {int(entry['id'])}",
    'expectedTexture':entry['texture'],'capturedTexture':original[0][0],
    'textureMatch':False,'expectedColor':native_color,'capturedColor':original[0][1],
    'colorMatch':all(all(abs(e-o)<=1e-6 for e,o in zip(native_color,o_color))
                     for _,o_color in original),
    'passes':False})
   continue
  # The right and left eye bind the same slot through duplicate materials; any
  # disagreement between the two is a mismatch even if one side matches.
  texture_checks=[o_name==entry['texture'] for o_name,_ in original]
  color_checks=[[abs(e-o)<=1e-6 for e,o in zip(native_color,o_color)]
                for _,o_color in original]
  result['slots'].append({'material':material,'slot':slot,'category':binding['category'],
   'id':binding['id'],'rgbSource':'card','alphaOnlyComparison':False,
   'expectedColor':native_color,'capturedColor':original[0][1],
   'expectedTexture':entry['texture'],'capturedTexture':original[0][0],
   'textureMatch':all(texture_checks),'colorMatch':all(all(c) for c in color_checks),
   'passes':all(texture_checks) and all(all(c) for c in color_checks)})
 checked=[slot for slot in result['slots'] if 'passes' in slot]
 result['passes']=all(slot['passes'] for slot in checked) and not result['unmatchedSlots']
 return result

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('capture',type=Path,help='controlled capture directory with frame.json')
 p.add_argument('draw',type=Path,help='JSON emitted by ikkoku-inspect draw-overlays')
 p.add_argument('catalog',type=Path,help='chosen source catalog IDs per source table')
 p.add_argument('--out',type=Path)
 args=p.parse_args()
 frame_path=args.capture/'frame.json'
 frame=json.loads(frame_path.read_text())
 draw=json.loads(args.draw.read_text())
 catalog=json.loads(args.catalog.read_text())
 card=args.capture/'fixture-card.png'
 if not frame.get('meshes') or not draw.get('bindings') or not catalog.get('tables'):
  raise ValueError('Missing frame meshes, native bindings or catalog tables')
 report=compare(draw,frame,catalog,{
  'frame.json':hashlib.sha256(frame_path.read_bytes()).hexdigest(),
  card.name:hashlib.sha256(card.read_bytes()).hexdigest()})
 out=args.out or args.capture/'draw-overlay-comparison.json'
 out.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
 print(json.dumps({k:report[k] for k in ('slots','unmatchedSlots','provenance','passes')},indent=2))
if __name__=='__main__':main()
