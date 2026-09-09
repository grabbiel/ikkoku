"""Small numpy deformation library: masks, ops, the default anime restyle and
the morph-target table. Every morph is a pure function of vertex positions
(and optionally normals) so it can be evaluated on the body and on any
attached mesh (eyelashes, eyebrows, eyeballs) alike.
"""
import math
from collections import OrderedDict
import numpy as np
from common import smoothstep, laplacian_smooth, vertex_normals, N_BODY, log
import landmarks as LM


# --------------------------------------------------------------------------
# masks (all return arrays in [0,1])
# --------------------------------------------------------------------------
def m_radial(P, c, r0, r1):
    d = np.linalg.norm(P - c, axis=1)
    return 1.0 - smoothstep(r0, r1, d)


def m_ellipsoid(P, c, radii, soft=0.4):
    d = np.linalg.norm((P - c) / np.asarray(radii), axis=1)
    return 1.0 - smoothstep(1.0 - soft, 1.0 + soft, d)


def m_zband(P, z0, z1, s0=0.02, s1=0.02):
    z = P[:, 2]
    return smoothstep(z0 - s0, z0 + s0, z) * (1.0 - smoothstep(z1 - s1, z1 + s1, z))


def m_above(P, z0, s=0.02):
    return smoothstep(z0 - s, z0 + s, P[:, 2])


def m_below(P, z0, s=0.02):
    return 1.0 - smoothstep(z0 - s, z0 + s, P[:, 2])


def m_side(P, sign, soft=0.01):
    return smoothstep(-soft, soft, P[:, 0] * sign)


def m_front(P, y0, soft=0.02):
    return 1.0 - smoothstep(y0 - soft, y0 + soft, P[:, 1])


def m_back(P, y0, soft=0.02):
    return smoothstep(y0 - soft, y0 + soft, P[:, 1])


def seg_dist(P, a, b):
    ab = b - a; L2 = float(ab @ ab)
    t = np.clip(((P - a) @ ab) / max(L2, 1e-12), 0.0, 1.0)
    q = a + t[:, None] * ab
    return np.linalg.norm(P - q, axis=1), t, q


def m_segment(P, a, b, r_in, r_out, t_fade=(0.12, 0.12)):
    d, t, _ = seg_dist(P, a, b)
    m = 1.0 - smoothstep(r_in, r_out, d)
    if t_fade[0] > 0:
        m *= smoothstep(0.0, t_fade[0], t)
    if t_fade[1] > 0:
        m *= 1.0 - smoothstep(1.0 - t_fade[1], 1.0, t)
    return m


# --------------------------------------------------------------------------
# ops: return deltas
# --------------------------------------------------------------------------
def op_scale(P, c, s, mask):
    s = np.broadcast_to(np.asarray(s, np.float64), (3,))
    return (P - c) * (s - 1.0) * mask[:, None]


def op_translate(P, v, mask):
    return np.broadcast_to(np.asarray(v, np.float64), P.shape) * mask[:, None]


def op_rotate(P, c, axis, angle, mask):
    axis = np.asarray(axis, np.float64); axis = axis / np.linalg.norm(axis)
    K = np.array([[0, -axis[2], axis[1]], [axis[2], 0, -axis[0]], [-axis[1], axis[0], 0]])
    R = np.eye(3) + math.sin(angle) * K + (1 - math.cos(angle)) * (K @ K)
    return ((P - c) @ R.T + c - P) * mask[:, None]


def op_axis_scale(P, a, b, s, mask):
    """Scale perpendicular to segment ab (thickness change)."""
    d, t, q = seg_dist(P, a, b)
    return (P - q) * (s - 1.0) * mask[:, None]


