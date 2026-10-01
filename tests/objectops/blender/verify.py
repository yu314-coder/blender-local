"""Object ▸ Duplicate Linked, Join, Parent, Clear Parent and Convert, the Mesh
menu's new rows, and Shear, run by the Blender they run on.

scripts/run-objectops-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: a window and a screen but no 3D View area in the
context, as for the bpy module on a device. The app's context is built the
way the app builds it: Blender's undo started through the app's own
`_blenderkit_undo.push` (an `ed.undo_push` under the window), and Shear's 3D
View borrowed by `_blenderkit_context.temp_override_view3d`, both loaded from
the source tree. Every string run is the one the Swift sends, printed by
tests/objectops/blender/main.swift: the body `perform` runs, then the history's
push; an adjustment is the history's rewind, the body with the panel's new
values, and a push that replaces the step — what `readjustThroughUndo` does.

After the steps that change what the Outliner shows, the app's own
`_blenderkit_sync.sync()` runs against a `_blenderkit` that records what it is
handed, and the Swift replays that.
"""
import bpy, bmesh, sys, types, json, math, base64, pathlib, importlib.util, contextlib, io, os
from mathutils import Vector

sys.dont_write_bytecode = True
CALLS, RECORDS, WORK = sys.argv[sys.argv.index("--") + 1:][:3]
ROOT = pathlib.Path(__file__).resolve().parents[3]
HISTORY = os.path.join(WORK, "Documents", ".blender-history")
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
        blocks[head[4:].strip()] = body


def b64(data):
    return base64.b64encode(bytes(data)).decode()


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps every call a pass makes."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.calls = []

    def sync_begin(self):
        self.calls = []

    def sync_push(self, name, kind, matrix, positions, normals, triangles, selected, active, rgba):
        self.calls.append(dict(call="push", name=name, kind=kind, matrix=b64(matrix),
                               positions=b64(positions), normals=b64(normals),
                               triangles=b64(triangles), selected=selected, active=active))

    def sync_edges(self, name, edges):
        self.calls.append(dict(call="edges", name=name, edges=b64(edges)))

    def sync_modifiers(self, name, record):
        self.calls.append(dict(call="modifiers", name=name, record=record))

    def sync_display(self, name, type, data_name, record):
        self.calls.append(dict(call="display", name=name, type=type, dataName=data_name, record=record))

    def sync_relations(self, name, parent, names):
        self.calls.append(dict(call="relations", name=name, parent=parent, names=list(names)))

    def sync_knots(self, name, values):
        self.calls.append(dict(call="knots", name=name, values=b64(values)))

    def sync_edit_selection(self, *args):
        pass

    def sync_local(self, name, values):
        pass

    def sync_end(self):
        pass

    def material_set(self, *args):
        pass


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
sync = load("_blenderkit_sync")
load("_blenderkit_undo")

namespace = {"bpy": bpy}


def run(block, **fill):
    """A block of what the Swift sends, in one namespace as the app's
    interpreter keeps: (error text or None, what it printed)."""
    source = blocks[block]
    for key, value in fill.items():
        source = source.replace("@" + key.upper() + "@", str(value))
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(source, "<" + block + ">", "exec"), namespace)
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return str(error).strip(), printed.getvalue()
    return None, printed.getvalue()


def history(block, label=""):
    error, printed = run(block, root=HISTORY, label=label)
    if error:
        raise RuntimeError(block + ": " + error)
    return json.loads([line for line in printed.splitlines() if line.startswith("{")][-1])


def perform(block, label):
    """What `perform` does: the body, then a history step if it worked.
    Returns the error or None."""
    namespace.pop("_bk_adjustable", None)
    error, _ = run(block)
    if error is None:
        check(block + ": the redo panel opens (_bk_adjustable)", namespace.get("_bk_adjustable") is True,
              namespace.get("_bk_adjustable"))
        history("PUSH", label)
    return error


def adjust(block, label):
    """What the panel does with a changed field: back to before the step,
    the body again, and the new step in the old one's place."""
    history("REWIND")
    error, _ = run(block)
    check(block + ": the adjusted run works", error is None, error)
    history("PUSH_REPLACE", label)


def ran(label, block, undo_label):
    error = perform(block, undo_label)
    check(label, error is None, error)


def refused(label, block, words):
    """Refused in words, with nothing changed: the scene's photograph after
    is the photograph before."""
    before = photo()
    error, _ = run(block)
    check(label, error is not None and words in error, error)
    check(label + " — and nothing changed", photo() == before, differences(before, photo()))


