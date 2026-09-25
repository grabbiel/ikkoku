#!/usr/bin/env python3
"""Build bounded, catalog-guarded card-color recipes and independent local fixtures.

All original PNGs, raw RGBA pixels, and source-format synthetic cards remain in
ignored .local/. Input images are previously selected safe face/clothing/hair
textures; card thumbnails are never decoded or copied into the synthetic cards.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

import msgpack
import numpy as np
from PIL import Image
from head_material_contract import create_head_base, create_eye_base, create_eye_white, VERIFIED_PROGRAMS
from clothed_material_contract import clothes_base, hair_base, PROGRAMS
sys.path.insert(0, str(Path(__file__).parent/'analysis'))
from card_contract import blank_png, dotnet_string, MAGIC, VERSIONS, parse_card

ROOT=Path(__file__).resolve().parents[2]


def digest(data):return hashlib.sha256(data).hexdigest()
def dump(path,value):path.write_text(json.dumps(value,indent=2,allow_nan=False)+'\n')
def pack(value):return msgpack.packb(value,use_bin_type=True,use_single_float=True)
def length(data):return struct.pack('<i',len(data))+data


def synthetic_card(custom,clothes,sex):
    makeup=custom['face']['baseMakeup']
    coordinate=length(pack(clothes))+length(pack({'version':'0.0.2','parts':[]}))+b'\x00'+length(pack(makeup))
    payloads=[('Custom','0.0.0',b''.join(length(pack(custom[k])) for k in ['face','body','hair'])),
              ('Coordinate','0.0.0',pack([coordinate]*7)),
              ('Parameter','0.0.5',pack({'version':'0.0.5','sex':sex,'exType':0,'firstname':'Appearance','lastname':'Synthetic','nickname':'Fixture'})),
              ('Status','0.0.0',pack({'version':'0.0.0','coordinateType':0,'clothesState':[0]*9})),
              ('FixtureUnknown','1',b'preserve-opaque-fixture-appearance\x00\xff')]
    payload=b'';infos=[]
    for name,version,data in payloads:
        infos.append(dict(name=name,version=version,pos=len(payload),size=len(data)));payload+=data
    header=pack({'lstInfo':infos})
    return blank_png()+struct.pack('<i',100)+dotnet_string(MAGIC)+dotnet_string(VERSIONS['card'])+length(b'')+length(header)+struct.pack('<q',len(payload))+payload


def get_path(records,path):
    value=records
    for key in path.split('.'):
        value=value[int(key)] if isinstance(value,list) else value[key]
    return value


def raw_texture(path,expected_sha,output):
    data=path.read_bytes()
    if digest(data)!=expected_sha:raise ValueError('Source PNG SHA-256 mismatch: '+str(path))
    with Image.open(path) as image:
        width,height=image.size
        if not 0<width<=4096 or not 0<height<=4096 or width*height>4_194_304:
            raise ValueError('Source texture exceeds native bound')
        pixels=image.convert('RGBA').tobytes()
    name=path.stem+'.rgba';folder=output/'card-appearance-inputs';folder.mkdir(exist_ok=True)
    (folder/name).write_bytes(pixels)
    return dict(file='card-appearance-inputs/'+name,sha256=digest(pixels),width=width,height=height)


def verify_programs(rows,directory,expected):
    for row in rows:
        if expected.get(row['shader'])!=row['programSHA256']:
            raise ValueError('Unverified recovered source shader: '+row['shader'])
        path=directory/row['file']
        if not path.resolve().is_relative_to(directory.resolve()) or digest(path.read_bytes())!=row['programSHA256']:
            raise ValueError('Source shader bytecode no longer matches its evidence')


def fixture_records(contract,hair_ids):
    makeup=dict(version='0.0.0',eyeshadowId=0,cheekId=0,lipId=0,paintId=[0,0])
    face=dict(version='0.0.2',headId=0,skinId=0,detailId=0,eyebrowId=0,noseId=0,hlUpId=0,hlDownId=0,whiteId=0,
              eyelineUpId=0,eyelineDownId=0,moleId=0,lipLineId=0,baseMakeup=makeup,
              eyebrowColor=[.22,.13,.1,1],eyelineColor=[.14,.08,.06,1],whiteBaseColor=[1,1,1,1],whiteSubColor=[.78,.84,.93,1],
              hlUpColor=[1,.92,.8,1],hlDownColor=[.8,.93,1,1],
              pupil=[dict(id=0,gradMaskId=0,gradBlend=.25,gradOffsetY=.5,gradScale=.5,baseColor=[.3,.48,.68,1],subColor=[.4,.2,.3,1]),
                     dict(id=0,gradMaskId=0,gradBlend=.6,gradOffsetY=.5,gradScale=.5,baseColor=[.5,.3,.2,1],subColor=[.4,.2,.3,1])])
    body=dict(version='0.0.2',skinId=0,detailId=0,skinMainColor=[.95,.76,.65,1],skinSubColor=[.82,.55,.42,1],paintId=[0,0],sunburnId=0)
    for name,record,key in [('body',body,'shapeValueBody'),('face',face,'shapeValueFace')]:
        record[key]=next(d['defaultValues'] for d in contract['domains'] if d['id']==name)
    hair=dict(version='0.0.4',parts=[dict(id=item,baseColor=[.21,.15,.1,1],startColor=[.08,.055,.035,1],endColor=[.39,.29,.17,1]) for item in [*hair_ids,0,0]])
    clothes=dict(version='0.0.1',parts=[dict(id=item,colorInfo=[dict(baseColor=color,pattern=0,tiling=[1,1],patternColor=[1,1,1,1]) for color in [[.16,.36,.65,1],[.82,.84,.9,1],[.3,.24,.2,1],[1,1,1,1]]],emblemeId=0) for item in [38,3,0,0,0,0,0,3,3]])
    clothes['parts'][1]['colorInfo'][0]['baseColor']=[.24,.22,.21,1]
    return dict(face=face,body=body,hair=hair,clothes=clothes)


def build(shared,output,*,male=False):
    if not output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('All source-derived output must remain in .local/')
    output.mkdir(parents=True,exist_ok=True)
    head=json.loads((shared/'head-materials/contract.json').read_text())
    verify_programs(head['verifiedCreateShaders'],shared/'head-materials',VERIFIED_PROGRAMS)
    composition=json.loads((shared/'clothed-materials/composition.json').read_text())
    verify_programs(composition['shaderEvidence'],shared/'clothed-materials',PROGRAMS)
    inputs={r['role']:r for r in head['defaultInputs']}
    if any(r['id']!=0 for r in inputs.values()):raise ValueError('Head recipes require recovered catalog ID0 inputs')
    gradient=inputs['pupilGradientMask']['texture']
    if digest((shared/'head-materials'/gradient['file']).read_bytes())!=gradient['pngSHA256']:
        raise ValueError('Recovered eye gradient mask SHA-256 mismatch')
    with Image.open(shared/'head-materials'/gradient['file']) as image:
        if image.convert('RGBA').getextrema()[0]!=(255,255):
            raise ValueError('Eye recipe requires the source constant-white gradient mask')
    clothes=json.loads((shared/'clothed-materials/manifest.json').read_text())
    entries=[]
    def texture(role):
        item=inputs[role]['texture'];return raw_texture(shared/'head-materials'/item['file'],item['pngSHA256'],output)
    def recipe(parts,kind,colors,requirements,mods,pass_index=0,**rest):
        entries.append(dict(parts=[p+'/0' for p in parts],pass_=pass_index,kind=kind,colors=colors,requirements=requirements,resolverProperties=mods,**rest))
        entries[-1]['pass']=entries[-1].pop('pass_')
    zero_makeup={'face.baseMakeup.'+key:0 for key in ['eyeshadowId','cheekId','lipId','paintId.0','paintId.1']}
    makeup_mods=['ChaFileMakeup.'+key for key in ['eyeshadowId','cheekId','lipId','PaintID1','PaintID2']]
    recipe(['cf_O_face'],'head',['body.skinMainColor','body.skinSubColor'],
           {'face.headId':0,'face.skinId':0,'face.detailId':0,'face.moleId':0,'face.lipLineId':0,**zero_makeup},
           ['ChaFileFace.headId','ChaFileFace.detailId','ChaFileFace.moleId','ChaFileFace.lipLineId',*makeup_mods],main=texture('faceBase'),mask=texture('faceColorMask'))
    recipe(['o_body_a'],'tint',['body.skinMainColor'],{'body.skinId':0,'body.detailId':0,'body.paintId.0':0,'body.paintId.1':0,'body.sunburnId':0},
           ['ChaFileBody.detailId','ChaFileBody.PaintID1','ChaFileBody.PaintID2','ChaFileBody.sunburnId'])
    for index,part in enumerate(['cf_Ohitomi_L02','cf_Ohitomi_R02']):
        recipe([part],'eye',[f'face.pupil.{index}.baseColor'],{f'face.pupil.{index}.id':0,f'face.pupil.{index}.gradMaskId':0},
               [f'ChaFileFace.Pupil{index+1}',f'ChaFileFace.PupilGradient{index+1}'],main=texture('pupilBase'),blend=f'face.pupil.{index}.gradBlend')
    recipe(['cf_Ohitomi_L','cf_Ohitomi_R'],'eyeWhite',['face.whiteBaseColor','face.whiteSubColor'],{'face.whiteId':0},['ChaFileFace.whiteId'],main=texture('eyeWhiteBase'))
    recipe(['cf_O_mayuge'],'tint',['face.eyebrowColor'],{'face.eyebrowId':0},['ChaFileFace.eyebrowId'])
    for part,field in [('cf_O_eyeline','eyelineUpId'),('cf_O_eyeline_low','eyelineDownId')]:
        recipe([part],'tint',['face.eyelineColor'],{'face.'+field:0},['ChaFileFace.'+field])
    recipe(['cf_O_eyeline'],'tint',['body.skinMainColor'],{'face.headId':0,'face.eyelineUpId':0},
           ['ChaFileFace.headId','ChaFileFace.eyelineUpId'],pass_index=1)
    for kind,field in [('highlightUpper','hlUp'),('highlightLower','hlDown')]:
        recipe(['cf_Ohitomi_L02','cf_Ohitomi_R02'],kind,['face.'+field+'Color'],{'face.'+field+'Id':0},['ChaFileFace.'+field+'Id'])
    for index,prefab,part,category,item_id,role in [(0,'p_o_top_tsyatu02','o_top_tsyats_a','ClothesTop',38,'top'),
                                                 (1,'p_o_bot_pants03','o_bot_pants03','ClothesBot',3,'pants'),
                                                 (8,'p_o_shoes_run01','o_shoes_run01','ClothesShoesOuter',3,'shoes')]:
        source=next(e for e in clothes['entries'] if e['prefab']==prefab)
        raw={t['name']:raw_texture(shared/'clothed-materials'/t['file'],t['sha256'],output) for t in source['textures']}
        main=next(v for k,v in raw.items() if k.endswith('_t'));mask=next(v for k,v in raw.items() if k.endswith('_mc'))
        requirements={f'clothes.parts.{index}.id':item_id,f'clothes.parts.{index}.emblemeId':0}
        requirements.update({f'clothes.parts.{index}.colorInfo.{c}.pattern':0 for c in range(4)})
        mods=['outfit{coordinate}.ChaFileClothes.'+category]+['outfit{coordinate}.ChaFileClothes.'+category+'Pattern'+str(c) for c in range(4)]
        recipe([part],'clothes',[f'clothes.parts.{index}.colorInfo.{c}.baseColor' for c in range(3)],requirements,mods,main=main,mask=mask)
    hair_ids=[9,5] if male else [2,1]
    if male:
        hair=json.loads((output/'male-hair-materials.json').read_text())
        verify_programs([r['shader'] for r in hair],output,PROGRAMS)
        masks=[([r['nodeName']],raw_texture(output/r['mask'],r['maskSHA256'],output)) for r in hair]
    else:
        masks=[]
        for prefab,nodes in [('p_cf_hair_b_03',['cf_hair_b_03_00']),
                             ('p_cf_hair_f_01',['cf_hair_idol_hair_f_00','cf_hair_idol_hair_f_01','cf_hair_idol_hair_f_02'])]:
            source=next(e for e in clothes['entries'] if e['prefab']==prefab)
            t=next(t for t in source['textures'] if t['name'].endswith('_mc'))
            masks.append((nodes,raw_texture(shared/'clothed-materials'/t['file'],t['sha256'],output)))
    for index,(parts,mask) in enumerate(masks):
        recipe(parts,'hair',[f'hair.parts.{index}.{key}' for key in ['baseColor','startColor','endColor']],
               {f'hair.parts.{index}.id':hair_ids[index]},['ChaFileHair.'+['HairBack','HairFront'][index]],mask=mask)
    limits=['Only selected original head00, reference clothes and two hair parts have native color recipes; unmatched original or modded IDs retain explicit reference materials.',
            'Hair and clothing geometry, patterns, makeup, detail normals, gloss and other unbound material fields are preserved in the source card but not restored by these recipes.',
            'Body uses flat skin tint for the explicitly clothed reference selection; no body texture or unclothed appearance parity.',
            'Verified albedo formulas only; original lighting, stencil, texture filtering and color-space parity remain incomplete.']
    stem='source-male-avatar' if male else 'source-avatar'
    appearance=json.loads((output/(stem+'.appearance.json')).read_text())
    surfaces={(p['part'],p.get('pass',0)) for p in appearance['parts']}
    if any((part,e['pass']) not in surfaces for e in entries for part in e['parts']):
        raise ValueError('A card-color binding does not identify a recovered material slot')
    manifest=dict(schemaVersion=1,entries=entries,limitations=limits)
    dump(output/(stem+'.card-appearance.json'),manifest)
    records=fixture_records(json.loads((output/'character-shape-contract.json').read_text()),hair_ids)
    card=synthetic_card(records,records['clothes'],0 if male else 1)
    path=output/'synthetic-appearance-card.png';path.write_bytes(card)
    parsed=parse_card(card)
    oracle=dict(schemaVersion=1,cardSHA256=digest(card),cardFile=path.name,sex=0 if male else 1,expectedAppliedFields=sorted({p for entry in entries for p in entry['colors']}),
                expectedRecipeCount=len(entries),recipes=[],sourceCardFraming=parsed.report)
    for entry_index,entry in enumerate(entries):
        for key,wanted in entry['requirements'].items():
            if get_path(records,key)!=wanted:raise ValueError('Synthetic fixture does not meet '+key)
        if entry['kind'] not in ['head','eye','eyeWhite','clothes','hair']:continue
        def image(meta):return np.frombuffer((output/meta['file']).read_bytes(),dtype=np.uint8).reshape(meta['height'],meta['width'],4).astype(np.float32)/255
        main=image(entry['main']) if 'main' in entry else None;mask=image(entry['mask']) if 'mask' in entry else None
        colors=np.asarray([get_path(records,p) for p in entry['colors']],dtype=np.float32)
        kind=entry['kind']
        if kind=='head':pixels=create_head_base(main,mask,*colors)
        elif kind=='eye':pixels=create_eye_base(main,colors[0],np.float32(get_path(records,entry['blend'])))
        elif kind=='eyeWhite':pixels=create_eye_white(main,*colors)
        elif kind=='clothes':pixels=clothes_base(main,mask,colors)
        else:pixels=hair_base(mask,colors)
        rgba=np.rint(np.clip(pixels,0,1)*255).astype(np.uint8).tobytes()
        filename=f'expected-appearance-{entry_index}.rgba';(output/'card-appearance-inputs'/filename).write_bytes(rgba)
        oracle['recipes'].append(dict(entryIndex=entry_index,parts=entry['parts'],kind=kind,file='card-appearance-inputs/'+filename,sha256=digest(rgba),bytes=len(rgba),tolerance=1))
    dump(output/'synthetic-appearance-oracle.json',oracle)
    print(json.dumps({'bindings':str(output/(stem+'.card-appearance.json')),'entries':len(entries),'fixture':str(path),'appliedFields':len(oracle['expectedAppliedFields'])}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared',type=Path,default=ROOT/'.local/reverse/rigs')
    parser.add_argument('--male',type=Path,default=ROOT/'.local/reverse/male')
    args=parser.parse_args();build(args.shared,args.shared);build(args.shared,args.male,male=True)
