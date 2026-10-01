"""Undo on the device, run by a headless Blender the way an iPad runs it.

scripts/run-undo-blender-check.sh starts Blender with `-b --factory-startup`:
no user settings and no 3D View area. Every string run is what the Swift sends,
printed by tests/undo/blender/main.swift, and the modules are the ones the app
ships from Resources/python/site.

Each undoable action is checked the same way: the scene is photographed —
objects, transforms, every mesh vertex, modifiers, modes, selection, a light's
and a camera's settings, keys, the frame and an image's pixels — after each
step; then every undo must give back the photograph of the step before, and
every redo the one after.
"""
import bpy, contextlib, hashlib, importlib.util, io, json, os, pathlib, sys, time, types
from array import array

CALLS, WORK = sys.argv[-2], sys.argv[-1]
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

namespace = {"bpy": bpy}


def run(name, **fill):
    """One block, in the namespace the app's interpreter shares between
    statements, returning what it printed."""
    source = blocks[name]
    for key, value in fill.items():
        source = source.replace("@" + key.upper() + "@", str(value))
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        exec(compile(source, "<" + name + ">", "exec"), namespace)
    return printed.getvalue()


def state_of(printed):
    return json.loads([line for line in printed.splitlines() if line.startswith("{")][-1])


def push(label, replace=False):
    return state_of(run("PUSH_REPLACE" if replace else "PUSH", root=HISTORY, label=label))


def undo():
    return state_of(run("UNDO"))


def redo():
    return state_of(run("REDO"))


# --------------------------------------------------------------------------
# The app's native modules, as much of them as these calls reach

class Quiet(types.ModuleType):
    """Anything not listed does nothing."""

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *args, **kwargs: None


class Bridge(Quiet):
    def mode(self):
        return "OBJECT"


class Paint(Quiet):
    def __init__(self):
        super().__init__("_blenderkit_paint")
        self.stroke = {}

    def image_pixels(self, name):
        return self.stroke.get(name)


sys.modules["_blenderkit"] = Bridge("_blenderkit")
sys.modules["_blenderkit_paint"] = paint = Paint()


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_all():
    # _blenderkit_tools too: the sync reports tool settings whenever the bridge
    # has `tool_state`, which this stand-in answers for every name, and it is
    # not on sys.path here (without it the pass raised ModuleNotFoundError).
    sync, texpaint, anim = (load(name) for name in ("_blenderkit_sync", "_blenderkit_texpaint",
                                                     "_blenderkit_anim"))
    load("_blenderkit_tools")
    return [sync, texpaint, anim, load("_blenderkit_undo")]


sync, texpaint, anim, history = load_all()


# --------------------------------------------------------------------------
# A photograph of the scene

def digest(values):
    return hashlib.sha1(array("f", values).tobytes()).hexdigest()[:16]


def photo():
    for obj in bpy.data.objects:
        if obj.mode == "EDIT":
            obj.update_from_editmode()
    scene = bpy.context.scene
    objects = {}
    for obj in bpy.data.objects:
        entry = dict(type=obj.type, parent=obj.parent.name if obj.parent else None,
                     matrix=digest([c for row in obj.matrix_world for c in row]),
                     mode=obj.mode, selected=obj.select_get(), hidden=obj.hide_viewport,
                     modifiers=[(m.name, m.type) for m in obj.modifiers],
                     materials=[s.material.name if s.material else None for s in obj.material_slots])
        if obj.type == "MESH":
            me = obj.data
            co = array("f", [0.0]) * (3 * len(me.vertices))
            me.vertices.foreach_get("co", co)
            sel = array("b", [0]) * len(me.vertices)
            me.vertices.foreach_get("select", sel)
            entry.update(mesh=me.name, verts=len(me.vertices), faces=len(me.polygons),
                         co=digest(co), vsel=hashlib.sha1(sel.tobytes()).hexdigest()[:12],
                         uvs=[layer.name for layer in me.uv_layers])
        if obj.animation_data and obj.animation_data.action:
            action = obj.animation_data.action
            keys = []
            for curve in getattr(action, "fcurves", []):
                keys.append((curve.data_path, curve.array_index,
                             [tuple(round(v, 5) for v in point.co) for point in curve.keyframe_points]))
            if not keys:
                for layer in getattr(action, "layers", []):
                    for strip in layer.strips:
                        for bag in strip.channelbags:
                            for curve in bag.fcurves:
                                keys.append((curve.data_path, curve.array_index,
                                             [tuple(round(v, 5) for v in p.co) for p in curve.keyframe_points]))
            entry["keys"] = sorted(keys)
        objects[obj.name] = entry
    images = {}
    for image in bpy.data.images:
        if image.has_data or image.packed_file is not None or image.source == "GENERATED":
            values = array("f", [0.0]) * len(image.pixels)
            image.pixels.foreach_get(values)
            images[image.name] = digest(values)
    active = bpy.context.view_layer.objects.active
    return dict(objects=objects, images=images, active=active.name if active else None,
                frame=scene.frame_current,
                lights={l.name: (round(l.energy, 4), l.type) for l in bpy.data.lights},
                cameras={c.name: (round(c.lens, 4), c.show_limits) for c in bpy.data.cameras},
                # A mesh nothing uses is not written to a .blend, so a step
                # restored from a file drops it, as a save and reload would.
                meshes=sorted(m.name for m in bpy.data.meshes if m.users))


