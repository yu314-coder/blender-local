"""The guards round 3's review found missing, run by a headless Blender with
the app's context: the app's undo stack (its history's first push), gpu.init(),
and the operator search's path (window and screen, no area). The modules are
the ones the app ships from Resources/python/site.

  * Loop cut: `mesh.loopcut` and `mesh.loopcut_slide` given an edge index
    segfault Blender with no 3D View in the context (shown here by a Blender
    of its own, without the guard), are refused in words with the guard, from
    a script and from the operator search, and still cut inside
    `temp_override_view3d`.
  * The vertex budget counts what Blender evaluates: the whole modifier stack
    (exact against Blender on seven stacks), a Multires with a Subdivision
    below it, Subdivision Set from the operator search, the Subdivision row's
    Levels stepper, the Data API browser, an Array's count and Voxel Remesh from the
    operator search — each refused before it runs, past a budget lowered so a
    small mesh crosses it.
  * Symmetry's coordinates: with a shape key other than Basis active, the
    edit mesh's (the active key's), not the Basis.
  * Duplicate in a mesh's Edit Mode copies the selected elements.

    scripts/run-guards-blender-check.sh
"""
import bpy, bmesh, gpu, sys, os, types, tempfile, subprocess, importlib.util, pathlib
from array import array

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources/python/site"
sys.dont_write_bytecode = True
NEGATIVE = "negative-loopcut" in sys.argv
# A Blender of its own that opens a file saved in a paint or sculpt mode, as
# the app opens its autosave at launch, and picks a brush there: with
# `give_brush_tool`, or without it (the crash that guard exists for).
BRUSH_CASE = sys.argv[sys.argv.index("brush-case") + 1:] if "brush-case" in sys.argv else None
# A Blender of its own that enters temp_override with a screen and no window,
# unwrapped: the crash `_blenderkit_context.install` refuses.
NEGATIVE_OVERRIDE = "negative-override" in sys.argv
# A Blender of its own that runs one of Blender's interface operators,
# unwrapped (`_blenderkit_context.INTERFACE_ONLY`): with no area, or under the
# borrowed 3D View.
NEGATIVE_INTERFACE = sys.argv[sys.argv.index("negative-interface") + 1:] if "negative-interface" in sys.argv else None
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


class _App(types.ModuleType):
    # The app's C module: this is Blender's main thread, and every other entry
    # point (the viewport's mirror) records nothing.
    def is_main_thread(self):
        return True

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules['_blenderkit'] = _App('_blenderkit')


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
for name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(name)
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
load("_blenderkit_knife")
multires = load("_blenderkit_multires")
# The budget itself, which _blenderkit_multires loads from beside it.
budget = sys.modules['_blenderkit_budget']
sculpt = load("_blenderkit_sculpt")
vwpaint = load("_blenderkit_vwpaint")
if not NEGATIVE and not NEGATIVE_OVERRIDE and not NEGATIVE_INTERFACE:
    context.install(bpy)
gpu.init()
undo.push(tempfile.mkdtemp(prefix="bk-guards-"), "Original")


def attempt(body):
    try:
        return "ran " + repr(body())
    except Exception as error:
        return "refused: " + str(error).strip().replace("\n", " ")


def f3(path, values=None):
    """The operator search's Run, exactly."""
    return attempt(lambda: sync.run_operator(path, dict(values or {})))


def counts(obj):
    if obj.mode == 'EDIT':
        bm = bmesh.from_edit_mesh(obj.data)
        return len(bm.verts), len(bm.edges), len(bm.faces)
    return len(obj.data.vertices), len(obj.data.edges), len(obj.data.polygons)


def evaluated(obj):
    graph = bpy.context.evaluated_depsgraph_get()
    graph.update()
    return len(obj.evaluated_get(graph).data.vertices)


def cube():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.mesh.primitive_cube_add(size=2)
    obj = bpy.context.object
    obj.name = "Cube"
    return obj


def edit(obj, select='ALL', mode='VERT'):
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    for element in list(bm.verts) + list(bm.edges) + list(bm.faces):
        element.select = select == 'ALL'
    if select == 'FACE0':
        face = bm.faces[0]
        face.select = True
        for element in list(face.edges) + list(face.verts):
            element.select = True
    bmesh.update_edit_mesh(obj.data)


# The line Blender's Info editor logs for every loop cut.
INFO_LINE = ("bpy.ops.mesh.loopcut_slide(MESH_OT_loopcut={'number_cuts': 1, 'smoothness': 0, "
             "'falloff': 'INVERSE_SQUARE', 'object_index': 0, 'edge_index': 4, "
             "'mesh_select_mode_init': (True, False, False)}, TRANSFORM_OT_edge_slide={'value': 0.0})")

def view_tool(key):
    window, area, region = sculpt._knife.view3d()
    with bpy.context.temp_override(window=window, area=area, region=region):
        return bpy.context.workspace.tools.from_space_view3d_mode(key, create=False)


