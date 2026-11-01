"""The Self-Test (`_blenderkit_selftest.py`) run in desktop Blender 5.2.1 with
the app's context, as the app runs it, and held to what it promises.

    Blender -b --factory-startup --python verify.py -- WORK [REQUEST] [only=a,b] [rounds=N] [edit=1] [paint=1] [checkpoints=1] [dirty=1]

REQUEST is the Python the app sends (`SelfTest.python`, dumped from the Swift
by tests/selftest/blender/main.swift); without it the call is made here.
The app's context is built the way the other Blender checks build it: the
modules from BK_SITE (or the source tree), `_blenderkit_context.install`,
gpu.init(), the history's first step in WORK/Documents/.blender-history.
Then a scene of the user's own is made — objects of every kind the
fingerprint reads, a second scene, a collection, keys, a material, a
selection, the 3D cursor, a frame, and (edit=1) the active object left in
Edit Mode — with steps of its own in the history, and the Self-Test runs.

Held, besides every check's own PASS: the report on disk with its header,
one line per check and the summary; what Blender holds afterwards the same as
before (a fingerprint of this file's own, not only the module's); the
history: Undo reaches the user's scene and never a check's, and Redo comes
back; the gate on, the budget at 2,500,000, no temporary file left.

With BK_SITE pointed at 6d31b90's modules this has to fail: Blender crashes
in the first freed-memory case under MallocScribble, or the report has a
FAIL (scripts/run-selftest-blender-check.sh runs both). Nothing here opens a
window, a browser or another app.
"""
import bpy, gpu, sys, os, types, importlib.util, pathlib, threading, json, tempfile, time

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = pathlib.Path(os.environ.get("BK_SITE") or ROOT / "Resources/python/site")
SELFTEST = pathlib.Path(os.environ.get("BK_SELFTEST") or ROOT / "Resources/python/site/_blenderkit_selftest.py")
sys.path.insert(0, str(SITE))
ARGS = sys.argv[sys.argv.index("--") + 1:]
WORK = ARGS[0]
REQUEST = next((a for a in ARGS[1:] if "=" not in a), None)
OPTS = dict(a.split("=", 1) for a in ARGS[1:] if "=" in a)
fail = 0

import webbrowser, subprocess


def _blocked(*a, **k):
    raise RuntimeError("blocked by the Self-Test check: no browser or subprocess")


webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked
import pwd
_real = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, 'Library', 'Application Support', 'Blender')
if os.path.realpath(bpy.utils.user_resource('CONFIG')).startswith(os.path.realpath(_real)):
    raise SystemExit("refusing to run with Blender's own settings folder")


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


def load(name, path=None):
    spec = importlib.util.spec_from_file_location(name, path or SITE / (name + ".py"))
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
selftest = load("_blenderkit_selftest", SELFTEST)
gate = sys.modules["_blenderkit_gate"]
gpu.init()
DOCUMENTS = os.path.join(WORK, "Documents")
HISTORY = os.path.join(DOCUMENTS, ".blender-history")
os.makedirs(DOCUMENTS, exist_ok=True)
if OPTS.get("paint") == "1":
    # The app's launch with its recovery file open in Vertex Paint (the
    # recovery file on this Mac is one): the history's first push comes while
    # an object is in a paint mode, so its probe of Blender's undo waits and
    # its steps are files until a push in Object Mode.
    bpy.ops.object.mode_set(mode='VERTEX_PAINT')
# checkpoints=1: the history kept in .blend files, as where Blender's undo failed its probe.
undo.push(HISTORY, "Original", force_checkpoints=OPTS.get("checkpoints") == "1")


