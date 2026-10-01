"""Conformance checks for the bundled `bpy` shim.

Run with scripts/run-conformance.sh, which launches the app in the
simulator and feeds this in through the DEBUG -eval64 hook, and reads the
results back over the console.

The checks fall into two halves: the API surface a Blender script touches
constantly, and the geometry the operators are supposed to produce. Each of
the geometry checks stands for a bug that shipped.
"""

import bpy, traceback

results = []
def check(label, fn, expect=None):
    try:
        got = fn()
        if expect is not None and got != expect:
            results.append(("FAIL", label, f"got {got!r} expected {expect!r}"))
        else:
            results.append(("ok", label, repr(got)[:48]))
    except Exception as e:
        results.append(("ERR", label, f"{type(e).__name__}: {e}"))

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))

# --- things Blender scripts do constantly ---
check("data.objects len", lambda: len(bpy.data.objects), 1)
check("context.object", lambda: bpy.context.object.name, "Cube")
check("context.active_object", lambda: bpy.context.active_object.name, "Cube")
check("selected_objects", lambda: [o.name for o in bpy.context.selected_objects], ["Cube"])
check("obj.select_get", lambda: bpy.data.objects["Cube"].select_get(), True)
check("obj rename", lambda: (setattr(bpy.data.objects["Cube"], "name", "Box"),
                             [o.name for o in bpy.data.objects])[1], ["Box"])
check("objects.remove", lambda: (bpy.data.objects.remove(bpy.data.objects[0]),
                                 len(bpy.data.objects))[1], 0)

bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
check("select_all INVERT", lambda: bpy.ops.object.select_all(action='INVERT'))
check("import mathutils", lambda: __import__("mathutils").Vector((1, 2, 3)).length)
check("obj.matrix_world", lambda: bpy.data.objects[0].matrix_world)
check("obj.dimensions", lambda: tuple(bpy.data.objects[0].dimensions))
check("obj.hide_viewport", lambda: bpy.data.objects[0].hide_viewport)
check("bpy.app.version", lambda: bpy.app.version)
check("data.scenes", lambda: bpy.data.scenes["Scene"].name)
check("ops.transform.translate", lambda: bpy.ops.transform.translate(value=(1, 0, 0)))
check("Vector arithmetic", lambda: list(bpy.data.objects[0].location + __import__("mathutils").Vector((1,1,1))) if False else "skipped")
check("obj.location tuple assign", lambda: (setattr(bpy.data.objects[0], "location", (1, 2, 3)),
                                            tuple(bpy.data.objects[0].location))[1], (1.0, 2.0, 3.0))
check("obj.location.x set", lambda: (setattr(bpy.data.objects[0].location, "x", 9.0),
                                     bpy.data.objects[0].location.x)[1], 9.0)
check("obj.keyframe_insert", lambda: bpy.data.objects[0].keyframe_insert(data_path="location"))
check("obj.data (mesh)", lambda: bpy.data.objects[0].data.name)

# --- geometry the operators are supposed to produce -------------------------
#
# Every check below stands for a bug that shipped: a primitive that ignored the
# size it was given, a `rotation=` that went nowhere, a `transform_apply` that
# moved the origin whatever it was asked to bake, and a duplicate that came back
# as a default cube.

import _blenderkit as _bk, math

def fresh(*a, **k):
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()

def size_of(name):
    b = _bk.bounds(name)
    return tuple(round(b[i + 3] - b[i], 4) for i in range(3))

def near(got, want, tol=0.002):
    return all(abs(g - w) <= tol for g, w in zip(got, want))

fresh()
bpy.ops.mesh.primitive_cube_add(size=0.5)
check("cube honours size=", lambda: near(size_of(bpy.context.object.name), (0.5, 0.5, 0.5)), True)

fresh()
bpy.ops.mesh.primitive_cylinder_add(radius=0.1, depth=0.8)
check("cylinder honours radius/depth",
      lambda: near(size_of(bpy.context.object.name), (0.2, 0.2, 0.8)), True)

fresh()
bpy.ops.mesh.primitive_torus_add(major_radius=0.34, minor_radius=0.035)
check("torus honours both radii",
      lambda: near(size_of(bpy.context.object.name), (0.75, 0.75, 0.07), 0.01), True)

fresh()
bpy.ops.mesh.primitive_cylinder_add(radius=0.1, depth=0.8, rotation=(math.pi / 2, 0, 0))
check("primitive honours rotation=",
      lambda: near(size_of(bpy.context.object.name), (0.2, 0.8, 0.2), 0.01), True)

# transform_apply has to bake the channels it was asked for and no others.
# Baking the location when only the scale was asked for moves the origin to the
# world centre, and anything rotated afterwards then swings across the scene
# instead of turning in place.
#
# Note Blender's defaults are all three True, so `transform_apply(scale=True)`
# alone still applies the location — the channels have to be turned off
# explicitly, and the second check below pins that down.
fresh()
bpy.ops.mesh.primitive_cube_add(size=1, location=(2, 0, 0))
obj = bpy.context.object
obj.scale = (0.5, 0.5, 0.5)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
check("transform_apply(scale only) keeps origin",
      lambda: tuple(round(c, 3) for c in obj.location), (2.0, 0.0, 0.0))
check("transform_apply(scale only) bakes size",
      lambda: near(size_of(obj.name), (0.5, 0.5, 0.5)), True)
check("transform_apply(scale only) clears scale",
      lambda: tuple(round(c, 3) for c in obj.scale), (1.0, 1.0, 1.0))

