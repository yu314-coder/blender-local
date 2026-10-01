"""Runs everything the redo panel can emit through a real Blender.

The host tests check that the right string comes out. Only Blender can say
whether it is a string Blender accepts, and only a real scene can show what
running it twenty times leaves behind. Three things here are invisible without
one: an operator that rejects an argument name, a mesh datablock orphaned once
per frame of a slider drag, and geometry that accumulates because the way back
to before the operator did not work.
"""
import bpy, bmesh, sys, collections, math, pathlib, importlib.util

# The modules under test are read from the source tree; nothing is written into it.
sys.dont_write_bytecode = True

CALLS = sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
fail = 0

def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1

blocks = []
for b in open(CALLS).read().split("#--"):
    b = b.strip()
    if not b:
        continue
    head, body = b.split("\n", 1)
    blocks.append((head[4:], body.strip()))

groups = collections.OrderedDict()
for head, body in blocks:
    groups.setdefault(head.split()[0], []).append((head.split()[-1], body))

discard = groups.pop("DISCARD")[0][1]
# Knife Project needs a cutter; it has a section of its own at the end.
knife = {name: dict(items) for name, items in list(groups.items()) if name.startswith("knife.")}
for name in knife:
    groups.pop(name)
# So do the edge tools' measured effects, on grids of their own.
edge = {name[5:]: dict(items) for name, items in list(groups.items()) if name.startswith("edge.")}
for name in list(groups):
    if name.startswith("edge."):
        groups.pop(name)


def fresh_cube():
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    return bpy.context.object


def shape(o):
    return tuple(round(c, 5) for v in o.data.vertices for c in v.co)


def grid_scene(select, mode=(True, False, False)):
    """A 10 x 10 grid, 0.2 apart (121 vertices), active and in object mode,
    with `select(bm, at)` choosing the selection in select mode `mode` (vertex
    by default) — what the app's selection push leaves Blender holding."""
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10, size=2)
    o = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = mode
    bm = bmesh.from_edit_mesh(o.data)
    for seq in (bm.faces, bm.edges, bm.verts):
        for e in seq:
            e.select = False

    def at(x, y):
        return next(v for v in bm.verts if abs(v.co.x - x) < 1e-4 and abs(v.co.y - y) < 1e-4)
    select(bm, at)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(o.data)
    bpy.ops.object.mode_set(mode='OBJECT')
    return o


def middle_row(bm, at):
    """The edge loop along y = 0: 11 vertices, 10 edges."""
    for v in bm.verts:
        v.select = abs(v.co.y) < 1e-4


def one_edge(bm, at):
    """The edge from (-0.2, 0) to (0, 0), itself: in edge select mode two
    selected vertices do not make a selected edge."""
    bm.edges.get((at(-0.2, 0), at(0, 0))).select_set(True)


def one_edge_seam_along(bm, at):
    """`one_edge`, with the loop's edge from (0.4, 0) to (0.6, 0) a seam."""
    one_edge(bm, at)
    bm.edges.get((at(0.4, 0), at(0.6, 0))).seam = True


def one_edge_sharp_rung(bm, at):
    """`one_edge`, with the ring's rung from (-0.2, 0.4) to (0, 0.4) sharp."""
    one_edge(bm, at)
    bm.edges.get((at(-0.2, 0.4), at(0, 0.4))).smooth = False


def one_vertex(bm, at):
    at(0, 0).select = True


def two_vertices(bm, at):
    """Opposite corners of one quad, with no edge between them."""
    at(-0.2, -0.2).select = True
    at(0, 0).select = True


def nothing(bm, at):
    pass


def loose_vertex(bm, at):
    """A vertex in no edge and an edge in no face beside the grid, and they
    alone selected: what Delete Loose removes. Its lead refuses a selection
    with nothing its switches remove in it (a whole cube: measured in 5.2.1,
    FINISHED, "Removed: 0 vertices", and everything deselected) — so with the
    vertex alone, the panel's Vertices switch turned off was refused; the
    edge keeps every one-switch change something to remove."""
    bm.verts.new((5.0, 5.0, 0.0)).select = True
    ends = [bm.verts.new((6.0, 5.0, 0.0)), bm.verts.new((7.0, 5.0, 0.0))]
    for v in ends:
        v.select = True
    bm.edges.new(ends).select = True


