"""Verification renders.

Blender mode (renders):
  Blender -b --factory-startup --python verify.py -- body f      # front/side with bones, face, eye close-ups, morph tiles
  Blender -b --factory-startup --python verify.py -- hair        # every hair on body_f
  Blender -b --factory-startup --python verify.py -- clothes     # every garment on the body
  Blender -b --factory-startup --python verify.py -- items       # accessories + items
Plain python mode (compose contact sheets from tiles with Pillow):
  python3 verify.py sheet
Outputs go to Tools/assets/out/verify/*.png
"""
import sys, os, math, json, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import *

TILES = os.path.join(VERIFY, "tiles")
os.makedirs(TILES, exist_ok=True)

MAT_COLORS = {"ik_skin_body": (0.93, 0.85, 0.80, 1), "ik_eye": (1, 1, 1, 1), "ik_eyelash": (0.12, 0.08, 0.12, 1), "ik_eyebrow": (0.35, 0.22, 0.22, 1),
              "ik_mouth": (0.95, 0.9, 0.9, 1), "ik_hair": (0.45, 0.30, 0.55, 1), "ik_cloth": (0.35, 0.45, 0.75, 1), "ik_item": (0.6, 0.6, 0.65, 1),
              "ik_bone": (1.0, 0.15, 0.1, 1), "ik_joint": (1.0, 0.9, 0.1, 1)}


# --------------------------------------------------------------------------
# Blender side
# --------------------------------------------------------------------------
def setup_render(engine="WORKBENCH", res=(900, 1400)):
    import bpy
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH" if engine == "WORKBENCH" else "BLENDER_EEVEE"
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sh = sc.display.shading
    sh.light = "STUDIO"; sh.color_type = "MATERIAL"; sh.show_shadows = False; sh.show_cavity = True
    sh.cavity_type = "BOTH"; sh.curvature_ridge_factor = 0.6; sh.curvature_valley_factor = 0.8
    sh.show_specular_highlight = True
    if sc.world is None:
        sc.world = bpy.data.worlds.new("W")
    sc.world.color = (0.18, 0.18, 0.2)
    cam_data = bpy.data.cameras.new("cam"); cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam); sc.camera = cam
    return sc, cam


def colorize_materials():
    import bpy
    for m in bpy.data.materials:
        for key, col in MAT_COLORS.items():
            if m.name.startswith(key):
                m.diffuse_color = col
                m.roughness = 0.5
        if m.name.startswith("ik_eye") and not m.name.startswith(("ik_eyelash", "ik_eyebrow")):
            m.roughness = 0.15


def look(cam, target, direction, dist, ortho_scale=None, fov=None):
    """Place the camera at target - direction*dist looking at target (Blender Z up)."""
    from mathutils import Vector
    d = Vector(direction).normalized()
    cam.location = Vector(target) - d * dist
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    if ortho_scale:
        cam.data.type = "ORTHO"; cam.data.ortho_scale = ortho_scale
    else:
        cam.data.type = "PERSP"; cam.data.lens = fov or 50


def render(path):
    import bpy
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def bone_overlay(arm, radius=0.006):
    """Thin cylinders for every bone + small spheres at heads, coloured, for the rig render."""
    import bpy, bmesh
    from mathutils import Vector, Matrix
    bm = bmesh.new()
    bm_j = bmesh.new()
    for b in arm.data.bones:
        h = arm.matrix_world @ b.head_local; t = arm.matrix_world @ b.tail_local
        L = (t - h).length
        if L < 1e-5:
            continue
        r = radius if b.use_deform else radius * 0.5
        rot = (t - h).normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
        M = Matrix.Translation(h + (t - h) * 0.5) @ rot
        bmesh.ops.create_cone(bm, cap_ends=True, segments=6, radius1=r, radius2=r * 0.35, depth=L, matrix=M)
        bmesh.ops.create_uvsphere(bm_j, u_segments=8, v_segments=6, radius=r * 1.6, matrix=Matrix.Translation(h))
    def finish(bm, name, mat):
        me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free(); me.materials.append(mat)
        ob = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(ob); return ob
    mb = bpy.data.materials.new("ik_bone"); mb.diffuse_color = MAT_COLORS["ik_bone"]
    mj = bpy.data.materials.new("ik_joint"); mj.diffuse_color = MAT_COLORS["ik_joint"]
    return finish(bm, "bones_overlay", mb), finish(bm_j, "joints_overlay", mj)


