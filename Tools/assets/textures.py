"""Procedural textures -> Assets/Textures/ (plain python3 with numpy + Pillow).

    python3 textures.py            # everything for which inputs exist
    python3 textures.py --sex f    # only skin/face maps for one body

Skin/face maps need Tools/assets/out/body_<sex>.npz written by build_body.py.
Colours meant to be tinted at runtime are stored near white (see ASSET_SPEC).
"""
import sys, os, json, math, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from common import *
import deform as DF

TEX = A_TEX
MH_SYS = os.path.join(MH, "system")


def save_rgba(path, rgb, alpha=None, srgb=True):
    rgb = np.clip(rgb, 0, 1)
    if rgb.ndim == 2:
        rgb = np.repeat(rgb[:, :, None], 3, 2)
    if alpha is None:
        im = Image.fromarray((rgb * 255 + 0.5).astype(np.uint8), "RGB")
    else:
        a = np.clip(alpha, 0, 1)
        im = Image.fromarray(np.dstack([(rgb * 255 + 0.5).astype(np.uint8), (a * 255 + 0.5).astype(np.uint8)]), "RGBA")
    im.save(path, optimize=True)
    log("wrote %s %s" % (os.path.relpath(path, REPO), im.size))
    return path


def grid(size):
    y, x = np.mgrid[0:size, 0:size]
    u = (x + 0.5) / size; v = 1.0 - (y + 0.5) / size
    return u, v


def blur(arr, radius):
    if radius <= 0:
        return arr
    im = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(im).astype(np.float32) / 255.0


# --------------------------------------------------------------------------
# body-derived maps
# --------------------------------------------------------------------------
class BodyData:
    def __init__(self, sex):
        p = os.path.join(OUT, "body_%s.npz" % sex)
        d = np.load(p, allow_pickle=False)
        self.sex = sex
        self.V = d["V"].astype(np.float64); self.N = d["normals"].astype(np.float64)
        self.tris = d["tris"]; self.uv_loops = d["uv_loops"].astype(np.float64)
        faces_len = d["faces_len"]; faces_flat = d["faces_flat"]
        self.ao = d["ao"].astype(np.float64); self.conc = d["concavity"].astype(np.float64)
        self.regions = d["regions"]
        self.L = {k: (np.asarray(v) if isinstance(v, list) else v) for k, v in json.loads(str(d["landmarks"])).items()}
        self.J = {k: np.asarray(v) for k, v in json.loads(str(d["joints"])).items()}
        # triangle corner -> loop index (same fan order as common.triangulate)
        tl = []; start = 0
        for n in faces_len:
            for i in range(1, n - 1):
                tl.append((start, start + i, start + i + 1))
            start += n
        self.tri_loops = np.asarray(tl, np.int64)
        assert len(self.tri_loops) == len(self.tris)
        self.uv_tris = self.uv_loops[self.tri_loops]
        # one representative uv per vertex
        self.vert_uv = np.zeros((len(self.V), 2))
        self.vert_uv[self.tris.ravel()] = self.uv_tris.reshape(-1, 2)
        # local uv scale (uv units per metre) per vertex from triangle edges
        e3 = np.linalg.norm(self.V[self.tris[:, 1]] - self.V[self.tris[:, 0]], axis=1)
        e2 = np.linalg.norm(self.uv_tris[:, 1] - self.uv_tris[:, 0], axis=1)
        ratio = e2 / np.maximum(e3, 1e-9)
        self.vert_uvscale = np.zeros(len(self.V)); cnt = np.zeros(len(self.V))
        for k in range(3):
            np.add.at(self.vert_uvscale, self.tris[:, k], ratio); np.add.at(cnt, self.tris[:, k], 1)
        self.vert_uvscale /= np.maximum(cnt, 1)

    def raster(self, vals, size, pad=6):
        vals = np.asarray(vals, np.float64)
        vt = vals[self.tris] if vals.ndim == 1 else vals[self.tris]
        return raster_field(self.uv_tris, vt, size, pad)

    def nearest_vertex(self, p, front=None):
        d = np.linalg.norm(self.V - np.asarray(p), axis=1)
        if front is not None:
            d = d + (self.N[:, 1] > -0.1) * 1.0
        return int(np.argmin(d))

    def uv_of(self, p, front=True):
        return self.vert_uv[self.nearest_vertex(p, front)]


