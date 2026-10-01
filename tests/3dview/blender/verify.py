"""The 3D View's Python, run by a headless Blender the way an iPad runs it.

scripts/run-3dview-blender-check.sh starts Blender with `-b --factory-startup`:
no user settings, and no 3D View area — `bpy.context.area` is None, as it is
for the bpy module on a device. Every string checked here comes from the Swift
that sends it, printed by tests/3dview/blender/main.swift.
"""
import bpy, bmesh, sys, math, types, pathlib, importlib.util, json
from array import array
from mathutils import Matrix

ARGS = sys.argv[sys.argv.index("--") + 1:]
CALLS = ARGS[0]
# Where Blender's side of the Set Origin / Apply scenarios is written, for the
# Swift that greys those rows out to be run against (main.swift's replay).
RECORDS = ARGS[1] if len(ARGS) > 1 else None
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


def run_text(text, name="<ui>"):
    namespace = {"bpy": bpy}
    exec(compile(text, name, "exec"), namespace)
    return namespace


def run(name):
    return run_text(blocks[name], "<" + name + ">")


def cube(location=(0, 0, 0), rotation=(0, 0, 0), name="Cube", fresh=True):
    if fresh:
        bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=2, location=location)
    o = bpy.context.object
    o.name = name
    o.data.name = name
    o.rotation_euler = rotation
    bpy.context.view_layer.update()
    return o


def edit(o, select=True):
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT' if select else 'DESELECT')