def import_glb(path):
    import bpy
    before = {o.name for o in bpy.data.objects}
    bpy.ops.import_scene.gltf(filepath=path)
    new_names = [o.name for o in bpy.data.objects if o.name not in before]
    for n in list(new_names):  # drop importer helper objects (bone shapes)
        o = bpy.data.objects[n]
        if o.type == "MESH" and n.startswith("Icosphere"):
            bpy.data.objects.remove(o); new_names.remove(n)
    return [bpy.data.objects[n] for n in new_names]


def apply_textures_for_preview(sex="f"):
    """Give the preview materials the generated textures (if present) so eye/skin renders are meaningful."""
    import bpy
    tex = A_TEX
    def load(name):
        p = os.path.join(tex, name)
        return bpy.data.images.load(p, check_existing=True) if os.path.exists(p) else None
    for m in bpy.data.materials:
        if not m.use_nodes:
            m.use_nodes = True
        nt = m.node_tree
        bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is None:
            continue
        img = None; alpha = False; tint = None
        if m.name.startswith("ik_skin_body"):
            img = load("skin_%s_base.png" % sex); tint = (1.0, 0.86, 0.78, 1)
        elif m.name.startswith("ik_eyelash"):
            img = load("eyelash_0.png"); alpha = True; tint = (0.18, 0.12, 0.16, 1)
        elif m.name.startswith("ik_eyebrow"):
            img = load("eyebrow_0.png"); alpha = True; tint = (0.42, 0.28, 0.30, 1)
        elif m.name.startswith("ik_eye") :
            # composite: white * shadow, iris over it, highlight over that
            w = load("eye_white.png"); i = load("eye_iris_0.png"); h = load("eye_highlight_0.png")
            if w and i:
                tw = nt.nodes.new("ShaderNodeTexImage"); tw.image = w
                ti = nt.nodes.new("ShaderNodeTexImage"); ti.image = i
                mixc = nt.nodes.new("ShaderNodeMixRGB"); mixc.blend_type = "MULTIPLY"; mixc.inputs["Fac"].default_value = 1.0
                mixc.inputs["Color2"].default_value = (0.55, 0.35, 0.75, 1)  # iris tint
                nt.links.new(ti.outputs["Color"], mixc.inputs["Color1"])
                mix = nt.nodes.new("ShaderNodeMixRGB"); nt.links.new(tw.outputs["Color"], mix.inputs["Color1"])
                nt.links.new(mixc.outputs["Color"], mix.inputs["Color2"]); nt.links.new(ti.outputs["Alpha"], mix.inputs["Fac"])
                last = mix
                if h:
                    th = nt.nodes.new("ShaderNodeTexImage"); th.image = h
                    mix2 = nt.nodes.new("ShaderNodeMixRGB"); nt.links.new(last.outputs["Color"], mix2.inputs["Color1"])
                    nt.links.new(th.outputs["Color"], mix2.inputs["Color2"]); nt.links.new(th.outputs["Alpha"], mix2.inputs["Fac"])
                    last = mix2
                nt.links.new(last.outputs["Color"], bsdf.inputs["Base Color"])
            continue
        if img is not None:
            t = nt.nodes.new("ShaderNodeTexImage"); t.image = img
            if tint:
                mixc = nt.nodes.new("ShaderNodeMixRGB"); mixc.blend_type = "MULTIPLY"; mixc.inputs["Fac"].default_value = 1.0
                mixc.inputs["Color2"].default_value = tint
                nt.links.new(t.outputs["Color"], mixc.inputs["Color1"]); nt.links.new(mixc.outputs["Color"], bsdf.inputs["Base Color"])
            else:
                nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
            if alpha:
                nt.links.new(t.outputs["Alpha"], bsdf.inputs["Alpha"]); m.surface_render_method = "DITHERED"
                m.blend_method = "HASHED" if hasattr(m, "blend_method") else None