BRUSH_TOOL_KEYS = {'VERTEX_PAINT': 'PAINT_VERTEX', 'WEIGHT_PAINT': 'PAINT_WEIGHT', 'SCULPT': 'SCULPT'}
if BRUSH_CASE:
    mode, path, brush, guarded = BRUSH_CASE[0], BRUSH_CASE[1], BRUSH_CASE[2], BRUSH_CASE[3] == "guarded"
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    key = BRUSH_TOOL_KEYS[mode]
    print("CASE opened in %s, 3D View tool %s" % (bpy.data.objects["Saved"].mode, view_tool(key)), flush=True)
    if not guarded:
        # The one implementation the Brush menu and every other route share
        # (`_blenderkit_sculpt.ensure_view_tool` and `_blenderkit_context`'s
        # Activate Brush Asset entry both call it).
        context.give_brush_tool = lambda *arguments: None
    print("CASE about to pick " + brush, flush=True)
    said = attempt(lambda: (sculpt if mode == 'SCULPT' else vwpaint).activate(brush))
    held = (bpy.context.scene.tool_settings.sculpt if mode == 'SCULPT' else vwpaint._paint(mode)).brush
    print("CASE survived: %s; Blender's brush %s; 3D View tool %s; still in %s"
          % (said, held.name if held else None, view_tool(key) is not None, bpy.data.objects["Saved"].mode),
          flush=True)
    sys.exit(0)


if NEGATIVE_INTERFACE:
    call, where = NEGATIVE_INTERFACE[0], NEGATIVE_INTERFACE[1]
    print("NEGATIVE about to run %s (%s)" % (call, where), flush=True)
    if where == "view":
        with context.temp_override_view3d("negative"):
            exec(call, {'bpy': bpy})
    else:
        exec(call, {'bpy': bpy})
    print("NEGATIVE survived", flush=True)
    sys.exit(0)


if NEGATIVE_OVERRIDE:
    print("NEGATIVE about to enter temp_override(window=None, screen=None)", flush=True)
    with bpy.context.temp_override(window=None, screen=None):
        pass
    print("NEGATIVE survived", flush=True)
    sys.exit(0)

if NEGATIVE:
    # A Blender of its own, without the guard: the crash it exists for.
    edit(cube(), 'ALL', 'EDGE')
    print("NEGATIVE about to run the Info line", flush=True)
    exec(INFO_LINE, {'bpy': bpy})
    print("NEGATIVE survived", flush=True)
    sys.exit(0)

# --------------------------------------------------------------------------
print("\nLoop cut without a 3D View")

home = os.environ.get("HOME", tempfile.gettempdir())
negative = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup", "--python", __file__, "--",
                           "negative-loopcut"], capture_output=True, text=True, timeout=180,
                          cwd=home, env=dict(os.environ))
check("control: without the guard, the Info editor's loop-cut line takes Blender down "
      "(exit %d)" % negative.returncode,
      "NEGATIVE about to run" in negative.stdout and "NEGATIVE survived" not in negative.stdout
      and negative.returncode != 0, negative.stdout[-300:])
obj = cube()
edit(obj, 'ALL', 'EDGE')
before = counts(obj)
said = attempt(lambda: exec(INFO_LINE, {'bpy': bpy}))
check("with it, the same line is refused in words, the mesh as it was",
      said.startswith("refused") and "3D View" in said and counts(obj) == before, said)
said = attempt(lambda: bpy.ops.mesh.loopcut(edge_index=0))
check("bpy.ops.mesh.loopcut(edge_index=0) from a script: refused", said.startswith("refused"), said)
said = f3('mesh.loopcut', {'number_cuts': 1, 'edge_index': 0, 'object_index': 0})
check("the operator search's loopcut with an edge index: refused", said.startswith("refused"), said)
check("and the operator keeps its own poll, RNA, signature and documentation",
      bpy.ops.mesh.loopcut.poll() and bpy.ops.mesh.loopcut_slide.get_rna_type().identifier
      == "MESH_OT_loopcut_slide" and bpy.ops.mesh.loopcut.idname() == "MESH_OT_loopcut"
      and repr(bpy.ops.mesh.loopcut).startswith("bpy.ops.mesh.loopcut(")
      and (bpy.ops.mesh.loopcut.__doc__ or "").startswith("bpy.ops.mesh.loopcut("),
      (repr(bpy.ops.mesh.loopcut), bpy.ops.mesh.loopcut.__doc__))
with context.temp_override_view3d("Loop Cut"):
    bpy.context.area.spaces.active.region_3d.update()
    result = bpy.ops.mesh.loopcut_slide(MESH_OT_loopcut={'number_cuts': 1, 'edge_index': 4,
                                                         'object_index': 0},
                                        TRANSFORM_OT_edge_slide={'value': 0.0})
