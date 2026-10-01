"""The Render panel's own Python, run by Blender 5.2.1 in background mode.

    blender -b --factory-startup --python verify.py -- <calls.txt> <work dir>

What it holds the app to:
  * a render through the scene's camera writes the file, at the size and with
    the samples asked for;
  * a render "from the 3D View" frames what the 3D View frames — Blender is
    asked where the same world points land in the picture, and must agree with
    the app's own projection;
  * that render leaves nothing behind: no camera object, no camera data, and
    the scene's own camera back where it was, even when the render raises;
  * the camera menu items and the light and camera property writes reach the
    data-block Blender keeps them on.
"""
import bpy, os, sys
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
CALLS, WORK = args[0], args[1]
blocks = {}
for chunk in open(CALLS).read().split("\n#--\n"):
    name, _, body = chunk.partition("\n")
    blocks[name.removeprefix("### ").strip()] = body

failures = []
def check(label, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else f"  {detail}"))
    if not ok:
        failures.append(label)

DEVICE_FILE = os.path.join(WORK, "device.txt")

def run(name, out=None):
    body = blocks[name]
    if out is not None:
        body = body.replace("@OUT@", out)
    body = body.replace("@DEVICE@", DEVICE_FILE)
    exec(compile(body, f"<{name}>", "exec"), {"bpy": bpy})

def numbers(name):
    return [float(v) for v in blocks[name].split()]


# A scene with one of everything, as the app's own scenes have.
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
bpy.ops.object.camera_add(location=(6, -5, 4), rotation=(1.1, 0, 0.85))
camera = bpy.context.object
camera.name = "Camera"
bpy.context.scene.camera = camera
bpy.ops.object.light_add(type='POINT', location=(4, 1, 6))
bpy.context.object.name = "Light"

print("\n  through the scene's camera")
out = os.path.join(WORK, "camera.png")
run("RENDER_CAMERA", out)
check("it writes the image", os.path.exists(out) and os.path.getsize(out) > 0)
scene = bpy.context.scene
check("at the size asked for", (scene.render.resolution_x, scene.render.resolution_y) == (320, 180),
      (scene.render.resolution_x, scene.render.resolution_y))
check("with the engine asked for", scene.render.engine == 'BLENDER_WORKBENCH', scene.render.engine)
check("the scene's camera is still the scene's camera", scene.camera is camera)

run("RENDER_CYCLES", os.path.join(WORK, "cycles.png"))
check("Cycles gets its samples, not Blender's 4096 default",
      scene.cycles.samples == 1024, scene.cycles.samples)
check("and adaptive sampling, so an easy image stops early", scene.cycles.use_adaptive_sampling)
check("Eevee's samples are set too, whichever engine ran", scene.eevee.taa_render_samples == 256,
      scene.eevee.taa_render_samples)

# The device. Blender leaves compute_device_type at NONE, which renders on the
# CPU; this is the check that the app turns Metal on. A machine with no Metal
# (a CI box, an Intel Mac) has to fall back rather than fail, so both are
# accepted — but the Metal one has to be chosen where Metal exists.
prefs = bpy.context.preferences.addons['cycles'].preferences
metal = [d for d in prefs.devices if d.type == 'METAL']
reported = open(DEVICE_FILE).read() if os.path.exists(DEVICE_FILE) else ""
check("the device is reported back to the panel", reported.startswith("Cycles on"), reported)
if metal:
    check("Cycles is set to Metal and the GPU", prefs.compute_device_type == 'METAL'
          and scene.cycles.device == 'GPU' and all(d.use for d in metal),
          (prefs.compute_device_type, scene.cycles.device, [(d.name, d.use) for d in prefs.devices]))
    check("and the panel is told which GPU", "CPU" not in reported, reported)
else:
    check("with no Metal device it falls back to the CPU", scene.cycles.device == 'CPU', reported)

print("\n  from the 3D View")
before_objects = set(bpy.data.objects.keys())
before_cameras = set(bpy.data.cameras.keys())
# The lines that make the camera, without the render and the cleanup, so the
# framing can be measured; then the whole thing, for the cleanup.
#
# `matrix_world` is whatever the depsgraph last evaluated, not what `location`
# was just set to, so the view layer is updated before anything is measured —
# a render does this itself, which is why the pictures are right either way.
setup = blocks["RENDER_VIEW"].split("\ntry:")[0]
namespace = {"bpy": bpy}
exec(compile(setup.replace("@OUT@", os.path.join(WORK, "view.png")), "<setup>", "exec"), namespace)
bpy.context.view_layer.update()
view_camera = scene.camera
check("the render goes through a camera of its own", view_camera is not camera, view_camera)
check("it is fitted to the view's vertical angle", view_camera.data.sensor_fit == 'VERTICAL')

