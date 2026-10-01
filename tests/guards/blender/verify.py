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
    Levels stepper, Every Property, an Array's count and Voxel Remesh from the
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
sculpt = load("_blenderkit_sculpt")
if not NEGATIVE:
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
    check("%s: counted %d, Blender evaluates %d" % ([k for k, _ in stack], multires.stack_vertices(obj),
                                                    evaluated(obj)),
          multires.stack_vertices(obj) == evaluated(obj))

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
    # What the Subdivision row sends for a new level (BpyBridge.modifierSettings).
    row = ("__import__('_blenderkit_multires').check_setting(\"Subdivision\", \"levels\", 7)\n"
           "bpy.context.object.modifiers[\"Subdivision\"].levels = 7\n"
           "bpy.context.object.modifiers[\"Subdivision\"].render_levels = 7")
    said = attempt(lambda: exec(row, {'bpy': bpy}))
    check("the Levels stepper's lines for level 7: refused before anything is set",
          said.startswith("refused") and obj.modifiers['Subdivision'].levels == 1, said)
    said = attempt(lambda: exec(row.replace("7", "3"), {'bpy': bpy}))
    check("and for level 3: set", said.startswith("ran") and obj.modifiers['Subdivision'].levels == 3, said)
    said = attempt(lambda: sync.set_property('bpy.data.objects["Cube"].modifiers["Subdivision"]',
                                             'levels', 7))
    check("Every Property's levels = 7: refused", said.startswith("refused")
          and obj.modifiers['Subdivision'].levels == 3, said)
    obj.modifiers.new('Array', 'ARRAY')
    said = attempt(lambda: multires.check_setting("Array", "count", 500, obj))
    check("an Array count of 500 over it: refused", said.startswith("refused"), said)
finally:
    multires.BUDGET = kept

obj = cube()
obj.data.remesh_voxel_size = 0.0048
said = f3('object.voxel_remesh')
check("Voxel Remesh from the search at a 0.0048 voxel on a 2 m cube: refused, the mesh as it was",
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

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