check("inside temp_override_view3d it cuts: %s -> %s" % (before, counts(obj)),
      'FINISHED' in result and counts(obj) == (12, 20, 10), (result, counts(obj)))

# --------------------------------------------------------------------------
print("\nA script's temp_override with a screen and no window")

# Found probing for the brush case below (2026-10-20): Blender's
# temp_override enter reads the active screen of the window it is to put a
# screen into, and with window=None it segfaults (WM_window_get_active_screen).
negative = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup", "--python", __file__, "--",
                           "negative-override"], capture_output=True, text=True, timeout=180,
                          cwd=home, env=dict(os.environ))
check("control: unwrapped, temp_override(window=None, screen=None) takes Blender down (exit %d)"
      % negative.returncode, "NEGATIVE about to enter" in negative.stdout
      and "NEGATIVE survived" not in negative.stdout and negative.returncode != 0, negative.stdout[-300:])


def enter(**members):
    def body():
        with bpy.context.temp_override(**members):
            return bpy.context.window is not None
    return attempt(body)


said = enter(window=None, screen=None)
check("wrapped, it is refused in words (%s), and the context is intact" % said[:70],
      said.startswith("refused") and "no window" in said and bpy.context.window is not None
      and bpy.context.screen is not None, said)
said = enter(window=None, screen=bpy.context.screen)
check("so is a screen with window=None", said.startswith("refused"), said)
for members in ({"window": None}, {"screen": None}, {"area": None}, {"region": None},
                {"screen": None, "area": None}):
    said = enter(**members)
    check("%s alone still enters, as Blender's does" % sorted(members), said.startswith("ran"), said)
check("and the window and screen are back after", bpy.context.window is not None
      and bpy.context.screen is not None)

# --------------------------------------------------------------------------
print("\nA brush picked in a file saved in a paint or sculpt mode")

# Measured in the app (2026-10-19): its autosave, saved in Vertex Paint,
# opened with no 3D View tool for the mode, and the Brush menu's pick
# (`brush.asset_activate`) crashed bpy 5.3 in WM_toolsystem_activate_brush_and_tool,
# which reads the mode's tool without asking whether there is one. Each case
# is a Blender of its own, as the app is at launch: a session that has
# entered the mode keeps its tool across a load without the file's interface.
folder = tempfile.mkdtemp(prefix="bk-guards-brush-")
for mode, brush in (('VERTEX_PAINT', "Paint Hard"), ('WEIGHT_PAINT', "Blur"), ('SCULPT', "Clay Strips")):
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16)
    bpy.context.object.name = "Saved"
    bpy.ops.object.mode_set(mode=mode)
    path = os.path.join(folder, mode.lower() + ".blend")
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    bpy.ops.object.mode_set(mode='OBJECT')
    runs = {}
    for how in (("guarded", "unguarded") if mode in ('VERTEX_PAINT', 'SCULPT') else ("guarded",)):
        runs[how] = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup", "--python", __file__, "--",
                                    "brush-case", mode, path, brush, how], capture_output=True, text=True,
                                   timeout=180, cwd=home, env=dict(os.environ))
    out = runs["guarded"].stdout
    check("%s, a file saved in it opened by a Blender of its own: no 3D View tool for it, and the Brush "
          "menu's pick of %s runs, Blender's brush is it, the tool is there"
          % (mode, brush), ("opened in %s, 3D View tool None" % mode) in out
          and ("CASE survived: ran '%s'; Blender's brush %s; 3D View tool True; still in %s" % (brush, brush, mode))
          in out and runs["guarded"].returncode == 0, out[-400:])
    if "unguarded" in runs:
        bad = runs["unguarded"]
        check("  control: without the guard the same pick takes that Blender down (exit %d)" % bad.returncode,
              "about to pick" in bad.stdout and "CASE survived" not in bad.stdout and bad.returncode != 0,
              bad.stdout[-300:])

# --------------------------------------------------------------------------
print("\nThe vertex budget counts what Blender evaluates")

stacks = [[('MULTIRES', 2), ('SUBSURF', 1)], [('MULTIRES', 3), ('SUBSURF', 2)],
          [('SUBSURF', 2), ('ARRAY', 3)], [('ARRAY', 3), ('SUBSURF', 2)],
          [('MIRROR', None), ('SUBSURF', 2)], [('SOLIDIFY', None), ('SUBSURF', 1)],
          [('WEIGHTED_NORMAL', None), ('SUBSURF', 3)]]