# The edge tools act on a selection a whole cube is not: Edge Slide returns
# CANCELLED on one (measured) and Connect Vertex Path wants two vertices. Each
# gets the scene it is for; everything else keeps the selected cube.
EDGE_SCENES = {
    "mesh.selectEdgeLoops": one_edge, "mesh.selectEdgeRings": one_edge,
    "mesh.connectVertexPath": two_vertices, "mesh.slideVertices": one_vertex,
    "mesh.edgeSlide": middle_row, "mesh.offsetEdgeSlide": middle_row,
    "mesh.bevelWeight": middle_row, "mesh.edgeCrease": middle_row,
    "mesh.markSeam": middle_row, "mesh.clearSeam": middle_row,
    "mesh.markSharp": middle_row, "mesh.clearSharp": middle_row,
    "mesh.deleteLoose": loose_vertex,
}


print("every call the catalogue can produce, run by Blender")

for name, items in groups.items():
    is_mesh = name.startswith("mesh.")
    if is_mesh and name in EDGE_SCENES:
        grid_scene(EDGE_SCENES[name])
    elif is_mesh:
        # A mesh operator needs something to operate on, with a selection —
        # and is left in OBJECT mode deliberately. Entering edit mode here hid
        # a real bug: the operator's own preamble has to do that, because
        # Blender's mode is not the interface's, and for a while only the
        # re-run path did it.
        fresh_cube()
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.object.mode_set(mode='OBJECT')
    else:
        # An add brings its own object, so it starts from nothing.
        bpy.ops.wm.read_homefile(use_empty=True)

    ns = {"bpy": bpy}
    first_shape = None
    same_shape = None
    pending_first = False
    rejected = None
    for kind, body in items:
        try:
            if kind == "FIRST" and is_mesh:
                # No mode_set around this on purpose. The ENTRY block before it
                # and the EXIT block after it are what handle the mode, and
                # doing it here would hide the bug this suite now checks for.
                exec(compile(body, "<call>", "exec"), ns)
                pending_first = True
            else:
                # The bridge re-reads the name of what it made after every run,
                # because Blender may have called this one Cylinder.001. A
                # harness that hardcoded a name would test a removal that never
                # matches, and every re-run would add another object.
                obj = bpy.context.view_layer.objects.active
                body = body.replace("@SUBJECT@", obj.name if obj else "")
                exec(compile(body, "<call>", "exec"), ns)
                # After EXIT, not after FIRST. In edit mode the mesh datablock
                # is whatever it was when edit mode was entered — the BMesh has
                # not been written back — so reading the shape any earlier
                # measures the mesh from before the operator ran.
                if kind == "EXIT" and pending_first:
                    pending_first = False
                    first_shape = shape(bpy.context.object)
                if kind == "SAME":
                    obj = bpy.context.view_layer.objects.active
                    same_shape = shape(obj) if obj else None
                # There is deliberately no "the mesh got too big" check here.
                # The soft ranges are real: `segments` reaches 100, and a
                # hundred-segment bevel on a cube genuinely is sixty thousand
                # vertices. A size threshold flags that as runaway compounding
                # when it is nothing of the kind. What actually proves the way
                # back works is the SAME block below — re-running the original
                # arguments after every other value has been through, and
                # getting the original mesh.
        except Exception as e:
            rejected = f"{kind}: {type(e).__name__} {e}"
            break

    check(f"{name}: Blender accepts every call", rejected is None, rejected)
    if rejected:
        continue

    bpy.ops.object.mode_set(mode='OBJECT')
    check(f"{name}: one object left", len(bpy.data.objects) == 1,
          [x.name for x in bpy.data.objects])
    # A mesh operator keeps its backup alive alongside the live mesh; an add
    # leaves only what it made.
    want = 2 if is_mesh else 1
    check(f"{name}: no orphan meshes", len(bpy.data.meshes) == want,
          [m.name for m in bpy.data.meshes])
    if is_mesh:
        check(f"{name}: left in the mode it started in",
              bpy.context.object.mode == 'OBJECT', bpy.context.object.mode)
        # The way back has to actually work: re-running with the original
        # arguments after twenty other values must give the original mesh. If
        # it does not, the operator is compounding on its own output — a bevel
        # of a bevel of a bevel.
        check(f"{name}: re-running the original arguments gives the original mesh",
              same_shape is not None and same_shape == first_shape,
              "the geometry drifted")

    if is_mesh:
        # The mode has to come back. Entering edit mode and staying there
        # leaves every object-mode operator failing its poll, and the next
        # script to clear the scene answers "context is incorrect" a long way
        # from the mesh operator that caused it.
        try:
            bpy.ops.object.select_all(action='SELECT')
            left_usable = True
        except Exception as e:
            left_usable = str(e)
        check(f"{name}: object mode still works afterwards",
              left_usable is True, left_usable)

    exec(compile(discard, "<call>", "exec"), {"bpy": bpy})
    check(f"{name}: the backup is gone afterwards",
          bpy.data.meshes.get("_bk_redo") is None,
          [m.name for m in bpy.data.meshes])

