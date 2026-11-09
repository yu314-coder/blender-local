"""Grease Pencil, run by a headless Blender the way the app runs it.

scripts/run-gpencil-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup` and a home of its own. Every string run here is the
one the Swift sends, printed by tests/gpencil/blender/main.swift; the modules
are the ones the app ships from Resources/python/site, with `_blenderkit` (the
app's C module) a stand-in that keeps what it is handed.

What is checked:
  * Add ▸ Grease Pencil's Blank, Stroke and Monkey, and the names of its menu;
  * Draw Mode in and out, its undo step's name, Blender's defaults read back;
  * strokes made by the app from samples through its own camera land on the
    active layer at the current frame with the positions, radii, opacities and
    material the app made — on Blender's own drawing plane, where Blender's own
    3D View, aimed as the app's camera, draws them back at the samples;
  * the keyframe rule: Auto Keying and Additive Drawing as Blender's;
  * onion skins and the timeline's Grease Pencil keys;
  * the mirror's record and buffers, and what 20,000 points cost;
  * undo of a stroke, the Eraser's three modes, the Layers panel's rows, a new
    material, the refusals, and every name the app shows against Blender's.
"""
import bpy, sys, os, json, math, time, types, importlib.util, pathlib, io, contextlib
from array import array
from mathutils import Vector, Matrix

sys.dont_write_bytecode = True
CALLS = sys.argv[sys.argv.index("--") + 1:][0]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


# The app's C module, keeping what the mirror hands it.
sent = {'gpencil': [], 'keys': None}
stub = types.ModuleType('_blenderkit')
stub.sync_gpencil = lambda name, record, blob: sent['gpencil'].append((name, record, blob))
stub.anim_keys = lambda names, counts, frames, flags, scene_frames, scene_flags: sent.__setitem__(
    'keys', (names, counts, frames, flags))
sys.modules['_blenderkit'] = stub
for module in ("_blenderkit_context", "_blenderkit_knife", "_blenderkit_undo", "_blenderkit_multires",
               "_blenderkit_sculpt", "_blenderkit_anim", "_blenderkit_gpencil"):
    spec = importlib.util.spec_from_file_location(module, SITE / (module + ".py"))
    sys.modules[module] = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sys.modules[module])
sys.modules["_blenderkit_context"].install(bpy)
gp = sys.modules["_blenderkit_gpencil"]
sculpt = sys.modules["_blenderkit_sculpt"]
knife = sys.modules["_blenderkit_knife"]
anim = sys.modules["_blenderkit_anim"]

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head.strip()] = body


def run(name):
    exec(compile(blocks[name], name, "exec"), {"bpy": bpy, "__name__": "__main__"})


def raises(name):
    try:
        run(name)
    except Exception as error:                      # noqa: BLE001 - the words are what is checked
        return str(error)
    return None


def expect(name):
    return json.loads(blocks[name + "_EXPECT"])


def fresh(kind='EMPTY', name='GPencil'):
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    scene = bpy.context.scene
    scene.frame_set(1)
    scene.tool_settings.use_keyframe_insert_auto = False
    scene.tool_settings.use_gpencil_draw_additive = False
    bpy.ops.object.grease_pencil_add(type=kind)
    obj = bpy.context.active_object
    obj.name = name
    return obj


def strokes(obj, layer=None):
    layer = layer or obj.data.layers.active
    frame = layer.current_frame()
    return frame.drawing.strokes if frame is not None else []


def last_points(obj):
    s = strokes(obj)[-1]
    return ([tuple(p.position) for p in s.points], [p.radius for p in s.points],
            [p.opacity for p in s.points], s.material_index)


def undo_names():
    rows = sys.modules["_blenderkit_undo"].blender_steps() or []
    return [r[2] for r in rows]


bpy.ops.ed.undo_push(message="start")
window, area, region = knife.view3d("Drawing")
space = area.spaces.active
rv3d = space.region_3d


def aim(camera_literal, view):
    camera = eval(camera_literal)
    with bpy.context.temp_override(window=window, area=area, region=region):
        return sculpt.aim(space, rv3d, region, camera, view)