# --------------------------------------------------------------------------
# default anime restyle
# --------------------------------------------------------------------------
def restyle_anime(V_all, body_faces, groups, tris, adj, cfg=None):
    """Apply the default restyle to all base vertices (body + helpers).
    Returns new V_all and a log of steps."""
    defaults = dict(head=1.15, eye=1.5, nose=0.6, mouth=0.85, neck=0.85, legs=1.06, limbs=0.92, face_smooth=2)
    defaults.update(cfg or {}); cfg = defaults
    P = V_all.copy()

    def LMK():
        return LM.compute(P, body_faces, groups, tris=tris)

    L = LMK()
    # 1. legs +6% length (scale z about hip joint height for everything below, then re-ground)
    m = m_below(P, L["hip_z"] + 0.03, s=0.06)
    P += op_scale(P, np.array([0, 0, L["hip_z"]]), (1, 1, cfg["legs"]), m)
    P[:, 2] -= P[:N_BODY, 2].min()
    L = LMK()
    # 2. limbs slimmed
    for side in ("L", "R"):
        for key, r in (("upperarm_" + side, 0.08), ("forearm_" + side, 0.06), ("thigh_" + side, 0.12), ("calf_" + side, 0.09)):
            a, b = L[key]
            m = m_segment(P, a, b, r, r * 1.6, t_fade=(0.15, 0.15))
            P += op_axis_scale(P, a, b, cfg["limbs"], m)
    # 3. neck thinner (cylindrical about neck axis)
    L = LMK()
    m = m_zband(P, L["clav_z"] + 0.005, L["chin_bottom"][2] - 0.008, 0.02, 0.012)
    m *= 1.0 - smoothstep(L["neck_r"] * 1.6, L["neck_r"] * 2.6, np.hypot(P[:, 0], P[:, 1] - L["neck_axis_y"]))
    ax_a = np.array([0.0, L["neck_axis_y"], L["clav_z"]]); ax_b = np.array([0.0, L["neck_axis_y"], L["chin_bottom"][2]])
    P += op_axis_scale(P, ax_a, ax_b, cfg["neck"], m)
    # 4. head x1.15 about neck base
    L = LMK()
    c = np.array([0.0, L["neck_axis_y"], L["neck_z"]])
    m = m_above(P, L["neck_z"] + 0.035, s=0.035)
    P += op_scale(P, c, cfg["head"], m)
    # 5. eyes x1.5 (sockets + eyeball helpers). Scaled about the eyeball's FRONT
    #    pole so the lid surface keeps its depth and the (still spherical) eyeball
    #    grows backwards into the skull instead of bulging out of the face.
    L = LMK()
    r = L["eye_r"]
    for side in ("L", "R"):
        c = L["eye_" + side]
        pivot = c + np.array([0.0, -r, 0.0])
        m = m_radial(P, c, 1.2 * r, 2.6 * r)
        P += op_scale(P, pivot, cfg["eye"], m)
    # 6. nose x0.65 about its midpoint (keeps nasion and subnasale roughly in place)
    L = LMK()
    c = L["nose_c"]
    radii = np.array([0.022, 0.022, 0.5 * (L["nose_root"][2] - L["nose_base"][2]) + 0.006])
    m = m_ellipsoid(P, c, radii, soft=0.45) * (1.0 - m_below(P, L["nose_base"][2] - 0.002, s=0.004))
    P += op_scale(P, c, cfg["nose"], m)
    # soften the compressed nostrils
    B = P[:N_BODY]
    nm = m_radial(B, L["nose_base"], 0.006, 0.016)
    P[:N_BODY] = laplacian_smooth(B, adj, nm, iters=3, lam=0.5, taubin_mu=-0.52)
    # 7. mouth x0.85 about mouth centre
    L = LMK()
    m = m_ellipsoid(P, L["mouth_c"], (L["mouth_half_width"] * 1.3, 0.02, 0.016), soft=0.5)
    P += op_scale(P, L["mouth_c"], cfg["mouth"], m)
    # 7b. rounder cheeks (fill the hollow under the cheekbone) and soften the socket ring
    L = LMK()
    B = P[:N_BODY]
    for side, sgn in (("L", 1), ("R", -1)):
        cm = m_radial(B, L["cheek_" + side], 0.015, 0.05)
        B += op_translate(B, (0.0025 * sgn, -0.0035, 0.0), cm)
    ring = np.zeros(N_BODY)
    for side in ("L", "R"):
        d = np.linalg.norm(B - L["eye_" + side], axis=1)
        ring = np.maximum(ring, smoothstep(1.45 * L["eye_r"], 1.8 * L["eye_r"], d) * (1.0 - smoothstep(2.6 * L["eye_r"], 3.4 * L["eye_r"], d)))
    ring *= m_front(B, L["head_c"][1], 0.03)
    P[:N_BODY] = laplacian_smooth(B, adj, ring, iters=8, lam=0.5, taubin_mu=-0.52)
    # 7c. taller anime eye opening: slide the lid margins over the eyeball (rotation about the eye centre)
    L = LMK()
    Nb = vertex_normals(P[:N_BODY], tris)
    N_all = np.zeros_like(P); N_all[:N_BODY] = Nb
    helper_mask = np.zeros(len(P), bool); helper_mask[N_BODY:] = True
    for side in ("L", "R"):
        P += lid_rotation(P, L, side, math.radians(cfg.get("lid_open_upper", 18)), math.radians(cfg.get("lid_open_lower", 8)), N=np.where(helper_mask[:, None], 0.0, N_all), ignore_facing=helper_mask)
    # 7d. lid margins: smooth the (blocky, heavy) lid loops and taper the opening into an almond
    L = LMK()
    B = P[:N_BODY]
    Nb = vertex_normals(B, tris)
    lid_m = np.zeros(N_BODY)
    for side in ("L", "R"):
        c = L["eye_" + side]; r = L["eye_r"]
        v = B - c; d = np.linalg.norm(v, axis=1)
        facing = (Nb * v).sum(1) / np.maximum(d, 1e-9)
        ring = smoothstep(0.9 * r, 1.02 * r, d) * (1.0 - smoothstep(1.45 * r, 1.75 * r, d))
        ring *= 1.0 - smoothstep(c[1] + 0.2 * r, c[1] + 0.6 * r, B[:, 1])      # front of the eye only
        ring *= smoothstep(-0.35, -0.05, facing)                               # not the socket pocket
        lid_m = np.maximum(lid_m, ring)
        # almond: pull the margin toward the eye's horizontal centre line near the corners
        corner = smoothstep(0.45 * r, 1.1 * r, np.abs(B[:, 0] - c[0])) * ring
        B[:, 2] -= (B[:, 2] - c[2]) * 0.22 * corner
    P[:N_BODY] = laplacian_smooth(B, adj, lid_m, iters=cfg.get("lid_smooth", 3), lam=0.5, taubin_mu=-0.52)
    # 8. face smoothing (body only; protect eye rims and lip line)
    L = LMK()
    B = P[:N_BODY]
    fm = m_front(B, L["head_c"][1] - 0.01, 0.03) * m_zband(B, L["chin_bottom"][2] - 0.01, L["head_top"][2] - 0.02, 0.02, 0.03)
    for side in ("L", "R"):
        fm *= smoothstep(1.15 * L["eye_r"], 1.6 * L["eye_r"], np.linalg.norm(B - L["eye_" + side], axis=1))
    fm *= 1.0 - (1.0 - smoothstep(0.002, 0.006, np.abs(B[:, 2] - L["mouth_z"]))) * (np.abs(B[:, 0]) < L["mouth_half_width"] * 1.1)
    Bs = laplacian_smooth(B, adj, fm, iters=cfg["face_smooth"], lam=0.5, taubin_mu=-0.53)
    P[:N_BODY] = Bs
    L = LMK()
    log("restyle done: height %.3f m, eye r %.4f, eye centre %s, mouth width %.3f, head half width %.3f" % (
        P[:N_BODY, 2].max(), L["eye_r"], np.round(L["eye_L"], 4), 2 * L["mouth_half_width"], L["head_half_width"]))
    return P, L


