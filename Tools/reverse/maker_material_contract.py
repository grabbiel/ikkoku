#!/usr/bin/env python3
"""Recover source pattern and create_head layers into bounded local card recipes.

Only face makeup and clothing pattern textures are decoded; original card images
are never opened. Reuses verified DXBC program hashes and source catalog IDs.
"""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path
import msgpack
import numpy as np
import UnityPy
from card_appearance_bindings import raw_texture, verify_programs, linear_colors, encode_rgb
from head_material_contract import VERIFIED_PROGRAMS, create_head_base
from clothed_material_contract import PROGRAMS, clothes_base

ROOT=Path(__file__).resolve().parents[2]
TABLES={
 'mt_pattern_00':('pattern','MainTexAB','MainTex'),
 'mt_cheek_00':('cheek','MainAB','CheekTex'),
 'mt_lipline_00':('lipline','MainAB','LiplineTex'),
 'mt_face_paint_00':('paint','MainAB','PaintTex'),
 'mt_mole_00':('mole','MainAB','MoleTex'),
}

def sha(data):return hashlib.sha256(data).hexdigest()
def dump(path,value):path.write_text(json.dumps(value,indent=2,allow_nan=False)+'\n')

def sample(image, uv, repeat=False):
    """D3D linear sample at texel centers, on UnityPy's upright RGBA array."""
    h,w,_=image.shape
    point=uv*np.array([w,-h],dtype=np.float32)+np.array([-.5,h-.5],dtype=np.float32)
    lower=np.floor(point).astype(np.int64);frac=point-lower
    def tex(dx,dy):
        x=lower[...,0]+dx;y=lower[...,1]+dy
        x=x%w if repeat else np.clip(x,0,w-1)
        y=y%h if repeat else np.clip(y,0,h-1)
        return image[y,x]
    a=tex(0,0)+(tex(1,0)-tex(0,0))*frac[...,0:1]
    b=tex(0,1)+(tex(1,1)-tex(0,1))*frac[...,0:1]
    return a+(b-a)*frac[...,1:2]

def pattern_pair(base,other,red):
    amount=np.maximum(red,1-other[3])
    return other[:3]+amount[...,None]*(base[:3]-other[:3])

def over(base,texture,color,mask=1):
    amount=texture[...,3:4]*color[3]*np.asarray(mask)[...,None]
    result=base.copy();result[...,:3]+=amount*(texture[...,:3]*color[:3]-result[...,:3]);result[...,3]=1
    return result

def face_uv(uv,layout,kind):
    off=np.array([.25-.5*layout[0],.3-.6*layout[1]])
    scale=.7*layout[3] if kind=='mole' else -8+8.7*layout[3]
    point=(uv+off-.5)*(4*(1-scale))
    angle=0 if kind=='mole' else (1-2*layout[2])*6.283185
    sine=np.sin(angle);cosine=np.cos(angle)
    return np.stack([point[...,0]*cosine+point[...,1]*sine,-point[...,0]*sine+point[...,1]*cosine],axis=-1)+.5