print("\nwhat only a real scene can show")

# Removing an object frees its name but not its mesh's. Without the datablock
# cleanup a slider drag leaves one orphan per frame.
o = fresh_cube()
created = bpy.context.view_layer.objects.active.name
meshes = len(bpy.data.meshes)
for v in range(31, 5, -1):
    _o = bpy.data.objects.get(created)
    if _o is not None:
        _d = _o.data
        bpy.data.objects.remove(_o, do_unlink=True)
        if _d is not None and _d.users == 0:
            bpy.data.meshes.remove(_d)
    bpy.ops.mesh.primitive_cylinder_add(vertices=v, radius=1, depth=2,
                                        end_fill_type='NGON', location=(0, 0, 0))
    created = bpy.context.view_layer.objects.active.name
check("twenty-six adjustments leave no orphan meshes",
      len(bpy.data.meshes) == meshes, len(bpy.data.meshes))
check("and the name never drifts to Cylinder.026", created == "Cylinder", created)
check("the geometry is the last value asked for",
      len(bpy.data.objects[created].data.vertices) == 12,
      len(bpy.data.objects[created].data.vertices))

# A mesh shared with another object must survive the cleanup.
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
a = bpy.context.view_layer.objects.active
b = bpy.data.objects.new("Sharer", a.data)
bpy.context.collection.objects.link(b)
_d = a.data
bpy.data.objects.remove(a, do_unlink=True)
if _d is not None and _d.users == 0:
    bpy.data.meshes.remove(_d)
check("a mesh another object is using is left alone",
      b.data is not None and len(b.data.vertices) == 8)

# The backup carries the selection, which is why re-running acts on the same
# faces rather than on everything.
o = fresh_cube()
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='DESELECT')
bpy.ops.object.mode_set(mode='OBJECT')
o.data.polygons[0].select = True
backup = o.data.copy()
backup.name = "_bk_redo"
backup.use_fake_user = True
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.inset(thickness=0.2)
bpy.ops.object.mode_set(mode='OBJECT')
old = o.data
o.data = bpy.data.meshes["_bk_redo"].copy()
bpy.data.meshes.remove(old)
check("the mesh backup carries the selection with it",
      [p.index for p in o.data.polygons if p.select] == [0],
      [p.index for p in o.data.polygons if p.select])

# An edit made earlier in the same edit session must survive an adjustment.
# In edit mode Blender works on a BMesh, and the mesh datablock behind it stays
# as it was when edit mode was entered — so a backup taken without
# `update_from_editmode()` captures the mesh from before every edit made since,
# and adjusting a bevel silently throws away the subdivide that preceded it.
preamble = None
for name, items in list(groups.items()):
    if name == "mesh.bevel":
        preamble = dict(items).get("PREAMBLE")
first = None
if preamble is None:
    check("the bevel preamble is in the dump", False, sorted(groups))