def skin_maps(bd, size=2048):
    V, N, L = bd.V, bd.N, bd.L
    ao = bd.ao
    # soft baked shading: AO + concavity + gentle top-light
    shade = 0.82 + 0.18 * np.clip(ao, 0, 1) ** 0.8
    shade -= np.clip(bd.conc, 0, 0.004) / 0.004 * 0.10          # creases darker
    shade += np.clip(-bd.conc, 0, 0.004) / 0.004 * 0.02          # ridges a touch lighter
    # warm (pink) zones stored as slight tint toward (1, .88, .86)
    pink = np.zeros(len(V))
    for key, r in (("cheek_L", 0.05), ("cheek_R", 0.05), ("nose_tip", 0.015)):
        pink = np.maximum(pink, DF.m_radial(V, L[key], r * 0.3, r) * 0.5)
    for s in ("L", "R"):
        pink = np.maximum(pink, DF.m_radial(V, bd.J[("l" if s == "L" else "r") + "-knee"], 0.03, 0.08) * 0.35)
        pink = np.maximum(pink, DF.m_radial(V, bd.J[("l" if s == "L" else "r") + "-elbow"], 0.025, 0.06) * 0.3)
        pink = np.maximum(pink, DF.m_radial(V, L["ear_" + s], 0.015, 0.035) * 0.3)
        for fi in (2, 3, 4, 5):
            pink = np.maximum(pink, DF.m_radial(V, bd.J["%s-finger-%d-4" % ("l" if s == "L" else "r", fi)], 0.006, 0.016) * 0.35)
    lips = DF.m_ellipsoid(V, L["mouth_c"], (L["mouth_half_width"] * 1.05, 0.02, 0.0085), 0.3) * (N[:, 1] < -0.2)
    pink = np.maximum(pink, lips * 0.35)
    navel = DF.m_radial(V, L["navel"], 0.004, 0.011)
    shade -= navel * 0.25
    # knees/collarbone subtle definition
    for s in ("l", "r"):
        shade -= DF.m_radial(V, bd.J[s + "-knee"] + np.array([0, -0.03, 0]), 0.0, 0.045) * 0.04
    rgb = np.stack([shade, shade * (1 - 0.10 * pink), shade * (1 - 0.13 * pink)], 1)
    img, cov = bd.raster(rgb, size)
    img = np.clip(img, 0, 1)
    bg = np.array([0.92, 0.86, 0.84])
    img[~cov] = bg
    # very slight blur to hide the per-vertex facets
    out = np.stack([blur(img[:, :, c], 1.5) for c in range(3)], 2)
    save_rgba(os.path.join(TEX, "skin_%s_base.png" % bd.sex), out)
    # ---- detail: R spec, G shading detail, B line mask
    spec = np.full(len(V), 0.45)
    head = V[:, 2] > L["neck_z"] + 0.03
    spec[head] = 0.7
    spec += lips * 0.3
    spec += DF.m_radial(V, L["nose_tip"], 0.008, 0.02) * 0.2
    for s in ("L", "R"):
        spec += DF.m_radial(V, L["shoulder_" + s], 0.03, 0.09) * 0.2
        spec += DF.m_radial(V, L["bust_" + s], 0.03, 0.09) * 0.15
    spec = np.clip(spec, 0, 1)
    detail_g = np.clip(1.0 - 0.45 * (1 - ao) - np.clip(bd.conc, 0, 0.004) / 0.004 * 0.35 - navel * 0.5, 0, 1)
    img, cov = bd.raster(np.stack([spec, detail_g], 1), size)
    img[~cov] = (0.45, 1.0)
    lines = line_mask(bd, size)
    det = np.dstack([img[:, :, 0], img[:, :, 1], lines])
    save_rgba(os.path.join(TEX, "skin_%s_detail.png" % bd.sex), det)


def _smooth_pts(pts, passes=3, jump=0.06):
    pts = [np.asarray(p, np.float64) for p in pts]
    for _ in range(passes):
        out = [pts[0]]
        for i in range(1, len(pts) - 1):
            a, b, c = pts[i - 1], pts[i], pts[i + 1]
            if np.abs(a - b).sum() > jump or np.abs(c - b).sum() > jump:
                out.append(b)
            else:
                out.append(0.25 * a + 0.5 * b + 0.25 * c)
        out.append(pts[-1]); pts = out
    return pts