from bpy_extras import view3d_utils

# --------------------------------------------------------------------------
print("1. Add ▸ Grease Pencil")
for kind, layers, points in (('EMPTY', ['Layer'], 0), ('STROKE', ['Color', 'Lines'], 175),
                             ('MONKEY', ['Fills', 'Lines'], 1216)):
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    run("ADD_" + kind)
    obj = bpy.context.active_object
    got = sum(len(s.points) for l in obj.data.layers for f in l.frames for s in f.drawing.strokes)
    check(f"{kind}: a GREASEPENCIL object, layers {layers}, {points} points, Show In Front",
          obj.type == 'GREASEPENCIL' and [l.name for l in obj.data.layers] == layers and got == points
          and obj.show_in_front, f"{obj.type} {[l.name for l in obj.data.layers]} {got}")
import bl_ui.space_view3d as sv
import inspect
menu = inspect.getsource(sv.VIEW3D_MT_grease_pencil_add.draw)
names = json.loads(blocks["ONION_NAMES"])
for value, label in names["add"]:
    check(f"the menu's row for {value} is {label!r}", f'text="{label}"' in menu and f"'{value}'" in menu)
check("the submenu is 'Grease Pencil'", sv.VIEW3D_MT_grease_pencil_add.bl_label == "Grease Pencil")
check("the operator's name, the undo step's: 'Add Grease Pencil'",
      bpy.ops.object.grease_pencil_add.get_rna_type().name == "Add Grease Pencil")

# --------------------------------------------------------------------------
print("\n2. Draw Mode")
obj = fresh()
for o in list(bpy.data.objects):
    if o != obj:
        bpy.data.objects.remove(o)
run("ENTER")
check("Draw Mode entered", obj.mode == 'PAINT_GREASE_PENCIL', obj.mode)
modes = {i.identifier: i.name for i in bpy.ops.object.mode_set.get_rna_type().properties['mode'].enum_items}
check("its name is Blender's: " + names["mode"], modes['PAINT_GREASE_PENCIL'] == names["mode"])
printed = io.StringIO()
with contextlib.redirect_stdout(printed):
    run("STATE")
state = json.loads(printed.getvalue().strip().splitlines()[-1])
check("factory settings read back: Origin, View, the Pencil, Scene unit 0.06, Strength 1, pressure on",
      state['placement'] == 'ORIGIN' and state['plane'] == 'VIEW' and state['brush']['name'] == 'Pencil'
      and state['brush']['unit'] == 'SCENE' and abs(state['brush']['unprojected_size'] - 0.06) < 1e-6
      and state['brush']['strength'] == 1.0 and state['brush']['use_pressure_size'], state)
run("LEAVE")
check("and left", obj.mode == 'OBJECT')
bpy.ops.object.mode_set('EXEC_DEFAULT', True, mode='PAINT_GREASE_PENCIL')
bpy.ops.object.mode_set('EXEC_DEFAULT', True, mode='OBJECT')
labels = json.loads(blocks["LAYER_UNDO_NAMES"])
check("Blender's step for the mode, both ways: " + labels["mode"],
      undo_names()[-2:] == [labels["mode"]] * 2, undo_names()[-3:])
run("ENTER")
refusal = None
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.empty_add()
try:
    run("ENTER")
except RuntimeError as error:
    refusal = str(error)
check("Draw Mode for an empty: refused in words", refusal == "Draw Mode is for a Grease Pencil object", refusal)
bpy.data.objects.remove(bpy.context.active_object)

# --------------------------------------------------------------------------
print("\n3. a stroke, as the app makes it")
obj = fresh()
bpy.context.view_layer.objects.active = obj
run("ENTER")
e = expect("STROKE_LINE")
mapped = aim(e["camera"], tuple(e["view"]))
before = len(strokes(obj))
started = time.perf_counter()
run("STROKE_LINE")
ms = (time.perf_counter() - started) * 1000
positions, radii, opacities, material = last_points(obj)
check("one stroke more, on the active layer at frame 1", len(strokes(obj)) == before + 1
      and obj.data.layers.active.current_frame().frame_number == 1)
