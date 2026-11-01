"""The gate's behaviour, for run-budget-tests.sh (round 4's fix round 2
review: the host suite held the gate's wiring by the source alone, and with
`_judge` answering None at once and the Edit Mode transaction refusing
nothing, it still printed ALL PASS).

Desktop Blender with the app's context (its modules from BK_SITE, or the
source tree; `_blenderkit_context.install`, gpu.init(), the app's undo
push), sandboxed by the script that starts it. Each case is one of the
budget's own, refused before Blender builds it, and Blender's own count is
read after: a script line's write, an Edit Mode operator (the transaction),
a driver, a handler and a frame. Then (fix round 3's review) a setting
Blender works out itself, a text's Texture Space: turned automatic again it
passes, refused with a growth it is put back, and the list of every setting
the gate takes for Blender's own working-out holds none that makes a vertex.
A handful of seconds.

Nothing here opens a window, a browser or another app.
"""
import bpy, gpu, sys, os, types, importlib.util, pathlib, threading

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = pathlib.Path(os.environ.get("BK_SITE") or ROOT / "Resources/python/site")
WORK = sys.argv[sys.argv.index("--") + 1]
fail = 0

import webbrowser, subprocess


def _blocked(*a, **k):
    raise RuntimeError("blocked by the budget smoke: no browser or subprocess")


webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


class _App(types.ModuleType):
    def is_main_thread(self):
        return threading.current_thread() is threading.main_thread()

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
context.install(bpy)
for name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools", "_blenderkit_points"):
    load(name)
budget = load("_blenderkit_budget")
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
gpu.init()
undo.push(os.path.join(WORK, ".blender-history"), "start")
gate = sys.modules["_blenderkit_gate"]


def mirror():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def count(obj):
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


def cube_array():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    bpy.context.view_layer.update()
    return a, m


def refused(said):
    return said is not None and "and this app stops at 2,500,000" in said


print("\n7. the gate's behaviour, in desktop Blender with the app's context")
a, m = cube_array()
m.count = 400_000
said = mirror()
check("a script line's Array Count 400,000 is refused, Blender stays at 16", refused(said) and count(a) == 16, said)

a, m = cube_array()
m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
bpy.context.view_layer.objects.active = a
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
try:
    bpy.ops.transform.resize(value=(0.00005, 1.0, 1.0))
    said = None
except RuntimeError as error:
    said = str(error)
bpy.ops.object.mode_set(mode='OBJECT')
check("an Edit Mode Resize of 0.00005 under an Array fitted to 40 is refused by the transaction, Blender at 168",
      refused(said) and count(a) == 168, said)

a, m = cube_array()
curve = m.driver_add("count")
curve.driver.expression = "400000"
said = mirror()
check("a driver of '400000' on Count is refused and muted, Blender at 16",
      refused(said) and count(a) == 16 and curve.mute, said)


def writes(scene=None, depsgraph=None):
    mod = bpy.data.objects["A"].modifiers["Array"]
    if mod.count != 400_000:
        mod.count = 400_000


a, m = cube_array()
bpy.app.handlers.depsgraph_update_post.append(writes)
a.location.x = 1.0
said = mirror()
bpy.app.handlers.depsgraph_update_post.remove(writes)
check("a depsgraph_update_post handler writing Count 400,000 is refused, Blender at 16",
      refused(said) and count(a) == 16, said)

a, m = cube_array()
bpy.context.scene.frame_set(1)
m.keyframe_insert("count", frame=1)
m.count = 400_000
m.keyframe_insert("count", frame=10)
m.count = 2
bpy.context.view_layer.update()
try:
    bpy.context.scene.frame_set(10)
    said = None
except RuntimeError as error:
    said = str(error)
check("a script's frame_set(10), Count keyed 400,000 there, is refused and the frame stays 1",
      refused(said) and count(a) == 16 and bpy.context.scene.frame_current == 1, said)
bpy.context.scene.frame_set(1)


# A setting Blender works out itself (fix round 3's `_derived` in
# _blenderkit_gate.py, October 29). A text's Texture Space Location and Size
# are read-only while Auto Texture Space is on, and Blender works them out on
# the original as well as on its evaluated copy: turned back on by a script
# line, the original reads the automatic place at once (rna_Curve_texspace_set
# -> BKE_curve_texspace_calc) while the copy holds the place it was moved to
# until Blender evaluates. Measured in sandboxed desktop 5.2.1 with the app's
# context, the gate with `_derived` taken out (6d31b90's code reads the same):
# the difference was priced as a write, the price wrote it on its copy of the
# text, and the line was refused — "The vertex budget could not price this
# change (bpy_struct: attribute "texspace_location" from "TextCurve" is
# read-only), so it was put back." — Auto Texture Space put back off. The
# budget check met it only after parts 1 to 8 (its 35-minute run), as the
# first mirror pass of part 11.
def text_with_moved_space(array=False):
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.object.text_add()
    t = bpy.context.object
    t.data.body = "Hi"
    if array:
        t.modifiers.new("Array", 'ARRAY').count = 2
    bpy.context.view_layer.update()
    # Each write evaluated on its own: Auto Texture Space off and the place
    # moved in one go loses the place (see docs/blender-local.md, still open).
    t.data.use_auto_texspace = False
    bpy.context.view_layer.update()
    t.data.texspace_location = (5.0, 5.0, 5.0)
    bpy.context.view_layer.update()
    return t


def space(block):
    return tuple(round(v, 4) for v in block.texspace_location)


