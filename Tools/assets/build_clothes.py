"""Clothes -> Assets/Clothes/<slot>_<name>.glb (+ <file>_cm.png ColorMask, <file>_bm.png body mask)
(run inside Blender)

  Blender -b --factory-startup --python build_clothes.py -- [--sex f] [--only top_sailor,...]

Reused CC0 MakeHuman garments are refit to the restyled body via their .mhclo
mapping, split into top/bottom by connected component and pushed to a minimum
distance from the skin (layer offsets, see OFFSETS). Procedural garments are
built from the body: offset region shells with clean cut planes (socks,
pantyhose, gloves, bra, underwear), shoe hulls, a lofted knife-pleated skirt,
and a sailor collar + ribbon on top of the refit T-shirt.

Skin weights are copied from the nearest body vertex *of the regions the slot
covers* (WEIGHT_REGIONS), never from fingers or the far side of the body.

Per garment:
  <file>_cm.png  ColorMask in the garment's UV space (R/G/B = tint zones 1/2/3,
                 background = zone 1 red, islands dilated 4 px). Procedural parts
                 are packed into a free tile of the atlas so they never overlap
                 the garment's islands.
  <file>_bm.png  body mask in BODY UV space, 1024^2: white = skin pixel hidden
                 under the garment. A body vertex counts as covered when the ray
                 along its normal hits a same-facing garment face within the
                 slot's reach (or the garment is within 2 mm), unless it is within
                 1.5 cm of an opening edge. Dilated 3 px.
  extras.hideBody  regions with >= 90 % of their vertices covered.
"""
import sys, os, json, math, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree
from common import *
import rig as RG
import deform as DF
from build_hair import Body, resample

REG = RG.REGIONS
REG_NAMES = {v: k for k, v in REG.items()}

# layer offsets (metres): distance between the skin and the garment surface
OFFSETS = dict(bra=0.002, underwear=0.002, pantyhose=0.0015, gloves=0.0015,
               socks=0.0025,            # worn over pantyhose (1.5 mm): +1 mm so the two shells never coincide
               top=0.007, bottom=0.007, skirt=0.007, blazer=0.010, dress=0.010, shoes=0.005)
# body-mask ray reach per garment kind (how far above the skin a garment face still "covers" it)
MASK_REACH = dict(tight=0.006, shoes=0.012, top=0.05, bottom=0.06, skirt=0.12, dress=0.12, blazer=0.06)
MASK_MARGIN = 0.015    # skin within this distance of an opening edge stays visible
# body regions whose vertices may donate skin weights, per slot
_ARMS = ["upperarm_L", "upperarm_R", "forearm_L", "forearm_R"]
_LEGS = ["thigh_L", "thigh_R", "calf_L", "calf_R"]
WEIGHT_REGIONS = {
    "top": ["torso_upper", "torso_lower"] + _ARMS, "bra": ["torso_upper"],
    "bottom": ["torso_lower"] + _LEGS, "underwear": ["torso_lower", "thigh_L", "thigh_R"],
    "pantyhose": ["torso_lower"] + _LEGS + ["foot_L", "foot_R"], "socks": ["calf_L", "calf_R", "foot_L", "foot_R"],
    "shoes_in": ["calf_L", "calf_R", "foot_L", "foot_R"], "shoes_out": ["calf_L", "calf_R", "foot_L", "foot_R"],
    "gloves": ["hand_L", "hand_R", "forearm_L", "forearm_R"],
}


class Garment:
    def __init__(self, name, slot, colors=("Main",), kind=None):
        self.name = name; self.slot = slot; self.colors = list(colors)
        self.kind = kind or ("tight" if slot in ("bra", "underwear", "pantyhose", "gloves", "socks") else ("shoes" if slot.startswith("shoes") else slot))
        self.V = []; self.F = []; self.UV = []; self.zone = []; self.alpha = []
        self.texture = None
        self.parts = []          # (loop_start, loop_end, zone, tiled) for UV packing of procedural parts
        self.openings = None     # explicit opening polylines (else: mesh boundary edges)
        self.hem_z = None        # skin below this height is never masked (loose hems)
        self.sharp_edges = []    # (vertex a, vertex b) pairs to mark sharp (pleat folds)
        self.weight_regions = None
        self.body_faces_range = []

    def add(self, V, F, uv_loops, zone=0, alpha=1.0, tiled=False):
        base = len(self.V); loop0 = len(self.UV)
        V = np.asarray(V, np.float64)
        zone_arr = np.broadcast_to(np.asarray(zone), (len(V),))
        alpha = np.broadcast_to(np.asarray(alpha, np.float64), (len(V),))
        for i in range(len(V)):
            self.V.append(V[i]); self.zone.append(int(zone_arr[i])); self.alpha.append(float(alpha[i]))
        for f in F:
            self.F.append([base + int(v) for v in f])
        self.UV.extend([tuple(uv) for uv in uv_loops])
        assert len(self.UV) == sum(len(f) for f in self.F)
        self.parts.append((loop0, len(self.UV), int(np.max(zone_arr)), bool(tiled)))
        if not tiled:
            self.body_faces_range.append((len(self.F) - len(F), len(self.F)))
        return base

    def main_faces(self):
        """Faces of the garment proper (tiled decoration such as collars/buttons excluded):
        only their boundary edges are garment openings."""
        return [f for a, b in self.body_faces_range for f in self.F[a:b]]

    def nverts(self):
        return len(self.V)


# --------------------------------------------------------------------------
# body region shells
# --------------------------------------------------------------------------
def region_shell(body, vert_mask, offset=0.002, clamp=None, smooth=0):
    """Faces of the body whose vertices are all in vert_mask (bool per vertex),
    offset along the normal; returns (V, F, uv_loops, orig_vert_ids)."""
    faces_idx = [i for i, f in enumerate(body.faces) if all(vert_mask[v] for v in f)]
    used = sorted({v for i in faces_idx for v in body.faces[i]})
    remap = {v: i for i, v in enumerate(used)}
    V = body.V[used] + body.N[used] * offset
    F = [[remap[v] for v in body.faces[i]] for i in faces_idx]
    uv = []
    for i in faces_idx:
        n = len(body.faces[i]); s = body.loop_start[i]
        uv.extend(body.uv_loops[s:s + n])
    if smooth:
        adj = build_adjacency(F, len(V))
        V = laplacian_smooth(V, adj, np.ones(len(V)), iters=smooth, lam=0.5, taubin_mu=-0.52)
    if clamp:
        for fn in clamp:
            V = fn(V)
    return V, F, np.asarray(uv), np.asarray(used)


