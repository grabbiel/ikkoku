"""Hair -> Assets/Hair/hair_<style>.glb   (run inside Blender)

  Blender -b --factory-startup --python build_hair.py -- [--sex f] [--only bob,long_straight]

Procedural styles are smooth surfaces built around the head:
  * scalp cap: lat-long shell cast from inside the skull, from the eyebrow line
    back (no gaps), offset 5 mm;
  * bangs: curved cap over the forehead whose hem is split into 5-7 wedge tips
    (longer side locks at the temples);
  * back hair (bob, long_straight): closed lofted shell around the head that
    descends and flares at the bottom, pushed outside the shoulders, plus a few
    overlapping strand cards on its surface;
  * ponytail / twintails: tapered wavy tubes from a gather point + a hair tie;
  * short_m / messy_m: the cap + short ribbon strands.
UVs: u across the strand / around the shell, v root (0) -> tip (1). Vertex colour
alpha 1 at the roots -> 0.3 at the tips (outline width multiplier). Long styles
get hair_back_* bone chains under `head`; extras.strandUV = true. Reused CC0
MakeHuman hair meshes are refit to the restyled body through their .mhclo
mapping (extras.strandUV = false).
"""
import sys, os, json, math, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from common import *
import rig as RG
import deform as DF

MH_HAIR = {  # id -> (folder, is_long)
    "mh_bob01": ("bob01", False), "mh_bob02": ("bob02", False), "mh_ponytail01": ("ponytail01", True), "mh_long01": ("long01", True),
    "mh_afro01": ("afro01", False), "mh_braid01": ("braid01", True), "mh_short01": ("short01", False), "mh_short02": ("short02", False),
    "mh_short03": ("short03", False), "mh_short04": ("short04", False),
}
TIP_ALPHA = 0.3


class Body:
    def __init__(self, sex):
        d = np.load(os.path.join(OUT, "body_%s.npz" % sex))
        self.sex = sex
        self.V = d["V"].astype(np.float64); self.N = d["normals"].astype(np.float64); self.tris = d["tris"]
        self.V_all = d["V_all"].astype(np.float64); self.Vmh_all = d["Vmh_all"].astype(np.float64); self.ground = float(d["ground"])
        self.W = d["W"]; self.bone_names = [str(b) for b in d["bone_names"]]
        self.bones = json.loads(str(d["bones"]))
        self.L = {k: (np.asarray(v) if isinstance(v, list) else v) for k, v in json.loads(str(d["landmarks"])).items()}
        self.J = {k: np.asarray(v) for k, v in json.loads(str(d["joints"])).items()}
        faces_len = d["faces_len"]; faces_flat = d["faces_flat"]
        self.faces = []; s = 0
        for n in faces_len:
            self.faces.append([int(x) for x in faces_flat[s:s + n]]); s += n
        self.bvh = BVHTree.FromPolygons([tuple(v) for v in self.V], self.faces)
        self.head_c = self.L["head_c"]; self.head_top = self.L["head_top"]

    def nearest(self, p):
        loc, nrm, idx, dist = self.bvh.find_nearest(Vector(p))
        return (np.array(loc), np.array(nrm), dist) if loc is not None else (None, None, None)

    def push_out(self, p, gap):
        """Keep point outside the body surface by `gap` (only near the surface)."""
        loc, nrm, dist = self.nearest(p)
        if loc is None:
            return p
        v = p - loc
        signed = float(v @ nrm)
        if signed < gap:
            return loc + nrm * gap
        return p

    @property
    def cast_origin(self):
        """A point inside the empty cranium (above the eye sockets / mouth cavity)."""
        return np.array([0.0, self.head_c[1] + 0.02, float(self.L["eye_z"]) + 0.05])

    def scalp_hit(self, direction):
        """Ray from inside the skull outward -> (point, normal) on the scalp."""
        d = np.asarray(direction, np.float64); d /= np.linalg.norm(d)
        o = self.cast_origin
        loc, nrm, idx, dist = self.bvh.ray_cast(Vector(o), Vector(d), 0.5)
        if loc is None or dist < 0.02:
            return None, None
        return np.array(loc), np.array(nrm)

    def head_ray(self, theta, phi):
        """Ray from the cast origin: azimuth theta (0 = front, +pi/2 = character's left), elevation phi.
        Returns (point, normal, dist) or (None, None, None)."""
        d = np.array([math.sin(theta) * math.cos(phi), -math.cos(theta) * math.cos(phi), math.sin(phi)])
        loc, nrm, idx, dist = self.bvh.ray_cast(Vector(self.cast_origin), Vector(d), 0.6)
        if loc is None:
            return None, None, None
        return np.array(loc), np.array(nrm), float(dist)


# --------------------------------------------------------------------------
# geometry helpers
# --------------------------------------------------------------------------
def resample(pts, n):
    pts = np.asarray(pts, np.float64)
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    if s[-1] <= 0:
        return np.repeat(pts[:1], n, 0)
    t = np.linspace(0, s[-1], n)
    out = np.stack([np.interp(t, s, pts[:, k]) for k in range(3)], 1)
    return out


def smooth_poly(pts, iters=2):
    pts = np.asarray(pts, np.float64).copy()
    for _ in range(iters):
        pts[1:-1] = 0.25 * pts[:-2] + 0.5 * pts[1:-1] + 0.25 * pts[2:]
    return pts