else:
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    o = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.subdivide(number_cuts=1)     # an edit before the adjustable one
    exec(compile(preamble, "<call>", "exec"), {"bpy": bpy})
    backup = bpy.data.meshes["_bk_redo"]
    check("the backup holds the edits made before the operator, not the mesh "
          "from before edit mode",
          len(backup.vertices) == 26, f"{len(backup.vertices)} vertices, expected 26")
    bpy.ops.object.mode_set(mode='OBJECT')

# An operator must work even if Blender was left in some other mode.
#
# This is the bug that made most of the app unusable after one tap on a sculpt
# brush. While Blender sits in sculpt mode, `object.select_all`, `object.delete`,
# `mesh.bevel` and `mesh.subdivide` all fail their poll — and
# `primitive_cube_add` crashes the process outright, with no traceback. An
# operator that asks for the mode it needs is immune to all of it; one that
# assumes object mode is not.
for name, items in list(groups.items()):
    if name == "DISCARD":
        continue
    blocks_by_kind = dict(items)
    entry = blocks_by_kind.get("ENTRY")
    first = blocks_by_kind.get("FIRST")
    if entry is None or first is None:
        continue
    if name in EDGE_SCENES:
        grid_scene(EDGE_SCENES[name])
    else:
        bpy.ops.wm.read_homefile(use_empty=True)
        bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    if name.startswith("mesh.") and name not in EDGE_SCENES:
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
    # Strand Blender somewhere the operator does not expect.
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.mode_set(mode='SCULPT')
    ns = {"bpy": bpy}
    try:
        exec(compile(entry, "<entry>", "exec"), ns)
        exec(compile(first, "<first>", "exec"), ns)
        survived = True
    except Exception as e:
        survived = str(e)
    check(f"{name}: runs even when Blender was left in sculpt mode",
          survived is True, survived)
    try:
        bpy.ops.object.mode_set(mode='OBJECT')
    except Exception:
        pass

# Blender's undo is off at startup in background mode until something calls
# `ed.undo_push()`. The app does, and adjusts through undo where it can
# (tests/undo/blender); these restorations are the checkpoint fallback's.
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
try:
    bpy.ops.ed.undo()
    undo_error = None
except Exception as e:
    undo_error = str(e)
check("bpy.ops.ed.undo refuses in background mode until ed.undo_push() starts the stack",
      undo_error is not None and "undo_push" in undo_error, undo_error)

print("\nthe edge tools, doing what was measured")


