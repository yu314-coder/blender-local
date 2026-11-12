# A low-poly landscape: a displaced grid, flat-shaded, with trees and water.
import bpy, random
from _common import clear, mat, camera, world, finish

clear()
random.seed(7)
bpy.ops.mesh.primitive_grid_add(x_subdivisions=40, y_subdivisions=40, size=20)
land = bpy.context.active_object
land.name = "Land"
for v in land.data.vertices:
    x, y = v.co.x, v.co.y
    v.co.z = max(-0.4, 1.6 * (1 - (x * x + y * y) / 120) + random.uniform(-0.25, 0.35))
land.data.materials.append(mat("Grass", (0.30, 0.55, 0.22), 0.9))
bpy.ops.mesh.primitive_plane_add(size=22, location=(0, 0, -0.1))
bpy.context.active_object.name = "Water"
bpy.context.active_object.data.materials.append(mat("Water", (0.1, 0.35, 0.6), 0.1))
trunk, leaves = mat("Trunk", (0.35, 0.2, 0.1), 0.9), mat("Leaves", (0.12, 0.4, 0.15), 0.8)
for i in range(18):
    x, y = random.uniform(-6, 6), random.uniform(-6, 6)
    z = 1.6 * (1 - (x * x + y * y) / 120)
    bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.08, depth=0.6, location=(x, y, z + 0.3))
    bpy.context.active_object.name = f"Trunk {i + 1}"
    bpy.context.active_object.data.materials.append(trunk)
    bpy.ops.mesh.primitive_cone_add(vertices=6, radius1=0.45, depth=1.2, location=(x, y, z + 1.1))
    bpy.context.active_object.name = f"Tree {i + 1}"
    bpy.context.active_object.data.materials.append(leaves)
bpy.ops.object.light_add(type="SUN", rotation=(0.9, 0.1, 0.8))
bpy.context.active_object.data.energy = 4
world((0.55, 0.75, 1.0), 0.9)
camera((11, -11, 7), (0, 0, 0.5), 32)
finish(select=land)
print("Template: Low-Poly Landscape")
