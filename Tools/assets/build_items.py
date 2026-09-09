"""Accessories -> Assets/Accessories/acc_<name>.glb, studio items -> Assets/Items/item_<name>.glb
(run inside Blender):  Blender -b --factory-startup --python build_items.py

Static meshes, material `ik_item` (glasses lenses: `ik_glass`, alphaMode BLEND, alpha 0.3),
box-projected UVs, COLOR_0 carries a base tint (RGB, alpha = outline width multiplier).
Accessories: origin at the attach point, extras.defaultParent (bone) + defaultOffset (metres,
glTF axes: x right of viewer / character left, y up, z front) + defaultRotation (deg, xyz).
"""
import sys, os, json, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import bpy, bmesh
from mathutils import Vector, Matrix
from common import *


# --------------------------------------------------------------------------
# primitive builder
# --------------------------------------------------------------------------
class Builder:
    def __init__(self):
        self.bm = bmesh.new()
        self.colors = []   # (vert index start, end, color)
        self.slots = []    # (face index start, end, material slot)

    def _begin(self):
        self._n0 = len(self.bm.verts); self._f0 = len(self.bm.faces)

    def _mark(self, color, alpha=1.0, slot=0):
        self.bm.verts.ensure_lookup_table(); self.bm.faces.ensure_lookup_table()
        self.colors.append((self._n0, len(self.bm.verts), tuple(color) + (alpha,)))
        self.slots.append((self._f0, len(self.bm.faces), slot))

    def box(self, size, at=(0, 0, 0), color=(0.8, 0.8, 0.8), rot=None, alpha=1.0):
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4)) @ Matrix.Diagonal((size[0], size[1], size[2], 1))
        bmesh.ops.create_cube(self.bm, size=1.0, matrix=M)
        self._mark(color, alpha)

    def sphere(self, r, at=(0, 0, 0), color=(0.8, 0.8, 0.8), scale=(1, 1, 1), seg=24, rings=16, alpha=1.0, rot=None):
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4)) @ Matrix.Diagonal((scale[0] * r, scale[1] * r, scale[2] * r, 1))
        bmesh.ops.create_uvsphere(self.bm, u_segments=seg, v_segments=rings, radius=1.0, matrix=M)
        self._mark(color, alpha)

    def cylinder(self, r, h, at=(0, 0, 0), color=(0.8, 0.8, 0.8), seg=24, rot=None, r2=None, alpha=1.0, slot=0):
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4))
        bmesh.ops.create_cone(self.bm, cap_ends=True, segments=seg, radius1=r, radius2=r if r2 is None else r2, depth=h, matrix=M)
        self._mark(color, alpha, slot)

    def torus(self, R, r, at=(0, 0, 0), color=(0.8, 0.8, 0.8), rot=None, seg=32, seg2=10, arc=None, alpha=1.0):
        """Torus (optionally an arc of `arc` radians) in the XY plane; `rot` may include a scale."""
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4))
        n1 = seg if arc is None else max(int(seg * arc / (2 * math.pi)), 3)
        verts = []
        for i in range(n1 + (0 if arc is None else 1)):
            th = (2 * math.pi if arc is None else arc) * i / n1 - (0 if arc is None else arc / 2)
            c = Vector((math.cos(th) * R, math.sin(th) * R, 0)); rad = Vector((math.cos(th), math.sin(th), 0))
            ring = []
            for j in range(seg2):
                ph = 2 * math.pi * j / seg2
                p = c + rad * math.cos(ph) * r + Vector((0, 0, math.sin(ph) * r))
                ring.append(self.bm.verts.new(M @ p))
            verts.append(ring)
        nloops = len(verts)
        for i in range(nloops if arc is None else nloops - 1):
            a = verts[i]; b = verts[(i + 1) % nloops]
            for j in range(seg2):
                self.bm.faces.new((a[j], b[j], b[(j + 1) % seg2], a[(j + 1) % seg2]))
        if arc is not None:
            self.bm.faces.new(tuple(reversed(verts[0]))); self.bm.faces.new(tuple(verts[-1]))
        self._mark(color, alpha)

    def lathe(self, profile, at=(0, 0, 0), color=(0.8, 0.8, 0.8), rot=None, seg=24, alpha=1.0, scale_xy=(1, 1)):
        """Surface of revolution about the local Z axis; profile = [(radius, z), ...] from bottom
        to top (radius 0 at an end closes it with a pole)."""
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4))
        rings = []
        for (r, z) in profile:
            if r <= 1e-6:
                rings.append([self.bm.verts.new(M @ Vector((0, 0, z)))])
                continue
            ring = []
            for j in range(seg):
                th = 2 * math.pi * j / seg
                ring.append(self.bm.verts.new(M @ Vector((math.cos(th) * r * scale_xy[0], math.sin(th) * r * scale_xy[1], z))))
            rings.append(ring)
        for i in range(len(rings) - 1):
            a, b = rings[i], rings[i + 1]
            if len(a) == 1:
                for j in range(seg):
                    self.bm.faces.new((a[0], b[j], b[(j + 1) % seg]))
            elif len(b) == 1:
                for j in range(seg):
                    self.bm.faces.new((a[j], b[0], a[(j + 1) % seg]))
            else:
                for j in range(seg):
                    self.bm.faces.new((a[j], b[j], b[(j + 1) % seg], a[(j + 1) % seg]))
        if len(rings[0]) > 1:
            self.bm.faces.new(tuple(reversed(rings[0])))
        if len(rings[-1]) > 1:
            self.bm.faces.new(tuple(rings[-1]))
        self._mark(color, alpha)

    def curved_cone(self, base, tip, r0, bend, color=(0.8, 0.8, 0.8), seg=14, n=8, flat=0.6, up=(0, 0, 1)):
        """Cone whose axis is a quadratic curve base -> base+bend (control) -> tip, base radius r0
        (elliptical: flattened by `flat` along the local front axis), radius tapering to a point."""
        self._begin()
        base = Vector(base); tip = Vector(tip); ctrl = (base + tip) / 2 + Vector(bend)
        rings = []
        for i in range(n + 1):
            t = i / n
            p = (1 - t) ** 2 * base + 2 * (1 - t) * t * ctrl + t ** 2 * tip
            T = (2 * (1 - t) * (ctrl - base) + 2 * t * (tip - ctrl)).normalized()
            a = T.cross(Vector(up)) if abs(T.dot(Vector(up))) < 0.95 else T.cross(Vector((1, 0, 0)))
            a.normalize(); b = T.cross(a)
            r = r0 * (1 - t) ** 0.9
            if i == n:
                rings.append([self.bm.verts.new(p)]); break
            ring = []
            for j in range(seg):
                th = 2 * math.pi * j / seg
                ring.append(self.bm.verts.new(p + a * math.cos(th) * r + b * math.sin(th) * r * flat))
            rings.append(ring)
        for i in range(len(rings) - 1):
            a, b = rings[i], rings[i + 1]
            for j in range(seg):
                if len(b) == 1:
                    self.bm.faces.new((a[j], b[0], a[(j + 1) % seg]))
                else:
                    self.bm.faces.new((a[j], b[j], b[(j + 1) % seg], a[(j + 1) % seg]))
        self.bm.faces.new(tuple(reversed(rings[0])))
        self._mark(color)

    def star(self, r_out, r_in, depth, at=(0, 0, 0), color=(0.8, 0.8, 0.8), rot=None, points=5):
        """Five-point star prism in the local XY plane, extruded along Z."""
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4))
        lo, hi = [], []
        for k in range(points * 2):
            th = math.pi / 2 + math.pi * k / points
            r = r_out if k % 2 == 0 else r_in
            lo.append(self.bm.verts.new(M @ Vector((math.cos(th) * r, math.sin(th) * r, -depth / 2))))
            hi.append(self.bm.verts.new(M @ Vector((math.cos(th) * r, math.sin(th) * r, depth / 2))))
        c0 = self.bm.verts.new(M @ Vector((0, 0, -depth / 2))); c1 = self.bm.verts.new(M @ Vector((0, 0, depth / 2)))
        n = points * 2
        for k in range(n):
            self.bm.faces.new((lo[k], lo[(k + 1) % n], hi[(k + 1) % n], hi[k]))
            self.bm.faces.new((c1, hi[k], hi[(k + 1) % n]))
            self.bm.faces.new((c0, lo[(k + 1) % n], lo[k]))
        self._mark(color)

    def plane(self, sx, sy, at=(0, 0, 0), color=(0.8, 0.8, 0.8), rot=None, alpha=1.0):
        self._begin()
        M = Matrix.Translation(Vector(at)) @ (rot or Matrix.Identity(4)) @ Matrix.Diagonal((sx, sy, 1, 1))
        bmesh.ops.create_grid(self.bm, x_segments=1, y_segments=1, size=0.5, matrix=M)
        self._mark(color, alpha)

    def transform(self, M):
        """Apply a 4x4 matrix to everything built so far."""
        bmesh.ops.transform(self.bm, matrix=M, verts=self.bm.verts)

    def finish(self, name, material, flip=False, smooth=False, extra_materials=()):
        bm = self.bm
        if flip:
            bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.faces.ensure_lookup_table()
        for a, b, slot in self.slots:
            if slot:
                for fi in range(a, b):
                    bm.faces[fi].material_index = slot
        me = bpy.data.meshes.new(name); bm.to_mesh(me); me.materials.append(material)
        for m in extra_materials:
            me.materials.append(m)
        col = np.ones((len(me.vertices), 4), np.float32)
        for a, b, c in self.colors:
            col[a:b] = c
        ca = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT"); ca.data.foreach_set("color", col.ravel())
        # box uvs by dominant face normal
        uv = me.uv_layers.new(name="UVMap")
        co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
        ext = max(float(co.max() - co.min()), 1e-3)
        for poly in me.polygons:
            n = np.abs(np.array(poly.normal)); ax = int(np.argmax(n))
            u_ax, v_ax = {0: (1, 2), 1: (0, 2), 2: (0, 1)}[ax]
            for li in poly.loop_indices:
                v = co[me.loops[li].vertex_index]
                uv.data[li].uv = ((v[u_ax] - co[:, u_ax].min()) / ext, (v[v_ax] - co[:, v_ax].min()) / ext)
        me.polygons.foreach_set("use_smooth", [smooth] * len(me.polygons))
        ob = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(ob)
        bm.free()
        return ob