def differences(a, b):
    out = []
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            if isinstance(a.get(key), dict) and isinstance(b.get(key), dict):
                out += [key + "." + k for k in sorted(set(a[key]) | set(b[key])) if a[key].get(k) != b[key].get(k)]
            else:
                out.append(key)
    return out


# --------------------------------------------------------------------------

print("headless, as on an iPad")
check("there is no 3D View area here, as there is none for bpy on a device", bpy.context.area is None,
      bpy.context.area)
check("and the main thread has the window and screen Blender's undo operators poll for",
      bpy.context.window is not None and bpy.context.screen is not None)

print("\nthe probe")
started = time.perf_counter()
state = push("Original")
check("Blender's undo works here, so it keeps the history", state["mode"] == "blender", state)
print("        probe: " + state["why"] + "; first step %.1f ms" % ((time.perf_counter() - started) * 1000))
check("the probe leaves nothing behind", "_bk_undo_probe" not in bpy.data.texts)
check("and the history starts with one step, nothing to undo or redo",
      (state["steps"], state["undo"], state["redo"]) == (1, False, False), state)
check("Blender's undo limits are set: 32 steps, 512 MB",
      (bpy.context.preferences.edit.undo_steps, bpy.context.preferences.edit.undo_memory_limit) == (32, 512))

print("\nevery step undone and redone exactly")
photos = [photo()]
labels = ["Original"]
cube = bpy.data.objects["Cube"]


def act(label, *names, before=None):
    if before:
        before()
    for name in names:
        run(name)
    state = push(label)
    photos.append(photo())
    labels.append(label)
    return state


act("Add Cylinder", "CYLINDER")
act("Move", "TRANSLATE")
act("Rotate", "ROTATE")
act("Add Modifier", "MODIFIER")
act("Delete", "DELETE", before=lambda: (run("TAP"), None))
act("Set Energy", "LIGHT_ENERGY")
act("Set Focal Length", "CAMERA_LENS")
act("Set Show Limits", "CAMERA_LIMITS")


def select_cube():
    for obj in bpy.data.objects:
        obj.select_set(obj.name == "Cube")
    bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]


act("Insert Keyframe", "ANIM_INSERT", before=select_cube)
bpy.context.scene.frame_set(12)
bpy.data.objects["Cube"].location.x = 4.0
act("Insert Keyframe", "ANIM_INSERT")
act("Deselect", "DESELECT_ALL")
act("Select All", "SELECT_ALL")
select_cube()
act("Add Paint Slot", "PAINT_ENTER")
image = bpy.data.images["Material Base Color"]
stroke = array("f", [0.8, 0.8, 0.8, 1.0]) * (64 * 64)
for i in range(0, 64 * 16, 4):
    stroke[i] = 0.1
paint.stroke["Material Base Color"] = stroke.tobytes()
act("Texture Paint", "PAINT_WRITE")
stroke[4 * 2000] = 0.95
paint.stroke["Material Base Color"] = stroke.tobytes()
act("Texture Paint", "PAINT_WRITE")
act("Toggle Edit Mode", "TOGGLE_EDIT", before=select_cube)
# A new cube's vertices are all selected, so Select All would change nothing.
act("Deselect", "EDIT_DESELECT_ALL")
act("Select All", "EDIT_SELECT_ALL")
act("Subdivide", "EDIT_SUBDIVIDE")
act("Bevel", "BEVEL")
act("Toggle Edit Mode", "TOGGLE_EDIT")