obj = cube()
for stack in stacks:
    obj.modifiers.clear()
    for kind, level in stack:
        modifier = obj.modifiers.new(kind.title(), kind)
        if kind == 'MULTIRES':
            for _ in range(level):
                bpy.ops.object.multires_subdivide(modifier=modifier.name, mode='CATMULL_CLARK')
        elif kind == 'SUBSURF':
            modifier.levels = level
        elif kind == 'ARRAY':
            modifier.count = level
        elif kind == 'MIRROR':
            modifier.use_mirror_merge = False
    # The budget's cheap count is exact where its model is (`Counts.exact`),
    # else an upper bound — Solidify's Rim Fill is counted as if every edge
    # were open (a cube has none: 76 against 52 under a level-1 Subdivision),
    # which the refinement a count past the budget gets replaces with
    # Blender's own (_blenderkit_budget._final). Both are held here.
    s = budget.Prices()
    try:
        cheap = budget._walk(obj, s)
        refined = budget._walk(obj, s, refine=True).final.v
    finally:
        s.close()
    n = evaluated(obj)
    check("%s: counted %d%s, refined %d, Blender evaluates %d"
          % ([k for k, _ in stack], cheap.final.v, "" if cheap.final.exact else " (a bound)", refined, n),
          multires.stack_vertices(obj) == cheap.final.v >= n and refined == n
          and (cheap.final.v == n or not cheap.final.exact))

kept = multires.BUDGET
multires.BUDGET = 30000
try:
    obj = cube()
    obj.modifiers.new('Subdivision', 'SUBSURF').levels = 2
    obj.modifiers.new('Multires', 'MULTIRES')
    presses = []
    for _ in range(6):
        said = attempt(lambda: multires.run('subdivide', 'Multires'))
        presses.append((said[:6], obj.modifiers['Multires'].total_levels, evaluated(obj)))
        if said.startswith("refused"):
            break
    check("Multires Subdivide over a Subdivision at level 2 stops before Blender evaluates past "
          "the budget: %s" % presses,
          presses[-1][0].startswith("refus") and presses[-1][1] == 4 and max(p[2] for p in presses) <= 30000
          and "once the modifiers below it are counted" in said, said)

    obj = cube()
    said = f3('object.subdivision_set', {'level': 7})
    check("Subdivision Set level 7 from the search: refused, nothing added",
          said.startswith("refused") and len(obj.modifiers) == 0, said)
    said = f3('object.subdivision_set', {'level': 3})
    check("level 3 runs, and Blender evaluates what was counted (%d)" % evaluated(obj),
          said.startswith("ran") and evaluated(obj) == multires.stack_vertices(obj) == 386, said)
    obj.modifiers.clear()
    obj.modifiers.new('Multires', 'MULTIRES')
    obj.modifiers.new('Subdivision', 'SUBSURF').levels = 1
    said = f3('object.subdivision_set', {'level': 6})
    check("on a Multires over a Subdivision, level 6: refused, no level made",
          said.startswith("refused") and obj.modifiers['Multires'].total_levels == 0, said)

    obj = cube()
    obj.modifiers.new('Subdivision', 'SUBSURF').levels = 1
    # What the Subdivision row sends for a new level (Bpy.modifierEdit: the
    # budget's price for every setting the edit sends, then the settings).
    row = ("__import__('_blenderkit_budget').price_modifier(\"Subdivision\", {\"levels\": 7, \"render_levels\": 7})\n"
           "bpy.context.object.modifiers[\"Subdivision\"].levels = 7\n"
           "bpy.context.object.modifiers[\"Subdivision\"].render_levels = 7")
    said = attempt(lambda: exec(row, {'bpy': bpy}))
    check("the Levels stepper's lines for level 7: refused before anything is set",
          said.startswith("refused") and obj.modifiers['Subdivision'].levels == 1, said)
    said = attempt(lambda: exec(row.replace("7", "3"), {'bpy': bpy}))
    check("and for level 3: set", said.startswith("ran") and obj.modifiers['Subdivision'].levels == 3, said)
    said = attempt(lambda: sync.set_property('bpy.data.objects["Cube"].modifiers["Subdivision"]',
                                             'levels', 7))
    check("the Data API browser's levels = 7: refused", said.startswith("refused")
          and obj.modifiers['Subdivision'].levels == 3, said)
    obj.modifiers.new('Array', 'ARRAY')
    said = attempt(lambda: multires.check_setting("Array", "count", 500, obj))
    check("an Array count of 500 over it: refused", said.startswith("refused"), said)
finally:
    multires.BUDGET = kept

obj = cube()
# A cube remeshes to 1.02 vertices per voxel-sized square of its area
# (desktop 5.2.1), so a 0.003 voxel would make about 2.7 million, past the
# budget. (Round 3 used 0.0048, which made 1,043,336 and is under it: the
# estimate this round, an upper bound for thin shapes too, lets that one run.)
obj.data.remesh_voxel_size = 0.003
said = f3('object.voxel_remesh')
check("Voxel Remesh from the search at a 0.003 voxel on a 2 m cube: refused, the mesh as it was",
      said.startswith("refused") and len(obj.data.vertices) == 8, said)
obj.data.remesh_voxel_size = 0.05
said = f3('object.voxel_remesh')
check("and at 0.05 it runs (%d vertices)" % len(obj.data.vertices),
      said.startswith("ran") and len(obj.data.vertices) > 8, said)