# --------------------------------------------------------------------------
# The user's own work
def users_scene():
    scene = bpy.context.scene
    cube = bpy.data.objects["Cube"]
    cube.modifiers.new("Subdivision", 'SUBSURF').levels = 1
    material = bpy.data.materials.new("Paint")
    cube.data.materials.append(material)
    cube.keyframe_insert("location", frame=1)
    cube.location.x = 2.0
    cube.keyframe_insert("location", frame=20)
    undo.push(HISTORY, "Insert Keyframe")
    bpy.ops.object.empty_add(location=(0, 4, 0))
    rig = bpy.context.object
    rig.name = "Rig"
    bpy.ops.mesh.primitive_uv_sphere_add(location=(1, 4, 1))
    bike = bpy.context.object
    bike.name = "Bike"
    bike.parent = rig
    bike.rotation_euler = (0.3, 0.2, 0.1)
    bike.scale = (1.0, 2.0, 0.5)
    undo.push(HISTORY, "Add UV Sphere")
    bpy.ops.object.text_add(location=(-3, 0, 0))
    bpy.context.object.data.body = "Hello"
    bpy.ops.curve.primitive_bezier_curve_add(location=(-3, -3, 0))
    bpy.context.object.data.bevel_depth = 0.05
    parts = bpy.data.collections.new("Parts")
    scene.collection.children.link(parts)
    bpy.ops.mesh.primitive_monkey_add(location=(4, -4, 0))
    monkey = bpy.context.object
    for holder in list(monkey.users_collection):
        holder.objects.unlink(monkey)
    parts.objects.link(monkey)
    side = bpy.data.scenes.new("Side")
    plane = bpy.data.objects.new("Plane", bpy.data.meshes.new("Plane"))
    side.collection.objects.link(plane)
    scene.frame_set(7)
    scene.cursor.location = (1.0, 2.0, 3.0)
    for obj in bpy.context.view_layer.objects:
        obj.select_set(obj.name in ("Bike", "Text"))
    bpy.context.view_layer.objects.active = bike
    undo.push(HISTORY, "Add Text")
    if OPTS.get("edit") == "1":
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='DESELECT')
        bike.data.vertices[0].select = True
        bpy.ops.object.mode_set(mode='OBJECT')
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.transform.translate(value=(0.0, 0.0, 0.5))
        undo.push(HISTORY, "Move")
    bpy.context.view_layer.update()


if OPTS.get("paint") == "1":
    bpy.data.objects["Cube"].location.x = 0.5
    undo.push(HISTORY, "Move")
else:
    users_scene()
if OPTS.get("dirty") == "1":
    # Pixels painted and not packed: a save would not keep them, so the run
    # has to refuse before it saves or opens anything.
    painted = bpy.data.images.new("Painted", 8, 8)
    pixels = list(painted.pixels)
    pixels[0] = 1.0
    painted.pixels = pixels
    bpy.data.objects["Cube"]["painted"] = painted
before = selftest.fingerprint()
history_before = undo.state()
names_before = {o.name for o in bpy.data.objects}
mode_before = bpy.context.object.mode
print("\nThe user's scene: %d objects, %d vertices, the active object in %s"
      % (before[1], before[2], mode_before), flush=True)

# --------------------------------------------------------------------------
# The run, as the app makes it
report = os.path.join(DOCUMENTS, "Self-Test", "self-test-desktop.txt")
render_output = os.path.join(tempfile.gettempdir(), "self-test-render.png")
started = time.perf_counter()
if REQUEST:
    source = open(REQUEST, encoding="utf-8").read()
    for key, value in (("@REPORT@", report), ("@HISTORY@", HISTORY), ("@RENDER@", render_output)):
        source = source.replace(key, value)
    print("\nThe app's request (%d lines), run" % source.count("\n"), flush=True)
    namespace = {"__name__": "__main__"}
    exec(compile(source, "<SelfTest.python>", "exec"), namespace)
else:
    render = "\n".join([
        "import bpy", "scene = bpy.context.scene",
        "if scene.camera is None:", "    raise RuntimeError('no camera')",
        "scene.render.engine = 'BLENDER_EEVEE'", "scene.render.resolution_x = 64",
        "scene.render.resolution_y = 64", "scene.render.resolution_percentage = 100",
        "scene.render.image_settings.file_format = 'PNG'", "scene.render.filepath = %r" % render_output,
        "if hasattr(scene, 'eevee'):", "    scene.eevee.taa_render_samples = 8",
        "bpy.ops.render.render(write_still=True)"])
    only = set(OPTS["only"].split(",")) if OPTS.get("only") else None
    selftest.run(report, progress=selftest.console_progress, history_root=HISTORY, render_source=render,
                 render_output=render_output, only=only, rounds=OPTS.get("rounds"))
took = time.perf_counter() - started

