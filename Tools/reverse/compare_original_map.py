#!/usr/bin/env python3
"""ST-A11: compare our map render with the original CharaStudio player's, case by case.

Inputs are one `original_map_probe.py capture` folder (map-trace.json and the
original-<case>-*.png images) and, per case, one app capture folder written with
IKKOKU_SOURCE_MAP_PROBE (native-map.json, native-map-geometry.png,
native-map-depth-normals.png) plus its IKKOKU_AUTOCAPTURE colour image
native-color.png, rendered from the same saved scene record.

Gates (all must pass; no registration, resizing, recolouring or camera fitting):
- record: the map number and transform our parser read equal the original's
  sceneInfo after the load (1e-6);
- rule: the original's map root after the load equals MapCtrl.Reflect computed here
  independently (localPosition = caMap.pos within 1e-5 m, localRotation =
  Quaternion.Euler(caMap.rot) within 1e-3 degrees, scale 1 within 1e-5);
- placement: our map root matrix, moved to Unity's basis, equals the original's
  localToWorld (1e-5 per element), and every map draw uses it;
- camera: our view matrix equals the original Camera.main worldToCameraMatrix in
  our basis (1e-5 per element) and the vertical field of view matches (1e-4 deg);
- geometry: map-only white silhouettes, IoU >= 0.999 (the frame protocol);
- depth-normals: on pixels both silhouettes cover, depth p99 <= 2 quantization steps
  of Unity's EncodeFloatRG over the shared far plane and normal p99 <= 2 channel
  bytes (compare_original_frame.depth_metrics).
Colour is reported, never gated: the in-app label lists what the map's material
leaves out. Two controls must FAIL: our depth image shifted one pixel, and (for a
case with a nonzero map rotation) that rotation composed in the wrong Euler order
(X, Y, Z).

With --oracle (an `original_map_probe.py oracle` folder, ST-A11 slice 2) each case
also gets:
- cleanColor: our colour against the original's Camera.main frame without its
  image effects (reported, not gated);
- irradiance (gated when our capture has baked lightmaps): our decoded lightmap
  (native-map-irradiance-decoded) against Unity's own gi.indirect.diffuse from the
  oracle, on interior pixels (both silhouettes, 3x3 neighbourhood on one smooth
  surface of the original's depth-normals, so MSAA-resolved edges are left out).
  The per-pixel error is the largest channel's |ours - Unity| / Unity. Gate:
  mean <= IRRADIANCE_TOLERANCE["mean"] and p99 <= IRRADIANCE_TOLERANCE["p99"],
  and the oracle's repeat render must have differed by 0. Both negative controls
  (our nonDirectional and gammaConstants variants) must FAIL the same gate;
- irradianceLit: how much Unity's realtime lights add to the oracle (lit over
  unlit), the term the app leaves out (reported).

Slice 3 (map 34; docs/reference/studio/maps.md, "The sky gate" and "Particles"):
- the map-only images on both sides hold the solid map (every material
  RenderType=Opaque); sky, particle, cutout and blended draws are counted only;
- record also checks the sun type; placement checks each sky draw against the
  original sky renderer's own world matrix (relative 1e-5) and that sky draws are
  not pick occluders;
- with the oracle's classes image the irradiance gate keeps only pixels Unity
  draws with a baked lightmap; the classes' pixel counts are reported;
- sky (gated when either side draws one): our sky image against Unity's sky-only
  radiance on pixels both cover (alpha), the largest channel's relative error,
  mean <= SKY_TOLERANCE["mean"] and p99 <= SKY_TOLERANCE["p99"], coverage IoU >=
  SKY_TOLERANCE["coverageIoU"]. Our rowsFlipped and gammaConstants variants must
  FAIL, and rotationIgnored too when the sky has a nonzero _Rotation;
- particles (gated when either side draws them and covers a pixel): RGB over black, footprint IoU and
  the relative error on pixels both cover, against PARTICLE_TOLERANCE (fixed
  before any map 34 data was compared). Our noDoubling and gammaTint variants
  must FAIL.
A single `original_map_probe.py map34` folder is both --original and --oracle (its
map-trace.json holds each case's oracle).
"""
from __future__ import annotations
import argparse, gzip, hashlib, json, math, zlib
from pathlib import Path
import numpy as np
from PIL import Image
from compare_original_frame import depth_metrics, geometry_metrics

