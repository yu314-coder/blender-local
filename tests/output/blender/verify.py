"""Render Animation and the Render, Output and World tabs' Python, run by
Blender 5.2.1 in background mode, as the iPad runs it (no area, no window).

    blender -b --factory-startup --python verify.py -- <calls.txt> <work dir>

What it holds the app to:
  * Render Animation renders the scene's frame range through its camera with
    its engine — a video (an MPEG-4 while the Output is untouched, the scene's
    own container and codec once chosen) or numbered frames — and says what it
    wrote, frame by frame and at the end;
  * Cancel stops it after the frame in hand, the video closed and playable;
  * nothing is left changed: the frame, the engine, the size, the output path,
    the format and its colour, FFmpeg's settings, the range, the samples, the
    objects — and the scene is evaluated at its own frame after it;
  * a render that fails says so in words and leaves no stub video;
  * each tab's write lands where Blender keeps it, and the settings read back.
Videos are listed in <work>/videos.txt for the shell script to probe.
"""
import bpy, importlib.util, json, os, pathlib, sys

args = sys.argv[sys.argv.index("--") + 1:]
CALLS, WORK = args[0], args[1]
blocks = {}
for chunk in open(CALLS).read().split("\n#--\n"):
    name, _, body = chunk.partition("\n")
    blocks[name.removeprefix("### ").strip()] = body

# The app has its site folder on sys.path; here it also holds the simulator's
# `bpy` stand-in, so the module is loaded by path.
SITE = pathlib.Path(__file__).resolve().parents[3] / "Resources" / "python" / "site"
spec = importlib.util.spec_from_file_location("_blenderkit_render", SITE / "_blenderkit_render.py")
render_module = importlib.util.module_from_spec(spec)
sys.modules["_blenderkit_render"] = render_module
spec.loader.exec_module(render_module)

failures = []


def check(label, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else f"  {detail}"))
    if not ok:
        failures.append(label)


FRAMES = os.path.join(WORK, "frame.txt")
CANCEL = os.path.join(WORK, "cancel")
RESULT = os.path.join(WORK, "result.json")
PROGRESS = os.path.join(WORK, "progress.txt")
VIDEOS = os.path.join(WORK, "videos.txt")
open(VIDEOS, "w").close()


def run(name, base=None, out=None):
    for path in (FRAMES, CANCEL, RESULT, PROGRESS):
        if os.path.exists(path):
            os.remove(path)
    body = blocks[name]
    for key, value in (("@BASE@", base), ("@OUT@", out), ("@FRAMES@", FRAMES), ("@CANCEL@", CANCEL),
                       ("@RESULT@", RESULT), ("@PROGRESS@", PROGRESS)):
        if value is not None:
            body = body.replace(key, value)
    exec(compile(body, f"<{name}>", "exec"), {"bpy": bpy})


def result():
    return json.load(open(RESULT)) if os.path.exists(RESULT) else {}


def video(path, frames, codec):
    with open(VIDEOS, "a") as f:
        f.write(f"{path}\t{frames}\t{codec}\n")


def snapshot(scene):
    r = scene.render
    im, ff = r.image_settings, r.ffmpeg
    return {
        'engine': r.engine, 'size': (r.resolution_x, r.resolution_y, r.resolution_percentage),
        'filepath': r.filepath, 'use_file_extension': r.use_file_extension,
        'media_type': im.media_type, 'file_format': im.file_format, 'color_mode': im.color_mode,
        'color_depth': im.color_depth,
        'ffmpeg': (ff.format, ff.codec, ff.constant_rate_factor, ff.ffmpeg_preset),
        'range': (scene.frame_start, scene.frame_end, scene.frame_step), 'frame': scene.frame_current,
        'cycles': (scene.cycles.samples, scene.cycles.device, scene.cycles.use_adaptive_sampling),
        'eevee': (scene.eevee.taa_render_samples, scene.eevee.shadow_pool_size),
        'camera': scene.camera.name if scene.camera else None,
        'objects': len(bpy.data.objects), 'cameras': len(bpy.data.cameras), 'worlds': len(bpy.data.worlds),
        'scenes': len(bpy.data.scenes),
    }


def changed(a, b):
    return {k: (a[k], b[k]) for k in a if a[k] != b[k]}


scene = bpy.context.scene
cube = bpy.data.objects["Cube"]
# The cube moves along X from 0 at frame 1 to 4 at frame 3.
scene.frame_set(1)
cube.location.x = 0
cube.keyframe_insert("location", index=0)
scene.frame_set(3)
cube.location.x = 4
cube.keyframe_insert("location", index=0)
scene.frame_start, scene.frame_end, scene.frame_step = 1, 3, 1
scene.frame_set(2)
scene.render.engine = 'BLENDER_WORKBENCH'
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 64, 36, 100