def eevee_lights():
    import bpy, math
    sc = bpy.context.scene
    sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 3.0
    so = bpy.data.objects.new("sun", sun); sc.collection.objects.link(so)
    so.rotation_euler = (math.radians(55), math.radians(10), math.radians(-30))
    fill = bpy.data.lights.new("fill", "SUN"); fill.energy = 1.2
    fo = bpy.data.objects.new("fill", fill); sc.collection.objects.link(fo)
    fo.rotation_euler = (math.radians(70), 0, math.radians(150))
    sc.world.use_nodes = True
    bg = sc.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.5, 0.5, 0.55, 1); bg.inputs[1].default_value = 0.6


def verify_body(sex):
    import bpy
    glb = os.path.join(A_CHAR, "body_%s.glb" % sex)
    bl_reset()
    objs = import_glb(glb)
    arm = next(o for o in objs if o.type == "ARMATURE")
    body = bpy.data.objects["body"]
    colorize_materials()
    sc, cam = setup_render()
    zmax = max(v.co.z for v in body.data.vertices)
    centre = (0, 0, zmax / 2)
    # -- plain front/side/back
    look(cam, centre, (0, 1, 0), 5, ortho_scale=zmax * 1.08); render(os.path.join(VERIFY, "body_%s_front.png" % sex))
    look(cam, centre, (-1, 0, 0), 5, ortho_scale=zmax * 1.08); render(os.path.join(VERIFY, "body_%s_side.png" % sex))
    look(cam, centre, (0, -1, 0), 5, ortho_scale=zmax * 1.08); render(os.path.join(VERIFY, "body_%s_back.png" % sex))
    # -- with bones (x-ray)
    bones_ob, joints_ob = bone_overlay(arm)
    sc.display.shading.show_xray = True; sc.display.shading.xray_alpha = 0.35
    look(cam, centre, (0, 1, 0), 5, ortho_scale=zmax * 1.08); render(os.path.join(VERIFY, "body_%s_rig_front.png" % sex))
    look(cam, centre, (-1, 0, 0), 5, ortho_scale=zmax * 1.08); render(os.path.join(VERIFY, "body_%s_rig_side.png" % sex))
    # hand close-up with bones
    hand = arm.matrix_world @ arm.data.bones["hand_L"].head_local
    look(cam, hand, (0, 1, 0.3), 2, ortho_scale=0.28); render(os.path.join(VERIFY, "body_%s_rig_hand.png" % sex))
    sc.display.shading.show_xray = False
    bpy.data.objects.remove(bones_ob); bpy.data.objects.remove(joints_ob)
    # -- face close-ups
    head_top = arm.matrix_world @ arm.data.bones["head_top"].head_local
    eye = arm.matrix_world @ arm.data.bones["eye_L"].head_local
    face_c = (0, eye.y, eye.z - 0.04)
    sc.render.resolution_x, sc.render.resolution_y = 900, 900
    look(cam, face_c, (0, 1, 0), 2, ortho_scale=0.30); render(os.path.join(VERIFY, "body_%s_face_front.png" % sex))
    look(cam, face_c, (-0.8, 0.6, -0.1), 2, ortho_scale=0.30); render(os.path.join(VERIFY, "body_%s_face_34.png" % sex))
    look(cam, face_c, (-1, 0, 0), 2, ortho_scale=0.30); render(os.path.join(VERIFY, "body_%s_face_side.png" % sex))
    # -- morph tiles (workbench)
    sc.render.resolution_x, sc.render.resolution_y = 300, 300
    sk = body.data.shape_keys
    others = {o.name: o for o in objs if o.type == "MESH" and o.name != "body"}
    for kb in sk.key_blocks[1:]:
        name = kb.name
        kb.value = 1.0
        for o in others.values():
            if o.data.shape_keys and name in o.data.shape_keys.key_blocks:
                o.data.shape_keys.key_blocks[name].value = 1.0
        if name.startswith("body."):
            look(cam, centre, (0, 1, 0), 5, ortho_scale=zmax * 1.08)
        elif name.startswith("ear."):
            look(cam, face_c, (-1, 0, 0), 2, ortho_scale=0.26)
        else:
            look(cam, face_c, (-0.35, 1, -0.1), 2, ortho_scale=0.24)
        render(os.path.join(TILES, "morph_%s_%s.png" % (sex, name)))
        kb.value = 0.0
        for o in others.values():
            if o.data.shape_keys and name in o.data.shape_keys.key_blocks:
                o.data.shape_keys.key_blocks[name].value = 0.0
    # -- textured eye close-up (Eevee) if textures exist
    if os.path.exists(os.path.join(A_TEX, "eye_iris_0.png")):
        apply_textures_for_preview(sex)
        eevee_lights()
        sc.render.engine = "BLENDER_EEVEE"
        sc.render.resolution_x, sc.render.resolution_y = 900, 900
        look(cam, face_c, (0, 1, 0), 2, ortho_scale=0.30); render(os.path.join(VERIFY, "body_%s_face_textured.png" % sex))
        look(cam, (0, eye.y, eye.z), (0, 1, 0), 1, ortho_scale=0.16); render(os.path.join(VERIFY, "body_%s_eyes_closeup.png" % sex))
        look(cam, (0, eye.y, eye.z), (-0.5, 1, 0.2), 1, ortho_scale=0.16); render(os.path.join(VERIFY, "body_%s_eyes_closeup_34.png" % sex))
        sc.render.resolution_x, sc.render.resolution_y = 900, 1400
        look(cam, centre, (0, 1, 0), 5, ortho_scale=zmax * 1.08); render(os.path.join(VERIFY, "body_%s_textured_front.png" % sex))
    log("body verify renders done")