# --------------------------------------------------------------------------
print("\nThe report", flush=True)
text = open(report, encoding="utf-8").read()
print("\n".join("    | " + line for line in text.splitlines()), flush=True)
lines = text.splitlines()
if OPTS.get("dirty") == "1":
    results = [l for l in lines if l.startswith(("PASS  ", "FAIL  "))]
    check("with painted pixels not saved, the run refuses in one line and touches nothing",
          len(results) == 1 and results[0].startswith("FAIL") and "not run: painted pixels of Painted" in results[0]
          and lines[-1] == "Summary:  not run", results)
    check("Blender holds what it held, the history as it was, nothing saved",
          selftest.fingerprint()[0] == before[0] and undo.state() == history_before
          and bpy.data.images["Painted"].is_dirty
          and not [p for p in os.listdir(tempfile.gettempdir()) if p.startswith("blender-local-self-test-")],
          undo.state())
    print("\nSelf-Test check (painted pixels): %d failed" % fail)
    sys.exit(1 if fail else 0)
results = [l for l in lines if l.startswith(("PASS  ", "FAIL  "))]
check("the report starts with its title, and its header names the device, the system, RAM, the app, Blender and "
      "the total time", lines[0] == "Blender Local Self-Test"
      and all(any(l.startswith(k) for l in lines[:16]) for k in ("Device:", "RAM:", "App:", "Blender:", "Total:"))
      and not any("did not finish" in l for l in lines[:16]), lines[:16])
expected = len([c for c in selftest.CHECKS if not OPTS.get("only") or c[1] in OPTS["only"].split(",")]) + 1
check("one line per check and one for the scene put back (%d), each with PASS or FAIL, a time and a detail"
      % expected, len(results) == expected and all(" s  " in l and " — " in l for l in results), len(results))
check("and the summary line last", lines[-1].startswith("Summary:  ") and "%d of %d passed" % (
    len([l for l in results if l.startswith("PASS")]), len(results)) in lines[-1], lines[-1])
failed = [l for l in results if l.startswith("FAIL")]
check("every check passes", not failed, "\n        ".join(failed))
check("the last line says the user's scene came back as it was",
      results and results[-1].startswith("PASS") and "Your scene, opened again" in results[-1], results[-1:])

after = selftest.fingerprint()
gone = [r for r in before[0] if r not in after[0]]
new = [r for r in after[0] if r not in before[0]]
check("what Blender holds is what it held before the test (%d rows: every object, mesh, curve, collection, "
      "scene, selection and mode)" % len(before[0]), not gone and not new, (gone[:3], new[:3]))
check("the active object is back in %s" % mode_before, bpy.context.object is not None
      and bpy.context.object.mode == mode_before, getattr(bpy.context.object, 'mode', None))
check("the gate is on and the budget at 2,500,000", gate._busy == 0 and budget.BUDGET == 2_500_000,
      (gate._busy, budget.BUDGET))
leftover = [p for p in os.listdir(tempfile.gettempdir()) if p.startswith("blender-local-self-test-")]
check("no saved copy of the scene is left in the temporary folder", not leftover, leftover)

# The history: Undo reaches the user's scene and never a check's.
state = undo.state()
check("the history's top step is the Self-Test's, and Undo is offered (%s)" % state.get('undo_label'),
      state['undo'] and state['undo_label'] == "Self-Test", state)
reached = []
for _ in range(40):
    if not undo.state()['undo']:
        break
    undo.step(-1)
    reached.append(({o.name for o in bpy.data.objects}, selftest.fingerprint()[0]))
check("Undo reaches %d step(s), each holding the user's objects and no check's" % len(reached),
      reached and all(names <= names_before for names, _ in reached), [sorted(n) for n, _ in reached])
check("the first step back is the scene as it was before the test", reached and reached[0][1] == before[0],
      [r for r in reached[0][1] if r not in before[0]][:3] if reached else None)
for _ in range(len(reached)):
    undo.step(1)
again = selftest.fingerprint()[0]
check("and Redo comes back to it", again == before[0], [r for r in again if r not in before[0]][:3])
files = [p for p in os.listdir(HISTORY) if p.endswith(".blend")]
print("  (%d checkpoint files in the history's folder; %d steps)" % (len(files), undo.state()['steps']))
print("\nSelf-Test check: %.1f s for the run, %d failed" % (took, fail))
sys.exit(1 if fail else 0)