def perform(case, scene):
    """What the bridge sends for a first press, on `scene`. The object, back
    in object mode, or the refusal Blender or the call raised."""
    try:
        exec(compile(edge[case]["PERFORM"], "<edge " + case + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the words are the point
        return str(error)
    return scene


def positions(o):
    return [v.co.copy() for v in o.data.vertices]


def moves(o, before, which):
    """How far each vertex in `which` moved, rounded; and whether any other did."""
    moved = {tuple(round(c, 4) for c in (o.data.vertices[i].co - before[i])) for i in which}
    others = any((o.data.vertices[i].co - before[i]).length > 1e-6
                 for i in range(len(before)) if i not in which)
    return moved, others


def edge_values(o, name):
    a = o.data.attributes.get(name)
    return [round(d.value, 4) for d in a.data] if a is not None else [0.0] * len(o.data.edges)


def row_edges(o):
    """The indices of the 10 edges along y = 0."""
    return {e.index for e in o.data.edges
            if all(abs(o.data.vertices[v].co.y) < 1e-4 for v in e.vertices)}


o = perform("loops", grid_scene(one_edge))
check("Select Edge Loops from one edge selects its loop across the grid: 10 edges",
      not isinstance(o, str) and sum(e.select for e in o.data.edges) == 10
      and {e.index for e in o.data.edges if e.select} == row_edges(o), o)
o = perform("rings", grid_scene(one_edge, mode=(False, True, False)))
check("Select Edge Rings, in edge select mode, selects the 11 edges across from it",
      not isinstance(o, str) and sum(e.select for e in o.data.edges) == 11
      and all({round(o.data.vertices[v].co.x, 4) for v in e.vertices} == {-0.2, 0.0}
              for e in o.data.edges if e.select), o)
# In vertex select mode the same ring selects its 22 vertices, and Blender's
# flush then selects the edges and faces between them too: a strip, as on a
# desktop in that mode.
o = perform("rings", grid_scene(one_edge))
picked = {(round(v.co.x, 4), round(v.co.y, 4)) for v in o.data.vertices if v.select} \
    if not isinstance(o, str) else o
check("in vertex select mode it selects the ring's 22 vertices",
      not isinstance(o, str) and len(picked) == 22 and {x for x, _ in picked} == {-0.2, 0.0}, picked)

# Delimit, the pair to Mark Seam and Mark Sharp: the loop stops at the seam
# three edges along, the ring at the sharp rung two along — and only with that
# flag in the set.
o = perform("loops", grid_scene(one_edge_seam_along))
check("a seam on the loop does not stop it at the default Delimit: 10 edges",
      not isinstance(o, str) and sum(e.select for e in o.data.edges) == 10, o)
o = perform("loopsSeam", grid_scene(one_edge_seam_along))
check("Delimit Seam stops it there: 7 edges, none at x > 0.4",
      not isinstance(o, str) and sum(e.select for e in o.data.edges) == 7
      and all(max(o.data.vertices[v].co.x for v in e.vertices) <= 0.4 + 1e-4
              for e in o.data.edges if e.select), o)
o = perform("rings", grid_scene(one_edge_sharp_rung, mode=(False, True, False)))
check("a sharp rung does not stop a ring at the default Delimit: 11 edges",
      not isinstance(o, str) and sum(e.select for e in o.data.edges) == 11, o)
o = perform("ringsSharp", grid_scene(one_edge_sharp_rung, mode=(False, True, False)))
check("Delimit Sharp stops it at that rung: 8 edges",
      not isinstance(o, str) and sum(e.select for e in o.data.edges) == 8, o)

# Why the Mesh menu offers these in Edit Mode only (`Mesh.editModeOnly`): from
# Object Mode the bridge's call switches into Edit Mode and acts on the
# selection the mesh stored, and a new cube is stored with everything selected.
o = perform("markSeam", fresh_cube())
check("from Object Mode, Mark Seam on a new cube marks all 12 of its edges",
      not isinstance(o, str) and sum(e.use_seam for e in o.data.edges) == 12, o)
o = perform("creaseHalf", fresh_cube())
check("and Edge Crease at 0.5 creases all 12",
      not isinstance(o, str) and edge_values(o, "crease_edge") == [0.5] * 12,
      o if isinstance(o, str) else edge_values(o, "crease_edge"))

o = grid_scene(middle_row)
before, row = positions(o), {v.index for v in o.data.vertices if v.select}
o = perform("slide", o)
moved, others = moves(o, before, row) if not isinstance(o, str) else ({o}, True)
check("Edge Slide at 0.5 moves the 11-vertex loop half the 0.2 spacing, and nothing else",
      len(moved) == 1 and abs(abs(next(iter(moved))[1]) - 0.1) < 1e-4
      and next(iter(moved))[0] == 0 and not others, (moved, others))
forward = next(iter(moved))[1] if len(moved) == 1 else None
o = grid_scene(middle_row)
o = perform("slideBack", o)
moved, others = moves(o, before, row) if not isinstance(o, str) else ({o}, True)
check("at -0.5 it slides the same distance the other way",
      forward is not None and moved == {(0.0, -forward, 0.0)} and not others, moved)

o = grid_scene(one_vertex)
before, picked = positions(o), {v.index for v in o.data.vertices if v.select}
o = perform("vertex", o)
moved, others = moves(o, before, picked) if not isinstance(o, str) else ({o}, True)
check("Slide Vertices at 0.5 along +X moves the vertex half an edge along X",
      moved == {(0.1, 0.0, 0.0)} and not others, moved)
o = perform("vertexY", grid_scene(one_vertex))
moved, others = moves(o, before, picked) if not isinstance(o, str) else ({o}, True)
check("and Direction +Y slides it along the edge that points that way",
      moved == {(0.0, 0.1, 0.0)} and not others, moved)

o = grid_scene(two_vertices)
counts = (len(o.data.vertices), len(o.data.edges), len(o.data.polygons))
o = perform("connect", o)
check("Connect Vertex Path joins two corners of a quad: one edge more, and the quad split in two",
      not isinstance(o, str)
      and (len(o.data.vertices), len(o.data.edges), len(o.data.polygons))
      == (counts[0], counts[1] + 1, counts[2] + 1), o if isinstance(o, str) else
      ((len(o.data.vertices), len(o.data.edges), len(o.data.polygons)), counts))

o = perform("offset", grid_scene(middle_row))
rows = sorted({round(v.co.y, 4) for v in o.data.vertices if abs(v.co.y) < 0.25}) \
    if not isinstance(o, str) else o
check("Offset Edge Slide at 0.5 adds a loop either side, halfway to the next: 22 vertices",
      not isinstance(o, str) and len(o.data.vertices) == 143
      and rows == [-0.2, -0.1, 0.0, 0.1, 0.2], rows)

for flag, mark, clear in (("use_seam", "markSeam", "clearSeam"),
                          ("use_edge_sharp", "markSharp", "clearSharp")):
    o = perform(mark, grid_scene(middle_row))
    marked = {e.index for e in o.data.edges if getattr(e, flag)} if not isinstance(o, str) else o
    check("%s marks the 10 selected edges and no others" % mark,
          not isinstance(o, str) and marked == row_edges(o), marked)
    o = perform(clear, o)
    check("%s takes them off again" % clear,
          not isinstance(o, str) and not any(getattr(e, flag) for e in o.data.edges), o)

for case, attribute, label in (("crease", "crease_edge", "Edge Crease"),
                               ("bevelWeight", "bevel_weight_edge", "Edge Bevel Weight")):
    o = perform(case, grid_scene(middle_row))
    values = edge_values(o, attribute) if not isinstance(o, str) else o
    check("%s at 1 gives the 10 selected edges a full weight, and no others" % label,
          not isinstance(o, str)
          and {i for i, v in enumerate(values) if v == 1.0} == row_edges(o)
          and all(v == 0.0 for i, v in enumerate(values) if i not in row_edges(o)), values)
o = perform("creaseHalf", grid_scene(middle_row))
o = perform("creaseHalf", o)
check("a crease adds to what the edge had: 0.5 twice is 1",
      not isinstance(o, str) and {edge_values(o, "crease_edge")[i] for i in row_edges(o)} == {1.0},
      o if isinstance(o, str) else {edge_values(o, "crease_edge")[i] for i in row_edges(o)})

# With nothing selected every one of these is refused in words — the ones that
# would return FINISHED having done nothing, and the ones that would return
# CANCELLED without a word — and Blender is left in object mode either way.
for case, words in (("loops", "select an edge"), ("rings", "select an edge"),
                    ("markSeam", "select an edge"), ("clearSharp", "select an edge"),
                    ("connect", "select two"), ("slide", "select an edge"),
                    ("offset", "select an edge"), ("vertex", "select a vertex"),
                    ("crease", "select an edge"), ("bevelWeight", "select an edge")):
    o = grid_scene(nothing)
    said = perform(case, o)
    check("%s with nothing selected says so" % case,
          isinstance(said, str) and words in said and o.mode == 'OBJECT', (said, o.mode))
said = perform("connect", grid_scene(one_vertex))
check("one vertex is not a path either, in the app's words rather than 'Invalid selection order'",
      isinstance(said, str) and "select two" in said, said)

# A whole cube is a selection Edge Slide cannot slide: CANCELLED, no error.
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2)
cube = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
check("(Blender's own answer to sliding a whole cube is CANCELLED, not an error)",
      bpy.ops.transform.edge_slide(value=0.5) == {'CANCELLED'})
bpy.ops.object.mode_set(mode='OBJECT')
said = perform("slide", cube)
check("which the call turns into a refusal, so no undo step is pushed for nothing",
      isinstance(said, str) and "cannot slide this selection" in said, said)

print("\nKnife Project, through the 3D View it aims")

# The app's site directory also holds the simulator's `bpy` stand-in, so it is
# not put on sys.path: the two modules the knife imports are loaded by path.
for module in ("_blenderkit_context", "_blenderkit_knife"):
    spec = importlib.util.spec_from_file_location(
        module, ROOT / "Resources" / "python" / "site" / (module + ".py"))
    sys.modules[module] = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sys.modules[module])


