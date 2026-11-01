"""What the transformops checks share: the app's context in a headless
Blender — its C module stood in for, the modules it ships loaded from
Resources/python/site, gpu.init(), the app's undo stack — and the fixtures."""
import bpy, bmesh, gpu, sys, os, json, types, importlib.util, pathlib, math
from mathutils import Vector, Matrix, Euler, Quaternion

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources/python/site"
sys.dont_write_bytecode = True
fail = 0
passed = 0


def check(label, ok, detail=""):
    global fail, passed
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if ok:
        passed += 1
    else:
        fail += 1


class _App(types.ModuleType):
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


ctx = load("_blenderkit_context")
for _name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools", "_blenderkit_select"):
    load(_name)
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
orient = load("_blenderkit_orient")
item = load("_blenderkit_item")

WORK = os.environ.get("BK_WORK") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "bk-transformops")
os.makedirs(WORK, exist_ok=True)
gpu.init()
undo.push(os.path.join(WORK, "hist"), "start")


def push(label, replace=False):
    undo.push(os.path.join(WORK, "hist"), label, replace=replace)


def reset():
    """An empty scene in Object Mode, the cursor at rest, Global."""
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for collection in (bpy.data.meshes, bpy.data.curves, bpy.data.lattices):
        for d in list(collection):
            if d.users == 0:
                collection.remove(d)
    scene = bpy.context.scene
    scene.cursor.location = (0, 0, 0)
    scene.cursor.rotation_mode = 'XYZ'
    scene.cursor.rotation_euler = (0, 0, 0)
    scene.transform_orientation_slots[0].type = 'GLOBAL'
    scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
    for flag in ('use_proportional_edit', 'use_proportional_edit_objects'):
        setattr(scene.tool_settings, flag, False)


def make(kind, name, location=(0, 0, 0), rotation=(0, 0, 0), scale=(1, 1, 1), **kw):
    adders = {'cube': bpy.ops.mesh.primitive_cube_add, 'grid': bpy.ops.mesh.primitive_grid_add,
              'sphere': bpy.ops.mesh.primitive_uv_sphere_add, 'ico': bpy.ops.mesh.primitive_ico_sphere_add,
              'cylinder': bpy.ops.mesh.primitive_cylinder_add, 'monkey': bpy.ops.mesh.primitive_monkey_add,
              'empty': bpy.ops.object.empty_add, 'curve': bpy.ops.curve.primitive_bezier_curve_add,
              'lattice': None}
    if kind == 'lattice':
        data = bpy.data.lattices.new(name)
        obj = bpy.data.objects.new(name, data)
        bpy.context.scene.collection.objects.link(obj)
        bpy.context.view_layer.update()
    else:
        adders[kind](**kw)
        obj = bpy.context.active_object
    obj.name = name
    obj.location = location
    obj.rotation_euler = rotation
    obj.scale = scale
    for o in list(bpy.context.view_layer.objects):
        if o is not None:
            o.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.context.view_layer.update()
    return obj


def axes_of(m3):
    """A mathutils 3x3 whose columns are axes, as three tuples."""
    return [tuple(m3.col[i]) for i in range(3)]


def blender_matrix(kind):
    """Blender's own orientation matrix for `kind`, as transform.translate
    works it out when it is given the type alone: a move of nothing with the
    undo on (outside any area override, where a registered operator's redo
    panel is safe), then the matrix it stored in its own properties. Returns
    the three axes, or None when it registered nothing."""
    wm = bpy.context.window_manager
    before = wm.operators[-1].as_pointer() if len(wm.operators) else None
    result = bpy.ops.transform.translate('EXEC_DEFAULT', True, value=(0, 0, 0), orient_type=kind)
    # Only an operator registered by this call: a CANCELLED one registers
    # nothing, and the last one in the list would be another case's.
    if 'FINISHED' not in result or not len(wm.operators) or wm.operators[-1].as_pointer() == before:
        return None
    props = wm.operators[-1].properties
    if props.orient_matrix_type != kind:
        return None
    return axes_of(props.orient_matrix)


def blender_matrix_in_view(obj, kind):
    """Blender's matrix for `kind` as its 3D View works it out — with the
    scene's pivot point, which a headless transform does not read (it falls
    back to the bounds centre with no View3D, so Active Element's Normal is
    never active-only there). Measured by displacement: a move of 1 along
    each axis, under the startup screen's borrowed 3D View with the undo off
    (no redo panel to build there), each read off a selected vertex — or the
    object — and put back."""
    def where():
        if obj.mode == 'EDIT':
            bm = bmesh.from_edit_mesh(obj.data)
            bm.verts.ensure_lookup_table()
            v = [v for v in bm.verts if v.select][0]
            return obj.matrix_world @ v.co
        return obj.matrix_world.translation.copy()
    out = []
    for i in range(3):
        value = [0.0, 0.0, 0.0]
        value[i] = 1.0
        if obj.mode == 'EDIT':
            bm = bmesh.from_edit_mesh(obj.data)
            saved = [v.co.copy() for v in bm.verts]
        else:
            saved = obj.location.copy()
        before = where()
        with ctx.temp_override_view3d('check'):
            bpy.ops.transform.translate(value=value, orient_type=kind)
        after = where()
        if obj.mode == 'EDIT':
            bm = bmesh.from_edit_mesh(obj.data)
            for v, c in zip(bm.verts, saved):
                v.co = c
            # The normals too: the next axis is worked out from them.
            bm.normal_update()
            bmesh.update_edit_mesh(obj.data)
        else:
            obj.location = saved
            bpy.context.view_layer.update()
        out.append(tuple(after - before))
    return out


def close_axes(a, b, tol=1e-5):
    if a is None or b is None:
        return False
    return all((Vector(x) - Vector(y)).length < tol for x, y in zip(a, b))


def fmt_axes(a):
    if a is None:
        return "None"
    return "[" + ", ".join("(%.4f, %.4f, %.4f)" % tuple(v) for v in a) + "]"


def finish():
    print("%d PASS, %d FAIL" % (passed, fail), flush=True)
    sys.exit(1 if fail else 0)