# Each step against the one before it: Deselect then Select All rightly comes
# back to a scene an earlier step had.
unchanged = [(i, labels[i]) for i in range(1, len(photos)) if photos[i] == photos[i - 1]]
check("every action really changed the scene, so the checks below could fail", not unchanged, unchanged)
check("the edit-mode steps changed the mesh", photos[-2]["objects"]["Cube"]["verts"] > 8,
      photos[-2]["objects"]["Cube"]["verts"])

state = history.state()
check(f"{len(labels)} steps, one per action, with the last one's label on Undo",
      state["steps"] == len(labels) and state["undo_label"] == labels[-1], state)
timings = {"undo": [], "redo": []}
for index in range(len(photos) - 1, 0, -1):
    expected_label = labels[index]
    state = undo()
    timings["undo"].append(state["timing"].get("total", 0))
    got = photo()
    check(f"undo {expected_label} gives back the scene before it",
          got == photos[index - 1], differences(got, photos[index - 1]))
check("at the first step Undo is off and Redo is on", (state["undo"], state["redo"]) == (False, True), state)
for index in range(1, len(photos)):
    state = redo()
    timings["redo"].append(state["timing"].get("total", 0))
    got = photo()
    check(f"redo {labels[index]} gives back the scene after it",
          got == photos[index], differences(got, photos[index]))
check("at the last step Redo is off", (state["undo"], state["redo"]) == (True, False), state)
check("no step needed a file: Blender's undo carried all of them",
      history.state()["mode"] == "blender" and not any(s["file"] for s in history._steps))

print("\nthe viewport is handed painted pixels again after an undo")
texpaint._signatures["Material Base Color"] = ("the viewport's copy",)
undo()
check("an undo that did not touch the image leaves the viewport's copy alone",
      texpaint._signatures.get("Material Base Color") == ("the viewport's copy",))
# Toggle Edit Mode, Bevel, Subdivide, Select All, Deselect and Toggle Edit
# Mode, then the second stroke itself.
for _ in range(6):
    undo()
check("an undo past a stroke forgets it, so the next mirror reads the pixels",
      "Material Base Color" not in texpaint._signatures, history.state()["undo_label"])
for _ in range(7):
    redo()

print("\nadjusting the last operation: undo, run again, push")


def fresh(*names):
    """The scene the adjusted operator should leave, made the long way: back
    to before it, run with the final arguments, photographed, and redone."""
    undo()
    for name in names:
        run(name)
    picture = photo()
    redo()
    return picture


bpy.ops.object.mode_set(mode="OBJECT")
push("Toggle Object Mode")
meshes_before = len(bpy.data.meshes)
run("CYLINDER")
before = history.state()["steps"]
push("Add Cylinder")
for name in ("CYLINDER_8", "CYLINDER_12"):
    run("REWIND")
    run(name)
    state = push("Add Cylinder", replace=True)
adjusted = photo()
check("adjusting twice leaves one step for it", state["steps"] == before + 1 and state["undo_label"] == "Add Cylinder",
      (before, state))
check("a cylinder of 12 vertices, named as the first was, and no orphan mesh",
      [o for o in adjusted["objects"] if o.startswith("Cylinder")] == ["Cylinder"]
      and adjusted["objects"]["Cylinder"]["verts"] == 24
      and len(bpy.data.meshes) == meshes_before + 1, (adjusted["meshes"], meshes_before))
reference = fresh("CYLINDER_12")
check("exactly the scene adding it with 12 vertices in the first place makes",
      adjusted == reference, differences(adjusted, reference))
undo()
check("one undo goes back to before the add", "Cylinder" not in photo()["objects"])
redo()