def knife_scene(target_kind="PLANE", cutter_at=(0.3, -0.2, 2.0), rotation=(0, 0, 0),
                cutter_selected=False, cutter="CIRCLE"):
    """A mesh to cut and a cutter called "Cutter", the mesh active and alone
    selected, in object mode — where a tap on Knife Project finds them."""
    bpy.ops.wm.read_homefile(use_empty=True)
    if target_kind == "PLANE":
        bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, 0))
    else:
        bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    target = bpy.context.object
    if cutter == "CIRCLE":
        bpy.ops.mesh.primitive_circle_add(vertices=32, radius=0.5, location=cutter_at,
                                          rotation=rotation)
    else:
        bpy.ops.mesh.primitive_cube_add(size=0.5, location=cutter_at)
    bpy.context.object.name = "Cutter"
    bpy.ops.object.select_all(action='DESELECT')
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    if cutter_selected:
        bpy.data.objects["Cutter"].select_set(True)
    return target


def view_state():
    """What a saved .blend keeps of the view. Not `perspective_matrix`: the
    startup file's is stale against its own view (put back and recomputed, the
    first row read 0.5612 where the file had 0.5695), and every draw on a
    desktop recomputes it anyway."""
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                r = area.spaces.active.region_3d
                return (tuple(round(x, 6) for x in r.view_rotation),
                        tuple(round(x, 6) for x in r.view_location),
                        round(r.view_distance, 6), r.view_perspective)
    return None