check(f"its {len(positions)} points are the app's, to 1e-5",
      len(positions) == len(e["positions"]) and all((Vector(a) - Vector(b)).length < 1e-5
                                                    for a, b in zip(positions, e["positions"])))
check("radius Unprojected Size / 2 x pressure, opacity Strength x pressure, as the app made them",
      all(abs(a - b) < 1e-6 for a, b in zip(radii, e["radii"]))
      and all(abs(a - b) < 1e-6 for a, b in zip(opacities, e["opacities"]))
      and abs(radii[0] - 0.03 * 0.5) < 1e-4, (radii[:3], opacities[:3]))
check("the active material slot", material == obj.active_material_index)
check("a poly line, as the Pencil's Curve Type makes it (not the Catmull-Rom a Blank's drawing defaults to)",
      strokes(obj)[-1].curve_type in ('POLY', 1), strokes(obj)[-1].curve_type)
worst = 0.0
plane_worst = 0.0
for world, screen in zip(e["world"], e["screen"]):
    drawn = view3d_utils.location_3d_to_region_2d(region, rv3d, Vector(world))
    want = sculpt.to_region(screen, mapped)
    worst = max(worst, (Vector(drawn) - Vector(want)).length)
    # Blender's own View plane through the origin under that pixel.
    on_plane = view3d_utils.region_2d_to_location_3d(region, rv3d, Vector(want), Vector((0, 0, 0)))
    plane_worst = max(plane_worst, (on_plane - Vector(world)).length)
check(f"Blender's 3D View, aimed as the app's camera, draws them where they were drawn (worst {worst:.4f} px)",
      worst < 0.02)
check(f"and they lie on Blender's View drawing plane through the origin (worst {plane_worst:.2e})",
      plane_worst < 1e-4)
check(f"written in one call, {ms:.1f} ms", ms < 200)

e = expect("STROKE_PIXELS")
obj.data.materials.append(bpy.data.materials["Black"])
mapped = aim(e["camera"], tuple(e["view"]))
run("STROKE_PIXELS")
positions, radii, opacities, material = last_points(obj)
worst = 0.0
for world, radius, screen in zip(e["world"], radii, e["screen"]):
    want = Vector(sculpt.to_region(screen, mapped))
    w = Vector(world)
    # Blender's pixel radius at the point's depth: 10 px across the view.
    beside = view3d_utils.region_2d_to_location_3d(region, rv3d, want + Vector((10, 0)), w)
    worst = max(worst, abs((beside - w).length - radius) / radius)
check(f"View unit, Size 20: each radius is 10 of Blender's pixels at its depth (worst {worst * 100:.3f} %)",
      worst < 2e-3)

turned = fresh(name="Turned")
turned.rotation_euler = (0, 0, 0.5)
turned.location = (1, 2, 0.5)
bpy.context.view_layer.update()
run("ENTER")
e = expect("STROKE_FRONT_PLANE")
mapped = aim(e["camera"], tuple(e["view"]))
run("STROKE_FRONT_PLANE")
positions, radii, _, _ = last_points(turned)
origin = turned.matrix_world.translation
normal = (turned.matrix_world.to_3x3() @ Vector((0, 1, 0))).normalized()
off = max(abs((Vector(w) - origin).dot(normal)) for w in e["world"])
local = max(((turned.matrix_world @ Vector(p)) - Vector(w)).length for p, w in zip(positions, e["world"]))
drawn = max((Vector(view3d_utils.location_3d_to_region_2d(region, rv3d, Vector(w)))
             - Vector(sculpt.to_region(s, mapped))).length for w, s in zip(e["world"], e["screen"]))
check(f"Front (X-Z) on a turned, moved object: on the object's XZ plane (worst {off:.2e} m)", off < 1e-4)
check(f"stored in the object's space (worst {local:.2e}), drawn where drawn (worst {drawn:.4f} px)",
      local < 1e-4 and drawn < 0.02)