def rot(x=0, y=0, z=0):
    return Matrix.Rotation(math.radians(z), 4, "Z") @ Matrix.Rotation(math.radians(y), 4, "Y") @ Matrix.Rotation(math.radians(x), 4, "X")


def scale(x=1, y=1, z=1):
    return Matrix.Diagonal((x, y, z, 1))


def export_static(ob, path, extras=None):
    for k, v in (extras or {}).items():
        ob[k] = v; ob.data[k] = v
    bl_export_glb(path, [ob], skins=False, morph=False, vcol=True)
    return glb_summary(path, verbose=False)[0]


# --------------------------------------------------------------------------
# accessories
# --------------------------------------------------------------------------
def body_ref():
    p = os.path.join(OUT, "body_f.npz")
    if not os.path.exists(p):
        return None
    d = np.load(p)
    L = {k: (np.asarray(v) if isinstance(v, list) else v) for k, v in json.loads(str(d["landmarks"])).items()}
    J = {k: np.asarray(v) for k, v in json.loads(str(d["joints"])).items()}
    return L, J, d["V"].astype(np.float64), d["normals"].astype(np.float64)


def head_surface(V, N, L, direction, lift=0.004):
    """Point on the head skin in `direction` from the head centre (+ lift along the normal)."""
    hc = L["head_c"]; d = np.asarray(direction, np.float64); d /= np.linalg.norm(d)
    sel = np.where(V[:, 2] > L["neck_z"] + 0.06)[0]
    v = V[sel] - hc; vn = v / np.linalg.norm(v, axis=1, keepdims=True)
    i = sel[np.argmax(vn @ d)]
    return V[i] + N[i] * lift, N[i]