def _stroke(draw, pts, size, width, jump=0.06, scale=2):
    """Anti-aliased polyline in UV space; broken where the UV jumps (seams)."""
    seg = []
    pts = _smooth_pts(pts, jump=jump)
    for p in pts:
        if seg and abs(p[0] - seg[-1][0]) + abs(p[1] - seg[-1][1]) > jump:
            if len(seg) > 1:
                draw.line([(x * size * scale, (1 - y) * size * scale) for x, y in seg], fill=255, width=width * scale, joint="curve")
            seg = []
        seg.append(p)
    if len(seg) > 1:
        draw.line([(x * size * scale, (1 - y) * size * scale) for x, y in seg], fill=255, width=width * scale, joint="curve")


def line_mask(bd, size):
    V, N, L, J = bd.V, bd.N, bd.L, bd.J
    scale = 2
    im = Image.new("L", (size * scale, size * scale), 0); draw = ImageDraw.Draw(im)
    front = N[:, 1] < -0.25
    for s, js in (("L", "l"), ("R", "r")):
        # collarbone: skin above the clavicle -> shoulder segment
        a, b = J[js + "-clavicle"], J[js + "-shoulder"]
        pts = []
        for t in np.linspace(0.12, 0.9, 14):
            p = a + (b - a) * t + np.array([0, -0.02, 0.012])
            d = np.linalg.norm(V - p, axis=1) + (~front) * 1.0
            pts.append(bd.vert_uv[int(np.argmin(d))])
        _stroke(draw, pts, size, 3)
        # under-bust crease
        nip = L["bust_" + s]
        sel = np.where(front & (np.abs(V[:, 0] - nip[0]) < 0.045) & (V[:, 2] < nip[2] - 0.004) & (V[:, 2] > nip[2] - 0.075) & (N[:, 2] < -0.45))[0]
        if len(sel) > 3:
            order = sel[np.argsort(V[sel, 0])]
            _stroke(draw, [bd.vert_uv[i] for i in order], size, 3)
        # ankle bone: short arc around the malleolus
        ank = J[js + "-ankle"]
        sel = np.where((np.abs(V[:, 2] - ank[2]) < 0.02) & (np.abs(V[:, 0] - ank[0]) < 0.06))[0]
        lat = sel[np.argmax(np.abs(V[sel, 0]))]
        uv = bd.vert_uv[lat]; r = 0.012 * bd.vert_uvscale[lat]
        cx, cy = uv[0] * size * scale, (1 - uv[1]) * size * scale
        draw.arc([cx - r * size * scale, cy - r * size * scale, cx + r * size * scale, cy + r * size * scale], 200, 340, fill=255, width=2 * scale)
    im = im.resize((size, size), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.6))
    return np.asarray(im).astype(np.float32) / 255.0


def face_overlays(bd, size=1024):
    V, N, L = bd.V, bd.N, bd.L
    # blush: soft ellipses on the cheeks
    a = np.zeros(len(V))
    for s in ("L", "R"):
        a = np.maximum(a, DF.m_radial(V, L["cheek_" + s] + np.array([0, 0, 0.004]), 0.008, 0.038) * (N[:, 1] < -0.15))
    img, cov = bd.raster(a, size); img[~cov] = 0
    save_rgba(os.path.join(TEX, "face_overlay_blush.png"), np.ones((size, size)), blur(img[:, :, 0], 6))
    # eyeshadow: upper lid region
    a = np.zeros(len(V))
    for s in ("L", "R"):
        up, lo, d = DF._lid_masks(V, L, s, N)
        c = L["eye_" + s]; r = L["eye_r"]
        a = np.maximum(a, up * (1 - DF.smoothstep(1.4 * r, 1.9 * r, d)) * DF.smoothstep(0.0, 0.25 * r, V[:, 2] - c[2]))
    img, cov = bd.raster(a, size); img[~cov] = 0
    save_rgba(os.path.join(TEX, "face_overlay_eyeshadow.png"), np.ones((size, size)), blur(np.clip(img[:, :, 0] * 1.3, 0, 1), 3))
    # lips
    lips = DF.m_ellipsoid(V, L["mouth_c"], (L["mouth_half_width"] * 1.02, 0.02, 0.0085), 0.25) * (N[:, 1] < -0.2)
    img, cov = bd.raster(lips, size); img[~cov] = 0
    save_rgba(os.path.join(TEX, "face_overlay_lip.png"), np.ones((size, size)), blur(np.clip(img[:, :, 0] * 1.4, 0, 1), 1.5))


