#!/usr/bin/env python3
"""Map the locally recovered clothed avatar to native preview material slots.

This is an explicit preview mapping, not a claim of source lighting parity.
Meshes, source colors, textures and material-slot evidence remain in .local/.
"""
import argparse
import json
from pathlib import Path


def linear(color):
    return [(v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4) for v in color[:3]] + [color[3]]


def build(folder):
    head = json.loads((folder / 'head-materials/contract.json').read_text())
    materials = {m['name']: m for m in head['drawMaterials']}
    clothes = json.loads((folder / 'clothed-materials/manifest.json').read_text())
    composition = json.loads((folder / 'clothed-materials/composition.json').read_text())
    bakes = {row['role']: row['file'] for row in composition['previews']}
    parts = []

    def add(part, kind, *, color=(1, 1, 1, 1), texture=None, alpha='OPAQUE', outline=True, **extra):
        row = dict(part=part + '/0', kind=kind, color=linear(list(color)), alphaMode=alpha, outline=outline, **extra)
        if kind in ['cloth', 'skin']:
            # Conservative matte preview while source specular/rim terms remain unported.
            row.update(specularStrength=0, rimStrength=0)
        if texture:
            if not (folder / texture).is_file():
                raise ValueError(f'Missing recovered preview input: {texture}')
            row['texture'] = texture
        parts.append(row)

    skin = materials['cf_m_face_00']['colors']['_Color']
    add('o_body_a', 'skin', color=skin, bodyMask='top-body-alpha-mask.png', sourceBodyAlpha=[1, 1], doubleSided=True)
    add('cf_O_face', 'skin', texture='head-materials/preview_face_base.png', doubleSided=True)
    head_inputs = [
        ('cf_O_mayuge', 'cf_m_mayuge_00', 'cw_t_mayuge_000.png'),
        ('cf_O_noseline', 'cf_m_noseline_00', 'cw_t_noseline_000.png'),
        ('cf_O_eyeline', 'cf_m_eyeline_00_up', 'cw_t_eyeline_up_000.png'),
        ('cf_O_eyeline', 'cf_m_eyeline_kage', 'cw_t_eyeline_kage_000.png'),
        ('cf_O_eyeline_low', 'cf_m_eyeline_down', 'cw_t_eyeline_down_000.png'),
        ('cf_Ohitomi_L', 'cf_m_sirome_00', 'preview_eye_white.png'),
        ('cf_Ohitomi_R', 'cf_m_sirome_00', 'preview_eye_white.png'),
        ('cf_Ohitomi_L02', 'cf_m_hitomi_00', 'preview_eye_base.png'),
        ('cf_Ohitomi_R02', 'cf_m_hitomi_00', 'preview_eye_base.png'),
    ]
    for name, material, texture in head_inputs:
        extra = {'pass': 1} if material == 'cf_m_eyeline_kage' else {}
        if material == 'cf_m_hitomi_00':
            eye = materials[material]
            extra['irisHighlights'] = dict(upper='head-materials/cw_t_hitomi_hi_u_000.png',
                lower='head-materials/cw_t_hitomi_hi_d_000.png',
                colors=[linear(eye['colors']['_overcolor1']), linear(eye['colors']['_overcolor2'])],
                strength=eye['floats']['_isHighLight'])
        add(name, 'unlit', color=materials[material]['colors']['_Color'], texture='head-materials/' + texture,
            alpha='BLEND', outline=False, **extra)
    for name in ['cf_O_canine', 'cf_O_tooth']:
        add(name, 'unlit', color=materials['cf_m_tooth']['colors']['_Color'], texture='head-materials/cf_t_tooth_00.png', outline=False)
    add('o_tang', 'skin', color=materials['cf_m_tang']['colors']['_Color'], outline=False)

    for role, part in [('top', 'o_top_tsyats_a'), ('pants', 'o_bot_pants03'), ('shoes', 'o_shoes_run01')]:
        add(part, 'cloth', texture='clothed-materials/' + bakes[role], outline=False)
    for role, file in [('hair_back', 'hair-back-rig-materials.json'), ('hair_front', 'hair-front-rig-materials.json')]:
        for node in json.loads((folder / file).read_text()):
            if node['nodeName'].startswith('cf_acs_'):
                continue  # Authored inactive accessory.
            add(node['nodeName'], 'hair', texture='clothed-materials/' + bakes[role])

    result = dict(schemaVersion=1, parts=parts, provenance={
        'geometry': 'source-avatar.json', 'head': 'head-materials/contract.json', 'clothes': 'clothed-materials/composition.json',
        'colorSpaceAssumption': 'Authored preview colors treated as sRGB, converted to linear uniforms; PNGs loaded as sRGB.',
        'limitations': ['Matte native toon lighting, not original shader parity; skin/clothing specular and rim disabled, clothing outlines disabled after visible inverted-hull artifacts.',
                       'Body uses flat authored face color; fully clothed selection with source top coverage mask.',
                       'Clothing uses recovered no-pattern source tint composition; original lighting and color-space parity pending.',
                       'Hair uses recovered tint masks and serialized colors; native strand highlights and detail differ from the source.',
                       'Iris highlights use original UV1/UV2 and recovered albedo/coverage composition; original eye lighting and stencil remain unported.',
                       'Source stencil and exact render queues are not yet implemented.']})
    destination = folder / 'source-avatar.appearance.json'
    destination.write_text(json.dumps(result, indent=2) + '\n')
    print(f'{destination}: {len(parts)} material slots')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    build(parser.parse_args().folder)