def export_catalogs(source,output):
    catalogs={};evidence=[];envs={}
    for obj in UnityPy.load(str(source/'list/characustom/00.unity3d')).objects:
        if obj.type.name!='TextAsset' or obj.peek_name() not in TABLES:continue
        value=msgpack.unpackb(obj.read().m_Script.encode('utf8','surrogateescape'),strict_map_key=False)
        kind,bundle_key,texture_key=TABLES[obj.peek_name()];textures={}
        for identifier,raw in value['dictList'].items():
            row=dict(zip(value['lstKey'],raw,strict=True));bundle=row[bundle_key];name=row[texture_key]
            if identifier==0:
                if bundle!='0' or name!='0':raise ValueError('Source null selection changed')
                continue
            path=source/bundle
            if bundle not in envs:envs[bundle]=UnityPy.load(str(path))
            matches=[o for o in envs[bundle].objects if o.type.name=='Texture2D' and o.peek_name()==name]
            if len(matches)!=1:raise ValueError('Ambiguous material texture '+name)
            texture=matches[0].read();settings=texture.m_TextureSettings
            wrap=int(settings.m_WrapMode)
            if wrap not in [0,1]:raise ValueError('Unrecovered wrap mode '+str(wrap))
            # Unity importer FilterMode is bilinear/trilinear for these inputs.
            if int(settings.m_FilterMode) not in [1,2]:raise ValueError('Unrecovered source filtering')
            png=output/(kind+'-'+str(identifier)+'.png');texture.image.save(png)
            meta=raw_texture(png,sha(png.read_bytes()),output);meta['wrap']='repeat' if wrap==0 else 'clamp'
            textures[str(identifier)]=meta
            evidence.append(dict(kind=kind,id=identifier,category=value['categoryNo'],bundle=bundle,bundleSHA256=sha(path.read_bytes()),name=name,pathID=str(matches[0].path_id),texture=meta))
        catalogs[kind]=textures
    if set(catalogs)!=set(k for k,_,_ in TABLES.values()):raise ValueError('Incomplete material catalog')
    dump(output/'source-material-catalog.json',dict(schemaVersion=1,entries=evidence))
    return catalogs

def expand(bindings,catalogs,creator,paint_mask):
    for entry in bindings['entries']:
        if entry['kind'] in ['head','clothes']:entry['colorSpace']='sourceLinear'
        if entry['kind']=='clothes':
            index=int(entry['colors'][0].split('.')[2]);prefix=f'clothes.parts.{index}.colorInfo.'
            category=['ClothesTop','ClothesBot','ClothesBra','ClothesShorts','ClothesGloves','ClothesPanst','ClothesSocks','ClothesShoesInner','ClothesShoesOuter'][index]
            entry['patterns']=[dict(selection=prefix+f'{i}.pattern',color=prefix+f'{i}.patternColor',tiling=prefix+f'{i}.tiling',resolverProperties=['outfit{coordinate}.ChaFileClothes.'+category+'Pattern'+str(i)],textures=catalogs['pattern']) for i in range(3)]
            entry['requirements']={k:v for k,v in entry['requirements'].items() if not k.startswith(prefix) or not k.endswith('.pattern')}
            entry['resolverProperties']=[p for p in entry['resolverProperties'] if 'Pattern' not in p]
        elif entry['kind']=='head':
            entry['requirements']={k:v for k,v in entry['requirements'].items() if 'baseMakeup' not in k and k not in ['face.moleId','face.lipLineId']}
            entry['resolverProperties']=[p for p in entry['resolverProperties'] if 'Makeup' not in p and p not in ['ChaFileFace.moleId','ChaFileFace.lipLineId']]
            def layer(kind,selection,color,resolver,**kwargs):
                return dict(kind=kind,selection=selection,color=color,resolverProperties=[resolver],textures=catalogs[kind],**kwargs)
            entry['layers']=[
                layer('cheek','makeup.cheekId','makeup.cheekColor','ChaFileMakeup.cheekId',transform=creator['colors']['_tex4uv']),
                layer('lipline','face.lipLineId','face.lipLineColor','ChaFileFace.lipLineId',transform=creator['colors']['_tex5uv']),
                layer('paint','makeup.paintId.0','makeup.paintColor.0','ChaFileMakeup.PaintID1',layout='makeup.paintLayout.0',mask=paint_mask),
                layer('paint','makeup.paintId.1','makeup.paintColor.1','ChaFileMakeup.PaintID2',layout='makeup.paintLayout.1',mask=paint_mask),
                layer('mole','face.moleId','face.moleColor','ChaFileFace.moleId',layout='face.moleLayout')]
    bindings['limitations']=[
        'Recovered original pattern IDs and cheek/lip-line/face-paint/mole layers are composed with source bilinear UV sampling; unconverted or mod-resolved textures remain explicit omissions.',
        'Lip makeup and eyeshadow are separate draw-material overlays, not create_head layers, and are retained without being applied. Body texture/detail, lighting, gloss, stencil, and mip derivatives remain incomplete.',
        'Head and clothes linearize material colors and encode the composed output to sRGB, matching measured original create passes; source lighting and mip/filter edge parity are not asserted.']
    return bindings

