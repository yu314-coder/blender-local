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
import bpy, math, os, sys
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
check("Set Active Object as Camera sets it", scene.camera is camera)
run("AIM_CAMERA")
location = numbers("VIEW_LOCATION")
rotation = numbers("VIEW_ROTATION")
check("Align Active Camera to View moves it to the view",
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

# A parented camera, and one rotated by quaternion: Align Active Camera to
# View is about where the camera ends up in the world. Round 3's review
# measured the old lines (the view's world values written into the local
# channels) 10.2 m and 78.1 deg off on the first and 63 deg on the second;
# they are the negative control here.
from mathutils import Euler, Matrix
want = Matrix.Translation(location) @ Euler(rotation, 'XYZ').to_matrix().to_4x4()


def apart(obj):
    bpy.context.view_layer.update()
    got = obj.matrix_world
    turn = got.to_quaternion().rotation_difference(want.to_quaternion()).angle
    return (got.translation - want.translation).length, math.degrees(turn)


def old_lines(name):
    return ("bpy.data.objects[%r].location = (%.4f, %.4f, %.4f)\n"
            "bpy.data.objects[%r].rotation_euler = (%.4f, %.4f, %.4f)"
            % ((name,) + tuple(location) + (name,) + tuple(rotation)))


rig = bpy.data.objects.new("Rig", None)
scene.collection.objects.link(rig)
rig.location = (3.0, -2.0, 1.5)
rig.rotation_euler = (0.3, -0.5, 1.1)
rig.scale = (1.5, 1.5, 1.5)
bpy.context.view_layer.update()


def keep_inverse(o):
    # Parented as Ctrl+P's Object does: with the parent's inverse kept.
    o.parent = rig
    o.matrix_parent_inverse = rig.matrix_world.inverted()


for label, setup in (("parented to a moved, turned and scaled empty, as a script parents it",
                      lambda o: setattr(o, "parent", rig)),
                     ("rotated by quaternion", lambda o: setattr(o, "rotation_mode", 'QUATERNION')),
                     ("parented with the inverse kept, rotated by axis and angle",
                      lambda o: (keep_inverse(o), setattr(o, "rotation_mode", 'AXIS_ANGLE')))):
    for kind in ("old", "new"):
        data = bpy.data.cameras.new("Aim " + kind)
        aim = bpy.data.objects.new("Aim", data)
        scene.collection.objects.link(aim)
        setup(aim)
        aim.location = (0.4, 0.2, -0.3)
        source = blocks["AIM_CAMERA"].replace('"Camera"', '"%s"' % aim.name)
        exec(compile(old_lines(aim.name) if kind == "old" else source, "<aim>", "exec"), {"bpy": bpy})
        off, turned = apart(aim)
        if kind == "old":
            check("negative control, %s: the old lines leave it %.2f m and %.1f deg off the view"
                  % (label, off, turned), off > 0.1 or turned > 1, (off, turned))
        else:
            check("%s: it ends up where the view is (%.1g m, %.1g deg)" % (label, off, turned),
                  off < 1e-4 and turned < 1e-3, (off, turned))
        bpy.data.objects.remove(aim)
        bpy.data.cameras.remove(data)
bpy.data.objects.remove(rig)

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

print("\n  a script's first Cycles render on the GPU (_blenderkit_cycles)")
import importlib.util, pathlib, tempfile
SITE = pathlib.Path(__file__).resolve().parents[3] / "Resources" / "python" / "site"
spec = importlib.util.spec_from_file_location("_blenderkit_cycles", SITE / "_blenderkit_cycles.py")
cycles_module = importlib.util.module_from_spec(spec)
sys.modules["_blenderkit_cycles"] = cycles_module
spec.loader.exec_module(cycles_module)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 1
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 16, 16, 100
scene.render.filepath = os.path.join(WORK, "cycles.png")
prefs = bpy.context.preferences.addons['cycles'].preferences
scene.cycles.device = 'CPU'
check("Cycles on the CPU is not on the GPU", not cycles_module.renders_on_gpu(scene))
scene.cycles.device = 'GPU'
prefs.compute_device_type = 'NONE'
check("nor is Cycles set to GPU with no compute device chosen (Cycles renders on the CPU then)",
      not cycles_module.renders_on_gpu(scene))
prefs.compute_device_type = 'METAL'
prefs.refresh_devices()
for device in prefs.devices:
    device.use = device.type == 'METAL'
metal = [d.name for d in prefs.devices if d.type == 'METAL']
check("with a Metal device chosen and on, as the Render panel sets it up, it is (%s)" % ", ".join(metal),
      bool(metal) and cycles_module.renders_on_gpu(scene), metal)


import io, contextlib
events = []


class Recorder(io.TextIOBase):
    """sys.stdout while a render runs: what Python prints, in order with the
    render's own progress (`render_stats`, which Blender calls as it renders)."""
    def write(self, text):
        if text.strip():
            events.append(("print", text.strip()))
        return len(text)


def _bk_test_stats(*arguments):
    events.append(("render", str(arguments[0]) if arguments else ""))


def render_recording():
    del events[:]
    bpy.app.handlers.render_stats.append(_bk_test_stats)
    try:
        with contextlib.redirect_stdout(Recorder()):
            bpy.ops.render.render(write_still=True)
    finally:
        bpy.app.handlers.render_stats.remove(_bk_test_stats)
    return list(events)


# The renders here are on the CPU, which costs a second and compiles nothing;
# `renders_on_gpu` is made to answer as a GPU render would.
scene.cycles.device = 'CPU'
real = cycles_module.renders_on_gpu
cycles_module.renders_on_gpu = lambda s: s.render.engine == 'CYCLES'
warning = blocks["CYCLES_WARNING"].strip()
try:
    exec(blocks["CYCLES_ARM"], {"bpy": bpy})
    first = render_recording()
    second = render_recording()
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        exec(blocks["CYCLES_DISARM"], {"bpy": bpy})
    finished = buffer.getvalue().strip()
    third = render_recording()
finally:
    cycles_module.renders_on_gpu = real
said = [i for i, e in enumerate(first) if e == ("print", warning)]
rendered = [i for i, e in enumerate(first) if e[0] == "render"]
check("the Render panel's warning is printed before Blender's render starts (event %s, the render's "
      "first progress line event %s of %d)" % (said[:1], rendered[:1], len(first)),
      len(said) == 1 and rendered and said[0] < rendered[0], first[:4])
check("once: the second render says nothing", ("print", warning) not in second, second[:3])
check("and the finished render is read back as built (%r)" % finished, finished == "True", finished)
check("disarmed, a render says nothing", ("print", warning) not in third, third[:3])
scene.render.engine = 'BLENDER_WORKBENCH'

print("\n  Eevee's shadow pool, held to the quality for the render (Quality.eeveeShadowPool)")
seen = []
def _pool_at_render(render_scene, *_):
    seen.append(render_scene.eevee.shadow_pool_size)
bpy.app.handlers.render_pre.append(_pool_at_render)
try:
    scene.eevee.shadow_pool_size = '512'
    run("RENDER_EEVEE", os.path.join(WORK, "eevee.png"))
    check("Good renders with a 128 MB pool, where Blender's default is 512", seen[-1:] == ['128'], seen)
    check("and the scene's own 512 is back after", scene.eevee.shadow_pool_size == '512',
          scene.eevee.shadow_pool_size)
    check("the image is written", os.path.getsize(os.path.join(WORK, "eevee.png")) > 0)
    scene.eevee.shadow_pool_size = '32'
    run("RENDER_EEVEE", os.path.join(WORK, "eevee32.png"))
    check("a scene that asks for less keeps its own (32)", seen[-1:] == ['32']
          and scene.eevee.shadow_pool_size == '32', (seen, scene.eevee.shadow_pool_size))
    scene.eevee.shadow_pool_size = '1024'
    cameras = len(bpy.data.cameras)
    run("RENDER_EEVEE_BEST", os.path.join(WORK, "eevee-best.png"))
    check("Best from the 3D View renders with 256, puts 1024 back and leaves no camera",
          seen[-1:] == ['256'] and scene.eevee.shadow_pool_size == '1024'
          and len(bpy.data.cameras) == cameras,
          (seen, scene.eevee.shadow_pool_size, len(bpy.data.cameras), cameras))
finally:
    bpy.app.handlers.render_pre.remove(_pool_at_render)
    scene.eevee.shadow_pool_size = '512'
    scene.render.engine = 'BLENDER_WORKBENCH'

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("ALL PASS")