def photo():
    for obj in bpy.data.objects:
        if obj.mode == 'EDIT':
            obj.update_from_editmode()
    out = {}
    for obj in bpy.data.objects:
        entry = dict(type=obj.type, parent=obj.parent.name if obj.parent else None,
                     matrix=[round(c, 5) for row in obj.matrix_world for c in row],
                     selected=obj.select_get(), mode=obj.mode,
                     data=obj.data.name if obj.data else None)
        if obj.type == 'MESH':
            me = obj.data
            entry.update(verts=len(me.vertices), faces=len(me.polygons),
                         co=[round(c, 5) for v in me.vertices for c in v.co],
                         vsel=[v.select for v in me.vertices])
        out[obj.name] = entry
    active = bpy.context.view_layer.objects.active
    return dict(objects=out, active=active.name if active else None)


def differences(a, b):
    keys = set(a["objects"]) | set(b["objects"])
    return [k for k in sorted(keys) if a["objects"].get(k) != b["objects"].get(k)] + (
        ["active"] if a["active"] != b["active"] else [])


def depth(obj):
    d = 0
    while obj.parent is not None:
        obj, d = obj.parent, d + 1
    return d


def truth():
    depsgraph = bpy.context.evaluated_depsgraph_get()
    out = {}
    for obj in bpy.context.scene.objects:
        drawn, hidden, disabled = sync.visibility(obj)
        entry = dict(type=obj.type, parent=obj.parent.name if obj.parent else None, depth=depth(obj),
                     drawn=drawn, vertices=0, edges=0, triangles=0)
        if drawn and obj.type in {"MESH", "CURVE", "FONT"}:
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            if mesh is not None:
                mesh.calc_loop_triangles()
                entry.update(vertices=len(mesh.vertices), edges=len(mesh.edges),
                             triangles=len(mesh.loop_triangles))
                evaluated.to_mesh_clear()
        out[obj.name] = entry
    return out


passes = []


def mirror(name):
    sync.sync()
    passes.append(dict(name=name, calls=list(bridge.calls), blender=truth(),
                       order=[o.name for o in bpy.context.scene.objects]))


def fresh():
    """A new empty file, as File ▸ New leaves the app, with Blender's undo
    started again on it."""
    bpy.ops.wm.read_homefile(use_empty=True)
    history("PUSH", "Original")


def only(*objects, active=None):
    for obj in bpy.data.objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active if active is not None else (objects[0] if objects else None)