points = numbers("POINTS")
expected = numbers("PROJECTED")
worst = 0.0
for i in range(0, len(points), 3):
    got = world_to_camera_view(scene, view_camera, Vector(points[i:i + 3]))
    want = expected[(i // 3) * 2:(i // 3) * 2 + 2]
    worst = max(worst, abs(got.x - want[0]), abs(got.y - want[1]))
check("the picture frames what the 3D View frames, to a pixel", worst < 1.0 / 320,
      f"worst {worst:.5f} of the frame")

# Back to where the render script expects to start.
scene.camera = namespace["_was"]
bpy.data.objects.remove(view_camera)
bpy.data.cameras.remove(namespace["_data"])

out = os.path.join(WORK, "view.png")
run("RENDER_VIEW", out)
check("it writes the image", os.path.exists(out) and os.path.getsize(out) > 0)
check("the scene's own camera is back", scene.camera is camera, scene.camera)
check("the temporary camera object is gone", set(bpy.data.objects.keys()) == before_objects,
      set(bpy.data.objects.keys()) ^ before_objects)
check("its data-block too", set(bpy.data.cameras.keys()) == before_cameras,
      set(bpy.data.cameras.keys()) ^ before_cameras)

# A render that raises must clean up too: a path nothing can be written to.
raised = False
try:
    run("RENDER_VIEW", "/dev/null/nope/render.png")
except Exception:
    raised = True
check("a render that fails still puts everything back", raised
      and scene.camera is camera
      and set(bpy.data.objects.keys()) == before_objects
      and set(bpy.data.cameras.keys()) == before_cameras,
      (raised, scene.camera, set(bpy.data.objects.keys()) ^ before_objects))

print("\n  no camera at all")
scene.camera = None
try:
    run("RENDER_CAMERA", os.path.join(WORK, "none.png"))
    check("it says so in a sentence", False, "no error raised")
except RuntimeError as error:
    check("it says so in a sentence", "no camera" in str(error).lower(), str(error))
except Exception as error:
    check("it says so in a sentence", False, f"{type(error).__name__}: {error}")
scene.camera = camera

print("\n  the camera menu items")
scene.camera = None
run("SET_SCENE_CAMERA")
check("Set Scene Camera sets it", scene.camera is camera)
run("AIM_CAMERA")
location = numbers("VIEW_LOCATION")
rotation = numbers("VIEW_ROTATION")
check("Aim Camera at This View moves it to the view",
      all(abs(a - b) < 1e-3 for a, b in zip(camera.location, location)), tuple(camera.location))
check("and turns it the way the view looks",
      all(abs(a - b) < 1e-3 for a, b in zip(camera.rotation_euler, rotation)), tuple(camera.rotation_euler))
# Aiming and then rendering from the view must land in the same place.
bpy.context.view_layer.update()
namespace = {"bpy": bpy}
exec(compile(blocks["RENDER_VIEW"].split("\ntry:")[0].replace("@OUT@", os.path.join(WORK, "x.png")),
             "<setup>", "exec"), namespace)
bpy.context.view_layer.update()
aimed = scene.camera
check("so aiming the camera and rendering the view agree",
      all(abs(a - b) < 1e-3 for a, b in zip(aimed.matrix_world.translation, camera.matrix_world.translation))
      and all(abs(a - b) < 1e-3 for a, b in
              zip(aimed.matrix_world.to_euler(), camera.matrix_world.to_euler())),
      (tuple(aimed.matrix_world.translation), tuple(camera.matrix_world.translation)))
scene.camera = namespace["_was"]
bpy.data.objects.remove(aimed)
bpy.data.cameras.remove(namespace["_data"])
scene.camera = camera

print("\n  light and camera properties")
light = bpy.data.objects["Light"]
run("LIGHT_ENERGY"); check("a light's power", light.data.energy == 250, light.data.energy)
run("LIGHT_COLOUR")
check("its colour", all(abs(a - b) < 1e-4 for a, b in zip(light.data.color, (1, 0.5, 0.25))),
      tuple(light.data.color))
run("LIGHT_RADIUS")
check("its radius", abs(light.data.shadow_soft_size - 0.35) < 1e-4, light.data.shadow_soft_size)
run("LIGHT_TYPE"); check("its type", light.data.type == 'SUN', light.data.type)
run("CAMERA_LENS"); check("a camera's focal length", camera.data.lens == 35, camera.data.lens)
run("CAMERA_CLIP_START"); run("CAMERA_CLIP_END")
check("its clipping range", (camera.data.clip_start, camera.data.clip_end) == (0.25, 250),
      (camera.data.clip_start, camera.data.clip_end))
run("CAMERA_TYPE"); run("CAMERA_ORTHO_SCALE")
check("and its projection", camera.data.type == 'ORTHO' and camera.data.ortho_scale == 9,
      (camera.data.type, camera.data.ortho_scale))

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("ALL PASS")
