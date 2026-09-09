"""Feature landmarks on the (MakeHuman-derived) body mesh, Blender space (m).

All landmarks are derived from the mesh itself plus the MakeHuman joint helper
groups (small cubes in base.obj whose centroids are the canonical joint
positions). Because the helper geometry is deformed together with the body,
the landmarks stay valid after the anime restyle.
"""
import numpy as np
from common import N_BODY, fit_sphere, vertex_normals, smoothstep, log


HELPER = {  # group name -> (start, end) vertex index ranges (inclusive) in base.obj
    "l-eye": (14598, 14669), "r-eye": (14670, 14741),
    "upper-teeth": (15060, 15127), "lower-teeth": (14992, 15059),
    "tongue": (13380, 13605), "hair": (18722, 19149), "tights": (15328, 18001), "skirt": (18002, 18721),
    "l-eyelashes-1": (14751, 14866), "l-eyelashes-2": (14742, 14854),
}


def joint_positions(V, groups):
    """groups: dict name -> sorted vertex index list (from base.obj 'joint-*' groups)."""
    return {g[6:]: V[idx].mean(0) for g, idx in groups.items() if g.startswith("joint-")}


def _front_surface_point(B, N, x, z, y_max, max_r=0.02):
    """Vertex nearest to (x, z) on the front-facing skin (normal pointing -Y)."""
    d = np.hypot(B[:, 0] - x, B[:, 2] - z)
    ok = (N[:, 1] < -0.2) & (B[:, 1] < y_max) & (d < max_r)
    if not ok.any():
        ok = (B[:, 1] < y_max) & (d < max_r * 2)
    cand = np.where(ok)[0]
    return B[cand[np.argmin(d[cand])]]


