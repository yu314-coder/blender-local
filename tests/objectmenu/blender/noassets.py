"""Shade Auto Smooth where the device runs it: a Blender without its
Essentials asset library.

The bpy staged into the app has colormanagement, fonts, icons and locale in
its datafiles and no `assets`. scripts/run-objectmenu-blender-check.sh runs
this in an APFS clone of desktop Blender 5.2.1 with `datafiles/assets`
removed, so what is checked here is what the device can do, not what the
desktop can. Every string run is the one the Swift sends (main.swift's dump).
"""
import bpy, sys, pathlib, importlib.util, contextlib, io

sys.dont_write_bytecode = True
CALLS = sys.argv[sys.argv.index("--") + 1]
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

spec = importlib.util.spec_from_file_location(
    "_blenderkit_context", ROOT / "Resources/python/site/_blenderkit_context.py")
context = importlib.util.module_from_spec(spec)
sys.modules["_blenderkit_context"] = context
spec.loader.exec_module(context)


def run(block):
    """What the block printed, and the error it raised or None."""
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            exec(compile(blocks[block], "<" + block + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return out.getvalue().strip(), str(error).strip()
    return out.getvalue().strip(), None


print("Blender without its Essentials asset library, as on the device")
check("(this Blender has no datafiles/assets)",
      bpy.utils.system_resource('DATAFILES', path='assets') == "",
      bpy.utils.system_resource('DATAFILES', path='assets'))
said, error = run("ESSENTIALS_PROBE")
check("the 3D View's question answers False, so the Auto Smooth row is greyed out", said == "False",
      (said, error))

bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
_, error = run("AUTO_SMOOTH")
check("Auto Smooth, run anyway (a script, an older menu), names the library and what to use instead",
      error is not None and "Essentials asset library" in error and "Shade Smooth by Angle" in error, error)
check("and leaves nothing half done: no modifier, no face smoothed",
      len(sphere.modifiers) == 0 and not any(p.use_smooth for p in sphere.data.polygons),
      (len(sphere.modifiers), sum(p.use_smooth for p in sphere.data.polygons)))
_, error = run("SMOOTH_BY_ANGLE")
check("Shade Smooth by Angle, which needs no library, still runs", error is None, error)
check("and smooths every face", all(p.use_smooth for p in sphere.data.polygons))

# More ▸ All Blender Tools runs it by name through run_operator, which used to
# pass Blender's 'No asset found at path ""' on bare (round 2's review).
import types
sys.modules.setdefault("_blenderkit", types.ModuleType("_blenderkit"))
spec = importlib.util.spec_from_file_location("_blenderkit_sync", ROOT / "Resources/python/site/_blenderkit_sync.py")
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
try:
    ui.run_operator("object.shade_auto_smooth", {})
    error = None
except RuntimeError as e:
    error = str(e)
check("the operator search's Auto Smooth names the library and what to use instead",
      error is not None and "Essentials asset library" in error and "Shade Smooth by Angle" in error, error)
check("and adds no modifier", len(sphere.modifiers) == 0, len(sphere.modifiers))

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
