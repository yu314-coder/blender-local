"""The scene the points check runs on, built the same way twice: once to hand
the Swift the control points it picks and drags from (`dump`), once in the
Blender that runs what the Swift sent (verify.py).

    Circle   a Bézier circle at (2, 0, 0), turned 0.3 about Z, scaled 1.5:
             four points, Auto handles
    Bez      a Bézier curve at (0, 3, 0): two points, Aligned handles
    Path     a NURBS path at (0, -3, 0): five points, joined by its polygon
    Lattice  object.add(type='LATTICE'), resolution 3 x 2 x 2, scaled 2.5,
             deforming Cube through a Lattice modifier
    Free     a Bézier curve of two points at (-4, -1, 0.5), turned 0.3 about
             Z, with Free handles of unequal length: (-1, 0.5, 0), (0, 0, 0),
             (3, 0, 0) and (5, 2, 0), (6, 1, 0), (8, 1, 0) — where the mean
             of a tapped knot's three entries is not the knot
    Rider    an empty riding Bez by Follow Path (fixed position 0): moved by
             Bez's points, not deformed by them
"""
import bpy, json, sys, pathlib, importlib.util

ROOT = pathlib.Path(__file__).resolve().parents[3]


def build():
    bpy.ops.wm.read_factory_settings(use_empty=False)
    bpy.ops.curve.primitive_bezier_circle_add(radius=1, location=(2, 0, 0), rotation=(0, 0, 0.3))
    circle = bpy.context.object
    circle.name = "Circle"
    circle.scale = (1.5, 1.5, 1.5)
    bpy.ops.curve.primitive_bezier_curve_add(radius=1, location=(0, 3, 0))
    bpy.context.object.name = "Bez"
    bpy.ops.curve.primitive_nurbs_path_add(location=(0, -3, 0))
    bpy.context.object.name = "Path"
    bpy.ops.object.add(type='LATTICE', location=(0, 0, 0))
    lattice = bpy.context.object
    lattice.name = "Lattice"
    lattice.data.points_u = 3
    lattice.scale = (2.5, 2.5, 2.5)
    cube = bpy.data.objects["Cube"]
    modifier = cube.modifiers.new("Lattice", 'LATTICE')
    modifier.object = lattice
    data = bpy.data.curves.new("Free", 'CURVE')
    data.dimensions = '3D'
    spline = data.splines.new('BEZIER')
    spline.bezier_points.add(1)
    for point, (left, knot, right) in zip(spline.bezier_points, (((-1, 0.5, 0), (0, 0, 0), (3, 0, 0)),
                                                                 ((5, 2, 0), (6, 1, 0), (8, 1, 0)))):
        point.handle_left_type = point.handle_right_type = 'FREE'
        point.co, point.handle_left, point.handle_right = knot, left, right
    free = bpy.data.objects.new("Free", data)
    bpy.context.scene.collection.objects.link(free)
    free.location = (-4, -1, 0.5)
    free.rotation_euler = (0, 0, 0.3)
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.object.empty_add(location=(0, 0, 0))
    rider = bpy.context.object
    rider.name = "Rider"
    follow = rider.constraints.new('FOLLOW_PATH')
    follow.target = bpy.data.objects["Bez"]
    follow.use_fixed_location = True
    follow.offset_factor = 0.0
    bpy.context.view_layer.update()
    return {name: bpy.data.objects[name] for name in ("Circle", "Bez", "Path", "Lattice", "Cube", "Free", "Rider")}


def edit(obj):
    """Into Edit Mode on `obj` alone, as the app's Edit Curve / Edit Lattice
    puts Blender there."""
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode='EDIT')


def load_points():
    spec = importlib.util.spec_from_file_location(
        "_blenderkit_points", ROOT / "Resources/python/site/_blenderkit_points.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["_blenderkit_points"] = module
    spec.loader.exec_module(module)
    return module


if __name__ == "__main__":
    out = sys.argv[sys.argv.index("--") + 1]
    points = load_points()
    objects = build()
    cages = {}
    for name in ("Circle", "Bez", "Path", "Lattice", "Free"):
        obj = objects[name]
        edit(obj)
        positions, flags, lines = points.cage(obj)
        cages[name] = dict(type=obj.type, positions=list(positions), flags=list(flags), lines=list(lines),
                           matrix=[c for row in obj.matrix_world for c in row],
                           record=points.record(obj))
        bpy.ops.object.mode_set(mode='OBJECT')
    json.dump(cages, open(out, "w"))
    print("wrote", out)