def flow_strand(body, p0, d0, hem_z=None, length=None, step=0.012, gravity=0.55, gap=0.006, curl=None, max_steps=90, wander=None):
    """March a strand from p0 along d0, pulled by gravity, sliding over the body."""
    pts = [np.asarray(p0, np.float64)]
    d = np.asarray(d0, np.float64); d /= np.linalg.norm(d)
    down = np.array([0, 0, -1.0])
    travelled = 0.0
    for i in range(max_steps):
        g = gravity if i > 1 else gravity * 0.3
        d = d * (1 - g) + down * g
        if curl is not None:
            d = d + curl(pts[-1], travelled)
        if wander is not None:
            d = d + wander
        d /= np.linalg.norm(d)
        p = pts[-1] + d * step
        p = body.push_out(p, gap)
        d = p - pts[-1]; d /= max(np.linalg.norm(d), 1e-9)
        travelled += step
        pts.append(p)
        if hem_z is not None and p[2] <= hem_z:
            break
        if length is not None and travelled >= length:
            break
    return np.asarray(pts)


def tip_alpha(t):
    """Vertex-colour alpha along a strand: 1 at the root -> TIP_ALPHA at the tip."""
    return 1.0 - (1.0 - TIP_ALPHA) * DF.smoothstep(0.45, 1.0, t)


class HairMesh:
    def __init__(self):
        self.V = []; self.F = []; self.UV = []; self.A = []; self.T = []

    def add_ribbon(self, pts, width, taper=0.85, twist=0.0, axis_c=None, n_seg=None, alpha_from=0.7, width_profile=None, bulge=0.18):
        """Clump strip: 3 vertices across (centre pushed outwards by bulge*width so the
        strand has a curved cross-section), u across 0..1, v root->tip."""
        pts = smooth_poly(pts, 2)
        n = n_seg or max(4, min(14, len(pts)))
        P = resample(pts, n)
        base = len(self.V)
        for i in range(n):
            t = i / (n - 1)
            T = (P[min(i + 1, n - 1)] - P[max(i - 1, 0)]); T /= max(np.linalg.norm(T), 1e-9)
            c = axis_c if axis_c is not None else np.array([0, 0, 0])
            O = P[i] - np.array([c[0], c[1], P[i][2]])          # horizontal radial from the head axis
            if np.linalg.norm(O) < 1e-6:
                O = np.array([0, -1.0, 0])
            O /= np.linalg.norm(O)
            S = np.cross(T, O); S /= max(np.linalg.norm(S), 1e-9)
            if twist:
                ang = twist * t
                S = S * math.cos(ang) + np.cross(T, S) * math.sin(ang)
            Oc = np.cross(S, T); Oc /= max(np.linalg.norm(Oc), 1e-9)   # outward for this ribbon
            w = width * (width_profile(t) if width_profile else (1.0 - taper * DF.smoothstep(0.55, 1.0, t) ** 1.3))
            w = max(w, width * 0.06)
            self.V.append(P[i] - S * w / 2); self.V.append(P[i] + Oc * bulge * w); self.V.append(P[i] + S * w / 2)
            self.UV.append((0.0, t)); self.UV.append((0.5, t)); self.UV.append((1.0, t))
            a = 1.0 - (1.0 - TIP_ALPHA) * DF.smoothstep(alpha_from, 1.0, t)
            self.A += [a, a, a]; self.T += [t, t, t]
        for i in range(n - 1):
            r0 = base + 3 * i; r1 = base + 3 * (i + 1)
            self.F.append([r0, r0 + 1, r1 + 1, r1]); self.F.append([r0 + 1, r0 + 2, r1 + 2, r1 + 1])

    def add_grid(self, P, UV, A, closed_u=False):
        """Quad grid: P (R, C, 3), UV (R, C, 2), A (R, C). Rows = along the strand (v), columns = across.
        Degenerate (coincident) rows are welded by index so the pole of a cap is one vertex."""
        R, C = P.shape[:2]
        base = len(self.V)
        idx = np.zeros((R, C), np.int64)
        for i in range(R):
            for j in range(C):
                if i == 0 and j > 0 and np.linalg.norm(P[0, j] - P[0, 0]) < 1e-7:
                    idx[i, j] = idx[0, 0]; continue
                idx[i, j] = len(self.V)
                self.V.append(np.asarray(P[i, j], np.float64)); self.UV.append((float(UV[i, j, 0]), float(UV[i, j, 1])))
                self.A.append(float(A[i, j])); self.T.append(float(UV[i, j, 1]))
        for i in range(R - 1):
            for j in range(C if closed_u else C - 1):
                a, b, c, d = idx[i, j], idx[i, (j + 1) % C], idx[i + 1, (j + 1) % C], idx[i + 1, j]
                f = [a, b, c, d]
                if a == b:
                    f = [a, c, d]
                self.F.append(f)

    def add_mesh(self, V, F, UV_loops, alpha=1.0):
        base = len(self.V)
        alpha = np.broadcast_to(np.asarray(alpha, np.float64), (len(V),))
        for v, a in zip(V, alpha):
            self.V.append(np.asarray(v)); self.A.append(float(a)); self.T.append(0.0)
        vuv = np.zeros((len(V), 2)); k = 0
        for f in F:
            for vi in f:
                vuv[vi] = UV_loops[k]; k += 1
        for uv in vuv:
            self.UV.append(tuple(uv))
        for f in F:
            self.F.append([base + vi for vi in f])

    def to_object(self, name, material, strand_uv=True):
        V = np.asarray(self.V); F = self.F
        uv_loops = np.asarray([self.UV[vi] for f in F for vi in f], np.float64)
        col = np.ones((len(V), 4), np.float32); col[:, 3] = np.asarray(self.A, np.float32)
        ob = bl_make_mesh(name, V, F, uv_loops, material, vcol=col)
        ob.data["strandUV"] = bool(strand_uv); ob["strandUV"] = bool(strand_uv)
        return ob