BASIS = np.diag([1.0, 1.0, -1.0, 1.0])  # Unity <-> engine: z negated (UnityCoordinates.basis)


def matrix(values):
    """A column-major 16-float list as a 4x4 array."""
    return np.array(values, dtype=np.float64).reshape(4, 4).T


def quaternion_axis(axis, degrees):
    half = math.radians(degrees) / 2
    q = [0.0, 0.0, 0.0, math.cos(half)]
    q["xyz".index(axis)] = math.sin(half)
    return np.array(q)


def quaternion_multiply(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return np.array([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz])


def unity_euler(degrees, order="zxy"):
    """Quaternion.Euler: rotate about Z, then X, then Y (q = qy * qx * qz). `order`
    lists the axes in application order, so a control can use the wrong one."""
    q = np.array([0.0, 0.0, 0.0, 1.0])
    for axis in order: q = quaternion_multiply(quaternion_axis(axis, degrees["xyz".index(axis)]), q)
    return q


def angle_degrees(a, b):
    dot = min(1.0, abs(float(np.dot(a / np.linalg.norm(a), b / np.linalg.norm(b)))))
    return math.degrees(2 * math.acos(dot))


def pixels(path):
    return np.asarray(Image.open(path).convert("RGBA"))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# The irradiance gate (ST-A11 slice 2; docs/reference/studio/maps.md, "The irradiance gate"). Its controls
# leave only our storage to allow for: the oracle's repeat render differs by 0, and the decode test
# (SourceStudioMapLightmapTests) puts map_fragment within 1e-4 of the cited formula. Our image is the
# float16 HDR target, so the gate allows one float16 step (2^-10 relative) for the mean and two for p99
# (the depth gate's two-quantization-step rule).
IRRADIANCE_TOLERANCE = dict(mean=2.0 ** -10, p99=2.0 ** -9)
INTERIOR_DEPTH_FRACTION = 0.02   # neighbour depth within 2 % of the pixel's
INTERIOR_NORMAL_BYTES = 6        # neighbour encoded view normal within 6 channel bytes
IRRADIANCE_VARIANTS = ("decoded", "nonDirectional", "gammaConstants")
# The sky gate (slice 3): the same float16 storage allowance as the irradiance gate. Both sides sample the
# same cube faces at the same direction (the camera gate holds the matrices to 1e-5), so what is left is our
# float16 target. Coverage is alpha on both sides (the fragment writes 1).
SKY_TOLERANCE = dict(mean=2.0 ** -10, p99=2.0 ** -9, coverageIoU=0.999)
SKY_VARIANTS = ("decoded", "rowsFlipped", "rotationIgnored", "gammaConstants")
# Particles (slice 3): minified, alpha-blended leaf cards. The tolerance was fixed before any map 34 data
# was compared, allowing for texture filtering and per-renderer blend order: far looser than the sky's and
# still far tighter than any term of the formula (the 2x factor alone is 75 %, the tint about 55 %). With the
# player's forced anisotropy (Toon.metal, mapForcedAnisoRepeat) the measured error is about 0.001 mean and
# 0.004 p99. Relative errors use PARTICLE_FLOOR as the smallest denominator (blended edges are near black).
PARTICLE_TOLERANCE = dict(mean=2.0 ** -6, p99=2.0 ** -3, footprintIoU=0.98)
PARTICLE_FLOOR = 2.0 ** -6
PARTICLE_VARIANTS = ("decoded", "noDoubling", "gammaTint")


def read_oracle_floats(path, width, height):
    """original_map_probe.py oracle's float32 RGB image (gzipped on arrival), rows top-down."""
    return np.frombuffer(gzip.decompress(Path(path).read_bytes()), dtype="<f4").reshape(height, width, 3).astype(np.float64)


def read_native_irradiance(path, width, height):
    """IKKOKU_SOURCE_MAP_PROBE's RGBA float16 image in raw DEFLATE, rows top-down."""
    return read_native_rgba(path, width, height)[:, :, :3]


def read_native_rgba(path, width, height):
    return np.frombuffer(zlib.decompress(Path(path).read_bytes(), -15), dtype="<f2").reshape(height, width, 4).astype(np.float64)


def read_oracle_rgba(path, width, height):
    """original_map_probe.py's float32 RGBA image (*.rgba.f32, gzipped on arrival), rows top-down."""
    return np.frombuffer(gzip.decompress(Path(path).read_bytes()), dtype="<f4").reshape(height, width, 4).astype(np.float64)


def iou(a, b):
    union = int((a | b).sum())
    return 1.0 if union == 0 else int((a & b).sum()) / union


def relative_error(unity, ours, mask, floor):
    """The largest channel's |ours - Unity| / max(Unity, floor) on `mask`."""
    return (np.abs(ours - unity) / np.maximum(unity, floor)).max(axis=-1)[mask]


def class_masks(path):
    """oracle-<case>-classes.png: white = Standard on a baked lightmap, red = Standard without one,
    green = another shader, black = no solid map renderer."""
    c = pixels(path)[:, :, :3] > 127
    return dict(lightmapped=c.all(axis=-1), probeLit=c[..., 0] & ~c[..., 1] & ~c[..., 2],
                otherShader=~c[..., 0] & c[..., 1] & ~c[..., 2], none=~c.any(axis=-1))


def surface_interior(geometry, depth_normals, far):
    """Silhouette pixels whose whole 3x3 neighbourhood lies on one smooth surface of a
    Unity depth-normals image: no depth step over INTERIOR_DEPTH_FRACTION of the depth and
    no normal step over INTERIOR_NORMAL_BYTES; the image border is left out."""
    d = depth_normals.astype(np.float64)
    depth = (d[:, :, 2] + d[:, :, 3] / 255) / 255 * far
    normal = d[:, :, :2]
    keep = geometry.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0: continue
            shift = lambda a: np.roll(np.roll(a, dy, axis=0), dx, axis=1)
            keep &= shift(geometry) & (np.abs(shift(depth) - depth) <= INTERIOR_DEPTH_FRACTION * depth) \
                & (np.abs(shift(normal) - normal).max(axis=-1) <= INTERIOR_NORMAL_BYTES)
    keep[0, :] = keep[-1, :] = keep[:, 0] = keep[:, -1] = False
    return keep


def irradiance_metrics(unity, ours, mask):
    """The largest channel's relative error per pixel on `mask`, against the gate."""
    if unity.shape != ours.shape or unity.shape[:2] != mask.shape or not mask.any(): raise ValueError("Invalid irradiance comparison extent")
    relative = (np.abs(ours - unity) / np.maximum(unity, 1e-3)).max(axis=-1)[mask]
    mean, p99 = float(relative.mean()), float(np.percentile(relative, 99))
    return dict(comparedPixels=int(mask.sum()), meanRelative=mean, p99Relative=p99, maximumRelative=float(relative.max()),
                meanAbsolute=float(np.abs(ours - unity)[mask].mean()), unityMean=float(unity[mask].mean()), oursMean=float(ours[mask].mean()),
                tolerance=dict(IRRADIANCE_TOLERANCE), passes=mean <= IRRADIANCE_TOLERANCE["mean"] and p99 <= IRRADIANCE_TOLERANCE["p99"])


def color_error(a, b):
    error = np.abs(a.astype(np.int16)[:, :, :3] - b.astype(np.int16)[:, :, :3])
    return dict(meanAbsoluteChannelBytes=float(error.mean()), p99ChannelBytes=float(np.percentile(error, 99)))


def sky_section(measured, oracle, ours, native, width, height):
    """The sky gate (see the module docstring)."""
    theirs, mine = measured.get("sky") or {}, native.get("sky") or {}
    if not theirs.get("written") and not mine.get("written"):
        return dict(gated=False, reason="neither side draws a sky")
    if not (theirs.get("written") and mine.get("written")):
        return dict(gated=True, passes=False, reason=f"only {'the original' if theirs.get('written') else 'our capture'} draws a sky")
    unity = read_oracle_rgba(oracle / (theirs["file"] + ".gz"), width, height)
    variants = {v: read_native_rgba(ours / mine["files"][v], width, height) for v in SKY_VARIANTS}
    covered = unity[..., 3] > 0.5
    decoded = variants["decoded"]
    mask = covered & (decoded[..., 3] > 0.5)
    if not mask.any(): return dict(gated=True, passes=False, reason="no pixel both skies cover")
    def metrics(image):
        relative = relative_error(unity[..., :3], image[..., :3], mask, 1e-3)
        return float(relative.mean()), float(np.percentile(relative, 99)), float(relative.max())
    mean, p99, maximum = metrics(decoded)
    coverage = iou(covered, decoded[..., 3] > 0.5)
    rotated = any(abs(r) > 0 for r in mine.get("rotationDegrees") or [])
    controls = {}
    for variant in SKY_VARIANTS[1:]:
        c_mean, c_p99, _ = metrics(variants[variant])
        fails = not (c_mean <= SKY_TOLERANCE["mean"] and c_p99 <= SKY_TOLERANCE["p99"])
        controls[variant] = dict(meanRelative=c_mean, p99Relative=c_p99, fails=fails, applicable=variant != "rotationIgnored" or rotated)
    passes = mean <= SKY_TOLERANCE["mean"] and p99 <= SKY_TOLERANCE["p99"] and coverage >= SKY_TOLERANCE["coverageIoU"]
    return dict(gated=True, comparedPixels=int(mask.sum()), coveredUnity=int(covered.sum()), coverageIoU=coverage,
                meanRelative=mean, p99Relative=p99, maximumRelative=maximum, unityMean=float(unity[..., :3][mask].mean()),
                oursMean=float(decoded[..., :3][mask].mean()), tolerance=dict(SKY_TOLERANCE), controls=controls,
                passes=passes and all(c["fails"] for c in controls.values() if c["applicable"]))


def particle_section(measured, oracle, ours, native, width, height):
    """The particles comparison (see the module docstring); RGB only."""
    theirs, mine = measured.get("particles") or {}, native.get("particles") or {}
    if not theirs.get("written") and not mine.get("written"):
        return dict(gated=False, reason="neither side draws particles")
    if not (theirs.get("written") and mine.get("written")):
        return dict(gated=True, passes=False, reason=f"only {'the original' if theirs.get('written') else 'our capture'} draws particles")
    files = mine.get("files") or {}
    if any(v not in files for v in PARTICLE_VARIANTS):
        return dict(gated=True, passes=False, reason=f"our capture lacks particle images {[v for v in PARTICLE_VARIANTS if v not in files]}")
    unity = read_oracle_rgba(oracle / (theirs["file"] + ".gz"), width, height)[..., :3]
    image = read_native_rgba(ours / files["decoded"], width, height)[..., :3]
    a, b = unity.max(axis=-1) > 1e-4, image.max(axis=-1) > 1e-4
    both = a & b
    footprint = iou(a, b)
    if not a.any() and not b.any():  # both draw them, out of this camera's view
        return dict(gated=False, coveredUnity=0, coveredOurs=0, reason="both sides draw particles; neither covers a pixel from this camera")
    if not both.any(): return dict(gated=True, passes=False, footprintIoU=footprint, reason="no pixel both cover")
    def metrics(candidate):
        relative = relative_error(unity, candidate, both, PARTICLE_FLOOR)
        mean, p99 = float(relative.mean()), float(np.percentile(relative, 99))
        return relative, mean, p99, mean <= PARTICLE_TOLERANCE["mean"] and p99 <= PARTICLE_TOLERANCE["p99"]
    relative, mean, p99, within = metrics(image)
    controls = {}
    for variant in PARTICLE_VARIANTS[1:]:
        _, c_mean, c_p99, c_within = metrics(read_native_rgba(ours / files[variant], width, height)[..., :3])
        controls[variant] = dict(meanRelative=c_mean, p99Relative=c_p99, fails=not c_within)
    absolute = np.abs(image - unity)[a | b]
    return dict(gated=True, coveredUnity=int(a.sum()), coveredOurs=int(b.sum()), footprintIoU=footprint, comparedPixels=int(both.sum()),
                meanRelative=mean, p99Relative=p99, maximumRelative=float(relative.max()), meanAbsolute=float(absolute.mean()),
                p99Absolute=float(np.percentile(absolute, 99)), unityMean=float(unity[both].mean()), oursMean=float(image[both].mean()),
                floor=PARTICLE_FLOOR, tolerance=dict(PARTICLE_TOLERANCE), controls=controls,
                passes=within and footprint >= PARTICLE_TOLERANCE["footprintIoU"] and all(c["fails"] for c in controls.values()))


def oracle_case(oracle_trace, case, oracle, ours, native, geometry, depth_normals, nc, width, height, far):
    """The --oracle sections for one case (see the module docstring)."""
    record = oracle_trace["cases"][case]
    measured = record["oracle"]
    result = {}
    result["sky"] = sky_section(measured, oracle, ours, native, width, height)
    result["particles"] = particle_section(measured, oracle, ours, native, width, height)
    classes = None
    if measured.get("classes"):
        path = oracle / measured["classes"]["image"]
        classes = class_masks(path)
        result["classes"] = dict(gated=False, image=dict(file=str(path), sha256=digest(path)),
                                 pixels={k: int(v.sum()) for k, v in classes.items()},
                                 pixelsInBothSilhouettes={k: int((v & geometry).sum()) for k, v in classes.items()},
                                 counts=measured["classes"].get("counts"))
    clean = oracle / measured["clean"]["image"]
    result["cleanColor"] = dict(gated=False, image=dict(file=str(clean), sha256=digest(clean)), **color_error(pixels(clean), nc))
    unity = read_oracle_floats(oracle / (measured["irradiance"]["file"] + ".gz"), width, height)
    lit = read_oracle_floats(oracle / (measured["irradianceLit"]["file"] + ".gz"), width, height)
    added = (lit - unity).max(axis=-1)
    result["irradianceLit"] = dict(gated=False, pixelsAddedOverOnePercent=int((added > 0.01 * unity.max(axis=-1)).sum()),
                                   maximumAdded=float(added.max()), meanAdded=float(added.mean()))
    files = native.get("irradiance", {}).get("files") if native.get("irradiance", {}).get("written") else None
    if not files:
        result["irradiance"] = dict(gated=False, reason="our capture has no baked-lightmap draws")
        return result
    interior = surface_interior(geometry, depth_normals, far)
    mask = interior & classes["lightmapped"] if classes is not None else interior
    section = irradiance_metrics(unity, read_native_irradiance(ours / files["decoded"], width, height), mask)
    repeat = measured["irradiance"]["repeatMaximumDifference"]
    section.update(gated=True, oracleSceneSHA256=record["sceneSHA256"], oracleRepeatMaximumDifference=repeat,
                   interior=dict(depthFraction=INTERIOR_DEPTH_FRACTION, normalBytes=INTERIOR_NORMAL_BYTES, pixels=int(interior.sum()),
                                 silhouettePixels=int(geometry.sum())),
                   lightmappedClassOnly=classes is not None)
    controls = {}
    for variant in IRRADIANCE_VARIANTS[1:]:
        control = irradiance_metrics(unity, read_native_irradiance(ours / files[variant], width, height), mask)
        controls[variant] = dict(meanRelative=control["meanRelative"], p99Relative=control["p99Relative"], fails=not control["passes"])
    section["controls"] = controls
    section["passes"] = section["passes"] and repeat == 0 and all(c["fails"] for c in controls.values())
    result["irradiance"] = section
    return result


def compare_case(trace, case, original, ours, oracle=None, oracle_trace=None):
    record = trace["cases"][case]
    native = json.loads((ours / "native-map.json").read_text())
    after = record["settled"]
    root = after["mapRoot"]
    if root is None: raise ValueError(f"{case}: the original has no map root after the load")
    if native["depthFar"] != trace["depthFar"] or native["width"] != trace["width"] or native["height"] != trace["height"]:
        raise ValueError(f"{case}: our capture is not at the original's size and far plane")
    ca = after["caMap"]
    result = dict(case=case, scene=record["scene"], sceneSHA256=record["sceneSHA256"], ourSceneSHA256=native["sceneSHA256"])
    # The record our parser read.
    record_error = max(abs(a - b) for a, b in zip(native["transform"]["position"] + native["transform"]["rotationDegrees"], ca["pos"] + ca["rot"]))
    sun_ok = "sunLightType" not in after or native.get("sunLightType") == after["sunLightType"]
    record_ok = native["map"] == after["sceneInfoMap"] == trace["mapNo"] and record_error <= 1e-6 and native["sceneSHA256"] == record["sceneSHA256"] and sun_ok
    result["record"] = dict(map=native["map"], originalMap=after["sceneInfoMap"], sunLightType=native.get("sunLightType"),
                            originalSunLightType=after.get("sunLightType"), maximumError=record_error, passes=record_ok)
    # MapCtrl.Reflect, computed independently.
    expected = unity_euler(ca["rot"])
    position_error = float(np.abs(np.array(root["localPosition"]) - np.array(ca["pos"])).max())
    rotation_error = angle_degrees(np.array(root["localRotation"]), expected)
    scale_error = float(np.abs(np.array(root["lossyScale"]) - 1).max())
    wrong_order = angle_degrees(np.array(root["localRotation"]), unity_euler(ca["rot"], "xyz"))
    result["rule"] = dict(positionError=position_error, rotationErrorDegrees=rotation_error, scaleError=scale_error,
                          tolerance=dict(position=1e-5, rotationDegrees=1e-3, scale=1e-5),
                          passes=position_error <= 1e-5 and rotation_error <= 1e-3 and scale_error <= 1e-5,
                          wrongEulerOrderControl=dict(errorDegrees=wrong_order, applicable=any(ca["rot"]), fails=wrong_order > 1e-3))
    # Our placement against the original's.
    ours_root = BASIS @ matrix(native["mapRoot"]) @ BASIS
    placement_error = float(np.abs(ours_root - matrix(root["localToWorld"])).max())
    skies = [d for d in native["draws"] if d.get("draw") == "sky"]
    draws = [d for d in native["draws"] if d.get("draw") != "sky"]
    draw_error = max(float(np.abs(matrix(d["model"]) - matrix(native["mapRoot"])).max()) for d in draws)
    flags_ok = all(d["objectID"] == 0 and not d["castsShadow"] and not d["outline"] for d in native["draws"]) \
        and all(d["pickOccluder"] for d in draws) and not any(d["pickOccluder"] for d in skies)
    result["placement"] = dict(mapRootError=placement_error, drawModelError=draw_error, draws=len(native["draws"]),
                               drawsArePickOccludersWithoutShadowOrOutline=flags_ok, tolerance=1e-5,
                               passes=placement_error <= 1e-5 and draw_error <= 1e-5 and flags_ok)
    original_skies = [r for r in record.get("capture", {}).get("mapRenderers", []) if r.get("class") == "sky"]
    if skies or original_skies:
        sky_ok, sky_error = len(skies) == len(original_skies), math.inf
        if sky_ok:
            def relative(ours_model, theirs):
                a, b = BASIS @ matrix(ours_model) @ BASIS, matrix(theirs)
                return float((np.abs(a - b) / np.maximum(1.0, np.abs(b))).max())
            # Each of our sky draws against its nearest original sky renderer (one per sun type in practice).
            sky_error = max(min(relative(d["model"], r["localToWorld"]) for r in original_skies) for d in skies)
            sky_ok = sky_error <= 1e-5
        result["placement"].update(skyDraws=len(skies), originalSkyRenderers=len(original_skies), skyModelRelativeError=sky_error)
        result["placement"]["passes"] = result["placement"]["passes"] and sky_ok
    # The camera.
    main = record["capture"]["main"]
    view_error = float(np.abs(matrix(native["camera"]["view"]) - matrix(main["worldToCamera"]) @ BASIS).max())
    fov_error = abs(native["camera"]["fovDegrees"] - main["fieldOfView"])
    result["camera"] = dict(viewError=view_error, fovErrorDegrees=fov_error, fovDegrees=main["fieldOfView"],
                            tolerance=dict(view=1e-5, fovDegrees=1e-4), passes=view_error <= 1e-5 and fov_error <= 1e-4)
    # Map-only images.
    names = dict(originalGeometry=original / f"original-{case}-map-geometry.png", nativeGeometry=ours / "native-map-geometry.png",
                 originalDepthNormals=original / f"original-{case}-map-depth-normals.png", nativeDepthNormals=ours / "native-map-depth-normals.png",
                 originalColor=original / f"original-{case}-color.png", nativeColor=ours / "native-color.png")
    a = pixels(names["originalGeometry"])[:, :, 0] > 127; b = pixels(names["nativeGeometry"])[:, :, 0] > 127
    result["geometry"] = geometry_metrics(a, b)
    od = pixels(names["originalDepthNormals"]); nd = pixels(names["nativeDepthNormals"])
    result["depthNormals"] = depth_metrics(od, nd, a & b, float(trace["depthFar"]))
    shifted = np.roll(nd, 1, axis=1)
    control = depth_metrics(od, shifted, a & b, float(trace["depthFar"]))
    result["depthNormals"]["onePixelShiftControl"] = dict(p99Metres=control["p99Metres"], normalP99ChannelBytes=control["normalP99ChannelBytes"],
                                                          fails=not control["passes"])
    # Colour, reported only.
    oc = pixels(names["originalColor"]); nc = pixels(names["nativeColor"])
    census = native.get("census", {})
    lightmapped = (census.get("lightmappedDraws") or 0) > 0
    reason = ("approximated shading: the baked lightmaps are drawn; the realtime sun and its shadows, specular and reflections, "
              "normal, metallic and detail maps, fog and the original image effects are not reproduced") if lightmapped else \
             ("approximated shading: the converted map draws with the item toon material under the scene light; "
              "baked lightmaps, map lights, sun-type lighting, fog, ambient and the original image effects are not reproduced")
    if census.get("skyDraws") or census.get("particleDraws"):
        reason += "; the cube sky and particles are drawn (no soft-particle fade or per-renderer sorting), light-probe-lit parts as items"
    result["color"] = dict(gated=False, lightmappedDraws=census.get("lightmappedDraws"), reason=reason, **color_error(oc, nc))
    gated = ["record", "rule", "placement", "camera", "geometry", "depthNormals"]
    if oracle is not None:
        result.update(oracle_case(oracle_trace, case, oracle, ours, native, a & b, od, nc, trace["width"], trace["height"], float(trace["depthFar"])))
        gated += [k for k in ("irradiance", "sky", "particles") if result[k].get("gated")]
    result["images"] = {k: dict(file=str(v), sha256=digest(v)) for k, v in names.items()}
    result["passes"] = all(result[k]["passes"] for k in gated) \
        and (result["rule"]["wrongEulerOrderControl"]["fails"] or not result["rule"]["wrongEulerOrderControl"]["applicable"]) \
        and result["depthNormals"]["onePixelShiftControl"]["fails"]
    return result


def compare(original, ours_by_case, oracle=None):
    trace = json.loads((original / "map-trace.json").read_text())
    oracle_file = None if oracle is None else oracle / "oracle-trace.json" if (oracle / "oracle-trace.json").is_file() else oracle / "map-trace.json"
    oracle_trace = json.loads(oracle_file.read_text()) if oracle_file is not None else None
    if oracle_trace is not None and (oracle_trace["width"], oracle_trace["height"]) != (trace["width"], trace["height"]):
        raise ValueError("the oracle is not at the original captures' size")
    cases = [compare_case(trace, case, original, ours, oracle, oracle_trace) for case, ours in ours_by_case]
    result = dict(schemaVersion=1, scope=__doc__.strip().splitlines()[0], mapNo=trace["mapNo"], depthFar=trace["depthFar"],
                  width=trace["width"], height=trace["height"], traceSHA256=digest(original / "map-trace.json"),
                  cases=cases, passes=all(c["passes"] for c in cases))
    if oracle is not None: result["oracleTraceSHA256"] = digest(oracle_file)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--original", type=Path, required=True, help="original_map_probe.py capture output folder")
    p.add_argument("--case", nargs=2, action="append", metavar=("CASE", "OURS"), required=True,
                   help="a trace case label and our IKKOKU_SOURCE_MAP_PROBE folder for its scene (repeatable)")
    p.add_argument("--oracle", type=Path, help="original_map_probe.py oracle output folder (adds cleanColor and the irradiance gate)")
    p.add_argument("--output", type=Path, help="write the comparison JSON here")
    a = p.parse_args()
    result = compare(a.original, [(case, Path(folder)) for case, folder in a.case], a.oracle)
    text = json.dumps(result, indent=2) + "\n"
    if a.output: a.output.parent.mkdir(parents=True, exist_ok=True); a.output.write_text(text)
    for c in result["cases"]:
        print(f"{c['case']}: {'PASS' if c['passes'] else 'FAIL'} rule {c['rule']['rotationErrorDegrees']:.2e} deg, placement {c['placement']['mapRootError']:.1e}, "
              f"camera {c['camera']['viewError']:.1e}, IoU {c['geometry']['intersectionOverUnion']:.6f}, depth p99 {c['depthNormals']['p99Metres']:.2e} m "
              f"(max {c['depthNormals']['maximumMetres']:.2e}), normal p99 {c['depthNormals']['normalP99ChannelBytes']}, colour MAE {c['color']['meanAbsoluteChannelBytes']:.1f} (not gated)"
              + (f", clean-colour MAE {c['cleanColor']['meanAbsoluteChannelBytes']:.1f}" if "cleanColor" in c else "")
              + (f", irradiance mean {c['irradiance']['meanRelative']:.4f} p99 {c['irradiance']['p99Relative']:.4f}"
                 f" (controls {', '.join(f'{k} p99 {v['p99Relative']:.3f}' for k, v in c['irradiance']['controls'].items())})"
                 if c.get("irradiance", {}).get("gated") else "")
              + (f", sky mean {c['sky']['meanRelative']:.2e} p99 {c['sky']['p99Relative']:.2e}"
                 f" (controls {', '.join(f'{k} p99 {v['p99Relative']:.3f}' for k, v in c['sky']['controls'].items())})"
                 if c.get("sky", {}).get("controls") else "")
              + (f", particles IoU {c['particles']['footprintIoU']:.4f} mean {c['particles']['meanRelative']:.4f} p99 {c['particles']['p99Relative']:.4f}"
                 f" (controls {', '.join(f'{k} p99 {v['p99Relative']:.3f}' for k, v in c['particles']['controls'].items())})"
                 if c.get("particles", {}).get("comparedPixels") else ""))
    raise SystemExit(0 if result["passes"] else 1)


if __name__ == "__main__":
    main()