obj = fresh()
run("ENTER")
run("STROKE_DOT")
check("a tap is a one-point stroke", len(strokes(obj)) == 1 and len(strokes(obj)[0].points) == 1)

# --------------------------------------------------------------------------
print("\n4. keyframes: Auto Keying and Additive Drawing (`ensure_active_keyframe`)")
obj = fresh()
run("ENTER")
run("STROKE_LINE")
scene = bpy.context.scene
scene.frame_set(5)
run("STROKE_LINE")
layer = obj.data.layers.active
check("Auto Keying off at frame 5: drawn onto the keyframe in effect (1), no new keyframe",
      [f.frame_number for f in layer.frames] == [1] and len(strokes(obj)) == 2)
run("AUTOKEY_ON")
run("STROKE_LINE")
check("Auto Keying on: a blank keyframe at 5, the stroke alone on it",
      [f.frame_number for f in layer.frames] == [1, 5] and len(strokes(obj)) == 1)
run("ADDITIVE_ON")
scene.frame_set(9)
run("STROKE_LINE")
check("Additive Drawing on: the keyframe at 9 starts as a copy of 5's, then the stroke",
      [f.frame_number for f in layer.frames] == [1, 5, 9] and len(strokes(obj)) == 2)
scene.frame_set(0)
scene.tool_settings.use_keyframe_insert_auto = False
run("STROKE_LINE")
check("before the first keyframe, even with Auto Keying off, a keyframe is made at the frame",
      [f.frame_number for f in layer.frames] == [0, 1, 5, 9])

print("\n5. onion skins and the timeline")
scene.frame_set(5)
got = gp.onion_frames(obj.data, layer, 5)
check("Keyframes (RELATIVE), 1 before and 1 after, at 5: the keyframes 1 and 9", got == [(1, -1), (9, 1)], got)
run("ONION_MODE")
run("ONION_BEFORE")
got = gp.onion_frames(obj.data, layer, 5)
check("Frames (ABSOLUTE), 4 before and 1 after, at 5: frames 1 to 4 before (0 is 5 away), none after",
      got == [(1, -4)], got)
check("during playback none", gp.onion_frames(obj.data, layer, 5, playing=True) == [])
layer.use_onion_skinning = False
check("a layer's Onion Skinning off: none", gp.onion_frames(obj.data, layer, 5) == [])
layer.use_onion_skinning = True
obj.data.onion_mode = 'RELATIVE'
obj.data.ghost_before_range = 1
anim.report_keys(scene)
names_sent, counts, frames, flags = sent['keys']
keyed = names_sent.decode().split('\0') if names_sent else []
index = keyed.index(obj.name) if obj.name in keyed else -1
columns = []
if index >= 0:
    count = array('I', counts)
    start = sum(count[:index])
    columns = list(array('f', frames)[start:start + count[index]])
check("the timeline's keys for the object are its keyframes 0, 1, 5, 9 (the layer a channel of its own, "
      "`register_channel_source`)", columns == [0, 1, 5, 9], columns)
channels = [c for c in anim.channels_of(obj.data) if isinstance(c, gp.LayerChannel)]
check("one channel for the layer, its frames and Keyframe types read",
      len(channels) == 1 and sorted(channels[0].frames()) == [0, 1, 5, 9]
      and all(f & ~1 == 0 for f in channels[0].flags()), [(c.frames(), c.flags()) for c in channels])
mask = [f == 5 for f in channels[0].frames()]
channels[0].select(mask)
check("the Timeline's selection reaches Blender's frames", [f.frame_number for f in layer.frames if f.select] == [5])
layer.frames[0].keyframe_type = 'BREAKDOWN'
check("a Breakdown's flag carries its type (2), as an F-Curve key's does",
      channels[0].flags()[0] >> 1 == 2, channels[0].flags())
layer.frames[0].keyframe_type = 'KEYFRAME'
for f in layer.frames:
    f.select = False