# A fresh cube, since the picked vertices are numbered on its eight.
bpy.data.objects.remove(bpy.data.objects["Cube"])
bpy.ops.mesh.primitive_cube_add(location=(0, -3, 0))
bpy.context.object.name = "Cube"
push("Add Cube")
select_cube()
run("TOGGLE_EDIT")
push("Toggle Edit Mode")
run("BEVEL_PICKED")
push("Bevel")
run("REWIND")
run("BEVEL_PICKED_WIDE")
push("Bevel", replace=True)
bpy.ops.object.mode_set(mode="OBJECT")
bpy.ops.object.mode_set(mode="EDIT")
widened = photo()
reference = fresh("BEVEL_PICKED_WIDE")
check("an edit-mode bevel adjusted to 0.3: exactly beveling at 0.3, on the same picked vertices",
      widened == reference, differences(widened, reference))
check("and it acted on the picked face alone, handed over again after the undo",
      8 < widened["objects"]["Cube"]["verts"] < 56, widened["objects"]["Cube"]["verts"])
check("no mesh backup was made for it", "_bk_redo" not in bpy.data.meshes)

# A re-run that raises part-way, after changing the mesh.
run("REWIND")
try:
    run("BEVEL_WIDE")
    raise RuntimeError("the re-run failed")
except RuntimeError:
    pass
run("CANCEL_REWIND")
check("a re-run that fails goes back to the last adjustment that worked", photo() == widened,
      differences(photo(), widened))
bpy.ops.object.mode_set(mode="OBJECT")
push("Toggle Object Mode")

print("\nRun Script is one step, and one that loads a file can still be undone")
before_script = photo()
run_script = """
import bpy
for i in range(3):
    bpy.ops.mesh.primitive_ico_sphere_add(location=(i * 2, -4, 0))
bpy.context.object.scale = (2, 2, 2)
bpy.data.objects["Light"].data.energy = 5
"""
exec(compile(run_script, "<Run Script>", "exec"), dict(namespace))
state = push("Run Script")
after_script = photo()
undo()
check("one undo takes back everything the script did", photo() == before_script,
      differences(photo(), before_script))
redo()
check("and one redo puts it back", photo() == after_script, differences(photo(), after_script))

clearing = """
import bpy
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_monkey_add()
"""
exec(compile(clearing, "<Run Script>", "exec"), dict(namespace))
state = push("Run Script")
cleared = photo()
check("a script that loads the factory settings is one step too", state["undo"] and state["undo_label"] == "Run Script",
      state)
check("the context still has its window and screen after the load",
      bpy.context.window is not None and bpy.context.screen is not None)
undo()
check("undo loads the scene the script replaced, as the load_pre handler kept it",
      photo() == after_script, differences(photo(), after_script))
redo()
check("redo loads the script's result", photo() == cleared, differences(photo(), cleared))
bpy.ops.mesh.primitive_cube_add(location=(0, 0, 3))
push("Add Cube")
after_cube = photo()
undo()
check("steps after the load are Blender's undo again", photo() == cleared and history._route(history._index + 1) == "blender",
      differences(photo(), cleared))
redo()
check("and redo", photo() == after_cube)

print("\nthe step limit")
bpy.ops.wm.read_factory_settings(use_empty=True)
sync, texpaint, anim, history = load_all()
push("Original")
bpy.ops.mesh.primitive_cube_add()
for i in range(40):
    bpy.context.object.location.x = i
    state = push("Move")
check("the history holds Blender's 32 undo steps and the state they go back to",
      state["steps"] == history.STEPS + 1, state["steps"])
undos = 0
while history.state()["undo"]:
    undo()
    undos += 1
check("32 undos, and the last one lands on the move before them", undos == 32
      and abs(bpy.context.view_layer.objects.active.location.x - 7) < 1e-6,
      (undos, bpy.context.view_layer.objects.active.location.x))

print("\nthe fallback, forced")
bpy.ops.wm.read_factory_settings(use_empty=False)
sync, texpaint, anim, history = load_all()
state = state_of(run("PUSH_FORCED", root=HISTORY, label="Original"))
check("checkpoints when asked for", state["mode"] == "checkpoint" and "asked" in state["why"], state)
photos = [photo()]
run("CYLINDER"); push("Add Cylinder"); photos.append(photo())
run("TRANSLATE"); push("Move"); photos.append(photo())
select_cube(); run("PAINT_ENTER"); push("Add Paint Slot"); photos.append(photo())
paint.stroke["Material Base Color"] = stroke.tobytes()
run("PAINT_WRITE"); push("Texture Paint"); photos.append(photo())
check("every step is a file", all(s["file"] and os.path.isfile(s["file"]) for s in history._steps))
for index in range(len(photos) - 1, 0, -1):
    undo()
    check(f"checkpoint undo {index}", photo() == photos[index - 1], differences(photo(), photos[index - 1]))
