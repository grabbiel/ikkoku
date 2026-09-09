"""Shared utilities for the Ikkoku asset pipeline.

Importable both from Blender's Python (bpy available) and from a plain
python3 with numpy/Pillow. Everything that needs bpy is guarded.

Working space ("Blender space"): metres, Z up, character faces -Y, +X is the
character's left. The glTF exporter (export_yup=True) turns this into
Y up / faces +Z as required by docs/ASSET_SPEC.md.
"""
import os, sys, json, struct, math, time
import numpy as np

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(TOOLS, "..", ".."))
SRC = os.path.join(TOOLS, "source")
MH = os.path.join(SRC, "makehuman")
OUT = os.path.join(TOOLS, "out")
VERIFY = os.path.join(OUT, "verify")
ASSETS = os.path.join(REPO, "Assets")
A_CHAR = os.path.join(ASSETS, "Characters")
A_HAIR = os.path.join(ASSETS, "Hair")
A_CLOTH = os.path.join(ASSETS, "Clothes")
A_ACC = os.path.join(ASSETS, "Accessories")
A_ITEMS = os.path.join(ASSETS, "Items")
A_TEX = os.path.join(ASSETS, "Textures")
SCRATCH = os.environ.get(
    "IKKOKU_SCRATCH",
    "/private/tmp/claude-501/-Users-rumpology-code-repo-ikkoku/4c65cccb-d6bb-4c0c-a7b0-3c99e1920c4f/scratchpad/assets")

for _d in (OUT, VERIFY, A_CHAR, A_HAIR, A_CLOTH, A_ACC, A_ITEMS, A_TEX, SCRATCH):
    os.makedirs(_d, exist_ok=True)

MH_SCALE = 0.1          # MakeHuman decimetres -> metres
N_BASE = 19158          # vertices in base.obj (13380 body + helpers)
N_BODY = 13380

_T0 = time.time()


def log(*a):
    print("[ikkoku %6.1fs]" % (time.time() - _T0), *a, flush=True)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# --------------------------------------------------------------------------
# MakeHuman file formats
# --------------------------------------------------------------------------
def load_obj(path):
    """Wavefront OBJ -> dict(v, vt, faces, fuv, groups, group_of_face).
    faces/fuv are python lists of index lists (0-based); fuv entries are -1
    when the face has no UVs."""
    V, VT, F, FT, G = [], [], [], [], []
    cur = "default"
    with open(path, "r", errors="replace") as f:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                V.append((float(p[1]), float(p[2]), float(p[3])))
            elif line.startswith("vt "):
                p = line.split()
                VT.append((float(p[1]), float(p[2])))
            elif line.startswith("f "):
                vi, ti = [], []
                for tok in line.split()[1:]:
                    parts = tok.split("/")
                    vi.append(int(parts[0]) - 1)
                    ti.append(int(parts[1]) - 1 if len(parts) > 1 and parts[1] else -1)
                F.append(vi); FT.append(ti); G.append(cur)
            elif line.startswith("g "):
                cur = line[2:].strip()
    return dict(v=np.asarray(V, np.float64), vt=np.asarray(VT, np.float64) if VT else np.zeros((0, 2)),
                faces=F, fuv=FT, groups=G)


def load_target(path, n=N_BASE):
    d = np.zeros((n, 3), np.float64)
    with open(path) as f:
        for line in f:
            if not line or line[0] == "#":
                continue
            p = line.split()
            if len(p) >= 4:
                d[int(p[0])] = (float(p[1]), float(p[2]), float(p[3]))
    return d


class Proxy:
    """A MakeHuman .mhclo/.mhmat proxy: mesh + fitting data relative to base.obj."""
    def __init__(self):
        self.name = ""; self.obj_file = None; self.material_file = None
        self.refs = None; self.weights = None; self.offsets = None
        self.scale_refs = {}   # axis index -> (v1, v2, denominator)
        self.delete_verts = np.zeros(N_BASE, bool)
        self.z_depth = 50
        self.mesh = None       # loaded obj dict