# --------------------------------------------------------------------------
# eyes
# --------------------------------------------------------------------------
def iris_texture(variant, size=512):
    u, v = grid(size)
    x = (u - 0.5) * 2; y = (v - 0.5) * 2         # -1..1, y up
    R = 0.76                                     # iris radius as fraction of eyeball UV half-width (catalog irisRadius = R/2)
    sx = {0: 1.0, 1: 0.88, 2: 1.0}[variant]
    r = np.hypot(x / (R * sx), y / R)
    ang = np.arctan2(y, x)
    alpha = 1.0 - DF.smoothstep(0.985, 1.0, r)
    lum = np.full_like(r, 0.97)
    # dark rim
    lum *= 1.0 - 0.62 * DF.smoothstep(0.80 if variant != 2 else 0.86, 0.985, r)
    # vertical gradient: top darker (lid shadow), bottom brighter
    lum *= 1.0 - 0.42 * DF.smoothstep(-0.15, 0.85, y / R)
    # lower rim highlight crescent
    cres = (1 - DF.smoothstep(0.62, 0.90, r)) * DF.smoothstep(0.40, 0.62, r) * DF.smoothstep(-0.95, -0.35, -y / R)
    lum = lum + cres * 0.28
    # radial streaks
    if variant != 2:
        streak = 0.5 + 0.5 * np.sin(ang * (28 if variant == 0 else 20) + 0.7 * np.sin(ang * 5))
        lum *= 1.0 - 0.10 * streak * DF.smoothstep(0.35, 0.6, r) * (1 - DF.smoothstep(0.85, 1.0, r))
    # pupil
    pr = {0: 0.34, 1: 0.44, 2: 0.30}[variant]
    pupil = 1.0 - DF.smoothstep(pr - 0.02, pr + 0.02, np.hypot(x / (R * sx * 0.9), y / R))
    lum = lum * (1 - pupil) + 0.04 * pupil
    rgb = np.stack([lum, lum * 0.985, lum * 0.97], 2)
    save_rgba(os.path.join(TEX, "eye_iris_%d.png" % variant), rgb, alpha)


def highlight_texture(variant, size=512):
    u, v = grid(size)
    def ell(cx, cy, rx, ry, soft=0.006):
        return 1.0 - DF.smoothstep(1.0 - soft * 8, 1.0, np.hypot((u - cx) / rx, (v - cy) / ry))
    if variant == 0:
        a = np.maximum(ell(0.37, 0.65, 0.11, 0.075), ell(0.66, 0.36, 0.045, 0.04))
    elif variant == 1:
        a = np.maximum(np.maximum(ell(0.36, 0.66, 0.07, 0.06), ell(0.63, 0.38, 0.04, 0.035)), ell(0.55, 0.72, 0.035, 0.03))
        # sparkle
        for dx, dy in ((0.06, 0), (-0.06, 0), (0, 0.06), (0, -0.06)):
            a = np.maximum(a, ell(0.36 + dx * 0.5, 0.66 + dy * 0.5, 0.012, 0.012) * 0.9)
    else:
        a = np.maximum(ell(0.5, 0.68, 0.16, 0.05), ell(0.64, 0.35, 0.03, 0.03))
    save_rgba(os.path.join(TEX, "eye_highlight_%d.png" % variant), np.ones((size, size)), a)


def eye_white(size=512):
    u, v = grid(size)
    lum = 1.0 - 0.34 * DF.smoothstep(0.55, 0.97, v)
    lum *= 1.0 - 0.12 * DF.smoothstep(0.30, 0.50, np.abs(u - 0.5))
    rgb = np.stack([lum, lum, lum * 1.0], 2)
    save_rgba(os.path.join(TEX, "eye_white.png"), rgb)


def _proxy_strips(rel, sex="f"):
    """Refit MakeHuman proxy (Blender space): (V, per-vertex uv, component id, n, tris, landmarks)."""
    d = np.load(os.path.join(OUT, "body_%s.npz" % sex)); Vmh = d["Vmh_all"].astype(np.float64); ground = float(d["ground"])
    p = load_mhclo(os.path.join(MH, rel)); V = mh_to_bl(fit_proxy(p, Vmh), ground); m = p.mesh
    vuv = np.zeros((len(V), 2))
    for fi, f in enumerate(m["faces"]):
        for k, vi in enumerate(f):
            ti = m["fuv"][fi][k]; vuv[vi] = m["vt"][ti] if ti >= 0 else (0, 0)
    comp, n = connected_components(m["faces"], len(V))
    L = {k: (np.asarray(v) if isinstance(v, list) else v) for k, v in json.loads(str(d["landmarks"])).items()}
    return V, vuv, comp, n, triangulate(m["faces"]), L