def evaluated_x():
    dg = bpy.context.evaluated_depsgraph_get()
    return cube.evaluated_get(dg).matrix_world.translation.x


print("\n  Render Animation of an untouched Output: an MPEG-4 video, the app's default")
check("the factory Output reads as untouched", render_module.output_untouched(scene))
before = snapshot(scene)
base = os.path.join(WORK, "Animation A")
run("ANIM_VIDEO", base=base)
got = result()
check("it says it wrote a video of the 3 frames",
      got.get('kind') == 'video' and got.get('frames') == 3 and got.get('total') == 3 and not got.get('cancelled'),
      got)
check("an MP4 named after the request", os.path.realpath(got.get('path', '')) == os.path.realpath(base + ".mp4")
      and os.path.getsize(base + ".mp4") > 0, (repr(got.get('path')), repr(base + ".mp4")))
video(base + ".mp4", 3, "h264")
check("the frame in hand was written as it went, the last \"3 3 3\"",
      open(FRAMES).read().strip() == "3 3 3", open(FRAMES).read() if os.path.exists(FRAMES) else None)
check("and Blender's own progress", os.path.exists(PROGRESS))
after = snapshot(scene)
check("nothing in the scene is left changed (frame, engine, size, path, format, FFmpeg, range, samples)",
      after == before, changed(before, after))
check("still untouched, so the next Render Animation is a video too", render_module.output_untouched(scene))
check("the scene is evaluated at its own frame after it (x = 2 at frame 2)", abs(evaluated_x() - 2.0) < 1e-4,
      evaluated_x())

print("\n  the scene's own Output, once chosen")
run("FORMAT_PNG")
check("choosing PNG on an untouched Output makes it chosen (FFmpeg's container and codec set)",
      not render_module.output_untouched(scene) and scene.render.image_settings.file_format == 'PNG'
      and (scene.render.ffmpeg.format, scene.render.ffmpeg.codec) == ('MPEG4', 'H264'))
before = snapshot(scene)
base = os.path.join(WORK, "Animation B")
run("ANIM_SCENE", base=base)
got = result()
names = sorted(os.listdir(base)) if os.path.isdir(base) else []
check("PNG frames, Blender's numbered names, in a folder named after the request",
      got.get('kind') == 'images' and got.get('path') == base and names == ['0001.png', '0002.png', '0003.png'],
      (got, names))
check("the last frame written is reported", (got.get('last') or '').endswith('0003.png'), got.get('last'))
check("and nothing left changed", snapshot(scene) == before, changed(before, snapshot(scene)))

run("FORMAT_VIDEO")
run("SET_CONTAINER")
run("SET_CODEC")
before = snapshot(scene)
base = os.path.join(WORK, "Animation C")
run("ANIM_SCENE", base=base)
got = result()
check("a chosen QuickTime H.265 video is a .mov",
      os.path.realpath(got.get('path', '')) == os.path.realpath(base + ".mov") and got.get('frames') == 3
      and os.path.getsize(base + ".mov") > 0, (repr(got.get('path')), repr(base + ".mov")))
video(base + ".mov", 3, "hevc")
check("nothing left changed", snapshot(scene) == before, changed(before, snapshot(scene)))
run("FORMAT_PNG")

print("\n  Cancel")
scene.frame_end = 10
before = snapshot(scene)
pressed = []


def _press_cancel(render_scene, *_):
    # The user's Cancel, pressed while frame 2 renders: the file the panel
    # writes, there before the frame's render_post.
    if render_scene.frame_current == 2 and not pressed:
        pressed.append(2)
        open(CANCEL, "w").close()


bpy.app.handlers.render_pre.append(_press_cancel)
base = os.path.join(WORK, "Animation D")
try:
    run("ANIM_VIDEO", base=base)
finally:
    bpy.app.handlers.render_pre.remove(_press_cancel)
got = result()
check("it stops after the frame in hand: 2 of 10, said as cancelled",
      got.get('frames') == 2 and got.get('total') == 10 and got.get('cancelled') is True, got)
check("the video it closed holds those 2", os.path.getsize(base + ".mp4") > 0)
video(base + ".mp4", 2, "h264")
check("and the frame, the range and everything else are as they were",
      snapshot(scene) == before, changed(before, snapshot(scene)))
scene.frame_end = 3