def cube(name, location=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.data.name = name
    return obj


def O(name):
    return bpy.data.objects[name]


def world(obj):
    bpy.context.view_layer.update()
    return obj.matrix_world.copy()


def moved(a, b):
    return max(abs(x - y) for ra, rb in zip(a, b) for x, y in zip(ra, rb))


print("the app's context")
check("no 3D View area in the context, as for bpy on a device", bpy.context.area is None)
fresh()
check("Blender's undo keeps the history here, as on a device",
      history("PUSH", "probe")["mode"] == "blender")

# --------------------------------------------------------------------------
print("\nObject ▸ Parent")
fresh()
a, b, c = cube("A"), cube("B", (3, 0, 0)), cube("C", (6, 0, 0))
a.rotation_euler = (0, 0, 0.5)
a.scale = (2, 1, 1)
history("PUSH", "Setup")
wb, wc = world(b), world(c)
only(b, c, active=a)
ran("Parent ▸ Object runs, with the parent active and unselected", "PARENT", "Make Parent")
check("B and C are A's children", b.parent == a and c.parent == a, (b.parent, c.parent))
check("and neither moved (Blender sets the parent inverse)",
      moved(world(b), wb) < 1e-5 and moved(world(c), wc) < 1e-5)
mirror("new: parent B and C to A")
only(c, active=b)
ran("Parent C to B: a chain", "PARENT", "Make Parent")
check("C is B's child, B is A's", c.parent == b and b.parent == a)
mirror("C under B under A")
only(a, active=c)
error, _ = run("PARENT")
check("A to its own grandchild is Blender's own refusal", error is not None and "Loop in parents" in error, error)
check("and A still has no parent", a.parent is None)
only(a)
refused("Parent with only the active object selected is refused", "PARENT", "no other object is selected")
only(b)
bpy.context.view_layer.objects.active = None
refused("Parent with no active object is refused", "PARENT", "no object is active")

print("\nKeep Transform, through the redo panel")
fresh()
a, b, c = cube("A"), cube("B", (3, 0, 0)), cube("C", (0, 5, 0))
history("PUSH", "Setup")
only(b, active=a)
ran("Parent B to A", "PARENT", "Make Parent")
a.location = (0, 0, 2)
history("PUSH", "Move")
before = world(b)
only(b, active=c)
ran("then B to C, Keep Transform off", "PARENT", "Make Parent")
off = moved(world(b), before)
check("B moves: it keeps its local transform, now under C (2.0 m, as measured)", abs(off - 2.0) < 1e-4, off)
# A tap is not an undo step in the app, so the step the panel rewinds to has
# the selection from before the taps: B selected with A active. Re-run from
# there, the body alone parents B to A — the defect this measured.
adjust("PARENT_ADJUSTED_KEEP_BODY_ONLY", "Make Parent")
check("(the body alone, from the rewound step, parents B to A — the object active at that step)",
      O("B").parent == O("A"), O("B").parent)
# What the bridge sends: the selection the operator ran on, then the body.
adjust("PARENT_ADJUSTED_KEEP", "Make Parent")
# An undo can reallocate every ID, so objects are fetched again by name.
a, b, c = O("A"), O("B"), O("C")
kept = world(b)
check("the panel's Keep Transform, through undo: B back where it was, still C's child",
      moved(kept, before) < 1e-5 and b.parent == c, (moved(kept, before), b.parent))
mirror("new: B re-parented to C with Keep Transform")
# The same press made first with Keep Transform on gives the same result.
history("UNDO")
a, b, c = O("A"), O("B"), O("C")
check("(undone: B is A's child again)", b.parent == a, b.parent)
only(b, active=c)
error, _ = run("PARENT_KEEP")
check("Object (Keep Transform) pressed first gives the adjusted result exactly",
      error is None and moved(world(b), kept) < 1e-6 and b.parent == c, error)
history("PUSH", "Make Parent")
namespace.pop("_bk_adjustable", None)
only(a, active=c)
run("PARENT_CHECKPOINT")
check("without Blender's undo it still parents, and opens no panel",
      a.parent == c and namespace.get("_bk_adjustable") is False, (a.parent, namespace.get("_bk_adjustable")))

print("\nObject ▸ Parent ▸ Clear")
fresh()
a, b = cube("A", (1, 1, 1)), cube("B", (3, 0, 0))
a.rotation_euler = (0, 0, 0.5)
history("PUSH", "Setup")
only(b, active=a)
ran("Parent B to A", "PARENT", "Make Parent")
wb = world(b)
only(b)
ran("Clear Parent runs", "CLEAR_CLEAR", "Clear Parent")
check("B has no parent and has not moved", b.parent is None and moved(world(b), wb) < 1e-5)
mirror("new: B's parent cleared")
adjust("CLEAR_ADJUSTED_INVERSE", "Clear Parent")
a, b = O("A"), O("B")
check("the panel's Type, Clear Parent Inverse: B keeps A and moves (2.44 m, as measured)",
      b.parent == a and abs(moved(world(b), wb) - 2.4383) < 1e-3, (b.parent, moved(world(b), wb)))
mirror("Clear Parent Inverse instead")
history("UNDO")
a, b = O("A"), O("B")
check("(undone: B is A's child, where it was)", b.parent == a and moved(world(b), wb) < 1e-5, b.parent)
only(b)
ran("Clear and Keep Transformation runs", "CLEAR_CLEAR_KEEP_TRANSFORM", "Clear Parent")
check("B has no parent and has not moved", b.parent is None and moved(world(b), wb) < 1e-5)
only(b)
refused("Clear Parent with nothing that has a parent is refused", "CLEAR_CLEAR", "nothing selected has a parent")

print("\nObject ▸ Duplicate Linked")
fresh()
a = cube("A")
m = a.modifiers.new("Subdivision", 'SUBSURF')
history("PUSH", "Setup")
only(a)
ran("Duplicate Linked runs", "DUP_LINKED", "Duplicate Linked")
dup = bpy.context.view_layer.objects.active
check("A.001 shares A's mesh, selected and active, where A is",
      dup.name == "A.001" and dup.data == a.data and dup.select_get() and not a.select_get()
      and moved(world(dup), world(a)) < 1e-6, (dup.name, dup.data.name))
mirror("new: A duplicated linked")
only()
bpy.context.view_layer.objects.active = None
refused("Duplicate Linked with nothing selected is refused", "DUP_LINKED", "none is selected")

print("\nObject ▸ Join")
fresh()
a, b, c = cube("A"), cube("B", (3, 0, 0)), cube("C", (6, 0, 0))
bpy.ops.object.camera_add(location=(0, -6, 2))
camera = bpy.context.object
history("PUSH", "Setup")
only(b, c, active=a)
refused("Join with the active object not selected is refused (Blender: CANCELLED)", "JOIN",
        "then the one to join into last")
only(a)
refused("Join with nothing else selected is refused (Blender: CANCELLED)", "JOIN",
        "then the one to join into last")
only(a, b, camera, active=camera)
refused("Join into a camera is refused in words, not \"context is incorrect\"", "JOIN", "is a camera")
only()
bpy.context.view_layer.objects.active = None
refused("Join with no active object is refused", "JOIN", "no object is active")
only(a, b, c, active=a)
ran("Join runs", "JOIN", "Join")
check("one mesh of 24 vertices where there were three cubes",
      set(bpy.data.objects.keys()) == {"A", "Camera"} and len(a.data.vertices) == 24,
      (bpy.data.objects.keys(), len(a.data.vertices)))
mirror("new: three cubes joined")
history("UNDO")
check("one undo brings the three cubes back", {"A", "B", "C"} <= set(bpy.data.objects.keys()),
      bpy.data.objects.keys())
check("each with its 8 vertices", all(len(O(n).data.vertices) == 8 for n in "ABC"))

# Hair curves and point clouds join as well; the Add menu makes neither, so a
# script or a file brings them.
fresh()
for name, x in (("P", 0), ("Q", 3)):
    cube(name, (x, 0, 0))
    bpy.ops.object.convert(target='POINTCLOUD')
history("PUSH", "Setup")
only(O("P"), O("Q"), active=O("P"))
ran("Join runs on two point clouds", "JOIN", "Join")
check("one point cloud of 16 points", list(bpy.data.objects.keys()) == ["P"]
      and O("P").type == 'POINTCLOUD' and len(O("P").data.points) == 16,
      (bpy.data.objects.keys(), len(O("P").data.points)))
mirror("new: two point clouds joined")
fresh()
for name in ("H", "I"):
    hair = bpy.data.hair_curves.new(name)
    hair.add_curves([3])
    bpy.context.collection.objects.link(bpy.data.objects.new(name, hair))
history("PUSH", "Setup")
only(O("H"), O("I"), active=O("H"))
ran("Join runs on two hair curves", "JOIN", "Join")
check("one hair-curves object of 6 points", list(bpy.data.objects.keys()) == ["H"]
      and O("H").type == 'CURVES' and len(O("H").data.points) == 6,
      (bpy.data.objects.keys(), len(O("H").data.points)))
mirror("new: two hair curves joined")

print("\nObject ▸ Convert")
fresh()
a = cube("A")
a.modifiers.new("Subdivision", 'SUBSURF').levels = 1
history("PUSH", "Setup")
only(a)
ran("Convert ▸ Mesh runs", "CONVERT_MESH", "Convert To")
check("the Subdivision is applied: 26 vertices, no modifier",
      a.type == 'MESH' and len(a.data.vertices) == 26 and not a.modifiers,
      (len(a.data.vertices), list(a.modifiers)))
adjust("CONVERT_MESH_ADJUSTED_KEEP", "Convert To")
a = O("A")
copy = bpy.context.view_layer.objects.active
check("Keep Original, through the panel: A keeps its modifier, the copy A.001 is the mesh",
      a.modifiers and copy.name == "A.001" and len(copy.data.vertices) == 26 and not copy.modifiers,
      (copy.name, list(a.modifiers)))
mirror("new: Convert to Mesh, keeping the original")

fresh()
a = cube("A")
bpy.ops.mesh.primitive_circle_add(location=(0, 4, 0))
circle = bpy.context.object
bpy.ops.object.text_add(location=(4, 0, 0))
text = bpy.context.object
bpy.ops.object.camera_add(location=(0, -6, 2))
camera = bpy.context.object
history("PUSH", "Setup")
only(a)
refused("Convert ▸ Curve on a cube is refused: every edge is in a face", "CONVERT_CURVE",
        "every edge of A is part of a face")
only(camera)
refused("Convert ▸ Mesh on a camera is refused in words", "CONVERT_MESH", "is a camera")
refused("Convert ▸ Curve on a camera too", "CONVERT_CURVE", "is a camera")
only()
bpy.context.view_layer.objects.active = None
refused("Convert with nothing selected is refused", "CONVERT_MESH", "none is selected")
only(circle)
ran("Convert ▸ Curve on Add ▸ Circle's wire runs", "CONVERT_CURVE", "Convert To")
check("it is a curve of one 32-point spline",
      circle.type == 'CURVE' and [len(s.points) for s in circle.data.splines] == [32],
      (circle.type, [len(s.points) for s in getattr(circle.data, 'splines', [])]))
only(text)
ran("Convert ▸ Mesh on text runs", "CONVERT_MESH", "Convert To")
check("the text is a mesh", text.type == 'MESH' and len(text.data.polygons) > 0, text.type)
mirror("new: a circle and a text converted")
only(a, camera, active=camera)
ran("Convert ▸ Mesh on a cube and a camera runs: the cube converts", "CONVERT_MESH", "Convert To")

# --------------------------------------------------------------------------
print("\nthe Mesh menu's rows")


def grid():
    """A 7 × 7 grid: 49 vertices, 36 faces, everything selected."""
    fresh()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=6, y_subdivisions=6, size=2)
    obj = bpy.context.object
    history("PUSH", "Setup")
    return obj


