"""Knife Project after the Render panel's render, in a Blender whose GPU module
nothing has started yet — the order a session meets it in.

Whichever thread starts Blender's GPU module keeps its context. The Render
panel renders on the script thread by default, so its first Eevee render used
to start the module there, and Knife Project, which aims Blender's view through
that module on the main thread, then refused for the rest of the session. The
session now starts the module on the main thread first (`ScriptThread.gpuStart`,
run by `BpySession.startGPUOnMainThread`), and this runs exactly that: the
start on the main thread, the panel's own render on a worker thread, then a cut.

Without the start, desktop Blender does not get as far as refusing: a worker
thread starting the GPU aborts the process (measured, exit 134), so that half
cannot be a check. It needs its own process for the same reason the cut does:
anything run before it could have started the module on the main thread.
"""
import bpy, sys, threading, tempfile, pathlib, importlib.util, collections

sys.dont_write_bytecode = True
CALLS = sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


blocks = collections.defaultdict(dict)
for b in open(CALLS).read().split("#--"):
    b = b.strip()
    if not b:
        continue
    head, body = b.split("\n", 1)
    name, part = head[4:].split()[0], head[4:].split()[-1]
    blocks[name][part] = body.strip()

for module in ("_blenderkit_context", "_blenderkit_knife"):
    spec = importlib.util.spec_from_file_location(
        module, ROOT / "Resources" / "python" / "site" / (module + ".py"))
    sys.modules[module] = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sys.modules[module])

print("\nKnife Project after a script-thread render, in a fresh Blender")
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, 0))
target = bpy.context.object
bpy.ops.mesh.primitive_circle_add(vertices=32, radius=0.5, location=(0.3, -0.2, 2.0))
bpy.context.object.name = "Cutter"
bpy.ops.object.select_all(action='DESELECT')
target.select_set(True)
bpy.context.view_layer.objects.active = target
scene = bpy.context.scene
scene.camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
scene.collection.objects.link(scene.camera)
scene.camera.location = (0, 0, 10)

import gpu
started = []
try:
    gpu.types.GPUFrameBuffer()
    started.append("before")
except Exception:
    pass
check("nothing has started the GPU module yet", not started, started)

exec(compile(blocks["knife.gpu"]["START"], "<gpu start>", "exec"), {"bpy": bpy})

output = str(pathlib.Path(tempfile.mkdtemp()) / "render.png")
render = blocks["knife.gpu"]["RENDER"].replace("@OUTPUT@", output)
errors = []


def script_thread():
    try:
        exec(compile(render, "<render>", "exec"), {"bpy": bpy})
    except Exception as e:                      # noqa: BLE001 - the failure is the finding
        errors.append(repr(e))


worker = threading.Thread(target=script_thread)
worker.start()
worker.join()
check("the Render panel's Eevee render runs on a worker thread", not errors, errors)
check("and writes its image", pathlib.Path(output).exists(), output)

body = blocks["knife.project"]["PERFORM"].replace("@SUBJECT@", target.name)
try:
    exec(compile(body, "<knife>", "exec"), {"bpy": bpy})
    cut = len(target.data.vertices)
except Exception as e:                          # noqa: BLE001
    cut = str(e)
check("then Knife Project cuts on the main thread", cut == 36, cut)

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