def generate_vectors(output):
    rng=np.random.default_rng(0x4b4b);rows=[]
    for i in range(128):
        base=rng.random(4).astype(np.float32);texture=rng.random(4).astype(np.float32);color=rng.random(4).astype(np.float32);mask=float(rng.random());red=float(rng.random())
        uv=rng.random(2).astype(np.float32);layout=rng.random(4).astype(np.float32);kind='mole' if i%2 else 'paint'
        expected=over(base,texture,color,mask)
        pair=np.r_[pattern_pair(base,color,np.asarray(red)),base[3]]
        rows.append(dict(base=base.tolist(),texture=texture.tolist(),color=color.tolist(),mask=mask,red=red,uv=uv.tolist(),layout=layout.tolist(),kind=kind,layer=expected.tolist(),pattern=pair.tolist(),transformedUV=face_uv(uv,layout,kind).tolist()))
    dump(output/'pixel-oracle.json',dict(schemaVersion=1,cases=rows))

def generate_card_oracle(folder, manifest, output):
    from card_appearance_bindings import fixture_records, synthetic_card, get_path
    records=fixture_records(json.loads((folder/'character-shape-contract.json').read_text()),[2,1] if folder.name=='rigs' else [9,5])
    records['face']['baseMakeup'].update(cheekId=2,cheekColor=[.95,.15,.22,.6],paintId=[1,3],paintColor=[[.2,.5,.9,.65],[.85,.35,.1,.7]],paintLayout=[[.7,.4,.3,.8],[.2,.6,.8,.9]])
    records['face'].update(moleId=1,moleColor=[.2,.1,.05,.8],moleLayout=[.25,.7,.5,.85],lipLineId=2,lipLineColor=[.35,.1,.15,.5])
    for i in range(3):records['clothes']['parts'][0]['colorInfo'][i].update(pattern=[1,2,3][i],patternColor=[[.9,.2,.3,.8],[.3,.8,.2,.5],[.1,.4,.9,1]][i],tiling=[[1,.9],[.95,1],[.8,.85]][i])
    data=synthetic_card(records,records['clothes'],1 if folder.name=='rigs' else 0)
    card=output/'synthetic-material-card.png';card.write_bytes(data)
    records['makeup']=records['face']['baseMakeup']
    def pixels(meta):return np.frombuffer((folder/meta['file']).read_bytes(),dtype=np.uint8).reshape(meta['height'],meta['width'],4).astype(np.float32)/255
    expected=[]
    for entry in manifest['entries']:
        if entry['kind']!='head' and not(entry['kind']=='clothes' and entry['colors'][0].startswith('clothes.parts.0.')):continue
        main=pixels(entry['main']);mask=pixels(entry['mask']);h,w,_=main.shape
        xx,yy=np.meshgrid((np.arange(w,dtype=np.float32)+.5)/w,1-(np.arange(h,dtype=np.float32)+.5)/h);uv=np.stack([xx,yy],axis=-1)
        source_linear=entry.get('colorSpace')=='sourceLinear'
        def selected_color(path):
            value=np.asarray(get_path(records,path),dtype=np.float32)
            return linear_colors(value) if source_linear else value
        colors=np.asarray([selected_color(path) for path in entry['colors']],dtype=np.float32)
        if entry['kind']=='head':
            result=create_head_base(main,mask,*colors)
            for layer in entry['layers']:
                ident=get_path(records,layer['selection']);meta=layer['textures'][str(ident)];color=selected_color(layer['color'])
                point=uv
                if layer.get('layout'):point=face_uv(uv,np.asarray(get_path(records,layer['layout']),dtype=np.float32),layer['kind'])
                elif layer.get('transform'):
                    transform=np.asarray(layer['transform'],dtype=np.float32);point=(uv+transform[:2]-1)*(1-transform[2:])+.5
                attenuation=sample(pixels(layer['mask']),uv)[...,0] if 'mask' in layer else 1
                result=over(result,sample(pixels(meta),point,meta['wrap']=='repeat'),color,attenuation)
        else:
            colored=[]
            for i,pattern in enumerate(entry['patterns']):
                ident=get_path(records,pattern['selection']);meta=pattern['textures'][str(ident)];other=selected_color(pattern['color']);tiling=np.asarray(get_path(records,pattern['tiling']),dtype=np.float32)
                red=sample(pixels(meta),uv*(20-19*tiling),meta['wrap']=='repeat')[...,0];colored.append(pattern_pair(colors[i],other,red))
            tint=1+mask[...,0:1]*(colored[0]-1);tint+=mask[...,1:2]*(colored[1]-tint);tint+=mask[...,2:3]*(colored[2]-tint)
            result=np.concatenate([np.clip(main[...,:3],0,1)*tint*main[...,3:4],main[...,3:4]**2],axis=-1)
        if source_linear:result=encode_rgb(result)
        rgba=np.rint(np.clip(result,0,1)*255).astype(np.uint8).tobytes();filename=entry['kind']+'-expected.rgba';(output/filename).write_bytes(rgba)
        expected.append(dict(part=entry['parts'][0],file=filename,width=w,height=h,sha256=sha(rgba)))
    dump(output/'image-oracle.json',dict(schemaVersion=1,cardFile=card.name,cardSHA256=sha(data),recipes=expected))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'.local/reverse/rigs/source/abdata')
    parser.add_argument('--shared',type=Path,default=ROOT/'.local/reverse/rigs')
    parser.add_argument('--male',type=Path,default=ROOT/'.local/reverse/male')
    args=parser.parse_args()
    shared=args.shared;head=json.loads((shared/'head-materials/contract.json').read_text())
    verify_programs(head['verifiedCreateShaders'],shared/'head-materials',VERIFIED_PROGRAMS)
    clothes=json.loads((shared/'clothed-materials/composition.json').read_text());verify_programs(clothes['shaderEvidence'],shared/'clothed-materials',PROGRAMS)
    creator=next(m for m in head['createMaterials'] if m['name']=='cf_m_face_create')
    for folder,stem in [(shared,'source-avatar'),(args.male,'source-male-avatar')]:
        if not folder.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Source-derived outputs must stay in .local/')
        material_dir=folder/'expanded-materials';material_dir.mkdir(exist_ok=True)
        catalogs=export_catalogs(args.source,material_dir)
        paint_png=shared/'head-materials/cf_face_00_mp.png'
        paint_mask=raw_texture(paint_png,sha(paint_png.read_bytes()),material_dir);paint_mask['wrap']='clamp'
        # Manifest is rooted beside avatar; make only texture paths relative to it.
        for textures in catalogs.values():
            for texture in textures.values():texture['file']='expanded-materials/'+texture['file']
        paint_mask['file']='expanded-materials/'+paint_mask['file']
        path=folder/(stem+'.card-appearance.json')
        result=expand(json.loads(path.read_text()),catalogs,creator,paint_mask)
        dump(path,result);generate_vectors(material_dir);generate_card_oracle(folder,result,material_dir)
        print(json.dumps(dict(bindings=str(path),textures=sum(map(len,catalogs.values())),patternIDs=len(catalogs['pattern']),faceLayerIDs=sum(len(v) for k,v in catalogs.items() if k!='pattern'))))
if __name__=='__main__':main()
