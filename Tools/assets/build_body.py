"""Build Assets/Characters/body_<sex>.glb from the CC0 MakeHuman base mesh.

Run:  Blender -b --python Tools/assets/build_body.py -- --sex f [--no-ao]

Steps: base.obj + macro target -> anime restyle (deform.py) -> proxy fitting
(eyes, eyelashes, eyebrows, teeth, tongue via .mhclo) -> armature + weights
(rig.py) -> morph targets -> _REGION attribute -> GLB export -> validation.
Also writes Tools/assets/out/body_<sex>.npz consumed by textures/hair/clothes.
"""
import sys, os, json, math, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from common import *
import landmarks as LM
import deform as DF
import rig as RG

SEX_CFG = {
    "f": dict(target="caucasian-female-young.target",
              restyle=dict(head=1.15, eye=1.5, nose=0.65, mouth=0.85, neck=0.85, legs=1.06, limbs=0.92, face_smooth=2)),
    "m": dict(target="caucasian-male-young.target",
              restyle=dict(head=1.12, eye=1.35, nose=0.65, mouth=0.9, neck=0.95, legs=1.05, limbs=0.95, face_smooth=2)),
}
EYE_FORWARD = 0.003     # max eyeball shift toward the face surface (m)
EYE_SHRINK_MAX = 0.08   # the lid-fit may shrink the eyeball by at most this fraction
EYE_MORPHS = ["eye.size", "eye.height", "eye.spacing", "eye.depth"]
LASH_MORPHS = ["eye.size", "eye.height", "eye.spacing", "eye.depth", "eye.angle", "eye.width", "eye.outer_height", "eye.inner_height",
               "eye.lid_upper", "eye.lid_lower", "exp.blink_L", "exp.blink_R", "exp.eye_wide", "exp.eye_smile", "exp.squint",
               "face.head_width", "face.head_height", "face.upper_depth"]
BROW_MORPHS = ["exp.brow_up", "exp.brow_angry", "exp.brow_sad", "eye.height", "eye.spacing", "face.head_width", "face.head_height", "face.upper_depth"]


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--sex", default="f")
    ap.add_argument("--no-ao", action="store_true")
    ap.add_argument("--out", default=None)
    return ap.parse_args(argv)


def obj_groups(base):
    g = {}
    for f, gn in zip(base["faces"], base["groups"]):
        g.setdefault(gn, set()).update(f)
    return {k: sorted(v) for k, v in g.items()}


def uv_loops_for(base, faces_idx):
    vt = base["vt"]
    out = []
    for fi in faces_idx:
        for ti in base["fuv"][fi]:
            out.append(vt[ti] if ti >= 0 else (0.0, 0.0))
    return np.asarray(out, np.float64)


def proxy_mesh_uvs(mesh, face_ids):
    vt = mesh["vt"]
    out = []
    for fi in face_ids:
        for ti in mesh["fuv"][fi]:
            out.append(vt[ti] if (ti >= 0 and len(vt)) else (0.0, 0.0))
    return np.asarray(out, np.float64)


def submesh(V, faces, keep_vert_mask):
    """Faces whose vertices are all kept; returns (Vsub, faces_sub, old_face_ids, old_vert_ids)."""
    keep = np.asarray(keep_vert_mask, bool)
    fid = [i for i, f in enumerate(faces) if all(keep[v] for v in f)]
    used = sorted({v for i in fid for v in faces[i]})
    remap = {v: i for i, v in enumerate(used)}
    fs = [[remap[v] for v in faces[i]] for i in fid]
    return V[used], fs, fid, np.asarray(used)


