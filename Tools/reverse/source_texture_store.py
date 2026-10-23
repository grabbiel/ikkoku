#!/usr/bin/env python3
"""Decode the Texture2D assets a native shader binding set names into a private
texture store for the opt-in live source-shader path (R1/CMT-04).

Input is the `ikkoku-inspect shader-bindings` report (or a bare binding set) and
one or more local bundle roots (folders holding `chara/*.unity3d`, directly or
under `abdata/`). Every asset identity (bundle + pathID, else a unique name) is
read from the local bundle, its SHA-256 checked against the identity, and its
authored mip chain decoded level by level. Textures whose `m_ColorSpace` marks
them sRGB are linearized texel by texel, as GPU sRGB sampling would; linear
textures (masks, normal maps) are stored as decoded. Levels are written as
little-endian half floats in Unity's bottom-up row order, the layout the probe
loader reads. The texture's own `m_TextureSettings` (filter, wrap, aniso) is
recorded for when the binding identity carries no sampler state.

Nothing is substituted: an identity whose bundle is not local, whose asset is
missing or ambiguous, or whose format is not decodable is listed under
`unavailable` with the reason, and the live path keeps that material on toon.
Runtime composites (`CustomTextureCreate` render targets) are never in the store.
Outputs must stay under a `.local` folder.
"""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path
import numpy as np

FILTERS = {0: 'Point', 1: 'Bilinear', 2: 'Trilinear'}
WRAPS = {0: 'Repeat', 1: 'Clamp'}
ENCODING = 'linear-rgba16f-little-endian-bottom-up'


def level_bytes(width, height, fmt):
    """Bytes of one mip level for the Unity 5.6 formats these bundles use."""
    if fmt in (10, 12, 24, 25):
        return max(1, (width + 3) // 4) * max(1, (height + 3) // 4) * (8 if fmt == 10 else 16)
    if fmt in (1, 3, 4, 5, 7, 9):
        return width * height * {1: 1, 3: 3, 4: 4, 5: 4, 7: 2, 9: 2}[fmt]
    raise ValueError('unsupported texture format %d' % fmt)


def srgb_to_linear(rgb):
    rgb = np.asarray(rgb, dtype=np.float32)
    return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4).astype(np.float32)


def identities(report):
    """Unique asset texture identities named by a binding set, with the inputs using them."""
    bindings = report.get('bindings', report)
    found = {}

    def add(identity, use):
        if not identity or identity.get('kind') != 'asset':
            return
        key = (identity.get('bundle'), identity.get('pathID') or '', identity.get('name') or '')
        entry = found.setdefault(key, dict(identity=identity, uses=[]))
        entry['uses'].append(use)

    for renderer in bindings.get('renderers', []):
        for name, texture in renderer['material'].get('textures', {}).items():
            add(texture.get('identity'), '%s slot %s %s' % (renderer['mesh'], renderer['materialSlot'], name))
    for name, texture in bindings.get('globalTextures', {}).items():
        add(texture.get('identity'), 'global ' + name)
    return [found[key] for key in sorted(found, key=lambda k: tuple(str(v) for v in k))]


def locate(bundle, roots):
    for root in roots:
        for candidate in (root / bundle, root / 'abdata' / bundle):
            if candidate.is_file():
                return candidate
    return None


def texture_settings(texture):
    settings = getattr(texture, 'm_TextureSettings', None)
    if settings is None:
        return None, None, None
    wrap = getattr(settings, 'm_WrapMode', None)
    if wrap is None:
        wrap = getattr(settings, 'm_WrapU', None)
    return FILTERS.get(getattr(settings, 'm_FilterMode', -1)), WRAPS.get(wrap), getattr(settings, 'm_Aniso', None)


