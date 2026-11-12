# An animated bouncing ball: keyframes with easing, squash and stretch.
import bpy
from _common import clear, mat, camera, world, finish

clear()
bpy.ops.mesh.primitive_plane_add(size=20)
bpy.context.active_object.name = "Ground"
bpy.context.active_object.data.materials.append(mat("Ground", (0.25, 0.45, 0.3), 0.8))
bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=0.5, location=(-4, 0, 3))
ball = bpy.context.active_object
ball.name = "Ball"
ball.data.materials.append(mat("Ball", (0.9, 0.15, 0.12), 0.3))
bpy.ops.object.shade_smooth()
sc = bpy.context.scene
sc.frame_start, sc.frame_end = 1, 72
x, height = -4.0, 3.0
for i, f in enumerate(range(1, 73, 12)):
    up = i % 2 == 0
    ball.location = (x + i * 1.4, 0, height * (0.75 ** (i // 2)) if up else 0.5)
    ball.scale = (1, 1, 1) if up else (1.25, 1.25, 0.7)
    ball.keyframe_insert("location", frame=f)
    ball.keyframe_insert("scale", frame=f)
bpy.ops.object.light_add(type="SUN", rotation=(0.8, 0.2, 0.6))
bpy.context.active_object.data.energy = 3
world((0.6, 0.75, 0.95), 0.8)
camera((0, -12, 2.5), (0, 0, 1.2), 35)
finish(select=ball)
print("Template: Bouncing Ball (press Space to play)")