def _strip_frame(V, vuv, comp, n, tris, size, t_of):
    """Rasterise every strip component into (s, t) fields: s = 0 at the inner corner (|x| min)
    -> 1 outer, t = 0 root -> 1 tip (t_of(P, cid) gives per-vertex t). Also returns per-component
    strip length / height in metres so strokes can be drawn in real units."""
    s = np.zeros(len(V)); t = np.zeros(len(V)); Ls = np.zeros(len(V)); Hs = np.zeros(len(V))
    for c in range(n):
        sel = np.where(comp == c)[0]; P = V[sel]
        ax = np.abs(P[:, 0]); s[sel] = (ax - ax.min()) / max(ax.max() - ax.min(), 1e-6)
        tt, h = t_of(P, c); t[sel] = tt
        Ls[sel] = ax.max() - ax.min(); Hs[sel] = h
    img, cov = raster_field(vuv[tris], np.stack([s, t, Ls, Hs], 1)[tris], size, pad=2)
    return img[:, :, 0], img[:, :, 1], img[:, :, 2], img[:, :, 3], cov


def _stroke_alpha(X, Y, a, b, w0, w1, soft=0.00025):
    """Tapered stroke from a to b (metres; components may be per-pixel arrays) on the (X, Y) metre grids."""
    ab0 = b[0] - a[0]; ab1 = b[1] - a[1]; L2 = np.maximum(ab0 * ab0 + ab1 * ab1, 1e-12)
    u = np.clip(((X - a[0]) * ab0 + (Y - a[1]) * ab1) / L2, 0, 1)
    dist = np.hypot(X - a[0] - u * ab0, Y - a[1] - u * ab1)
    w = w0 + (w1 - w0) * u
    return 1.0 - DF.smoothstep(w - soft, w + soft, dist)


def eyelash_textures(size=1024):
    """Anime lashes painted in the eyelash strip's UV space: upper strip = thin dark line
    thickening toward the outer corner + 6-8 short lashes there; lower strip = faint line
    with a few tiny lashes near the outer corner. Variant 1 is finer."""
    V, vuv, comp, n, tris, L = _proxy_strips("system/eyelashes/eyelashes01/eyelashes01.mhclo")
    eye = {"L": L["eye_L"], "R": L["eye_R"]}
    upper = {}

    def t_of(P, c):
        cen = eye["L"] if P[:, 0].mean() > 0 else eye["R"]
        d = np.linalg.norm(P - cen, axis=1)
        d0, d1 = np.percentile(d, 12), np.percentile(d, 88)
        upper[c] = P[:, 2].mean() > cen[2] - 0.002
        return np.clip((d - d0) / max(d1 - d0, 1e-6), 0, 1), max(d1 - d0, 1e-6)
    S, T, Ls, Hs, cov = _strip_frame(V, vuv, comp, n, tris, size, t_of)
    # which pixels belong to an upper strip: rasterise the flag
    flag = np.array([1.0 if upper[comp[i]] else 0.0 for i in range(len(V))])
    fimg, _ = raster_field(vuv[tris], flag[tris], size, pad=2)
    is_up = fimg[:, :, 0] > 0.5
    X = S * Ls; Y = T * Hs            # metres along / across the strip
    lum = np.full((size, size), 0.96)
    for variant in (0, 1):
        k_fine = 0.65 if variant else 1.0
        # upper: liner thickening toward the outer corner
        th = (0.0009 + 0.0026 * DF.smoothstep(0.2, 1.0, S)) * k_fine
        liner = (1.0 - DF.smoothstep(th - 0.00025, th + 0.00025, Y)) * DF.smoothstep(0.0, 0.06, S) * (1.0 - DF.smoothstep(0.985, 1.0, S))
        a_up = liner
        n_l = 6 if variant else 8
        for k in range(n_l):
            f = k / max(n_l - 1, 1)
            s_k = 0.56 + 0.40 * f
            ln = (0.0032 + 0.0026 * f) * (0.8 if variant else 1.0)
            lean = 0.25 + 0.35 * f
            a = (s_k * Ls, 0.0); b = (s_k * Ls + ln * lean, ln)
            a_up = np.maximum(a_up, _stroke_alpha(X, Y, a, b, 0.00075 * k_fine, 0.00012))
        # lower: faint line + 3 tiny lashes at the outer corner
        th_lo = 0.00035 * k_fine
        a_lo = (1.0 - DF.smoothstep(th_lo - 0.0002, th_lo + 0.0002, Y)) * DF.smoothstep(0.2, 0.5, S) * (1.0 - DF.smoothstep(0.96, 1.0, S)) * 0.55
        for k in range(3):
            s_k = 0.70 + 0.11 * k; ln = (0.0016 + 0.0004 * k) * (0.8 if variant else 1.0)
            a_lo = np.maximum(a_lo, 0.75 * _stroke_alpha(X, Y, (s_k * Ls, 0.0), (s_k * Ls + ln * 0.4, ln), 0.0004 * k_fine, 0.0001))
        alpha = np.where(is_up, a_up, a_lo) * cov
        save_rgba(os.path.join(TEX, "eyelash_%d.png" % variant), lum, alpha)