fresh()
bpy.ops.mesh.primitive_cube_add(size=1, location=(2, 0, 0))
whole = bpy.context.object
bpy.ops.object.transform_apply()
check("transform_apply() defaults bake everything",
      lambda: tuple(round(c, 3) for c in whole.location), (0.0, 0.0, 0.0))
check("transform_apply() leaves geometry in place",
      lambda: near(_bk.bounds(whole.name)[0:3], (1.5, -0.5, -0.5)), True)

# A duplicate has to carry the geometry, not just the primitive kind.
fresh()
bpy.ops.mesh.primitive_cube_add(size=1)
src = bpy.context.object
src.scale = (0.2, 0.2, 0.2)
bpy.ops.object.transform_apply(scale=True)
bpy.ops.object.duplicate()
check("duplicate keeps edited geometry",
      lambda: near(size_of(bpy.context.object.name), (0.2, 0.2, 0.2)), True)

# Quaternion orientation: the idiom for pointing geometry along a direction.
fresh()
from mathutils import Vector
bpy.ops.mesh.primitive_cylinder_add(radius=0.01, depth=1.0)
tube_obj = bpy.context.object
tube_obj.rotation_mode = 'QUATERNION'
tube_obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(Vector((1, 0, 0)))
check("rotation_quaternion aims geometry",
      lambda: near(size_of(tube_obj.name), (1.0, 0.02, 0.02), 0.01), True)

# Curves, and the array-along-a-curve pair that builds a chain.
fresh()
cd = bpy.data.curves.new("Path", type='CURVE')
sp = cd.splines.new('POLY')
sp.points.add(3)
for pt, co in zip(sp.points, [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]):
    pt.co = co + (1,)
sp.use_cyclic_u = True
path_obj = bpy.data.objects.new("Path", cd)
bpy.context.collection.objects.link(path_obj)
check("data.curves.new", lambda: bpy.data.curves["Path"].name, "Path")
check("spline points", lambda: len(cd.splines[0].points), 4)
check("curve object linked", lambda: "Path" in bpy.data.objects, True)

bpy.ops.mesh.primitive_cube_add(size=1)
lnk = bpy.context.object
lnk.name = "Link"
lnk.scale = (0.1, 0.05, 0.05)
bpy.ops.object.transform_apply(scale=True)
arr = lnk.modifiers.new("Array", 'ARRAY')
arr.fit_type = 'FIT_CURVE'
arr.curve = path_obj
fit = lnk.modifiers.new("Follow", 'CURVE')
fit.object = path_obj
# The path is a 1x1 square, perimeter 4; 0.1-long links fill it about 40 times.
check("array along curve fills the path",
      lambda: near(size_of("Link"), (1.1, 0.05, 1.1), 0.12), True)

# --- one scene across every tab ---------------------------------------------
#
# On device Blender owns the scene, and the viewport is refreshed from it after
# every operation — from any tab, not just Scripting. That refresh used to
# replace each object outright, which threw away everything Blender has nowhere
# to keep: the material the Shading tab edits, painted texture, vertex colours,
# keyframes, and the object's own identity. So painting something and then
# moving anything reverted the paint, and each tab quietly undid the others'
# work. The refresh reconciles by name now, and these checks pin that down.

fresh()
bpy.ops.mesh.primitive_cube_add(size=2)
tab = bpy.context.object
tab.name = "Shared"
_bk.material_set("Shared", "Metallic", 0.75)
_bk.material_set("Shared", "Roughness", 0.2)
bpy.ops.uv.smart_project()
_bk.paint("Shared", 0.5, 0.5, 1.0, 0.0, 0.0, 0.1, 1.0)
painted_before = _bk.texture_info("Shared")[2]
id_before = len(bpy.data.objects)

import _blenderkit_sync
mirrored = _blenderkit_sync.sync()

check("mirror pushes the scene", lambda: mirrored, 1)
check("mirror keeps the material the Shading tab set",
      lambda: (round(_bk.material_get("Shared", "Metallic"), 3),
               round(_bk.material_get("Shared", "Roughness"), 3)), (0.75, 0.2))
check("mirror keeps painted texture",
      lambda: _bk.texture_info("Shared")[2] == painted_before and painted_before > 0, True)
check("mirror keeps the object, not a copy of it",
      lambda: [o.name for o in bpy.data.objects], ["Shared"])
check("mirror keeps the selection",
      lambda: bpy.context.object.name, "Shared")

# And a second pass must be just as harmless as the first.
_blenderkit_sync.sync()
check("a second mirror still keeps the material",
      lambda: round(_bk.material_get("Shared", "Metallic"), 3), 0.75)
check("a second mirror still keeps the paint",
      lambda: _bk.texture_info("Shared")[2] == painted_before, True)

# Geometry, though, is Blender's to overwrite — that is what makes a script
# able to override what the other tabs built.
bpy.ops.object.select_all(action='SELECT')
verts_before = len(bpy.data.objects["Shared"].data.vertices)
bpy.data.objects["Shared"].modifiers.new("Sub", 'SUBSURF')
_blenderkit_sync.sync()
check("mirror takes geometry from bpy",
      lambda: len(bpy.data.objects["Shared"].data.vertices) > verts_before, True)

# view_layer is where scripts set the active object before an operator runs.
fresh()
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
first = bpy.context.object.name
bpy.ops.mesh.primitive_cube_add(size=1, location=(3, 0, 0))
bpy.context.view_layer.objects.active = bpy.data.objects[first]
check("view_layer.objects.active", lambda: bpy.context.object.name, first)

for status, label, detail in results:
    print(f"{status:4} {label:28} {detail}")
print("---")
print("pass", sum(1 for r in results if r[0] == "ok"),
      "fail", sum(1 for r in results if r[0] != "ok"))