def load_mhclo(path):
    p = Proxy()
    folder = os.path.dirname(path)
    refs, ws, offs = [], [], []
    mode = None
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line[0] == "#":
                continue
            w = line.split()
            key = w[0]
            if key in ("verts", "delete_verts"):
                mode = key; continue
            if mode == "verts" and (w[0].lstrip("-").isdigit()):
                if len(w) == 1:
                    v = int(w[0]); refs.append((v, v, v)); ws.append((1.0, 0.0, 0.0)); offs.append((0.0, 0.0, 0.0))
                else:
                    refs.append((int(w[0]), int(w[1]), int(w[2])))
                    ws.append((float(w[3]), float(w[4]), float(w[5])))
                    offs.append((float(w[6]), float(w[7]), float(w[8])) if len(w) > 8 else (0.0, 0.0, 0.0))
                continue
            if mode == "delete_verts" and w[0].isdigit():
                toks = w; i = 0
                while i < len(toks):
                    if i + 2 < len(toks) and toks[i + 1] == "-":
                        a, b = int(toks[i]), int(toks[i + 2]); p.delete_verts[a:b + 1] = True; i += 3
                    else:
                        p.delete_verts[int(toks[i])] = True; i += 1
                continue
            if key == "name": p.name = " ".join(w[1:])
            elif key == "obj_file": p.obj_file = os.path.join(folder, w[1])
            elif key == "material": p.material_file = os.path.join(folder, w[1])
            elif key == "z_depth": p.z_depth = int(w[1])
            elif key in ("x_scale", "y_scale", "z_scale"):
                p.scale_refs["xyz".index(key[0])] = (int(w[1]), int(w[2]), float(w[3]))
    p.refs = np.asarray(refs, np.int64); p.weights = np.asarray(ws, np.float64); p.offsets = np.asarray(offs, np.float64)
    if p.obj_file and os.path.exists(p.obj_file):
        p.mesh = load_obj(p.obj_file)
    return p


def fit_proxy(p, coords_mh):
    """Proxy vertex positions for base-mesh coordinates `coords_mh` (N_BASE,3)
    given in MakeHuman space (decimetres, Y up, faces +Z)."""
    S = np.eye(3)
    for ax, (v1, v2, den) in p.scale_refs.items():
        S[ax, ax] = abs(coords_mh[v1, ax] - coords_mh[v2, ax]) / den
    r, w = p.refs, p.weights
    out = (coords_mh[r[:, 0]] * w[:, 0:1] + coords_mh[r[:, 1]] * w[:, 1:2] + coords_mh[r[:, 2]] * w[:, 2:3]
           + p.offsets @ S.T)
    return out


# --------------------------------------------------------------------------
# space conversion
# --------------------------------------------------------------------------
def mh_to_bl(V, ground_y=0.0):
    """MakeHuman (dm, Y up, +Z front) -> Blender (m, Z up, -Y front)."""
    V = np.asarray(V, np.float64)
    out = np.empty_like(V)
    out[:, 0] = V[:, 0] * MH_SCALE
    out[:, 1] = -V[:, 2] * MH_SCALE
    out[:, 2] = (V[:, 1] - ground_y) * MH_SCALE
    return out


def bl_to_mh(V, ground_y=0.0):
    V = np.asarray(V, np.float64)
    out = np.empty_like(V)
    out[:, 0] = V[:, 0] / MH_SCALE
    out[:, 1] = V[:, 2] / MH_SCALE + ground_y
    out[:, 2] = -V[:, 1] / MH_SCALE
    return out


# --------------------------------------------------------------------------
# mesh utilities (numpy)
# --------------------------------------------------------------------------
def triangulate(faces):
    tris = []
    for f in faces:
        for i in range(1, len(f) - 1):
            tris.append((f[0], f[i], f[i + 1]))
    return np.asarray(tris, np.int64)


