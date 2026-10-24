#!/usr/bin/env python3
"""Translated family colour outside the capture meshes the native frame cannot draw live.

compare_original_frame.py compares each translated family only where it is frontmost in
the original frame, the complete translated render and its own render. A capture mesh
whose shader family has no translated program (for example the pantyhose's
`main_alpha`) is absent from both native renders, so the family under it (skin) reads as
frontmost there while the original shows the untranslated mesh over it. This tool
repeats the same family comparison, with the same limits (mean <= 1, p99 <= 4 channel
bytes), after removing every pixel inside the original silhouette of those meshes: their
actual BakeMesh triangles projected with the recorded camera, without a depth test, so
the exclusion is conservative (pixels where the mesh is hidden are removed too). It reads
a finished live-probe run folder (`compare_original_frame.py` inputs plus
`live-report.json`) and writes `wear-comparison.json`; nothing is fitted or recoloured.
"""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from compare_original_frame import family_metrics
from compare_original_model import geometry, sidecar


def silhouette(folder, frame, meshes):
    """Union of the named capture meshes' BakeMesh triangles in the capture camera."""
    width, height = frame['width'], frame['height']
    camera = frame['camera']
    transform = np.asarray(camera['projection']).reshape(4, 4).T @ np.asarray(camera['view']).reshape(4, 4).T
    image = Image.new('1', (width, height)); draw = ImageDraw.Draw(image)
    for mesh in meshes:
        _, indices = geometry(folder, mesh)
        baked = sidecar(folder, mesh['bakedPositions'], mesh['vertices'])
        matrix = np.asarray(mesh['rendererMatrix']).reshape(4, 4).T
        positions = (np.c_[baked / mesh['lossyScale'], np.ones(len(baked))] @ matrix.T)[:, :3]
        clip = np.c_[positions, np.ones(len(positions))] @ transform.T
        if np.any(clip[:, 3] <= 0): raise ValueError('Excluded mesh crosses the camera plane: ' + mesh['name'])
        xy = (clip[:, :2] / clip[:, 3:4] * [1, -1] + 1) * [width / 2, height / 2]
        for submesh in indices:
            for triangle in submesh.reshape(-1, 3): draw.polygon([tuple(p) for p in xy[triangle]], fill=1)
    return np.asarray(image, dtype=bool)


def family(shader):
    parts = shader.split('/')
    return parts[1] if len(parts) == 2 and parts[0] == 'Shader Forge' else None


def compare(folder):
    native = json.loads((folder / 'native-report.json').read_text())
    name = native.get('sourceFrameFile', 'frame.json')
    if Path(name).name != name or name.startswith('.'): raise ValueError('Invalid source frame path')
    frame_path = folder / name
    if native.get('sourceFrameSHA256') != hashlib.sha256(frame_path.read_bytes()).hexdigest():
        raise ValueError('Native report does not identify this exact source capture')
    frame = json.loads(frame_path.read_text())
    live = json.loads((folder / 'live-report.json').read_text())
    drawn = set(live['liveFamilies'])
    excluded = [mesh for mesh in frame['meshes']
                if any(family(m.get('shader', '')) not in drawn | {'shadowcast'} for m in mesh['materials'][:mesh.get('submeshes', 1)])]
    # Mesh files sit next to the capture's own frame (the run folder may link it).
    mask = silhouette(frame_path.resolve().parent, frame, excluded) if excluded else np.zeros((frame['height'], frame['width']), bool)
    def pixels(file):
        result = np.asarray(Image.open(folder / file).convert('RGBA'))
        if result.shape != (frame['height'], frame['width'], 4): raise ValueError('Capture dimensions differ from source camera')
        return result
    source, full = pixels('original-color.png'), pixels('native-translated.png')
    families = {}
    for path in sorted(folder.glob('native-translated-*.png')):
        only = pixels(path.name).copy(); only[mask] = 0
        families[path.name[len('native-translated-'):-len('.png')]] = family_metrics(source, full, only)
    return dict(schemaVersion=1, sourceFrameSHA256=native['sourceFrameSHA256'],
                scope='compare_original_frame.py family metrics (frontmost in the original, the complete translated render and the family render; limits unchanged) outside the original BakeMesh silhouettes of capture meshes whose family is not drawn live; silhouettes are not depth tested.',
                excludedMeshes=[dict(name=m['name'], path=m['path'], shaders=[x.get('shader') for x in m['materials']]) for m in excluded],
                excludedPixels=int(mask.sum()), translatedFamilies=families)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folder', type=Path)
    folder = parser.parse_args().folder
    result = compare(folder)
    (folder / 'wear-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