def decode_levels(texture):
    """Yield (width, height, float32 RGBA bottom-up) per authored mip level."""
    from UnityPy.export.Texture2DConverter import parse_image_data
    data = texture.get_image_data()
    fmt = texture.m_TextureFormat
    fmt = getattr(fmt, 'value', fmt)
    width, height, offset = texture.m_Width, texture.m_Height, 0
    levels = max(1, getattr(texture, 'm_MipCount', 1) or 1)
    for level in range(levels):
        count = level_bytes(width, height, fmt)
        if offset + count > len(data):
            raise ValueError('truncated mip chain at level %d' % level)
        image = parse_image_data(data[offset:offset + count], width, height, texture.m_TextureFormat,
                                 texture.object_reader.version, texture.object_reader.platform, flip=False)
        yield width, height, np.asarray(image.convert('RGBA'), dtype=np.float32) / 255
        offset += count
        width, height = max(1, width // 2), max(1, height // 2)


def build(report, roots, output):
    import UnityPy
    output.mkdir(parents=True, exist_ok=True)
    entries, unavailable, bundles = [], [], {}
    for item in identities(report):
        identity = item['identity']
        bundle = identity.get('bundle')
        record = dict(bundle=bundle, name=identity.get('name'), pathID=identity.get('pathID'), uses=item['uses'])
        path = locate(bundle, roots) if bundle else None
        if path is None:
            unavailable.append(dict(record, reason='bundle not in the local bundle roots'))
            continue
        if path not in bundles:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            objects = [obj for obj in UnityPy.load(str(path)).objects if obj.type.name == 'Texture2D']
            bundles[path] = (digest, objects)
        digest, objects = bundles[path]
        if identity.get('bundleSHA256') and identity['bundleSHA256'] != digest:
            unavailable.append(dict(record, reason='local bundle SHA-256 differs from the binding identity'))
            continue
        if identity.get('pathID'):
            matches = [obj for obj in objects if str(obj.path_id) == str(identity['pathID'])]
        else:
            matches = [obj for obj in objects if obj.read().m_Name == identity.get('name')]
        if len(matches) != 1:
            unavailable.append(dict(record, reason='asset missing from the bundle' if not matches else 'asset name is ambiguous in the bundle'))
            continue
        texture = matches[0].read()
        if identity.get('name') and texture.m_Name != identity['name']:
            unavailable.append(dict(record, reason='bundle asset name differs from the binding identity'))
            continue
        color_space = 'srgb' if getattr(texture, 'm_ColorSpace', 1) == 1 else 'linear'
        try:
            levels = list(decode_levels(texture))
        except Exception as error:  # unsupported format or truncated data: never substitute
            unavailable.append(dict(record, reason='not decodable: %s' % error))
            continue
        key = hashlib.sha256(('%s#%s' % (bundle, matches[0].path_id)).encode()).hexdigest()[:20]
        folder = output / key
        folder.mkdir(exist_ok=True)
        files, hashes = [], []
        for level, (width, height, pixels) in enumerate(levels):
            if color_space == 'srgb':
                pixels[:, :, :3] = srgb_to_linear(pixels[:, :, :3])
            data = pixels.astype('<f2').tobytes()
            name = 'level-%d.rgba16f' % level
            (folder / name).write_bytes(data)
            files.append(name)
            hashes.append(hashlib.sha256(data).hexdigest())
        filter_mode, wrap, aniso = texture_settings(texture)
        fmt = texture.m_TextureFormat
        entries.append(dict(bundle=bundle, bundleSHA256=digest, name=texture.m_Name, pathID=str(matches[0].path_id),
                            serializedFile=identity.get('serializedFile'), width=texture.m_Width, height=texture.m_Height,
                            mipLevels=len(levels), colorSpace=color_space, textureFormat=int(getattr(fmt, 'value', fmt)),
                            filter=filter_mode, wrap=wrap, aniso=aniso, directory=key, files=files, sha256=hashes, uses=item['uses']))
    manifest = dict(schemaVersion=1, encoding=ENCODING,
                    scope='Texture2D pixels decoded from local game bundles for the identities a native shader binding set names. '
                          'Runtime composites and textures in bundles that are not local are listed as unavailable.',
                    roots=[str(root) for root in roots], entries=entries, unavailable=unavailable)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def verify(manifest_path, frame_path):
    """Compare stored base levels with a capture's decoded textures of the same name and size."""
    manifest = json.loads(manifest_path.read_text())
    frame = json.loads(frame_path.read_text())
    rows = {}
    for row in frame.get('textures', []):
        if row.get('textureType') == 'Texture2D':
            rows.setdefault((row.get('name'), row.get('width'), row.get('height')), []).append(row)
    results = []
    for entry in manifest['entries']:
        for row in rows.get((entry['name'], entry['width'], entry['height']), []):
            if not row['file'].endswith('.rgba16f'):
                continue
            original = np.frombuffer((frame_path.parent / row['file']).read_bytes(), dtype='<f2').reshape(row['height'], row['width'], 4).astype(np.float32)
            stored = np.frombuffer((manifest_path.parent / entry['directory'] / entry['files'][0]).read_bytes(), dtype='<f2').reshape(entry['height'], entry['width'], 4).astype(np.float32)
            error = np.abs(original - stored)
            results.append(dict(name=entry['name'], captureFile=row['file'], colorSpace=entry['colorSpace'],
                                captureDecodedColorSpace=(row.get('authoredMipSource') or {}).get('decodedColorSpace'),
                                meanAbsoluteError=float(error.mean()), maximumError=float(error.max())))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bindings', type=Path, help='ikkoku-inspect shader-bindings report or binding set JSON')
    parser.add_argument('output', type=Path, help='store folder (under .local)')
    parser.add_argument('--bundle-root', type=Path, action='append', required=True)
    parser.add_argument('--verify-frame', type=Path, help='capture frame JSON to compare base levels against')
    args = parser.parse_args()
    if '.local' not in args.output.resolve().parts:
        raise SystemExit('Decoded source textures must stay under a .local folder')
    manifest = build(json.loads(args.bindings.read_text()), args.bundle_root, args.output)
    summary = dict(entries=len(manifest['entries']), unavailable=len(manifest['unavailable']),
                   unavailableReasons=sorted({u['reason'] for u in manifest['unavailable']}))
    if args.verify_frame:
        summary['verification'] = verify(args.output / 'manifest.json', args.verify_frame)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