def build_adjacency(faces, n):
    """Vertex adjacency as CSR arrays (indptr, indices) from polygon faces."""
    a, b = [], []
    for f in faces:
        k = len(f)
        for i in range(k):
            a.append(f[i]); b.append(f[(i + 1) % k])
    a = np.asarray(a); b = np.asarray(b)
    src = np.concatenate([a, b]); dst = np.concatenate([b, a])
    key = src.astype(np.int64) * n + dst
    key = np.unique(key)
    src = key // n; dst = key % n
    counts = np.bincount(src, minlength=n)
    indptr = np.zeros(n + 1, np.int64); indptr[1:] = np.cumsum(counts)
    return indptr, dst


def laplacian_smooth(V, adj, mask, iters=2, lam=0.5, taubin_mu=None):
    """Masked Laplacian smoothing (optionally Taubin lambda/mu to avoid shrink)."""
    indptr, idx = adj
    n = len(V)
    deg = np.diff(indptr).astype(np.float64)
    deg[deg == 0] = 1
    row = np.repeat(np.arange(n), np.diff(indptr))
    V = V.copy()
    m = np.asarray(mask, np.float64)[:, None]
    for _ in range(iters):
        for step in ([lam] if taubin_mu is None else [lam, taubin_mu]):
            nb = np.zeros_like(V)
            np.add.at(nb, row, V[idx])
            nb /= deg[:, None]
            V = V + step * m * (nb - V)
    return V


def vertex_normals(V, tris):
    fn = np.cross(V[tris[:, 1]] - V[tris[:, 0]], V[tris[:, 2]] - V[tris[:, 0]])
    N = np.zeros_like(V)
    for k in range(3):
        np.add.at(N, tris[:, k], fn)
    ln = np.linalg.norm(N, axis=1); ln[ln == 0] = 1
    return N / ln[:, None]


def connected_components(faces, n):
    indptr, idx = build_adjacency(faces, n)
    comp = -np.ones(n, np.int64); c = 0
    for s in range(n):
        if comp[s] >= 0:
            continue
        stack = [s]; comp[s] = c
        while stack:
            v = stack.pop()
            for u in idx[indptr[v]:indptr[v + 1]]:
                if comp[u] < 0:
                    comp[u] = c; stack.append(u)
        c += 1
    return comp, c


def nearest_points(src, query, chunk=2048):
    """Brute-force nearest neighbour (index, distance) of each query in src."""
    src = np.asarray(src, np.float64); query = np.asarray(query, np.float64)
    idx = np.empty(len(query), np.int64); dist = np.empty(len(query))
    s2 = (src ** 2).sum(1)
    for i in range(0, len(query), chunk):
        q = query[i:i + chunk]
        d = s2[None, :] - 2 * q @ src.T + (q ** 2).sum(1)[:, None]
        j = d.argmin(1); idx[i:i + chunk] = j
        dist[i:i + chunk] = np.sqrt(np.maximum(d[np.arange(len(q)), j], 0))
    return idx, dist


def fit_sphere(P):
    """Least-squares sphere fit -> (centre, radius)."""
    P = np.asarray(P, np.float64)
    A = np.c_[2 * P, np.ones(len(P))]
    b = (P ** 2).sum(1)
    x, *_ = np.linalg.lstsq(A, b, rcond=None)
    c = x[:3]; r = math.sqrt(max(x[3] + (c ** 2).sum(), 0))
    return c, r


# --------------------------------------------------------------------------
# GLB parsing (validation without Blender)
# --------------------------------------------------------------------------
def parse_glb(path):
    with open(path, "rb") as f:
        magic, ver, length = struct.unpack("<III", f.read(12))
        assert magic == 0x46546C67, "not a GLB"
        clen, ctype = struct.unpack("<II", f.read(8))
        js = json.loads(f.read(clen))
        blob = b""
        if f.tell() < length:
            blen, btype = struct.unpack("<II", f.read(8))
            blob = f.read(blen)
    return js, blob