def selecting(obj, choose):
    """The selection the app's push leaves Blender holding, in object mode."""
    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(obj.data)
    for seq in (bm.verts, bm.edges, bm.faces):
        seq.ensure_lookup_table()
        for element in seq:
            element.select = False
    choose(bm)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)
    bpy.ops.object.mode_set(mode='OBJECT')
    history("PUSH", "Select")


def everything(bm):
    for f in bm.faces:
        f.select = True
    for v in bm.verts:
        v.select = True


def nothing(bm):
    pass


def counts(obj):
    if obj.mode == 'EDIT':
        obj.update_from_editmode()
    return len(obj.data.vertices), len(obj.data.edges), len(obj.data.polygons)


def mesh_row(label, block, scene, expect, undo_label):
    obj = scene()
    error = perform(block, undo_label)
    got = counts(obj)
    check(label, error is None and got == expect, (error, got))
    check(label + " — left in object mode, where it started", obj.mode == 'OBJECT', obj.mode)
    return obj


def whole_grid():
    obj = grid()
    selecting(obj, everything)
    return obj


def four_faces():
    obj = grid()
    selecting(obj, lambda bm: [setattr(bm.faces[i], "select", True) for i in (0, 1, 6, 7)])
    return obj


def whole_cube():
    fresh()
    obj = cube("A")
    history("PUSH", "Setup")
    selecting(obj, everything)
    return obj