def vertex_ao(ob, n_dirs=24, max_dist=0.6, seed=7):
    """Cheap per-vertex ambient occlusion by BVH ray casting (cosine-weighted hemisphere)."""
    me = ob.data
    bvh = BVHTree.FromObject(ob, bpy.context.evaluated_depsgraph_get())
    n = len(me.vertices)
    co = np.empty(n * 3, np.float32); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
    nm = np.empty(n * 3, np.float32); me.vertices.foreach_get("normal", nm); nm = nm.reshape(-1, 3)
    rng = np.random.default_rng(seed)
    # fixed set of directions on the unit hemisphere (z up), rotated per-vertex into the normal frame
    u = (np.arange(n_dirs) + 0.5) / n_dirs; phi = 2 * math.pi * ((np.arange(n_dirs) * 0.618034) % 1.0)
    dz = np.sqrt(u); rr = np.sqrt(1 - u)
    dirs = np.stack([rr * np.cos(phi), rr * np.sin(phi), dz], 1)
    ao = np.zeros(n, np.float32)
    for i in range(n):
        nrm = nm[i]; t = np.cross(nrm, [0, 0, 1] if abs(nrm[2]) < 0.9 else [1, 0, 0]); t /= np.linalg.norm(t); b = np.cross(nrm, t)
        origin = Vector(co[i] + nrm * 0.0015)
        hits = 0
        for d in dirs:
            wd = d[0] * t + d[1] * b + d[2] * nrm
            loc, _, _, dist = bvh.ray_cast(origin, Vector(wd), max_dist)
            if loc is not None:
                hits += 1.0 - min(dist / max_dist, 1.0) ** 0.5 * 0.7
        ao[i] = 1.0 - hits / n_dirs
    return ao


def vertex_concavity(V, adj, N):
    indptr, idx = adj
    row = np.repeat(np.arange(len(V)), np.diff(indptr)); deg = np.maximum(np.diff(indptr), 1)
    nb = np.zeros_like(V); np.add.at(nb, row, V[idx]); nb /= deg[:, None]
    return ((nb - V) * N).sum(1)