def run_block(body, target):
    body = body.replace("@SUBJECT@", target.name)
    exec(compile(body, "<knife>", "exec"), {"bpy": bpy})


def radii(target, first, centre, axis=(0, 0, 1)):
    """How far each vertex from `first` on lies from the line through `centre`."""
    from mathutils import Vector
    axis, centre = Vector(axis).normalized(), Vector(centre)
    out = []
    for v in list(target.data.vertices)[first:]:
        p = target.matrix_world @ v.co - centre
        out.append((p - axis * p.dot(axis)).length)
    return out


view_before = view_state()
check("the startup screen has a 3D View for the knife to borrow", view_before is not None)

project = knife["knife.project"]
target = knife_scene()
run_block(project["PERFORM"], target)
cut = radii(target, 4, (0.3, -0.2, 0))
check("it cuts the cutter's outline into the plane under it",
      len(cut) == 32 and max(abs(r - 0.5) for r in cut) < 1e-5,
      f"{len(cut)} new vertices, radii {min(cut, default=0):.6f}..{max(cut, default=0):.6f}")
check("and leaves the mode it found", target.mode == 'OBJECT', target.mode)
check("the backup that makes it adjustable was taken",
      bpy.data.meshes.get("_bk_redo") is not None, [m.name for m in bpy.data.meshes])
check("the cutter is not left selected, to join the next edit session",
      not bpy.data.objects["Cutter"].select_get() and target.select_get(),
      [o.name for o in bpy.data.objects if o.select_get()])
check("Blender's 3D View is put back where it was", view_state() == view_before,
      f"{view_state()} vs {view_before}")

# With Blender's undo keeping the history there is no backup — the same cut.
target = knife_scene()
run_block(project["UNDOPERFORM"], target)
check("without a backup it cuts the same",
      len(target.data.vertices) == 36 and bpy.data.meshes.get("_bk_redo") is None,
      f"{len(target.data.vertices)} vertices")

# A cube: the top face alone, then through both, then back — the redo panel.
target = knife_scene("CUBE", cutter_at=(0.3, -0.2, 3.0))
run_block(project["PERFORM"], target)
first = sorted(tuple(round(c, 5) for c in v.co) for v in target.data.vertices)
top = [target.matrix_world @ v.co for v in list(target.data.vertices)[8:]]
check("on a cube it cuts only the face it can see",
      len(top) == 32 and all(abs(v.z - 1) < 1e-6 for v in top),
      f"{len(top)} new vertices on z = {sorted(set(round(v.z, 4) for v in top))}")
