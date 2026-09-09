"""Skeleton construction, skin weights and body regions.

Joint positions come from the MakeHuman joint-helper cubes (deformed together
with the mesh, so they follow the restyle); eye and bust bones come from the
landmarks. Weights: Blender bone-heat (ARMATURE_AUTO) with a numpy fallback.
"""
from collections import OrderedDict
import numpy as np
from common import log, smoothstep, N_BODY, build_adjacency, nearest_points

REGIONS = OrderedDict([("torso_upper", 1), ("torso_lower", 2), ("upperarm_L", 3), ("upperarm_R", 4), ("forearm_L", 5), ("forearm_R", 6),
                       ("hand_L", 7), ("hand_R", 8), ("thigh_L", 9), ("thigh_R", 10), ("calf_L", 11), ("calf_R", 12), ("foot_L", 13), ("foot_R", 14)])


def bone_region(bone):
    if bone in ("hips", "spine01") or bone.startswith("thigh") and False:
        return "torso_lower"
    if bone in ("spine02", "spine03") or bone.startswith(("shoulder", "bust")):
        return "torso_upper"          # the neck stays region 0 (never hidden by a garment slot)
    for key in ("upperarm", "forearm", "thigh", "calf"):
        if bone.startswith(key):
            return key + "_" + bone[-1]
    if bone.startswith(("hand", "thumb", "index", "middle", "ring", "pinky")):
        return "hand_" + bone[-1]
    if bone.startswith(("foot", "toes")):
        return "foot_" + bone[-1]
    return None  # head, eyes, root -> 0 (never hidden)


def bone_table(J, L):
    """Bone definitions in Blender space. J: joint dict (MakeHuman names), L: landmarks."""
    B = []

    def add(name, head, tail, parent, deform=True):
        B.append(dict(name=name, head=np.asarray(head, np.float64).tolist(), tail=np.asarray(tail, np.float64).tolist(), parent=parent, deform=deform))

    add("root", (0, 0, 0), (0, -0.15, 0), None, deform=False)
    add("hips", J["pelvis"], J["spine-4"], "root")
    add("spine01", J["spine-4"], J["spine-3"], "hips")
    add("spine02", J["spine-3"], J["spine-2"], "spine01")
    add("spine03", J["spine-2"], J["neck"], "spine02")
    add("neck", J["neck"], J["head"], "spine03")
    add("head", J["head"], J["head-2"], "neck")
    add("head_top", J["head-2"], np.asarray(J["head-2"]) + (0, 0, 0.03), "head", deform=False)
    for S, s in (("L", "l"), ("R", "r")):
        add("eye_" + S, L["eye_" + S], np.asarray(L["eye_" + S]) + (0, -0.02, 0), "head", deform=False)
        add("bust_" + S, L["bust_base_" + S], np.asarray(L["bust_" + S]) + (0, -0.01, 0), "spine03", deform=False)
        add("shoulder_" + S, J[s + "-clavicle"], J[s + "-shoulder"], "spine03")
        add("upperarm_" + S, J[s + "-shoulder"], J[s + "-elbow"], "shoulder_" + S)
        add("forearm_" + S, J[s + "-elbow"], J[s + "-hand"], "upperarm_" + S)
        add("hand_" + S, J[s + "-hand"], J[s + "-finger-3-1"], "forearm_" + S)
        for fi, fname in enumerate(["thumb", "index", "middle", "ring", "pinky"], start=1):
            parent = "hand_" + S
            for k in (1, 2, 3):
                bn = "%s%02d_%s" % (fname, k, S)
                add(bn, J["%s-finger-%d-%d" % (s, fi, k)], J["%s-finger-%d-%d" % (s, fi, k + 1)], parent)
                parent = bn
        add("thigh_" + S, J[s + "-upper-leg"], J[s + "-knee"], "hips")
        add("calf_" + S, J[s + "-knee"], J[s + "-ankle"], "thigh_" + S)
        add("foot_" + S, J[s + "-ankle"], J[s + "-foot-1"], "calf_" + S)
        add("toes_" + S, J[s + "-foot-1"], J[s + "-foot-2"], "foot_" + S)
    return B


def add_hair_chain(B, name_prefix, points, parent="head"):
    """Append a chain of bones through `points` (list of positions)."""
    names = []
    for i in range(len(points) - 1):
        n = "%s_%02d" % (name_prefix, i + 1)
        B.append(dict(name=n, head=np.asarray(points[i], np.float64).tolist(), tail=np.asarray(points[i + 1], np.float64).tolist(), parent=parent, deform=True))
        parent = n; names.append(n)
    return names