mesh_row("Limited Dissolve: the flat grid to its 4 corners and one face", "MESH_limitedDissolve",
         whole_grid, (4, 4, 1), "Limited Dissolve")
mesh_row("Un-Subdivide at 2: 49 vertices to 22", "MESH_unsubdivide", whole_grid, (22, 41, 20), "Un-Subdivide")
adjust("MESH_unsubdivide_1", "Un-Subdivide")
check("its panel's Iterations at 1, through undo: 28, as a first run at 1 gives",
      counts(bpy.context.object) == (28, 52, 25), counts(bpy.context.object))
mesh_row("Edge Split ▸ Faces by Edges: 49 vertices to 144", "MESH_edgeSplitEdges", whole_grid,
         (144, 144, 36), "Edge Split")
mesh_row("Edge Split ▸ Faces & Edges by Vertices: 144 too", "MESH_edgeSplitVertices", whole_grid,
         (144, 144, 36), "Edge Split")
mesh_row("Split ▸ Selection: four faces off as their own island, 49 to 54", "MESH_splitSelection",
         four_faces, (54, 88, 36), "Split")
mesh_row("Edge Split on four faces: 49 to 61", "MESH_edgeSplitEdges", four_faces, (61, 92, 36), "Edge Split")


def loose_bits():
    fresh()
    obj = cube("A")
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    v1, v2 = bm.verts.new((3, 0, 0)), bm.verts.new((4, 0, 0))
    bm.edges.new((v1, v2))
    bm.verts.new((5, 5, 5))
    bm.to_mesh(obj.data)
    bm.free()
    history("PUSH", "Setup")
    selecting(obj, everything)
    return obj


mesh_row("Delete Loose: a loose edge and a loose vertex go, 11 vertices to 8", "MESH_deleteLoose",
         loose_bits, (8, 12, 6), "Delete Loose")
whole_cube()
refused("Delete Loose with nothing loose is refused, and the selection is kept", "MESH_deleteLoose",
        "nothing selected is loose")


def plane_and_cube():
    fresh()
    obj = cube("A")
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    quad = [bm.verts.new((x, y, 3)) for x, y in ((0, 0), (1, 0), (1, 1), (0, 1))]
    bm.faces.new(quad)
    bm.to_mesh(obj.data)
    bm.free()
    history("PUSH", "Setup")
    selecting(obj, everything)
    return obj