# --------------------------------------------------------------------------
# scalp sampling (short_m / messy_m strands)
# --------------------------------------------------------------------------
def sample_scalp(body, n, front_z, side_z, nape_z, seed=1, region=None):
    """Roots: ray-cast from the head centre in random directions on the upper hemisphere; keep those inside the hairline."""
    rng = np.random.default_rng(seed)
    roots = []
    tries = 0
    while len(roots) < n and tries < n * 40:
        tries += 1
        d = rng.normal(size=3); d /= np.linalg.norm(d)
        if d[2] < -0.35:
            continue
        p, nrm = body.scalp_hit(d)
        if p is None:
            continue
        ear_y = float(body.L["ear_L"][1])
        if p[1] < ear_y - 0.02 and p[2] < front_z:
            continue
        if abs(p[1] - ear_y) <= 0.02 and p[2] < side_z:
            continue
        if p[1] > ear_y + 0.02 and p[2] < nape_z:
            continue
        if p[2] < body.L["neck_z"] + 0.03:
            continue
        if region is not None and not region(p):
            continue
        roots.append((p, nrm))
    return roots


def style_common(body):
    L = body.L
    brow_z = float(L["brow_L"][2]); eye_z = float(L["eye_z"]); r = float(L["eye_r"])
    front_z = brow_z + 0.045
    side_z = float(L["ear_top_L"][2]) + 0.012
    nape_z = float(L["neck_z"]) + 0.075
    return dict(front_z=front_z, side_z=side_z, nape_z=nape_z, brow_z=brow_z, eye_z=eye_z, r=r, chin_z=float(L["chin_bottom"][2]),
                jaw_z=float(L["jaw_L"][2]), shoulder_z=float(L["shoulder_L"][2]), waist_z=float(L["waist_z"]), hc=body.head_c, top=body.head_top,
                ear_top_z=float(L["ear_top_L"][2]), ear_bottom_z=float(L["ear_bottom_L"][2]), neck_z=float(L["neck_z"]))


def flow_dir(p, nrm, hc, down_w=0.7, radial_w=0.3, lift=0.12):
    """Initial strand direction: along the scalp surface, downwards and away from the head axis."""
    down = np.array([0, 0, -1.0])
    radial = p - np.array([hc[0], hc[1], p[2]]); radial /= max(np.linalg.norm(radial), 1e-9)
    tdown = down - nrm * (down @ nrm)
    if np.linalg.norm(tdown) < 0.25:      # crown: flow outwards
        tdown = radial - nrm * (radial @ nrm)
    tdown /= max(np.linalg.norm(tdown), 1e-9)
    d = tdown * down_w + radial * radial_w + nrm * lift
    return d / np.linalg.norm(d)


# --------------------------------------------------------------------------
# smooth surfaces: cap, bangs, back shell, cards, tubes
# --------------------------------------------------------------------------
def _sstep(a, b, x):
    return float(DF.smoothstep(a, b, np.float64(x)))


def cap_boundary_z(c, theta, lower=0.0):
    """Height of the cap's lower boundary per azimuth (0 = front): just above the brows at the
    front, above the ears at the sides, the nape at the back."""
    a = abs(math.atan2(math.sin(theta), math.cos(theta)))
    z_front = c["brow_z"] + 0.022 - lower; z_side = c["ear_top_z"] + 0.006; z_back = c["nape_z"]
    if a < 0.75:
        return z_front
    if a < 1.25:
        return z_front + (z_side - z_front) * _sstep(0.75, 1.25, a)
    if a < 2.15:
        return z_side
    if a < 2.65:
        return z_side + (z_back - z_side) * _sstep(2.15, 2.65, a)
    return z_back


def elevation_for_z(body, theta, z_target, phi_hi=math.radians(88), phi_lo=math.radians(-65)):
    """Elevation (from the cast origin) at which the ray in azimuth theta hits the head at z_target,
    plus the hit at that elevation. Scans downwards; returns the lowest valid elevation if never reached."""
    prev = None
    for k in range(60):
        phi = phi_hi + (phi_lo - phi_hi) * k / 59
        p, n, d = body.head_ray(theta, phi)
        if p is None:
            break
        if p[2] <= z_target:
            if prev is None:
                return phi, (p, n, d)
            phi0, (p0, n0, d0) = prev
            t = (p0[2] - z_target) / max(p0[2] - p[2], 1e-9)
            return phi0 + (phi - phi0) * t, (p0 + (p - p0) * t, n0 + (n - n0) * t, d0 + (d - d0) * t)
        prev = (phi, (p, n, d))
    return prev[0], prev[1]


