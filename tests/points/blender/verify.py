"""Edit Mode on curves and lattices, run by the Blender it runs on.

scripts/run-points-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup` and a home of its own. Every string run here is the one
the Swift sends, printed by tests/points/blender/main.swift; the app's own
`_blenderkit_points` and `_blenderkit_sync` run from the source tree against a
`_blenderkit` that records what they hand over. Undo steps are pushed the way
the app's history pushes them (`ed.undo_push` in the main thread's context).
"""
import bpy, gpu, sys, types, json, math, pathlib, importlib.util
from array import array
from mathutils import Vector, Matrix

sys.dont_write_bytecode = True
CALLS, REPLAY = sys.argv[sys.argv.index("--") + 1:][:2]
ROOT = pathlib.Path(__file__).resolve().parents[3]
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


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps what the points and the
    mirror hand over, and takes anything else without a word."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.points = []
        self.meshes = []
        self.pushes = []
        self.edges = {}
        self.frames = []

    def sync_points(self, name, record, positions, flags, lines, during_pass=1):
        self.points.append(dict(name=name, record=record, positions=array('f', positions).tolist(),
                                flags=list(bytes(flags)), lines=array('I', lines).tolist(),
                                during_pass=during_pass))

    def anim_frame(self, frame, subframe, names, matrices):
        self.frames.append(dict(names=[n.decode() for n in bytes(names).split(b'\0')] if names else [],
                                matrices=array('d', matrices).tolist()))
        return 0

    def anim_mesh(self, name, co, normals, tris, edges=None):
        self.meshes.append(dict(name=name, co=array('f', co).tolist(),
                                tris=len(tris), edges=None if edges is None else array('I', edges).tolist()))
        return 1

    def sync_push(self, name, kind, matrix, positions, normals, triangles, selected, active, rgba):
        self.pushes.append(dict(name=name, kind=kind, positions=array('f', positions).tolist(),
                                triangles=len(triangles)))

    def sync_edges(self, name, edges):
        self.edges[name] = array('I', edges).tolist()

    def mode(self):
        return bpy.context.object.mode if bpy.context.object else 'OBJECT'

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *args, **kwargs: None


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name, folder="Resources/python/site"):
    spec = importlib.util.spec_from_file_location(name, ROOT / folder / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


load("_blenderkit_context")
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
sync = load("_blenderkit_sync")
points = load("_blenderkit_points")
undo = load("_blenderkit_undo")
fixtures = load("fixtures", "tests/points/blender")


def run(block, subject=None, **replace):
    """Runs what the Swift sends; the error's text, or None."""
    source = blocks[block].replace("@SUBJECT@", subject or "")
    try:
        exec(compile(source, "<" + block + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return str(error).strip()
    return None


def ran(label, block, subject=None):
    error = run(block, subject)
    check(label, error is None, error)
    return error is None


def steps():
    rows = undo.blender_steps()
    return len(rows) if rows else 0


def selected(obj):
    return sorted(i for i, f in enumerate(points.cage(obj)[1]) if f & points.SELECTED)


def expect(block):
    text = blocks[block].strip()
    return sorted(int(i) for i in text.split(",")) if text else []


def world(obj, i):
    positions = points.cage(obj)[0]
    return obj.matrix_world @ Vector(positions[3 * i:3 * i + 3])


def state(obj):
    """Everything a drag may change, for comparing."""
    snap = points._snapshot(obj)
    return [list(map(list, s[2])) if isinstance(s, tuple) else list(s) for s in snap]


replay = []


def remember(name, obj):
    """The last `sync_points` for `obj`, with Blender's own answer beside it,
    for the Swift to read back."""
    pushed = [p for p in bridge.points if p['name'] == obj.name]
    if not pushed:
        check(name + ": the points were pushed", False)
        return
    p = pushed[-1]
    positions = list(points.cage(obj)[0]) if obj.mode == 'EDIT' else []
    replay.append(dict(name=name, object=obj.name, type=obj.type, record=p['record'],
                       positions=p['positions'], flags=p['flags'], lines=p['lines'],
                       selected=selected(obj) if obj.mode == 'EDIT' else [], blender=positions))


objects = fixtures.build()
circle, bez, path, lattice, cube, free, rider = (objects[n] for n in ("Circle", "Bez", "Path", "Lattice", "Cube",
                                                                     "Free", "Rider"))
print("  undo stack:", bpy.ops.ed.undo_push(message="Original"))
# The app's context for Blender's own transform, which the checks below hold
# the app's commits to: the GPU initialised and the startup screen's 3D View
# (`_blenderkit_knife` builds the same on the device).
gpu.init()
WINDOW = bpy.context.window_manager.windows[0]
AREA = next(a for a in WINDOW.screen.areas if a.type == 'VIEW_3D')
REGION = next(r for r in AREA.regions if r.type == 'WINDOW')


def blenders_turn(obj, pivot, probe=None):
    """`obj`'s points after Blender's own half turn about Z with no centre
    given, `pivot` its Transform Pivot Point, in the 3D View; then put back.
    What Blender itself pivots on, for the app's commit to be held to. A half
    turn, since in the 3D View Blender turns the other way about Z from a
    call without one, and half a turn either way lands every point in the
    same place. With `probe`, an entry the turn moves, also the pivot itself:
    the midpoint of that entry's two places."""
    keep = points._snapshot(obj)
    before = world(obj, probe) if probe is not None else None
    bpy.context.scene.tool_settings.transform_pivot_point = pivot
    with bpy.context.temp_override(window=WINDOW, screen=WINDOW.screen, area=AREA, region=REGION):
        result = bpy.ops.transform.rotate(value=3.1416, orient_axis='Z')
    turned = state(obj)
    centre = (before + world(obj, probe)) / 2 if probe is not None else None
    points._put_back(obj, keep)
    bpy.context.scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
    return result, turned, centre


def gap(a, b):
    """The largest difference between two `state`s, or None when their
    shapes differ."""
    flat = lambda s_: [v for part in s_ for v in (part if not isinstance(part[0], list) else
                                                  [x for column in part for x in column])]
    fa, fb = flat(a), flat(b)
    return max((abs(x - y) for x, y in zip(fa, fb)), default=0.0) if len(fa) == len(fb) else None


def activate(obj):
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj


# ---------------------------------------------------------------------------
print("Edit Mode in and out")
for obj in (circle, lattice):
    activate(obj)
    ran(obj.name + ": Edit Curve / Edit Lattice", "ENTER_EDIT")
    check(obj.name + ": in Blender's Edit Mode", obj.mode == 'EDIT', obj.mode)
    ran(obj.name + ": Done", "LEAVE_EDIT")
    check(obj.name + ": back in Object Mode", obj.mode == 'OBJECT', obj.mode)
    ran(obj.name + ": Tab in", "TOGGLE_EDIT")
    check(obj.name + ": Tab put it in Edit Mode", obj.mode == 'EDIT')
    ran(obj.name + ": Tab out", "TOGGLE_EDIT")
    check(obj.name + ": Tab took it out", obj.mode == 'OBJECT')
bpy.ops.object.text_add(location=(0, 6, 0))
text = bpy.context.object
activate(text)
error = run("ENTER_EDIT")
check("a text object is refused in a sentence",
      error == "Edit Mode works on meshes, curves and lattices here, and Text is a text object.", error)
check("and left in Object Mode", text.mode == 'OBJECT')
activate(bpy.data.objects["Light"])
error = run("TOGGLE_EDIT")
check("Tab on a light is refused in a sentence",
      error == "Edit Mode works on meshes, curves and lattices here, and Light is a light.", error)
activate(circle)
error = run("SCULPT_MODE")
check("Sculpt Mode stays a mesh's: refused for a curve",
      error == "Sculpt Mode works on meshes, and Circle is a curve. Select a mesh first.", error)
check("and the curve left in Object Mode", circle.mode == 'OBJECT')

# ---------------------------------------------------------------------------
print("The mirror: a lattice drawn, points pushed while editing")
bridge.pushes.clear(); bridge.points.clear(); bridge.edges.clear()
activate(lattice)
sync.sync()
pushed = [p for p in bridge.pushes if p['name'] == 'Lattice']
check("a lattice reaches the viewport as its grid: 12 points, no triangles",
      len(pushed) == 1 and len(pushed[0]['positions']) == 36 and pushed[0]['triangles'] == 0,
      pushed and (len(pushed[0]['positions']), pushed[0]['triangles']))
check("drawn by its 20 lines", len(bridge.edges.get('Lattice', [])) == 40, len(bridge.edges.get('Lattice', [])))
ev = lattice.evaluated_get(bpy.context.evaluated_depsgraph_get()).data
evaluated = [c for p in ev.points for c in p.co_deform]
check("where the evaluated lattice has its points",
      pushed and max(abs(a - b) for a, b in zip(pushed[0]['positions'], evaluated)) < 1e-6)
mine = [p for p in bridge.points if p['name'] in ('Lattice', 'Circle', 'Bez', 'Path', 'Free')]
check("every curve and lattice sends its settings, and no points outside Edit Mode",
      sorted(p['name'] for p in mine) == ['Bez', 'Circle', 'Free', 'Lattice', 'Path']
      and all(not p['flags'] for p in mine), [(p['name'], len(p['flags'])) for p in mine])
fixtures.edit(circle)
bridge.points.clear()
sync.sync()
mine = [p for p in bridge.points if p['name'] == 'Circle']
check("in Edit Mode the circle's 12 points go with the pass",
      len(mine) == 1 and len(mine[0]['flags']) == 12 and mine[0]['during_pass'] == 1)
remember("entering Edit Mode", circle)
bpy.ops.ed.undo_push(message="Toggle Edit Mode")

# ---------------------------------------------------------------------------
print("Taps and a box")
for block in ("TAP_KNOT", "TAP_HANDLE", "BOX"):
    bridge.points.clear()
    ran(block, block)
    check(block + ": Blender holds what the Swift chose", selected(circle) == expect(block + "_EXPECT")
          or (block == "BOX" and selected(circle) == expect("BOX_EXPECT")),
          (selected(circle), expect(block + "_EXPECT")))
    if block != "BOX":
        check(block + ": the tap's read-back carries the points, outside a pass",
              any(p['name'] == 'Circle' and p['during_pass'] == 0 for p in bridge.points))
        remember(block, circle)
error = run("TAP_KNOT")
check("a stale index is ignored, not an error",
      points.select("Circle", [3, 4, 5, 999]) is None and selected(circle) == [3, 4, 5])
bpy.ops.ed.undo_push(message="Select")

# ---------------------------------------------------------------------------
print("A drag: Blender previews every frame, and the release commits that frame")
before = state(circle)
knot_before = world(circle, 4)
count = steps()
ran("the drag begins", "DRAG_BEGIN")
check("Blender holds the drag", points.dragging())
bridge.meshes.clear()
frames = []
for k, dz in enumerate((0.25, 0.5, 0.75)):
    ran("frame %d" % k, "DRAG_FRAME_%d" % k)
    frames.append(state(circle))
    moved = world(circle, 4) - knot_before
    check("frame %d: the knot moved %.2f along global Z, from where it began" % (k, dz),
          (moved - Vector((0, 0, dz))).length < 1e-5, tuple(moved))
check("each frame mirrored the circle's wire to the viewport",
      sum(1 for m in bridge.meshes if m['name'] == 'Circle') == 3)
check("the frames pushed no undo step", steps() == count, (count, steps()))
neighbour = state(circle)
check("Blender recalculated the next point's Auto handle, which no rigid preview would",
      neighbour[0][1][6:9] != before[0][1][6:9])
ran("the release", "DRAG_COMMIT")
committed = state(circle)
check("the commit is exactly the last frame, every field", committed == frames[-1])
check("the drag is over", not points.dragging())
bpy.ops.ed.undo_push(message="Move")
check("one undo step for the whole drag", steps() == count + 1, (count, steps()))
bpy.ops.ed.undo()
check("Undo puts every point back", state(circle) == before)
bpy.ops.ed.redo()
check("Redo brings the commit back", state(circle) == committed)
check("the commit's line is the bare operator", blocks["DRAG_COMMIT"].strip().splitlines()[-1].startswith(
    "bpy.ops.transform.translate(value=(0.0000, 0.0000, 0.7500)"), blocks["DRAG_COMMIT"].splitlines()[-1])

before = state(circle)
ran("a drag begins again", "DRAG_BEGIN")
ran("and moves", "DRAG_FRAME_1")
ran("and is cancelled", "DRAG_CANCEL")
check("a cancelled drag leaves every point as it was", state(circle) == before)
check("and is over", not points.dragging())

print("A turn about the median the gizmo showed")
# Back to the step before the move, where the points are the ones the Swift
# made its gizmo from.
bpy.ops.ed.undo()
check("Undo returns to the points the gizmo was made from", selected(circle) == [3, 4, 5])
pivot = Vector(float(v) for v in blocks["TURN_PIVOT"].split(","))
# Blender's own turn of the same points, with no centre given, is what the
# app's pivot is held to: this check once computed "Blender's median" with
# the Swift's own formula, and could not see a pivot Blender does not use.
own, _, centre = blenders_turn(circle, 'MEDIAN_POINT', probe=4)
check("the turn's centre is the point Blender's own turn of the tapped knot pivots on",
      own == {'FINISHED'} and (Vector((centre.x, centre.y, pivot.z)) - pivot).length < 1e-4,
      (own, tuple(centre), tuple(pivot)))
knot_before = world(circle, 4)
ran("the turn begins", "TURN_BEGIN")
ran("a frame", "TURN_FRAME")
frame = state(circle)
ran("the release", "TURN_COMMIT")
check("the turn's commit is its frame", state(circle) == frame)
expected = Matrix.Translation(pivot) @ Matrix.Rotation(0.6, 4, 'Z') @ Matrix.Translation(-pivot) @ knot_before
check("the knot turned 0.6 about Z through the pivot", (world(circle, 4) - expected).length < 1e-4,
      (tuple(world(circle, 4)), tuple(expected)))
bpy.ops.ed.undo_push(message="Rotate")
ran("a scale begins", "SCALE_BEGIN")
ran("a frame", "SCALE_FRAME")
frame = state(circle)
ran("the release", "SCALE_COMMIT")
check("the scale's commit is its frame", state(circle) == frame)
bpy.ops.ed.undo_push(message="Resize")

# ---------------------------------------------------------------------------
print("Free handles of unequal length: the app's turn against Blender's own")
fixtures.edit(free)
free_start = points._snapshot(free)
for k in range(int(blocks["FREE_CASES"])):
    points._put_back(free, free_start)
    run("FREE_%d_SELECT" % k)
    chosen = selected(free)
    setting = blocks["FREE_%d_PIVOT" % k].strip()
    own, blenders, _ = blenders_turn(free, setting)
    error = run("FREE_%d_TURN" % k)
    apps = state(free)
    worst = gap(apps, blenders)
    check("Free %s, %s: the app's turn is Blender's own" % (chosen, setting),
          error is None and own == {'FINISHED'} and worst is not None and worst < 1e-3, (error, own, worst))
points._put_back(free, free_start)
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------------
print("An empty riding Bez by Follow Path follows Bez's drag")
check("the mirror says the rider depends on Bez", "Bez" in sync._relations(rider)[1], sync._relations(rider))
fixtures.edit(bez)
ran("a tap on Bez's first knot", "RIDER_SELECT")
bez_start = state(bez)
start = rider.evaluated_get(bpy.context.evaluated_depsgraph_get()).matrix_world.translation.copy()
ran("the drag begins, the rider following", "RIDER_BEGIN")
bridge.frames.clear()
ran("a frame of 0.5 up", "RIDER_FRAME")
held = rider.evaluated_get(bpy.context.evaluated_depsgraph_get()).matrix_world.translation.copy()
sent_frames = [f for f in bridge.frames if 'Rider' in f['names']]
shown = None
if sent_frames:
    f = sent_frames[-1]
    m = f['matrices'][16 * f['names'].index('Rider'):][:16]
    shown = Vector((m[3], m[7], m[11]))
print("  measured: the rider went from %s to %s in Blender; the frame showed %s" % (
    tuple(round(v, 4) for v in start), tuple(round(v, 4) for v in held), shown and tuple(round(v, 4) for v in shown)))
check("Blender moved the rider with the knot", (held - start).length > 0.4, (tuple(start), tuple(held)))
check("the frame showed the rider where Blender has it", shown is not None and (shown - held).length < 1e-5,
      (shown, tuple(held)))
ran("and is cancelled", "DRAG_CANCEL")
back = rider.evaluated_get(bpy.context.evaluated_depsgraph_get()).matrix_world.translation.copy()
check("the cancel put Bez and the rider back, and showed the rider back", state(bez) == bez_start
      and (back - start).length < 1e-6 and bridge.frames and
      (Vector(bridge.frames[-1]['matrices'][3:12:4]) - start).length < 1e-5)
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------------
print("Two curves in Edit Mode at once")
bpy.ops.object.mode_set(mode='OBJECT')
for other in bpy.context.view_layer.objects:
    other.select_set(other in (circle, bez))
bpy.context.view_layer.objects.active = circle
bpy.ops.object.mode_set(mode='EDIT')
check("Blender takes both curves into Edit Mode", circle.mode == 'EDIT' and bez.mode == 'EDIT')
bpy.ops.curve.select_all(action='SELECT')
ran("a tap on the circle's knot", "TAP_KNOT")
check("deselects the other curve's points, which the viewport does not draw",
      selected(circle) == [3, 4, 5] and selected(bez) == [])
bpy.ops.curve.select_all(action='SELECT')
bez_before, circle_before = state(bez), state(circle)
ran("a drag begins with both curves' points selected", "DRAG_BEGIN")
for k in range(3):
    ran("frame %d" % k, "DRAG_FRAME_%d" % k)
bez_frame = state(bez)
moved = [abs(a - b) for a, b in zip(bez_frame[0][0], bez_before[0][0])]
check("the other curve moved once, by the last frame's value, not by every frame's",
      max(moved) > 0.7 and max(moved) < 0.75 / 1.0 + 1e-4, max(moved))
ran("and is cancelled", "DRAG_CANCEL")
check("a cancel puts both curves back", state(bez) == bez_before and state(circle) == circle_before)
bpy.ops.object.mode_set(mode='OBJECT')
for other in bpy.context.view_layer.objects:
    other.select_set(other == circle)

# ---------------------------------------------------------------------------
print("The lattice: a box over its top, a drag, and the cube under it")
bpy.ops.object.mode_set(mode='OBJECT')
dependencies = sync._relations(cube)
check("the mirror says the cube depends on the lattice", "Lattice" in str(dependencies), dependencies)


def cube_top():
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = cube.evaluated_get(depsgraph).to_mesh()
    top = max((cube.matrix_world @ v.co).z for v in mesh.vertices)
    cube.evaluated_get(depsgraph).to_mesh_clear()
    return top


top_start = cube_top()
fixtures.edit(lattice)
bpy.ops.ed.undo_push(message="Toggle Edit Mode")
bridge.points.clear()
ran("the box", "LATTICE_BOX")
check("Blender holds the top layer the Swift boxed", selected(lattice) == expect("LATTICE_BOX_EXPECT"),
      (selected(lattice), expect("LATTICE_BOX_EXPECT")))
remember("the lattice box", lattice) if bridge.points else None
bpy.ops.ed.undo_push(message="Box Select")
before = state(lattice)
count = steps()
ran("the drag begins", "LATTICE_BEGIN")
bridge.meshes.clear()
ran("a frame", "LATTICE_FRAME")
check("the frame mirrored the lattice and the cube it deforms",
      {m['name'] for m in bridge.meshes} == {'Lattice', 'Cube'}, {m['name'] for m in bridge.meshes})
cube_frame = [m for m in bridge.meshes if m['name'] == 'Cube']
top_frame = max(cube_frame[0]['co'][2::3]) if cube_frame else None
ran("the release", "LATTICE_COMMIT")
top_end = cube_top()
print("  measured: the cube's top went from z %.4f to %.4f (frame of 0.1: %.4f)" % (
    top_start, top_end, (cube.matrix_world @ Vector((0, 0, top_frame))).z if top_frame is not None else float('nan')))
check("the lattice's top layer rose 0.2", all(
    abs((lattice.matrix_world @ Vector(state(lattice)[0][3 * i:3 * i + 3])).z
        - (lattice.matrix_world @ Vector(before[0][3 * i:3 * i + 3])).z - 0.2) < 1e-5
    for i in expect("LATTICE_BOX_EXPECT")))
check("and the cube under its Lattice modifier rose with it", top_end > top_start + 0.1, (top_start, top_end))
bpy.ops.ed.undo_push(message="Move")
check("one undo step", steps() == count + 1)
bpy.ops.ed.undo()
check("Undo puts the lattice back, and the cube with it", state(lattice) == before and abs(cube_top() - top_start) < 1e-6)
bpy.ops.ed.redo()

# ---------------------------------------------------------------------------
print("The Curve menu")
fixtures.edit(bez)
bpy.ops.curve.select_all(action='SELECT')


def counts(obj):
    return [len(s.bezier_points) if s.type == 'BEZIER' else len(s.points) for s in obj.data.splines]


ran("Subdivide", "SUBDIVIDE")
check("Subdivide: 2 points become 3", counts(bez) == [3], counts(bez))
bpy.ops.curve.select_all(action='SELECT')
ran("Subdivide, 2 cuts", "SUBDIVIDE_2")
check("2 cuts in each of 2 segments: 7 points", counts(bez) == [7], counts(bez))
last = 3 * (counts(bez)[0] - 1)
points.select("Bez", [last, last + 1, last + 2])
end = bez.data.splines[0].bezier_points[-1].co.copy()
ran("Extrude", "EXTRUDE")
check("Extrude adds a point on the end, where it was, selected",
      counts(bez) == [8] and (bez.data.splines[0].bezier_points[-1].co - end).length < 1e-6
      and bez.data.splines[0].bezier_points[-1].select_control_point
      and not bez.data.splines[0].bezier_points[-2].select_control_point, counts(bez))
for identifier, wanted in (("AUTOMATIC", 'AUTO'), ("VECTOR", 'VECTOR'), ("ALIGNED", 'ALIGNED'),
                           ("FREE_ALIGN", 'FREE')):
    ran("Set Handle Type ▸ " + identifier, "HANDLE_" + identifier)
    p = bez.data.splines[0].bezier_points[-1]
    check(identifier + ": the selected point's handles are " + wanted,
          p.handle_left_type == wanted and p.handle_right_type == wanted,
          (p.handle_left_type, p.handle_right_type))
ran("Toggle Free/Align", "HANDLE_TOGGLE_FREE_ALIGN")
check("Toggle Free/Align: Free becomes Aligned", bez.data.splines[0].bezier_points[-1].handle_left_type == 'ALIGNED')
ran("Toggle Cyclic", "CYCLIC")
check("Toggle Cyclic closes the spline", bez.data.splines[0].use_cyclic_u)
ran("Toggle Cyclic again", "CYCLIC")
check("and opens it", not bez.data.splines[0].use_cyclic_u)
first = bez.data.splines[0].bezier_points[0].co.copy()
lastco = bez.data.splines[0].bezier_points[-1].co.copy()
ran("Switch Direction", "SWITCH")
check("Switch Direction reverses the points", (bez.data.splines[0].bezier_points[0].co - lastco).length < 1e-6
      and (bez.data.splines[0].bezier_points[-1].co - first).length < 1e-6)
points.select("Bez", [1])
ran("Delete Vertices", "DELETE_VERT")
check("Delete ▸ Vertices: 8 points become 7", counts(bez) == [7], counts(bez))
points.select("Bez", [4, 7])
ran("Delete Segments", "DELETE_SEGMENT")
check("Delete ▸ Segments between points 1 and 2 splits the spline", len(bez.data.splines) == 2, counts(bez))
ran("Select All", "CURVE_ALL")
check("Select All selects every point and handle", len(selected(bez)) == len(points.cage(bez)[1]))
ran("Invert", "CURVE_INVERT")
check("Invert deselects them all", selected(bez) == [])
ran("Select None", "CURVE_NONE")
for block, phrase in (("CYCLIC", "Toggle Cyclic needs"), ("SWITCH", "Switch Direction needs"),
                      ("SUBDIVIDE", "Subdivide needs"), ("DELETE_VERT", "Nothing is selected"),
                      ("DELETE_SEGMENT", "Delete Segments needs"), ("EXTRUDE", "Extrude needs"),
                      ("HANDLE_VECTOR", "Set Handle Type works")):
    before_rows = (counts(bez), [(p.handle_left_type, p.co.copy()) for s_ in bez.data.splines for p in s_.bezier_points])
    error = run(block)
    check(block + " with nothing selected says so, and changes nothing",
          error is not None and error.startswith(phrase) and (counts(bez), [
              (p.handle_left_type, p.co.copy()) for s_ in bez.data.splines for p in s_.bezier_points]) == before_rows,
          error)
points.select("Bez", [1])
error = run("SUBDIVIDE")
check("Subdivide with one point selected, which Blender answers FINISHED and does nothing, says so",
      error is not None and error.startswith("Subdivide needs"), error)
points.select("Bez", [1])
ran("Hide Selected", "CURVE_HIDESELECTED")
check("the hidden point is flagged hidden in the cage", points.cage(bez)[1][1] & points.HIDDEN)
ran("Reveal", "CURVE_REVEAL")
check("and comes back", not any(f & points.HIDDEN for f in points.cage(bez)[1]))

print("The Lattice menu")
fixtures.edit(lattice)
ran("Select All", "LATTICE_ALL")
check("every lattice point selected", len(selected(lattice)) == len(lattice.data.points))
co = points._read(lattice.data.points, 'co_deform', 'f', 3)
co[0] += 0.3
lattice.data.points.foreach_set('co_deform', co)
ran("Make Regular", "MAKE_REGULAR")
grid = points._read(lattice.data.points, 'co_deform', 'f', 3)
U, V, W = lattice.data.points_u, lattice.data.points_v, lattice.data.points_w


def at(u, v, w):
    p = (w * V + v) * U + u
    return Vector(grid[3 * p:3 * p + 3])


du, dv, dw = at(1, 0, 0) - at(0, 0, 0), at(0, 1, 0) - at(0, 0, 0), at(0, 0, 1) - at(0, 0, 0)
regular = max((at(u, v, w) - (at(0, 0, 0) + u * du + v * dv + w * dw)).length
              for u in range(U) for v in range(V) for w in range(W))
print("  measured: Make Regular's grid spans %s, steps %s %s %s" % (
    tuple(round(c, 3) for c in at(U - 1, V - 1, W - 1) - at(0, 0, 0)),
    tuple(round(c, 3) for c in du), tuple(round(c, 3) for c in dv), tuple(round(c, 3) for c in dw)))
check("Make Regular puts every point back on an even grid", regular < 1e-5, regular)
ran("Flip U", "FLIP_U")

# ---------------------------------------------------------------------------
print("The Data tab")
activate(bez)


def evaluated_counts(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = obj.evaluated_get(depsgraph).to_mesh()
    result = (len(mesh.vertices), len(mesh.polygons)) if mesh is not None else (0, 0)
    obj.evaluated_get(depsgraph).to_mesh_clear()
    return result


fresh = bpy.data.objects.new("Plain", bpy.data.curves.new("Plain", 'CURVE'))
bpy.context.scene.collection.objects.link(fresh)
spline = fresh.data.splines.new('BEZIER')
spline.bezier_points.add(3)
for i, p in enumerate(spline.bezier_points):
    p.co = (math.cos(i * math.pi / 2), math.sin(i * math.pi / 2), 0)
    p.handle_left_type = p.handle_right_type = 'AUTO'
spline.use_cyclic_u = True
fresh.data.dimensions = '3D'
wire = evaluated_counts(fresh)
fresh.data.fill_mode = 'HALF'
check("a 3D curve with no depth and no extrusion: Fill Mode changes nothing (the Data tab's note)",
      evaluated_counts(fresh) == wire, (wire, evaluated_counts(fresh)))
fresh.data.dimensions = '2D'
fresh.data.fill_mode = 'BOTH'
flat = evaluated_counts(fresh)
print("  measured: a closed 2D curve with Fill Mode Both evaluates to %d vertices and %d faces" % flat)
check("a closed 2D curve is filled with no depth: the note is for 3D curves alone", flat[1] > 0, flat)
bpy.data.objects.remove(fresh)

for block, prop, wanted in (("BEVEL_DEPTH", "bevel_depth", 0.1), ("BEVEL_RESOLUTION", "bevel_resolution", 2),
                            ("EXTRUDE_DEPTH", "extrude", 0.25), ("FILL_HALF", "fill_mode", 'HALF'),
                            ("RESOLUTION_U", "resolution_u", 4)):
    ran(block, block)
    value = getattr(bez.data, prop)
    check(block + ": Blender holds " + str(wanted), value == wanted or (isinstance(wanted, float)
                                                                    and abs(value - wanted) < 1e-6), value)
check("a bevelled curve has a surface", evaluated_counts(bez)[1] > 0, evaluated_counts(bez))
ran("2D", "DIMENSIONS_2D")
check("2D: the curve is flat, and its fill mode one of the 2D list",
      bez.data.dimensions == '2D' and bez.data.fill_mode in ('NONE', 'BACK', 'FRONT', 'BOTH'), bez.data.fill_mode)
bridge.points.clear()
sync.sync()
remember("the Data tab's changes", bez)
check("the record says what the fields wrote", any(
    'bevel_depth=0.1' in p['record'] and 'dimensions=2D' in p['record'] and 'resolution_u=4.0' in p['record']
    for p in bridge.points if p['name'] == 'Bez'))

fixtures.edit(lattice)
ran("Resolution U 4, in Edit Mode", "LATTICE_U")
ran("Resolution W 3", "LATTICE_W")
check("the lattice is 4 x 2 x 3 = 24 points, its edit lattice too", len(lattice.data.points) == 24
      and len(points.cage(lattice)[1]) == 24, len(lattice.data.points))
ran("Interpolation U Linear", "LATTICE_LINEAR")
ran("Outside", "LATTICE_OUTSIDE")
check("Linear and Outside held", lattice.data.interpolation_type_u == 'KEY_LINEAR' and lattice.data.use_outside)
bridge.points.clear()
sync.sync()
remember("the lattice's new resolution, in Edit Mode", lattice)
pushed = [p for p in bridge.points if p['name'] == 'Lattice']
check("its grid goes to Edit Mode with 24 points and their lines",
      pushed and len(pushed[-1]['flags']) == 24 and len(pushed[-1]['lines']) == len(points.lattice_lines(4, 2, 3)))
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------------
print("Add ▸ Lattice")
names = set(bpy.data.objects.keys())
namespace = {"bpy": bpy}
exec(compile(blocks["ADD_LATTICE"], "<ADD_LATTICE>", "exec"), namespace)
made = [bpy.data.objects[n] for n in set(bpy.data.objects.keys()) - names]
check("Add Lattice makes one lattice at the cursor's place", len(made) == 1 and made[0].type == 'LATTICE'
      and (made[0].location - Vector((1, 2, 3))).length < 1e-6, made)
check("its panel can re-run it", namespace.get("_bk_adjustable") is True)
lattices = len(bpy.data.lattices)
ran("Radius 2 in its panel", "ADD_LATTICE_RERUN", subject=made[0].name if made else "")
remade = [bpy.data.objects[n] for n in set(bpy.data.objects.keys()) - names]
check("the re-run replaces it and its data-block: one new lattice, no orphan",
      len(remade) == 1 and len(bpy.data.lattices) == lattices, (len(remade), len(bpy.data.lattices), lattices))
if remade:
    keyed = remade[0]
    plain = points.record(keyed)
    keyed.shape_key_add(name="Basis")
    try:
        keyed.data.points_u = 4
        refused = None
    except AttributeError as error:
        refused = str(error)
    check("a lattice with a shape key keeps its resolution, and its record says so",
          "points_editable=1" in plain and "points_editable=0" in points.record(keyed)
          and refused is not None and "read-only" in refused, (plain, points.record(keyed), refused))

# ---------------------------------------------------------------------------
print("A drag Blender's state moves out from under")


def refetch():
    """The objects again, after an Undo that may have reloaded them: an old
    reference reads "StructRNA of type Object has been removed"."""
    global circle, bez, path, lattice, cube, free, rider
    circle, bez, path, lattice, cube, free, rider = (bpy.data.objects[n] for n in (
        "Circle", "Bez", "Path", "Lattice", "Cube", "Free", "Rider"))


# The hold (BpySession.pointDragOpen) keeps Tab, Done and Undo from running
# under a drag; these are what the frames do if one ever got through.
activate(circle)
fixtures.edit(circle)
points.select("Circle", [3, 4, 5])
bpy.ops.ed.undo_push(message="Select")
place = circle.matrix_world.copy()
ran("a drag begins", "DRAG_BEGIN")
ran("a frame", "DRAG_FRAME_0")
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.ed.undo_push(message="Toggle Edit Mode")
error = run("DRAG_FRAME_1")
check("the curve left Edit Mode (Tab): the next frame is refused, in words",
      error is not None and "left Edit Mode" in error, error)
check("and moved nothing: the object stayed where it was", circle.matrix_world == place)
error = run("DRAG_COMMIT")
check("the release is refused too, and moves nothing", error is not None and "left Edit Mode" in error
      and circle.matrix_world == place and not points.dragging(), error)
bpy.ops.ed.undo()
refetch()
check("Undo takes the Tab back to the selection", circle.mode == 'EDIT' and selected(circle) == [3, 4, 5],
      (circle.mode, selected(circle)))
bpy.ops.transform.translate(value=(0.5, 0, 0))
bpy.ops.ed.undo_push(message="Move")
moved = state(circle)
ran("a drag begins after a move", "DRAG_BEGIN")
ran("a frame", "DRAG_FRAME_0")
bpy.ops.ed.undo()
refetch()
undone = state(circle)
check("Undo between two frames takes the earlier move back", undone != moved)
error = run("DRAG_FRAME_1")
check("the next frame is refused, in words, and leaves the undone points", error is not None
      and "changed during the drag" in error and state(circle) == undone, error)
error = run("DRAG_COMMIT")
check("the release is refused, and Blender keeps what the Undo left", error is not None
      and state(circle) == undone and not points.dragging(), error)
bpy.ops.ed.redo()
refetch()
check("Redo brings the move back", state(circle) == moved)
ran("a drag begins", "DRAG_BEGIN")
ran("a frame", "DRAG_FRAME_0")
bpy.ops.ed.undo()
refetch()
ran("and is cancelled after an Undo", "DRAG_CANCEL")
check("a cancel after an Undo keeps what the Undo left, and ends the drag",
      state(circle) == undone and not points.dragging())
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------------
print("Delete Segments on a cyclic spline")


def fresh_ring():
    """A Bézier circle as Add ▸ Curve ▸ Circle makes it, in Edit Mode."""
    bpy.ops.curve.primitive_bezier_circle_add(location=(0, -6, 0))
    made = bpy.context.object
    activate(made)
    bpy.ops.object.mode_set(mode='EDIT')
    return made


for chosen, label in (([1, 4], "knots 1 and 2"), ([1, 10], "the closing pair")):
    ring = fresh_ring()
    points.select(ring.name, chosen)
    counted = len(ring.data.splines[0].bezier_points)
    error = run("DELETE_SEGMENT")
    check("Delete Segments on %s of a cyclic spline opens it, every point kept, and says it was done" % label,
          error is None and not ring.data.splines[0].use_cyclic_u
          and len(ring.data.splines[0].bezier_points) == counted, (error, ring.data.splines[0].use_cyclic_u))
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.data.objects.remove(ring)
ring = fresh_ring()
points.select(ring.name, [1, 7])
before_rows = (ring.data.splines[0].use_cyclic_u, state(ring))
error = run("DELETE_SEGMENT")
check("knots 1 and 3, not neighbours: refused, and nothing changed", error is not None
      and error.startswith("Delete Segments needs") and (ring.data.splines[0].use_cyclic_u, state(ring)) == before_rows,
      error)
bpy.ops.object.mode_set(mode='OBJECT')
bpy.data.objects.remove(ring)

# ---------------------------------------------------------------------------
print("Nothing here takes Blender down")
activate(circle)
for label, action, refused in (
        ("select out of Edit Mode", lambda: points.select("Circle", [0]), True),
        ("select on a mesh", lambda: points.select("Cube", [0]), True),
        ("a drag out of Edit Mode", lambda: points.begin_drag("Circle"), True),
        ("restore with no drag", lambda: points.restore(), True),
        ("cancel with no drag", lambda: points.cancel(), False),
        ("mirror with no drag", lambda: points.mirror(), False),
        ("settle with no drag", lambda: points.settle(), False)):
    before_all = (circle.mode, state(circle), points.dragging())
    try:
        result = action()
        said = None
    except RuntimeError as error:
        said = str(error)
    check("%s: %s, and nothing changed" % (label, "refused in words" if refused else "quietly nothing"),
          (said is not None) == refused and (circle.mode, state(circle), points.dragging()) == before_all, said)
fixtures.edit(circle)
points.begin_drag("Circle")
bpy.ops.curve.select_all(action='SELECT')
bpy.ops.curve.subdivide()
try:
    points.restore()
    check("a curve changed under a drag is refused, not overwritten", False)
except RuntimeError as error:
    check("a curve changed under a drag is refused, not overwritten", "changed" in str(error), error)
points.cancel()
check("and the drag can still be cancelled", not points.dragging())
bpy.ops.curve.select_all(action='SELECT')
bpy.ops.curve.delete(type='VERT')
check("every point deleted: the curve has no spline", len(circle.data.splines) == 0)
check("its cage is empty", len(points.cage(circle)[1]) == 0)
error = run("EMPTY_DONE")
check("Done after a tap on the emptied curve: no mesh selection pushed, back in Object Mode",
      error is None and circle.mode == 'OBJECT', error)
fixtures.edit(circle)
points.begin_drag("Circle")
print("  a move with no points:", bpy.ops.transform.translate(value=(0, 0, 1)))
points.mirror()
points.cancel()
bridge.points.clear()
sync.sync()
check("the pass still sends the empty curve's settings", any(p['name'] == 'Circle' for p in bridge.points))
for block in ("SUBDIVIDE", "EXTRUDE", "DELETE_VERT", "CYCLIC", "SWITCH", "HANDLE_AUTOMATIC", "CURVE_ALL"):
    print("  on an empty curve, %s: %s" % (block, run(block) or "FINISHED"))
bpy.ops.object.mode_set(mode='OBJECT')
activate(circle)
ran("Edit Mode on a curve with no splines", "ENTER_EDIT")
bpy.ops.object.mode_set(mode='OBJECT')
fixtures.edit(lattice)
for u, v, w in ((1, 1, 1), (64, 2, 2)):
    lattice.data.points_u, lattice.data.points_v, lattice.data.points_w = u, v, w
    positions, flags, lines = points.cage(lattice)
    check("a %d x %d x %d lattice: %d points, %d lines" % (u, v, w, len(flags), len(lines) // 2),
          len(flags) == u * v * w and len(lines) // 2 == (u - 1) * v * w + u * (v - 1) * w + u * v * (w - 1))
    bpy.ops.lattice.select_all(action='SELECT')
    points.begin_drag("Lattice", ["Cube"])
    bpy.ops.transform.translate(value=(0, 0, 0.1))
    points.mirror()
    points.cancel()
bpy.ops.object.mode_set(mode='OBJECT')
check("Blender is still here", bpy.context.scene is not None)

json.dump(replay, open(REPLAY, "w"))
print(("%d failed" % fail) if fail else "all passed")
sys.exit(1 if fail else 0)