t = text_with_moved_space()
moved = space(t.data)
t.data.use_auto_texspace = True
said = mirror()
copy = t.data.evaluated_get(bpy.context.evaluated_depsgraph_get())
check("a script line turning Auto Texture Space back on, on a text whose Texture Space was moved to (5, 5, 5), "
      "passes, and Blender evaluates the automatic place (%s, the copy %s)" % (space(t.data), space(copy)),
      said is None and moved == (5.0, 5.0, 5.0) and t.data.use_auto_texspace and copy.use_auto_texspace
      and space(copy) == space(t.data) != moved, said)

# Only the setting Blender works out is let go: a growth written in the same
# line is still refused, in the budget's own words (without `_derived` the
# words were the price's failure above), and what is put back is what Blender
# evaluated, the Texture Space at (5, 5, 5) with it. Measured with the
# difference dropped instead of put back (this round's first `_derived`):
# refused, Auto Texture Space went back off and the place stayed at the
# automatic (0.4835, 0.341, 0), which Blender then evaluated.
t = text_with_moved_space(array=True)
held = count(t)
t.data.use_auto_texspace = True
t.modifiers["Array"].count = 400_000
said = mirror()
copy = t.data.evaluated_get(bpy.context.evaluated_depsgraph_get())
check("and with it, in the same line, the text's Array Count 400,000 is refused by the budget, Blender stays at %d "
      "with Auto Texture Space off and its Texture Space where it was (%s, the copy %s)"
      % (held, space(t.data), space(copy)),
      refused(said) and count(t) == held and t.modifiers["Array"].count == 2 and not t.data.use_auto_texspace
      and space(t.data) == space(copy) == (5.0, 5.0, 5.0), said)

# What `_derived` can let go at all: every setting whose RNA definition is
# writable and that reads read-only now, on a fixture of every object type the
# app adds, every modifier and constraint type on a cube (a Cloth with Linear
# bending among them) and a lattice with a shape key. Blender 5.2.1's RNA
# makes a setting read-only at run time through an editable function
# (RNA_def_property_editable_func); of the ones on what the gate compares,
# none makes a vertex. A setting new here fails this and is to be looked at.
# Nothing here is evaluated: the gate is held off, the fixtures removed first.
LET_GO = {
    'texspace_location': "where a texture is mapped (Auto Texture Space)",
    'texspace_size': "how large the texture's space is (Auto Texture Space)",
    'points_u': "a lattice's resolution once it has a shape key: a Lattice deforms, it makes no vertex",
    'points_v': "the same",
    'points_w': "the same",
    'use_mesh_mirror_y': "Sculpt and paint symmetry, on an object that is not a mesh",
    'use_mesh_mirror_z': "the same",
    'internal_compression_stiffness': "a Cloth's internal springs with Linear bending: a simulation setting",
    'internal_compression_stiffness_max': "the same",
    'internal_spring_max_diversion': "the same",
    'internal_spring_max_length': "the same",
    'internal_spring_normal_check': "the same",
    'internal_tension_stiffness': "the same",
    'internal_tension_stiffness_max': "the same",
    'vertex_group_intern': "the same",
}
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)
bpy.context.view_layer.update()
gate._busy += 1
made = []
try:
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    made.append(cube)
    for kind in [i.identifier for i in bpy.types.Modifier.bl_rna.properties['type'].enum_items]:
        try:
            m = cube.modifiers.new(kind, kind)
        except (TypeError, RuntimeError):
            continue
        if kind == 'CLOTH':
            m.settings.bending_model = 'LINEAR'
    for kind in [i.identifier for i in bpy.types.Constraint.bl_rna.properties['type'].enum_items]:
        try:
            cube.constraints.new(kind)
        except (TypeError, RuntimeError):
            continue
    for add in (bpy.ops.curve.primitive_bezier_curve_add, bpy.ops.surface.primitive_nurbs_surface_surface_add,
                bpy.ops.object.text_add, bpy.ops.object.metaball_add, bpy.ops.object.armature_add,
                bpy.ops.object.empty_add, lambda: bpy.ops.object.add(type='LATTICE'),
                lambda: bpy.ops.object.add(type='LATTICE')):
        add()
        made.append(bpy.context.object)
    made[-1].shape_key_add(name="Basis")
    found = {}

    def walk(struct, depth, where):
        for ident, kind, _ in gate._props(struct):
            if kind == 'ID':
                continue
            if kind in ('STRUCT', 'COLLECTION'):
                if depth >= 3:
                    continue
                try:
                    value = getattr(struct, ident)
                except (AttributeError, RuntimeError, ReferenceError):
                    continue
                if kind == 'STRUCT':
                    if value is not None and hasattr(value, 'bl_rna') and gate._owned(struct, ident, value):
                        walk(value, depth + 1, where + "." + ident)
                else:
                    for item in list(value)[:16]:
                        if hasattr(item, 'bl_rna'):
                            walk(item, depth + 1, where + "." + ident)
                continue
            if gate._derived(struct, ident):
                found.setdefault((type(struct).__name__, ident), where)

    for name in sorted(set(gate._COLLECTIONS.values())):
        for block in getattr(bpy.data, name, ()):
            walk(block, 0, block.name)
            if isinstance(block, bpy.types.Object):
                for item in list(block.modifiers) + list(block.constraints):
                    walk(item, 1, block.name + " " + item.name)
                for bone in (block.pose.bones if block.pose else ()):
                    walk(bone, 1, block.name + " " + bone.name)
finally:
    for obj in made:
        bpy.data.objects.remove(obj)
    gate._busy -= 1
bpy.context.view_layer.update()
unknown = {k: v for k, v in found.items() if k[1] not in LET_GO}
check("what the gate takes for Blender's own working-out is only settings that make no vertex: %d found on a "
      "fixture of every kind (%s)" % (len(found), ", ".join(sorted({"%s.%s" % k for k in found}))[:200]),
      not unknown and ('TextCurve', 'texspace_location') in found and ('Lattice', 'points_u') in found, unknown)

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