mesh_row("Delete Loose with Faces on: a face on its own goes too, 12 to 8", "MESH_deleteLoose_faces",
         plane_and_cube, (8, 12, 6), "Delete Loose")
# With Faces off (the default) Blender removes nothing from a face on its own
# and still clears the selection; the check follows the switch and refuses.
plane_and_cube()
refused("with Faces off (the default) a face on its own is not loose: refused, the selection kept",
        "MESH_deleteLoose", "nothing selected is loose")


def cube_and_vertex():
    fresh()
    obj = cube("A")
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.verts.new((5, 5, 5))
    bm.to_mesh(obj.data)
    bm.free()
    history("PUSH", "Setup")
    selecting(obj, everything)
    return obj


cube_and_vertex()
refused("with Vertices off a vertex on its own is not loose either: refused", "MESH_deleteLoose_noverts",
        "nothing selected is loose")
mesh_row("and with Vertices on it goes, 9 vertices to 8", "MESH_deleteLoose", cube_and_vertex,
         (8, 12, 6), "Delete Loose")


def inner_vertex():
    """One inner vertex of the 7 × 7 grid, and so no edge."""
    obj = grid()
    selecting(obj, lambda bm: setattr(min(bm.verts, key=lambda v: v.co.length), "select", True))
    return obj


obj = mesh_row("Edge Split ▸ Faces & Edges by Vertices on one inner vertex, no edge: 49 to 52",
               "MESH_edgeSplitVertices", inner_vertex, (52, 88, 36), "Edge Split")
inner_vertex()
refused("Faces by Edges on that vertex has no edge to split along: refused", "MESH_edgeSplitEdges",
        "select an edge first")


def two_grids():
    """Two grids in Edit Mode as Edit Mesh leaves two selected meshes: the
    active one with nothing selected, the other with everything."""
    fresh()
    meshes = []
    for name, x in (("A", 0), ("B", 4)):
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=6, y_subdivisions=6, size=2, location=(x, 0, 0))
        bpy.context.object.name = name
        meshes.append(bpy.context.object)
    a, b = meshes
    for obj, choose in ((a, nothing), (b, everything)):
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        for seq in (bm.verts, bm.edges, bm.faces):
            for element in seq:
                element.select = False
        choose(bm)
        bm.select_flush_mode()
        bm.to_mesh(obj.data)
        bm.free()
    only(a, b, active=a)
    bpy.ops.object.mode_set(mode='EDIT')
    history("PUSH", "Setup")
    return a, b


a, b = two_grids()
error = perform("MESH_limitedDissolve", "Limited Dissolve")
check("Limited Dissolve with the selection on the other mesh in Edit Mode runs, and takes it 49 to 4",
      error is None and counts(b) == (4, 4, 1) and counts(a) == (49, 84, 36), (error, counts(a), counts(b)))
bpy.ops.object.mode_set(mode='OBJECT')
a, b = two_grids()
bpy.ops.object.mode_set(mode='OBJECT')
bm = bmesh.new()
bm.from_mesh(b.data)
bm.verts.new((9, 9, 9)).select = True
bm.to_mesh(b.data)
bm.free()
error = perform("MESH_deleteLoose", "Delete Loose")
check("Delete Loose reads every mesh in Edit Mode too: the other mesh's loose vertex goes, 50 to 49",
      error is None and counts(b)[0] == 49 and counts(a)[0] == 49, (error, counts(a), counts(b)))


def holed():
    fresh()
    obj = cube("A")
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[0]], context='FACES_ONLY')
    bm.to_mesh(obj.data)
    bm.free()
    history("PUSH", "Setup")
    selecting(obj, everything)
    return obj


mesh_row("Fill Holes at 4: the missing face is back", "MESH_fillHoles", holed, (8, 12, 6), "Fill Holes")
mesh_row("Fill Holes at 3 leaves a four-sided hole", "MESH_fillHoles_3", holed, (8, 12, 5), "Fill Holes")
mesh_row("Fill Holes at 0 fills any hole", "MESH_fillHoles_0", holed, (8, 12, 6), "Fill Holes")


def wavy_triangles():
    fresh()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=6, y_subdivisions=6, size=2)
    obj = bpy.context.object
    for v in obj.data.vertices:
        v.co.z = 0.3 * math.sin(3 * v.co.x) * math.cos(2 * v.co.y)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.quads_convert_to_tris(quad_method='FIXED')
    bpy.ops.object.mode_set(mode='OBJECT')
    history("PUSH", "Setup")
    return obj