# --------------------------------------------------------------------------
print("\nSymmetry's coordinates under a shape key")

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)
bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10, size=2)
grid = bpy.context.object
grid.shape_key_add(name='Basis')
key = grid.shape_key_add(name='Key 1')
for point in key.data:
    point.co.x += 0.1
grid.active_shape_key_index = 1
grid.modifiers.new('Weighted Normal', 'WEIGHTED_NORMAL').show_in_editmode = True
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(grid.data)
bm.verts.ensure_lookup_table()
bm.verts[85].co.z += 0.5
bmesh.update_edit_mesh(grid.data)
grid.update_from_editmode()
reported = array('f')
reported.frombytes(sync._edit_coordinates(grid, grid.data, len(grid.data.vertices)))
bm = bmesh.from_edit_mesh(grid.data)
bm.verts.ensure_lookup_table()
worst = max(abs(reported[3 * i + j] - bm.verts[i].co[j]) for i in range(len(bm.verts)) for j in range(3))
check("Key 1 active: the edit mesh's positions (vertex 85 %s, Basis %s), all within %.1g"
      % (tuple(round(reported[3 * 85 + j], 3) for j in range(3)),
         tuple(round(c, 3) for c in grid.data.vertices[85].co), worst), worst < 1e-6)

# --------------------------------------------------------------------------
print("\nDuplicate in Edit Mode")

obj = cube()
edit(obj, 'FACE0', 'FACE')
objects = len(bpy.data.objects)
# Bpy.duplicateElements, as the More menu's Duplicate sends it while editing.
said = attempt(lambda: exec("bpy.ops.mesh.duplicate_move()", {'bpy': bpy}))
check("one face selected: 8/12/6 -> %s, still one object, still in Edit Mode" % (counts(obj),),
      said.startswith("ran") and counts(obj) == (12, 16, 7) and len(bpy.data.objects) == objects
      and obj.mode == 'EDIT', said)

# --------------------------------------------------------------------------
print("\nA base mesh too heavy to sculpt on a level, from inside Sculpt Mode")

# Sculpt Mode's way in refuses a Multires level on a base mesh past
# MULTIRES_BASE_BUDGET (2,000 vertices). Round 3's review found three ways
# round it from inside Sculpt Mode, at Sculpt level 0 (the base mesh, which is
# allowed): the Modifiers panel's Subdivide, the operator search's
# `object.multires_subdivide` and the panel's Sculpt level stepper.


def heavy():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64)
    obj = bpy.context.object
    obj.name = "Heavy"
    obj.modifiers.new("Multires", 'MULTIRES')
    bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
    obj.modifiers["Multires"].sculpt_levels = 0
    bpy.ops.object.mode_set(mode='SCULPT')
    return obj


def levels(obj):
    m = obj.modifiers["Multires"]
    return (m.levels, m.sculpt_levels, m.total_levels)


obj = heavy()
start = levels(obj)
said = attempt(lambda: multires.run('subdivide', 'Multires'))
check("the panel's Subdivide is refused in words (%s), levels %s kept, still in Sculpt Mode"
      % (said[:60], start), said.startswith("refused") and "2,000" in said
      and levels(obj) == start and obj.mode == 'SCULPT', (said, levels(obj), obj.mode))
said = f3("object.multires_subdivide", {"modifier": "Multires"})
check("the operator search's Multires Subdivide is refused, levels kept, back in Sculpt Mode",
      said.startswith("refused") and "2,000" in said and levels(obj) == start
      and obj.mode == 'SCULPT', (said, levels(obj), obj.mode))
said = attempt(lambda: multires.check_setting("Multires", "sculpt_levels", 1, obj))
check("the Sculpt level stepper's check refuses level 1", said.startswith("refused") and "2,000" in said,
      said)
said = attempt(lambda: multires.check_setting("Multires", "sculpt_levels", 0, obj))
check("and lets level 0 through", said.startswith("ran"), said)
said = attempt(lambda: multires.check_setting("Multires", "levels", 1, obj))
check("and the viewport level, which Sculpt Mode does not sculpt", said.startswith("ran"), said)
bpy.ops.object.mode_set(mode='OBJECT')
said = attempt(lambda: multires.run('subdivide', 'Multires'))
check("in Object Mode the panel's Subdivide runs (%s -> %s)" % (start, levels(obj)),
      said.startswith("ran") and levels(obj)[2] == start[2] + 1, said)
# The negative control: without the check, the panel's Subdivide from Sculpt
# Mode leaves the heavy base sculpted on a level, as round 3 measured. (With
# the check off alone, Sculpt Mode's way back in, `refuse_sculpt_entry`, now
# refuses and leaves it in Object Mode; that is switched off too.)
obj = heavy()
real = sculpt.refuse_heavy_level
real_entry = context.refuse_sculpt_entry
sculpt.refuse_heavy_level = lambda *arguments: None
context.refuse_sculpt_entry = lambda *arguments: None
try:
    said = attempt(lambda: multires.run('subdivide', 'Multires'))