def cap_mesh(body, c, hm, cols=48, rows=10, offset=0.005, lower=0.0, v_max=0.8):
    """Lat-long scalp cap: one pole vertex on the crown, columns around the head, rows down to
    cap_boundary_z. u around (seam at the front centre), v 0 crown -> v_max boundary."""
    P = np.zeros((rows + 1, cols + 1, 3)); UV = np.zeros((rows + 1, cols + 1, 2)); A = np.ones((rows + 1, cols + 1))
    top, ntop, dtop = body.head_ray(0.0, math.radians(89.9))
    pole = top + ntop * offset
    for j in range(cols + 1):
        theta = 2 * math.pi * j / cols
        phi_min, _ = elevation_for_z(body, theta, cap_boundary_z(c, theta, lower))
        for i in range(rows + 1):
            t = i / rows
            if i == 0:
                P[i, j] = pole
            else:
                phi = math.pi / 2 - (math.pi / 2 - phi_min) * t ** 0.85
                p, n, d = body.head_ray(theta, phi)
                if p is None:
                    p, n, d = body.head_ray(theta, phi + math.radians(4))
                P[i, j] = p + n * offset
            UV[i, j] = (j / cols, v_max * t)
    hm.add_grid(P, UV, A)
    return P


def bangs_mesh(body, c, hm, n_wedges=6, cols=42, rows=8, side_len=0.05, hem_up=0.0, root_offset=0.008, tip_offset=0.016):
    """Curved fringe over the forehead: a spherical cap section around the cast origin (never
    inside the face), root at the hairline, hem cut into n_wedges wedge tips; longer side locks."""
    o = body.cast_origin
    th0, th1 = -1.0, 1.0
    z_root = c["brow_z"] + 0.058
    z_base = c["eye_z"] + 0.75 * c["r"] + hem_up
    P = np.zeros((rows + 1, cols + 1, 3)); UV = np.zeros((rows + 1, cols + 1, 2)); A = np.ones((rows + 1, cols + 1))
    for j in range(cols + 1):
        u = j / cols
        theta = th0 + (th1 - th0) * u
        phi_r, (pr, nr, dr) = elevation_for_z(body, theta, z_root)
        R_root = dr
        w = (u * n_wedges) % 1.0; tri = 1.0 - 2.0 * abs(w - 0.5)
        z_hem = z_base - 0.024 * tri
        side = _sstep(0.86, 1.0, abs(2 * u - 1))
        z_hem -= side_len * side + 0.01 * side
        for i in range(rows + 1):
            t = i / rows
            z = z_root + (z_hem - z_root) * t
            R = R_root + root_offset + (tip_offset - root_offset) * t + 0.004 * side
            s = max(min((z - o[2]) / R, 0.999), -0.999)
            phi = math.asin(s)
            d = np.array([math.sin(theta) * math.cos(phi), -math.cos(theta) * math.cos(phi), math.sin(phi)])
            p, n, dist = body.head_ray(theta, phi)
            if p is not None and dist + 0.007 > R:
                R = dist + 0.007
            P[i, j] = o + d * R
            UV[i, j] = (u, t); A[i, j] = tip_alpha(t)
    hm.add_grid(P, UV, A)
    return P


def back_shell(body, c, hm, hem_z, cols=56, rows=20, theta0=0.8, offset=0.007, flare=0.14, curl_in=0.0, gap=0.009, v_max=0.97, cap_offset=0.005):
    """Closed lofted shell around the back and sides of the head that descends to hem_z.
    Per column: head part = rays from the cast origin (elevations 86 -> 0 deg, offset blending
    from the cap's offset at the crown to `offset`), then a vertical descent from the head's
    widest point with radius growing by `flare` * drop; the last rows curl inward by curl_in
    (bob). Vertices are kept `gap` outside the body (shoulders)."""
    hc = c["hc"]
    P = np.zeros((rows + 1, cols + 1, 3)); UV = np.zeros((rows + 1, cols + 1, 2)); A = np.ones((rows + 1, cols + 1))
    for j in range(cols + 1):
        u = j / cols
        theta = theta0 + (2 * math.pi - 2 * theta0) * u
        poly = []
        for phi_deg in (86, 74, 62, 50, 38, 26, 14, 4, 0):
            p, n, d = body.head_ray(theta, math.radians(phi_deg))
            if p is None:
                continue
            off = cap_offset + (offset - cap_offset) * _sstep(40.0, 80.0, 90.0 - phi_deg)
            poly.append(p + n * off)
        eq = poly[-1]
        radial = eq - np.array([hc[0], hc[1], eq[2]]); r_eq = np.linalg.norm(radial); radial /= max(r_eq, 1e-9)
        z_eq = eq[2]
        drop = z_eq - hem_z
        nz = max(int(drop / 0.03), 2)
        for k in range(1, nz + 1):
            s = k / nz
            z = z_eq - drop * s
            r = r_eq + flare * drop * s ** 1.15
            if curl_in:
                r -= curl_in * r_eq * DF.smoothstep(0.5, 1.0, np.float64(s)) ** 1.5
            q = np.array([hc[0], hc[1], z]) + radial * r
            q = body.push_out(q, gap)
            poly.append(q)
        Q = resample(smooth_poly(np.asarray(poly), 1), rows + 1)
        for i in range(rows + 1):
            t = i / rows
            P[i, j] = Q[i] if i < 2 else body.push_out(Q[i], gap)
            UV[i, j] = (0.06 + 0.88 * u, v_max * t); A[i, j] = tip_alpha(t)
    # relax the loft (not the top rows / hem) so the head/descent junction is smooth
    for _ in range(8):
        Pn = P.copy()
        Pn[3:-1, 1:-1] = 0.5 * P[3:-1, 1:-1] + 0.125 * (P[2:-2, 1:-1] + P[4:, 1:-1] + P[3:-1, :-2] + P[3:-1, 2:])
        P = Pn
    for i in range(3, rows):
        for j in range(1, cols):
            P[i, j] = body.push_out(P[i, j], gap)
    hm.add_grid(P, UV, A)
    return P