def eyebrow_textures(size=1024):
    """Clean tapered anime brow painted in the eyebrow strip's UV space (thick blunt inner end,
    slight arch, thin tail). Variant 1 is thinner and straighter."""
    V, vuv, comp, n, tris, L = _proxy_strips("system/eyebrows/eyebrow001/eyebrow001.mhclo")
    # The MakeHuman brow strip is an irregular multi-row band: derive the frame from its rasterised
    # outline instead of the mesh rows. s: along u (0 at the inner end, from the 3D |x| direction),
    # t: per texture column, 0 at the strip's lower edge -> 1 at its upper edge.
    cid = np.zeros(len(V)); sgn = np.zeros(len(V))
    for c in range(n):
        ids = np.where(comp == c)[0]
        cid[ids] = c + 1
        sgn[ids] = 1.0 if np.corrcoef(vuv[ids, 0], np.abs(V[ids, 0]))[0, 1] > 0 else -1.0
    img, cov = raster_field(vuv[tris], np.stack([cid, sgn], 1)[tris], size, pad=1)
    cimg = np.rint(img[:, :, 0]).astype(int) * cov; simg = img[:, :, 1]
    S = np.zeros((size, size)); T = np.zeros((size, size))
    for c in range(1, n + 1):
        m = cimg == c
        cols = np.where(m.any(0))[0]
        u0, u1 = cols.min(), cols.max()
        rows_idx = np.arange(size)[:, None]
        top = np.where(m, rows_idx, size).min(0); bot = np.where(m, rows_idx, -1).max(0)   # row 0 = top of the image
        T = np.where(m, (bot[None, :] - rows_idx) / np.maximum(bot - top, 1)[None, :], T)
        su = (np.arange(size)[None, :] - u0) / max(u1 - u0, 1)
        S = np.where(m, np.where(simg > 0, su, 1.0 - su), S)
    cov = cimg > 0
    lum = np.full((size, size), 0.96)
    for variant in (0, 1):
        thin = 0.6 if variant else 1.0
        centre = 0.5 + (0.03 if variant else 0.06) * np.sin(math.pi * S) - 0.08 * DF.smoothstep(0.7, 1.0, S)
        w = 0.30 * thin * (1.0 - 0.72 * DF.smoothstep(0.35, 1.0, S)) * DF.smoothstep(0.0, 0.10, S) ** 0.5
        alpha = (1.0 - DF.smoothstep(w - 0.05, w + 0.05, np.abs(T - centre))) * DF.smoothstep(0.0, 0.04, S) * (1.0 - DF.smoothstep(0.94, 1.0, S)) * cov
        save_rgba(os.path.join(TEX, "eyebrow_%d.png" % variant), lum, alpha)


# --------------------------------------------------------------------------
# hair / cloth
# --------------------------------------------------------------------------
def hair_strand(size=512):
    u, v = grid(size)
    rng = np.random.default_rng(3)
    streak = np.zeros((size, size))
    for k in range(60):
        cu = rng.random(); w = 0.004 + rng.random() * 0.01; amp = rng.random()
        streak += amp * np.exp(-((u - cu) / w) ** 2)
    streak /= streak.max()
    lum = 0.90 + 0.10 * streak
    alpha = (1 - DF.smoothstep(0.90, 0.995, v)) * DF.smoothstep(0.0, 0.05, u) * DF.smoothstep(0.0, 0.05, 1 - u)
    save_rgba(os.path.join(TEX, "hair_strand.png"), lum, alpha)