print("\n  Frame Step")
scene.frame_end, scene.frame_step = 5, 2
base = os.path.join(WORK, "Animation E")
run("ANIM_VIDEO", base=base)
got = result()
check("frames 1 to 5 by 2 are 3 frames, the last frame 5 said as \"3 3 5\"",
      got.get('frames') == 3 and got.get('total') == 3 and open(FRAMES).read().strip() == "3 3 5",
      (got, open(FRAMES).read() if os.path.exists(FRAMES) else None))
video(base + ".mp4", 3, "h264")
scene.frame_end, scene.frame_step = 3, 1

print("\n  EEVEE")
scene.render.resolution_x, scene.render.resolution_y = 32, 18
scene.eevee.taa_render_samples = 2
scene.eevee.shadow_pool_size = '512'
before = snapshot(scene)
pools = []


def _pool(render_scene, *_):
    pools.append(render_scene.eevee.shadow_pool_size)


bpy.app.handlers.render_pre.append(_pool)
base = os.path.join(WORK, "Animation F")
try:
    run("ANIM_EEVEE", base=base)
finally:
    bpy.app.handlers.render_pre.remove(_pool)
got = result()
check("an EEVEE animation renders its 3 frames into a video", got.get('frames') == 3
      and os.path.getsize(base + ".mp4") > 0, got)
video(base + ".mp4", 3, "h264")
check("with the shadow pool held to 128 MB while it renders", pools and all(p == '128' for p in pools), pools)
check("and the scene's 512 back after, with nothing else changed", snapshot(scene) == before,
      changed(before, snapshot(scene)))
scene.render.resolution_x, scene.render.resolution_y = 64, 36

print("\n  Test All Features' three frames")
scene.frame_end = 10
scene.render.resolution_x, scene.render.resolution_y = 1920, 1080
before = snapshot(scene)
base = os.path.join(WORK, "Animation H")
run("ANIM_FEATURE", base=base)
got = result()
check("a range and size for the render only: 3 frames", got.get('frames') == 3 and got.get('total') == 3, got)
check("the scene's own range (1-10) and size (1920 x 1080) back after", snapshot(scene) == before,
      changed(before, snapshot(scene)))
video(base + ".mp4", 3, "h264")
scene.frame_end = 3
scene.render.resolution_x, scene.render.resolution_y = 64, 36

print("\n  a render that fails")
camera = scene.camera
scene.camera = None
before = snapshot(scene)
base = os.path.join(WORK, "Animation G")
try:
    run("ANIM_VIDEO", base=base)
    check("no camera is refused in words", False, "no error")
except RuntimeError as error:
    check("no camera is refused in words", "no camera" in str(error).lower(), str(error))
check("and leaves no file", not os.path.exists(base + ".mp4") and not os.path.exists(base))
check("and nothing changed", snapshot(scene) == before, changed(before, snapshot(scene)))
scene.camera = camera
# Past the panel's guard, Blender's own refusal: the module's stub cleanup.
scene.camera = None
try:
    render_module.render_animation(os.path.join(WORK, "Animation G2"), video=True, result=RESULT)
except RuntimeError:
    pass
check("called without the guard, the module refuses too and opens no video",
      not os.path.exists(os.path.join(WORK, "Animation G2.mp4")))
scene.camera = camera
# Blender's own refusal after it opened the video: the camera taken away as
# the first frame starts (`render_pre`), as the app measured with no camera
# at all — a 305-byte MP4 that nothing plays.
def _take_camera(render_scene, *_):
    render_scene.camera = None


bpy.app.handlers.render_pre.append(_take_camera)
stub = os.path.join(WORK, "Animation G3")
saved = render_module.save(scene)
raised = None
try:
    render_module.render_animation(stub, video=True, result=RESULT)
except Exception as error:                          # noqa: BLE001
    raised = str(error)
finally:
    bpy.app.handlers.render_pre.remove(_take_camera)
    render_module.restore(scene, saved)
    scene.camera = camera
check("Blender's own refusal after opening the video is raised in its words (%r)" % (raised or "")[:60],
      raised is not None and "camera" in raised.lower(), raised)
check("and leaves no stub video", not os.path.exists(stub + ".mp4"),
      os.path.getsize(stub + ".mp4") if os.path.exists(stub + ".mp4") else 0)
check("and its outcome says no frame, with the error", result().get('frames') == 0
      and "camera" in (result().get('error') or "").lower(), result())
print("\n  a still from a video Output")
run("FORMAT_VIDEO")
before = snapshot(scene)
out = os.path.join(WORK, "still.png")
run("STILL_SCENE", out=out)
check("is a PNG", os.path.exists(out) and open(out, "rb").read(4) == b"\x89PNG")
check("and the video Output is back after it", snapshot(scene) == before, changed(before, snapshot(scene)))
run("FORMAT_PNG")

