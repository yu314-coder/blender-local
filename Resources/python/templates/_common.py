# Shared helpers for the starter scenes in File ▸ New ▸ Templates. Each
# template script starts from Blender's startup file (File ▸ New ▸ General)
# and builds its scene with bpy, so nothing is downloaded.
import bpy, math
from mathutils import Vector

def clear():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)

def mat(name, rgb, rough=0.5, metal=0.0, emit=0.0, alpha=1.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes.get("Principled BSDF")
    p.inputs["Base Color"].default_value = (*rgb, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    if emit:
        p.inputs["Emission Color"].default_value = (*rgb, 1)
        p.inputs["Emission Strength"].default_value = emit
    if alpha < 1:
        p.inputs["Alpha"].default_value = alpha
    m.diffuse_color = (*rgb, 1)
    return m

def box(name, size, loc, material, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    o.data.materials.append(material)
    return o

def camera(loc, target, lens=35):
    bpy.ops.object.camera_add(location=loc)
    c = bpy.context.active_object
    c.rotation_euler = (Vector(target) - c.location).to_track_quat("-Z", "Y").to_euler()
    c.data.lens = lens
    bpy.context.scene.camera = c
    return c

def world(rgb, strength=1.0):
    sc = bpy.context.scene
    w = sc.world or bpy.data.worlds.new("World")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    if bg:
        bg.inputs["Color"].default_value = (*rgb, 1)
        bg.inputs["Strength"].default_value = strength

def finish(engine="BLENDER_EEVEE", res=(1920, 1080), select=None):
    sc = bpy.context.scene
    sc.render.engine = engine
    sc.render.resolution_x, sc.render.resolution_y = res
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    if select is not None:
        select.select_set(True)
        bpy.context.view_layer.objects.active = select