def hair_mh_textures():
    """Reused CC0 MakeHuman hair diffuse maps -> near-white luminance + alpha (1024²)."""
    out = {}
    for d in sorted(os.listdir(os.path.join(MH_SYS, "hair"))):
        pngs = [f for f in os.listdir(os.path.join(MH_SYS, "hair", d)) if f.endswith("_diffuse.png")]
        if not pngs:
            continue
        im = Image.open(os.path.join(MH_SYS, "hair", d, pngs[0])).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
        a = np.asarray(im).astype(np.float32) / 255
        lum = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
        cov = a[:, :, 3] > 0.5
        m = lum[cov].mean() if cov.any() else 0.5
        lum = np.clip(0.72 + 0.28 * (lum / max(m, 0.05)) * 0.9, 0, 1)
        p = os.path.join(OUT, "tex"); os.makedirs(p, exist_ok=True)
        out[d] = save_rgba(os.path.join(p, "hair_mh_%s.png" % d), lum, a[:, :, 3])
    return out


def patterns(size=512):
    u, v = grid(size)
    def tile_save(name, a):
        save_rgba(os.path.join(TEX, "pattern_%s.png" % name), np.ones((size, size)), a)
    tile_save("plain", np.ones((size, size)))
    stripes = DF.smoothstep(0.45, 0.5, (u * 8) % 1.0) * (1 - DF.smoothstep(0.95, 1.0, (u * 8) % 1.0))
    tile_save("stripes", stripes)
    gu = (u * 4) % 1.0; gv = (v * 4) % 1.0
    band = lambda t: DF.smoothstep(0.30, 0.34, t) * (1 - DF.smoothstep(0.66, 0.70, t))
    thin = lambda t: DF.smoothstep(0.47, 0.49, t) * (1 - DF.smoothstep(0.51, 0.53, t))
    plaid = np.clip(0.55 * band(gu) + 0.55 * band(gv) + 0.5 * thin(gu) + 0.5 * thin(gv), 0, 1)
    tile_save("plaid", plaid)
    cx = (u * 6) % 1.0 - 0.5; cy = (v * 6) % 1.0 - 0.5
    dots = 1 - DF.smoothstep(0.22, 0.26, np.hypot(cx, cy))
    cx2 = (u * 6 + 0.5) % 1.0 - 0.5; cy2 = (v * 6 + 0.5) % 1.0 - 0.5
    dots = np.maximum(dots, 1 - DF.smoothstep(0.22, 0.26, np.hypot(cx2, cy2)))
    tile_save("dots", dots)
    # lace: rings + scallops
    r1 = np.hypot((u * 5) % 1.0 - 0.5, (v * 5) % 1.0 - 0.5)
    ring = (1 - DF.smoothstep(0.30, 0.33, r1)) * DF.smoothstep(0.22, 0.25, r1)
    r2 = np.hypot((u * 5 + 0.5) % 1.0 - 0.5, (v * 5 + 0.5) % 1.0 - 0.5)
    ring2 = (1 - DF.smoothstep(0.18, 0.21, r2)) * DF.smoothstep(0.10, 0.13, r2)
    web = np.maximum(thin((u * 10) % 1.0), thin((v * 10) % 1.0)) * 0.6
    lace = np.clip(ring + ring2 + web, 0, 1)
    tile_save("lace", lace)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sex", default=None)
    args = ap.parse_args()
    sexes = [args.sex] if args.sex else [s for s in ("f", "m") if os.path.exists(os.path.join(OUT, "body_%s.npz" % s))]
    for sex in sexes:
        bd = BodyData(sex)
        log("skin maps for body_%s (%d verts)" % (sex, len(bd.V)))
        skin_maps(bd)
        if sex == "f":
            face_overlays(bd)
    if args.sex is None:
        for i in range(3):
            iris_texture(i); highlight_texture(i)
        eye_white(); eyelash_textures(); eyebrow_textures(); hair_strand(); hair_mh_textures(); patterns()


if __name__ == "__main__":
    main()