def apply_body_mask(body, mask_png):
    """Preview of the engine's body mask: delete body faces whose corners all sample white."""
    import bpy, bmesh
    img = bpy.data.images.load(mask_png, check_existing=True)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32); img.pixels.foreach_get(px); px = px.reshape(h, w, 4)[:, :, 0]   # rows bottom-up = v up
    me = body.data
    uv = me.uv_layers.active.data
    n = len(me.vertices); hidden = np.zeros(n, bool); seen = np.zeros(n, bool)
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            if seen[vi]:
                continue
            u, v = uv[li].uv
            hidden[vi] = px[min(max(int(v * h), 0), h - 1), min(max(int(u * w), 0), w - 1)] > 0.5; seen[vi] = True
    kill = [p.index for p in me.polygons if all(hidden[me.loops[li].vertex_index] for li in p.loop_indices)]
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in kill], context="FACES")
    bm.to_mesh(me); bm.free(); me.update()
    return len(kill), int(hidden.sum())


def verify_on_body(kind, sex="f", only=None):
    """Render every hair/garment/accessory file on top of body_f (workbench); `only` = glob filter."""
    import bpy, math
    folder = {"hair": A_HAIR, "clothes": A_CLOTH, "accessories": A_ACC}[kind]
    files = sorted(glob.glob(os.path.join(folder, (only or "*") + ".glb")))
    for f in files:
        bl_reset()
        base = os.path.splitext(os.path.basename(f))[0]
        sex = "m" if (base.endswith("_m") or base.endswith("_m_cm")) and os.path.exists(os.path.join(A_CHAR, "body_m.glb")) else "f"
        import_glb(os.path.join(A_CHAR, "body_%s.glb" % sex))
        body = bpy.data.objects["body"]
        arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
        new = import_glb(f)
        for o in new:
            if o.type == "ARMATURE":
                bpy.data.objects.remove(o)  # accessory/garment carries its own copy of the skeleton for preview
        colorize_materials()
        sc, cam = setup_render(res=(700, 1100))
        zmax = max(v.co.z for v in body.data.vertices)
        name = os.path.splitext(os.path.basename(f))[0]
        if kind == "accessories":
            head = arm.matrix_world @ arm.data.bones["head"].head_local
            # accessories are exported at their attach point: place at bone head + defaultOffset (glTF axes -> Blender)
            for o in new:
                if o.type == "MESH":
                    parent = o.get("defaultParent") or o.data.get("defaultParent") or "head"
                    off = list(o.get("defaultOffset") or o.data.get("defaultOffset") or (0, 0, 0))
                    rot = list(o.get("defaultRotation") or o.data.get("defaultRotation") or (0, 0, 0))
                    bh = arm.matrix_world @ arm.data.bones[parent].head_local
                    o.parent = None
                    o.location = (bh.x + off[0], bh.y - off[2], bh.z + off[1])
                    o.rotation_euler = (math.radians(rot[0]), math.radians(-rot[2]), math.radians(rot[1]))
            on_head = all((o.get("defaultParent") or o.data.get("defaultParent") or "head") in ("head", "neck") for o in new if o.type == "MESH")
            if on_head:
                look(cam, (0, head.y, head.z), (-0.6, 1, -0.15), 2, ortho_scale=0.45)
                render(os.path.join(VERIFY, "%s.png" % name))
                look(cam, (0, head.y, head.z - 0.1), (0, 1, 0), 2, ortho_scale=0.6)
            else:
                look(cam, (0, 0, zmax * 0.62), (-0.6, 1, -0.15), 4, ortho_scale=zmax * 0.85)
                render(os.path.join(VERIFY, "%s.png" % name))
                look(cam, (0, 0, zmax * 0.62), (0, 1, 0), 4, ortho_scale=zmax * 0.85)
            name = name + "_front"
        elif kind == "clothes":
            bm = f[:-4] + "_bm.png"
            if os.path.exists(bm):
                nk, nh = apply_body_mask(body, bm)
                log("  body mask %s: %d hidden verts, %d faces removed" % (os.path.basename(bm), nh, nk))
            look(cam, (0, 0, zmax / 2), (-0.5, 1, -0.05), 5, ortho_scale=zmax * 1.08)
            render(os.path.join(VERIFY, "%s.png" % name))
            look(cam, (0, 0, zmax / 2), (0.6, -1, -0.05), 5, ortho_scale=zmax * 1.08)
            name = name + "_back"
        elif kind == "hair":
            head = arm.matrix_world @ arm.data.bones["head"].head_local
            look(cam, (0, head.y, head.z - 0.05), (-0.6, 1, -0.15), 2, ortho_scale=0.5)
            render(os.path.join(VERIFY, "%s_34.png" % name))
            look(cam, (0, head.y, head.z - 0.05), (0, 1, 0), 2, ortho_scale=0.5)
            render(os.path.join(VERIFY, "%s.png" % name))
            look(cam, (0, head.y, head.z - 0.05), (0, -1, 0), 2, ortho_scale=0.5)
            name = name + "_back"
        else:
            look(cam, (0, 0, zmax / 2), (-0.5, 1, -0.05), 5, ortho_scale=zmax * 1.08)
        render(os.path.join(VERIFY, "%s.png" % name))
        log("rendered", name)