# --------------------------------------------------------------------------
# morph targets
# --------------------------------------------------------------------------
class Ctx:
    def __init__(self, P, N=None):
        self.P = P; self.N = N


def _lid_masks(P, L, side, N=None):
    """(upper lid mask, lower lid mask, dist) around one eye; lids = outward
    facing skin in front of the eyeball within ~1.9 r of the centre. The
    socket cavity (a skin pocket hugging the eyeball, normals pointing at the
    eye centre) is excluded via the normals when available."""
    c = L["eye_" + side]; r = L["eye_r"]
    v = P - c
    d = np.linalg.norm(v, axis=1)
    front = 1.0 - smoothstep(c[1] + 0.25 * r, c[1] + 0.7 * r, P[:, 1])
    ring = 1.0 - smoothstep(1.25 * r, 1.95 * r, d)
    if N is not None:
        # socket cavity = inward-facing skin behind the front cap (the lid's own inner edge is in front)
        facing = (N * v).sum(1) / np.maximum(d, 1e-9)
        cavity = (1.0 - smoothstep(-0.5, -0.15, facing)) * smoothstep(c[1] - 0.62 * r, c[1] - 0.35 * r, P[:, 1])
        ring = ring * (1.0 - cavity)
    up = smoothstep(-0.25 * r, 0.15 * r, P[:, 2] - c[2])
    return ring * front * up, ring * front * (1.0 - up), d


