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
Colour is reported, never gated: the converted map is drawn with the item toon
material under the scene light and the catalog lists what it leaves out. Two
controls must FAIL: our depth image shifted one pixel, and (for a case with a
nonzero map rotation) that rotation composed in the wrong Euler order (X, Y, Z).
"""
from __future__ import annotations
import argparse, hashlib, json, math
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


def compare_case(trace, case, original, ours):
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
    record_ok = native["map"] == after["sceneInfoMap"] == trace["mapNo"] and record_error <= 1e-6 and native["sceneSHA256"] == record["sceneSHA256"]
    result["record"] = dict(map=native["map"], originalMap=after["sceneInfoMap"], maximumError=record_error, passes=record_ok)
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
    draw_error = max(float(np.abs(matrix(d["model"]) - matrix(native["mapRoot"])).max()) for d in native["draws"])
    flags_ok = all(d["objectID"] == 0 and d["pickOccluder"] and not d["castsShadow"] and not d["outline"] for d in native["draws"])
    result["placement"] = dict(mapRootError=placement_error, drawModelError=draw_error, draws=len(native["draws"]),
                               drawsArePickOccludersWithoutShadowOrOutline=flags_ok, tolerance=1e-5,
                               passes=placement_error <= 1e-5 and draw_error <= 1e-5 and flags_ok)
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
    oc = pixels(names["originalColor"]).astype(np.int16)[:, :, :3]; nc = pixels(names["nativeColor"]).astype(np.int16)[:, :, :3]
    error = np.abs(oc - nc)
    result["color"] = dict(gated=False, meanAbsoluteChannelBytes=float(error.mean()), p99ChannelBytes=float(np.percentile(error, 99)),
                           reason="approximated shading: the converted map draws with the item toon material under the scene light; "
                                  "baked lightmaps, map lights, sun-type lighting, fog, ambient and the original image effects are not reproduced")
    result["images"] = {k: dict(file=str(v), sha256=digest(v)) for k, v in names.items()}
    result["passes"] = all(result[k]["passes"] for k in ("record", "rule", "placement", "camera", "geometry", "depthNormals")) \
        and (result["rule"]["wrongEulerOrderControl"]["fails"] or not result["rule"]["wrongEulerOrderControl"]["applicable"]) \
        and result["depthNormals"]["onePixelShiftControl"]["fails"]
    return result


def compare(original, ours_by_case):
    trace = json.loads((original / "map-trace.json").read_text())
    cases = [compare_case(trace, case, original, ours) for case, ours in ours_by_case]
    return dict(schemaVersion=1, scope=__doc__.strip().splitlines()[0], mapNo=trace["mapNo"], depthFar=trace["depthFar"],
                width=trace["width"], height=trace["height"], traceSHA256=digest(original / "map-trace.json"),
                cases=cases, passes=all(c["passes"] for c in cases))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--original", type=Path, required=True, help="original_map_probe.py capture output folder")
    p.add_argument("--case", nargs=2, action="append", metavar=("CASE", "OURS"), required=True,
                   help="a trace case label and our IKKOKU_SOURCE_MAP_PROBE folder for its scene (repeatable)")
    p.add_argument("--output", type=Path, help="write the comparison JSON here")
    a = p.parse_args()
    result = compare(a.original, [(case, Path(folder)) for case, folder in a.case])
    text = json.dumps(result, indent=2) + "\n"
    if a.output: a.output.parent.mkdir(parents=True, exist_ok=True); a.output.write_text(text)
    for c in result["cases"]:
        print(f"{c['case']}: {'PASS' if c['passes'] else 'FAIL'} rule {c['rule']['rotationErrorDegrees']:.2e} deg, placement {c['placement']['mapRootError']:.1e}, "
              f"camera {c['camera']['viewError']:.1e}, IoU {c['geometry']['intersectionOverUnion']:.6f}, depth p99 {c['depthNormals']['p99Metres']:.2e} m "
              f"(max {c['depthNormals']['maximumMetres']:.2e}), normal p99 {c['depthNormals']['normalP99ChannelBytes']}, colour MAE {c['color']['meanAbsoluteChannelBytes']:.1f} (not gated)")
    raise SystemExit(0 if result["passes"] else 1)


if __name__ == "__main__":
    main()