_CT = {5120: "i1", 5121: "u1", 5122: "i2", 5123: "u2", 5125: "u4", 5126: "f4"}
_NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_accessor(js, blob, i):
    a = js["accessors"][i]
    nc = _NC[a["type"]]; ct = _CT[a["componentType"]]; cnt = a["count"]
    isz = np.dtype(ct).itemsize
    if "bufferView" in a:
        bv = js["bufferViews"][a["bufferView"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = bv.get("byteStride", 0)
        if stride and stride != nc * isz:
            raw = np.frombuffer(blob, dtype=np.uint8, count=stride * cnt, offset=off)
            arr = np.lib.stride_tricks.as_strided(raw, shape=(cnt, nc * isz), strides=(stride, 1)).copy()
            arr = arr.view(ct).reshape(cnt, nc)
        else:
            arr = np.frombuffer(blob, dtype=ct, count=cnt * nc, offset=off).reshape(cnt, nc).copy()
    else:
        arr = np.zeros((cnt, nc), ct)
    if "sparse" in a:
        sp = a["sparse"]
        bvi = js["bufferViews"][sp["indices"]["bufferView"]]
        ict = _CT[sp["indices"]["componentType"]]
        ind = np.frombuffer(blob, dtype=ict, count=sp["count"], offset=bvi.get("byteOffset", 0) + sp["indices"].get("byteOffset", 0))
        bvv = js["bufferViews"][sp["values"]["bufferView"]]
        val = np.frombuffer(blob, dtype=ct, count=sp["count"] * nc, offset=bvv.get("byteOffset", 0) + sp["values"].get("byteOffset", 0)).reshape(-1, nc)
        arr[ind.astype(np.int64)] = val
    return arr


def glb_summary(path, verbose=True):
    js, blob = parse_glb(path)
    info = {"file": os.path.relpath(path, REPO), "bytes": os.path.getsize(path), "meshes": [], "materials": [m.get("name") for m in js.get("materials", [])],
            "joints": [], "images": len(js.get("images", [])), "nodes": len(js.get("nodes", []))}
    for m in js.get("meshes", []):
        prims = m["primitives"]
        p0 = prims[0]
        nv = js["accessors"][p0["attributes"]["POSITION"]]["count"]
        ntri = sum(js["accessors"][p["indices"]]["count"] // 3 for p in prims if "indices" in p)
        mi = dict(name=m.get("name"), verts=nv, tris=ntri, attributes=sorted(p0["attributes"].keys()),
                  materials=[js["materials"][p["material"]]["name"] for p in prims if "material" in p],
                  targets=m.get("extras", {}).get("targetNames", []), extras={k: v for k, v in m.get("extras", {}).items() if k != "targetNames"})
        info["meshes"].append(mi)
    for s in js.get("skins", []):
        info["joints"] = [js["nodes"][j]["name"] for j in s["joints"]]
    if verbose:
        log("GLB %s: %.2f MB, %d nodes, %d images" % (info["file"], info["bytes"] / 1e6, info["nodes"], info["images"]))
        for mi in info["meshes"]:
            log("  mesh %-12s verts=%6d tris=%6d mats=%s attrs=%s targets=%d extras=%s" % (
                mi["name"], mi["verts"], mi["tris"], mi["materials"], mi["attributes"], len(mi["targets"]), mi["extras"]))
        if info["joints"]:
            log("  skin joints (%d): %s" % (len(info["joints"]), " ".join(info["joints"])))
    return info, js, blob


# --------------------------------------------------------------------------
# Blender helpers (only usable inside Blender)
# --------------------------------------------------------------------------
def in_blender():
    try:
        import bpy  # noqa
        return True
    except ImportError:
        return False


def bl_reset():
    import bpy
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "METRIC"; sc.unit_settings.scale_length = 1.0
    return sc


def bl_material(name, color=(0.9, 0.9, 0.9, 1.0), image_path=None, alpha_clip=False, emission=0.0, embed=True, roughness=0.6):
    """Principled material; image (if any) is packed so it ends up inside the GLB."""
    import bpy
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial"); out.location = (400, 0)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled"); bsdf.location = (0, 0)
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    if "Emission Strength" in bsdf.inputs:
        bsdf.inputs["Emission Strength"].default_value = emission
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    if image_path:
        img = bpy.data.images.load(image_path, check_existing=True)
        if embed:
            img.pack()
        tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img; tex.location = (-400, 0)
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        if alpha_clip:
            nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
            m.surface_render_method = "DITHERED"
    m.use_backface_culling = False
    return m


def bl_make_mesh(name, verts, faces, uv_loops=None, material=None, smooth=True, vcol=None, custom_normals=None):
    """Create a mesh object from numpy arrays. uv_loops: (n_loops,2) in face-loop order."""
    import bpy
    me = bpy.data.meshes.new(name)
    faces = [list(map(int, f)) for f in faces]
    me.from_pydata([tuple(map(float, v)) for v in verts], [], faces)
    me.update()
    if uv_loops is not None:
        uv = me.uv_layers.new(name="UVMap")
        uv.data.foreach_set("uv", np.asarray(uv_loops, np.float32).ravel())
    if vcol is not None:
        ca = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
        ca.data.foreach_set("color", np.asarray(vcol, np.float32).ravel())
    if smooth:
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    if material is not None:
        me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def bl_get_verts(ob):
    n = len(ob.data.vertices)
    co = np.empty(n * 3, np.float32); ob.data.vertices.foreach_get("co", co)
    return co.reshape(-1, 3).astype(np.float64)


def bl_set_verts(ob, V):
    ob.data.vertices.foreach_set("co", np.asarray(V, np.float32).ravel())
    ob.data.update()


def bl_add_shape_key(ob, name, deltas):
    """Add a relative shape key = basis + deltas."""
    import bpy
    if ob.data.shape_keys is None:
        ob.shape_key_add(name="Basis", from_mix=False)
    sk = ob.shape_key_add(name=name, from_mix=False)
    base = np.empty(len(ob.data.vertices) * 3, np.float32)
    ob.data.shape_keys.key_blocks["Basis"].data.foreach_get("co", base)
    sk.data.foreach_set("co", (base.reshape(-1, 3) + np.asarray(deltas, np.float32)).ravel())
    sk.value = 0.0
    return sk


def bl_select_only(objs, active=None):
    import bpy
    for o in bpy.data.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]


def bl_export_glb(path, objs, skins=True, morph=True, vcol=True, extras=True, attributes=True, images="AUTO"):
    import bpy
    bl_select_only(objs, objs[0])
    kw = dict(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
              export_skins=skins, export_morph=morph, export_morph_normal=False, export_try_sparse_sk=True,
              export_apply=True, export_texcoords=True, export_normals=True, export_tangents=True,
              export_all_influences=False, export_influence_nb=4, export_extras=extras, export_attributes=attributes,
              export_image_format=images, export_animations=False, export_def_bones=False,
              export_vertex_color="ACTIVE" if vcol else "NONE", export_all_vertex_colors=False,
              export_active_vertex_color_when_no_material=True, export_rest_position_armature=True,
              export_hierarchy_flatten_bones=False, export_leaf_bone=False, export_unused_images=False)
    bpy.ops.export_scene.gltf(**kw)
    log("exported", os.path.relpath(path, REPO), "%.2f MB" % (os.path.getsize(path) / 1e6))
    return path


def bl_ensure_uv_valid(ob):
    """Blender requires each loop to have a uv; nothing else."""
    return ob


def write_png(path, arr):
    """Minimal PNG writer (no Pillow needed): arr uint8 HxW (L), HxWx3 (RGB) or HxWx4 (RGBA)."""
    import zlib
    arr = np.ascontiguousarray(arr)
    if arr.dtype != np.uint8:
        arr = np.clip(np.rint(arr * 255.0 if arr.max() <= 1.0 else arr), 0, 255).astype(np.uint8)
    h, w = arr.shape[:2]
    ch = 1 if arr.ndim == 2 else arr.shape[2]
    ctype = {1: 0, 3: 2, 4: 6}[ch]
    raw = b"".join(b"\x00" + arr[y].tobytes() for y in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))
    return path