print("\n  the settings the tabs read")
import io, contextlib
buffer = io.StringIO()
with contextlib.redirect_stdout(buffer):
    run("SETTINGS")
settings = json.loads(buffer.getvalue().strip().splitlines()[-1])
check("the three engines with Blender's names",
      settings['engines'] == [['BLENDER_EEVEE', 'EEVEE'], ['BLENDER_WORKBENCH', 'Workbench'], ['CYCLES', 'Cycles']],
      settings['engines'])
views = [v[0] for v in settings['color']['view_transforms']]
check("the view transforms the OpenColorIO config lists", {'AgX', 'Standard', 'Khronos PBR Neutral', 'Filmic'}
      <= set(views), views)
check("a look by the name its menu draws", ['AgX - Punchy', 'Punchy'] in settings['color']['looks'],
      settings['color']['looks'][:3])
check("the frame range, step and rate", (settings['frame_start'], settings['frame_end'], settings['frame_step'],
                                         settings['fps'], settings['fps_base']) == (1, 3, 1, 24, 1.0))
check("the World's Background", settings['world'] and settings['world']['background']
      and settings['world']['node'] == 'Background', settings['world'])
check("Blender has FFmpeg", settings['ffmpeg_available'])
check("the colours PNG offers", [c[0] for c in settings['color_modes']] == ['BW', 'RGB', 'RGBA'],
      settings['color_modes'])

print("\n  each write lands where Blender keeps it")
scene.cycles.device = 'CPU'
run("ENGINE_CYCLES")
check("Cycles, and its Device GPU Compute (the app's default)", scene.render.engine == 'CYCLES'
      and scene.cycles.device == 'GPU', (scene.render.engine, scene.cycles.device))
run("SET_DEVICE")
run("ENGINE_EEVEE")
check("EEVEE is only the engine: Cycles' Device stays as set", scene.render.engine == 'BLENDER_EEVEE'
      and scene.cycles.device == 'CPU', (scene.render.engine, scene.cycles.device))
run("RATE_2398")
check("23.98 is 24 over 1.001", (scene.render.fps, round(scene.render.fps_base, 6)) == (24, 1.001))
im, ff = scene.render.image_settings, scene.render.ffmpeg
# FFmpeg's settings as a scene starts with them (nothing chosen yet).
ff.format, ff.codec, ff.constant_rate_factor = 'MPEG1', 'NONE', 'NONE'
run("FORMAT_VIDEO")
check("FFmpeg Video: Media Type Video, MPEG-4, H.264, Medium Quality",
      (im.media_type, im.file_format, ff.format, ff.codec, ff.constant_rate_factor)
      == ('VIDEO', 'FFMPEG', 'MPEG4', 'H264', 'MEDIUM'),
      (im.media_type, im.file_format, ff.format, ff.codec, ff.constant_rate_factor))
run("FORMAT_PNG")
ff.format, ff.codec, ff.constant_rate_factor = 'MPEG1', 'NONE', 'NONE'
im.media_type = 'VIDEO'
check("(Blender's own switch to Video makes a Matroska)", ff.format == 'MKV', ff.format)
im.media_type = 'IMAGE'
run("FORMAT_VIDEO")
check("which the app's FFmpeg Video makes MPEG-4, a container the panel can play", ff.format == 'MPEG4', ff.format)
run("SET_CONTAINER")
run("FORMAT_PNG")
run("FORMAT_VIDEO")
check("and a QuickTime chosen before is kept", ff.format == 'QUICKTIME', ff.format)
run("FORMAT_JPEG")
check("JPEG", (im.media_type, im.file_format) == ('IMAGE', 'JPEG'))
run("FORMAT_EXR")
check("OpenEXR", im.file_format == 'OPEN_EXR')
run("FORMAT_PNG")
run("SET_COLOR_MODE")
check("Color BW", im.color_mode == 'BW')
run("SET_CRF")
check("Output Quality", ff.constant_rate_factor == 'HIGH')
run("QUALITY_DRAFT_EEVEE")
check("Draft in EEVEE is 8 Render samples", scene.eevee.taa_render_samples == 8)
run("QUALITY_BEST_CYCLES")
check("Best in Cycles is 1024", scene.cycles.samples == 1024)
run("SET_RES_X"); run("SET_PERCENT"); run("SET_STEP")
check("Resolution X, %, Step", (scene.render.resolution_x, scene.render.resolution_percentage, scene.frame_step)
      == (1280, 50, 2))
