"""The Transform fields, run by the Blender they run on.

scripts/run-transformfields-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`, and the app's context is built as the app builds it:
an undo stack (`ed.undo_push` under the window, which `_blenderkit_undo`
does on device) and `gpu.init()`. Nothing here needs either — the fields only
assign RNA properties — but the measurement is the one the app would get.

The scene is the review's: Child parented to Parent with the app's own
Object ▸ Parent string, Parent then moved 2 in X and turned 90° about Z, and
a Grandchild under Child. Beside it: a quaternion under a turned, scaled
holder parented with Keep Transform, an object with deltas in ZXY Euler, an
axis angle, and a mirrored scale under the holder.

The app's own `_blenderkit_sync.push_local` sends each object's channels to a
`_blenderkit` that records them. Then every string tests/transformfields/
blender/main.swift prints for a field is run, one at a time: what Blender
then holds, every object's `matrix_world`, and the scene put back.
"""
import bpy, sys, types, json, math, pathlib, importlib.util
from array import array

sys.dont_write_bytecode = True
CALLS, RECORDS = sys.argv[sys.argv.index("--") + 1:][:2]
ROOT = pathlib.Path(__file__).resolve().parents[3]

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`, keeping what `push_local` sends
    under the rule PythonBootstrap.c holds it to: ten and eleven doubles."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.local = {}
        self.channels = {}

    def sync_local(self, name, values):
        numbers = array('d')
        numbers.frombytes(values)
        if len(numbers) != 10:
            raise ValueError("sync_local wants ten doubles, got %d" % len(numbers))
        self.local[name] = list(numbers)

    def sync_channels(self, name, values):
        numbers = array('d')
        numbers.frombytes(values)
        if len(numbers) != 11:
            raise ValueError("sync_channels wants eleven doubles, got %d" % len(numbers))
        self.channels[name] = list(numbers)


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


load("_blenderkit_context")
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
sync = load("_blenderkit_sync")

# The app's context: an undo stack and an initialised GPU.
window = bpy.context.window_manager.windows[0]
with bpy.context.temp_override(window=window, screen=window.screen):
    bpy.ops.ed.undo_push(message="Transform fields check")
import gpu  # noqa: E402 - after the undo stack, as the app does it
gpu.init()

namespace = {"bpy": bpy}


def run(block):
    exec(compile(blocks[block], "<" + block + ">", "exec"), namespace)


for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)


def cube(name, location):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.object
    obj.name = name
    return obj


def parent(child, to, keep=False):
    """Object ▸ Parent as the app sends it: the child selected, the parent
    selected and active."""
    for obj in bpy.data.objects:
        obj.select_set(False)
    child.select_set(True)
    to.select_set(True)
    bpy.context.view_layer.objects.active = to
    run("PARENT_KEEP" if keep else "PARENT")


parent_obj = cube("Parent", (0, 0, 0))
child = cube("Child", (0, 3, 0))
grandchild = cube("Grandchild", (0, 5, 1))
parent(child, parent_obj)
parent(grandchild, child)
parent_obj.location = (2, 0, 0)
parent_obj.rotation_euler = (0, 0, math.pi / 2)

holder = cube("Holder", (1, 1, 0))
holder.rotation_euler = (0.3, 0, 0.5)
holder.scale = (2, 1, 1)
bpy.context.view_layer.update()
quat = cube("Quat", (0, -3, 1))
quat.rotation_mode = 'QUATERNION'
quat.rotation_quaternion = (2, 0.3, 0.1, 0.4)
quat.delta_rotation_quaternion = (0.9, 0.1, 0, 0.2)
parent(quat, holder, keep=True)
mirror = cube("Mirror", (-2, 0, 0))
mirror.scale = (-1, 1, 1)
parent(mirror, holder)

delta = cube("Delta", (0, 0, 2))
delta.rotation_mode = 'ZXY'
delta.rotation_euler = (0.3, 0.2, 1.1)
delta.delta_location = (1, 0, 0)
delta.delta_rotation_euler = (0, 0, 0.4)
delta.delta_scale = (1, 2, 1)
delta.scale = (1.5, 1, 0.5)

axis_angle = cube("AxisAngle", (3, 3, 0))
axis_angle.rotation_mode = 'AXIS_ANGLE'
axis_angle.rotation_axis_angle = (0.5, 0, 1, 1)
bpy.context.view_layer.update()

ORDER = ["Parent", "Child", "Grandchild", "Holder", "Quat", "Delta", "AxisAngle", "Mirror"]


def row_major(m):
    return [float(c) for row in m for c in row]


def rotation_of(obj):
    if obj.rotation_mode == 'QUATERNION':
        return [float(c) for c in obj.rotation_quaternion]
    if obj.rotation_mode == 'AXIS_ANGLE':
        return [float(c) for c in obj.rotation_axis_angle]
    return [float(c) for c in obj.rotation_euler]


def state(obj):
    sync.push_local(obj)
    return dict(channels=bridge.channels[obj.name], local=bridge.local[obj.name],
                matrix=row_major(obj.matrix_world),
                parent=obj.parent.name if obj.parent else None,
                location=[float(c) for c in obj.location], rotation_mode=obj.rotation_mode,
                rotation=rotation_of(obj), scale=[float(c) for c in obj.scale])


def saved():
    return {o.name: (tuple(o.location), tuple(o.rotation_euler), tuple(o.rotation_quaternion),
                     tuple(o.rotation_axis_angle), tuple(o.scale)) for o in bpy.data.objects}


def restore(values):
    for name, (loc, euler, quaternion, axis_angle, scale) in values.items():
        obj = bpy.data.objects[name]
        obj.location, obj.rotation_euler = loc, euler
        obj.rotation_quaternion, obj.rotation_axis_angle, obj.scale = quaternion, axis_angle, scale
    bpy.context.view_layer.update()


before = {name: state(bpy.data.objects[name]) for name in ORDER}
original = saved()
edits = {}
fail = 0
for key in [k for k in blocks if k.startswith("EDIT|")]:
    _, name, group, axis = key.split("|")
    error = None
    try:
        run(key)
    except Exception as exc:              # noqa: BLE001 - the failure is the finding
        error = str(exc)
    bpy.context.view_layer.update()
    obj = bpy.data.objects[name]
    sync.push_local(obj)
    edits[name + "|" + group + "|" + axis] = dict(
        python=blocks[key], error=error,
        matrices={o.name: row_major(o.matrix_world) for o in bpy.data.objects},
        channels=bridge.channels[name])
    restore(original)
    back = {n: row_major(bpy.data.objects[n].matrix_world) for n in ORDER}
    if any(max(abs(a - b) for a, b in zip(back[n], before[n]["matrix"])) > 1e-6 for n in ORDER):
        print("  FAIL  the scene was not put back after " + key)
        fail += 1

print("  %d field edits run in Blender %s" % (len(edits), bpy.app.version_string))
json.dump(dict(before=before, edits=edits, order=ORDER), open(RECORDS, "w"))
sys.exit(1 if fail else 0)