def _project_out(P, delta, c, r_min, mask):
    """After moving lid vertices, keep them outside the eyeball sphere."""
    Q = P + delta
    v = Q - c; d = np.linalg.norm(v, axis=1); d[d == 0] = 1
    push = np.clip(r_min - d, 0, None) * (mask > 0.02)
    return delta + v / d[:, None] * push[:, None]


def lid_rotation(P, L, side, ang_upper, ang_lower, N=None, ignore_facing=None):
    """Rotate the upper lid by ang_upper (positive = opens/up... see below) and
    the lower lid by ang_lower about the eye centre (x axis), so lid margins
    slide over the eyeball sphere. Convention: ang_upper > 0 raises the upper
    lid (opens), ang_lower > 0 lowers the lower lid (opens)."""
    up, lo, d = _lid_masks(P, L, side, N)
    if ignore_facing is not None:
        # helper geometry (eyelash helpers) has no meaningful normals: use the plain masks
        up2, lo2, _ = _lid_masks(P, L, side, None)
        up = np.where(ignore_facing, up2, up); lo = np.where(ignore_facing, lo2, lo)
    c = L["eye_" + side]
    delta = op_rotate(P, c, (1, 0, 0), -ang_upper, up) + op_rotate(P, c, (1, 0, 0), ang_lower, lo)
    return delta