run("SET_FRAME_START")
check("Frame Start 5 moves End with it, as the Timeline's rule says (FrameRange.settingStart)",
      (scene.frame_start, scene.frame_end) == (5, 5), (scene.frame_start, scene.frame_end))
for name, read, want in (("SET_THRESHOLD", lambda: round(scene.cycles.adaptive_threshold, 4), 0.05),
                         ("SET_TIME_LIMIT", lambda: scene.cycles.time_limit, 2.5),
                         ("SET_DENOISE", lambda: scene.cycles.use_denoising, False),
                         ("SET_BOUNCES", lambda: scene.cycles.max_bounces, 4),
                         ("SET_TRANSPARENT", lambda: scene.render.film_transparent, True),
                         ("SET_RAYTRACING", lambda: scene.eevee.use_raytracing, True),
                         ("SET_SHADOW_RAYS", lambda: scene.eevee.shadow_ray_count, 3),
                         ("SET_MOTION_BLUR", lambda: scene.render.use_motion_blur, True),
                         ("SET_LIGHT", lambda: scene.display.shading.light, 'FLAT'),
                         ("SET_OBJECT_COLOR", lambda: scene.display.shading.color_type, 'SINGLE'),
                         ("SET_RENDER_AA", lambda: scene.display.render_aa, '16'),
                         ("SET_LOOK", lambda: scene.view_settings.look, 'AgX - Punchy'),
                         ("SET_EXPOSURE", lambda: round(scene.view_settings.exposure, 4), 0.5),
                         ("SET_GAMMA", lambda: round(scene.view_settings.gamma, 4), 1.2),
                         ("SET_VIEW", lambda: scene.view_settings.view_transform, 'Standard')):
    run(name)
    check(f"{name}: {want!r}", read() == want, read())

print("\n  World")
scene.world = None
run("WORLD_NEW")
world = scene.world
check("New makes a World and gives it to the scene", world is not None and world.users >= 1, world)
bg = world.node_tree.nodes.get("Background") if world else None
check("with a Background on the World Output's Surface",
      bg is not None and bg.outputs[0].is_linked
      and bg.outputs[0].links[0].to_node.bl_idname == 'ShaderNodeOutputWorld')
run("WORLD_COLOR")
check("Color is the Background's, scene-linear, and the viewport colour with it",
      tuple(round(c, 4) for c in bg.inputs['Color'].default_value[:3]) == (0.2, 0.4, 0.8)
      and tuple(round(c, 4) for c in world.color) == (0.2, 0.4, 0.8), tuple(bg.inputs['Color'].default_value))
run("WORLD_STRENGTH")
check("Strength", abs(bg.inputs['Strength'].default_value - 2.5) < 1e-6)
# A render shows it: EEVEE, the frame's corner is the World behind the cube.
scene.render.engine = 'BLENDER_EEVEE'
scene.render.film_transparent = False
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 32, 18, 100
scene.render.image_settings.color_mode = 'RGB'
scene.eevee.taa_render_samples = 1
corner_file = os.path.join(WORK, "world.png")
scene.render.filepath = corner_file
bpy.ops.render.render(write_still=True)
picture = bpy.data.images.load(corner_file)
corner = tuple(round(c, 3) for c in picture.pixels[:3])
check("an EEVEE render shows the World's colour behind the scene (corner %s, blue over red)" % (corner,),
      corner[2] > corner[0] + 0.2 and corner[1] > corner[0], corner)
bpy.data.images.remove(picture)
state = render_module.world_state(scene)
check("and they read back", state['background'] and state['strength'] == 2.5
      and [round(c, 4) for c in state['color']] == [0.2, 0.4, 0.8], state)
world.node_tree.nodes.remove(bg)
check("with nothing on the Surface it reads as no node", render_module.world_state(scene)['node'] is None)
run("WORLD_STRENGTH")
bg = next((n for n in world.node_tree.nodes if n.bl_idname == 'ShaderNodeBackground'), None)
check("and a Strength makes the Background again, linked", bg is not None and bg.outputs[0].is_linked
      and abs(bg.inputs['Strength'].default_value - 2.5) < 1e-6)
emission = world.node_tree.nodes.new('ShaderNodeEmission')
output = next(n for n in world.node_tree.nodes if n.bl_idname == 'ShaderNodeOutputWorld')
world.node_tree.links.new(emission.outputs[0], output.inputs['Surface'])
try:
    run("WORLD_COLOR")
    check("a Surface that is not a Background is refused in words", False, "no error")
except RuntimeError as error:
    check("a Surface that is not a Background is refused in words", "Background" in str(error), str(error))

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("ALL PASS")