def verify_items():
    import bpy
    files = sorted(glob.glob(os.path.join(A_ITEMS, "*.glb")))
    bl_reset()
    sc, cam = setup_render(res=(1400, 900))
    x = 0.0
    for f in files:
        new = import_glb(f)
        name = os.path.splitext(os.path.basename(f))[0]
        if "room" in name or "sky" in name:
            for o in new:
                bpy.data.objects.remove(o)
            continue
        mesh_obs = [o for o in new if o.type == "MESH"]
        w = max(max((o.dimensions.x for o in mesh_obs), default=1), 0.5)
        for o in mesh_obs:
            o.location.x += x + w / 2
        x += w + 0.4
    colorize_materials()
    look(cam, (x / 2, 0, 0.6), (-0.3, 1, -0.5), 20, ortho_scale=x + 1)
    render(os.path.join(VERIFY, "items_lineup.png"))
    for f in files:
        name = os.path.splitext(os.path.basename(f))[0]
        if "room" in name or "sky" in name:
            bl_reset(); sc, cam = setup_render(res=(1200, 800))
            new = import_glb(f); colorize_materials()
            look(cam, (0, 0, 1.2), (-0.5, 1, -0.4), 12, ortho_scale=9 if "room" in name else 30)
            render(os.path.join(VERIFY, "%s.png" % name))
    log("items verify done")