def clamp_z(z_cut, above):
    """Project vertices beyond a horizontal plane back onto it (clean hem)."""
    def f(V):
        V = V.copy()
        if above:
            V[V[:, 2] > z_cut, 2] = z_cut
        else:
            V[V[:, 2] < z_cut, 2] = z_cut
        return V
    return f


def band_mask(body, z0, z1, regions=None, extra=None):
    V = body.V
    m = (V[:, 2] >= z0) & (V[:, 2] <= z1)
    if regions is not None:
        m &= np.isin(body.regions, [REG[r] for r in regions])
    if extra is not None:
        m &= extra
    return m


# --------------------------------------------------------------------------
# surface helpers
# --------------------------------------------------------------------------
def surface_point(body, x, z, from_back, offset):
    """Point on the body surface at (x, z) seen from the front/back, offset along the normal."""
    o = Vector((x, 1.0 if from_back else -1.0, z)); d = Vector((0, -1.0 if from_back else 1.0, 0))
    loc, nrm, idx, dist = body.bvh.ray_cast(o, d, 3.0)
    if loc is None:  # above the shoulder line: cast downwards instead
        yc = float(body.L["spine_axis_y"]) + (0.03 if from_back else -0.03)
        loc, nrm, idx, dist = body.bvh.ray_cast(Vector((x, yc, 2.0)), Vector((0, 0, -1.0)), 3.0)
        if loc is None:
            return None
    return np.array(loc) + np.array(nrm) * offset


def surface_strip(body, pts, widths, offset, n=None):
    """Strip lying on the body: centreline `pts`, per-point widths. Each cross-section is
    tangent to the skin (cross(normal, tangent)); edge vertices are re-projected onto the
    nearest surface point + offset so the strip hugs the body. u across, v along."""
    P = np.asarray(pts, np.float64)
    if n:
        P = resample(P, n); widths = np.interp(np.linspace(0, 1, n), np.linspace(0, 1, len(widths)), widths)
    m = len(P); V = []; F = []; uv = []
    for i in range(m):
        T = P[min(i + 1, m - 1)] - P[max(i - 1, 0)]; T /= max(np.linalg.norm(T), 1e-9)
        loc, nrm, dist = body.nearest(P[i])
        N = np.asarray(nrm) if loc is not None else np.array([0, -1.0, 0])
        S = np.cross(N, T); S /= max(np.linalg.norm(S), 1e-9)
        for sgn in (-1, 1):
            q = P[i] + S * sgn * widths[i] / 2
            loc2, nrm2, d2 = body.nearest(q)
            if loc2 is not None:
                q = np.asarray(loc2) + np.asarray(nrm2) * offset
            V.append(q)
    for i in range(m - 1):
        F.append([2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2]); t0 = i / (m - 1); t1 = (i + 1) / (m - 1)
        uv += [(0, 1 - t0), (1, 1 - t0), (1, 1 - t1), (0, 1 - t1)]
    return np.asarray(V), F, np.asarray(uv)


def torus_mesh(centre, axis, R, r, nu=20, nv=8, flatten=1.0):
    """Torus around `axis` at `centre` (ribbon loop / hair tie); `flatten` scales the
    cross-section along the axis. u around the ring, v around the tube."""
    axis = np.asarray(axis, np.float64); axis /= np.linalg.norm(axis)
    a = np.cross(axis, [0, 0, 1.0])
    if np.linalg.norm(a) < 1e-6:
        a = np.cross(axis, [1.0, 0, 0])
    a /= np.linalg.norm(a); b = np.cross(axis, a)
    V = []; F = []; UV = []
    for i in range(nu):
        th = 2 * math.pi * i / nu
        rad = a * math.cos(th) + b * math.sin(th)
        for j in range(nv):
            ph = 2 * math.pi * j / nv
            V.append(centre + rad * (R + r * math.cos(ph)) + axis * (r * flatten * math.sin(ph)))
    for i in range(nu):
        for j in range(nv):
            F.append([i * nv + j, ((i + 1) % nu) * nv + j, ((i + 1) % nu) * nv + (j + 1) % nv, i * nv + (j + 1) % nv])
            UV += [(i / nu, j / nv), ((i + 1) / nu, j / nv), ((i + 1) / nu, (j + 1) / nv), (i / nu, (j + 1) / nv)]
    return np.asarray(V), F, np.asarray(UV)


def box_mesh(centre, size):
    c = np.asarray(centre, np.float64); s = np.asarray(size, np.float64) / 2
    V = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], np.float64) * s + c
    F = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
    UV = np.array([(0, 0), (1, 0), (1, 1), (0, 1)] * 6, np.float64)
    return V, F, UV