def compute(V_all, body_faces, groups, N=None, tris=None):
    """V_all: (N_BASE,3) Blender space. Returns dict of landmarks (np arrays / floats)."""
    B = V_all[:N_BODY]
    if N is None:
        N = vertex_normals(B, tris)
    J = joint_positions(V_all, groups)
    L = {"J": J}
    # --- eyes (from eye helper shells: near-perfect spheres)
    for side, key in (("L", "l-eye"), ("R", "r-eye")):
        a, b = HELPER[key]
        c, r = fit_sphere(V_all[a:b + 1])
        L["eye_" + side] = c; L["eye_r"] = r
    eye_z = float((L["eye_L"][2] + L["eye_R"][2]) / 2)
    eye_y = float((L["eye_L"][1] + L["eye_R"][1]) / 2)
    L["eye_z"] = eye_z
    # --- head extents
    neck_z = float(J["neck"][2])
    head_sel = B[:, 2] > neck_z + 0.02
    H = B[head_sel]
    L["head_c"] = H.mean(0)
    L["head_top"] = J["head-2"].copy()
    L["head_top"][2] = float(B[:, 2].max())
    L["head_back_y"] = float(H[:, 1].max())
    L["head_front_y"] = float(H[:, 1].min())
    L["neck_z"] = neck_z
    # half width at eye level
    band = H[np.abs(H[:, 2] - eye_z) < 0.01]
    L["head_half_width"] = float(band[:, 0].max())
    # --- lips: contact line = close vertex pairs with opposite vertical normals
    lf = np.where((B[:, 2] > neck_z + 0.03) & (B[:, 2] < eye_z - 0.02) & (np.abs(B[:, 0]) < 0.05) & (B[:, 1] < L["head_c"][1] - 0.02))[0]
    P = B[lf]; Nl = N[lf]
    up = lf[Nl[:, 2] > 0.6]; dn = lf[Nl[:, 2] < -0.6]
    # pairwise distance between up-normal verts and down-normal verts
    D = np.sqrt(((B[up][:, None, :] - B[dn][None, :, :]) ** 2).sum(-1))
    close = D < 0.0015
    lower_edge = up[close.any(1)]     # lower lip upper edge (normals up)
    upper_edge = dn[close.any(0)]     # upper lip lower edge (normals down)
    contact = np.concatenate([lower_edge, upper_edge])
    if len(contact) < 6:
        log("WARNING: lip contact line not found; falling back to teeth helpers")
        ut = V_all[HELPER["upper-teeth"][0]:HELPER["upper-teeth"][1] + 1]
        lt = V_all[HELPER["lower-teeth"][0]:HELPER["lower-teeth"][1] + 1]
        mz = (ut[:, 2].min() + lt[:, 2].max()) / 2
        sel = lf[np.abs(B[lf, 2] - mz) < 0.003]
        contact = sel
    C = B[contact]
    L["mouth_z"] = float(np.median(C[:, 2]))
    L["mouth_c"] = np.array([0.0, float(C[:, 1].min()), L["mouth_z"]])
    xmax = float(C[:, 0].max()); xmin = float(C[:, 0].min())
    L["mouth_half_width"] = float((xmax - xmin) / 2)
    L["mouth_corner_L"] = C[np.argmax(C[:, 0])].copy()
    L["mouth_corner_R"] = C[np.argmin(C[:, 0])].copy()
    L["lip_upper_idx"] = upper_edge; L["lip_lower_idx"] = lower_edge
    # --- sagittal profile landmarks (x ~ 0, front)
    mid = np.where((np.abs(B[:, 0]) < 0.004) & (B[:, 1] < L["head_c"][1]) & (B[:, 2] > neck_z))[0]
    Pm = B[mid]
    mz = L["mouth_z"]
    # nose tip: most forward between mouth+1.5cm and eye level
    sel = mid[(B[mid, 2] > mz + 0.015) & (B[mid, 2] < eye_z + 0.005)]
    L["nose_tip"] = B[sel[np.argmin(B[sel, 1])]].copy()
    tip_z = float(L["nose_tip"][2])
    # subnasale: most recessed between mouth+6mm and tip-3mm
    sel = mid[(B[mid, 2] > mz + 0.006) & (B[mid, 2] < tip_z - 0.003)]
    L["nose_base"] = B[sel[np.argmax(B[sel, 1])]].copy()
    # nasion: most recessed between tip+1.5cm and eye+2.5cm
    sel = mid[(B[mid, 2] > tip_z + 0.015) & (B[mid, 2] < eye_z + 0.025)]
    L["nose_root"] = B[sel[np.argmax(B[sel, 1])]].copy()
    L["nose_c"] = (L["nose_tip"] + L["nose_root"]) / 2
    # chin: most forward below the lower lip crease; chin bottom: lowest front point of the head
    sel = mid[(B[mid, 2] < mz - 0.012) & (B[mid, 2] > neck_z + 0.02)]
    L["chin"] = B[sel[np.argmin(B[sel, 1])]].copy()
    sel = mid[(B[mid, 2] < mz) & (B[mid, 1] < L["chin"][1] + 0.03)]
    L["chin_bottom"] = B[sel[np.argmin(B[sel, 2])]].copy()
    # nostril wings: most lateral points of the nose at base height
    sel = np.where((np.abs(B[:, 2] - L["nose_base"][2]) < 0.006) & (B[:, 1] < L["nose_base"][1] + 0.004) & (np.abs(B[:, 0]) < 0.03))[0]
    L["nose_wing_L"] = B[sel[np.argmax(B[sel, 0])]].copy(); L["nose_wing_R"] = B[sel[np.argmin(B[sel, 0])]].copy()
    # --- ears: most lateral vertices between nose base and eye level (+)
    band = np.where((B[:, 2] > L["nose_base"][2] - 0.01) & (B[:, 2] < eye_z + 0.025) & (B[:, 2] > neck_z))[0]
    for side, sgn in (("L", 1), ("R", -1)):
        xs = B[band, 0] * sgn
        xm = xs.max()
        ear = band[xs > xm - 0.015]
        L["ear_" + side] = B[ear].mean(0)
        L["ear_top_" + side] = B[ear[np.argmax(B[ear, 2])]].copy()
        L["ear_bottom_" + side] = B[ear[np.argmin(B[ear, 2])]].copy()
    L["ear_x"] = float(abs(L["ear_L"][0]))
    # side-of-head x at ear height excluding ears (approx: percentile)
    L["head_side_x"] = float(np.percentile(np.abs(B[band, 0]), 90))
    # --- jaw corners: most lateral at mouth height - 8 mm
    sel = np.where((np.abs(B[:, 2] - (mz - 0.008)) < 0.008) & (B[:, 2] > neck_z))[0]
    L["jaw_L"] = B[sel[np.argmax(B[sel, 0])]].copy(); L["jaw_R"] = B[sel[np.argmin(B[sel, 0])]].copy()
    # --- cheeks & brows (front surface points)
    cz = (eye_z + mz) / 2 - 0.004
    cx = L["mouth_half_width"] + 0.012
    for side, sgn in (("L", 1), ("R", -1)):
        L["cheek_" + side] = _front_surface_point(B, N, sgn * cx, cz, L["head_c"][1])
        L["brow_" + side] = _front_surface_point(B, N, sgn * abs(L["eye_L"][0]), eye_z + 1.35 * L["eye_r"], L["head_c"][1])
    # --- neck
    z0 = neck_z + 0.01; z1 = float(L["chin_bottom"][2]) - 0.005
    sel = np.where((B[:, 2] > z0) & (B[:, 2] < z1))[0]
    L["neck_axis_y"] = float(B[sel, 1].mean())
    L["neck_r"] = float(np.percentile(np.hypot(B[sel, 0], B[sel, 1] - L["neck_axis_y"]), 85))
    L["clav_z"] = float(J["l-clavicle"][2])
    L["shoulder_L"] = J["l-shoulder"]; L["shoulder_R"] = J["r-shoulder"]
    # --- torso
    zs1, zs2, zs3 = float(J["spine-1"][2]), float(J["spine-2"][2]), float(J["spine-3"][2])
    L["chest_top_z"] = zs1; L["waist_z"] = zs3; L["pelvis_z"] = float(J["pelvis"][2])
    for side, sgn in (("L", 1), ("R", -1)):
        sel = np.where((B[:, 2] > zs2 - 0.02) & (B[:, 2] < zs1) & (B[:, 0] * sgn > 0.04) & (B[:, 0] * sgn < 0.16))[0]
        nip = B[sel[np.argmin(B[sel, 1])]].copy()
        L["bust_" + side] = nip
        st = np.where((np.abs(B[:, 0]) < 0.01) & (np.abs(B[:, 2] - nip[2]) < 0.01))[0]
        L["bust_base_" + side] = np.array([nip[0], float(B[st, 1].min()) + 0.015, nip[2]])
    sel = np.where((np.abs(B[:, 0]) < 0.006) & (np.abs(B[:, 2] - zs3) < 0.02))[0]
    L["navel"] = B[sel[np.argmin(B[sel, 1])]].copy()
    sel = np.where((np.abs(B[:, 2] - L["pelvis_z"]) < 0.03) & (np.abs(B[:, 0]) < 0.25))[0]
    L["hip_half_width"] = float(np.abs(B[sel, 0]).max())
    for side, sgn in (("L", 1), ("R", -1)):
        sel = np.where((B[:, 2] > L["pelvis_z"] - 0.10) & (B[:, 2] < L["pelvis_z"] + 0.02) & (B[:, 0] * sgn > 0.03) & (B[:, 0] * sgn < 0.15))[0]
        L["butt_" + side] = B[sel[np.argmax(B[sel, 1])]].copy()
    L["spine_axis_y"] = float(J["spine-2"][1])
    # --- limbs (joint chains)
    for side, s in (("L", "l"), ("R", "r")):
        L["upperarm_" + side] = (J[s + "-shoulder"], J[s + "-elbow"])
        L["forearm_" + side] = (J[s + "-elbow"], J[s + "-hand"])
        L["thigh_" + side] = (J[s + "-upper-leg"], J[s + "-knee"])
        L["calf_" + side] = (J[s + "-knee"], J[s + "-ankle"])
        L["wrist_" + side] = J[s + "-hand"]; L["ankle_" + side] = J[s + "-ankle"]
    L["hip_z"] = float(J["l-upper-leg"][2])
    L["ground_z"] = float(B[:, 2].min())
    return L


def describe(L):
    keys = ["eye_L", "eye_r", "nose_tip", "nose_root", "nose_base", "mouth_c", "mouth_half_width", "chin", "chin_bottom",
            "ear_L", "cheek_L", "brow_L", "head_top", "head_half_width", "neck_r", "bust_L", "navel", "hip_half_width", "butt_L"]
    for k in keys:
        v = L[k]
        log("  landmark %-16s %s" % (k, np.round(v, 4) if isinstance(v, np.ndarray) else round(float(v), 4)))