# --------------------------------------------------------------------------
# plain python: contact sheets
# --------------------------------------------------------------------------
def compose_sheet(pattern, out, cols=8, label_strip=22):
    from PIL import Image, ImageDraw, ImageFont
    files = sorted(glob.glob(pattern))
    if not files:
        log("no tiles for", pattern); return
    tiles = [Image.open(f).convert("RGB") for f in files]
    w, h = tiles[0].size
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * w, rows * (h + label_strip)), (30, 30, 34))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 13)
    except Exception:
        font = ImageFont.load_default()
    for i, (f, t) in enumerate(zip(files, tiles)):
        r, c = divmod(i, cols)
        sheet.paste(t, (c * w, r * (h + label_strip) + label_strip))
        name = os.path.basename(f).rsplit(".", 1)[0]
        name = name.split("_", 2)[-1] if name.startswith("morph_") else name
        d.text((c * w + 4, r * (h + label_strip) + 4), name, fill=(240, 240, 240), font=font)
    sheet.save(out)
    log("sheet", os.path.relpath(out, REPO), "%d tiles" % len(tiles))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    what = argv[0] if argv else "body"
    if what == "sheet":
        for sex in ("f", "m"):
            if glob.glob(os.path.join(TILES, "morph_%s_*.png" % sex)):
                compose_sheet(os.path.join(TILES, "morph_%s_face*.png" % sex), os.path.join(VERIFY, "morphs_%s_face.png" % sex))
                compose_sheet(os.path.join(TILES, "morph_%s_eye*.png" % sex), os.path.join(VERIFY, "morphs_%s_eye.png" % sex))
                compose_sheet(os.path.join(TILES, "morph_%s_nose*.png" % sex), os.path.join(VERIFY, "morphs_%s_nose.png" % sex))
                compose_sheet(os.path.join(TILES, "morph_%s_mouth*.png" % sex), os.path.join(VERIFY, "morphs_%s_mouth.png" % sex))
                compose_sheet(os.path.join(TILES, "morph_%s_ear*.png" % sex), os.path.join(VERIFY, "morphs_%s_ear.png" % sex))
                compose_sheet(os.path.join(TILES, "morph_%s_body*.png" % sex), os.path.join(VERIFY, "morphs_%s_body.png" % sex))
                compose_sheet(os.path.join(TILES, "morph_%s_exp*.png" % sex), os.path.join(VERIFY, "morphs_%s_exp.png" % sex))
        return
    if what == "body":
        verify_body(argv[1] if len(argv) > 1 else "f")
    elif what in ("hair", "clothes", "accessories"):
        verify_on_body(what, only=argv[1] if len(argv) > 1 else None)
    elif what == "items":
        verify_items()


if __name__ == "__main__":
    main()