print("\n6. the mirror's record")
sent['gpencil'].clear()
depsgraph = bpy.context.evaluated_depsgraph_get()
gp.push(obj, depsgraph)
name, record, blob = sent['gpencil'][-1]
r = json.loads(record)
current = [b for b in r['blocks'] if b['onion'] == 0]
ghosts = [(b['onion'], b['frame']) for b in r['blocks'] if b['onion'] != 0]
check("the frame's drawing and the ghosts of 1 and 9", len(current) == 1 and ghosts == [(-1, 1), (1, 9)], ghosts)
size = sum(4 * (b['points'] * (5 + 4 * b['vcol']) + (b['strokes'] + 1) + 4 * b['strokes'] + 4 * b['strokes'] * b['fcol'])
           for b in r['blocks'])
check("the buffers are exactly what the blocks say", size == len(blob), (size, len(blob)))
check("the layer's keyframes and the one in effect travel with it",
      r['layers'][0]['frames'] == [[0, 'KEYFRAME', False], [1, 'KEYFRAME', False], [5, 'KEYFRAME', False],
                                   [9, 'KEYFRAME', False]] and r['layers'][0]['frame'] == 5, r['layers'][0])
check("a frame change pushes it again only when what it shows changed",
      gp.push_frame(scene, depsgraph) == 0)
scene.frame_set(6)
check("6 shows the same keyframe and ghosts as 5: not pushed", gp.push_frame(scene) == 0)
scene.frame_set(9)
check("9 does: pushed", gp.push_frame(scene) == 1)
monkey = fresh('MONKEY', name='Suzanne')
sent['gpencil'].clear()
gp.push(monkey, bpy.context.evaluated_depsgraph_get())
r = json.loads(sent['gpencil'][-1][1])
check("the Monkey: 1,216 points in 28 strokes over Fills and Lines",
      sum(b['points'] for b in r['blocks']) == 1216 and sum(b['strokes'] for b in r['blocks']) == 28)
# 20,000 points: what a pass costs.
big = monkey.data.layers['Lines'].current_frame().drawing
big.add_strokes([200] * 100)
positions = array('f', [0.0]) * (3 * len(big.attributes['position'].data))
big.attributes['position'].data.foreach_set('vector', positions)
times = []
for _ in range(5):
    sent['gpencil'].clear()
    t = time.perf_counter()
    gp.push(monkey, bpy.context.evaluated_depsgraph_get())
    times.append((time.perf_counter() - t) * 1000)
points = sum(json.loads(sent['gpencil'][-1][1])['blocks'][i]['points'] for i in range(2))
check(f"{points:,} points read and handed over in {sorted(times)[2]:.1f} ms (median of 5): under 25 ms",
      points == 21216 and sorted(times)[2] < 25, times)
bpy.ops.object.mode_set(mode='PAINT_GREASE_PENCIL')
code = blocks["STROKE_LINE"].replace("'GPencil'", "'Suzanne'").replace('"GPencil"', '"Suzanne"')
t = time.perf_counter()
exec(compile(code, "stroke", "exec"), {"bpy": bpy})
check(f"a stroke written into a 21,000-point drawing in {(time.perf_counter() - t) * 1000:.1f} ms: under 50 ms",
      (time.perf_counter() - t) * 1000 < 50)

# --------------------------------------------------------------------------
print("\n7. undo")
obj = fresh()
run("ENTER")
bpy.ops.ed.undo_push(message="Strokes Paint Mode Toggle")
run("STROKE_LINE")
bpy.ops.ed.undo_push(message=labels["stroke"])
check("drawn", len(strokes(obj)) == 1)
bpy.ops.ed.undo()
obj = bpy.data.objects['GPencil']
check("Undo takes the stroke back, in Draw Mode", len(strokes(obj)) == 0 and obj.mode == 'PAINT_GREASE_PENCIL')
bpy.ops.ed.redo()
obj = bpy.data.objects['GPencil']
check("Redo brings it again", len(strokes(obj)) == 1)
check("the step's name is the draw operator's: " + labels["stroke"],
      bpy.ops.grease_pencil.brush_stroke.get_rna_type().name == labels["stroke"])

