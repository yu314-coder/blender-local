"""The keys build 58 added that Blender runs, run by the Blender they run on.

scripts/run-keymenus-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: no user settings and no 3D View area in the context,
as for the bpy module on a device. Every string run here is the one the Swift
sends, printed by tests/keymenus/blender/main.swift, and each result is held
to what Blender's own operator does with the same arguments.
"""
import bpy, bmesh, sys, types, pathlib
from mathutils import Matrix, Vector

sys.dont_write_bytecode = True
CALLS = sys.argv[sys.argv.index("--") + 1:][0]
ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Resources" / "python" / "site"))
# The app's own module, which `_blenderkit_anim` imports; nothing here calls it.
sys.modules["_blenderkit"] = types.ModuleType("_blenderkit")
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head.strip()] = body


def run(name):
    """A block as the bridge runs it: `bpy` in scope, errors raised."""
    exec(compile(blocks[name], name, "exec"), {"bpy": bpy, "__name__": "__main__"})


def raises(name):
    try:
        run(name)
    except Exception as error:  # noqa: BLE001 - the words are what is checked
        return str(error)
    return None


def fresh():
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.context.scene.frame_set(1)


def counts(obj):
    bm = bmesh.from_edit_mesh(obj.data)
    return len(bm.verts), len(bm.edges), len(bm.faces)


def faces(obj):
    bpy.ops.object.mode_set(mode='OBJECT')
    out = sorted(tuple(sorted(p.vertices)) for p in obj.data.polygons)
    bpy.ops.object.mode_set(mode='EDIT')
    return out


# --- Alt+F, Fill -----------------------------------------------------------
fresh()
bpy.ops.mesh.primitive_circle_add(vertices=8)
circle = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
run("FILL")
check("Fill fills an 8-sided circle with 6 faces", counts(circle) == (8, 13, 6), counts(circle))
said = raises("FILL")
check("Fill again says it found no loop to fill",
      said is not None and "found no loop of selected edges" in said, said)
bpy.ops.mesh.select_all(action='DESELECT')
said = raises("FILL")
check("Fill with nothing selected passes Blender's own words on",
      said is not None and "No edges selected" in said, said)

# --- Shift+Ctrl+T and Ctrl+T ------------------------------------------------
for name, quad, ngon in (("TRIANGULATE_FIXED", 'FIXED', 'CLIP'), ("TRIANGULATE", 'BEAUTY', 'BEAUTY')):
    fresh()
    bpy.ops.mesh.primitive_cylinder_add(vertices=8)
    obj = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    run(name)
    ours = faces(obj)
    fresh()
    bpy.ops.mesh.primitive_cylinder_add(vertices=8)
    obj = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.quads_convert_to_tris(quad_method=quad, ngon_method=ngon)
    theirs = faces(obj)
    check("%s lays the triangles Blender's %s/%s does" % (name, quad, ngon),
          ours == theirs and len(ours) == 28, (len(ours), len(theirs)))
check("Shift+Ctrl+T's call names Fixed and Clip",
      "quad_method='FIXED'" in blocks["TRIANGULATE_FIXED"] and "ngon_method='CLIP'" in blocks["TRIANGULATE_FIXED"],
      blocks["TRIANGULATE_FIXED"])

# --- Ctrl+G, Vertex Groups --------------------------------------------------
fresh()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
cube.name = "Cube"
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
run("ASSIGN_NEW")
bpy.ops.object.mode_set(mode='OBJECT')
weights = sorted({round(g.weight, 3) for v in cube.data.vertices for g in v.groups})
check("Assign to New Group makes Group, active, with every selected vertex at the Weight",
      [g.name for g in cube.vertex_groups] == ['Group'] and cube.vertex_groups.active_index == 0
      and all(len(v.groups) == 1 for v in cube.data.vertices) and weights == [0.5],
      ([g.name for g in cube.vertex_groups], weights))
bpy.ops.object.mode_set(mode='EDIT')
run("ASSIGN_NEW")
check("Assign to New Group again makes Group.001, active",
      [g.name for g in cube.vertex_groups] == ['Group', 'Group.001'] and cube.vertex_groups.active_index == 1,
      [g.name for g in cube.vertex_groups])
run("SET_ACTIVE_GROUP")
check("Set Active Group makes Group active", cube.vertex_groups.active_index == 0, cube.vertex_groups.active_index)
run("REMOVE_FROM_ALL")
bpy.ops.object.mode_set(mode='OBJECT')
check("Remove from All takes the selection out of every group",
      all(len(v.groups) == 0 for v in cube.data.vertices), [len(v.groups) for v in cube.data.vertices])
bpy.ops.object.mode_set(mode='EDIT')
said = raises("REMOVE_FROM_ALL")
check("Remove from All with nothing to remove says so",
      said is not None and "None of the selected vertices is in a vertex group" in said, said)