def main():
    args = parse_args()
    sex = args.sex; cfg = SEX_CFG[sex]
    out_glb = args.out or os.path.join(A_CHAR, "body_%s.glb" % sex)
    bl_reset()
    # ------------------------------------------------------------------ base mesh
    base = load_obj(os.path.join(MH, "base.obj"))
    groups = obj_groups(base)
    T = load_target(os.path.join(MH, cfg["target"]))
    Vmh0 = base["v"] + T
    ground = Vmh0[groups["joint-ground"]][:, 1].mean()
    V0 = mh_to_bl(Vmh0, ground)
    body_fid = [i for i, g in enumerate(base["groups"]) if g == "body"]
    body_faces = [base["faces"][i] for i in body_fid]
    body_uv = uv_loops_for(base, body_fid)
    tris = triangulate(body_faces); adj = build_adjacency(body_faces, N_BODY)
    log("base: %d verts (%d body), %d body faces, %d tris, height %.3f m" % (len(V0), N_BODY, len(body_faces), len(tris), V0[:N_BODY, 2].max()))
    L0 = LM.compute(V0, body_faces, groups, tris=tris)
    # eyeball/lid gap reference (pre-restyle)
    eyes_p = load_mhclo(os.path.join(MH, "system/eyes/high-poly/high-poly.mhclo"))
    eyes_V0 = mh_to_bl(fit_proxy(eyes_p, Vmh0), ground)
    comp, ncomp = connected_components(eyes_p.mesh["faces"], len(eyes_V0))

    def eyeball_parts(EV):
        parts = {}
        for side, sgn in (("L", 1), ("R", -1)):
            cands = [c for c in range(ncomp) if (EV[comp == c][:, 0] * sgn > 0).all()]
            big = max(cands, key=lambda c: (comp == c).sum())  # 276-vert inner sphere = iris-textured eyeball
            parts[side] = big
        return parts

    parts0 = eyeball_parts(eyes_V0)
    gap_ratio = {}
    for side in ("L", "R"):
        c, r = fit_sphere(eyes_V0[comp == parts0[side]])
        B0 = V0[:N_BODY]; d = np.linalg.norm(B0 - c, axis=1)
        lid = (d < 1.6 * r) & (B0[:, 1] < c[1] - 0.55 * r)
        gap_ratio[side] = float(d[lid].min() / r)
    log("eyeball: source radius %.4f, lid/eyeball ratio L %.3f R %.3f" % (r, gap_ratio["L"], gap_ratio["R"]))
    # ------------------------------------------------------------------ restyle
    V1, L = DF.restyle_anime(V0, body_faces, groups, tris, adj, cfg["restyle"])
    LM.describe(L)
    J = LM.joint_positions(V1, groups)
    B = V1[:N_BODY]
    Vmh1 = bl_to_mh(V1, ground)
    N = vertex_normals(B, tris)
    # ------------------------------------------------------------------ proxies
    def fit(rel):
        p = load_mhclo(os.path.join(MH, rel))
        return p, mh_to_bl(fit_proxy(p, Vmh1), ground)
    eyes_V = mh_to_bl(fit_proxy(eyes_p, Vmh1), ground)
    lash_p, lash_V = fit("system/eyelashes/eyelashes01/eyelashes01.mhclo")
    brow_p, brow_V = fit("system/eyebrows/eyebrow001/eyebrow001.mhclo")
    teeth_p, teeth_V = fit("system/teeth/teeth_base/teeth_base.mhclo")
    tongue_p, tongue_V = fit("system/tongue/tongue01/tongue01.mhclo")
    parts = eyeball_parts(eyes_V)
    eye_objs = {}; eye_info = {}
    for side in ("L", "R"):
        keep = comp == parts[side]
        EV, EF, fid, used = submesh(eyes_V, eyes_p.mesh["faces"], keep)
        c, r = fit_sphere(EV)
        d = np.linalg.norm(B - c, axis=1); lid = (d < 1.6 * r) & (B[:, 1] < c[1] - 0.55 * r)
        r_target = d[lid].min() / gap_ratio[side]
        # anime eye: bring the eyeball up to EYE_FORWARD toward the skin surface (the socket rim
        # otherwise stands well in front of the iris) and re-fit the radius to the lids from the new
        # centre; the shift is reduced until the lid-fit shrinks the ball by at most EYE_SHRINK_MAX
        for fwd in np.arange(EYE_FORWARD, 0.0009, -0.0005):
            c2 = c + np.array([0.0, -fwd, 0.0])
            d2 = np.linalg.norm(B - c2, axis=1); lid2 = (d2 < 1.6 * r) & (B[:, 1] < c2[1] - 0.55 * r)
            r_target2 = d2[lid2].min() / gap_ratio[side]
            if r_target2 >= r_target * (1 - EYE_SHRINK_MAX):
                break
        log("eye_%s: moved %.1f mm forward; lid-fit radius %.4f -> %.4f (%.1f%%)" % (side, fwd * 1000, r_target, r_target2, 100 * (r_target2 / r_target - 1)))
        EV = c2 + (EV - c) * (r_target2 / r)
        c, r = fit_sphere(EV)
        # fresh planar UVs centred on the front pole (iris centred at 0.5,0.5)
        loc = EV - c
        uv_v = np.stack([0.5 + loc[:, 0] / (2 * r), 0.5 + loc[:, 2] / (2 * r)], 1)
        uv_loops = np.concatenate([uv_v[f] for f in EF])
        ob = bl_make_mesh("eye_" + side, EV, EF, uv_loops, bl_material("ik_eye", (1, 1, 1, 1)))
        eye_objs[side] = ob; eye_info[side] = dict(centre=c.tolist(), radius=float(r), verts=len(EV), tris=int(sum(len(f) - 2 for f in EF)))
        L["eye_" + side] = c
        log("eye_%s: %d verts, centre %s, radius %.4f (rescaled from %.4f)" % (side, len(EV), np.round(c, 4), r, r_target))
    L["eye_r"] = float((eye_info["L"]["radius"] + eye_info["R"]["radius"]) / 2)
    # ------------------------------------------------------------------ blender objects
    mat_skin = bl_material("ik_skin_body", (0.96, 0.92, 0.90, 1))
    body = bl_make_mesh("body", B, body_faces, body_uv, mat_skin)
    lash = bl_make_mesh("eyelash", lash_V, lash_p.mesh["faces"], proxy_mesh_uvs(lash_p.mesh, range(len(lash_p.mesh["faces"]))), bl_material("ik_eyelash", (0.2, 0.15, 0.2, 1)))
    brow = bl_make_mesh("eyebrow", brow_V, brow_p.mesh["faces"], proxy_mesh_uvs(brow_p.mesh, range(len(brow_p.mesh["faces"]))), bl_material("ik_eyebrow", (0.35, 0.25, 0.25, 1)))
    mat_mouth = bl_material("ik_mouth", (0.95, 0.9, 0.9, 1))
    teeth = bl_make_mesh("teeth", teeth_V, teeth_p.mesh["faces"], proxy_mesh_uvs(teeth_p.mesh, range(len(teeth_p.mesh["faces"]))), mat_mouth)
    tongue = bl_make_mesh("tongue", tongue_V, tongue_p.mesh["faces"], proxy_mesh_uvs(tongue_p.mesh, range(len(tongue_p.mesh["faces"]))), mat_mouth)
    for o in (lash, brow, teeth, tongue):
        log("%s: %d verts %d faces" % (o.name, len(o.data.vertices), len(o.data.polygons)))
    # ------------------------------------------------------------------ rig
    bones = RG.bone_table(J, L)
    arm = RG.build_armature(bones, "Armature")
    bone_names = [b["name"] for b in bones]
    deform_names = [b["name"] for b in bones if b["deform"]]
    RG.auto_weight(body, arm)
    W = RG.get_weights_dense(body, bone_names)
    tot = W.sum(1)
    n_zero = int((tot < 1e-4).sum())
    empty_bones = [b for j, b in enumerate(bone_names) if b in deform_names and W[:, j].max() < 1e-4]
    log("heat weights: %d/%d verts covered, empty deform bones: %s" % (N_BODY - n_zero, N_BODY, empty_bones or "none"))
    if n_zero > 0 or empty_bones:
        log("falling back to numpy weights for %d uncovered verts" % n_zero)
        Wf = RG.numpy_weights(B, bones, deform_names, adj)
        Wfull = np.zeros_like(W)
        for j, b in enumerate(deform_names):
            Wfull[:, bone_names.index(b)] = Wf[:, j]
        bad = tot < 1e-4
        W[bad] = Wfull[bad]
    # bust bones: manual radial weights on top of heat weights
    for side in ("L", "R"):
        m = DF.m_radial(B, L["bust_base_" + side], 0.02, 0.09) * DF.m_front(B, L["bust_base_" + side][1] + 0.03, 0.02)
        j = bone_names.index("bust_" + side)
        W *= (1 - 0.9 * m)[:, None]
        W[:, j] += 0.9 * m
    W = RG.set_weights_dense(body, bone_names, W, limit=4)
    for b in arm.data.bones:
        if b.name.startswith(("eye_", "bust_")):
            b.use_deform = True
    infl = (W > 1e-5).sum(1)
    log("weights: max influences %d, mean %.2f, verts with 0 weight: %d" % (infl.max(), infl.mean(), int((W.sum(1) < 0.5).sum())))
    # other meshes: parent + armature modifier + single-group weights
    def bind(ob, group, w=1.0):
        vg = ob.vertex_groups.new(name=group)
        vg.add(list(range(len(ob.data.vertices))), w, "REPLACE")
        mod = ob.modifiers.new("Armature", "ARMATURE"); mod.object = arm
        ob.parent = arm
    for side in ("L", "R"):
        bind(eye_objs[side], "eye_" + side)
    for o in (lash, brow, teeth, tongue):
        bind(o, "head")
    # ------------------------------------------------------------------ regions
    regions = RG.region_ids(W, bone_names, B, L)
    attr = body.data.attributes.new("_REGION", "INT", "POINT")
    attr.data.foreach_set("value", regions.astype(np.int32))
    counts = {name: int((regions == rid).sum()) for name, rid in RG.REGIONS.items()}
    log("regions:", counts, "head/neck(0):", int((regions == 0).sum()))
    # ------------------------------------------------------------------ morph targets
    M = DF.morph_table(L)
    body_morphs = DF.evaluate_morphs(M, B, N)
    mags = {}
    for name, d in body_morphs.items():
        bl_add_shape_key(body, name, d)
        mags[name] = float(np.abs(d).max())
    log("morphs on body: %d; max |delta| mm: %s" % (len(body_morphs), {k: round(v * 1000, 1) for k, v in mags.items()}))
    weak = [k for k, v in mags.items() if v < 0.0015]
    if weak:
        log("WARNING weak morphs (<1.5mm):", weak)
    for side in ("L", "R"):
        for name, d in DF.evaluate_morphs(M, bl_get_verts(eye_objs[side]), None, EYE_MORPHS).items():
            bl_add_shape_key(eye_objs[side], name, d)
    for name, d in DF.evaluate_morphs(M, lash_V, None, LASH_MORPHS).items():
        bl_add_shape_key(lash, name, d)
    for name, d in DF.evaluate_morphs(M, brow_V, None, BROW_MORPHS).items():
        bl_add_shape_key(brow, name, d)
    # ------------------------------------------------------------------ vertex AO / concavity for textures
    bpy.context.view_layer.update()
    ao = np.ones(N_BODY, np.float32) if args.no_ao else vertex_ao(body)
    conc = vertex_concavity(B, adj, N)
    log("vertex AO: min %.2f mean %.2f; concavity range %.4f..%.4f" % (ao.min(), ao.mean(), conc.min(), conc.max()))
    # ------------------------------------------------------------------ export
    objs = [arm, body, eye_objs["L"], eye_objs["R"], lash, brow, teeth, tongue]
    body.data["ikkoku"] = "body"
    bl_export_glb(out_glb, objs, images="NONE")
    info, js, blob = glb_summary(out_glb)
    # sidecar regions file in exported vertex order (+ verify attribute round trip)
    mesh_js = [m for m in js["meshes"] if m["name"] == "body"][0]
    prim = mesh_js["primitives"][0]
    if "_REGION" in prim["attributes"]:
        reg_exp = read_accessor(js, blob, prim["attributes"]["_REGION"])[:, 0]
        pos = read_accessor(js, blob, prim["attributes"]["POSITION"])
        pos_bl = np.stack([pos[:, 0], -pos[:, 2], pos[:, 1]], 1)
        idx, dist = nearest_points(B, pos_bl, chunk=512)
        ok = float((regions[idx] == np.rint(reg_exp).astype(np.uint8)).mean())
        log("_REGION attribute exported as componentType %d, %d values, order check %.4f (max pos err %.2e)" % (
            js["accessors"][prim["attributes"]["_REGION"]]["componentType"], len(reg_exp), ok, dist.max()))
        side = out_glb.replace(".glb", ".regions.bin")
        with open(side, "wb") as f:
            f.write(np.rint(reg_exp).astype(np.uint8).tobytes())
        log("wrote sidecar %s (%d bytes)" % (os.path.relpath(side, REPO), len(reg_exp)))
    # ------------------------------------------------------------------ data for downstream scripts
    np.savez_compressed(os.path.join(OUT, "body_%s.npz" % sex),
                        V=B.astype(np.float32), V_all=V1.astype(np.float32), Vmh_all=Vmh1.astype(np.float32), ground=ground,
                        tris=tris.astype(np.int32), faces_flat=np.concatenate([np.asarray(f) for f in body_faces]).astype(np.int32),
                        faces_len=np.asarray([len(f) for f in body_faces], np.int32), uv_loops=body_uv.astype(np.float32),
                        normals=N.astype(np.float32), W=W.astype(np.float32), bone_names=np.asarray(bone_names),
                        bones=json.dumps(bones), landmarks=json.dumps({k: (v.tolist() if isinstance(v, np.ndarray) else (v if not isinstance(v, tuple) else [x.tolist() for x in v])) for k, v in L.items() if k not in ("J", "lip_upper_idx", "lip_lower_idx")}),
                        joints=json.dumps({k: v.tolist() for k, v in J.items()}), regions=regions, ao=ao, concavity=conc.astype(np.float32),
                        eye_info=json.dumps(eye_info), morph_mags=json.dumps(mags))
    log("saved out/body_%s.npz" % sex)
    # ------------------------------------------------------------------ re-import validation
    bl_reset()
    bpy.ops.import_scene.gltf(filepath=out_glb)
    names = sorted(o.name for o in bpy.data.objects)
    arms = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    sk = bpy.data.objects["body"].data.shape_keys
    log("re-import ok: objects %s; bones %d; body shape keys %d" % (names, len(arms[0].data.bones) if arms else 0, len(sk.key_blocks) - 1 if sk else 0))
    summary = dict(file=os.path.relpath(out_glb, REPO), bytes=os.path.getsize(out_glb), bones=bone_names, morphs=list(body_morphs.keys()),
                   eye=eye_info, regions=counts, morph_mags_mm={k: round(v * 1000, 2) for k, v in mags.items()})
    write_json(os.path.join(OUT, "body_%s_summary.json" % sex), summary)


if __name__ == "__main__":
    main()