# --------------------------------------------------------------------------
# Blender side
# --------------------------------------------------------------------------
def build_armature(bones, name="Armature"):
    import bpy
    from mathutils import Vector
    from common import bl_select_only
    arm = bpy.data.armatures.new(name)
    ob = bpy.data.objects.new(name, arm)
    bpy.context.scene.collection.objects.link(ob)
    bl_select_only([ob])
    bpy.ops.object.mode_set(mode="EDIT")
    eb = {}
    for b in bones:
        e = arm.edit_bones.new(b["name"])
        e.head = Vector(b["head"]); e.tail = Vector(b["tail"]); e.use_deform = b["deform"]
        axis = (e.tail - e.head).normalized()
        up = Vector((0, -1, 0)) if abs(axis.y) < 0.8 else Vector((0, 0, 1))
        e.align_roll(up)
        eb[b["name"]] = e
    for b in bones:
        if b["parent"]:
            eb[b["name"]].parent = eb[b["parent"]]
            eb[b["name"]].use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")
    log("armature '%s': %d bones (%d deform)" % (name, len(bones), sum(1 for b in bones if b["deform"])))
    return ob


def get_weights_dense(ob, bone_names):
    """(n_verts, n_bones) float32 matrix from vertex groups."""
    n = len(ob.data.vertices)
    W = np.zeros((n, len(bone_names)), np.float32)
    gi = {g.name: i for i, g in enumerate(ob.vertex_groups)}
    col = {gi[b]: j for j, b in enumerate(bone_names) if b in gi}
    for v in ob.data.vertices:
        for g in v.groups:
            j = col.get(g.group)
            if j is not None:
                W[v.index, j] = g.weight
    return W


def set_weights_dense(ob, bone_names, W, limit=4):
    """Replace all vertex groups from a dense matrix (top-`limit` normalised)."""
    W = np.asarray(W, np.float64).copy()
    if limit and W.shape[1] > limit:
        order = np.argsort(-W, axis=1)[:, limit:]          # columns to drop per row (strict top-`limit`)
        np.put_along_axis(W, order, 0.0, axis=1)
    s = W.sum(1, keepdims=True); s[s == 0] = 1
    W /= s
    for g in list(ob.vertex_groups):
        ob.vertex_groups.remove(g)
    for j, b in enumerate(bone_names):
        vg = ob.vertex_groups.new(name=b)
        nz = np.nonzero(W[:, j] > 1e-5)[0]
        for i in nz:
            vg.add([int(i)], float(W[i, j]), "REPLACE")
    return W


def auto_weight(body, arm):
    """Bone heat weights. Returns True if every vertex got weights."""
    import bpy
    from common import bl_select_only
    bl_select_only([body, arm], active=arm)
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    return True


def bone_segments(bones, names):
    H = np.array([b["head"] for b in bones if b["name"] in names]); T = np.array([b["tail"] for b in bones if b["name"] in names])
    return H, T


def numpy_weights(V, bones, deform_names, adj, k=4, smooth_iters=6, keep=4):
    """Fallback: inverse-distance^k to bone segments, smoothed over the mesh."""
    H, T = bone_segments(bones, deform_names)
    n = len(V); nb = len(H)
    D = np.empty((n, nb))
    for j in range(nb):
        ab = T[j] - H[j]; L2 = max(float(ab @ ab), 1e-12)
        t = np.clip(((V - H[j]) @ ab) / L2, 0, 1)
        D[:, j] = np.linalg.norm(V - (H[j] + t[:, None] * ab), axis=1)
    W = 1.0 / (D + 0.01) ** k
    thr = -np.sort(-W, axis=1)[:, keep - 1:keep]
    W[W < thr] = 0
    W /= W.sum(1, keepdims=True)
    indptr, idx = adj
    row = np.repeat(np.arange(n), np.diff(indptr)); deg = np.maximum(np.diff(indptr), 1)
    for _ in range(smooth_iters):
        nbw = np.zeros_like(W); np.add.at(nbw, row, W[idx]); nbw /= deg[:, None]
        W = 0.5 * W + 0.5 * nbw
    return W


def transfer_weights(src_V, src_W, dst_V, use_kd=True):
    """Nearest-vertex weight copy (kd-tree inside Blender, brute force otherwise)."""
    try:
        from mathutils.kdtree import KDTree
        kd = KDTree(len(src_V))
        for i, p in enumerate(src_V):
            kd.insert(p, i)
        kd.balance()
        idx = np.array([kd.find(p)[1] for p in dst_V])
    except ImportError:
        idx, _ = nearest_points(src_V, dst_V, chunk=512)
    return src_W[idx]


def region_ids(W, bone_names, V=None, L=None):
    """Region per vertex from its dominant bone; the torso is split at the waist
    and the buttock/hip flare (thigh-dominated but above the hip joint) counts as torso_lower."""
    dom = np.argmax(W, axis=1)
    out = np.zeros(len(W), np.uint8)
    for j, b in enumerate(bone_names):
        r = bone_region(b)
        if r:
            out[dom == j] = REGIONS[r]
    if V is not None and L is not None:
        torso = np.isin(out, [REGIONS["torso_upper"], REGIONS["torso_lower"]])
        out[torso & (V[:, 2] < L["waist_z"])] = REGIONS["torso_lower"]
        out[torso & (V[:, 2] >= L["waist_z"])] = REGIONS["torso_upper"]
        thigh = np.isin(out, [REGIONS["thigh_L"], REGIONS["thigh_R"]])
        out[thigh & (V[:, 2] > L["hip_z"] - 0.02)] = REGIONS["torso_lower"]
    return out
