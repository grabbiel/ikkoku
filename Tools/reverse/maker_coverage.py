#!/usr/bin/env python3
"""Count bounded native Maker coverage against the two recovered source catalogs.

Reads catalog metadata and converted manifests only. Counts are not a claim of
installed-game/mod completeness or original shader/rendering equivalence.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import msgpack
import UnityPy
from maker_asset_library import source_file

ROOT = Path(__file__).resolve().parents[2]


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def load(path): return json.loads(path.read_text())


def tables(path):
    result = []
    for obj in UnityPy.load(str(path)).objects:
        if obj.type.name != 'TextAsset': continue
        raw = obj.read().m_Script
        raw = raw.encode('utf8', 'surrogateescape') if isinstance(raw, str) else bytes(raw)
        try: value = msgpack.unpackb(raw, raw=False, strict_map_key=False)
        except (ValueError, msgpack.ExtraData, msgpack.FormatError): continue
        if not isinstance(value, dict) or 'dictList' not in value: continue
        result.append(dict(name=obj.peek_name(), category=value['categoryNo'],
            rows=[dict(zip(value['lstKey'], row, strict=True)) for row in value['dictList'].values()]))
    return result


def verified(directory, ref):
    path = (directory / ref['file']).resolve()
    assert path.is_relative_to(directory.resolve()) and sha(path) == ref['sha256']
    return path


def coverage(output):
    if not output.resolve().is_relative_to((ROOT/'.local').resolve()): raise ValueError('Evidence must stay under .local/')
    shared = ROOT/'.local/reverse/rigs'; directory = ROOT/'.local/reverse/maker-library'
    paths = [source_file(shared, 'list/characustom/00.unity3d')]
    evidence = load(directory/'heads/evidence.json')
    head_catalog = next(row for row in evidence['sources'] if '/list/characustom/' in row['path'])
    paths.append(Path(head_catalog['path'])); assert sha(paths[-1]) == head_catalog['sha256']
    catalogs = [table for path in paths for table in tables(path)]
    library = load(directory/'library.json'); entries = library['entries']
    original_entries = [e for e in entries if e.get('modGUID') is None]
    rows_by_key = {}
    for table in catalogs:
        for row in table['rows']:
            key = (table['category'], int(row['ID']))
            assert key not in rows_by_key, f'Ambiguous source catalog identity {key}'
            rows_by_key[key] = row
    for entry in original_entries:
        row = rows_by_key[(entry['category'], entry['id'])]
        assert (row.get('MainData') == 'p_dummy') == entry.get('empty', False)
    groups = {}
    for group, categories in [('hair', range(101,105)), ('clothes', range(105,113)), ('accessories', range(120,131))]:
        rows = [r for (cat, _),r in rows_by_key.items() if cat in categories]
        converted = [e for e in original_entries if e['category'] in categories]
        dummy = sum(r.get('MainData') == 'p_dummy' for r in rows)
        drawable = [e for e in converted if not e.get('empty',False)]
        groups[group] = dict(catalogRows=len(rows), catalogDrawable=len(rows)-dummy, catalogDummy=dummy,
            convertedDrawable=len(drawable), convertedDummy=sum(e.get('empty',False) for e in converted),
            unconvertedDrawable=len(rows)-dummy-len(drawable),
            convertedIdentities=[dict(category=e['category'],id=e['id'],empty=e.get('empty',False)) for e in converted])
    assemblies = []
    for assembly in library['assemblies']:
        path = verified(directory, assembly['manifest'])
        assemblies.append((assembly['sex'],assembly['headID'],path))
    for sex, path in [(1,shared/'source-avatar.json'),(0,ROOT/'.local/reverse/male/source-male-avatar.json')]:
        manifest = load(path); assert manifest.get('headID',0) == 0
        assemblies.append((sex,0,path))
    head_ids = {key[1] for key in rows_by_key if key[0] == 100}
    converted_heads = {head for _,head,_ in assemblies}
    assert converted_heads <= head_ids
    groups['head'] = dict(catalogRows=len(head_ids), catalogDrawable=len(head_ids), catalogDummy=0,
        convertedDrawable=len(converted_heads), convertedDummy=0, unconvertedDrawable=len(head_ids-converted_heads),
        convertedIDs=sorted(converted_heads), normalSexHeadAssemblies=len(assemblies), supportedExTypes=[0],
        boneTypeBehavior='Standard type0 and source additive correction table for every nonzero Int32 type; not separate body assets.')
    shader_entries = []; kinds = {}
    def count_materials(label, appearance, bindings):
        a,b = load(appearance),load(bindings)
        surfaces = {(p['part'],p.get('pass',0)) for p in a['parts']}
        bound = set()
        for recipe in b['entries']:
            kinds[recipe['kind']] = kinds.get(recipe['kind'],0)+1
            for part in recipe['parts']:
                if (part,recipe.get('pass',0)) in surfaces: bound.add((part,recipe.get('pass',0)))
        shader_entries.append(dict(asset=label, materialSurfaces=len(surfaces), cardBoundSurfaces=len(bound),
            recipes=len(b['entries']), drawableSurfacesWithoutCardRecipes=len(surfaces-bound),
            patternRecipes=sum(bool(e.get('patterns')) for e in b['entries']), faceLayerRecipes=sum(bool(e.get('layers')) for e in b['entries'])))
    drawable = [e for e in original_entries if not e.get('empty',False)]
    for entry in drawable:
        if 'appearance' in entry and 'cardBindings' in entry:
            count_materials(f"{entry['category']}:{entry['id']}", verified(directory,entry['appearance']),verified(directory,entry['cardBindings']))
    geometry_recipe_count = len(shader_entries)
    for sex,head,path in assemblies:
        count_materials(f'assembly:{sex}:{head}',path.with_suffix('.appearance.json'),path.with_suffix('.card-appearance.json'))
    catalog = load(shared/'expanded-materials/source-material-catalog.json')
    material_types = {'pattern':'mt_pattern','cheek':'mt_cheek','lipline':'mt_lipline','paint':'mt_face_paint','mole':'mt_mole'}
    material_coverage = {}
    for kind, prefix in material_types.items():
        source = [r for table in catalogs if table['name'].startswith(prefix+'_') for r in table['rows']]
        available = [e for e in catalog['entries'] if e['kind']==kind]
        source_ids = {int(r['ID']) for r in source}; converted = {e['id'] for e in available}
        assert converted <= source_ids
        for entry in available: verified(shared/'expanded-materials',entry['texture'])
        material_coverage[kind] = dict(catalogIDs=len(source_ids), catalogNullIDs=int(0 in source_ids),
            convertedTextureIDs=len(converted), unconvertedNonNullIDs=len(source_ids-converted-{0}), convertedIDs=sorted(converted))
    report = dict(schemaVersion=1,
        scope='Only source list/characustom/00 and /50 catalogs transferred and hash-verified in this workspace; no all-installed catalog/mod denominator.',
        catalogEvidence=[dict(path=str(path),sha256=sha(path)) for path in paths], groups=groups,
        materialCatalogs=material_coverage,
        shaderRecipes=dict(geometryAssetsWithAppearanceAndRecipes=geometry_recipe_count, convertedDrawableGeometryAssets=len(drawable),
            normalAssemblies=len(assemblies), recipeKinds=kinds, entries=shader_entries,
            meaning='Card color/pattern/makeup composition bindings on recovered surfaces; not complete Unity shader, lighting, stencil, mipmap or behavior equivalence.'),
        modScope=dict(convertedLibraryModGUIDEntries=sum(e.get('modGUID') is not None for e in entries),
            allInstalledModsCounted=False, note='Saved mod identities remain preserved. Existing separate mod-texture library/adapters are outside this geometry catalog denominator.'),
        omissions=['Other source catalog bundles and installed zipmods are outside this bounded count.',
            'Undeclared/unconverted hair, garments and accessories are not automatically native assets.',
            'Special exType1 male assembly, alternate wear states and complete material behavior remain unsupported.',
            'Lip makeup and eyeshadow overlays, additional body textures/details, original full lighting and physics are not included by these recipe counts.'])
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'.local/reverse/maker-expansion/asset-coverage.json')
    result = coverage(parser.parse_args().output)
    print(json.dumps({key:{k:v for k,v in value.items() if not k.startswith('convertedIdentities')} for key,value in result['groups'].items()}))
