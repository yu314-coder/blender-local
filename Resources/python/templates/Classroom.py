# A classroom: rows of desks and chairs, a chalkboard, windows letting in the sun.
import bpy, math
from _common import clear, mat, box, camera, world, finish

clear()
wood = mat("Wood", (0.45, 0.28, 0.14), 0.55)
metal = mat("Steel", (0.55, 0.57, 0.6), 0.35, 1.0)
wall = mat("Wall", (0.86, 0.83, 0.76), 0.8)
floor = mat("Floor", (0.32, 0.22, 0.14), 0.45)
board = mat("Chalkboard", (0.06, 0.16, 0.11), 0.9)
frame = mat("Board Frame", (0.30, 0.20, 0.12), 0.6)
glass = mat("Window", (0.75, 0.88, 1.0), 0.05, emit=2.0)
chalk = mat("Chalk", (0.95, 0.95, 0.92), 0.9)

W, D, H = 10.0, 12.0, 3.4
box("Floor", (W, D, 0.1), (0, 0, -0.05), floor)
box("Ceiling", (W, D, 0.1), (0, 0, H + 0.05), wall)
box("Back Wall", (W, 0.2, H), (0, D / 2, H / 2), wall)
box("Front Wall", (W, 0.2, H), (0, -D / 2, H / 2), wall)
box("Right Wall", (0.2, D, H), (W / 2, 0, H / 2), wall)
# The left wall: windows between pillars.
for i, y in enumerate((-4.5, -1.5, 1.5, 4.5)):
    box(f"Window {i + 1}", (0.05, 2.2, 1.8), (-W / 2, y, 1.9), glass)
for i, y in enumerate((-6, -3, 0, 3, 6)):
    box(f"Pillar {i + 1}", (0.25, 0.8, H), (-W / 2, y, H / 2), wall)
box("Sill", (0.3, D, 1.0), (-W / 2, 0, 0.5), wall)
box("Lintel", (0.3, D, 0.5), (-W / 2, 0, H - 0.25), wall)

# Chalkboard on the back wall, with a line of chalk writing.
box("Chalkboard", (5.0, 0.05, 1.6), (0, D / 2 - 0.12, 1.8), board)
box("Board Frame", (5.2, 0.08, 0.08), (0, D / 2 - 0.14, 0.98), frame)
bpy.ops.object.text_add(location=(-1.6, D / 2 - 0.16, 1.7), rotation=(math.radians(90), 0, 0))
t = bpy.context.active_object
t.name = "Lesson"
t.data.body = "E = mc²"
t.data.size = 0.45
t.data.materials.append(chalk)

def desk(x, y, n):
    box(f"Desk {n} Top", (1.1, 0.6, 0.05), (x, y, 0.74), wood)
    for dx in (-0.5, 0.5):
        for dy in (-0.25, 0.25):
            box(f"Desk {n} Leg", (0.04, 0.04, 0.72), (x + dx, y + dy, 0.36), metal)
    cy = y - 0.6
    box(f"Chair {n} Seat", (0.45, 0.42, 0.04), (x, cy, 0.45), wood)
    box(f"Chair {n} Back", (0.45, 0.04, 0.4), (x, cy - 0.2, 0.75), wood)
    for dx in (-0.2, 0.2):
        for dy in (-0.18, 0.18):
            box(f"Chair {n} Leg", (0.03, 0.03, 0.44), (x + dx, cy + dy, 0.22), metal)

n = 1
for row in range(4):
    for col in range(3):
        desk(-2.6 + col * 2.6, 2.6 - row * 2.0, n)
        n += 1
box("Teacher's Desk", (1.8, 0.8, 0.8), (2.5, 4.6, 0.4), wood)

bpy.ops.object.light_add(type="SUN", rotation=(math.radians(55), math.radians(-35), math.radians(-70)))
sun = bpy.context.active_object
sun.name = "Sun"
sun.data.energy = 4.0
for i, y in enumerate((-3, 0, 3)):
    bpy.ops.object.light_add(type="AREA", location=(0, y, H - 0.1))
    l = bpy.context.active_object
    l.name = f"Ceiling Light {i + 1}"
    l.data.energy = 120
    l.data.size = 1.2
world((0.6, 0.72, 0.9), 0.6)
cam = camera((3.6, -5.6, 1.7), (-0.6, 3.5, 1.2), 22)
finish(select=cam)
print("Template: Classroom")
