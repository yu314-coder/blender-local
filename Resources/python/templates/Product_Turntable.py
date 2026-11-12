# A turntable: a smooth object spinning once over 120 frames, lit for render.
import bpy, math
from mathutils import Vector
from _common import clear, mat, camera, world, finish

clear()
bpy.ops.mesh.primitive_cylinder_add(vertices=96, radius=3, depth=0.2, location=(0, 0, -0.1))
bpy.context.active_object.name = "Turntable"
bpy.context.active_object.data.materials.append(mat("Base", (0.08, 0.08, 0.09), 0.3))
bpy.ops.object.empty_add(location=(0, 0, 0))
pivot = bpy.context.active_object
pivot.name = "Pivot"
bpy.ops.mesh.primitive_torus_add(major_radius=1.0, minor_radius=0.35, location=(0, 0, 1.1),
                                 rotation=(math.radians(70), 0, 0))
prod = bpy.context.active_object
prod.name = "Product"
prod.data.materials.append(mat("Gold", (1.0, 0.76, 0.33), 0.2, 1.0))
prod.modifiers.new("Subdivision", "SUBSURF").levels = 2
bpy.ops.object.shade_smooth()
prod.parent = pivot
sc = bpy.context.scene
sc.frame_start, sc.frame_end = 1, 120
pivot.rotation_euler.z = 0
pivot.keyframe_insert("rotation_euler", frame=1)
pivot.rotation_euler.z = math.tau
pivot.keyframe_insert("rotation_euler", frame=121)
for fc in getattr(pivot.animation_data.action, "fcurves", []) or []:
    for k in fc.keyframe_points:
        k.interpolation = "LINEAR"
for name, loc, energy in (("Key", (4, -4, 5), 800), ("Rim", (-4, 4, 4), 600)):
    bpy.ops.object.light_add(type="AREA", location=loc)
    l = bpy.context.active_object
    l.name = name
    l.data.energy = energy
    l.data.size = 3
    # Aimed at the product: a light shines down its own -Z.
    l.rotation_euler = (Vector((0, 0, 1)) - l.location).to_track_quat("-Z", "Y").to_euler()
world((0.05, 0.05, 0.06), 1.0)
camera((0, -10, 3.4), (0, 0, 0.9), 50)
finish(engine="CYCLES", res=(1080, 1080), select=prod)
print("Template: Product Turntable (Render Animation makes the video)")