obj = wavy_triangles()
edges_before = {tuple(sorted(e.vertices)) for e in obj.data.edges}
error = perform("MESH_beautifyFaces", "Beautify Faces")
turned = len(edges_before - {tuple(sorted(e.vertices)) for e in obj.data.edges})
check("Beautify Faces turns 18 of the 120 edges of a wavy grid triangulated the fixed way",
      error is None and turned == 18 and counts(obj) == (49, 120, 72), (error, turned, counts(obj)))


def top_face():
    fresh()
    obj = cube("A")
    history("PUSH", "Setup")
    selecting(obj, lambda bm: setattr(max(bm.faces, key=lambda f: f.calc_center_median().z), "select", True))
    return obj


def selected_z(obj):
    return sorted({round(v.co.z, 4) for v in obj.data.vertices if v.select})


obj = mesh_row("Extrude Individual Faces on the top face: 8 vertices to 12", "MESH_extrudeIndividual",
               top_face, (12, 20, 10), "Extrude Individual Faces")
check("out along the normal, to z = 1.2", selected_z(obj) == [1.2], selected_z(obj))
obj = mesh_row("its Offset at -0.2", "MESH_extrudeIndividual_in", top_face, (12, 20, 10),
               "Extrude Individual Faces")
check("goes in, to z = 0.8", selected_z(obj) == [0.8], selected_z(obj))
obj = mesh_row("and Extrude (Along Normals) now starts outward too", "MESH_extrude", top_face,
               (12, 20, 10), "Extrude")
check("to z = 1.2", selected_z(obj) == [1.2], selected_z(obj))
mesh_row("Extrude Individual Faces on the whole cube: each face on its own, 32 vertices",
         "MESH_extrudeIndividual", whole_cube, (32, 60, 30), "Extrude Individual Faces")

mesh_row("Bevel Vertices on a whole cube: 56 vertices, 30 faces", "MESH_bevelVertices", whole_cube,
         (56, 84, 30), "Bevel")
mesh_row("Bevel (Edges) on a whole cube: 56 vertices, 54 faces", "MESH_bevel", whole_cube,
         (56, 108, 54), "Bevel")
mesh_row("Bevel with its Affect at Vertices is Bevel Vertices", "MESH_bevel_VERTICES", whole_cube,
         (56, 84, 30), "Bevel")
mesh_row("Bevel Vertices with its Affect at Edges is Bevel", "MESH_bevelVertices_EDGES", whole_cube,
         (56, 108, 54), "Bevel")


def one_corner():
    fresh()
    obj = cube("A")
    history("PUSH", "Setup")
    selecting(obj, lambda bm: setattr(bm.verts[0], "select", True))
    return obj


mesh_row("Bevel Vertices on one corner: 14 vertices, 9 faces", "MESH_bevelVertices", one_corner,
         (14, 21, 9), "Bevel")
mesh_row("Inset Individual on a whole cube: 32 vertices", "MESH_inset_individual", whole_cube,
         (32, 60, 30), "Inset Faces")
mesh_row("Inset (a region) on the whole cube has no border to inset: 8", "MESH_inset", whole_cube,
         (8, 12, 6), "Inset Faces")
mesh_row("Inset Individual on four faces of a grid: 65", "MESH_inset_individual", four_faces,
         (65, 116, 52), "Inset Faces")
mesh_row("Inset (a region) on the same four faces: 57", "MESH_inset", four_faces, (57, 100, 44), "Inset Faces")

print("\nthe rows that act on a selection refuse an empty one, and change nothing")
for block, words in [("MESH_limitedDissolve", "select something first"),
                     ("MESH_splitSelection", "select something first"),
                     ("MESH_unsubdivide", "select something first"),
                     ("MESH_edgeSplitEdges", "select an edge first"),
                     ("MESH_edgeSplitVertices", "select a vertex first"),
                     ("MESH_fillHoles", "select an edge first"),
                     ("MESH_beautifyFaces", "select a face first"),
                     ("MESH_extrudeIndividual", "select a face first"),
                     ("MESH_deleteLoose", "nothing selected is loose"),
                     ("MESH_bevelVertices", "select some first"),
                     ("MESH_bevel", "select some first")]:
    obj = grid()
    selecting(obj, nothing)
    refused(block + " with nothing selected", block, words)
    check(block + " with nothing selected — left in object mode", obj.mode == 'OBJECT', obj.mode)

# --------------------------------------------------------------------------
print("\nShear, through the borrowed 3D View, with no GPU module started")