def tangent_frame(normal):
    """4x4 rotation mapping local -y (front of a flat accessory) onto `normal` and local +z onto
    the surface's 'up' direction, so a bow / pin built facing -y lies flat on the skin."""
    f = np.asarray(normal, np.float64); f /= np.linalg.norm(f)
    up = np.array([0, 0, 1.0]); u = up - f * (up @ f)
    if np.linalg.norm(u) < 1e-6:
        u = np.array([0, -1.0, 0])
    u /= np.linalg.norm(u); r = np.cross(u, f)
    M = Matrix.Identity(4)
    for k in range(3):
        M[k][0] = float(r[k]); M[k][1] = float(-f[k]); M[k][2] = float(u[k])
    return M


def to_gltf(v):
    """Blender (x, y, z) -> glTF (x, z, -y)."""
    return [float(v[0]), float(v[2]), float(-v[1])]


def glass_material():
    """Transparent lens material: alphaMode BLEND, alpha 0.3."""
    m = bl_material("ik_glass", (0.75, 0.88, 1.0, 0.3), roughness=0.1)
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Alpha"].default_value = 0.3
    m.surface_render_method = "BLENDED"
    if hasattr(m, "blend_method"):
        m.blend_method = "BLEND"
    return m


def accessories(mat):
    ref = body_ref()
    L, J, BV, BN = ref if ref else ({}, {}, None, None)
    head = J.get("head", np.array([0, -0.04, 1.47])); head_top = L.get("head_top", np.array([0, -0.035, 1.69]))
    eye_L = L.get("eye_L", np.array([0.033, -0.114, 1.569])); eye_r = float(L.get("eye_r", 0.027))
    hw = float(L.get("head_half_width", 0.096)); neck = J.get("neck", np.array([0, 0, 1.36]))
    hip_x = float(L.get("hip_half_width", 0.175))
    out = {}
    glass = glass_material()

    def on_head(direction, lift=0.004, fallback=None):
        if BV is None:
            return fallback, np.asarray(direction, np.float64) / np.linalg.norm(direction)
        return head_surface(BV, BN, L, direction, lift)

    def save(name, ob, parent, offset_bl, rotation=(0, 0, 0), display=None):
        path = os.path.join(A_ACC, "acc_%s.glb" % name)
        info = export_static(ob, path, {"defaultParent": parent, "defaultOffset": to_gltf(offset_bl), "defaultRotation": list(rotation)})
        out[name] = dict(file=os.path.relpath(path, REPO), bytes=os.path.getsize(path), parent=parent, offset=to_gltf(offset_bl), name=display or name.replace("_", " ").title(),
                         tris=info["meshes"][0]["tris"], materials=info["materials"])
        bpy.data.objects.remove(ob)

    red = (0.85, 0.15, 0.25); dark_red = (0.7, 0.1, 0.2)
    # ribbon: bow = two flattened loops + knot + two tails; origin at the knot
    b = Builder()
    for s in (1, -1):
        b.torus(0.023, 0.0085, at=(s * 0.03, -0.002, 0.004), color=red, rot=rot(0, s * 12, s * 8) @ rot(90, 0, 0) @ scale(1.25, 0.8, 0.45), seg=24, seg2=10)
    b.lathe([(0, -0.009), (0.008, -0.007), (0.011, 0), (0.008, 0.007), (0, 0.009)], at=(0, -0.006, 0), color=dark_red, rot=rot(0, 0, 0), seg=16, scale_xy=(1.15, 0.8))
    for s in (1, -1):
        b.box((0.015, 0.003, 0.07), at=(s * 0.014, 0.0, -0.042), color=red, rot=rot(0, s * 16, 0))
        b.box((0.011, 0.0031, 0.012), at=(s * 0.026, 0.0, -0.079), color=red, rot=rot(0, s * 16, 0))
    # origin on the skin at the side-top of the head (the old offset was 3 cm inside the skull); the
    # bow is rotated so its loops lie flat on the head (orientation baked in, defaultRotation 0)
    p_rib, n_rib = on_head((0.62, -0.12, 0.77), lift=0.006, fallback=np.array([0.062, -0.045, head_top[2] - 0.02]))
    b.transform(tangent_frame(n_rib))
    save("ribbon", b.finish("acc_ribbon", mat, smooth=True), "head", p_rib - head, (0, 0, 0), "Ribbon")
    # glasses: rims + lenses (ik_glass, alpha 0.3) + bridge + temples; origin at the bridge
    b = Builder(); ex = float(eye_L[0]); ry = eye_r * 1.05; frame = (0.15, 0.12, 0.12)
    for s in (1, -1):
        b.torus(ry, 0.0022, at=(s * ex, 0, 0), color=frame, rot=rot(90, 0, 0) @ scale(1.0, 0.85, 1.0))
        b.cylinder(ry - 0.001, 0.0012, at=(s * ex, 0.0, 0), color=(0.8, 0.9, 1.0), rot=rot(90, 0, 0) @ scale(1.0, 0.85, 1.0), seg=32, slot=1)
        b.box((0.003, 0.125, 0.003), at=(s * (ex + ry + 0.002), 0.06, 0.004), color=frame)
        b.box((0.003, 0.003, 0.02), at=(s * (ex + ry + 0.002), 0.123, -0.006), color=frame, rot=rot(-20, 0, 0))
        b.box((0.006, 0.0025, 0.0025), at=(s * (ex + ry), 0.0, 0.004), color=frame)
    b.cylinder(0.0022, ex * 2 - ry * 2 + 0.004, at=(0, 0, 0.004), color=frame, rot=rot(0, 90, 0), seg=8)
    save("glasses", b.finish("acc_glasses", mat, smooth=True, extra_materials=[glass]), "head", np.array([0, eye_L[1] - eye_r - 0.006, eye_L[2]]) - head, (0, 0, 0), "Glasses")
    # beret: puffy dome + rim band + stalk; origin at the bottom centre
    b = Builder(); wine = (0.35, 0.15, 0.2)
    b.lathe([(0.112, 0.0), (0.135, 0.014), (0.14, 0.03), (0.128, 0.046), (0.1, 0.06), (0.06, 0.068), (0, 0.071)], color=wine, seg=40)
    b.torus(0.112, 0.008, at=(0, 0, 0.004), color=(0.28, 0.11, 0.16), seg=40, seg2=8)
    b.cylinder(0.004, 0.018, at=(0, 0, 0.078), color=wine, seg=8)
    # rim (R 0.112) sits where the head is that wide: ~3 cm above the eye line, not on the crown
    save("hat_beret", b.finish("acc_hat_beret", mat, smooth=True), "head", np.array([0, float(L.get("head_c", [0, -0.1, 0])[1]) + 0.005, float(L.get("eye_z", head_top[2] - 0.12)) + 0.035]) - head, (0, 8, 0), "Beret")
    # hairpin: bar + star; origin at the centre
    b = Builder(); gold = (0.9, 0.75, 0.25)
    b.box((0.05, 0.003, 0.004), color=gold)
    b.cylinder(0.0015, 0.05, at=(0, 0.002, -0.001), color=gold, rot=rot(0, 90, 0), seg=6)
    b.star(0.011, 0.0048, 0.004, at=(0.017, -0.003, 0.001), color=(0.95, 0.5, 0.6), rot=rot(90, 0, 0))
    save("hairpin", b.finish("acc_hairpin", mat), "head", np.array([0.05, -0.085, head_top[2] - 0.06]) - head, (0, 0, -25), "Hairpin")
    # headband: thin arc over the head; origin at the head top centre
    b = Builder()
    # arc in the ear-to-ear (x-z) plane, apex up: turn the arc's middle to +y first, then tilt the ring plane upright
    band_rot = Matrix.Rotation(math.radians(90), 4, "X") @ Matrix.Rotation(math.radians(90), 4, "Z") @ scale(1, 1, 1.6)
    b.torus(hw + 0.004, 0.0045, at=(0, 0, 0), color=(0.2, 0.2, 0.55), rot=band_rot, arc=math.radians(200), seg=48, seg2=8)
    save("headband", b.finish("acc_headband", mat, smooth=True), "head", np.array([0, -0.02, head_top[2] - 0.098]) - head, (0, 0, 0), "Headband")
    # necklace: chain torus (tilted, front lower) + bail ring + teardrop pendant; origin at the neck base centre
    b = Builder(); chain = (0.9, 0.8, 0.35)
    b.torus(0.075, 0.0025, at=(0, 0, 0), color=chain, rot=rot(10, 0, 0), seg=56, seg2=6)
    b.torus(0.005, 0.0015, at=(0, -0.076, -0.017), color=chain, rot=rot(0, 90, 0), seg=12, seg2=6)
    b.lathe([(0, 0.0), (0.005, -0.004), (0.0085, -0.011), (0.007, -0.018), (0.003, -0.023), (0, -0.025)], at=(0, -0.078, -0.021), color=(0.3, 0.5, 0.9), seg=20, scale_xy=(1, 0.6))
    save("necklace", b.finish("acc_necklace", mat, smooth=True), "neck", np.array([0, -0.02, 0.02]), (0, 0, 0), "Necklace")
    # cat ears: two curved cones with a pink inner ear; origin at the head top centre
    b = Builder(); fur = (0.3, 0.25, 0.3); pink = (0.95, 0.6, 0.7)
    for s in (1, -1):
        b.curved_cone((s * 0.06, 0.0, 0.015), (s * 0.095, -0.005, 0.10), 0.034, (s * 0.012, 0.004, 0.0), color=fur, seg=16, n=8, flat=0.55)
        b.curved_cone((s * 0.06, -0.008, 0.024), (s * 0.086, -0.011, 0.082), 0.02, (s * 0.008, 0.002, 0.0), color=pink, seg=12, n=6, flat=0.35)
    save("cat_ears", b.finish("acc_cat_ears", mat, smooth=True), "head", np.array([0, 0.005, head_top[2] - 0.03]) - head, (0, 0, 0), "Cat ears")
    # bag: origin on the shoulder; strap loop in the front-back plane over the shoulder, box hanging
    # beside the hip (thin in x, its flat face outward), flap + buckle on the outer face
    b = Builder(); leather = (0.45, 0.3, 0.2); dark = (0.35, 0.22, 0.15)
    bx = hip_x - 0.155 + 0.05
    b.box((0.07, 0.22, 0.16), at=(bx, 0, -0.42), color=leather)
    b.box((0.012, 0.225, 0.075), at=(bx + 0.034, 0, -0.375), color=dark)
    b.box((0.006, 0.03, 0.02), at=(bx + 0.043, 0, -0.395), color=(0.9, 0.8, 0.35))
    b.torus(0.21, 0.006, at=(bx * 0.5, 0, -0.21), color=dark, rot=rot(0, 90, 0) @ scale(1, 0.7, 1), seg=48, seg2=8)
    save("bag", b.finish("acc_bag", mat), "spine03", np.array([0.155, 0.0, 0.18]), (0, 0, 0), "Bag")
    return out