def strand_cards(body, c, hm, P, rng, n_cards=10, width=(0.028, 0.042), extend=0.03, lift=0.003, start=(0.42, 0.55)):
    """Overlapping strand cards lying on a shell grid P (rows x cols x 3), from below the head's
    widest point down to a little past the hem (they never stick out above the crown)."""
    hc = c["hc"]; R, C = P.shape[:2]
    for k in range(n_cards):
        uj = rng.uniform(0.04, 0.96) * (C - 1)
        j0 = int(uj); f = uj - j0; j1 = min(j0 + 1, C - 1)
        i0 = int(rng.uniform(*start) * (R - 1))
        pts = []
        for i in range(i0, R):
            p = P[i, j0] * (1 - f) + P[i, j1] * f
            radial = p - np.array([hc[0], hc[1], p[2]]); radial /= max(np.linalg.norm(radial), 1e-9)
            s = (i - i0) / max(R - 1 - i0, 1)
            pts.append(p + radial * (lift + 0.003 * s + 0.002 * rng.random()))
        d = pts[-1] - pts[-2]; d /= max(np.linalg.norm(d), 1e-9)
        pts.append(pts[-1] + d * extend * rng.uniform(0.6, 1.0))
        hm.add_ribbon(pts, rng.uniform(*width), axis_c=hc, twist=rng.uniform(-0.2, 0.2), taper=0.8, alpha_from=0.55, bulge=0.15,
                      width_profile=lambda t: (0.55 + 0.45 * DF.smoothstep(0.0, 0.25, t)) * (1.0 - 0.8 * DF.smoothstep(0.6, 1.0, t) ** 1.3))


def tube_mesh(hm, centre, radius_fn, n_around=12, alpha_fn=tip_alpha):
    """Tapered tube around a centreline: rings (n_around + 1 verts, duplicate seam column), a
    fan cap at the base and the last ring collapsed to the tip. u around, v along."""
    Pc = np.asarray(centre); n = len(Pc)
    ref = np.array([0, 0, 1.0])
    P = np.zeros((n + 1, n_around + 1, 3)); UV = np.zeros((n + 1, n_around + 1, 2)); A = np.ones((n + 1, n_around + 1))
    N1 = None
    for i in range(n):
        T = Pc[min(i + 1, n - 1)] - Pc[max(i - 1, 0)]; T /= max(np.linalg.norm(T), 1e-9)
        if N1 is None:
            N1 = np.cross(T, ref if abs(T @ ref) < 0.9 else np.array([1.0, 0, 0]))
        N1 = N1 - T * (N1 @ T); N1 /= max(np.linalg.norm(N1), 1e-9)      # parallel transport
        N2 = np.cross(T, N1)
        t = i / (n - 1); r = radius_fn(t) if i < n - 1 else 0.0015
        for k in range(n_around + 1):
            a = 2 * math.pi * k / n_around
            P[i + 1, k] = Pc[i] + (N1 * math.cos(a) + N2 * math.sin(a)) * r
            UV[i + 1, k] = (k / n_around, t); A[i + 1, k] = alpha_fn(t)
    P[0, :] = Pc[0]; UV[0, :, 0] = UV[1, :, 0]; UV[0, :, 1] = 0.0     # base cap (welded pole row)
    hm.add_grid(P, UV, A)
    return P


def wavy_tail(body, origin, direction, length, wave_amp, wave_len, gravity, n=18, gap=0.02, side=None):
    """Centreline of a ponytail: gravity flow from the origin with a sinusoidal side wave."""
    pts = flow_strand(body, origin, direction, length=length, step=length / 24, gravity=gravity, gap=gap, max_steps=40)
    pts = resample(pts, n)
    s = np.linspace(0, length, n)
    if side is None:
        side = np.array([1.0, 0, 0])
    out = pts + np.outer(np.sin(2 * math.pi * s / wave_len) * wave_amp * DF.smoothstep(0.0, 0.25, s / length), side)
    return np.asarray([body.push_out(p, gap) for p in out])