def raster_field(uv_tris, val_tris, size, pad=6):
    """Rasterise per-corner values over UV triangles into an image.
    uv_tris: (T,3,2) in UV space (v up); val_tris: (T,3) or (T,3,C).
    Returns (img float32 HxWxC with row 0 = v=1, coverage bool HxW). Uncovered
    pixels within `pad` px of a covered one are filled (seam padding)."""
    H = W = size
    val_tris = np.asarray(val_tris, np.float64)
    if val_tris.ndim == 2:
        val_tris = val_tris[:, :, None]
    C = val_tris.shape[2]
    img = np.zeros((H, W, C), np.float64); cov = np.zeros((H, W), bool)
    px = np.stack([uv_tris[:, :, 0] * W, (1.0 - uv_tris[:, :, 1]) * H], 2)  # (T,3,2) pixel coords
    for t in range(len(px)):
        p = px[t]
        x0 = max(int(np.floor(p[:, 0].min())) - 1, 0); x1 = min(int(np.ceil(p[:, 0].max())) + 1, W - 1)
        y0 = max(int(np.floor(p[:, 1].min())) - 1, 0); y1 = min(int(np.ceil(p[:, 1].max())) + 1, H - 1)
        if x1 < x0 or y1 < y0:
            continue
        xs = np.arange(x0, x1 + 1) + 0.5; ys = np.arange(y0, y1 + 1) + 0.5
        X, Y = np.meshgrid(xs, ys)
        (ax, ay), (bx, by), (cx, cy) = p
        det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        if abs(det) < 1e-12:
            continue
        l1 = ((bx - X) * (cy - Y) - (cx - X) * (by - Y)) / det
        l2 = ((cx - X) * (ay - Y) - (ax - X) * (cy - Y)) / det
        l3 = 1.0 - l1 - l2
        eps = -0.75 / max(abs(det) ** 0.5, 1.0)  # slight conservative expansion (sub-pixel) to avoid cracks
        inside = (l1 >= eps) & (l2 >= eps) & (l3 >= eps)
        if not inside.any():
            continue
        lam = np.stack([l1, l2, l3], -1).clip(0, 1); lam /= lam.sum(-1, keepdims=True)
        vals = lam @ val_tris[t]                     # (h,w,C)
        sub = img[y0:y1 + 1, x0:x1 + 1]; csub = cov[y0:y1 + 1, x0:x1 + 1]
        write = inside & ~csub
        sub[write] = vals[write]; csub |= inside
    # seam padding by iterative dilation (never wrapping around the image border)
    for _ in range(pad):
        acc = np.zeros_like(img); cnt = np.zeros((H, W), np.float64)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            sh = np.roll(np.roll(img, dy, 0), dx, 1); sc = np.roll(np.roll(cov, dy, 0), dx, 1).copy()
            if dy == 1:
                sc[0, :] = False
            elif dy == -1:
                sc[-1, :] = False
            if dx == 1:
                sc[:, 0] = False
            elif dx == -1:
                sc[:, -1] = False
            acc += sh * sc[:, :, None]; cnt += sc
        fill = (~cov) & (cnt > 0)
        img[fill] = acc[fill] / cnt[fill][:, None]
        cov = cov | fill
    return img.astype(np.float32), cov


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=1)
    log("wrote", os.path.relpath(path, REPO))