finally:
    sculpt.refuse_heavy_level = real
    context.refuse_sculpt_entry = real_entry
check("negative control: without the check the panel's Subdivide leaves %s sculpted at level %d"
      % (obj.name, levels(obj)[1]), said.startswith("ran") and levels(obj)[1] > 0
      and sculpt.active_multires(obj) is not None, (said, levels(obj)))

# Subdivision Set from the operator search, from Sculpt Mode: the search runs
# it in Object Mode, where Blender's operator subdivides a Multires once per
# missing level and each one raises the Sculpt level, and goes back. Round 4's
# review measured the reviewer's case (an 8,066-vertex base with a new
# Multires, level 1) going back into Sculpt Mode at 1/1/1, which Sculpt
# Mode's way in refuses; only the 2.5M vertex budget was asked.


def heavy_new():
    obj = heavy()
    bpy.ops.object.mode_set(mode='OBJECT')
    obj.modifiers.remove(obj.modifiers["Multires"])
    obj.modifiers.new("Multires", 'MULTIRES')
    bpy.ops.object.mode_set(mode='SCULPT')
    return obj


obj = heavy_new()
said = f3("object.subdivision_set", {"level": 1})
check("the search's Subdivision Set (level 1) on the 8,066-vertex base with a new Multires is refused in "
      "words, levels 0/0/0 kept, still in Sculpt Mode", said.startswith("refused") and "2,000" in said
      and levels(obj) == (0, 0, 0) and obj.mode == 'SCULPT', (said, levels(obj), obj.mode))
obj = heavy()
said = f3("object.subdivision_set", {"level": 1})
check("on the base with a level already (Sculpt level 0) level 1 runs: it sets the viewport level only, "
      "and the base is still what Sculpt Mode sculpts (%s)" % (levels(obj),),
      said.startswith("ran") and levels(obj) == (1, 0, 1) and obj.mode == 'SCULPT'
      and sculpt.active_multires(obj) is None, (said, levels(obj), obj.mode))
said = f3("object.subdivision_set", {"level": 2})
check("and level 2, which would subdivide and sculpt level 2, is refused (%s kept)" % (levels(obj),),
      said.startswith("refused") and levels(obj) == (1, 0, 1) and obj.mode == 'SCULPT', (said, levels(obj)))
# Negative controls: without the check Blender's operator leaves the review's
# 1/1/1, and Sculpt Mode's way back in is then refused by the mode guard
# below (the object stays in Object Mode); without that too, it goes back into
# Sculpt Mode on the level, as round 4's review measured.
obj = heavy_new()
real_heavy = sync._heavy_sculpt_level
sync._heavy_sculpt_level = lambda *arguments: None
try:
    said = f3("object.subdivision_set", {"level": 1})
    first = (said, levels(obj), obj.mode)
    obj = heavy_new()
    real_entry = context.refuse_sculpt_entry
    context.refuse_sculpt_entry = lambda *arguments: None
    try:
        said = f3("object.subdivision_set", {"level": 1})
    finally:
        context.refuse_sculpt_entry = real_entry
    second = (said, levels(obj), obj.mode, sculpt.active_multires(obj) is not None)
finally:
    sync._heavy_sculpt_level = real_heavy
check("negative control: without the check it runs to %s, and the mode guard keeps it out of Sculpt "
      "Mode (%s)" % (first[1], first[2]), first[0].startswith("ran") and first[1] == (1, 1, 1)
      and first[2] == 'OBJECT', first)
check("negative control: without either, back in Sculpt Mode at %s with the Multires sculpted, as the "
      "review measured" % (second[1],), second[0].startswith("ran") and second[1] == (1, 1, 1)
      and second[2] == 'SCULPT' and second[3], second)

# An object already sculpted on a heavy level (a file saved so, which the app
# opens as it is): the panel's Delete Higher from Sculpt Mode runs in Object
# Mode, and Sculpt Mode's way back in now refuses the level it leaves. The
# change is kept, in Object Mode, and not reported as undone.
obj = heavy()
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
obj.modifiers["Multires"].sculpt_levels = 1
real_entry = context.refuse_sculpt_entry
context.refuse_sculpt_entry = lambda *arguments: None
try:
    bpy.ops.object.mode_set(mode='SCULPT')
finally:
    context.refuse_sculpt_entry = real_entry
start = levels(obj)
said = attempt(lambda: multires.run('deleteHigher', 'Multires'))
check("Delete Higher from Sculpt Mode on a base sculpted at a heavy level (%s): runs, leaves %s, and "
      "stays out of Sculpt Mode (%s)" % (start, levels(obj), obj.mode),
      start == (2, 1, 2) and said.startswith("ran") and levels(obj)[2] == 1 and obj.mode == 'OBJECT',
      (said, levels(obj), obj.mode))