def tie_mesh(origin, axis, r_major=0.018, r_minor=0.006):
    """Small torus (scrunchie) around `axis` at origin."""
    axis = np.asarray(axis, np.float64); axis /= np.linalg.norm(axis)
    a = np.cross(axis, [0, 0, 1])
    if np.linalg.norm(a) < 1e-6:
        a = np.cross(axis, [1, 0, 0])
    a /= np.linalg.norm(a); b = np.cross(axis, a)
    V = []; F = []; UV = []
    nu, nv = 16, 8
    for i in range(nu):
        th = 2 * math.pi * i / nu
        ring_c = origin + (a * math.cos(th) + b * math.sin(th)) * r_major
        rad = (a * math.cos(th) + b * math.sin(th))
        for j in range(nv):
            ph = 2 * math.pi * j / nv
            V.append(ring_c + rad * math.cos(ph) * r_minor + axis * math.sin(ph) * r_minor)
    for i in range(nu):
        for j in range(nv):
            F.append([i * nv + j, ((i + 1) % nu) * nv + j, ((i + 1) % nu) * nv + (j + 1) % nv, i * nv + (j + 1) % nv])
            UV += [(i / nu, j / nv), ((i + 1) / nu, j / nv), ((i + 1) / nu, (j + 1) / nv), (i / nu, (j + 1) / nv)]
    return np.asarray(V), F, np.asarray(UV)


def side_locks(body, c, hm, length, width=0.018):
    """Two tapered strands in front of the ears, curling in toward the jaw (ponytail / twintails)."""
    hc = c["hc"]
    for sgn in (1, -1):
        p, n = body.scalp_hit(np.array([sgn * 1.0, -0.3, 0.2]))
        if p is None:
            continue

        def curl(q, s, sgn=sgn):
            return np.array([-sgn * 0.35, -0.15, 0.0]) * DF.smoothstep(0.3, 1.0, np.float64(s / length))
        pts = flow_strand(body, p + n * 0.007, np.array([sgn * 0.2, -0.2, -1.0]), length=length, step=0.012, gravity=0.5, gap=0.008, curl=curl)
        hm.add_ribbon(pts, width, axis_c=hc, taper=0.85, twist=sgn * 0.4, alpha_from=0.5, bulge=0.25)


def gather_point(body, direction, lift=0.018):
    p, n = body.scalp_hit(np.asarray(direction, np.float64))
    return p + n * lift, n


# --------------------------------------------------------------------------
# styles
# --------------------------------------------------------------------------
def build_style(style, body, mat, mat_tie):
    c = style_common(body); rng = np.random.default_rng(11)
    parts = {}
    chain = []
    if style == "bob":
        hm = HairMesh()
        cap_mesh(body, c, hm)
        bangs_mesh(body, c, hm, n_wedges=6, side_len=0.03)
        P = back_shell(body, c, hm, hem_z=c["chin_z"] + 0.005, flare=0.10, curl_in=0.22)
        strand_cards(body, c, hm, P, rng, n_cards=9, extend=0.012, width=(0.024, 0.036))
        parts["hair"] = hm
    elif style == "long_straight":
        hm = HairMesh()
        cap_mesh(body, c, hm)
        bangs_mesh(body, c, hm, n_wedges=7, side_len=0.09)
        parts["hair_front"] = hm
        hb = HairMesh()
        hem = c["waist_z"] + 0.02
        P = back_shell(body, c, hb, hem_z=hem, flare=0.09, gap=0.01, rows=26)
        strand_cards(body, c, hb, P, rng, n_cards=10, width=(0.03, 0.045), extend=0.03, start=(0.35, 0.5))
        parts["hair_back"] = hb
        chain = [np.array([0, c["hc"][1] + 0.075, c["nape_z"] + 0.02]), np.array([0, c["hc"][1] + 0.07, c["shoulder_z"] - 0.02]),
                 np.array([0, c["hc"][1] + 0.05, c["shoulder_z"] - 0.14]), np.array([0, c["hc"][1] + 0.03, hem])]
    elif style == "ponytail":
        hm = HairMesh()
        cap_mesh(body, c, hm, offset=0.006)
        bangs_mesh(body, c, hm, n_wedges=5, side_len=0.02)
        side_locks(body, c, hm, length=0.10)
        parts["hair"] = hm
        g, gn = gather_point(body, [0, 1.0, -0.12], lift=0.008)           # occiput, just above the ear line
        centre = wavy_tail(body, g, np.array([0, 0.8, -0.45]), length=0.40, wave_amp=0.016, wave_len=0.15, gravity=0.38)
        r_base = 0.034
        hb = HairMesh()
        tube_mesh(hb, centre, lambda t: 0.005 + r_base * (1.0 - 0.85 * t ** 1.3) * (1.0 + 0.2 * math.sin(math.pi * min(t / 0.35, 1.0))))
        parts["hair_back"] = hb
        ht = HairMesh(); ht.add_mesh(*tie_mesh(centre[0] + (centre[1] - centre[0]) * 0.55, centre[1] - centre[0], r_major=r_base + 0.004, r_minor=0.008))
        parts["hair_tie"] = ht
        chain = [centre[0], centre[6], centre[12], centre[-1]]
    elif style == "twintails":
        hm = HairMesh()
        cap_mesh(body, c, hm, offset=0.006)
        bangs_mesh(body, c, hm, n_wedges=6, side_len=0.015)
        parts["hair"] = hm
        hb = HairMesh(); chain = []
        r_base = 0.031
        for sgn in (1, -1):
            g, gn = gather_point(body, [sgn * 1.0, 0.35, 0.22], lift=0.008)   # above and behind the ear
            centre = wavy_tail(body, g, np.array([sgn * 0.75, 0.2, -0.6]), length=0.46, wave_amp=0.014, wave_len=0.16, gravity=0.45,
                               side=np.array([0, 1.0, 0]))
            tube_mesh(hb, centre, lambda t: 0.005 + r_base * (1.0 - 0.85 * t ** 1.3) * (1.0 + 0.2 * math.sin(math.pi * min(t / 0.35, 1.0))))
            ht = HairMesh(); ht.add_mesh(*tie_mesh(centre[0] + (centre[1] - centre[0]) * 0.6, centre[1] - centre[0], r_major=r_base + 0.004, r_minor=0.0075))
            parts["hair_tie_%s" % ("L" if sgn > 0 else "R")] = ht
            chain.append([centre[0], centre[6], centre[12], centre[-1]])
        parts["hair_back"] = hb
    elif style in ("short_m", "messy_m"):
        hm = HairMesh()
        cap_mesh(body, c, hm, lower=0.01)
        messy = style == "messy_m"
        for p, nrm in sample_scalp(body, 170 if messy else 140, c["front_z"] - 0.01, c["side_z"], c["nape_z"] + 0.01, seed=3):
            d0 = flow_dir(p, nrm, c["hc"], down_w=0.5, radial_w=0.5, lift=0.25 if messy else 0.15) + np.array([rng.uniform(-0.5, 0.5), rng.uniform(-0.6, 0.3), rng.uniform(-0.6, 0.5) if messy else -0.2]) * (0.8 if messy else 0.3)
            pts = flow_strand(body, p + nrm * 0.006, d0, length=rng.uniform(0.05, 0.085) if not messy else rng.uniform(0.06, 0.11), step=0.012,
                              gravity=0.12 if not messy else 0.05, gap=0.008)
            hm.add_ribbon(pts, rng.uniform(0.022, 0.03), axis_c=c["hc"], twist=rng.uniform(-0.6, 0.6), taper=0.85, alpha_from=0.55)
        parts["hair"] = hm
    return parts, chain