# --------------------------------------------------------------------------
print("\n8. the Eraser")
cam = json.loads(blocks["ERASE_CAMERA"])


def vertical(obj):
    """A stroke from (0, 0, -1) to (0, 0, 1) through the middle of the Front
    view, which the eraser's swipe crosses."""
    d = obj.data.layers.active.current_frame().drawing
    d.add_strokes([21])
    s = d.strokes[-1]
    for i, p in enumerate(s.points):
        p.position = (0.0, 0.0, -1.0 + i * 0.1)
        p.radius = 0.02
        p.opacity = 1.0
    return d


for mode, check_fn, what in (
        ('HARD', lambda d: len(d.strokes) == 2 and sum(len(s.points) for s in d.strokes) < 21,
         "Point: the points under it go, the stroke split in two"),
        ('STROKE', lambda d: len(d.strokes) == 0, "Stroke: the whole stroke goes"),
        ('SOFT', lambda d: len(d.strokes) >= 1 and min(p.opacity for s in d.strokes for p in s.points) < 1.0,
         "Dissolve: what it passed over is fainter (or gone)")):
    obj = fresh()
    run("ENTER")
    d = vertical(obj)
    run("ERASE_" + mode)
    d = obj.data.layers.active.current_frame().drawing
    check(what, check_fn(d), [(len(s.points), [round(p.opacity, 2) for p in s.points][8:13]) for s in d.strokes])
obj = fresh()
run("ENTER")
d = obj.data.layers.active.current_frame().drawing
d.add_strokes([2])
for p, z in zip(d.strokes[-1].points, (-1.0, 1.0)):
    p.position = (0.0, 0.0, z)
    p.radius = 0.02
    p.opacity = 1.0
run("ERASE_STROKE")
check("Stroke: a two-point stroke crossing the path between its points goes too", len(strokes(obj)) == 0)
for mode, what in (('HARD', "Point"), ('SOFT', "Dissolve")):
    obj = fresh()
    run("ENTER")
    d = obj.data.layers.active.current_frame().drawing
    d.add_strokes([2])
    for p, z in zip(d.strokes[-1].points, (-1.0, 1.0)):
        p.position = (0.0, 0.0, z)
        p.radius = 0.02
        p.opacity = 1.0
    run("ERASE_" + mode)
    d = obj.data.layers.active.current_frame().drawing
    ends = [(round(s.points[0].position[2], 3), round(s.points[-1].position[2], 3)) for s in d.strokes]
    if mode == 'HARD':
        check(f"{what}: a two-point stroke is cut where the path crosses it, its ends kept",
              len(d.strokes) == 2 and ends[0][0] == -1.0 and ends[1][1] == 1.0, ends)
    else:
        faded = [p.opacity for s in d.strokes for p in s.points]
        check(f"{what}: points put where the path crosses, faded or gone there, the ends untouched",
              len(faded) > 2 and min(faded) < 1.0 and ends[0][0] == -1.0 and ends[-1][1] == 1.0, (ends, faded))
obj = fresh()
run("ENTER")
vertical(obj)
obj.data.layers.active.lock = True
run("ERASE_STROKE")
check("a locked layer is left alone", len(strokes(obj)) == 1)

# --------------------------------------------------------------------------
print("\n9. the Layers panel, materials, the brush")
obj = fresh()
for mode in ('OBJECT', 'PAINT_GREASE_PENCIL'):
    bpy.ops.object.mode_set(mode=mode)
    n = len(obj.data.layers)
    run("LAYER_ADD")
    check(f"+ adds a layer in {mode}, active", len(obj.data.layers) == n + 1
          and obj.data.layers.active == obj.data.layers[-1], [l.name for l in obj.data.layers])
order = [l.name for l in obj.data.layers]
run("LAYER_DOWN")
check("the arrow down moves the active layer down", [l.name for l in obj.data.layers] != order
      and [l.name for l in obj.data.layers][-2] == order[-1], [l.name for l in obj.data.layers])