def sheared(block, select=everything):
    fresh()
    obj = cube("A", (1, 2, 3))
    history("PUSH", "Setup")
    selecting(obj, select)
    before = [v.co.copy() for v in obj.data.vertices]
    error = perform(block, "Shear")
    return obj, before, error


AXES = {"X": 0, "Y": 1, "Z": 2}
# The angle as the call carries it: the Swift writes numbers to four places
# (`LastOperator.number`), so 20° goes as 0.3491 rad, 20.002°.
import re
angle = float(re.search(r"angle=(-?[0-9.]+)", blocks["SHEAR"]).group(1))
check("(Shear's call carries 20° as %s rad)" % angle, abs(angle - 20 * math.pi / 180) < 1e-4)
obj, before, error = sheared("SHEAR")
median = sum(before, Vector()) / len(before)
worst = max(abs((after.x - b.x) - (-math.tan(angle) * (b.y - median.y))) + abs(after.y - b.y) + abs(after.z - b.z)
            for b, after in zip(before, (v.co for v in obj.data.vertices)))
check("Shear at its 20°, Along X by Y: x moves by −tan(20°) × y from the median, nothing else moves",
      error is None and worst < 1e-5, (error, worst))
check("and the view it borrowed is put back: the context has no area again", bpy.context.area is None)
for i in range(6):
    label = blocks["SHEAR_AXES_%d_LABEL" % i]
    along, by = label.replace("Along ", "").split(", by ")
    obj, before, error = sheared("SHEAR_AXES_%d" % i)
    median = sum(before, Vector()) / len(before)
    a, b = AXES[along], AXES[by]
    after = [v.co for v in obj.data.vertices]
    worst = 0.0
    for p, q in zip(before, after):
        for k in range(3):
            want = p[k] - math.tan(0.5) * (p[b] - median[b]) if k == a else p[k]
            worst = max(worst, abs(q[k] - want))
    # Which way is Blender's to choose; that it moves along one axis by the
    # other, and the size, are what the label promises.
    flipped = max(abs(q[a] - (p[a] + math.tan(0.5) * (p[b] - median[b]))) for p, q in zip(before, after))
    check("Shear %s: only %s moves, by tan(0.5) × %s" % (label, along, by),
          error is None and min(worst, flipped) < 1e-5, (error, worst, flipped))
obj, before, error = sheared("SHEAR", nothing)
check("Shear with nothing selected is refused in words", error is not None and "select some first" in error, error)
check("and nothing moved", [v.co for v in obj.data.vertices] == before)
check("the angle field stops at 80°: 2 rad is held to %s" % blocks["SHEAR_STEEP_ANGLE"],
      abs(float(blocks["SHEAR_STEEP_ANGLE"]) - 80 * math.pi / 180) < 1e-3, blocks["SHEAR_STEEP_ANGLE"])
# Object Mode: Object ▸ Transform ▸ Shear moves the selected objects. This
# used to "prove" the opposite with two cubes at y = 0, which a shear Along X
# by Y cannot move; these two are 4 apart in y.
fresh()
a, b = cube("A", (0, -2, 0)), cube("B", (0, 2, 1))
history("PUSH", "Setup")
only(a, b)
before = [world(a), world(b)]
error = perform("SHEAR_OBJECTS", "Shear")
shift = math.tan(angle) * 2
check("Shear in Object Mode, Along X by Y: the cube at y = −2 goes +%.4f in x, the one at y = +2 −%.4f"
      % (shift, shift),
      error is None and abs(a.location.x - shift) < 1e-4 and abs(b.location.x + shift) < 1e-4
      and tuple(a.location.yz) == (-2, 0) and tuple(b.location.yz) == (2, 1),
      (error, tuple(a.location), tuple(b.location)))
check("and their rotation and scale are left alone",
      all(tuple(o.rotation_euler) == (0, 0, 0) and tuple(o.scale) == (1, 1, 1) for o in (a, b)))
check("still in Object Mode", a.mode == 'OBJECT' and b.mode == 'OBJECT')
only()
refused("Shear in Object Mode with nothing selected is refused in words", "SHEAR_OBJECTS", "select some first")
import gpu
gpu.init()
obj, before, error = sheared("SHEAR")
check("and the same with the GPU module started", error is None and obj.data.vertices[0].co != before[0], error)

with open(RECORDS, "w") as handle:
    json.dump(passes, handle)
print("\n%d mirror passes written for the Swift" % len(passes))
print("ALL PASS" if fail == 0 else "%d FAILED" % fail)
sys.exit(1 if fail else 0)