def chain_weights(V, chain_pts, head_name, chain_names):
    """Per-vertex (head, chain bones...) weights for a chain of bones through chain_pts."""
    P = np.asarray(chain_pts)
    segs = len(chain_names)
    W = np.zeros((len(V), segs + 1))
    for i, p in enumerate(V):
        best = (1e9, 0, 0.0)
        for s in range(segs):
            a, b = P[s], P[s + 1]; ab = b - a
            t = float(np.clip(((p - a) @ ab) / max(ab @ ab, 1e-9), 0, 1))
            d = np.linalg.norm(p - (a + ab * t))
            if d < best[0]:
                best = (d, s, t)
        d, s, t = best
        # above the chain start -> head
        z_rel = p[2] - P[0][2]
        head_w = DF.smoothstep(-0.06, 0.02, z_rel)
        if s == 0 and t < 0.5:
            wa, wb = 1 - t * 2 * 0.5, t * 2 * 0.5
        else:
            wa, wb = 1 - t, t
        W[i, 0] = head_w
        W[i, 1 + s] += (1 - head_w) * wa
        if s + 1 < segs:
            W[i, 2 + s] += (1 - head_w) * wb
        else:
            W[i, 1 + s] += (1 - head_w) * wb
    return W


def export_style(style, body, sex):
    bl_reset()
    strand_tex = os.path.join(A_TEX, "hair_strand.png")
    mat = bl_material("ik_hair", (0.92, 0.9, 0.95, 1), image_path=strand_tex if os.path.exists(strand_tex) else None, alpha_clip=True)
    mat_tie = bl_material("ik_item", (0.9, 0.3, 0.4, 1))
    import time as _t; t0 = _t.time()
    parts, chain = build_style(style, body, mat, mat_tie)
    log("  surfaces built in %.1fs: %s" % (_t.time() - t0, {k: len(v.V) for k, v in parts.items()}))
    bones = json.loads(json.dumps(body.bones))
    chains = []
    if chain:
        if isinstance(chain[0], list):   # multiple chains (twintails): hair_back_01..03 (L), hair_back_04..06 (R), each rooted at head
            idx = 0
            for ch in chain:
                names = []; parent = "head"
                for i in range(len(ch) - 1):
                    idx += 1; n = "hair_back_%02d" % idx
                    bones.append(dict(name=n, head=np.asarray(ch[i]).tolist(), tail=np.asarray(ch[i + 1]).tolist(), parent=parent, deform=True))
                    parent = n; names.append(n)
                chains.append((ch, names))
        else:
            names = RG.add_hair_chain(bones, "hair_back", [np.asarray(p) for p in chain], parent="head")
            chains.append((chain, names))
    arm = RG.build_armature(bones, "Armature")
    objs = [arm]
    stats = {}
    for name, hm in parts.items():
        is_tie = name.startswith("hair_tie")
        ob = hm.to_object(name, mat_tie if is_tie else mat, strand_uv=not is_tie)
        V = np.asarray(hm.V)
        vg_head = ob.vertex_groups.new(name="head")
        if name in ("hair_back",) and chains:
            # nearest chain per vertex
            best = None
            for ch, names in chains:
                W = chain_weights(V, ch, "head", names)
                d = np.linalg.norm(V - np.asarray(ch[0]), axis=1)
                if best is None:
                    best = (d, W, names)
                    W_sel = W; N_sel = [names] * len(V); dist = d
                else:
                    closer = d < dist
                    W_sel = np.where(closer[:, None], W, W_sel); dist = np.minimum(d, dist)
                    N_sel = [names if closer[i] else N_sel[i] for i in range(len(V))]
            groups = {bn: ob.vertex_groups.new(name=bn) for ch, names in chains for bn in names}
            for i in range(len(V)):
                names = N_sel[i]
                vg_head.add([i], float(W_sel[i, 0]), "REPLACE")
                for s, bn in enumerate(names):
                    w = float(W_sel[i, 1 + s])
                    if w > 1e-4:
                        groups[bn].add([i], w, "REPLACE")
        else:
            vg_head.add(list(range(len(V))), 1.0, "REPLACE")
        mod = ob.modifiers.new("Armature", "ARMATURE"); mod.object = arm; ob.parent = arm
        objs.append(ob)
        A = np.asarray(hm.A)
        stats[name] = dict(verts=len(V), faces=len(hm.F), alpha_min=round(float(A.min()), 2))
    log("  objects+weights in %.1fs" % (_t.time() - t0))
    out = os.path.join(A_HAIR, "hair_%s.glb" % style)
    bl_export_glb(out, objs)
    info, js, blob = glb_summary(out)
    return dict(file=os.path.relpath(out, REPO), bytes=os.path.getsize(out), parts=stats, chain_bones=[n for ch, names in chains for n in names])