run("LAYER_UP")
check("and up again", [l.name for l in obj.data.layers] == order)
run("LAYER_ACTIVE")
check("a row makes its layer active", obj.data.layers.active.name == "Layer")
run("LAYER_OPACITY")
run("LAYER_HIDE")
run("LAYER_LOCK")
layer = obj.data.layers["Layer"]
check("Opacity, Hide and Locked written", abs(layer.opacity - 0.25) < 1e-6 and layer.hide and layer.lock)
refusal = raises("STROKE_LINE")
check("drawing on a locked or hidden layer: Blender's words", refusal == "Active layer is locked or hidden", refusal)
run("LAYER_RENAME")
check("renamed", obj.data.layers.active.name == "Ink")
n = len(obj.data.layers)
run("LAYER_REMOVE")
check("− removes the active layer", len(obj.data.layers) == n - 1 and "Ink" not in [l.name for l in obj.data.layers])
for op, label in (("layer_add", labels["add"]), ("layer_remove", labels["remove"]),
                  ("layer_move", labels["move"]), ("layer_active", labels["active"])):
    check(f"{op}'s name, the undo step's: {label}", getattr(bpy.ops.grease_pencil, op).get_rna_type().name == label)
for key in ('hide', 'lock', 'opacity', 'use_onion_skinning'):
    check(f"the layer's {key} is called {labels[key]!r}",
          bpy.types.GreasePencilLayer.bl_rna.properties[key].name == labels[key])
slots = len(obj.material_slots)
run("MATERIAL_ADD")
material = obj.material_slots[obj.active_material_index].material
check("New Material: a slot more, active, the picked orange as Blender's linear colour",
      len(obj.material_slots) == slots + 1 and obj.active_material_index == slots
      and all(abs(a - b) < 1e-3 for a, b in zip(material.grease_pencil.color, (1.0, 0.2140, 0.0, 1.0))),
      tuple(material.grease_pencil.color))
check("material.new's name, the step's: " + labels["material"],
      bpy.ops.material.new.get_rna_type().name == labels["material"])
run("MATERIAL_ACTIVE")
check("a swatch makes its slot active", obj.active_material_index == 0)
check("the slot's step is " + labels["material_active"],
      bpy.types.Object.bl_rna.properties['active_material_index'].name == labels["material_active"])
run("MATERIAL_COLOUR")
check("Base Color written", abs(obj.material_slots[0].material.grease_pencil.color[2] - 1.0) < 1e-4)
bpy.ops.object.mode_set(mode='PAINT_GREASE_PENCIL')
run("BRUSH_SIZE")
check("the header's Size: Unprojected Size 0.1",
      abs(bpy.context.scene.tool_settings.gpencil_paint.brush.unprojected_size - 0.1) < 1e-6)
err = raises("BRUSH_INK")
check("an Essentials brush picked: Ink Pen", err is None
      and bpy.context.scene.tool_settings.gpencil_paint.brush.name == "Ink Pen", err)

# --------------------------------------------------------------------------
print("\n10. names")
props = bpy.types.GreasePencil.bl_rna.properties
check("Onion Skinning's Mode rows", [list(i) for i in names["modes"]]
      == [[i.identifier, i.name] for i in props['onion_mode'].enum_items])
check("Filter by Type's rows", [list(i) for i in names["filters"]]
      == [[i.identifier, i.name] for i in props['onion_keyframe_type'].enum_items])
eraser = bpy.types.BrushGpencilSettings.bl_rna.properties['eraser_mode']
check("the Eraser's Mode rows: Dissolve, Point, Stroke", [list(i) for i in names["eraser"]]
      == [[i.identifier, i.name] for i in eraser.enum_items])
import bl_ui.space_toolsystem_toolbar as tb
tools = [t.label for t in tb.VIEW3D_PT_tools_active._tools['PAINT_GREASE_PENCIL'] if t is not None and hasattr(t, 'label')]
check(f"the toolbar's Draw Mode tools include {names['tools']}", all(t in tools for t in names["tools"]), tools)

print("\nALL PASS" if fail == 0 else f"\n{fail} FAILED")
sys.exit(1 if fail else 0)