# Sculpt Mode's way in, by every road: the mode menu asked
# `refuse_heavy_multires`, and round 4's review measured the search's
# `object.mode_set(mode='SCULPT')` and `sculpt.sculptmode_toggle` entering
# Sculpt Mode at 1/1/1 on the 8,066-vertex base; a script line could too.


def heavy_level():
    obj = heavy()
    bpy.ops.object.mode_set(mode='OBJECT')
    obj.modifiers["Multires"].sculpt_levels = 1
    return obj


for road, run_it in (
        ("the search's object.mode_set(mode='SCULPT')",
         lambda: f3("object.mode_set", {"mode": 'SCULPT'})),
        ("the search's sculpt.sculptmode_toggle", lambda: f3("sculpt.sculptmode_toggle")),
        ("a script line's bpy.ops.object.mode_set(mode='SCULPT')",
         lambda: attempt(lambda: exec("bpy.ops.object.mode_set(mode='SCULPT')", {'bpy': bpy}))),
        ("a script line's mode_set with its undo, toggled",
         lambda: attempt(lambda: exec("bpy.ops.object.mode_set('EXEC_DEFAULT', True, mode='SCULPT', "
                                      "toggle=True)", {'bpy': bpy}))),
        ("a script line's bpy.ops.sculpt.sculptmode_toggle()",
         lambda: attempt(lambda: exec("bpy.ops.sculpt.sculptmode_toggle()", {'bpy': bpy})))):
    obj = heavy_level()
    said = run_it()
    check("%s on the base at levels %s is refused in words, still in Object Mode" % (road, levels(obj)),
          said.startswith("refused") and "2,000" in said and obj.mode == 'OBJECT', (said, obj.mode))
obj = heavy_level()
real_entry = context.refuse_sculpt_entry
context.refuse_sculpt_entry = lambda *arguments: None
try:
    said = f3("object.mode_set", {"mode": 'SCULPT'})
finally:
    context.refuse_sculpt_entry = real_entry
check("negative control: without the guard the search's mode_set enters Sculpt Mode on the level (%s)"
      % obj.mode, said.startswith("ran") and obj.mode == 'SCULPT' and sculpt.active_multires(obj) is not None,
      (said, obj.mode))
bpy.ops.object.mode_set(mode='OBJECT')
obj.modifiers["Multires"].sculpt_levels = 0
said = f3("object.mode_set", {"mode": 'SCULPT'})
check("at Sculpt level 0 (its base mesh) the search's mode_set goes in", said.startswith("ran")
      and obj.mode == 'SCULPT', (said, obj.mode))
said = f3("sculpt.sculptmode_toggle")
check("and its toggle comes out again, which is never refused", said.startswith("ran") and obj.mode == 'OBJECT',
      (said, obj.mode))
obj.modifiers["Multires"].sculpt_levels = 1
bpy.ops.object.mode_set(mode='EDIT')
said = attempt(lambda: exec("bpy.ops.object.mode_set(mode='OBJECT')", {'bpy': bpy}))
check("leaving another mode for Object Mode is never asked", said.startswith("ran") and obj.mode == 'OBJECT',
      said)

# A level too heavy to sculpt on a base light enough (MULTIRES_LEVEL_BUDGET):
# round 3's review put an Undo or a lift on levels 4-5 at 8-10 s in the app
# and a Grab's tree at 534 MB; measured here, level 5 of a 1,986-vertex base
# is 2,064,386 vertices.
obj = cube()
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.delete()
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32)
obj = bpy.context.object
obj.name = "Light"
obj.modifiers.new("Multires", 'MULTIRES')
for _ in range(3):
    bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
bpy.ops.object.mode_set(mode='SCULPT')
said = attempt(lambda: multires.run('subdivide', 'Multires'))
check("on a 1,986-vertex base at level 3, the panel's Subdivide to level 4 (516,098 vertices) is refused "
      "from Sculpt Mode, naming the level to sculpt at", said.startswith("refused") and "516,098" in said
      and "level 3 or lower" in said and obj.modifiers["Multires"].total_levels == 3, said)
said = attempt(lambda: multires.check_setting("Multires", "sculpt_levels", 3, obj))
check("and level 3 (129,026 vertices) sculpts", said.startswith("ran"), said)
said = attempt(lambda: sculpt.refuse_heavy_multires())
check("Sculpt Mode's way in lets level 3 in", said.startswith("ran"), said)
bpy.ops.object.mode_set(mode='OBJECT')
said = attempt(lambda: multires.run('subdivide', 'Multires'))
check("in Object Mode the level is made (the vertex budget allows %d)" % obj.modifiers["Multires"].total_levels,
      said.startswith("ran") and obj.modifiers["Multires"].total_levels == 4, said)
