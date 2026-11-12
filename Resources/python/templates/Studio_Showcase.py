# A product-shot studio: a pedestal, a few primitives and soft area lights.
import bpy, math
from _common import clear, mat, camera, world, finish

clear()
bpy.ops.mesh.primitive_plane_add(size=16)
bpy.context.active_object.name = "Floor"
bpy.context.active_object.data.materials.append(mat("Floor", (0.8, 0.78, 0.74), 0.6))
bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=1.6, depth=0.5, location=(0, 0, 0.25))
ped = bpy.context.active_object
ped.name = "Pedestal"
ped.data.materials.append(mat("Pedestal", (0.12, 0.13, 0.16), 0.25))
ped.modifiers.new("Bevel", "BEVEL").width = 0.06
bpy.ops.mesh.primitive_monkey_add(size=2.0, location=(0, 0, 1.38), rotation=(math.radians(-8), 0, math.radians(18)))
suz = bpy.context.active_object
suz.name = "Suzanne"
suz.data.materials.append(mat("Orange", (0.95, 0.38, 0.06), 0.28))
suz.modifiers.new("Subdivision", "SUBSURF").levels = 2
bpy.ops.object.shade_smooth()
for name, op, loc, rgb in (("Torus", "torus", (3.0, -1.2, 0.28), (0.05, 0.55, 0.6)),
                           ("Sphere", "sphere", (-2.7, -1.0, 0.7), (0.9, 0.9, 0.92)),
                           ("Cone", "cone", (2.4, 2.0, 0.7), (0.98, 0.78, 0.12))):
    if op == "torus":
        bpy.ops.mesh.primitive_torus_add(major_radius=0.85, minor_radius=0.28, location=loc)
    elif op == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=0.7, location=loc)
    else:
        bpy.ops.mesh.primitive_cone_add(vertices=48, radius1=0.6, depth=1.4, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.data.materials.append(mat(name, rgb, 0.08 if op == "sphere" else 0.3, 1.0 if op == "sphere" else 0.0))
    bpy.ops.object.shade_smooth()
for name, loc, rot, energy, size in (("Key Light", (4.5, -4.5, 6), (45, 0, 45), 900, 4),
                                     ("Fill Light", (-5, 2, 4), (55, 0, -110), 220, 6)):
    bpy.ops.object.light_add(type="AREA", location=loc, rotation=tuple(math.radians(a) for a in rot))
    l = bpy.context.active_object
    l.name = name
    l.data.energy = energy
    l.data.size = size
world((0.55, 0.62, 0.72), 0.35)
camera((0, -9.5, 4.2), (0, 0, 1.1), 40)
finish(engine="CYCLES", select=suz)
print("Template: Studio Showcase")