# --------------------------------------------------------------------------
# studio items
# --------------------------------------------------------------------------
def items(mat):
    out = {}

    def save(name, ob, category, display=None, extras=None):
        path = os.path.join(A_ITEMS, "item_%s.glb" % name)
        info = export_static(ob, path, extras or {})
        out[name] = dict(file=os.path.relpath(path, REPO), bytes=os.path.getsize(path), category=category, name=display or name.replace("_", " ").title(), tris=info["meshes"][0]["tris"])
        bpy.data.objects.remove(ob)

    grey = (0.75, 0.75, 0.78)
    # primitives (1 m scale, resting on the floor)
    b = Builder(); b.box((1, 1, 1), at=(0, 0, 0.5), color=grey); save("cube", b.finish("item_cube", mat), "Primitives", "Cube")
    b = Builder(); b.sphere(0.5, at=(0, 0, 0.5), color=grey, seg=32, rings=20); save("sphere", b.finish("item_sphere", mat, smooth=True), "Primitives", "Sphere")
    b = Builder(); b.cylinder(0.5, 1.0, at=(0, 0, 0.5), color=grey, seg=32); save("cylinder", b.finish("item_cylinder", mat, smooth=True), "Primitives", "Cylinder")
    b = Builder(); b.plane(2, 2, color=grey); save("plane", b.finish("item_plane", mat), "Primitives", "Plane")
    b = Builder(); b.torus(0.5, 0.15, at=(0, 0, 0.15), color=grey, seg=40, seg2=16); save("torus", b.finish("item_torus", mat, smooth=True), "Primitives", "Torus")
    b = Builder()
    for i in range(5):
        b.box((1.0, 0.3, 0.2 * (i + 1)), at=(0, -0.6 + 0.3 * i, 0.1 * (i + 1)), color=grey)
    save("stairs", b.finish("item_stairs", mat), "Primitives", "Stairs")
    # furniture
    wood = (0.55, 0.38, 0.24); dark = (0.3, 0.22, 0.16); fabric = (0.4, 0.45, 0.6); white = (0.92, 0.92, 0.9)
    b = Builder()
    b.box((0.45, 0.45, 0.04), at=(0, 0, 0.44), color=wood); b.box((0.45, 0.04, 0.45), at=(0, 0.205, 0.68), color=wood)
    for x in (-0.19, 0.19):
        for y in (-0.19, 0.19):
            b.box((0.04, 0.04, 0.42), at=(x, y, 0.21), color=dark)
    save("chair", b.finish("item_chair", mat), "Furniture", "Chair")
    b = Builder()
    b.box((1.2, 0.6, 0.04), at=(0, 0, 0.73), color=wood)
    for x in (-0.55, 0.55):
        b.box((0.05, 0.5, 0.71), at=(x, 0, 0.355), color=dark)
    b.box((1.1, 0.04, 0.3), at=(0, 0.25, 0.55), color=dark)
    save("desk", b.finish("item_desk", mat), "Furniture", "Desk")
    b = Builder()
    b.box((1.1, 2.0, 0.25), at=(0, 0, 0.125), color=dark); b.box((1.05, 1.95, 0.18), at=(0, 0, 0.34), color=white)
    b.box((1.1, 0.08, 0.8), at=(0, 1.0, 0.4), color=dark); b.box((0.5, 0.35, 0.1), at=(0, 0.75, 0.48), color=(0.95, 0.95, 0.98))
    b.box((1.0, 1.4, 0.06), at=(0, -0.2, 0.46), color=(0.5, 0.6, 0.8))
    save("bed", b.finish("item_bed", mat), "Furniture", "Bed")
    b = Builder()
    b.box((1.8, 0.85, 0.35), at=(0, 0, 0.175), color=fabric); b.box((1.8, 0.2, 0.5), at=(0, 0.33, 0.6), color=fabric)
    for x in (-0.8, 0.8):
        b.box((0.2, 0.85, 0.55), at=(x, 0, 0.275), color=fabric)
    for x in (-0.4, 0.4):
        b.box((0.7, 0.6, 0.12), at=(x, -0.05, 0.41), color=(0.5, 0.55, 0.7))
    save("sofa", b.finish("item_sofa", mat), "Furniture", "Sofa")
    b = Builder()
    b.cylinder(0.5, 0.04, at=(0, 0, 0.73), color=wood, seg=32); b.cylinder(0.05, 0.7, at=(0, 0, 0.36), color=dark, seg=16); b.cylinder(0.3, 0.03, at=(0, 0, 0.015), color=dark, seg=32)
    save("table", b.finish("item_table", mat, smooth=False), "Furniture", "Table")
    # room shells (interior faces visible: flipped normals on the walls)
    wall = (0.9, 0.9, 0.88); floor = (0.7, 0.6, 0.5)

    def room(name, w, d, h, floor_col, wall_col, windows=(), door=None, display=None):
        b = Builder()
        b.box((w, d, 0.02), at=(0, 0, -0.01), color=floor_col)
        b.box((w, d, 0.02), at=(0, 0, h + 0.01), color=wall_col)
        # walls with rectangular window gaps: split into segments
        def wall_x(y, sgn):  # wall along x at y
            gaps = [g for g in windows if g[0] == ("back" if sgn > 0 else "front")]
            for _, x0, x1, z0, z1 in gaps:
                b.box((x1 - x0, 0.1, z0), at=((x0 + x1) / 2, y, z0 / 2), color=wall_col)
                b.box((x1 - x0, 0.1, h - z1), at=((x0 + x1) / 2, y, (h + z1) / 2), color=wall_col)
                b.box((x1 - x0, 0.02, z1 - z0), at=((x0 + x1) / 2, y, (z0 + z1) / 2), color=(0.7, 0.85, 1.0), alpha=0.0)
            xs = sorted([x for g in gaps for x in (g[1], g[2])])
            edges = [-w / 2] + xs + [w / 2]
            for i in range(0, len(edges) - 1, 2):
                x0, x1 = edges[i], edges[i + 1]
                b.box((x1 - x0, 0.1, h), at=((x0 + x1) / 2, y, h / 2), color=wall_col)
        wall_x(d / 2, 1); wall_x(-d / 2, -1)
        for sx in (-1, 1):
            if door and door[0] == ("left" if sx < 0 else "right"):
                _, y0, y1 = door
                b.box((0.1, y0 + d / 2, h), at=(sx * w / 2, (-d / 2 + y0) / 2, h / 2), color=wall_col)
                b.box((0.1, d / 2 - y1, h), at=(sx * w / 2, (y1 + d / 2) / 2, h / 2), color=wall_col)
                b.box((0.1, y1 - y0, h - 2.1), at=(sx * w / 2, (y0 + y1) / 2, (h + 2.1) / 2), color=wall_col)
            else:
                b.box((0.1, d, h), at=(sx * w / 2, 0, h / 2), color=wall_col)
        save(name, b.finish("item_" + name, mat), "Rooms", display, extras={"room": True})

    room("room_classroom", 9.0, 7.0, 3.0, (0.75, 0.65, 0.5), wall,
         windows=[("back", -3.5, -1.5, 0.9, 2.4), ("back", -1.0, 1.0, 0.9, 2.4), ("back", 1.5, 3.5, 0.9, 2.4)], door=("right", -3.0, -2.0), display="Classroom")
    room("room_bedroom", 5.0, 4.0, 2.6, (0.8, 0.7, 0.55), (0.95, 0.9, 0.85), windows=[("back", -0.8, 0.8, 1.0, 2.2)], door=("left", 0.5, 1.4), display="Bedroom")
    # street: ground, sidewalk, two building blocks
    b = Builder()
    b.box((30, 8, 0.02), at=(0, 0, -0.01), color=(0.35, 0.35, 0.37)); b.box((30, 3, 0.15), at=(0, 5.5, 0.075), color=(0.7, 0.7, 0.68))
    b.box((30, 3, 0.15), at=(0, -5.5, 0.075), color=(0.7, 0.7, 0.68))
    for x, wdt, hgt, col in ((-8, 8, 9, (0.8, 0.75, 0.7)), (2, 6, 6, (0.75, 0.8, 0.85)), (10, 7, 12, (0.85, 0.8, 0.75))):
        b.box((wdt, 6, hgt), at=(x, 10, hgt / 2), color=col)
    for x in range(-12, 13, 8):
        b.cylinder(0.08, 5, at=(x, 4.2, 2.5), color=(0.3, 0.3, 0.3), seg=8)
    save("room_street", b.finish("item_room_street", mat), "Rooms", "Street", extras={"room": True})
    # sky dome: inverted sphere with a vertical colour gradient in COLOR_0
    b = Builder(); b.sphere(60.0, at=(0, 0, 0), color=(0.55, 0.75, 1.0), seg=48, rings=24)
    ob = b.finish("item_sky_dome", mat, flip=True, smooth=True)
    me = ob.data
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
    t = np.clip(co[:, 2] / 60.0, -1, 1)
    col = np.ones((len(co), 4), np.float32)
    top = np.array([0.35, 0.55, 0.95]); hor = np.array([0.85, 0.92, 1.0]); low = np.array([0.6, 0.65, 0.7])
    for i in range(len(co)):
        col[i, :3] = hor + (top - hor) * smoothstep(0.0, 0.7, t[i]) if t[i] >= 0 else hor + (low - hor) * smoothstep(0.0, 0.5, -t[i])
    me.color_attributes["Col"].data.foreach_set("color", col.ravel())
    save("sky_dome", ob, "Sky", "Sky dome", extras={"sky": True})
    return out


def main():
    bl_reset()
    mat = bl_material("ik_item", (0.9, 0.9, 0.9, 1))
    acc = accessories(mat)
    it = items(mat)
    write_json(os.path.join(OUT, "accessories_summary.json"), acc)
    write_json(os.path.join(OUT, "items_summary.json"), it)
    log("accessories:", {k: v["bytes"] for k, v in acc.items()})
    log("items:", {k: v["bytes"] for k, v in it.items()})


if __name__ == "__main__":
    main()