# --------------------------------------------------------------------------
# MakeHuman garments
# --------------------------------------------------------------------------
def fit_garment(body, rel):
    p = load_mhclo(os.path.join(MH, rel))
    V = mh_to_bl(fit_proxy(p, body.Vmh_all), body.ground)
    mesh = p.mesh
    # make sure faces wind outwards (the body-mask ray test needs same-facing normals)
    tris = triangulate(mesh["faces"]); Nv = vertex_normals(V, tris)
    step = max(len(V) // 400, 1); s = 0.0
    for i in range(0, len(V), step):
        loc, nrm, dist = body.nearest(V[i])
        if loc is not None and dist < 0.05:
            s += float(Nv[i] @ np.asarray(nrm))
    if s < 0:
        mesh["faces"] = [list(reversed(f)) for f in mesh["faces"]]
        mesh["fuv"] = [list(reversed(f)) for f in mesh["fuv"]]
        log("  %s: flipped face winding (was inward)" % os.path.basename(rel))
    comp, n = connected_components(mesh["faces"], len(V))
    return p, V, comp, n


def component_submesh(V, mesh, comp, ids):
    keep = np.isin(comp, ids)
    fid = [i for i, f in enumerate(mesh["faces"]) if keep[f[0]]]
    used = sorted({v for i in fid for v in mesh["faces"][i]})
    remap = {v: i for i, v in enumerate(used)}
    F = [[remap[v] for v in mesh["faces"][i]] for i in fid]
    uv = []
    for i in fid:
        for ti in mesh["fuv"][i]:
            uv.append(mesh["vt"][ti] if ti >= 0 and len(mesh["vt"]) else (0, 0))
    return V[used], F, np.asarray(uv), np.asarray(used)


def split_top_bottom(body, V, comp, n):
    """Classify connected components of a suit into top / bottom / shoes by height."""
    tops, bottoms, shoes = [], [], []
    waist = body.L["waist_z"]; ankle = body.L["ankle_L"][2]
    for c in range(n):
        sel = comp == c
        if sel.sum() < 12:
            continue
        zmax = V[sel, 2].max(); zmin = V[sel, 2].min()
        if zmax < ankle + 0.08:
            shoes.append(c)
        elif zmax > waist + 0.08:
            tops.append(c)
        else:
            bottoms.append(c)
    return tops, bottoms, shoes


def enforce_offset(body, V, F, offset, rounds=3, far=None):
    """Push garment vertices that are closer than `offset` to the skin outwards along the
    skin normal; the push is spread over neighbours so the shell stays smooth."""
    V = np.asarray(V, np.float64).copy()
    indptr, idx = build_adjacency(F, len(V))
    row = np.repeat(np.arange(len(V)), np.diff(indptr)); deg = np.maximum(np.diff(indptr), 1)
    far = far or offset * 4
    for _ in range(rounds):
        push = np.zeros(len(V)); dirs = np.zeros_like(V)
        for i in range(len(V)):
            loc, nrm, idx_, dist = body.bvh.find_nearest(Vector(V[i]), far)
            if loc is None:
                continue
            nrm = np.asarray(nrm); s = float((V[i] - np.asarray(loc)) @ nrm)
            dirs[i] = nrm
            if s < offset:
                push[i] = offset - s
        if push.max() <= 1e-5:
            break
        for _ in range(2):
            nb = np.zeros(len(V)); np.add.at(nb, row, push[idx]); nb /= deg
            push = np.maximum(push, 0.7 * nb)
        V += dirs * push[:, None]
    return V


def luminance_texture(src_png, out_png, size=1024):
    """CC0 garment diffuse -> near-white luminance (keeps folds/AO) for tinting."""
    img = bpy.data.images.load(src_png, check_existing=True)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32); img.pixels.foreach_get(px); px = px.reshape(h, w, 4)
    lum = 0.299 * px[:, :, 0] + 0.587 * px[:, :, 1] + 0.114 * px[:, :, 2]
    m = float(np.median(lum)); lum = np.clip(0.55 + 0.45 * (lum / max(m, 0.05)), 0, 1) ** 0.8
    f = max(w // size, 1)
    lum = lum[:h // f * f, :w // f * f].reshape(h // f, f, w // f, f).mean((1, 3))
    lum = lum[::-1]  # blender images are bottom-up
    write_png(out_png, np.repeat((lum * 255).astype(np.uint8)[:, :, None], 3, 2))
    return out_png


def paint_tile_white(src_png, out_png, rect):
    """Copy of a luminance texture with the UV rect (u0, v0, u1, v1) painted white
    (procedural parts packed there must not pick up the garment's folds)."""
    img = bpy.data.images.load(src_png, check_existing=True)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32); img.pixels.foreach_get(px); px = px.reshape(h, w, 4)
    u0, v0, u1, v1 = rect
    px[int(v0 * h):int(math.ceil(v1 * h)), int(u0 * w):int(math.ceil(u1 * w)), :3] = 1.0   # pixels are bottom-up = v up
    rgb = (px[::-1, :, :3] * 255).astype(np.uint8)
    write_png(out_png, rgb)
    return out_png


# --------------------------------------------------------------------------
# procedural garments
# --------------------------------------------------------------------------
def core_bvh(body):
    """BVH of the torso + legs only (no arms/hands hanging beside the hips)."""
    keep = np.isin(body.regions, [REG[r] for r in ("torso_upper", "torso_lower", "thigh_L", "thigh_R", "calf_L", "calf_R")])
    faces = [f for f in body.faces if all(keep[v] for v in f)]
    return BVHTree.FromPolygons([tuple(v) for v in body.V], faces)


def body_radius(body, origin, direction, max_dist=0.6):
    """Farthest torso/leg-surface hit along a horizontal ray from `origin` (silhouette radius)."""
    if not hasattr(body, "bvh_core"):
        body.bvh_core = core_bvh(body)
    o = Vector(origin); d = Vector(direction); best = 0.0; travelled = 0.0
    for _ in range(8):
        loc, nrm, idx, dist = body.bvh_core.ray_cast(o, d, max_dist - travelled)
        if loc is None:
            break
        travelled += dist + 1e-4; best = travelled
        o = loc + d * 1e-4
    return best


def pleated_skirt(body, g, n_pleats=24, seg_z=12, z_waist=1.00, z_hem=0.62, hem_axes=(0.29, 0.27), band_rows=2):
    """Knife-pleated skirt lofted around the hips.
    Waist ring = hip circumference + 1 cm (same ellipse aspect as the hips) at z_waist; every ring
    is also kept >= OFFSETS['skirt'] + pleat depth outside the skin; below the hips the rings
    flare to hem_axes at z_hem. Pleat pattern per pleat: wide outer panel, fold in, inner
    panel, fold out (4 columns), fold edges marked sharp. Top `band_rows` rows = waistband (zone 1)."""
    L = body.L; V = body.V; off = OFFSETS["skirt"]
    hip_z = L["hip_z"]
    sel = (np.abs(V[:, 2] - hip_z) < 0.012) & (np.abs(V[:, 0]) < 0.3) & np.isin(body.regions, [REG["torso_lower"], REG["thigh_L"], REG["thigh_R"]])
    cx = 0.0; cy = float((V[sel, 1].max() + V[sel, 1].min()) / 2)
    a_hip = float(np.abs(V[sel, 0]).max()); b_hip = float((V[sel, 1].max() - V[sel, 1].min()) / 2)
    circ = math.pi * (3 * (a_hip + b_hip) - math.sqrt((3 * a_hip + b_hip) * (a_hip + 3 * b_hip)))
    k = (circ + 0.01) / circ
    a_w, b_w = a_hip * k, b_hip * k
    log("  skirt: hips a=%.3f b=%.3f circ=%.3f m -> waist ellipse a=%.3f b=%.3f (circ %.3f), hem %s" % (a_hip, b_hip, circ, a_w, b_w, circ + 0.01, hem_axes))
    fracs = [0.0, 0.62, 0.70, 0.92]; signs = [1.0, 1.0, -1.0, -1.0]
    seg_theta = n_pleats * len(fracs)
    thetas = np.array([2 * math.pi * (p + f) / n_pleats for p in range(n_pleats) for f in fracs])
    pleat_sign = np.array([s for p in range(n_pleats) for s in signs])

    def ellipse_r(th, a, b):
        return a * b / math.sqrt((b * math.sin(th)) ** 2 + (a * math.cos(th)) ** 2)

    verts = []; uv = []; F = []; zone = []
    for i in range(seg_z + 1):
        t = i / seg_z
        z = z_waist + (z_hem - z_waist) * t
        amp = 0.0 if i < band_rows else 0.004 + 0.011 * t
        r_base = np.zeros(seg_theta)
        for j, th in enumerate(thetas):
            d = (math.sin(th), -math.cos(th), 0.0)
            rb = body_radius(body, (cx, cy, z), d)
            r_env = ellipse_r(th, a_w, b_w)
            if z < hip_z:
                s = (hip_z - z) / (hip_z - z_hem)
                r_env = r_env + (ellipse_r(th, *hem_axes) - r_env) * s ** 0.9
            r_base[j] = max(r_env, rb + off + amp)
        for _ in range(2):   # soften kinks where the envelope and the skin offset cross
            r_base = 0.25 * np.roll(r_base, 1) + 0.5 * r_base + 0.25 * np.roll(r_base, -1)
        if i < band_rows:
            r_base += 0.002
        for j, th in enumerate(thetas):
            r = r_base[j] + amp * pleat_sign[j]
            verts.append((cx + math.sin(th) * r, cy - math.cos(th) * r, z)); uv.append((th / (2 * math.pi), 1 - t)); zone.append(1 if i < band_rows else 0)
    for i in range(seg_z):
        for j in range(seg_theta):
            a = i * seg_theta + j; b = i * seg_theta + (j + 1) % seg_theta
            F.append([a, a + seg_theta, b + seg_theta, b])          # outward winding
    uv_loops = [uv[v] if not (v % seg_theta == 0 and k_ in (2, 3)) else (1.0, uv[v][1]) for f in F for k_, v in enumerate(f)]
    base = g.add(np.asarray(verts), F, np.asarray(uv_loops), zone=np.asarray(zone), alpha=1.0)
    # sharp fold edges: vertical edges at the fold columns (fractions 0.62/0.70 and 0.92/0.0)
    fold_cols = [j for j in range(seg_theta) if pleat_sign[j] != pleat_sign[(j + 1) % seg_theta]]
    for i in range(seg_z):
        for j in fold_cols:
            for jj in (j, (j + 1) % seg_theta):
                if i >= band_rows - 1:
                    g.sharp_edges.append((base + i * seg_theta + jj, base + (i + 1) * seg_theta + jj))
    g.openings = [[np.asarray(verts[j]) for j in list(range(seg_theta)) + [0]],
                  [np.asarray(verts[seg_z * seg_theta + j]) for j in list(range(seg_theta)) + [0]]]
    g.hem_z = z_hem + 0.03
    bb = np.asarray(verts)
    log("  skirt bbox x %.3f..%.3f y %.3f..%.3f z %.3f..%.3f, %d verts" % (bb[:, 0].min(), bb[:, 0].max(), bb[:, 1].min(), bb[:, 1].max(), bb[:, 2].min(), bb[:, 2].max(), len(bb)))


def sailor_collar(body, g, off):
    """Square back flap on the upper back, two lapels running over the shoulders down to the
    sternum (all lying on the T-shirt surface), and a ribbon bow with tails. Procedural parts
    are UV-tiled (zone 1 = collar, zone 2 = ribbon)."""
    L = body.L
    neck_z = L["neck_z"]; chest_top = L["chest_top_z"]; y_back = float(L["spine_axis_y"]) + 0.03
    # back flap: top edge follows the neckline (height of the shoulder/neck surface behind the neck)
    xs = np.linspace(-0.125, 0.125, 11); nrows = 6
    pts = np.zeros((nrows, len(xs), 3))
    for j, x in enumerate(xs):
        loc, nrm, idx, dist = body.bvh.ray_cast(Vector((x, y_back, 2.0)), Vector((0, 0, -1.0)), 3.0)
        z_top = float(loc.z) if loc is not None else neck_z - 0.02
        z_top = min(z_top, neck_z - 0.005)
        for i in range(nrows):
            z = z_top - 0.012 - i * 0.024
            p = surface_point(body, x, z, True, off)
            pts[i, j] = p if p is not None else np.array([x, y_back + 0.05, z])
    V = pts.reshape(-1, 3); F = []; uvf = []; nx = len(xs)
    for i in range(nrows - 1):
        for j in range(nx - 1):
            a = i * nx + j
            F.append([a, a + 1, a + nx + 1, a + nx])
            uvf += [(j / (nx - 1), 1 - i / (nrows - 1)), ((j + 1) / (nx - 1), 1 - i / (nrows - 1)), ((j + 1) / (nx - 1), 1 - (i + 1) / (nrows - 1)), (j / (nx - 1), 1 - (i + 1) / (nrows - 1))]
    g.add(V, F, np.asarray(uvf), zone=1, tiled=True)
    # lapels: from the neckline over the shoulder to the sternum
    for sgn in (1, -1):
        loc, nrm, idx, dist = body.bvh.ray_cast(Vector((sgn * 0.07, y_back, 2.0)), Vector((0, 0, -1.0)), 3.0)
        z0 = min(float(loc.z), neck_z - 0.005) if loc is not None else neck_z - 0.02
        p0 = np.array(loc) + np.array(nrm) * off if loc is not None else surface_point(body, sgn * 0.07, z0, True, off)
        p1 = surface_point(body, sgn * 0.065, neck_z - 0.045, False, off)
        p2 = surface_point(body, sgn * 0.04, chest_top + 0.005, False, off)
        p3 = surface_point(body, sgn * 0.012, chest_top - 0.03, False, off)
        pts = [q for q in (p0, p1, p2, p3) if q is not None]
        Vl, Fl, uvl = surface_strip(body, pts, [0.075, 0.06, 0.035, 0.014], off, n=9)
        g.add(Vl, Fl, uvl, zone=1, tiled=True)
    # ribbon: knot + two loops + two tails at the sternum
    c = surface_point(body, 0.0, chest_top - 0.04, False, off + 0.006)
    Vk, Fk, uvk = box_mesh(c + (0, -0.004, 0), (0.022, 0.012, 0.018))
    g.add(Vk, Fk, uvk, zone=2, tiled=True)
    for sgn in (1, -1):
        Vt, Ft, uvt = torus_mesh(c + np.array([sgn * 0.034, -0.002, 0.002]), (0, 1.0, 0), 0.021, 0.0065, nu=18, nv=8, flatten=0.55)
        g.add(Vt, Ft, uvt, zone=2, tiled=True)
        tail = [c + (sgn * 0.006, 0, -0.008), c + (sgn * 0.02, 0, -0.045), c + (sgn * 0.034, 0, -0.085), c + (sgn * 0.044, 0, -0.105)]
        Vs, Fs, uvs = surface_strip(body, tail, [0.018, 0.022, 0.026, 0.028], off + 0.003, n=7)
        g.add(Vs, Fs, uvs, zone=2, tiled=True)


def shoe_hull(body, g, side, high, offset):
    L = body.L
    ank = L["ankle_" + side]
    rid = REG["foot_" + side]
    z_cut = ank[2] + (0.055 if high else 0.005)
    mask = (body.regions == rid) | ((np.linalg.norm(body.V - ank, axis=1) < 0.08) & (body.V[:, 2] < z_cut + 0.03) & (np.sign(body.V[:, 0]) == (1 if side == "L" else -1)))
    mask &= body.V[:, 2] < z_cut + 0.03
    V, F, uv, ids = region_shell(body, mask, offset=offset, clamp=[clamp_z(z_cut, above=True)], smooth=3)
    # sole: flatten the underside and thicken
    bottom = V[:, 2] < 0.014
    V[bottom, 2] = -0.004 if not high else -0.008
    zone = np.where(bottom, 2, 0)
    g.add(V, F, uv, zone=zone)
    return z_cut


# --------------------------------------------------------------------------
# body mask
# --------------------------------------------------------------------------
def body_mask_ids(body, V, F, reach, margin=MASK_MARGIN, openings=None, hem_z=None, F_open=None):
    """Bool per body vertex: covered by the garment (see module docstring). Opening edges are
    the boundary edges of F_open (default: all faces) unless explicit `openings` are given."""
    V = np.asarray(V, np.float64)
    gb = BVHTree.FromPolygons([tuple(map(float, v)) for v in V], [tuple(map(int, f)) for f in F])
    if openings is None:
        cnt = {}
        for f in (F_open if F_open is not None else F):
            k = len(f)
            for i in range(k):
                a, b = int(f[i]), int(f[(i + 1) % k]); e = (a, b) if a < b else (b, a); cnt[e] = cnt.get(e, 0) + 1
        segs = [(V[a], V[b]) for (a, b), c in cnt.items() if c == 1]
    else:
        segs = [(np.asarray(pl[i]), np.asarray(pl[i + 1])) for pl in openings for i in range(len(pl) - 1)]
    pts = []
    for a, b in segs:
        n = max(int(np.linalg.norm(b - a) / 0.004) + 1, 2)
        pts.extend(a + (b - a) * np.linspace(0, 1, n)[:, None])
    kd = None
    if pts:
        kd = KDTree(len(pts))
        for i, p in enumerate(pts):
            kd.insert(Vector(p), i)
        kd.balance()
    covered = np.zeros(len(body.V), bool)
    lo = V.min(0) - reach - 0.01; hi = V.max(0) + reach + 0.01
    zlo, zhi = float(V[:, 2].min()) + 0.004, float(V[:, 2].max()) - 0.004    # never above/below the garment itself
    cand = np.where(np.all((body.V >= lo) & (body.V <= hi), axis=1))[0]
    cone = math.radians(50); n_cone = 8
    for i in cand:
        p = body.V[i]; n = body.N[i]
        if (hem_z is not None and p[2] < hem_z) or p[2] < zlo or p[2] > zhi:
            continue
        # hidden from every direction: the normal ray and a 50 deg cone of 8 rays around it must all
        # hit a same-facing garment face (skin visible through any opening escapes at least one ray)
        t1 = np.cross(n, [0, 0, 1.0] if abs(n[2]) < 0.9 else [1.0, 0, 0]); t1 /= np.linalg.norm(t1); t2 = np.cross(n, t1)
        o = Vector(p + n * 0.0005); hits = 0
        for k in range(n_cone + 1):
            if k == 0:
                d = n
            else:
                a = 2 * math.pi * (k - 1) / n_cone
                d = n * math.cos(cone) + (t1 * math.cos(a) + t2 * math.sin(a)) * math.sin(cone)
            loc, nrm, idx, dist = gb.ray_cast(o, Vector(d), reach if k == 0 else reach * 1.6)
            if loc is not None and float(Vector(n).dot(nrm)) > 0.0:
                hits += 1
            elif k == 0:
                break
        hit = hits >= n_cone      # the normal ray plus at most one escaping cone ray
        if not hit:
            # tangential normals (under the bust, armpits): nearest same-facing garment point that lies
            # roughly along the skin normal (a placket edge beside a V opening does not count)
            loc, nrm, idx, dist = gb.find_nearest(Vector(p), min(reach, 0.025))
            if loc is not None:
                to = np.asarray(loc) - p
                hit = dist <= 0.002 or (float(Vector(n).dot(nrm)) > 0.25 and float(to @ n) > 0.6 * max(dist, 1e-6))
        if hit and kd is not None:
            _, _, d = kd.find(Vector(p))
            if d < margin:
                hit = False
        covered[i] = hit
    return covered


def write_body_mask(body, covered, path, size=1024, dilate=3):
    c = covered.astype(np.float64)
    tri_sel = np.where(c[body.tris].max(1) > 0)[0]
    m = np.zeros((size, size), bool)
    if len(tri_sel):
        img, cov = raster_field(body.uv_tris[tri_sel], c[body.tris[tri_sel]], size, pad=0)
        m = (img[:, :, 0] >= 0.5) & cov
    for _ in range(dilate):
        m = dilate_bool(m, 1, diagonal=True)
    write_png(path, (m * 255).astype(np.uint8))
    return float(m.mean())


# --------------------------------------------------------------------------
# UV packing of procedural parts
# --------------------------------------------------------------------------
def dilate_bool(a, r, diagonal=False):
    """Binary dilation by r pixels (4- or 8-neighbourhood) that does not wrap around the border."""
    offs = ((0, 1), (0, -1), (1, 0), (-1, 0)) + (((1, 1), (1, -1), (-1, 1), (-1, -1)) if diagonal else ())
    for _ in range(r):
        p = np.pad(a, 1)
        b = a.copy()
        for dy, dx in offs:
            b |= p[1 + dy:1 + dy + a.shape[0], 1 + dx:1 + dx + a.shape[1]]
        a = b
    return a


def pack_tiled_uvs(g, n=32):
    """Move the tiled (procedural) parts into the largest free block of the atlas so they
    never overlap the garment's own islands. One sub-tile per zone (parts of one zone may
    overlap each other). Returns (uv array, rect (u0, v0, u1, v1) or None)."""
    uv = np.asarray(g.UV, np.float64).copy()
    tiled = [p for p in g.parts if p[3]]
    if not tiled:
        return uv, None
    fixed = np.ones(len(uv), bool)
    for a, b, z, t in tiled:
        fixed[a:b] = False
    if not fixed.any():
        return uv, None
    occ = np.zeros((n, n), bool)
    fu = uv[fixed]
    iu = np.clip((fu[:, 0] * n).astype(int), 0, n - 1); iv = np.clip(((1 - fu[:, 1]) * n).astype(int), 0, n - 1)
    occ[iv, iu] = True
    # edge midpoints of the fixed faces too (large triangles)
    k = 0
    for f in g.F:
        m = len(f)
        if fixed[k]:
            for i in range(m):
                p = (uv[k + i] + uv[k + (i + 1) % m]) / 2
                occ[min(int((1 - p[1]) * n), n - 1), min(int(p[0] * n), n - 1)] = True
        k += m
    occ = dilate_bool(occ, 1)
    free = ~occ
    # largest free rectangle (rows x cols) by brute force over the summed-area table
    S = np.zeros((n + 1, n + 1), int); S[1:, 1:] = free.cumsum(0).cumsum(1)
    best = (0, None)
    for r0 in range(n):
        for r1 in range(r0 + 1, n + 1):
            for c0 in range(n):
                for c1 in range(c0 + 1, n + 1):
                    area = (r1 - r0) * (c1 - c0)
                    if area <= best[0]:
                        continue
                    if S[r1, c1] - S[r0, c1] - S[r1, c0] + S[r0, c0] == area:
                        best = (area, (r0, r1, c0, c1))
    if best[1] is None:
        log("  WARNING no free UV block for tiled parts; leaving them in place")
        return uv, None
    r0, r1, c0, c1 = best[1]
    u0, u1 = c0 / n, c1 / n; v0, v1 = 1 - r1 / n, 1 - r0 / n
    zones = sorted({z for a, b, z, t in tiled})
    w = (u1 - u0) / len(zones); pad = 0.004
    for a, b, z, t in tiled:
        zi = zones.index(z)
        sub = uv[a:b]
        lo = sub.min(0); hi = np.maximum(sub.max(0) - lo, 1e-6)
        loc = (sub - lo) / hi
        uv[a:b, 0] = u0 + zi * w + pad + loc[:, 0] * (w - 2 * pad)
        uv[a:b, 1] = v0 + pad + loc[:, 1] * (v1 - v0 - 2 * pad)
    log("  tiled %d procedural parts into UV rect u %.3f..%.3f v %.3f..%.3f (%d zones)" % (len(tiled), u0, u1, v0, v1, len(zones)))
    return uv, (u0, v0, u1, v1)


# --------------------------------------------------------------------------
# export
# --------------------------------------------------------------------------
def allowed_weight_mask(body, g):
    regions = g.weight_regions or WEIGHT_REGIONS.get(g.slot, list(REG.keys()))
    m = np.isin(body.regions, [REG[r] for r in regions])
    if g.slot in ("top",) or g.kind in ("dress", "blazer"):
        m |= (body.regions == 0) & (body.V[:, 2] < body.L["neck_z"] + 0.06)   # lower neck for collars
    return m


def export_garment(body, g, texture=None, sex="f"):
    bl_reset()
    uv, rect = pack_tiled_uvs(g)
    tex_path = texture
    if texture and rect is not None:
        tex_path = paint_tile_white(texture, os.path.join(OUT, "tex", "cloth_%s.png" % g.name), rect)
    mat = bl_material("ik_cloth", (0.95, 0.95, 0.96, 1), image_path=tex_path)
    V = np.asarray(g.V); F = g.F
    col = np.ones((len(V), 4), np.float32); col[:, 3] = np.asarray(g.alpha, np.float32)
    ob = bl_make_mesh(g.slot, V, F, uv, mat, vcol=col)
    if g.sharp_edges:
        me = ob.data
        ekey = {}
        for e in me.edges:
            a, b = e.vertices; ekey[(min(a, b), max(a, b))] = e.index
        attr = me.attributes.get("sharp_edge") or me.attributes.new("sharp_edge", "BOOLEAN", "EDGE")
        vals = np.zeros(len(me.edges), bool)
        for a, b in g.sharp_edges:
            ei = ekey.get((min(a, b), max(a, b)))
            if ei is not None:
                vals[ei] = True
        attr.data.foreach_set("value", vals)
    # body mask + hideBody from coverage
    reach = MASK_REACH.get(g.kind, MASK_REACH["top"])
    covered = body_mask_ids(body, V, F, reach, openings=g.openings, hem_z=g.hem_z, F_open=g.main_faces())
    per_region = {}
    for name, rid in REG.items():
        sel = body.regions == rid
        per_region[name] = round(float(covered[sel].mean()), 3) if sel.any() else 0.0
    hide = sorted(name for name, frac in per_region.items() if frac >= 0.9)
    ob.data["hideBody"] = hide; ob["hideBody"] = hide
    ob.data["colors"] = g.colors; ob["colors"] = g.colors
    bones = json.loads(json.dumps(body.bones))
    arm = RG.build_armature(bones, "Armature")
    # weights: nearest body vertex among the slot's regions
    allowed = allowed_weight_mask(body, g)
    W = RG.transfer_weights(body.V[allowed], body.W[allowed], V)
    RG.set_weights_dense(ob, body.bone_names, W, limit=4)
    used_bones = [body.bone_names[j] for j in np.where(W.max(0) > 1e-4)[0]]
    mod = ob.modifiers.new("Armature", "ARMATURE"); mod.object = arm; ob.parent = arm
    fname = g.name
    out = os.path.join(A_CLOTH, fname + ".glb")
    bl_export_glb(out, [arm, ob])
    # ColorMask in the garment's UV space: background = zone 1 (Main, red), islands dilated 4 px
    tris = triangulate(F)
    tri_loops = []; start = 0
    for f in F:
        for i in range(1, len(f) - 1):
            tri_loops.append((start, start + i, start + i + 1))
        start += len(f)
    tri_loops = np.asarray(tri_loops)
    zone = np.asarray(g.zone)
    onehot = np.zeros((len(V), 3)); onehot[np.arange(len(V)), np.clip(zone, 0, 2)] = 1.0
    img, cov = raster_field(uv[tri_loops], onehot[tris], 1024, pad=4)
    img[~cov] = (1, 0, 0)
    cm = os.path.join(A_CLOTH, fname + "_cm.png")
    write_png(cm, np.clip(img, 0, 1))
    bm = os.path.join(A_CLOTH, fname + "_bm.png")
    white = write_body_mask(body, covered, bm)
    info, js, blob = glb_summary(out)
    bb = V.min(0), V.max(0)
    log("  %s: covered body verts %d (%.1f%%), mask white %.1f%%, hideBody %s, bones %d, bbox x %.3f..%.3f y %.3f..%.3f z %.3f..%.3f" % (
        fname, covered.sum(), 100 * covered.mean(), 100 * white, hide, len(used_bones), bb[0][0], bb[1][0], bb[0][1], bb[1][1], bb[0][2], bb[1][2]))
    return dict(file=os.path.relpath(out, REPO), bytes=os.path.getsize(out), cm=os.path.relpath(cm, REPO), bodyMask=os.path.relpath(bm, REPO),
                slot=g.slot, hideBody=hide, colors=g.colors, verts=len(V), tris=len(tris), sex=sex,
                maskCoverage=dict(bodyVerts=int(covered.sum()), bodyVertsFrac=round(float(covered.mean()), 4), maskWhiteFrac=round(white, 4), regions=per_region),
                bones=used_bones, bbox=[np.round(bb[0], 4).tolist(), np.round(bb[1], 4).tolist()])


# --------------------------------------------------------------------------
# garment table
# --------------------------------------------------------------------------
def build_all(body, only=None, sex="f"):
    results = {}
    L = body.L; J = body.J
    tex_dir = os.path.join(OUT, "tex"); os.makedirs(tex_dir, exist_ok=True)

    sfx = "_m" if sex == "m" else ""

    def want(name):
        return only is None or name in only or name + sfx in only

    # ---------- reused MakeHuman suits
    suits = {
        "f": [("female_casualsuit02", "top_croptop", "bottom_shorts", "Crop top", "Shorts"),
              ("female_casualsuit01", "top_tshirt", "bottom_jeans", "T-shirt", "Jeans")],
        "m": [("male_casualsuit03", "top_shirt_m", "bottom_trousers_m", "Shirt", "Trousers")],
    }[sex]
    suit_cache = {}
    for suit, top_id, bot_id, top_name, bot_name in suits:
        if not (want(top_id) or want(bot_id) or (sex == "f" and suit == "female_casualsuit01" and (want("top_sailor") or want("top_blazer")))):
            continue
        p, V, comp, n = fit_garment(body, "system/clothes/%s/%s.mhclo" % (suit, suit))
        tops, bottoms, shoes = split_top_bottom(body, V, comp, n)
        log("suit %s: %d components -> tops %s bottoms %s shoes %s" % (suit, n, tops, bottoms, shoes))
        tex = os.path.join(MH, "system/clothes/%s/%s_diffuse.png" % (suit, suit))
        lum = luminance_texture(tex, os.path.join(tex_dir, "cloth_%s.png" % suit)) if os.path.exists(tex) else None
        suit_cache[suit] = (p, V, comp, tops, bottoms, lum)
        for ids, gid, gname, slot in ((tops, top_id, top_name, "top"), (bottoms, bot_id, bot_name, "bottom")):
            if not ids or not want(gid):
                continue
            Vs, F, uv, used = component_submesh(V, p.mesh, comp, ids)
            Vs = enforce_offset(body, Vs, F, OFFSETS[slot])
            g = Garment(gid, slot, ["Main", "Trim"])
            zmax = Vs[:, 2].max()
            zone = np.where(Vs[:, 2] > zmax - 0.035, 1, 0)    # trim zone: neckline / waistband
            g.add(Vs, F, uv, zone=zone)
            if slot == "bottom":
                g.hem_z = float(Vs[:, 2].min()) + 0.03        # ankle / thigh skin at the hem stays visible
            results[gid] = export_garment(body, g, texture=lum, sex=sex)
            results[gid]["name"] = gname
    # ---------- dress
    if sex == "f" and want("top_dress_camisole"):
        p, V, comp, n = fit_garment(body, "dress01/clothes/toigo_camisole_dress_with_full_skirt/toigo_camisole_dress_with_full_skirt.mhclo")
        Vs, F, uv, used = component_submesh(V, p.mesh, comp, list(range(n)))
        Vs = enforce_offset(body, Vs, F, OFFSETS["dress"])
        g = Garment("top_dress_camisole", "top", ["Main", "Trim"], kind="dress")
        g.weight_regions = WEIGHT_REGIONS["top"] + _LEGS
        zone = np.where(Vs[:, 2] < Vs[:, 2].min() + 0.04, 1, 0)
        g.add(Vs, F, uv, zone=zone)
        g.hem_z = float(Vs[:, 2].min()) + 0.05
        results["top_dress_camisole"] = export_garment(body, g, sex=sex); results["top_dress_camisole"]["name"] = "Camisole dress"
    # ---------- sailor top = refit T-shirt + collar + ribbon
    if sex == "f" and want("top_sailor"):
        p, V, comp, tops, bottoms, lum = suit_cache["female_casualsuit01"]
        Vs, F, uv, used = component_submesh(V, p.mesh, comp, tops)
        Vs = enforce_offset(body, Vs, F, OFFSETS["top"])
        g = Garment("top_sailor", "top", ["Main", "Collar", "Ribbon"])
        g.add(Vs, F, uv, zone=0)
        sailor_collar(body, g, OFFSETS["top"] + 0.003)
        results["top_sailor"] = export_garment(body, g, texture=lum, sex=sex); results["top_sailor"]["name"] = "Sailor top"
    # ---------- pleated skirt
    if sex == "f" and want("bottom_skirt_pleated"):
        g = Garment("bottom_skirt_pleated", "bottom", ["Main", "Waistband"], kind="skirt")
        pleated_skirt(body, g)
        results["bottom_skirt_pleated"] = export_garment(body, g, sex=sex); results["bottom_skirt_pleated"]["name"] = "Pleated skirt"
    # ---------- socks / pantyhose / gloves
    knee = J["l-knee"][2]; ankle = J["l-ankle"][2]; waist = L["waist_z"]
    legs = ["thigh_L", "thigh_R", "calf_L", "calf_R", "foot_L", "foot_R", "torso_lower"]
    if want("socks_knee"):
        g = Garment("socks_knee" + sfx, "socks", ["Main", "Top band"])
        z_cut = knee + 0.035
        m = band_mask(body, -1, z_cut + 0.03, legs)
        V, F, uv, ids = region_shell(body, m, OFFSETS["socks"], clamp=[clamp_z(z_cut, True)])
        zone = np.where(V[:, 2] > z_cut - 0.03, 1, 0)
        g.add(V, F, uv, zone=zone)
        results["socks_knee" + sfx] = export_garment(body, g, sex=sex); results["socks_knee" + sfx]["name"] = "Knee socks"
    if want("socks_ankle"):
        g = Garment("socks_ankle" + sfx, "socks", ["Main", "Top band"])
        z_cut = ankle + 0.045
        m = band_mask(body, -1, z_cut + 0.03, legs)
        V, F, uv, ids = region_shell(body, m, OFFSETS["socks"], clamp=[clamp_z(z_cut, True)])
        zone = np.where(V[:, 2] > z_cut - 0.02, 1, 0)
        g.add(V, F, uv, zone=zone)
        results["socks_ankle" + sfx] = export_garment(body, g, sex=sex); results["socks_ankle" + sfx]["name"] = "Ankle socks"
    if sex == "f" and want("pantyhose_black"):
        g = Garment("pantyhose_black", "pantyhose", ["Main"])
        z_cut = waist - 0.01
        m = band_mask(body, -1, z_cut + 0.03, legs)
        V, F, uv, ids = region_shell(body, m, OFFSETS["pantyhose"], clamp=[clamp_z(z_cut, True)])
        g.add(V, F, uv, zone=0)
        results["pantyhose_black"] = export_garment(body, g, sex=sex); results["pantyhose_black"]["name"] = "Pantyhose"
    if want("gloves_short"):
        g = Garment("gloves_short" + sfx, "gloves", ["Main", "Cuff"])
        for S, s in (("L", "l"), ("R", "r")):
            a, b = J[s + "-elbow"], J[s + "-hand"]
            ab = b - a; L2 = float(ab @ ab)
            t = ((body.V - a) @ ab) / L2
            t_cut = 1.0 - 0.06 / math.sqrt(L2)
            m = np.isin(body.regions, [REG["hand_" + S], REG["forearm_" + S]]) & (t > t_cut - 0.15)

            def clamp_low(V, a=a, ab=ab, L2=L2, t_cut=t_cut):
                V = V.copy(); tt = ((V - a) @ ab) / L2; under = tt < t_cut
                V[under] += np.outer(t_cut - tt[under], ab); return V
            V, F, uv, ids = region_shell(body, m, OFFSETS["gloves"], clamp=[clamp_low])
            tt = ((V - a) @ ab) / L2
            zone = np.where(tt < t_cut + 0.05, 1, 0)
            g.add(V, F, uv, zone=zone)
        results["gloves_short" + sfx] = export_garment(body, g, sex=sex); results["gloves_short" + sfx]["name"] = "Short gloves"
    # ---------- underwear / bra
    if want("underwear_plain"):
        g = Garment("underwear_plain" + sfx, "underwear", ["Main", "Trim"])
        z_top = L["pelvis_z"] + 0.045; z_leg = L["hip_z"] - 0.035
        m = band_mask(body, z_leg - 0.03, z_top + 0.03, ["torso_lower", "thigh_L", "thigh_R"])
        m &= ~((body.V[:, 2] < z_leg) & (np.abs(body.V[:, 0]) > 0.035))   # leg openings
        V, F, uv, ids = region_shell(body, m, OFFSETS["underwear"], clamp=[clamp_z(z_top, True)])
        zone = np.where(V[:, 2] > z_top - 0.02, 1, 0)
        g.add(V, F, uv, zone=zone)
        results["underwear_plain" + sfx] = export_garment(body, g, sex=sex); results["underwear_plain" + sfx]["name"] = "Plain underwear"
    if sex == "f" and want("bra_plain"):
        g = Garment("bra_plain", "bra", ["Main", "Trim"])
        V0 = body.V
        m = np.zeros(len(V0), bool)
        for S in ("L", "R"):
            m |= (np.linalg.norm(V0 - L["bust_base_" + S], axis=1) < 0.085) & (V0[:, 1] < L["bust_base_" + S][1] + 0.05)
        bz = L["bust_L"][2]
        m |= (np.abs(V0[:, 2] - (bz - 0.03)) < 0.02) & np.isin(body.regions, [REG["torso_upper"]])   # band around the torso
        m &= np.isin(body.regions, [REG["torso_upper"]])
        V, F, uv, ids = region_shell(body, m, OFFSETS["bra"])
        zone = np.where(np.abs(V[:, 2] - (bz - 0.03)) < 0.012, 1, 0)
        g.add(V, F, uv, zone=zone)
        results["bra_plain"] = export_garment(body, g, sex=sex); results["bra_plain"]["name"] = "Plain bra"
    # ---------- shoes
    if want("shoes_in_loafers"):
        g = Garment("shoes_in_loafers" + sfx, "shoes_in", ["Main", "Trim", "Sole"])
        for S in ("L", "R"):
            shoe_hull(body, g, S, high=False, offset=OFFSETS["shoes"])
        results["shoes_in_loafers" + sfx] = export_garment(body, g, sex=sex); results["shoes_in_loafers" + sfx]["name"] = "Loafers"
    if want("shoes_out_sneakers"):
        g = Garment("shoes_out_sneakers" + sfx, "shoes_out", ["Main", "Trim", "Sole"])
        for S in ("L", "R"):
            shoe_hull(body, g, S, high=True, offset=OFFSETS["shoes"])
        results["shoes_out_sneakers" + sfx] = export_garment(body, g, sex=sex); results["shoes_out_sneakers" + sfx]["name"] = "Sneakers"
    # ---------- blazer: refit T-shirt widened as a jacket shell over it
    if sex == "f" and want("top_blazer"):
        p, V, comp, tops, bottoms, lum = suit_cache["female_casualsuit01"]
        Vs, F, uv, used = component_submesh(V, p.mesh, comp, tops)
        Nn = vertex_normals(Vs, triangulate(F))
        Vb = enforce_offset(body, Vs + Nn * 0.004, F, OFFSETS["blazer"])
        g = Garment("top_blazer", "top", ["Main", "Lapel", "Buttons"], kind="blazer")
        zmax = Vb[:, 2].max()
        front = (Vb[:, 1] < body.head_c[1] - 0.02) & (np.abs(Vb[:, 0]) < 0.05) & (Vb[:, 2] > zmax - 0.16)
        zone = np.where(front, 1, 0)
        g.add(Vb, F, uv, zone=zone)
        for k in range(3):   # buttons: 3 small discs down the front
            c = surface_point(body, 0.0, zmax - 0.10 - k * 0.045, False, OFFSETS["blazer"] + 0.012)
            if c is not None:
                Vt, Ft, uvt = torus_mesh(c, (0, 1.0, 0), 0.006, 0.003, nu=12, nv=6, flatten=0.5)
                g.add(Vt, Ft, uvt, zone=2, tiled=True)
        results["top_blazer"] = export_garment(body, g, texture=lum, sex=sex); results["top_blazer"]["name"] = "Blazer"
    return results


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser(); ap.add_argument("--sex", default="f"); ap.add_argument("--only", default=None)
    args = ap.parse_args(argv)
    body = Body(args.sex)
    d = np.load(os.path.join(OUT, "body_%s.npz" % args.sex))
    body.uv_loops = d["uv_loops"].astype(np.float64)
    ls = np.zeros(len(body.faces), np.int64); s = 0; tl = []
    for i, f in enumerate(body.faces):
        ls[i] = s
        for k in range(1, len(f) - 1):
            tl.append((s, s + k, s + k + 1))
        s += len(f)
    body.loop_start = ls
    body.uv_tris = body.uv_loops[np.asarray(tl, np.int64)]
    assert len(body.uv_tris) == len(body.tris)
    body.regions = d["regions"]
    only = args.only.split(",") if args.only else None
    res = build_all(body, only, args.sex)
    prev = {}
    sp = os.path.join(OUT, "clothes_summary.json")
    if os.path.exists(sp):
        prev = json.load(open(sp))
    prev.update(res)
    write_json(sp, prev)


if __name__ == "__main__":
    main()