def selected(o):
    o.update_from_editmode()
    me = o.data
    return ({v.index for v in me.vertices if v.select},
            {e.index for e in me.edges if e.select},
            {p.index for p in me.polygons if p.select})


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit` module and records what it is told."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.shown = "OBJECT"
        self.modes = []
        self.pushed = {}
        self.edit = None
        self.selection = set()
        self.active = None
        self.arrays = {}
        self.displays = {}
        self.local = {}
        self.frames = []
        # What the last pass left on screen, and whether one is under way:
        # `sync_local` is held to the device's rule for both.
        self.screen = set()
        self.in_pass = False

    def sync_begin(self):
        self.pushed = {}
        self.displays = {}
        self.in_pass = True

    def sync_push(self, name, kind, matrix, verts, normals, tris, selected, active, rgba):
        values = array('d')
        values.frombytes(matrix)
        self.pushed[name] = dict(kind=kind, verts=len(verts) // 12, tris=len(tris) // 12,
                                 matrix=list(values), selected=bool(selected), active=bool(active))

    def sync_display(self, name, kind, data, record):
        self.displays[name] = [kind, data, record]

    def sync_local(self, name, values):
        """As SceneMirror.carryLocal decides it: in a pass, the name must have
        been pushed; outside one — a frame change — a name not on screen is
        skipped. What it refuses, PythonBootstrap.c raises as ValueError."""
        channels = array('d')
        channels.frombytes(values)
        if len(channels) != 10:
            raise ValueError("sync_local wants ten doubles, got %d" % len(channels))
        if self.in_pass and name not in self.pushed:
            raise ValueError("this pass pushed no object named %s" % name)
        if not self.in_pass and name not in self.screen:
            return None
        self.local[name] = list(channels)

    def anim_frame(self, frame, subframe, names, matrices):
        self.frames.append(frame)
        return len([n for n in names.split(b'\0') if n])

    def anim_mesh(self, *args):
        return 0

    def sync_end(self):
        self.screen = set(self.pushed)
        self.in_pass = False

    def mode(self):
        return self.shown

    def set_mode(self, mode):
        if mode not in ("OBJECT", "EDIT", "SCULPT", "VERTEX_PAINT", "WEIGHT_PAINT", "TEXTURE_PAINT"):
            raise ValueError("unsupported mode: " + mode)
        self.modes.append(mode)
        self.shown = mode

    def sync_edit_selection(self, name, bits, vsel, tpoly, psel, ends, esel, vhide=b'', vco=b''):
        def typed(code, raw):
            values = array(code)
            values.frombytes(raw)
            return list(values)
        self.edit = dict(name=name, bits=bits, vsel=typed('b', vsel), tpoly=typed('I', tpoly),
                         psel=typed('b', psel), ends=typed('I', ends), esel=typed('b', esel))

    def select_all(self, on=True):
        if not on:
            self.selection = set()
            self.active = None

    def select(self, name, on=True):
        (self.selection.add if on else self.selection.discard)(name)

    def set_active(self, name):
        self.active = name or None

    def material_set(self, *args):
        pass

    def set_timeline(self, *args):
        pass

    def mesh_arrays(self, name):
        return self.arrays[name]


bridge = Bridge()
sys.modules["_blenderkit"] = bridge
spec = importlib.util.spec_from_file_location(
    "_blenderkit_sync", ROOT / "Resources/python/site/_blenderkit_sync.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
sys.modules["_blenderkit_sync"] = sync


print("headless, as on an iPad")
check("there is no 3D View area here, as there is none for bpy on a device",
      bpy.context.area is None, bpy.context.area)


print("\nBlender's mode reaches the interface")
o = cube()
bridge.shown, bridge.modes = "OBJECT", []
sync.sync()
check("object mode reports nothing new", bridge.modes == [], bridge.modes)
bpy.ops.object.mode_set(mode='EDIT')
sync.sync()
check("Blender in edit mode shows as editing — the Editing chip, Bevel, Done",
      bridge.shown == "EDIT", bridge.modes)
bpy.ops.object.mode_set(mode='OBJECT')
sync.sync()
check("and Blender back in object mode shows as object mode", bridge.shown == "OBJECT", bridge.modes)
bridge.shown = "TEXTURE_PAINT"
sync.sync()
check("the interface's own painting is not ended by Blender staying in object mode",
      bridge.shown == "TEXTURE_PAINT", bridge.modes)
bpy.ops.object.mode_set(mode='EDIT')
sync.sync()
check("but Blender entering edit mode is shown", bridge.shown == "EDIT", bridge.modes)
bpy.ops.object.mode_set(mode='OBJECT')
# Sculpt Mode is Blender's own now (_blenderkit_sculpt): an Undo that takes
# Blender back to object mode takes the interface with it.
bridge.shown = "SCULPT"
sync.sync()
check("Sculpt Mode follows Blender's: Blender in object mode shows as object mode",
      bridge.shown == "OBJECT", bridge.modes)
bpy.ops.object.mode_set(mode='SCULPT')
sync.sync()
check("and Blender in Sculpt Mode shows as Sculpt Mode", bridge.shown == "SCULPT", bridge.modes)
bpy.ops.object.mode_set(mode='OBJECT')
sync.sync()


print("\nTab, and leaving a brush")
o = cube()
run("TOGGLE")
check("Tab from object mode enters edit mode", o.mode == 'EDIT', o.mode)
run("TOGGLE")
check("and from edit mode leaves it, by Blender's own mode", o.mode == 'OBJECT', o.mode)
bpy.ops.object.mode_set(mode='SCULPT')
run("LEAVEBRUSH")
check("a sculpt mode Blender is really in is left for object mode", o.mode == 'OBJECT', o.mode)
bpy.ops.object.mode_set(mode='EDIT')
run("LEAVEBRUSH")
check("edit mode is not a brush mode, and is left alone", o.mode == 'EDIT', o.mode)
bpy.ops.object.mode_set(mode='OBJECT')


print("\na mode the active object does not have")
# Only a mesh has an edit, sculpt or paint mode. Asked for one with a light
# active, mode_set is handed an enum it does not have, and Blender answers
#   TypeError: Converting py args to operator properties:
#              enum "EDIT" not found in ('OBJECT')
# which the app showed as it came -- with "Sun" in the status bar and nothing
# said about it.
bpy.ops.object.light_add(type='SUN')
sun = bpy.context.object
sun.name = "Sun"
bpy.ops.object.camera_add()
camera = bpy.context.object
camera.name = "Camera"


def refusal(name):
    try:
        run(name)
    except RuntimeError as error:
        return str(error)
    except Exception as error:
        return type(error).__name__ + ": " + str(error)
    return ""


bpy.context.view_layer.objects.active = sun
said = refusal("MODE_EDIT")
# Edit Mode is a mesh's, a curve's and a lattice's (2026-10-01: curves and
# lattices are edited by their control points), so the sentence names all three.
check("Edit Mesh on a light is refused in a sentence",
      said == "Edit Mode works on meshes, curves and lattices here, and Sun is a light.", said)
check("and Blender is left in object mode", sun.mode == 'OBJECT', sun.mode)
check("Tab is refused the same way", refusal("TOGGLE") == said, refusal("TOGGLE"))
said = refusal("MODE_SCULPT")
check("Sculpt Mode names itself, not Edit Mode",
      said == "Sculpt Mode works on meshes, and Sun is a light. Select a mesh first.", said)

bpy.context.view_layer.objects.active = camera
said = refusal("MODE_EDIT")
check("a camera is named as a camera", "Camera is a camera" in said, said)

bpy.context.view_layer.objects.active = None
check("with nothing active it asks for an object",
      refusal("MODE_EDIT") == "Edit Mode needs an object. Select a mesh, a curve or a lattice first.",
      refusal("MODE_EDIT"))

bpy.context.view_layer.objects.active = o
check("a mesh is not refused", refusal("MODE_EDIT") == "" and o.mode == 'EDIT', o.mode)
check("and object mode is never refused",
      refusal("MODE_OBJECT") == "" and o.mode == 'OBJECT', o.mode)

# A mesh operator with a light active took the other road: its mode switch is
# wrapped in `except: pass` -- right for a mode Blender happens to be in
# already -- so it stayed in object mode and the operator then failed its own
# poll, saying "context is incorrect" and naming neither the light nor itself.
bpy.context.view_layer.objects.active = sun
said = refusal("PERFORM_BEVEL")
check("a mesh operator on a light names the operator and the light",
      said == "Bevel works on meshes, and Sun is a light. Select a mesh first.", said)
check("and Blender is left where it was", sun.mode == 'OBJECT', sun.mode)
check("an add is not held to a mesh: everything has object mode",
      refusal("PERFORM_ADD") == "", refusal("PERFORM_ADD"))
for extra in [x for x in bpy.data.objects if x.name.startswith("Cube.")]:
    bpy.data.objects.remove(extra)

bpy.data.objects.remove(sun)
bpy.data.objects.remove(camera)


print("\nBlender's edit selection reaches the interface")
o = cube()
edit(o, select=False)
bpy.context.scene.tool_settings.mesh_select_mode = (False, False, True)
bm = bmesh.from_edit_mesh(o.data)
bm.faces.ensure_lookup_table()
bm.faces[2].select_set(True)
bm.select_flush_mode()
bmesh.update_edit_mesh(o.data)
bridge.shown, bridge.edit = "EDIT", None
sync.sync()
report = bridge.edit or {}
check("the edited object's selection is reported", report.get("name") == "Cube", report)
check("with Blender's select mode", report.get("bits") == 4, report.get("bits"))
check("a flag per vertex, the face's four corners set",
      len(report.get("vsel", [])) == 8 and sum(report["vsel"]) == 4, report.get("vsel"))
check("the polygon behind each of the twelve triangles",
      len(report.get("tpoly", [])) == 12 and sorted(set(report["tpoly"])) == list(range(6)),
      report.get("tpoly"))
check("one polygon selected", report.get("psel", [0, 0, 0])[2] == 1 and sum(report["psel"]) == 1,
      report.get("psel"))
check("and its four edges", sum(report.get("esel", [])) == 4 and len(report.get("ends", [])) == 24,
      report.get("esel"))
me = o.data
me.calc_loop_triangles()
drawn_from = array('I', [0]) * (3 * len(me.loop_triangles))
me.loop_triangles.foreach_get('vertices', drawn_from)
evaluated = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
em = evaluated.to_mesh()
em.calc_loop_triangles()
drawn = array('I', [0]) * (3 * len(em.loop_triangles))
em.loop_triangles.foreach_get('vertices', drawn)
evaluated.to_mesh_clear()
check("the mesh's triangles are in the order the viewport draws them, so indices carry over",
      list(drawn_from) == list(drawn))
bpy.ops.object.mode_set(mode='OBJECT')
o.modifiers.new("Subdivision", 'SUBSURF')
edit(o)
sync.sync()
check("through a modifier that rebuilds the mesh, no selection is reported by index",
      bridge.edit is not None and bridge.edit["vsel"] == [], bridge.edit)
bpy.ops.object.mode_set(mode='OBJECT')


print("\nthe viewport's edit selection reaches Blender")
o = cube()
edit(o)
run("PUSH_VERT")
v, _, _ = selected(o)
check("two vertices, by index", v == {0, 1}, v)
check("in vertex select mode",
      tuple(bpy.context.scene.tool_settings.mesh_select_mode) == (True, False, False))
run("PUSH_ALLVERTS")
check("all of them, without a list", selected(o)[0] == set(range(8)))
run("PUSH_FACE")
v, e, f = selected(o)
check("a face, by polygon index", f == {2}, f)
check("its corners and edges come with it", len(v) == 4 and len(e) == 4, (v, e))
check("in face select mode",
      tuple(bpy.context.scene.tool_settings.mesh_select_mode) == (False, False, True))
run("PUSH_EDGE")
wanted = {x.index for x in o.data.edges if 0 in tuple(x.vertices)}
_, e, _ = selected(o)
check("edges by their ends, the pairs that are not edges selecting nothing",
      e == wanted and len(wanted) == 3, (e, wanted))
try:
    run("PUSH_STALE")
    stale = None
except RuntimeError as error:
    stale = str(error)
check("a selection read from some other mesh is refused, not guessed at",
      stale is not None and "changed" in stale, stale)
bpy.ops.object.mode_set(mode='OBJECT')
o = cube()
edit(o, select=False)
run("PUSH_POSITIONS")
v, _, _ = selected(o)
check("a mesh the mirror could not line up is selected by position",
      len(v) == 4 and {round(o.data.vertices[i].co.x, 3) for i in v} == {1.0}, v)
bpy.ops.object.mode_set(mode='OBJECT')


print("\nwhile editing, the selection commands act on elements")
o = cube()
edit(o)
run("PUSH_FACE")
run("EDIT_INVERT")
check("Invert inverts the faces, not the objects", selected(o)[2] == {0, 1, 3, 4, 5}, selected(o)[2])
run("PUSH_FACE")
run("EDIT_DELETE_FACE")
o.update_from_editmode()
check("Delete removes the selected face, not the object",
      len(o.data.polygons) == 5 and "Cube" in bpy.data.objects, len(o.data.polygons))
check("and Blender is still editing afterwards", o.mode == 'EDIT', o.mode)
run("EDIT_DESELECTALL")
check("Deselect All clears the mesh's selection", selected(o) == (set(), set(), set()), selected(o))
run("EDIT_SELECTALL")
check("Select All selects every face", selected(o)[2] == set(range(5)), selected(o)[2])
run("SELECTMODE_EDGE")
check("the select mode control reaches Blender",
      tuple(bpy.context.scene.tool_settings.mesh_select_mode) == (False, True, False))
run("SELECTMODE_OPERATOR")
check("and bpy.ops.mesh.select_mode is sent a type Blender accepts",
      tuple(bpy.context.scene.tool_settings.mesh_select_mode) == (False, False, True))
bpy.ops.object.mode_set(mode='OBJECT')


print("\na mesh operator is one block, from any mode")
o = cube()
edit(o)
ns = run("PERFORM_INSET_PUSHED")
o = bpy.data.objects["Cube"]
o.update_from_editmode()
check("the inset acts on the face handed over, not on Blender's own selection of everything",
      len(o.data.polygons) == 10, len(o.data.polygons))
check("it is adjustable", ns.get("_bk_adjustable") is True, ns.get("_bk_adjustable"))
backup = bpy.data.meshes.get("_bk_redo")
check("with a backup that carries the selection it acted on",
      backup is not None and [p.index for p in backup.polygons if p.select] == [2],
      backup and [p.index for p in backup.polygons if p.select])
check("and Blender still editing", o.mode == 'EDIT', o.mode)
run_text(blocks["RERUN_INSET"].replace("@SUBJECT@", o.name), "<RERUN_INSET>")
o = bpy.data.objects["Cube"]
o.update_from_editmode()
check("adjusting it re-runs on that same face", len(o.data.polygons) == 10, len(o.data.polygons))
bpy.ops.object.mode_set(mode='OBJECT')

for start in ("OBJECT", "EDIT", "SCULPT"):
    o = cube()
    edit(o)
    bpy.ops.object.mode_set(mode='OBJECT')
    leftover = bpy.data.meshes.new("_bk_redo")
    leftover.use_fake_user = True
    bpy.ops.object.mode_set(mode=start)
    try:
        ns, error = run("PERFORM_BEVEL"), None
    except Exception as exc:
        ns, error = {}, str(exc)
    o = bpy.data.objects["Cube"]
    after = o.mode
    bpy.ops.object.mode_set(mode='OBJECT')
    redo = [m for m in bpy.data.meshes if m.name.startswith("_bk_redo")]
    check(f"from {start}: the bevel runs", error is None and len(o.data.vertices) > 8,
          error or len(o.data.vertices))
    check(f"from {start}: the old backup goes, in the same block, and a new one is taken",
          ns.get("_bk_adjustable") is True and len(redo) == 1 and len(redo[0].vertices) == 8,
          [(m.name, len(m.vertices)) for m in redo])
    check(f"from {start}: Blender is left in {start}", after == start, after)

for start in ("OBJECT", "SCULPT"):
    o = cube()
    bpy.ops.object.mode_set(mode=start)
    try:
        ns, error = run("PERFORM_ADD"), None
    except Exception as exc:
        ns, error = {}, str(exc)
    check(f"from {start}: an add runs and is adjustable",
          error is None and len(bpy.data.objects) == 2 and ns.get("_bk_adjustable") is True,
          error or [x.name for x in bpy.data.objects])


print("\na tap sends its selection once, and reads back only the selection")
other = cube(name="Other")
target = cube(location=(0, 4, 0), name="Target", fresh=False)
bpy.ops.object.select_all(action='DESELECT')
other.select_set(True)
bpy.context.view_layer.objects.active = other
bridge.selection, bridge.active, bridge.pushed, bridge.shown = {"Other"}, "Other", {"sentinel": {}}, "OBJECT"
run("TAP_SELECT")
check("Blender selects what was tapped", target.select_get() and not other.select_get())
check("and makes it active", bpy.context.view_layer.objects.active == target)
check("the interface is told the selection",
      bridge.selection == {"Target"} and bridge.active == "Target", (bridge.selection, bridge.active))
check("without any mesh being read back", bridge.pushed == {"sentinel": {}}, bridge.pushed)


print("\na sculpt stroke is kept")
o = cube()
base = array('f', [0.0]) * 24
o.data.vertices.foreach_get('co', base)
drawn = array('f', base)
drawn[2] += 0.25
bridge.arrays = {"Cube": (drawn.tobytes(), b'', b'')}
run("SCULPT_WRITE")
check("the stroke is written into Blender's mesh",
      abs(o.data.vertices[0].co.z - (base[2] + 0.25)) < 1e-5, o.data.vertices[0].co.z)


def evaluated_positions(obj):
    evaluated_object = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated_object.to_mesh()
    try:
        values = array('f', [0.0]) * (3 * len(mesh.vertices))
        mesh.vertices.foreach_get('co', values)
        return values
    finally:
        evaluated_object.to_mesh_clear()


o = cube()
o.data.vertices.foreach_get('co', base)
bend = o.modifiers.new("Bend", 'SIMPLE_DEFORM')
bend.deform_method = 'BEND'
bend.angle = 0.3
before = evaluated_positions(o)
drawn = array('f', before)
drawn[0] += 0.2
bridge.arrays = {"Cube": (drawn.tobytes(), b'', b'')}
run("SCULPT_WRITE")
after = evaluated_positions(o)
check("through a deforming modifier, the stroke's movement is what is kept",
      abs(after[0] - drawn[0]) < 0.05 and abs(after[0] - before[0]) > 0.1,
      (before[0], drawn[0], after[0]))
check("and the rest of the base mesh is untouched",
      all(abs(o.data.vertices[i].co[j] - base[3 * i + j]) < 1e-4 for i in range(1, 8) for j in range(3)))

o = cube()
o.modifiers.new("Subdivision", 'SUBSURF')
shown = len(evaluated_positions(o)) // 3
bridge.arrays = {"Cube": ((array('f', [0.0]) * (3 * shown)).tobytes(), b'', b'')}
try:
    run("SCULPT_WRITE")
    refused = None
except RuntimeError as error:
    refused = str(error)
check("through a modifier that changes the vertex count, the stroke is refused, with the reason",
      refused is not None and "vertex count" in refused, refused)


print("\nthe Outliner's render column comes back from Blender")
o = cube()
bridge.shown = "OBJECT"
o.hide_render = True
sync.sync()
check("hide_render travels with the object", bridge.pushed.get("Cube", {}).get("kind") == "MESH|norender",
      bridge.pushed.get("Cube"))
o.hide_viewport = True
sync.sync()
# `hide_viewport` is Disable in Viewports: not drawn, and said to be disabled
# so the Outliner can tell it from an eye H closed.
check("alongside hidden and disabled",
      bridge.pushed.get("Cube", {}).get("kind") == "MESH|hidden|disabled|norender",
      bridge.pushed.get("Cube"))


print("\nSet Origin and Apply Transform")


def stray_cube(location=(1, 0, 0)):
    """A cube with one loose vertex 30 units out, so MEDIAN and BOUNDS differ."""
    o = cube(location=location)
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bm.verts.new((30.0, 0.0, 0.0))
    bm.to_mesh(o.data)
    bm.free()
    o.data.update()
    bpy.context.view_layer.update()
    return o


# The mode guard has to survive: if the guard were concatenated in front of the
# operator, BpyModeGuard.requiredMode would see a non-bpy.ops first line and
# return the operator unbracketed — and both of these refuse edit mode.
for name in ("ORIGIN_CURSOR", "APPLY_SCALE"):
    check(f"{name} still arrives bracketed by the mode guard",
          "mode_set(mode='OBJECT')" in blocks[name], blocks[name].split("\n")[:5])

o = stray_cube()
run("ORIGIN_GEOMETRY_MEDIAN")
median = round(o.location.x, 3)
o = stray_cube()
run("ORIGIN_GEOMETRY_BOUNDS")
bounds = round(o.location.x, 3)
check("Origin to Geometry moves the origin, not the shape", median > 1.0, median)
check("and center='BOUNDS' is a different origin from the median",
      abs(bounds - median) > 1.0, (median, bounds))

o = stray_cube()
before = [tuple(v.co) for v in o.data.vertices]
run("GEOMETRY_TO_ORIGIN")
check("Geometry to Origin leaves location alone",
      tuple(round(c, 3) for c in o.location) == (1.0, 0.0, 0.0), tuple(o.location))
check("and moves the vertices instead",
      [tuple(v.co) for v in o.data.vertices] != before)

o = stray_cube()
bpy.context.scene.cursor.location = (0, 0, 5)
run("ORIGIN_CURSOR")
check("Origin to 3D Cursor puts the origin on Blender's cursor",
      tuple(round(c, 3) for c in o.location) == (0.0, 0.0, 5.0), tuple(o.location))
bpy.context.scene.cursor.location = (0, 0, 0)

for name in ("ORIGIN_CENTER_OF_MASS", "ORIGIN_CENTER_OF_VOLUME"):
    o = stray_cube()
    try:
        run(name)
        error = None
    except Exception as exc:
        error = str(exc)
    check(f"{name} is a call Blender accepts", error is None, error)

# Apply Scale from object mode, the only mode the menus offer it in: the
# channel asked for and no other.
o = cube(location=(1, 2, 3))
o.rotation_euler = (0.3, 0, 0)
o.scale = (1, 2, 3)
bpy.context.view_layer.update()
run("APPLY_SCALE")
check("Apply Scale bakes the scale", tuple(round(c, 3) for c in o.scale) == (1.0, 1.0, 1.0),
      tuple(o.scale))
check("and leaves location and rotation where they were",
      tuple(round(c, 3) for c in o.location) == (1.0, 2.0, 3.0)
      and tuple(round(c, 3) for c in o.rotation_euler) == (0.3, 0.0, 0.0),
      (tuple(o.location), tuple(o.rotation_euler)))

# The menus are disabled while editing, so this is not a menu path: it is the
# OBJECT bracket that `setup:` exists to keep, working. Were the guard joined
# in front of the operator, this would fail its poll.
o = cube(location=(1, 2, 3))
o.scale = (1, 2, 3)
bpy.context.view_layer.update()
edit(o)
run("APPLY_SCALE")
check("the mode guard still brackets it: from edit mode it bakes",
      tuple(round(c, 3) for c in o.scale) == (1.0, 1.0, 1.0), tuple(o.scale))
check("and hands edit mode back", o.mode == "EDIT", o.mode)
bpy.ops.object.mode_set(mode='OBJECT')

o = cube(location=(1, 2, 3))
o.rotation_euler = (0.3, 0, 0)
o.scale = (1, 2, 3)
bpy.context.view_layer.update()
run("APPLY_ALL")
check("Apply All Transforms bakes all three",
      tuple(round(c, 3) for c in o.location) == (0.0, 0.0, 0.0)
      and tuple(round(c, 3) for c in o.rotation_euler) == (0.0, 0.0, 0.0)
      and tuple(round(c, 3) for c in o.scale) == (1.0, 1.0, 1.0),
      (tuple(o.location), tuple(o.rotation_euler), tuple(o.scale)))

# The trap the Apply Scale row exists for: a modifier measured in metres reads
# the object's local space, so an unapplied non-uniform scale stretches it.
def bevel_levels(o):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = o.evaluated_get(dg)
    me = ev.to_mesh()
    levels = sorted({round((o.matrix_world @ v.co).z, 3) for v in me.vertices})
    ev.to_mesh_clear()
    return levels


o = cube()
o.scale = (1, 1, 4)
modifier = o.modifiers.new("Bevel", 'BEVEL')
modifier.width = 0.1
modifier.segments = 1
bpy.context.view_layer.update()
crooked = bevel_levels(o)
run("APPLY_SCALE")
bpy.context.view_layer.update()
even = bevel_levels(o)
check("an unapplied non-uniform scale stretches a Bevel along the scaled axis",
      abs(crooked[-1] - crooked[-2] - 0.4) < 1e-3, crooked)
check("and Apply Scale makes the bevel the width the modifier asks for",
      abs(even[-1] - even[-2] - 0.1) < 1e-3, even)

# Neither operator fails on a type it cannot handle — origin_set returns
# FINISHED and does nothing, transform_apply returns CANCELLED — so the guard
# in setup: is what turns a silent no-op into a sentence the banner can show.
for name, what in (("ORIGIN_CURSOR", "Set Origin"), ("APPLY_SCALE", "Apply Transform")):
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.object.camera_add(location=(1, 2, 3))
    bpy.context.view_layer.update()
    try:
        run(name)
        raised = None
    except RuntimeError as exc:
        raised = str(exc)
    check(f"{what} refuses a camera-only selection in words, naming it",
          raised is not None and "does nothing to" in raised and '"Camera"' in raised, raised)
    print("        " + str(raised))
    bpy.ops.object.select_all(action='DESELECT')
    try:
        run(name)
        raised = None
    except RuntimeError as exc:
        raised = str(exc)
    check(f"and {what} with nothing selected says so", raised is not None and "selected" in raised,
          raised)

# A camera alongside a mesh is Blender's own behaviour: it does the mesh.
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.object.camera_add(location=(4, 0, 0))
bpy.ops.mesh.primitive_cube_add(size=2, location=(1, 2, 3))
mesh = bpy.context.object
mesh.scale = (1, 2, 3)
for obj in bpy.data.objects:
    obj.select_set(True)
bpy.context.view_layer.objects.active = mesh
bpy.context.view_layer.update()
try:
    run("APPLY_SCALE")
    mixed = None
except Exception as exc:
    mixed = str(exc)
check("but a camera next to a mesh is not refused", mixed is None, mixed)
check("and the mesh is the one that gets baked",
      tuple(round(c, 3) for c in mesh.scale) == (1.0, 1.0, 1.0), tuple(mesh.scale))


print("\nthe menus' undo steps are named as Blender names them")
names = blocks["OBJECT_OP_UNDO_NAMES"].split("\n")
origin_label = bpy.ops.object.origin_set.get_rna_type().name
apply_label = bpy.ops.object.transform_apply.get_rna_type().name
check(f"Set Origin's six rows: {origin_label!r}", names[:6] == [origin_label] * 6, names[:6])
check(f"Apply's four rows: {apply_label!r}", names[6:] == [apply_label] * 4, names[6:])


print("\nwhich objects each operator acts on, type by type")


def make(kind, light=None):
    """One object of `kind` at (1,2,3), turned 0.3 about X and scaled 2,
    selected and active, with geometry where the type has any."""
    bpy.ops.wm.read_homefile(use_empty=True)
    at = dict(location=(1, 2, 3))
    if kind == "MESH": bpy.ops.mesh.primitive_cube_add(**at)
    elif kind == "CURVE": bpy.ops.curve.primitive_bezier_curve_add(**at)
    elif kind == "SURFACE": bpy.ops.surface.primitive_nurbs_surface_sphere_add(**at)
    elif kind == "FONT": bpy.ops.object.text_add(**at)
    elif kind == "META": bpy.ops.object.metaball_add(**at)
    elif kind == "ARMATURE": bpy.ops.object.armature_add(**at)
    elif kind == "LATTICE": bpy.ops.object.add(type='LATTICE', **at)
    elif kind == "EMPTY" and light == "INSTANCE":
        # An empty instancing a collection of one triangle, which is what
        # Add ▸ Collection Instance makes.
        parts = bpy.data.collections.new("Parts")
        mesh = bpy.data.meshes.new("Part")
        mesh.from_pydata([(2, 2, 0), (4, 2, 0), (4, 5, 0)], [], [(0, 1, 2)])
        parts.objects.link(bpy.data.objects.new("Part", mesh))
        bpy.ops.object.collection_instance_add(collection=parts.name, **at)
    elif kind == "EMPTY": bpy.ops.object.empty_add(**at)
    elif kind == "CAMERA": bpy.ops.object.camera_add(**at)
    elif kind == "LIGHT": bpy.ops.object.light_add(type=light, **at)
    elif kind == "SPEAKER": bpy.ops.object.speaker_add(**at)
    elif kind == "LIGHT_PROBE": bpy.ops.object.lightprobe_add(type='SPHERE', **at)
    elif kind == "VOLUME": bpy.ops.object.volume_add(**at)
    elif kind == "CURVES":
        bpy.ops.object.add(type='CURVES', **at)
        bpy.context.object.data.add_curves([4])
        for i, point in enumerate(bpy.context.object.data.points):
            point.position = (3 + i, 0, 0)
    elif kind == "POINTCLOUD": bpy.ops.object.pointcloud_random_add(**at)
    elif kind == "GREASEPENCIL": bpy.ops.object.grease_pencil_add(type='STROKE', **at)
    o = bpy.context.object
    o.rotation_euler = (0.3, 0, 0)
    o.scale = (2, 2, 2)
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    bpy.context.view_layer.update()
    return o


def snapshot():
    """Everything Apply or Set Origin can change: each object's own channels,
    and what its data holds that a bake rewrites."""
    state = {}
    for o in bpy.data.objects:
        values = [c for row in o.matrix_basis for c in row]
        if o.type == 'MESH':
            co = array('f', [0.0]) * (3 * len(o.data.vertices))
            o.data.vertices.foreach_get('co', co)
            values += list(co)
        elif o.type == 'LIGHT':
            values += [getattr(o.data, 'size', 0.0), getattr(o.data, 'size_y', 0.0)]
        elif o.type == 'EMPTY':
            values.append(o.empty_display_size)
        elif o.type == 'FONT':
            values.append(o.data.size)
        state[o.name] = values
    return state


def outcome(build, action):
    """'changed', 'nothing', or 'refused: <what was said>' — compared at the
    menus' own tolerance (LocalTransform.tolerance), so float noise the menu
    rightly calls nothing is nothing here too."""
    build()
    before = snapshot()
    try:
        action()
    except RuntimeError as exc:
        return "refused: " + str(exc).strip().splitlines()[-1]
    bpy.context.view_layer.update()
    after = snapshot()
    moved = before.keys() != after.keys() or any(
        len(before[k]) != len(after[k]) or any(abs(a - b) > 1e-5 for a, b in zip(before[k], after[k]))
        for k in before)
    return "changed" if moved else "nothing"


def cursor_then(action):
    def go():
        bpy.context.scene.cursor.location = (7, -5, 3)
        action()
    return go


bare_scale = lambda: bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
bare_origin = cursor_then(lambda: bpy.ops.object.origin_set(type='ORIGIN_CURSOR'))
for line in blocks["REACH"].split("\n"):
    kind, light, origin_acts, apply_acts = line.split()
    light = None if light == "-" else light
    noun = ("empty instancing a collection" if light == "INSTANCE"
            else kind.lower().replace("_", " ") if light is None else f"{light.lower()} light")
    label = ("an " if noun[0] in "aeiou" else "a ") + noun
    build = lambda: make(kind, light)
    for acts, name, bare, sent in ((apply_acts == "1", "Apply Scale", bare_scale, "APPLY_SCALE"),
                                   (origin_acts == "1", "Set Origin", bare_origin, "ORIGIN_CURSOR")):
        did = outcome(build, bare)
        guarded = outcome(build, cursor_then(lambda: run(sent)))
        if acts:
            check(f"{name} acts on {label}, and Blender changes it", did == "changed", did)
            check(f"and the guard lets it through", guarded == "changed", guarded)
        else:
            check(f"{name} does nothing to {label}, as Blender does nothing", did != "changed", did)
            check(f"and the guard says so, naming it",
                  guarded.startswith("refused") and "does nothing to" in guarded and '"' in guarded,
                  guarded)

# What Blender refuses in its own words reaches the banner in them: the guard
# stands aside, and the sentence is Blender's.
for kind, light, row, words in (("FONT", None, "APPLY_LOCATION", "Text objects can only have their scale applied"),
                                ("LIGHT", "AREA", "APPLY_ALL", "Area Lights can only have scale applied")):
    said = outcome(lambda: make(kind, light), lambda: run(row))
    check(f"{row} on {'text' if light is None else 'an area light'} is refused in Blender's words",
          said.startswith("refused") and words in said, said)
o = make("LIGHT", "AREA")
size = o.data.size
run("APPLY_SCALE")
check("Apply Scale on an area light bakes the scale into its size",
      abs(o.data.size - 2 * size) < 1e-6 and tuple(o.scale) == (1.0, 1.0, 1.0), (size, o.data.size, tuple(o.scale)))


print("\nthe channels the mirror sends for Apply are the ones Blender bakes")


def one(o=None, *others, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for x in (o,) + others:
        x.select_set(True)
    bpy.context.view_layer.objects.active = active or o
    bpy.context.view_layer.update()


def a_cube(name="Cube", location=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=2, location=location)
    o = bpy.context.object
    o.name = name
    return o


def a_child(scale):
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.object.empty_add()
    parent = bpy.context.object
    parent.scale = (0.01, 0.01, 0.01)
    child = a_cube()
    child.parent = parent
    child.scale = (scale, scale, scale)
    one(child)


def a_fresh_cube(**channels):
    bpy.ops.wm.read_homefile(use_empty=True)
    o = a_cube()
    for key, value in channels.items():
        setattr(o, key, value)
    one(o)


SCENARIOS = {
    "identity": lambda: a_fresh_cube(),
    "mirrored": lambda: a_fresh_cube(scale=(-1, 1, 1)),
    "child_of_small": lambda: a_child(1),
    "child_x100": lambda: a_child(100),
    "turned_45": lambda: a_fresh_cube(rotation_euler=(0, 0, math.radians(45))),
    "turned_10": lambda: a_fresh_cube(rotation_euler=(0, 0, math.radians(10))),
    "noise": lambda: a_fresh_cube(scale=(1.0000001, 1, 1)),
    "delta_scale": lambda: a_fresh_cube(delta_scale=(2, 1, 1)),
    "delta_location": lambda: a_fresh_cube(delta_location=(0, 0, 1)),
    "quaternion": lambda: a_fresh_cube(rotation_mode='QUATERNION', rotation_quaternion=(0.9, 0.3, 0, 0)),
    "zero_quaternion": lambda: a_fresh_cube(rotation_mode='QUATERNION', rotation_quaternion=(0, 0, 0, 0)),
    "axis_angle": lambda: a_fresh_cube(rotation_mode='AXIS_ANGLE', rotation_axis_angle=(0.4, 1, 0, 0)),
    "zxy_delta": lambda: a_fresh_cube(rotation_mode='ZXY', rotation_euler=(0.1, 0.2, 0.3),
                                      delta_rotation_euler=(0.05, 0, 0.1)),
    "area_x2": lambda: make("LIGHT", "AREA"),
    "point_x2": lambda: make("LIGHT", "POINT"),
    "empty_x2": lambda: make("EMPTY"),
    "instance": lambda: make("EMPTY", "INSTANCE"),
    "scale_1_0002": lambda: a_fresh_cube(scale=(1.0002, 1, 1)),
    "text": lambda: make("FONT"),
    "camera_only": lambda: make("CAMERA"),
}


def camera_and_mesh():
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.object.camera_add(location=(4, 0, 0))
    bpy.context.object.scale = (2, 2, 2)
    camera = bpy.context.object
    one(a_cube(), camera)


def active_unselected():
    bpy.ops.wm.read_homefile(use_empty=True)
    big = a_cube("Big", (3, 0, 0))
    big.scale = (2, 2, 2)
    plain = a_cube("Plain")
    one(plain, active=big)


def no_active():
    """Delete the active object, then Select All: a selection, and no active
    object."""
    bpy.ops.wm.read_homefile(use_empty=True)
    cube = a_cube("Scaled")
    cube.scale = (1, 2, 3)
    one(cube)
    bpy.context.view_layer.objects.active = None


SCENARIOS["camera_and_mesh"] = camera_and_mesh
SCENARIOS["active_unselected"] = active_unselected
SCENARIOS["no_active"] = no_active

ROWS = {"all": (True, True, True), "location": (True, False, False),
        "rotation": (False, True, False), "scale": (False, False, True)}
BAKED_BY_APPLY = lambda o: o.type not in {'CAMERA', 'SPEAKER', 'LIGHT_PROBE', 'VOLUME', 'LIGHT'} \
    or (o.type == 'LIGHT' and o.data.type == 'AREA')
records = []
for name, build in SCENARIOS.items():
    build()
    bridge.local = {}
    sync.sync()
    objects = []
    for o in bpy.context.scene.objects:
        pushed = bridge.pushed.get(o.name)
        if pushed is None:
            continue
        local = bridge.local.get(o.name)
        objects.append(dict(name=o.name, kind=pushed["kind"], matrix=pushed["matrix"],
                            selected=pushed["selected"], active=pushed["active"],
                            local=local, display=bridge.displays.get(o.name)))
        # The pushed channels against Blender's own composition of them.
        basis = o.matrix_basis
        s = local[7:10] if local else [0, 0, 0]
        want_scale = [a * b for a, b in zip(o.scale, o.delta_scale)]
        rotation = basis.to_3x3() @ Matrix.Diagonal([1 / c for c in s]) if all(s) else None
        q = rotation.to_quaternion() if rotation is not None else None
        ok = (local is not None
              and all(abs(local[i] - basis.translation[i]) < 1e-5 for i in range(3))
              and all(abs(local[7 + i] - want_scale[i]) < 1e-6 for i in range(3))
              and q is not None
              and min(max(abs(a - b) for a, b in zip(local[3:7], q)),
                      max(abs(a + b) for a, b in zip(local[3:7], q))) < 1e-5)
        check(f"{name}: {o.name}'s channels are matrix_basis's, deltas and sign included", ok,
              (local, tuple(basis.translation), tuple(q) if q else None, want_scale))
    active = bpy.context.view_layer.objects.active
    record = dict(name=name, objects=objects, apply={})
    if active is not None and active.select_get() and BAKED_BY_APPLY(active):
        record["scale"] = [a * b for a, b in zip(active.scale, active.delta_scale)]
    for row, (l, r, sc) in ROWS.items():
        record["apply"][row] = dict(
            bare=outcome(build, lambda: bpy.ops.object.transform_apply(location=l, rotation=r, scale=sc)),
            sent=outcome(build, lambda: run("APPLY_" + row.upper())))
    record["origin"] = dict(bare=outcome(build, bare_origin),
                            sent=outcome(build, cursor_then(lambda: run("ORIGIN_CURSOR"))))
    records.append(record)
if RECORDS:
    with open(RECORDS, "w") as f:
        json.dump(records, f)
    print(f"        {len(records)} scenarios written for the Swift to replay")

# A keyed channel moves with the playhead, and a frame change pushes matrices
# only; the channels have to follow, or Apply answers for the old frame.
spec = importlib.util.spec_from_file_location(
    "_blenderkit_anim", ROOT / "Resources/python/site/_blenderkit_anim.py")
anim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(anim)
sys.modules["_blenderkit_anim"] = anim
o = cube()
o.keyframe_insert("location", frame=1)
o.location = (3, 0, 0)
o.keyframe_insert("location", frame=10)
bpy.context.scene.frame_set(1)
sync.sync()
bridge.local, bridge.frames = {}, []
anim.frame_set(10)
check("after a frame change the channels the menu reads are the new frame's",
      bridge.frames == [10] and abs(bridge.local.get("Cube", [0])[0] - 3.0) < 1e-5,
      (bridge.frames, bridge.local.get("Cube")))


print("\ntransforms land where the drag's preview put them")


def rows(values):
    return [values[0:3], values[3:6], values[6:9]]


def same_points(actual, expected, tolerance=2e-3):
    wanted = [expected[i:i + 3] for i in range(0, len(expected), 3)]
    got = [tuple(p) for p in actual]
    near = lambda a, b: all(abs(a[k] - b[k]) < tolerance for k in range(3))
    return (all(any(near(g, w) for g in got) for w in wanted)
            and all(any(near(g, w) for w in wanted) for g in got))


for name, label in (("ROTATE_VIEW_OBJECT", "the outer ring"), ("ROTATE_AXIS_OBJECT", "a Z ring")):
    o = cube(rotation=tuple(floats(name + "_START")))
    try:
        run(name)
        error = None
    except Exception as exc:
        error = str(exc)
    bpy.context.view_layer.update()
    got = o.matrix_world.to_3x3()
    want = rows(floats(name + "_EXPECT"))
    check(f"{label}: Blender accepts what it sends", error is None, error)
    check(f"{label}: and turns the object to where the preview did",
          all(abs(got[i][j] - want[i][j]) < 2e-3 for i in range(3) for j in range(3)), (got, want))

o = cube(location=(1, 2, 0))
edit(o)
run("ROTATE_VIEW_EDIT")
o.update_from_editmode()
check("the outer ring while editing turns the vertices to where the preview did",
      same_points([v.co for v in o.data.vertices], floats("ROTATE_VIEW_EDIT_EXPECT")))
bpy.ops.object.mode_set(mode='OBJECT')

o = cube(rotation=tuple(floats("SCALE_LOCAL_OBJECT_START")))
run("SCALE_LOCAL_OBJECT")
want = floats("SCALE_LOCAL_OBJECT_EXPECT")
check("a scale of a turned object keeps the shape the preview showed",
      all(abs(o.scale[i] - want[i]) < 2e-3 for i in range(3)), (tuple(o.scale), want))

o = cube(location=(0.5, -0.5, 0), rotation=(0, 0, math.pi / 4))
edit(o)
run("SCALE_LOCAL_EDIT")
o.update_from_editmode()
check("and while editing",
      same_points([v.co for v in o.data.vertices], floats("SCALE_LOCAL_EDIT_EXPECT")))
bpy.ops.object.mode_set(mode='OBJECT')

a = cube(location=(2, 0, 0), rotation=(0, 0, math.pi / 4), name="A")
b = cube(location=(-2, 1, 0), rotation=(0, 0, math.pi / 6), name="B", fresh=False)
a.select_set(True)
b.select_set(True)
bpy.context.view_layer.objects.active = a
bpy.context.view_layer.update()
run("SCALE_LOCAL_MULTI")
want = floats("SCALE_LOCAL_MULTI_EXPECT")
got = list(a.location) + list(a.scale) + list(b.location) + list(b.scale)
check("two turned objects scaled together land where the preview put them",
      all(abs(g - w) < 2e-3 for g, w in zip(got, want)), (got, want))

print("\nwhat the drags used to send, for contrast")
# The strings the gizmo emitted before these fixes, run the same way. If either
# of these starts passing, the check above is no longer telling the two apart.
o = cube(rotation=tuple(floats("ROTATE_VIEW_OBJECT_START")))
try:
    run_text("bpy.ops.transform.rotate(value=0.5000, orient_axis='VIEW')", "<old view ring>")
    old_view = None
except TypeError as error:
    old_view = str(error)
check("the old outer-ring rotation is refused by Blender", old_view is not None and "VIEW" in old_view,
      old_view)
print("        " + str(old_view))
o = cube(rotation=tuple(floats("SCALE_LOCAL_OBJECT_START")))
run_text(blocks["SCALE_LOCAL_OBJECT"].replace(", orient_type='LOCAL'", ""), "<old scale>")
want = floats("SCALE_LOCAL_OBJECT_EXPECT")
check("the old scale, without the local orientation, lands on a different shape from the preview",
      any(abs(o.scale[i] - want[i]) > 0.05 for i in range(3)), (tuple(o.scale), want))
print("        old: scale " + str(tuple(round(c, 4) for c in o.scale)) + ", preview "
      + str(tuple(round(c, 4) for c in want)))

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