cube.vertex_groups[0].lock_weight = True
said = raises("REMOVE_FROM_ALL")
check("Remove from All with the active group locked says so, as Blender's poll does",
      said is not None and "locked" in said, said)
cube.vertex_groups[0].lock_weight = False

# --- K, Insert Keyframe Menu --------------------------------------------------
fresh()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
from io import StringIO
import contextlib


def rows():
    buffer = StringIO()
    with contextlib.redirect_stdout(buffer):
        run("KEYING_ROWS")
    return [line for line in buffer.getvalue().splitlines() if line]


selected = rows()
check("K offers Blender's 19 keying sets with an object selected, Available first",
      len(selected) == 19 and selected[0] == "Available\tAvailable" and "Scaling\tScale" in selected,
      selected[:4])
cube.select_set(False)
unselected = rows()
check("K offers 18 with nothing selected (no Available)",
      len(unselected) == 18 and not any(r.startswith("Available") for r in unselected), len(unselected))
cube.select_set(True)
bpy.context.scene.frame_set(4)
run("KEYING_LOCATION")
action = cube.animation_data.action if cube.animation_data else None


def curves():
    bag = None
    for layer in action.layers:
        for strip in layer.strips:
            bag = strip.channelbag(cube.animation_data.action_slot)
    return sorted((f.data_path, f.array_index, [tuple(k.co) for k in f.keyframe_points]) for f in bag.fcurves)


check("K ▸ Location keys location at the frame",
      action is not None and [c[:2] for c in curves()] == [('location', 0), ('location', 1), ('location', 2)]
      and all(c[2] == [(4.0, 0.0)] for c in curves()), curves() if action else None)
run("KEYING_LOCROTSCALE")
check("K ▸ Location, Rotation & Scale keys all nine channels",
      len(curves()) == 9, len(curves()))

# --- Ctrl+M, Interactive Mirror ---------------------------------------------
check("Mirror's panel: Mirror, Orientation and Constraint Axis",
      blocks["MIRROR_PANEL"] == "Mirror\nOrientation|X|Y|Z", blocks["MIRROR_PANEL"])


def close(a, b, eps=1e-4):
    return all(abs(x - y) < eps for ra, rb in zip(a, b) for x, y in zip(ra, rb))


fresh()
bpy.ops.mesh.primitive_cube_add(location=(2, 0, 0), rotation=(0, 0, 0.7))
cube = bpy.context.object
before = cube.matrix_world.copy()
run("MIRROR_X_GLOBAL")
bpy.context.view_layer.update()
reflect = Matrix.Translation((1, 0, 0)) @ Matrix.Diagonal((-1, 1, 1, 1)) @ Matrix.Translation((-1, 0, 0))
check("Mirror X Global flips the object about the pivot's plane",
      close(cube.matrix_world, reflect @ before), cube.matrix_world)

fresh()
bpy.ops.mesh.primitive_cube_add(location=(2, 0, 0), rotation=(0, 0, 0.7))
cube = bpy.context.object
before = cube.matrix_world.copy()
run("MIRROR_YZ_LOCAL")
bpy.context.view_layer.update()
local = before.to_3x3().normalized()
flip = local @ Matrix.Diagonal((1, -1, -1)) @ local.transposed()
check("Mirror locking Local X turns the object half round its own X, about the pivot",
      close(cube.matrix_world.to_3x3(), flip @ before.to_3x3())
      and (cube.matrix_world.translation - Vector((2, 0, 0))).length < 1e-4, cube.matrix_world)

fresh()
bpy.ops.mesh.primitive_cube_add(location=(-3, 0, 0))
a = bpy.context.object
bpy.ops.mesh.primitive_cube_add(location=(3, 1, 0))
b = bpy.context.object
a.select_set(True)
run("MIRROR_X_INDIVIDUAL")
bpy.context.view_layer.update()
check("Mirror about Individual Origins flips each object in place",
      (a.matrix_world.translation - Vector((-3, 0, 0))).length < 1e-4
      and (b.matrix_world.translation - Vector((3, 1, 0))).length < 1e-4
      and a.matrix_world[0][0] < 0 and b.matrix_world[0][0] < 0, (a.matrix_world, b.matrix_world))

fresh()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
before = sorted(tuple(round(c, 4) for c in v.co) for v in cube.data.vertices)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
run("MIRROR_Z_EDIT")
bpy.ops.object.mode_set(mode='OBJECT')
after = sorted(tuple(round(c, 4) for c in v.co) for v in cube.data.vertices)
expected = sorted((x, y, round(1 - z, 4)) for x, y, z in before)
check("Mirror Z Global in Edit Mode flips the vertices about the pivot (z 0.5)",
      after == expected, after[:2])

print("\n%d failed" % fail)
sys.exit(1 if fail else 0)
