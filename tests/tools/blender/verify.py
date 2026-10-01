"""Snapping, the pivot point and proportional editing, run by the Blender they
run on.

scripts/run-tools-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: no user settings, and no 3D View area — `bpy.context
.area` is None, as it is for the bpy module on a device. Every string checked
here is the one the Swift sends, printed by tests/tools/blender/main.swift.

Two things this is here to hold down, both of which a Swift-only test cannot:

  * that `_blenderkit_tools.snap` does what `bpy.ops.view3d.snap_*` does, since
    those operators cannot be called here at all (their poll is False), and
  * that a rotation lands where the drag's preview left the objects. With no
    View3D, Blender turns a selection about the centre of its bounds whatever
    `transform_pivot_point` says, and the gizmo previews about the median, so
    every pivot has to name its own centre.
"""
import bpy, sys, types, pathlib, importlib.util, json, math, array

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


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


def floats(name):
    return [float(x) for x in blocks[name].split()]


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit` module and records the mirror."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.state = None
        self.relations = []
        self.knots = {}

    def tool_state(self, *values):
        self.state = values

    def sync_relations(self, name, parent, names):
        self.relations.append((name, parent, list(names)))

    def sync_knots(self, name, points):
        self.knots[name] = array.array('f', points).tolist()


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


load("_blenderkit_anim", "Resources/python/site/_blenderkit_anim.py")
tools = load("_blenderkit_tools", "Resources/python/site/_blenderkit_tools.py")
fixtures = load("fixtures", "tests/tools/blender/fixtures.py")


def run(name):
    namespace = {"bpy": bpy}
    exec(compile(blocks[name], "<" + name + ">", "exec"), namespace)


def empty():
    bpy.ops.wm.read_homefile(use_empty=True)


def cubes(places=((0, 0, 0), (4, 0, 0), (10, 0, 0))):
    """A, B and C — the spread the Swift side previews against."""
    empty()
    made = []
    for name, place in zip("ABC", places):
        bpy.ops.mesh.primitive_cube_add(size=2, location=place)
        obj = bpy.context.object
        obj.name = name
        made.append(obj)
    for obj in made:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = made[-1]
    bpy.context.view_layer.update()
    return made


# ---------------------------------------------------------------------------
print("\nthe view3d snap operators are out of reach, which is why snap() exists")
# ---------------------------------------------------------------------------
cubes()
for name in ("snap_cursor_to_center", "snap_cursor_to_selected",
             "snap_selected_to_grid", "snap_selected_to_cursor",
             "snap_selected_to_active", "snap_cursor_to_grid", "snap_cursor_to_active"):
    check("bpy.ops.view3d.%s cannot poll" % name, not getattr(bpy.ops.view3d, name).poll())

# ---------------------------------------------------------------------------
print("\nevery control writes the property it names, and reports it back")
# ---------------------------------------------------------------------------
empty()
ts = bpy.context.scene.tool_settings

run("SET_SNAP_ON")
check("the magnet", ts.use_snap is True)
check("and the mirror was told", bridge.state is not None and bridge.state[0] == 1,
      bridge.state)

run("SET_ELEMENTS")
check("snap elements land in snap_elements_base, not in _individual",
      ts.snap_elements_base == {'VERTEX', 'EDGE', 'FACE_MIDPOINT'}
      and ts.snap_elements_individual == set(),
      (ts.snap_elements_base, ts.snap_elements_individual))
check("reported as the bit field the interface unpacks",
      bridge.state[1] == sum(1 << tools.ELEMENTS.index(n)
                             for n in ('VERTEX', 'EDGE', 'FACE_MIDPOINT')),
      bridge.state[1])

run("SET_INDIVIDUAL")
check("the two projecting elements are their own set",
      ts.snap_elements_individual == {'FACE_NEAREST'}, ts.snap_elements_individual)
check("and reported apart", bridge.state[2] == 1 << tools.INDIVIDUAL.index('FACE_NEAREST'),
      bridge.state[2])

run("SET_TARGET")
check("snap with", ts.snap_target == 'MEDIAN' and bridge.state[3] == tools.TARGETS.index('MEDIAN'))

run("SET_PIVOT")
check("the pivot point",
      ts.transform_pivot_point == 'INDIVIDUAL_ORIGINS'
      and bridge.state[4] == tools.PIVOTS.index('INDIVIDUAL_ORIGINS'))

run("SET_PROPORTIONAL_EDIT")
check("edit mode's proportional switch, and only that one",
      ts.use_proportional_edit is True and ts.use_proportional_edit_objects is False,
      (ts.use_proportional_edit, ts.use_proportional_edit_objects))
run("SET_PROPORTIONAL_OBJECTS")
check("and object mode's", ts.use_proportional_edit_objects is True)
check("both reported", bridge.state[5] == 1 and bridge.state[6] == 1, bridge.state)

run("SET_CONNECTED")
check("connected only", ts.use_proportional_connected is True and bridge.state[7] == 1)

run("SET_FALLOFF")
check("the falloff identifier is the one Blender knows",
      ts.proportional_edit_falloff == 'INVERSE_SQUARE'
      and bridge.state[8] == tools.FALLOFFS.index('INVERSE_SQUARE'))

run("SET_SIZE")
check("the size", abs(ts.proportional_size - 2.5) < 1e-5 and abs(bridge.state[11] - 2.5) < 1e-5)
run("SET_SIZE_HUGE")
check("clamped at both ends to the same number",
      abs(ts.proportional_size - 5000.0) < 1e-3 and abs(bridge.state[11] - 5000.0) < 1e-3,
      (ts.proportional_size, bridge.state[11]))

run("SET_CURSOR")
check("the 3D cursor is written and mirrored",
      tuple(round(v, 4) for v in bpy.context.scene.cursor.location) == (1.5, 0.0, -2.0)
      and tuple(round(v, 4) for v in bridge.state[12:15]) == (1.5, 0.0, -2.0),
      (tuple(bpy.context.scene.cursor.location), bridge.state[12:15]))

check("eleven ints and five doubles, as TransformToolsMirror unpacks them",
      len(bridge.state) == 16 and all(isinstance(v, int) for v in bridge.state[:11])
      and all(isinstance(v, float) for v in bridge.state[11:]), bridge.state)
check("Auto Merge off and its threshold 0.001 at the factory's, and mirrored so",
      ts.use_mesh_automerge is False and bridge.state[9] == 0
      and abs(bridge.state[15] - 0.001) < 1e-9, bridge.state)
run("SET_AUTOMERGE")
check("Auto Merge is use_mesh_automerge", ts.use_mesh_automerge is True and bridge.state[9] == 1)
run("SET_MERGE_THRESHOLD")
check("its threshold is double_threshold",
      abs(ts.double_threshold - 0.0025) < 1e-7 and abs(bridge.state[15] - 0.0025) < 1e-7,
      (ts.double_threshold, bridge.state[15]))
run("SET_MERGE_THRESHOLD_HUGE")
check("clamped to bl_rna's 1 on both sides",
      ts.double_threshold == 1.0 and bridge.state[15] == 1.0, (ts.double_threshold, bridge.state[15]))
run("SET_AUTOMERGE_OFF")
check("and off again", ts.use_mesh_automerge is False and bridge.state[9] == 0)
check("Include Active and Non-edited on at the factory's: both bits",
      bridge.state[10] == 3 and tools.SNAP_FLAGS[:2] == ('use_snap_self', 'use_snap_nonedit'), bridge.state)
check("Split Edges & Faces and Affect Only Parents and Origins are the next three bits",
      tools.SNAP_FLAGS[2:] == ('use_mesh_automerge_and_split', 'use_transform_skip_children',
                               'use_transform_data_origin')
      and int(blocks["FLAGS_ALL"]) == 31, (tools.SNAP_FLAGS, blocks["FLAGS_ALL"]))
run("SET_AUTOMERGE_SPLIT")
check("Split Edges & Faces is use_mesh_automerge_and_split, mirrored as bit 4",
      ts.use_mesh_automerge_and_split is True and bridge.state[10] & 4, bridge.state[10])
run("SET_SKIP_CHILDREN")
check("Affect Only Parents is use_transform_skip_children, bit 8",
      ts.use_transform_skip_children is True and bridge.state[10] & 8, bridge.state[10])
run("SET_DATA_ORIGIN")
check("Affect Only Origins is use_transform_data_origin, bit 16",
      ts.use_transform_data_origin is True and bridge.state[10] & 16, bridge.state[10])
run("SET_AFFECT_OFF")
check("and both off again", not ts.use_transform_skip_children and not ts.use_transform_data_origin
      and bridge.state[10] & 24 == 0, bridge.state[10])
ts.use_mesh_automerge_and_split = False
run("SET_SNAP_SELF_OFF")
check("Include Active is use_snap_self", ts.use_snap_self is False and bridge.state[10] == 2)
run("SET_SNAP_NONEDIT_OFF")
check("Include Non-edited is use_snap_nonedit", ts.use_snap_nonedit is False and bridge.state[10] == 0)
run("SET_INDIVIDUAL_PROJECT")
run("SET_ELEMENTS_NONE")
check("the base set empties beside Face Project, as holdsLastSnapElement allows",
      ts.snap_elements_base == set() and ts.snap_elements_individual == {'FACE_PROJECT'}
      and bridge.state[1] == 0, (ts.snap_elements_base, ts.snap_elements_individual))

# ---------------------------------------------------------------------------
print("\nthe Shift+S menu")
# ---------------------------------------------------------------------------
made = cubes()
bpy.context.scene.cursor.location = (3, 3, 3)
run("SNAP_CURSOR_TO_CENTER")
check("Cursor to World Origin", tuple(bpy.context.scene.cursor.location) == (0, 0, 0))

made = cubes()
bpy.context.scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
run("SNAP_CURSOR_TO_SELECTED")
check("Cursor to Selected takes the median of the origins",
      abs(bpy.context.scene.cursor.location.x - 14 / 3) < 1e-4,
      tuple(bpy.context.scene.cursor.location))

made = cubes()
bpy.context.scene.tool_settings.transform_pivot_point = 'BOUNDING_BOX_CENTER'
run("SNAP_CURSOR_TO_SELECTED")
check("and the centre of the bounds when that is the pivot",
      abs(bpy.context.scene.cursor.location.x - 5.0) < 1e-4,
      tuple(bpy.context.scene.cursor.location))
bpy.context.scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'

made = cubes()
bpy.context.scene.cursor.location = (2, -1, 0.5)
run("SNAP_SELECTION_TO_CURSOR")
check("Selection to Cursor puts every object on it",
      all(tuple(round(v, 4) for v in o.matrix_world.translation) == (2.0, -1.0, 0.5)
          for o in made),
      [tuple(o.location) for o in made])

made = cubes()
bpy.context.scene.cursor.location = (2, -1, 0.5)
run("SNAP_SELECTION_TO_CURSOR_OFFSET")
check("Keep Offset moves the group, holding its shape",
      abs(made[1].location.x - made[0].location.x - 4) < 1e-4
      and abs(made[0].matrix_world.translation.x - (2 - 14 / 3)) < 1e-4,
      [tuple(o.location) for o in made])

made = cubes(places=((0.3, 0.7, -1.2), (4.4, 0, 0), (10, 0, 0)))
run("SNAP_SELECTION_TO_GRID")
check("Selection to Grid rounds each object to the step",
      tuple(round(v, 4) for v in made[0].location) == (0.0, 1.0, -1.0)
      and abs(made[1].location.x - 4.0) < 1e-4,
      [tuple(o.location) for o in made])

made = cubes(places=((0.3, 0.7, -1.2), (4.4, 0.5, 0), (10, 0, 0)))
run("SNAP_SELECTION_TO_ACTIVE")
check("Selection to Active puts the selection on the active object's origin",
      all(tuple(round(v, 4) for v in o.matrix_world.translation) == (10.0, 0.0, 0.0) for o in made),
      [tuple(o.location) for o in made])

made = cubes()
bpy.context.scene.cursor.location = (0.25, -0.75, 1.3)
run("SNAP_CURSOR_TO_GRID")
check("Cursor to Grid rounds the cursor to the step, halves upward as view3d_snap.cc does",
      tuple(round(v, 4) for v in bpy.context.scene.cursor.location) == (0.5, -0.5, 1.5),
      tuple(bpy.context.scene.cursor.location))

made = cubes(places=((0.3, 0.7, -1.2), (4.4, 0.5, 0), (10, 0, 0)))
bpy.context.view_layer.objects.active = made[1]
run("SNAP_CURSOR_TO_ACTIVE")
check("Cursor to Active puts the cursor on the active object",
      tuple(round(v, 4) for v in bpy.context.scene.cursor.location) == (4.4, 0.5, 0.0),
      tuple(bpy.context.scene.cursor.location))

empty()
bpy.ops.mesh.primitive_cube_add(size=2, location=(1, 0, 0))
mesh = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
import bmesh
bm = bmesh.from_edit_mesh(mesh.data)
bm.verts.ensure_lookup_table()
for v in bm.verts:
    v.select = False
bm.select_history.clear()
bm.verts[3].select = True
bm.select_history.add(bm.verts[3])
corner = mesh.matrix_world @ bm.verts[3].co
bmesh.update_edit_mesh(mesh.data)
run("SNAP_CURSOR_TO_ACTIVE")
bpy.ops.object.mode_set(mode='OBJECT')
check("and while editing, on the active vertex",
      (bpy.context.scene.cursor.location - corner).length < 1e-5,
      (tuple(bpy.context.scene.cursor.location), tuple(corner)))

# Blender's own menu, read from its RNA-registered class rather than recalled.
menu = bpy.types.VIEW3D_MT_snap
import inspect
source = inspect.getsource(menu.draw)
titles = [line.split('text="')[1].split('"')[0] for line in source.splitlines() if 'text="' in line]
check("the Snap menu is Blender's, in Blender's order",
      "|".join(titles) == blocks["SNAP_MENU_ORDER"],
      (titles, blocks["SNAP_MENU_ORDER"]))

# A child of a selected parent must not move twice.
made = cubes()
made[1].parent = made[0]
made[1].matrix_parent_inverse = made[0].matrix_world.inverted()
bpy.context.view_layer.update()
bpy.context.scene.cursor.location = (0, 0, 5)
run("SNAP_SELECTION_TO_CURSOR")
# matrix_world is only recomputed when the depsgraph runs.
bpy.context.view_layer.update()
check("a child of a selected parent is moved by the parent alone",
      abs(made[1].matrix_world.translation.z - 5.0) < 1e-4,
      tuple(made[1].matrix_world.translation))

# Edit mode moves the vertices, not the object.
empty()
bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
mesh = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.context.scene.cursor.location = (0, 0, 3)
run("SNAP_SELECTION_TO_CURSOR_OFFSET")
bpy.ops.object.mode_set(mode='OBJECT')
check("while editing, the vertices move and the object stays put",
      abs(mesh.location.z) < 1e-5
      and abs(min(v.co.z for v in mesh.data.vertices) - 2.0) < 1e-4,
      (tuple(mesh.location), [round(v.co.z, 3) for v in mesh.data.vertices]))

# ---------------------------------------------------------------------------
print("\na rotation lands where the drag's preview left it, for every pivot")
# ---------------------------------------------------------------------------
for name in ('MEDIAN_POINT', 'BOUNDING_BOX_CENTER', 'CURSOR', 'ACTIVE_ELEMENT',
             'INDIVIDUAL_ORIGINS'):
    made = cubes()
    bpy.context.scene.cursor.location = (1.5, 0, -2)
    bpy.context.scene.tool_settings.transform_pivot_point = name
    try:
        run("TURN_" + name)
    except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
        check("%s: Blender accepts what it sends" % name, False, exc)
        continue
    check("%s: Blender accepts what it sends" % name, True)
    bpy.context.view_layer.update()
    want = floats("TURN_" + name + "_EXPECT")
    got = []
    for obj in made:
        got += list(obj.matrix_world.translation) + [obj.rotation_euler.z]
    check("%s: and puts every object where the preview did" % name,
          all(abs(a - b) < 2e-3 for a, b in zip(want, got)),
          "want %s got %s" % ([round(v, 3) for v in want], [round(v, 3) for v in got]))

# Median Point cannot be left to the default: with no View3D, Blender turns
# about the bounds centre whatever transform_pivot_point says, and the gizmo
# previews about the median.
check("every pivot but Individual Origins names its centre",
      all("center_override" in blocks["TURN_" + n]
          for n in ('MEDIAN_POINT', 'BOUNDING_BOX_CENTER', 'CURSOR', 'ACTIVE_ELEMENT')))
check("and Median Point's is the median, not the bounds centre",
      "center_override=(4.6667," in blocks["TURN_MEDIAN_POINT"], blocks["TURN_MEDIAN_POINT"])
check("Individual Origins is the helper instead",
      "transform_individual" in blocks["TURN_INDIVIDUAL_ORIGINS"])

# ---------------------------------------------------------------------------
print("\nproportional editing, as operator arguments")
# ---------------------------------------------------------------------------
made = cubes()
bpy.ops.object.select_all(action='DESELECT')
made[0].select_set(True)
bpy.context.view_layer.objects.active = made[0]
# tool_settings alone, which is what the header used to change and nothing else.
bpy.context.scene.tool_settings.use_proportional_edit_objects = False
run("MOVE_PROPORTIONAL")
bpy.context.view_layer.update()
check("the selected object moved", abs(made[0].location.z) > 0.5, tuple(made[0].location))
check("and so did its neighbour, with tool_settings off — the arguments did it",
      abs(made[1].location.z) > 1e-3, tuple(made[1].location))
check("while the far one did not, at this radius",
      abs(made[2].location.z) < 1e-3, tuple(made[2].location))

# ---------------------------------------------------------------------------
print("\nwhat a drag previews is what Blender commits: object mode")
# ---------------------------------------------------------------------------


def build(setup):
    """The Swift side's scene: cubes A, B, C… at its places, its selection and
    active object, its cursor."""
    empty()
    made = []
    for i, place in enumerate(setup["places"]):
        bpy.ops.mesh.primitive_cube_add(size=2, location=place)
        obj = bpy.context.object
        obj.name = chr(65 + i)
        made.append(obj)
    bpy.context.view_layer.update()
    for child, parent in setup.get("parents", ()):
        # Parented where it stands, as Ctrl+P leaves a child.
        made[child].parent = made[parent]
        made[child].matrix_parent_inverse = made[parent].matrix_world.inverted()
    bpy.ops.object.select_all(action='DESELECT')
    for i in setup["selected"]:
        made[i].select_set(True)
    bpy.context.view_layer.objects.active = made[setup["active"]]
    bpy.context.scene.cursor.location = setup["cursor"]
    bpy.context.view_layer.update()
    return made


def matrices(objects):
    out = []
    for obj in objects:
        m = obj.matrix_world
        out += [m[r][c] for c in range(4) for r in range(3)]
    return out


def commit(name):
    """Runs a case's Python on its scene; returns the objects, their
    locations before, and the largest gap between Blender and the preview."""
    made = build(json.loads(blocks[name + "_SETUP"]))
    before = [o.matrix_world.translation.copy() for o in made]
    run(name)
    bpy.context.view_layer.update()
    want = floats(name + "_EXPECT")
    got = matrices(made)
    gap = max(abs(a - b) for a, b in zip(want, got)) if len(want) == len(got) else float("inf")
    return made, before, gap


def on_step(value, step, tolerance=2e-4):
    return abs(value / step - round(value / step)) * step < tolerance


STEP = float(blocks["SNAP_STEP"])
for name in ("SNAP_INC_AXIS", "SNAP_GRID_AXIS", "SNAP_BOTH_AXIS", "SNAP_GRID_PLANE",
             "SNAP_GRID_FREE", "SNAP_GRID_ACTIVE", "SNAP_INC_ROTATE", "SNAP_INC_SCALE",
             "SCALE_ABOUT_CURSOR"):
    made, before, gap = commit(name)
    check("%s: Blender lands where the preview did (%.1e)" % (name, gap), gap < 2e-3, blocks[name])

    moved = [o.matrix_world.translation - b for o, b in zip(made, before)]
    median = sum((o.matrix_world.translation for o in made), bpy.types.Object.bl_rna and
                 __import__("mathutils").Vector()) / len(made)
    if name == "SNAP_INC_AXIS":
        check("  Increment moves the selection by one vector, in whole steps along X",
              (moved[0] - moved[1]).length < 1e-4 and on_step(moved[0].x, STEP)
              and abs(moved[0].x) > 1e-3 and abs(moved[0].y) < 1e-5 and abs(moved[0].z) < 1e-5,
              [tuple(v) for v in moved])
        check("  from where it started, so the cubes stay off the grid",
              not on_step(made[0].location.x, STEP), tuple(made[0].location))
    elif name in ("SNAP_GRID_AXIS", "SNAP_BOTH_AXIS"):
        check("  Grid puts the median's X on the grid, the selection moving as one%s"
              % (" — Grid wins over Increment" if name == "SNAP_BOTH_AXIS" else ""),
              on_step(median.x, STEP) and (moved[0] - moved[1]).length < 1e-4
              and abs(moved[0].y) < 1e-5 and abs(moved[0].z) < 1e-5,
              (tuple(median), [tuple(v) for v in moved]))
    elif name == "SNAP_GRID_PLANE":
        check("  on the XY plane handle, the median's X and Y",
              on_step(median.x, STEP) and on_step(median.y, STEP) and abs(moved[0].z) < 1e-5,
              tuple(median))
    elif name == "SNAP_GRID_FREE":
        check("  with no constraint, onto the ground grid under the pointer",
              on_step(median.x, STEP) and on_step(median.y, STEP) and abs(median.z) < 1e-4,
              tuple(median))
    elif name == "SNAP_GRID_ACTIVE":
        check("  Snap With Active puts the active object's Y on the grid instead",
              on_step(made[1].location.y, STEP) and not on_step(median.y, STEP), tuple(made[1].location))
    elif name == "SNAP_INC_ROTATE":
        angle = made[0].rotation_euler.z
        check("  a rotation turns in 5 degree steps",
              abs(angle) > 1e-3 and abs(math.degrees(angle) / 5 - round(math.degrees(angle) / 5)) < 1e-2,
              math.degrees(angle))
    elif name == "SNAP_INC_SCALE":
        check("  a scale in steps of 0.1", on_step(made[0].scale.x, 0.1, 1e-4)
              and abs(made[0].scale.x - 1) > 1e-3, tuple(made[0].scale))
    elif name == "SCALE_ABOUT_CURSOR":
        check("  one object scaled about the cursor moves away from it, preview included",
              moved[0].length > 1e-2, tuple(moved[0]))

for name in blocks["FAMILY_CASES"].split():
    made, before, gap = commit(name)
    moved = [(o.matrix_world.translation - b).length for o, b in zip(made, before)]
    check("%s: every object of a parent chain where the preview put it (%.1e)" % (name, gap),
          gap < 2e-3, blocks[name])
    if name == "FAMILY_PROPORTIONAL_translate":
        check("  A's parent stayed, its child went further than A, and the far one stayed",
              moved[1] < 1e-6 and moved[2] > moved[0] + 1e-3 and moved[6] < 1e-6,
              [round(m, 4) for m in moved])

def world_bounds(objects):
    out = []
    for obj in objects:
        corners = [obj.matrix_world @ v.co for v in obj.data.vertices]
        out += [min(c[i] for c in corners) for i in range(3)] + [max(c[i] for c in corners) for i in range(3)]
    return out


for name in blocks["AFFECT_CASES"].split():
    made = build(json.loads(blocks[name + "_SETUP"]))
    flags = json.loads(blocks[name + "_TOOLS"])
    ts = bpy.context.scene.tool_settings
    ts.use_transform_skip_children = flags["skip_children"]
    ts.use_transform_data_origin = flags["data_origin"]
    bpy.context.view_layer.update()
    before_geometry = world_bounds(made)
    before_matrix = [o.matrix_world.copy() for o in made]
    run(name)
    bpy.context.view_layer.update()
    want, got = floats(name + "_EXPECT"), world_bounds(made)
    gap = max(abs(a - b) for a, b in zip(want, got)) if len(want) == len(got) else float("inf")
    check("%s: every object's geometry where the preview drew it (%.1e)" % (name, gap), gap < 2e-3,
          blocks[name])
    selected = json.loads(blocks[name + "_SETUP"])["selected"]
    # C (2) is A's child and G (3) is C's.
    if flags["skip_children"] and selected == [0]:
        still = max(abs(a - b) for a, b in zip(before_geometry[12:24], got[12:24]))
        check("  Affect Only Parents: A's unselected child and grandchild stayed where they were",
              still < 1e-5, still)
    if flags["data_origin"]:
        a_geometry = max(abs(a - b) for a, b in zip(before_geometry[:6], got[:6]))
        a_origin = max(abs(x - y) for row_a, row_b in zip(made[0].matrix_world, before_matrix[0])
                       for x, y in zip(row_a, row_b))
        check("  Affect Only Origins: A's geometry stayed and its origin changed",
              a_geometry < 1e-5 and a_origin > 1e-3, (a_geometry, a_origin))
    ts.use_transform_skip_children = False
    ts.use_transform_data_origin = False

for name in blocks["PROP_OBJECT_CASES"].split():
    made, before, gap = commit(name)
    check("%s: every object, neighbours included, where the preview put it (%.1e)" % (name, gap),
          gap < 2e-3, blocks[name])
made, before, _ = commit("PROP_OBJECT_LINEAR_translate")
check("and in reach means in reach: the far cube stayed, the near ones followed",
      (made[4].matrix_world.translation - before[4]).length < 1e-6
      and all((made[i].matrix_world.translation - before[i]).length > 1e-3 for i in (1, 2, 3)),
      [tuple(o.matrix_world.translation - b) for o, b in zip(made, before)])

# Individual Origins: the helper against the preview, and — for a scale, where
# the view cannot flip a sign — against desktop Blender given a 3D View to
# read the pivot from.
for name in ("PROP_INDIVIDUAL_rotate", "PROP_INDIVIDUAL_scale"):
    made, before, gap = commit(name)
    check("%s: the helper lands where the preview did (%.1e)" % (name, gap), gap < 2e-3, blocks[name])
    check("  with the selection still selected, and only it",
          sorted(o.name for o in bpy.context.selected_objects) == ["A", "B"],
          [o.name for o in bpy.context.selected_objects])

calls = []


class Recorder(types.ModuleType):
    def transform_individual(self, kind, **arguments):
        calls.append((kind, arguments))


recorder = Recorder("_blenderkit_tools")
sys.modules["_blenderkit_tools"] = recorder
run("PROP_INDIVIDUAL_scale")
sys.modules["_blenderkit_tools"] = tools
kind, arguments = calls[-1]
setup = json.loads(blocks["PROP_INDIVIDUAL_scale_SETUP"])
bpy.ops.wm.read_homefile()
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)
desktop = []
for i, place in enumerate(setup["places"]):
    bpy.ops.mesh.primitive_cube_add(size=2, location=place)
    bpy.context.object.name = chr(65 + i)
    desktop.append(bpy.context.object)
bpy.ops.object.select_all(action='DESELECT')
for i in setup["selected"]:
    desktop[i].select_set(True)
bpy.context.view_layer.objects.active = desktop[setup["active"]]
bpy.context.scene.tool_settings.transform_pivot_point = 'INDIVIDUAL_ORIGINS'
screen = bpy.data.screens['Layout']
area = next(a for a in screen.areas if a.type == 'VIEW_3D')
region = next(r for r in area.regions if r.type == 'WINDOW')
with bpy.context.temp_override(area=area, region=region, screen=screen):
    bpy.ops.transform.resize(**arguments)
bpy.context.view_layer.update()
want = floats("PROP_INDIVIDUAL_scale_EXPECT")
got = matrices(desktop)
gap = max(abs(a - b) for a, b in zip(want, got))
check("  and desktop Blender, reading Individual Origins from a 3D View, agrees (%.1e)" % gap,
      gap < 2e-3, "want %s got %s" % ([round(v, 3) for v in want], [round(v, 3) for v in got]))

# ---------------------------------------------------------------------------
print("\nwhat a drag previews is what Blender commits: edit mode, on Blender's meshes")
# ---------------------------------------------------------------------------
worst = {}

def add_mirror(obj, mirror):
    """The Mirror modifier the Swift side put in the object's stack."""
    m = obj.modifiers.new("Mirror", 'MIRROR')
    m.use_axis = mirror["axes"]
    m.use_clip = mirror["clip"]
    m.merge_threshold = mirror["merge_threshold"]


for name in blocks["EDIT_CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    obj = fixtures.build(setup["fixture"])
    if "mirror" in setup:
        add_mirror(obj, setup["mirror"])
    start = [v.co.copy() for v in obj.data.vertices]
    fixtures.select_vertices(obj, setup["selected"])
    try:
        run(name)
    except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
        check(name + ": Blender accepts what it sends", False, exc)
        bpy.ops.object.mode_set(mode='OBJECT')
        continue
    bpy.ops.object.mode_set(mode='OBJECT')
    got = [c for v in obj.data.vertices for c in v.co]
    want = floats(name + "_EXPECT")
    gaps = [max(abs(got[3 * i + k] - want[3 * i + k]) for k in range(3))
            for i in range(len(start))]
    # Counted above float noise: a vertex the pivot sits on moves by nothing,
    # and 1e-5 of nothing is either side of the line by chance. The same goes
    # for a vertex exactly on the rim: on the subdivided cube two sit 2e-8
    # inside size 1.6, each side's float rounding lets a different one in, and
    # Root's infinite slope there makes that 1.7e-4 of movement (measured).
    moved_blender = sum(1 for i, v in enumerate(obj.data.vertices) if (v.co - start[i]).length > 1e-4)
    moved_preview = sum(1 for i in range(len(start))
                        if max(abs(want[3 * i + k] - start[i][k]) for k in range(3)) > 1e-4)
    gap = max(gaps)
    worst[name] = gap
    check("%s: %d vertices moved in Blender, %d in the preview, largest gap %.1e"
          % (name, moved_blender, moved_preview, gap),
          gap < 1e-3 and moved_blender == moved_preview and moved_blender >= 1,
          blocks[name])

# The clipping cases pass above only if the preview clipped. Each would have
# failed without it: the same drag previewed with no Mirror lands elsewhere,
# and at least one vertex Blender left on the plane is off it there.
for name in blocks["CLIP_CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    obj = fixtures.build("grid")
    add_mirror(obj, setup["mirror"])
    fixtures.select_vertices(obj, setup["selected"])
    run(name)
    bpy.ops.object.mode_set(mode='OBJECT')
    got = [c for v in obj.data.vertices for c in v.co]
    plain = floats(name + "_UNCLIPPED")
    gap = max(abs(a - b) for a, b in zip(got, plain))
    pinned = sum(1 for i, v in enumerate(obj.data.vertices)
                 if abs(v.co.x) < 1e-6 and abs(plain[3 * i]) > 1e-4)
    check("%s: an unclipped preview would miss by %.3f; %d vertices Blender held on the plane"
          % (name, gap, pinned), gap > 1e-3 and pinned >= 1, (gap, pinned))

grid = json.loads(blocks["EDIT_SNAP_INC_SETUP"])
obj = fixtures.build("grid")
start = [obj.matrix_world @ v.co for v in obj.data.vertices]
fixtures.select_vertices(obj, grid["selected"])
run("EDIT_SNAP_INC")
bpy.ops.object.mode_set(mode='OBJECT')
i = grid["selected"][0]
step = (obj.matrix_world @ obj.data.vertices[i].co) - start[i]
check("while editing, Increment moves the vertices in whole steps along X",
      on_step(step.x, STEP) and abs(step.x) > 1e-3 and abs(step.y) < 1e-4 and abs(step.z) < 1e-4,
      tuple(step))

# ---------------------------------------------------------------------------
print("\nsnapping to geometry: the search found Blender's geometry, and the move "
      "put Blender's own Snap With point on it")
# ---------------------------------------------------------------------------
from mathutils import Vector, geometry as mgeometry            # noqa: E402
from mathutils.bvhtree import BVHTree                           # noqa: E402


def world_geometry(obj, positions=None, skip=()):
    """Blender's vertices, edges, face centres and surface, in world space —
    all of it, or what a drag of the vertices in `skip` may land on."""
    m = obj.matrix_world
    verts = positions or [m @ v.co for v in obj.data.vertices]
    skip = set(skip)
    edges = [(verts[a], verts[b]) for a, b in (tuple(e.vertices) for e in obj.data.edges)
             if a not in skip and b not in skip]
    polys = [list(p.vertices) for p in obj.data.polygons if not skip.intersection(p.vertices)]
    centres = [sum((verts[i] for i in p), Vector()) / len(p) for p in polys]
    tree = BVHTree.FromPolygons(verts, polys)
    kept = [v for i, v in enumerate(verts) if i not in skip]
    return kept, edges, centres, tree


def segment_distance(p, a, b):
    closest, factor = mgeometry.intersect_point_line(p, a, b)
    closest = a if factor <= 0 else b if factor >= 1 else closest
    return (p - closest).length


def distance_to(kind, point, found):
    """How far `point` is from the nearest element of that kind Blender has."""
    verts, edges, centres, tree = found
    if kind in ('vertex', 'point'):
        return min((v - point).length for v in verts)
    if kind == 'edge':
        return min(segment_distance(point, a, b) for a, b in edges)
    if kind == 'edge_midpoint':
        return min(((a + b) / 2 - point).length for a, b in edges)
    if kind == 'face_midpoint':
        return min((c - point).length for c in centres)
    if kind == 'face':
        return tree.find_nearest(point)[3]
    raise ValueError(kind)


def expected_source(record, before, point, found):
    """Where Blender's Snap With point should be after the move, worked out
    here from Blender's geometry: `transform_constraint_get_nearest`."""
    kind, (mode, axis) = record["kind"], record["constraint"]
    if mode == "free":
        return point
    direction = Vector([1.0 if k == axis else 0.0 for k in range(3)])
    if mode == "plane":
        if kind == 'edge':
            _, edges, _, _ = found
            a, b = min(edges, key=lambda e: segment_distance(point, *e))
            return mgeometry.intersect_line_plane(a, b, before, direction)
        move = point - before
        return before + move - direction * move.dot(direction)
    if kind == 'edge':
        _, edges, _, _ = found
        a, b = min(edges, key=lambda e: segment_distance(point, *e))
        on_axis, _ = mgeometry.intersect_line_line(before, before + direction, a, b)
        return on_axis
    if kind == 'face':
        _, _, _, tree = found
        _, normal, _, _ = tree.find_nearest(point)
        return mgeometry.intersect_line_plane(before, before + direction, point, normal)
    return before + direction * (point - before).dot(direction)


def build_snap(setup):
    """The fixture the drag lands on, then cubes A, B… with the Swift side's
    selection and active object."""
    empty()
    target = fixtures.add(setup["target"])
    made = []
    for i, place in enumerate(setup["places"]):
        bpy.ops.mesh.primitive_cube_add(size=2, location=place)
        obj = bpy.context.object
        obj.name = chr(65 + i)
        made.append(obj)
    if "parent" in setup:
        # Parented where it stands, as Ctrl+P leaves a child: the inverse
        # keeps its world matrix what the Swift side mirrored.
        bpy.context.view_layer.update()
        child, parent = (made[i] for i in setup["parent"])
        child.parent = parent
        child.matrix_parent_inverse = parent.matrix_world.inverted()
    bpy.ops.object.select_all(action='DESELECT')
    for i in setup["selected"]:
        made[i].select_set(True)
    bpy.context.view_layer.objects.active = made[setup["active"]]
    bpy.context.scene.cursor.location = setup["cursor"]
    bpy.context.view_layer.update()
    return made, target


def snap_source(record, objects):
    """Blender's Snap With point, read off Blender's objects: a function, so
    Closest's corner, chosen before the move, is the one read after it."""
    if record["with"] == "CLOSEST":
        point = Vector(record["location"])
        pairs = [(o, i) for o in objects for i in range(8)]
        o, i = min(pairs, key=lambda p: (p[0].matrix_world @ Vector(p[0].bound_box[p[1]]) - point).length)
        return lambda: o.matrix_world @ Vector(o.bound_box[i])
    if record["with"] == "ACTIVE":
        active = bpy.context.view_layer.objects.active
        return lambda: active.matrix_world.translation.copy()
    return lambda: sum((o.matrix_world.translation for o in objects), Vector()) / len(objects)


for name in blocks["GEO_CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    record = json.loads(blocks[name + "_SNAP"])
    made, target = build_snap(setup)
    selected = [made[i] for i in setup["selected"]]
    point = Vector(record["location"])
    found = world_geometry(target)
    gap_on = distance_to(record["kind"], point, found)
    check("%s: the %s found is one Blender has (%.1e away)" % (name, record["kind"], gap_on),
          gap_on < 2e-5, record)
    source = snap_source(record, selected)
    before = source()
    run(name)
    bpy.context.view_layer.update()
    want = floats(name + "_EXPECT")
    got = matrices(made)
    gap = max(abs(a - b) for a, b in zip(want, got))
    check("  Blender lands where the preview did (%.1e)" % gap, gap < 2e-5, blocks[name])
    after = source()
    wanted = expected_source(record, before, point, found)
    miss = (after - wanted).length
    # Float, relative to the move: an axis that meets a tilted face's plane far
    # off moved 13.76 in one case, and 1.6e-5 of that is its seventh digit.
    check("  and its %s point is where the %s constraint puts it (%.1e)"
          % (record["with"].lower(), record["constraint"][0], miss),
          miss < 2e-5 * max(1.0, (after - before).length), (tuple(after), tuple(wanted)))
    if name == "GEO_FACE_AXIS_ABOVE":
        down = distance_to('face', after, found)
        check("  dropped along Z, it lands on Blender's surface (%.1e)" % down, down < 2e-5)
    if record["constraint"][0] == "axis":
        k = record["constraint"][1]
        move = after - before
        check("  having moved along that axis only",
              all(abs(move[j]) < 1e-6 for j in range(3) if j != k) and abs(move[k]) > 1e-4, tuple(move))
    if "parent" in setup:
        child, parent = (made[i] for i in setup["parent"])
        carried = child.matrix_world.translation - Vector(setup["places"][setup["parent"][0]])
        check("  and the unselected child moved with its parent, by the parent's move (%.1e)"
              % (carried - (after - before)).length,
              (carried - (after - before)).length < 2e-5 and carried.length > 1e-3
              and not child.select_get(), (tuple(carried), tuple(after - before)))

for name in blocks["GEO_EDIT_CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    record = json.loads(blocks[name + "_SNAP"])
    obj = fixtures.build(setup["fixture"])
    m = obj.matrix_world.copy()
    start = [m @ v.co for v in obj.data.vertices]
    point = Vector(record["location"])
    found = world_geometry(obj, positions=start, skip=setup["selected"])
    gap_on = distance_to(record["kind"], point, found)
    check("%s: the %s found is one Blender has, and touches no selected vertex (%.1e away)"
          % (name, record["kind"], gap_on), gap_on < 2e-5, record)
    fixtures.select_vertices(obj, setup["selected"])
    run(name)
    bpy.ops.object.mode_set(mode='OBJECT')
    got = [c for v in obj.data.vertices for c in v.co]
    want = floats(name + "_EXPECT")
    gap = max(abs(a - b) for a, b in zip(got, want))
    check("  Blender moved every vertex where the preview did (%.1e)" % gap, gap < 2e-5, blocks[name])
    moved = record["moved"]
    after = m @ obj.data.vertices[moved].co
    wanted = expected_source(record, start[moved], point, found)
    miss = (after - wanted).length
    check("  and the selected vertex is where the %s constraint puts it (%.1e)"
          % (record["constraint"][0], miss), miss < 2e-5, (tuple(after), tuple(wanted)))

# ---------------------------------------------------------------------------
print("\nAuto Merge: the preview welds what Blender's commit welds")
# ---------------------------------------------------------------------------
for name in blocks["AUTOMERGE_CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    obj = fixtures.build(setup["fixture"])
    before = len(obj.data.vertices)
    # The scene's setting, written as the panel writes it.
    run("SET_AUTOMERGE" if setup["automerge"] else "SET_AUTOMERGE_OFF")
    fixtures.select_vertices(obj, setup["selected"])
    run(name)
    bpy.ops.object.mode_set(mode='OBJECT')
    want = floats(name + "_EXPECT")
    got = [c for v in obj.data.vertices for c in v.co]
    gap = max(abs(a - b) for a, b in zip(got, want)) if len(got) == len(want) else float("inf")
    welded = before - len(obj.data.vertices)
    check("%s: Blender kept %d of %d vertices, the preview %d, largest gap %.1e"
          % (name, len(obj.data.vertices), before, len(want) // 3, gap),
          len(want) == len(got) and gap < 2e-5
          and welded == (1 if name == "AUTOMERGE_SNAP_ON" else 0), blocks[name])

# ---------------------------------------------------------------------------
print("\nwhat moves with what: the mirror's record, closed over in Swift, "
      "against Blender's depsgraph")
# ---------------------------------------------------------------------------
objects = fixtures.relations()
moved = json.loads(blocks["RELATIONS_MOVED"])
parents = json.loads(blocks["RELATIONS_PARENTS"])
differ = []
for obj in objects:
    want = sorted(fixtures.moved_with(obj))
    if moved.get(obj.name) != want:
        differ.append((obj.name, want, moved.get(obj.name)))
check("for all %d objects, what moves with each is what Blender's depsgraph updates" % len(objects),
      not differ and len(moved) == len(objects), differ)
for name, holds in (("P", "a parent carries its child and grandchild, and what reads it"),
                    ("X", "a Boolean's cutter carries the base, a follower and a vertex child"),
                    ("O", "an Array's, a Hook's and a driver's object"),
                    ("U", "a mirror object, and an Object Info node's; not a material's")):
    check("  %s: %s — %s" % (name, holds, ", ".join(n for n in moved[name] if n != name)),
          moved[name] == sorted(fixtures.moved_with(bpy.data.objects[name])))
check("the parents come across as Blender's",
      all(parents[o.name] == (o.parent.name if o.parent else "") for o in objects)
      and parents["G"] == "C" and parents["VP"] == "X", parents)
sync = load("_blenderkit_sync", "Resources/python/site/_blenderkit_sync.py")
bridge.relations.clear()
sync._push_relations(bpy.data.objects["U"])
sync._push_relations(bpy.data.objects["G"])
sync._push_relations(bpy.data.objects["N"])
check("an object that depends on nothing is not described; one that does is, parent first",
      bridge.relations == [("G", "C", ["C"]), ("N", "", ["G", "U"])], bridge.relations)

# ---------------------------------------------------------------------------
print("\na curve with no surface is snapped by what snapCurve offers: its control points")
# ---------------------------------------------------------------------------
empty()
bpy.ops.curve.primitive_bezier_circle_add(location=(1, 2, 0))
circle = bpy.context.object
bpy.ops.curve.primitive_nurbs_path_add(location=(4, 0, 0))
path = bpy.context.object
bpy.ops.curve.primitive_bezier_curve_add(location=(7, 0, 0))
bevelled = bpy.context.object
bevelled.data.bevel_depth = 0.1
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
bridge.knots.clear()
for obj in (circle, path, bevelled):
    sync._push_knots(obj, obj.evaluated_get(depsgraph))


def flat(points):
    return [c for p in points for c in p]


check("a Bezier circle: its 4 knots, in its own space, not its 48-point wire",
      circle.name in bridge.knots
      and max(abs(a - b) for a, b in zip(bridge.knots[circle.name],
                                         flat(p.co for p in circle.data.splines[0].bezier_points))) < 1e-6
      and len(bridge.knots[circle.name]) == 12
      and len(circle.evaluated_get(depsgraph).to_mesh().vertices) == 48, bridge.knots.get(circle.name))
circle.evaluated_get(depsgraph).to_mesh_clear()
check("a NURBS path: its 5 points",
      len(bridge.knots.get(path.name, ())) == 15
      and max(abs(a - b) for a, b in zip(bridge.knots[path.name],
                                         flat(p.co[:3] for p in path.data.splines[0].points))) < 1e-6,
      bridge.knots.get(path.name))
bevelled.display_type = 'BOUNDS'
check("Display As Bounds travels as a flag, which the search reads to skip it",
      sync._kind(bevelled).split('|')[-1] == 'boundbox' and 'boundbox' not in sync._kind(path),
      (sync._kind(bevelled), sync._kind(path)))
check("a bevelled curve is a mesh, and snapped as one: nothing sent",
      bevelled.name not in bridge.knots
      and bevelled.evaluated_get(depsgraph).evaluated_geometry().mesh is not None)

# ---------------------------------------------------------------------------
print("\nthe helper's own edges")
# ---------------------------------------------------------------------------
empty()
try:
    tools.set_tools(pivto='CURSOR')
    check("a misspelt setting is refused", False, "it was accepted")
except TypeError as exc:
    check("a misspelt setting is refused", "pivto" in str(exc), exc)

try:
    tools.snap('NOWHERE')
    check("an unknown snap action is refused", False, "it was accepted")
except ValueError:
    check("an unknown snap action is refused", True)

empty()
bpy.ops.object.select_all(action='DESELECT')
try:
    tools.snap('CURSOR_TO_SELECTED')
    check("Cursor to Selected with nothing selected says so", False, "it was accepted")
except RuntimeError:
    check("Cursor to Selected with nothing selected says so", True)

# A failure part way through transform_individual must leave the selection as
# it found it.
made = cubes()
before = [o.name for o in bpy.context.selected_objects]
try:
    tools.transform_individual('ROTATE', value=0.5, orient_axis='NOPE')
except Exception:                                  # noqa: BLE001 - the point is what survives
    pass
check("a failed per-object transform restores the selection",
      sorted(o.name for o in bpy.context.selected_objects) == sorted(before),
      [o.name for o in bpy.context.selected_objects])

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