for index in range(1, len(photos)):
    redo()
    check(f"checkpoint redo {index}", photo() == photos[index], differences(photo(), photos[index]))

print("\nthe fallback, after Blender's undo fails")
bpy.ops.wm.read_factory_settings(use_empty=False)
sync, texpaint, anim, history = load_all()
push("Original")
run("CYLINDER"); push("Add Cylinder")
run("TRANSLATE"); push("Move")
moved = photo()
real_operator = history._operator


def broken(name, **arguments):
    if name in ("undo", "redo"):
        raise RuntimeError("Operator bpy.ops.ed." + name + ".poll() failed, context is incorrect")
    return real_operator(name, **arguments)


history._operator = broken
state = undo()
check("a failed undo changes nothing in the scene", photo() == moved, differences(photo(), moved))
check("and the history falls back to checkpoints, saying why",
      state["mode"] == "checkpoint" and "context is incorrect" in state["why"], state)
history._operator = real_operator
run("ROTATE"); state = push("Rotate")
rotated = photo()
check("steps go on as checkpoints", state["mode"] == "checkpoint" and history._steps[-1]["file"], state)
undo()
check("and undo from them works", photo() == moved, differences(photo(), moved))
redo()
check("and redo", photo() == rotated, differences(photo(), rotated))

print("\ncrash recovery")
recovery = os.path.join(WORK, "Documents", "autosave.blend")
started = time.perf_counter()
written = float(run("AUTOSAVE", path=recovery).strip().splitlines()[-1])
check("the autosave is written, whole, where RootView looks", os.path.isfile(recovery)
      and not os.path.exists(recovery + ".partial"))
kept = photo()
bpy.ops.wm.open_mainfile(filepath=recovery, load_ui=False)
check("and opens as the scene it was written from", photo() == kept, differences(photo(), kept))
check("no step writes it any more", not any(name == "autosave.blend" for name in os.listdir(HISTORY)))

print("\nhow long it takes")
bpy.ops.wm.read_factory_settings(use_empty=False)
sync, texpaint, anim, history = load_all()
push("Original")
bpy.ops.mesh.primitive_uv_sphere_add(segments=443, ring_count=222, location=(0, 0, 4))
push("Add Sphere")
print("        a %d-vertex mesh in the scene" % len(bpy.context.object.data.vertices))


def measure(label, count, action):
    values = []
    for _ in range(count):
        started = time.perf_counter()
        action()
        values.append((time.perf_counter() - started) * 1000)
    print("        %-44s %s" % (label, ", ".join("%.2f" % v for v in values) + " ms"))
    return min(values)


def move_and_push():
    bpy.data.objects["Sphere"].location.x += 1
    run("PUSH", root=HISTORY, label="Move")


push_ms = measure("Move, then push (Blender's undo)", 5, move_and_push)
undo_ms = measure("undo (Blender's undo)", 5, lambda: run("UNDO"))
redo_ms = measure("redo (Blender's undo)", 5, lambda: run("REDO"))
save_ms = measure("autosave (a whole .blend)", 3, lambda: run("AUTOSAVE", path=recovery))
sync_ms = measure("the mirror, with the native calls stubbed", 3, sync.sync)
bpy.ops.wm.read_factory_settings(use_empty=False)
sync, texpaint, anim, history = load_all()
state_of(run("PUSH_FORCED", root=HISTORY, label="Original"))
bpy.ops.mesh.primitive_uv_sphere_add(segments=443, ring_count=222, location=(0, 0, 4))
push("Add Sphere")
old_push = measure("Move, then push (checkpoint)", 5, move_and_push)
old_undo = measure("undo (checkpoint)", 5, lambda: run("UNDO"))
check("a push with Blender's undo is cheaper than writing a checkpoint", push_ms < old_push, (push_ms, old_push))
check("an undo with Blender's undo is no slower than loading a checkpoint", undo_ms <= old_undo * 1.5,
      (undo_ms, old_undo))

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