def morph_table(L):
    """OrderedDict name -> fn(ctx) returning delta (n,3) for the +1 direction."""
    r = L["eye_r"]; hw = L["head_half_width"]; mw = L["mouth_half_width"]
    hc = L["head_c"]; neck_c = np.array([0.0, L["neck_axis_y"], L["neck_z"]])
    head_m = lambda P: m_above(P, L["neck_z"] + 0.03, 0.03)
    M = OrderedDict()

    def both(fn):
        """Mirror a one-sided op: each vertex is driven by its own side only (soft blend at x=0)."""
        def f(ctx):
            sL = smoothstep(-0.004, 0.004, ctx.P[:, 0])[:, None]
            try:
                return fn(ctx.P, "L", N=ctx.N) * sL + fn(ctx.P, "R", N=ctx.N) * (1.0 - sL)
            except TypeError:
                return fn(ctx.P, "L") * sL + fn(ctx.P, "R") * (1.0 - sL)
        return f

    # ---- face
    M["face.head_width"] = lambda c: op_scale(c.P, hc, (1.10, 1, 1), head_m(c.P))
    M["face.head_height"] = lambda c: op_scale(c.P, neck_c, (1, 1, 1.08), head_m(c.P))
    M["face.upper_depth"] = lambda c: op_scale(c.P, hc, (1, 1.12, 1), head_m(c.P) * m_above(c.P, L["eye_z"] - 0.01, 0.03))
    M["face.lower_depth"] = lambda c: op_scale(c.P, hc, (1, 1.12, 1), head_m(c.P) * m_below(c.P, L["eye_z"] - 0.02, 0.03))
    jaw_m = lambda P: head_m(P) * m_below(P, L["mouth_z"] + 0.005, 0.02) * m_front(P, hc[1] + 0.01, 0.03)
    M["face.jaw_width"] = lambda c: op_scale(c.P, hc, (1.15, 1, 1), jaw_m(c.P))
    M["face.jaw_height"] = lambda c: op_translate(c.P, (0, 0, -0.008), jaw_m(c.P))
    M["face.jaw_depth"] = lambda c: op_translate(c.P, (0, -0.008, 0), jaw_m(c.P))
    chin_m = lambda P: m_radial(P, L["chin"], 0.012, 0.035)
    M["face.chin_height"] = lambda c: op_translate(c.P, (0, 0, -0.008), chin_m(c.P))
    M["face.chin_width"] = lambda c: op_scale(c.P, L["chin"], (1.35, 1, 1), chin_m(c.P))
    M["face.chin_depth"] = lambda c: op_translate(c.P, (0, -0.008, 0), chin_m(c.P))
    cheek_m = lambda P, s: m_radial(P, L["cheek_" + s], 0.012, 0.045)
    M["face.cheek_width"] = both(lambda P, s: op_scale(P, np.array([0, L["cheek_" + s][1], L["cheek_" + s][2]]), (1.12, 1, 1), cheek_m(P, s)))
    M["face.cheek_height"] = both(lambda P, s: op_translate(P, (0, 0, 0.008), cheek_m(P, s)))
    M["face.cheek_depth"] = both(lambda P, s: op_translate(P, (0, -0.006, 0), cheek_m(P, s)))
    # ---- eyes (sockets; eyeball meshes get the same function -> engine may also drive eye bones)
    sock = lambda P, s: m_radial(P, L["eye_" + s], 1.2 * r, 2.3 * r)
    M["eye.size"] = both(lambda P, s: op_scale(P, L["eye_" + s], 1.2, sock(P, s)))
    M["eye.height"] = both(lambda P, s: op_translate(P, (0, 0, 0.006), sock(P, s)))
    M["eye.spacing"] = both(lambda P, s: op_translate(P, (0.005 * (1 if s == "L" else -1), 0, 0), sock(P, s)))
    M["eye.depth"] = both(lambda P, s: op_translate(P, (0, 0.005, 0), sock(P, s)))
    M["eye.angle"] = both(lambda P, s: op_rotate(P, L["eye_" + s], (0, 1, 0), math.radians(-12 if s == "L" else 12), sock(P, s)))
    M["eye.width"] = both(lambda P, s: op_scale(P, L["eye_" + s], (1.18, 1, 1), sock(P, s)))
    outer = lambda P, s: sock(P, s) * smoothstep(-0.2 * r, 0.5 * r, (P[:, 0] - L["eye_" + s][0]) * (1 if s == "L" else -1))
    inner = lambda P, s: sock(P, s) * smoothstep(-0.2 * r, 0.5 * r, (L["eye_" + s][0] - P[:, 0]) * (1 if s == "L" else -1))
    M["eye.outer_height"] = both(lambda P, s: op_translate(P, (0, 0, 0.006), outer(P, s)))
    M["eye.inner_height"] = both(lambda P, s: op_translate(P, (0, 0, 0.006), inner(P, s)))

    M["eye.lid_upper"] = both(lambda P, s, N=None: lid_rotation(P, L, s, math.radians(-16), 0, N))
    M["eye.lid_lower"] = both(lambda P, s, N=None: lid_rotation(P, L, s, 0, math.radians(-12), N))
    # ---- nose
    nose_m = lambda P: m_ellipsoid(P, L["nose_c"], (0.02, 0.02, 0.6 * (L["nose_root"][2] - L["nose_base"][2]) + 0.006), 0.5)
    M["nose.height"] = lambda c: op_translate(c.P, (0, 0, 0.006), nose_m(c.P))
    M["nose.depth"] = lambda c: op_translate(c.P, (0, -0.005, 0), nose_m(c.P))
    M["nose.size"] = lambda c: op_scale(c.P, L["nose_root"], 1.25, nose_m(c.P))
    tip_m = lambda P: m_radial(P, L["nose_tip"], 0.006, 0.018)
    M["nose.angle"] = lambda c: op_rotate(c.P, L["nose_root"], (1, 0, 0), math.radians(-14), nose_m(c.P))
    bridge_m = lambda P: m_radial(P, L["nose_root"], 0.006, 0.02)
    M["nose.bridge_height"] = lambda c: op_translate(c.P, (0, -0.004, 0), bridge_m(c.P))
    M["nose.bridge_width"] = lambda c: op_scale(c.P, L["nose_root"], (1.4, 1, 1), bridge_m(c.P))
    wing_m = lambda P: m_radial(P, L["nose_base"], 0.008, 0.02)
    M["nose.wing_width"] = lambda c: op_scale(c.P, L["nose_base"], (1.4, 1, 1), wing_m(c.P))
    M["nose.tip_height"] = lambda c: op_translate(c.P, (0, -0.002, 0.004), tip_m(c.P))
    # ---- mouth
    mouth_m = lambda P: m_ellipsoid(P, L["mouth_c"], (mw * 1.4, 0.022, 0.018), 0.5)
    M["mouth.height"] = lambda c: op_translate(c.P, (0, 0, 0.006), mouth_m(c.P))
    M["mouth.width"] = lambda c: op_scale(c.P, L["mouth_c"], (1.25, 1, 1), mouth_m(c.P))
    M["mouth.depth"] = lambda c: op_translate(c.P, (0, -0.005, 0), mouth_m(c.P))

    def lips(ctx, which):
        P = ctx.P; N = ctx.N
        m = m_ellipsoid(P, L["mouth_c"], (mw * 1.15, 0.02, 0.012), 0.5)
        dz = P[:, 2] - L["mouth_z"]
        if N is not None:
            nz = N[:, 2]
            near = 1.0 - smoothstep(0.002, 0.004, np.abs(dz))
            upper = np.where(near > 0.5, (nz < 0).astype(float), (dz > 0).astype(float))
        else:
            upper = (dz > 0).astype(float)
        return m * (upper if which == "upper" else 1.0 - upper)
    M["mouth.lip_upper"] = lambda c: op_translate(c.P, (0, -0.0025, -0.0015), lips(c, "upper"))
    M["mouth.lip_lower"] = lambda c: op_translate(c.P, (0, -0.0025, 0.0015), lips(c, "lower"))
    corner = lambda P, s: m_radial(P, L["mouth_corner_" + s], 0.005, 0.016)
    M["mouth.corner_height"] = both(lambda P, s: op_translate(P, (0, 0, 0.005), corner(P, s)))
    # ---- ears
    ear_m = lambda P, s: m_radial(P, L["ear_" + s], 0.02, 0.04) * smoothstep(L["head_side_x"] - 0.012, L["head_side_x"] - 0.002, np.abs(P[:, 0]))
    M["ear.size"] = both(lambda P, s: op_scale(P, np.array([L["head_side_x"] * (1 if s == "L" else -1), L["ear_" + s][1], L["ear_" + s][2]]), 1.3, ear_m(P, s)))
    M["ear.angle"] = both(lambda P, s: op_rotate(P, np.array([L["head_side_x"] * (1 if s == "L" else -1), L["ear_" + s][1] - 0.01, L["ear_" + s][2]]), (0, 0, 1), math.radians(-25 if s == "L" else 25), ear_m(P, s)))
    M["ear.upper"] = both(lambda P, s: op_translate(P, (0, 0, 0.006), ear_m(P, s) * smoothstep(-0.005, 0.01, P[:, 2] - L["ear_" + s][2])))
    M["ear.lower"] = both(lambda P, s: op_translate(P, (0, 0, -0.006), ear_m(P, s) * smoothstep(-0.005, 0.01, L["ear_" + s][2] - P[:, 2])))
    # ---- body
    bust_m = lambda P, s: m_radial(P, L["bust_base_" + s], 0.03, 0.10) * m_front(P, L["bust_base_" + s][1] + 0.03, 0.02)
    M["body.bust_size"] = both(lambda P, s: op_scale(P, L["bust_base_" + s] + np.array([0, 0.02, 0]), 1.35, bust_m(P, s)))
    M["body.bust_height"] = both(lambda P, s: op_translate(P, (0, 0, 0.02), bust_m(P, s)))
    M["body.bust_spacing"] = both(lambda P, s: op_translate(P, (0.015 * (1 if s == "L" else -1), 0, 0), bust_m(P, s)))
    M["body.bust_softness"] = both(lambda P, s: op_translate(P, (0.006 * (1 if s == "L" else -1), 0.004, -0.014), bust_m(P, s) * m_radial(P, L["bust_" + s], 0.02, 0.08)))
    spine = lambda z: np.array([0.0, L["spine_axis_y"], z])
    waist_m = lambda P: m_zband(P, L["pelvis_z"] + 0.03, L["chest_top_z"] - 0.06, 0.05, 0.05) * (1.0 - smoothstep(0.18, 0.24, np.hypot(P[:, 0], P[:, 1] - L["spine_axis_y"])))
    M["body.waist_width"] = lambda c: op_scale(c.P, spine(0), (1.12, 1, 1), waist_m(c.P))
    M["body.waist_depth"] = lambda c: op_scale(c.P, spine(0), (1, 1.12, 1), waist_m(c.P))
    M["body.belly"] = lambda c: op_translate(c.P, (0, -0.025, 0), m_radial(c.P, L["navel"], 0.04, 0.13) * m_front(c.P, L["navel"][1] + 0.06, 0.03))
    M["body.back"] = lambda c: op_translate(c.P, (0, 0.015, 0), m_zband(c.P, L["waist_z"], L["chest_top_z"] + 0.02, 0.05, 0.05) * m_back(c.P, L["spine_axis_y"] + 0.02, 0.04))
    torso_r = lambda P: 1.0 - smoothstep(0.20, 0.26, np.hypot(P[:, 0], P[:, 1] - L["spine_axis_y"]))
    hip_m = lambda P: m_zband(P, L["pelvis_z"] - 0.12, L["pelvis_z"] + 0.06, 0.05, 0.05) * torso_r(P)
    M["body.hip_width"] = lambda c: op_scale(c.P, spine(0), (1.12, 1, 1), hip_m(c.P))
    M["body.hip_depth"] = lambda c: op_scale(c.P, spine(0), (1, 1.12, 1), hip_m(c.P))
    M["body.butt_size"] = both(lambda P, s: op_translate(P, (0, 0.025, -0.005), m_radial(P, L["butt_" + s], 0.04, 0.13) * m_back(P, L["butt_" + s][1] - 0.08, 0.04) * torso_r(P)))

    def shoulder(P, s):
        sgn = 1 if s == "L" else -1
        m = smoothstep(0.03, abs(L["shoulder_" + s][0]) - 0.02, P[:, 0] * sgn) * m_above(P, L["chest_top_z"] - 0.20, 0.08)
        return op_translate(P, (0.02 * sgn, 0, 0), m)
    M["body.shoulder_width"] = both(shoulder)
    neck_m = lambda P: m_zband(P, L["clav_z"] + 0.01, L["chin_bottom"][2] - 0.01, 0.02, 0.012) * (1.0 - smoothstep(L["neck_r"] * 1.6, L["neck_r"] * 2.6, np.hypot(P[:, 0], P[:, 1] - L["neck_axis_y"])))
    M["body.neck_thickness"] = lambda c: op_axis_scale(c.P, np.array([0, L["neck_axis_y"], L["clav_z"]]), np.array([0, L["neck_axis_y"], L["chin_bottom"][2]]), 1.15, neck_m(c.P))
    for key, rr, s in (("upperarm", 0.08, 1.2), ("forearm", 0.06, 1.2), ("thigh", 0.12, 1.15), ("calf", 0.09, 1.2)):
        def limb(P, side, key=key, rr=rr, s=s):
            a, b = L[key + "_" + side]
            return op_axis_scale(P, a, b, s, m_segment(P, a, b, rr, rr * 1.6, (0.15, 0.15)))
        M["body.%s_thickness" % key] = both(limb)
    # ---- expressions
    # blink: the upper lid margin (~+55 deg on the sphere) swings down past the lower margin (~-45 deg)
    blink = lambda P, s, N=None: lid_rotation(P, L, s, math.radians(-92), math.radians(-14), N)
    M["exp.blink_L"] = lambda c: blink(c.P, "L", c.N)
    M["exp.blink_R"] = lambda c: blink(c.P, "R", c.N)
    M["exp.eye_wide"] = both(lambda P, s, N=None: lid_rotation(P, L, s, math.radians(12), math.radians(8), N))
    M["exp.eye_smile"] = both(lambda P, s, N=None: lid_rotation(P, L, s, math.radians(-8), math.radians(-42), N))
    M["exp.squint"] = both(lambda P, s, N=None: lid_rotation(P, L, s, math.radians(-30), math.radians(-24), N))
    brow_m = lambda P, s: m_radial(P, L["brow_" + s], 0.012, 0.035)
    M["exp.brow_up"] = both(lambda P, s: op_translate(P, (0, 0, 0.007), brow_m(P, s)))

    def brow_tilt(P, s, inner_dz, outer_dz):
        sgn = 1 if s == "L" else -1
        m = brow_m(P, s)
        t = smoothstep(-0.02, 0.02, (P[:, 0] - L["brow_" + s][0]) * sgn)  # 0 inner .. 1 outer
        delta = np.zeros_like(P); delta[:, 2] = (inner_dz * (1 - t) + outer_dz * t) * m
        return delta
    M["exp.brow_angry"] = both(lambda P, s: brow_tilt(P, s, -0.006, 0.002))
    M["exp.brow_sad"] = both(lambda P, s: brow_tilt(P, s, 0.006, -0.002))

    def jaw_open(ctx, amount):
        P = ctx.P
        lower = lips(ctx, "lower")
        chin = m_radial(P, L["chin"], 0.02, 0.05) * m_below(P, L["mouth_z"] - 0.004, 0.004)
        m = np.maximum(lower, chin * 0.9)
        # rotate lower face about the jaw hinge (below the ears)
        hinge = np.array([0.0, L["ear_L"][1], L["mouth_z"] - 0.01])
        return op_rotate(P, hinge, (1, 0, 0), -amount, m)

    def corners(ctx, dx, dz, dy=0.0):
        P = ctx.P
        out = np.zeros_like(P)
        for s, sgn in (("L", 1), ("R", -1)):
            out += op_translate(P, (dx * sgn, dy, dz), corner(P, s))
        return out
    M["exp.mouth_a"] = lambda c: jaw_open(c, math.radians(9)) + corners(c, -0.002, 0)
    M["exp.mouth_i"] = lambda c: jaw_open(c, math.radians(2)) + corners(c, 0.007, 0.002)
    M["exp.mouth_u"] = lambda c: jaw_open(c, math.radians(4)) + corners(c, -0.008, 0, -0.004) + op_translate(c.P, (0, -0.005, 0), mouth_m(c.P))
    M["exp.mouth_e"] = lambda c: jaw_open(c, math.radians(5)) + corners(c, 0.005, 0.001)
    M["exp.mouth_o"] = lambda c: jaw_open(c, math.radians(7)) + corners(c, -0.006, 0, -0.003)
    M["exp.smile"] = lambda c: corners(c, 0.004, 0.007) + op_translate(c.P, (0, -0.002, 0.003), m_radial(c.P, L["cheek_L"], 0.01, 0.04) + m_radial(c.P, L["cheek_R"], 0.01, 0.04))
    M["exp.frown"] = lambda c: corners(c, 0.0, -0.006)
    M["exp.mouth_open"] = lambda c: jaw_open(c, math.radians(13))
    return M


def evaluate_morphs(M, P, N=None, names=None):
    """Evaluate the morph table on point set P -> OrderedDict name -> delta."""
    ctx = Ctx(P, N)
    out = OrderedDict()
    for name, fn in M.items():
        if names is not None and name not in names:
            continue
        d = fn(ctx)
        out[name] = np.asarray(d, np.float64)
    return out