def export_mh(hid, body, sex):
    folder, is_long = MH_HAIR[hid]
    p = load_mhclo(os.path.join(MH, "system/hair/%s/%s.mhclo" % (folder, folder)))
    V = mh_to_bl(fit_proxy(p, body.Vmh_all), body.ground)
    bl_reset()
    tex = os.path.join(OUT, "tex", "hair_mh_%s.png" % folder)
    mat = bl_material("ik_hair", (0.92, 0.9, 0.95, 1), image_path=tex if os.path.exists(tex) else None, alpha_clip=True)
    mesh = p.mesh
    uv_loops = []
    for fi, f in enumerate(mesh["faces"]):
        for ti in mesh["fuv"][fi]:
            uv_loops.append(mesh["vt"][ti] if ti >= 0 and len(mesh["vt"]) else (0, 0))
    col = np.ones((len(V), 4), np.float32)
    ob = bl_make_mesh("hair", V, mesh["faces"], np.asarray(uv_loops), mat, vcol=col)
    ob.data["strandUV"] = False; ob["strandUV"] = False
    bones = json.loads(json.dumps(body.bones))
    chains = []
    if is_long and V[:, 2].min() < body.L["neck_z"] - 0.02:
        c = style_common(body)
        zmin = float(V[:, 2].min())
        ch = [np.array([0, c["hc"][1] + 0.07, c["nape_z"] + 0.02]), np.array([0, c["hc"][1] + 0.06, c["shoulder_z"] - 0.03]),
              np.array([0, c["hc"][1] + 0.05, (c["shoulder_z"] - 0.03 + zmin) / 2]), np.array([0, c["hc"][1] + 0.04, zmin])]
        names = RG.add_hair_chain(bones, "hair_back", ch, parent="head")
        chains.append((ch, names))
    arm = RG.build_armature(bones, "Armature")
    vg_head = ob.vertex_groups.new(name="head")
    if chains:
        ch, names = chains[0]
        W = chain_weights(V, ch, "head", names)
        groups = {bn: ob.vertex_groups.new(name=bn) for bn in names}
        for i in range(len(V)):
            vg_head.add([i], float(W[i, 0]), "REPLACE")
            for s, bn in enumerate(names):
                if W[i, 1 + s] > 1e-4:
                    groups[bn].add([i], float(W[i, 1 + s]), "REPLACE")
    else:
        vg_head.add(list(range(len(V))), 1.0, "REPLACE")
    mod = ob.modifiers.new("Armature", "ARMATURE"); mod.object = arm; ob.parent = arm
    out = os.path.join(A_HAIR, "hair_%s.glb" % hid)
    bl_export_glb(out, [arm, ob])
    glb_summary(out)
    return dict(file=os.path.relpath(out, REPO), bytes=os.path.getsize(out), parts={"hair": dict(verts=len(V), faces=len(mesh["faces"]))},
                chain_bones=[n for ch, names in chains for n in names], source=folder)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser(); ap.add_argument("--sex", default="f"); ap.add_argument("--only", default=None)
    args = ap.parse_args(argv)
    body = Body(args.sex)
    styles = ["bob", "long_straight", "ponytail", "twintails", "short_m", "messy_m"] + list(MH_HAIR.keys())
    if args.only:
        styles = args.only.split(",")
    summary = {}
    sp = os.path.join(OUT, "hair_summary.json")
    if os.path.exists(sp):
        summary = json.load(open(sp))
    for s in styles:
        log("=== hair", s)
        summary[s] = export_mh(s, body, args.sex) if s in MH_HAIR else export_style(s, body, args.sex)
    write_json(sp, summary)


if __name__ == "__main__":
    main()