run_block(project["THROUGH"], target)
through = [target.matrix_world @ v.co for v in list(target.data.vertices)[8:]]
check("Cut Through, adjusted afterwards, cuts the face on the far side too",
      len(through) == 64 and sorted(set(round(v.z, 4) for v in through)) == [-1.0, 1.0],
      f"{len(through)} new vertices on z = {sorted(set(round(v.z, 4) for v in through))}")
run_block(project["SAME"], target)
check("and turning it off again gives the first cut back, not a cut of the cut",
      sorted(tuple(round(c, 5) for c in v.co) for v in target.data.vertices) == first,
      f"{len(target.data.vertices)} vertices")
check("with no orphaned meshes", len(bpy.data.meshes) == 3, [m.name for m in bpy.data.meshes])

# Along the cutter's own normal, not along an axis.
from mathutils import Euler, Vector
tilt = Euler((0.4, 0.25, 0.3))
normal = tilt.to_quaternion() @ Vector((0, 0, 1))
target = knife_scene("CUBE", cutter_at=tuple(normal * 5), rotation=tilt)
run_block(project["PERFORM"], target)
tilted = radii(target, 8, normal * 5, normal)
# 33 vertices here, not 32 — every one of them on the outline, which is what
# is checked; the count is the knife's business.
check("a tilted cutter cuts along its own normal",
      len(tilted) >= 32 and max(abs(r - 0.5) for r in tilted) < 1e-4,
      f"{len(tilted)} new vertices, {min(tilted, default=0):.6f}..{max(tilted, default=0):.6f} from its axis")

# Selected when edit mode was entered, the cutter goes into edit mode with the
# target, and Blender then has nothing to cut with.
target = knife_scene(cutter_selected=True)
bpy.ops.object.mode_set(mode='EDIT')
check("(the landmine: both objects are in edit mode)",
      bpy.data.objects["Cutter"].mode == 'EDIT', bpy.data.objects["Cutter"].mode)
run_block(project["PERFORM"], target)
bpy.ops.object.mode_set(mode='OBJECT')
check("a cutter that went into edit mode with the target still cuts",
      len(target.data.vertices) == 36, f"{len(target.data.vertices)} vertices")

# What cannot be done is said, in words, and leaves nothing behind.
def refusal(body, target):
    try:
        run_block(body, target)
        return None
    except Exception as e:
        return str(e)

target = knife_scene(cutter_at=(50, 50, 2))
said = refusal(project["PERFORM"], target)
check("an outline that misses the mesh is an error, not a FINISHED that did nothing",
      said is not None and "nothing was cut" in said, said)
check("and puts the view back all the same", view_state() == view_before)
check("and the mode", target.mode == 'OBJECT', target.mode)

said = refusal(knife["knife.missing"]["PERFORM"], knife_scene())
check("a cutter that is gone is named", said is not None and "'Nothing'" in said, said)

target = knife_scene(cutter="CUBE")
said = refusal(project["PERFORM"], target)
check("a closed cutter gets Blender's own reason",
      said is not None and "wire or boundary edges" in said, said)
check("and the selection and the view come back from a refusal inside the call",
      not bpy.data.objects["Cutter"].select_get() and view_state() == view_before)

# The GPU module the view needs is the one Eevee renders with. The cuts above
# started it, on this thread; this renders on the same thread, then cuts again.
# The other order — a render on the script thread starting the module first —
# needs a fresh Blender, and is gpu_order.py's.
target = knife_scene()
scene = bpy.context.scene
scene.camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
scene.collection.objects.link(scene.camera)
scene.camera.location = (0, 0, 10)
scene.render.engine = 'BLENDER_EEVEE'
scene.render.resolution_x = scene.render.resolution_y = 32
scene.eevee.taa_render_samples = 1
try:
    bpy.ops.render.render(write_still=False)
    run_block(project["PERFORM"], target)
    rendered = len(target.data.vertices) == 36
except Exception as e:
    rendered = str(e)
check("after an Eevee render on the main thread, where cuts had started the GPU, it still cuts",
      rendered is True, rendered)

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