said = attempt(lambda: sculpt.refuse_heavy_multires())
check("and Sculpt Mode's way in refuses it at level 4", said.startswith("refused") and "516,098" in said, said)
obj.modifiers["Multires"].sculpt_levels = 3
said = attempt(lambda: sculpt.refuse_heavy_multires())
check("at Sculpt level 3 it goes in", said.startswith("ran"), said)

# The Sculpt header's Subdivide, on a mesh light enough: what Blender's own
# operator leaves from Sculpt Mode (desktop 5.2.1: viewport level kept, sculpt
# and total raised), where it used to leave 4/4/4.
obj = cube()
bpy.ops.object.mode_set(mode='SCULPT')
for _ in range(4):
    sculpt.multires_subdivide()
mine = levels(obj)
bpy.ops.object.mode_set(mode='OBJECT')
obj.modifiers.remove(obj.modifiers["Multires"])
bpy.ops.object.mode_set(mode='SCULPT')
obj.modifiers.new("Multires", 'MULTIRES')
for _ in range(4):
    bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
blenders = levels(obj)
check("four presses of the Sculpt header's Subdivide leave %s, as Blender's own operator from Sculpt "
      "Mode does (%s)" % (mine, blenders), mine == blenders == (0, 4, 4) and obj.mode == 'SCULPT',
      (mine, blenders))

# --------------------------------------------------------------------------
print("\nBlender's own interface: its menus, pies, panels and regions")

# Each crashed this context in desktop 5.2.1 (round 4's review of group 7;
# `_blenderkit_context.INTERFACE_ONLY`): the first four given what to open,
# with or without an area; the rest under the borrowed 3D View, where every
# command runs in Local View, the search's rows among them. Shown crashing by
# a Blender of its own without the guard (two of them; the operator sweep,
# tests/opsearch/blender, found the others), and refused in words with it:
# from a script, inside the borrowed view, and from the operator search,
# whose form says why before Run.
INTERFACE_CASES = (
    ("wm.call_menu", {"name": "VIEW3D_MT_object"}),
    ("wm.call_menu_pie", {"name": "VIEW3D_MT_object_mode_pie"}),
    ("wm.call_panel", {"name": "VIEW3D_PT_snapping"}),
    ("wm.context_menu_enum", {"data_path": "scene.render.engine"}),
    ("wm.toolbar", {}), ("view3d.object_mode_pie_or_toggle", {}), ("screen.region_quadview", {}),
    ("screen.area_close", {}), ("view2d.pan", {}), ("view2d.scroll_down", {}), ("view2d.scroll_left", {}),
    ("view2d.scroll_right", {}), ("view2d.scroll_up", {}))
check("the cases are every operator INTERFACE_ONLY names",
      sorted(p for p, _ in INTERFACE_CASES) == sorted(context.INTERFACE_ONLY), sorted(context.INTERFACE_ONLY))
for call, where in (("bpy.ops.wm.call_menu(name='VIEW3D_MT_object')", "none"), ("bpy.ops.wm.toolbar()", "view")):
    negative = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup", "--python", __file__, "--",
                               "negative-interface", call, where], capture_output=True, text=True, timeout=180,
                              cwd=home, env=dict(os.environ))
    check("control: unwrapped, %s %s takes Blender down (exit %d)"
          % (call, "with no area" if where == "none" else "under the borrowed 3D View", negative.returncode),
          "NEGATIVE about to run" in negative.stdout and "NEGATIVE survived" not in negative.stdout
          and negative.returncode != 0, negative.stdout[-300:])
cube()
for path, values in INTERFACE_CASES:
    module, name = path.split(".")
    line = "bpy.ops.%s(%s)" % (path, ", ".join("%s=%r" % kv for kv in values.items()))
    plain = attempt(lambda: getattr(getattr(bpy.ops, module), name)(**values))
    with context.temp_override_view3d("Guards"):
        viewed = attempt(lambda: getattr(getattr(bpy.ops, module), name)(**values))
    searched = f3(path, values)
    form = sync.operator_info(path)
    check("%s: refused in words from a script, in the borrowed 3D View and from the search; the form "
          "says why" % line,
          all(said.startswith("refused") and "Blender's own interface" in said for said in (plain, viewed, searched))
          and form["refused"] == context.INTERFACE_ONLY[path] and not form["available"],
          (plain[:90], viewed[:90], searched[:90], form["refused"]))
check("and each keeps its poll, RNA and signature: wm.call_menu polls %s, is %s"
      % (bpy.ops.wm.call_menu.poll(), bpy.ops.wm.call_menu.idname()),
      bpy.ops.wm.call_menu.idname() == "WM_OT_call_menu"
      and repr(bpy.ops.wm.call_menu).startswith("bpy.ops.wm.call_menu("))
check("Blender is still running, its window and screen there",
      bpy.context.window is not None and bpy.context.screen is not None)

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
