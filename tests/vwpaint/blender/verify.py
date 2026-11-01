"""Weight Paint and Vertex Paint with Blender's own brushes, run by a headless
Blender the way the app runs them.

scripts/run-vwpaint-blender-check.sh starts Blender with `-b --factory-startup`
and a home of its own. Every string run is what the Swift sends, printed by
tests/vwpaint/blender/main.swift, and the modules are the ones the app ships
from Resources/python/site. The undo stack comes from the history's first
push, the GPU module and the 3D View from the modules themselves.

What is checked:
  * into both modes and out, each one history step named as Blender's own
    history names it ("Weight Paint Mode", "Vertex Paint Mode");
  * refusals: a light, a mesh with no faces, a hidden one, a locked group, a
    worker thread, another object, the script line with no 3D View — each a
    sentence, none a crash;
  * a stroke streamed in chunks is the same dabs as one of Blender's strokes
    exactly, where the dabs sent as separate strokes are not (the negative
    control); one history step named "Weight Paint" / "Vertex Paint", which
    Undo and Redo take back and forth exactly;
  * every Essentials brush of both modes strokes, with Undo and Redo;
  * the brush settings read back as written, where Blender reads them;
  * what the viewport is handed (`_blenderkit.sync_paint`), per vertex of
    the evaluated mesh, through a Subdivision too;
  * after a file load has freed Blender's undo stack, a stroke starts one.
"""
import bpy, sys, os, math, json, threading, importlib.util, pathlib, io, contextlib, types
from array import array
from mathutils import Vector

sys.dont_write_bytecode = True
CALLS, WORK = sys.argv[-2], sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
HISTORY = os.path.join(WORK, "Documents", ".blender-history")
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


# The app's C module, recording what the viewport is handed.
handed = []


class _App(types.ModuleType):
    def is_main_thread(self):
        return threading.current_thread() is threading.main_thread()

    def sync_paint(self, name, kind, data):
        handed.append((name, kind, bytes(data)))

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules['_blenderkit'] = _App('_blenderkit')
for module in ("_blenderkit_context", "_blenderkit_knife", "_blenderkit_undo", "_blenderkit_multires",
               "_blenderkit_sculpt", "_blenderkit_vwpaint"):
    spec = importlib.util.spec_from_file_location(module, SITE / (module + ".py"))
    sys.modules[module] = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sys.modules[module])
sys.modules["_blenderkit_context"].install(bpy)
paint = sys.modules["_blenderkit_vwpaint"]
sculpt = sys.modules["_blenderkit_sculpt"]
undo_module = sys.modules["_blenderkit_undo"]

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body
namespace = {"bpy": bpy}


def run(name, **fill):
    source = blocks[name]
    for key, value in fill.items():
        source = source.replace("@" + key.upper() + "@", str(value))
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        exec(compile(source, "<" + name + ">", "exec"), namespace)
    return printed.getvalue()


def answer(name, **fill):
    return json.loads([line for line in run(name, **fill).splitlines()
                       if line.startswith("{") or line.startswith("[")][-1])


def refused(name, **fill):
    try:
        run(name, **fill)
    except RuntimeError as error:
        return str(error)
    return None


def push(label):
    return answer("HISTORY_PUSH", root=HISTORY, label=label)


def undo():
    return answer("HISTORY_UNDO")


def redo():
    return answer("HISTORY_REDO")


def blender_step():
    rows = undo_module.blender_steps() or []
    active = next((row for row in rows if row[3]), None)
    return active[2] if active else None


# --------------------------------------------------------------------------
# The app's camera and points (ViewportCamera's maths, as the sculpt check)

FOV = 2 * math.atan(18.0 / 50.0)
VIEW = (1100.0, 800.0)
CAMERA = dict(target=(0.0, 0.0, 0.0), distance=5.5, azimuth=0.6, elevation=0.4, fov_y=FOV,
              ortho=False, near=0.05, far=1000.0)


def camera_literal(cam):
    n = lambda v: "%.9g" % v
    t = cam["target"]
    return ("dict(target=(%s, %s, %s), distance=%s, azimuth=%s, elevation=%s, fov_y=%s, "
            "ortho=%s, near=%s, far=%s)" % (n(t[0]), n(t[1]), n(t[2]), n(cam["distance"]),
                                            n(cam["azimuth"]), n(cam["elevation"]), n(cam["fov_y"]),
                                            "True" if cam["ortho"] else "False", n(cam["near"]),
                                            n(cam["far"])))


def app_project(cam, p, view=VIEW):
    w, h = view
    a, e = cam["azimuth"], cam["elevation"]
    right = Vector((math.cos(a), math.sin(a), 0))
    up = Vector((-math.sin(e) * math.sin(a), math.sin(e) * math.cos(a), math.cos(e)))
    back = Vector((math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e)))
    eye = Vector(cam["target"]) + back * cam["distance"]
    d = Vector(p) - eye
    f = (h / 2) / math.tan(cam["fov_y"] / 2)
    z = -d.dot(back)
    return (w / 2 + d.dot(right) / z * f, h / 2 - d.dot(up) / z * f)


def line(a, b, count):
    pa, pb = app_project(CAMERA, a), app_project(CAMERA, b)
    return [(pa[0] + (pb[0] - pa[0]) * i / (count - 1), pa[1] + (pb[1] - pa[1]) * i / (count - 1),
             1.0, i / 60.0) for i in range(count)]


def literal(pts):
    return ", ".join("(%.3f, %.3f, %.4f, %.4f)" % p for p in pts)


def stroke(name, pts, per_chunk=4):
    begin = answer("BEGIN", object=name, camera=camera_literal(CAMERA))
    chunks = [answer("CHUNK", points=literal(pts[i:i + per_chunk])) for i in range(0, len(pts), per_chunk)]
    end = answer("END")
    return begin, chunks, end


# --------------------------------------------------------------------------
# What Blender holds

def obj(name):
    return bpy.data.objects[name]


def weights(name):
    o = obj(name)
    group = o.vertex_groups.active
    out = [0.0] * len(o.data.vertices)
    if group is None:
        return out
    for v in o.data.vertices:
        for element in v.groups:
            if element.group == group.index:
                out[v.index] = element.weight
    return out


def colours(name):
    layer = obj(name).data.color_attributes.active_color
    if layer is None:
        return []
    values = array('f', [0.0]) * (4 * len(layer.data))
    layer.data.foreach_get('color_srgb', values)
    return list(values)


def held(name):
    return weights(name) if obj(name).mode == 'WEIGHT_PAINT' else colours(name)


def apart(a, b):
    if len(a) != len(b):
        return float("inf")
    return max((abs(x - y) for x, y in zip(a, b)), default=0.0)


def painted(name):
    o = obj(name)
    if o.mode == 'WEIGHT_PAINT':
        return sum(1 for w in weights(name) if w > 1e-6)
    c = colours(name)
    return sum(1 for i in range(0, len(c), 4) if abs(c[i] - 1) + abs(c[i + 1] - 1) + abs(c[i + 2] - 1) > 1e-4)


def fresh(name, location=(0, 0, 0)):
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=1, location=location)
    bpy.context.object.name = name
    return bpy.context.object.name


def select(name):
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    obj(name).select_set(True)
    bpy.context.view_layer.objects.active = obj(name)


# --------------------------------------------------------------------------
print("\nInto both modes, and out")

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
ball = fresh("Ball")
first = push("Original")
check("the history's first push runs Blender's undo", first["mode"] == "blender", first)
check("the toolbar's tools carry Blender's names (Brush, Blur, Average, Smear)",
      blocks["TOOL_LABELS"].strip() == "Brush,Blur,Average,Smear", blocks["TOOL_LABELS"])
for mode, enter_block, undo_block in (("WEIGHT_PAINT", "ENTER_WEIGHT", "MODE_UNDO_WEIGHT"),
                                      ("VERTEX_PAINT", "ENTER_VERTEX", "MODE_UNDO_VERTEX")):
    select(ball)
    push("Object Mode")
    run(enter_block)
    label = blocks[undo_block].strip()
    state = push(label)
    check("%s: Blender is in it, and the history's step is %r" % (mode, label),
          obj(ball).mode == mode and state["undo_label"] == label, (obj(ball).mode, state))
    # Blender's own name for the same step: mode_set with its undo on.
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.mode_set('EXEC_DEFAULT', True, mode=mode)
    check("  which is what Blender's history calls entering it (%r)" % blender_step(),
          blender_step() == label, undo_module.blender_steps()[-3:])
    bpy.ops.object.mode_set('EXEC_DEFAULT', True, mode='OBJECT')
    check("  and leaving it (%r)" % blender_step(), blender_step() == label)
    run(enter_block)
    push(label)
    run("LEAVE")
    push(label)
    check("  the bar's Object Mode leaves it", obj(ball).mode == 'OBJECT')
    undo()
    check("  Undo: back in it", obj(ball).mode == mode, obj(ball).mode)
    undo()
    redo()
    check("  Redo: in it", obj(ball).mode == mode, obj(ball).mode)
    bpy.ops.object.mode_set(mode='OBJECT')

# --------------------------------------------------------------------------
print("\nRefusals: each a sentence, none a crash")

bpy.ops.object.light_add(type='POINT', location=(4, 0, 0))
lamp = bpy.context.object.name
said = refused("ENTER_WEIGHT")
check("a light: refused, by name", said is not None and lamp in said and obj(lamp).mode == 'OBJECT', said)
bpy.ops.mesh.primitive_plane_add(location=(0, 4, 0))
wire = bpy.context.object.name
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.delete(type='ONLY_FACE')
bpy.ops.object.mode_set(mode='OBJECT')
said = refused("ENTER_VERTEX")
check("a mesh with no faces: refused (Blender would enter and paint nothing)",
      said is not None and "no faces" in said and obj(wire).mode == 'OBJECT', said)
select(ball)
obj(ball).hide_set(True)
said = refused("ENTER_WEIGHT")
check("a hidden mesh: refused", said is not None and "hidden" in said, said)
obj(ball).hide_set(False)
select(ball)
run("ENTER_WEIGHT")
push("Weight Paint Mode")
said = refused("BEGIN", object=lamp, camera=camera_literal(CAMERA))
check("a stroke on another object: refused", said is not None and "not it" in said, said)
obj(ball).vertex_groups.new(name="Locked").lock_weight = True
push("Locked")
before = len(undo_module.blender_steps())
said = refused("BEGIN", object=ball, camera=camera_literal(CAMERA))
check("a locked active group: refused in words, no step pushed (Blender's exec warns and pushes one)",
      said is not None and "locked" in said and len(undo_module.blender_steps()) == before, said)
obj(ball).vertex_groups.remove(obj(ball).vertex_groups["Locked"])
push("Unlocked")
result = []
worker = threading.Thread(target=lambda: result.append(refused("BEGIN", object=ball,
                                                              camera=camera_literal(CAMERA))))
worker.start()
worker.join()
check("a worker thread: refused", result and result[0] is not None and "main thread" in result[0], result)
element = dict(name='', location=(0, 0, 0), mouse=(500, 400), mouse_event=(500, 400), pressure=1.0,
               size=60.0, time=0.0, is_start=True, x_tilt=0.0, y_tilt=0.0)
try:
    bpy.ops.paint.weight_paint('EXEC_DEFAULT', True, stroke=[element], mode='NORMAL', override_location=True)
    said = None
except RuntimeError as error:
    said = str(error)
check("the script line with no 3D View: Blender's own poll refuses it, no crash",
      said is not None and "poll" in said, said)

# --------------------------------------------------------------------------
print("\nA stroke streamed in chunks is Blender's one stroke")

run("STRENGTH_0.3")
run("SIZE_60")
path = line((-0.7, -0.5, 0.4), (0.7, -0.6, 0.1), 40)


def one_call(name, dabs_points):
    """The dabs the streamed stroke made, as one of Blender's strokes."""
    window, area, region = sculpt._knife.view3d()
    space = area.spaces.active
    stroke_state = dict(mode=obj(name).mode, last=None, spaced=paint._brush(obj(name).mode).stroke_method == 'SPACE')
    with bpy.context.temp_override(window=window, area=area, region=region):
        mapped = sculpt.aim(space, space.region_3d, region, CAMERA, VIEW)
        converted = [sculpt.to_region(p, mapped) + (p[2], p[3]) for p in dabs_points]
        dabs = paint._space(stroke_state, converted)
        elements = paint._elements(dict(mode=obj(name).mode), dabs)
        operator = bpy.ops.paint.weight_paint if obj(name).mode == 'WEIGHT_PAINT' else bpy.ops.paint.vertex_paint
        operator('EXEC_DEFAULT', True, stroke=elements, mode='NORMAL', override_location=True)
    return len(dabs)


for mode, enter_block, name_block in (("WEIGHT_PAINT", "ENTER_WEIGHT", "STROKE_NAME_WEIGHT"),
                                      ("VERTEX_PAINT", "ENTER_VERTEX", "STROKE_NAME_VERTEX")):
    select(ball)
    run(enter_block)
    push(mode)
    if mode == 'VERTEX_PAINT':
        run("COLOR_RED")
        run("STRENGTH_0.3")
    start = held(ball)
    start_index = undo_module._index
    begin, chunks, end = stroke(ball, path)
    state = push(end.get("step", "?"))
    streamed = held(ball)
    name = blocks[name_block].strip()
    check("%s: the stroke painted %d vertices in %d chunks" % (mode, painted(ball), len(chunks)),
          painted(ball) > 20 and sum(1 for c in chunks if c["applied"]) >= 3, chunks)
    check("  one history step, named as Blender's history names it (%r)" % end.get("step"),
          end.get("step") == name and state["undo_label"] == name and undo_module._index == start_index + 1,
          (end, state))
    data = [h for h in handed if h[0] == ball][-1] if handed else None
    kind = 'WEIGHT' if mode == 'WEIGHT_PAINT' else 'COLOR'
    check("  the viewport was last handed exactly what Blender holds, one %s value per vertex drawn"
          % kind.lower(), data is not None and data[1] == kind and data[2] == paint.values(obj(ball))
          and len(data[2]) == (4 if kind == 'WEIGHT' else 16) * len(obj(ball).data.vertices),
          data and (data[1], len(data[2])))
    undo()
    check("  Undo: what Blender held before it, exactly (%.1g apart)" % apart(held(ball), start),
          apart(held(ball), start) == 0, apart(held(ball), start))
    redo()
    check("  Redo: the stroke again, exactly (%.1g apart)" % apart(held(ball), streamed),
          apart(held(ball), streamed) == 0, apart(held(ball), streamed))
    undo()
    # From here Blender's own strokes, each taken back, on the step before
    # the stream's: the history's Redo of it is given up for them.
    count = one_call(ball, path)
    one = held(ball)
    check("  the same %d dabs as one of Blender's strokes leave exactly what the stream left "
          "(%.1g apart)" % (count, apart(one, streamed)), apart(one, streamed) < 1e-6, apart(one, streamed))
    bpy.ops.ed.undo()
    # The negative control: the chunks sent as strokes of their own, without
    # the rewind, are not Blender's one stroke.
    window, area, region = sculpt._knife.view3d()
    space = area.spaces.active
    stroke_state = dict(mode=mode, last=None, spaced=True)
    operator = bpy.ops.paint.weight_paint if mode == 'WEIGHT_PAINT' else bpy.ops.paint.vertex_paint
    pieces = 0
    for i in range(0, len(path), 4):
        with bpy.context.temp_override(window=window, area=area, region=region):
            mapped = sculpt.aim(space, space.region_3d, region, CAMERA, VIEW)
            converted = [sculpt.to_region(p, mapped) + (p[2], p[3]) for p in path[i:i + 4]]
            dabs = paint._space(stroke_state, converted)
            if dabs:
                operator('EXEC_DEFAULT', True, stroke=paint._elements(dict(mode=mode), dabs), mode='NORMAL',
                         override_location=True)
                pieces += 1
    cut = held(ball)
    check("  negative control: the same dabs sent as %d strokes of their own are not (%.3f apart)"
          % (pieces, apart(cut, streamed)), apart(cut, streamed) > 0.01, apart(cut, streamed))
    for _ in range(pieces):
        bpy.ops.ed.undo()
    check("  and Blender's undo takes them all back", apart(held(ball), start) == 0, apart(held(ball), start))
    bpy.ops.object.mode_set(mode='OBJECT')
    push("Object Mode")

# --------------------------------------------------------------------------
print("\nThe brush settings, written and read back")

select(ball)
run("ENTER_WEIGHT")
push("Weight Paint Mode")
run("SIZE_60")
run("STRENGTH_0.3")
run("WEIGHT_0.6")
state = answer("STATE")
ts = bpy.context.scene.tool_settings.weight_paint
check("Weight Paint: Size 60, Strength 0.3, Weight 0.6 read back where Blender reads them",
      state["size"] == 60 and abs(state["strength"] - 0.3) < 1e-4 and abs(state["weight"] - 0.6) < 1e-4
      and paint._owner('WEIGHT_PAINT', 'size').size == 60, state)
run("WEIGHT_PAST")
check("a Weight past 1 is held to Blender's range", abs(answer("STATE")["weight"] - 1.0) < 1e-6)
for tool, kind in (("BLUR", "BLUR"), ("AVERAGE", "AVERAGE"), ("SMEAR", "SMEAR"), ("BRUSH", "DRAW")):
    run("TOOL_" + tool)
    state = answer("STATE")
    check("the toolbar's %s takes Blender's %s brush (%s)" % (tool.title(), kind.title(), state["brush"]),
          state["brush_type"] == kind and state["tool"] == tool, state)
run("BLEND_ADD")
check("Blend: Add, on the brush", answer("STATE")["blend"] == "ADD" and paint._brush('WEIGHT_PAINT').blend == 'ADD')
run("BLEND_MIX")
run("ENTER_VERTEX")
push("Vertex Paint Mode")
run("COLOR_RED")
state = answer("STATE")
check("Vertex Paint: Color red, in sRGB, where Blender reads it",
      state["color"] == [1.0, 0.0, 0.0] and tuple(paint._owner('VERTEX_PAINT', 'color').color) == (1.0, 0.0, 0.0),
      state)
said = refused("WEIGHT_0.6")
check("Weight is refused in Vertex Paint", said is not None and "Weight Paint" in said, said)

# --------------------------------------------------------------------------
print("\nVertex Paint's colour: the picker's sRGB, held as Blender holds it")

# Blender 5.2.1 holds the brush's colour scene linear (Brush.color and the
# unified one are subtype COLOR). The header used to write the picker's sRGB
# as the linear value: 0.5 grey painted sRGB 0.737 (round 4's review). Red,
# the only colour checked then, is the same in both spaces.
from mathutils import Color


def painted_corners(name):
    c = colours(name)
    return [tuple(c[i:i + 3]) for i in range(0, len(c), 4)
            if abs(c[i] - 1) + abs(c[i + 1] - 1) + abs(c[i + 2] - 1) > 1e-4]


def closest(corners, target):
    return min(corners, key=lambda p: max(abs(a - b) for a, b in zip(p, target)), default=None)


select(ball)
run("ENTER_VERTEX")
push("Vertex Paint Mode")
run("ACTIVATE", brush="Paint Hard")
run("STRENGTH_1")
run("SIZE_60")
subtype = paint._owner('VERTEX_PAINT', 'color').bl_rna.properties['color'].subtype
for block, srgb in (("COLOR_GREY", (0.5, 0.5, 0.5)), ("COLOR_MIXED", (0.2, 0.6, 0.9))):
    run(block)
    state = answer("STATE")
    held_now = tuple(paint._owner('VERTEX_PAINT', 'color').color)
    linear = tuple(Color(srgb).from_srgb_to_scene_linear())
    check("%s: Blender holds the picker's sRGB %s as scene linear %s (subtype %s), and the swatch reads "
          "back %s" % (block, srgb, tuple(round(c, 4) for c in held_now), subtype, state["color"]),
          subtype == 'COLOR' and state["color_space"] == 'SCENE_LINEAR'
          and max(abs(a - b) for a, b in zip(held_now, linear)) < 1e-5
          and max(abs(a - b) for a, b in zip(state["color"], srgb)) < 1e-3
          and max(abs(a - b) for a, b in zip(state["color_held"], held_now)) < 1e-4, state)
    start = held(ball)
    begin, chunks, end = stroke(ball, path)
    push(end.get("step", "?"))
    corners = painted_corners(ball)
    near = closest(corners, srgb)
    off = max(abs(a - b) for a, b in zip(near, srgb)) if near else float("inf")
    full = sum(1 for p in corners if max(abs(a - b) for a, b in zip(p, srgb)) < 1.5 / 255)
    check("  and a Paint Hard stroke at strength 1 paints it: %d corners at the picked colour, the "
          "nearest %.4f from it (a byte is %.4f)" % (full, off, 1 / 255), off < 1.5 / 255 and full > 50,
          (near, len(corners)))
    undo()
    check("  Undo takes the stroke back", apart(held(ball), start) == 0, apart(held(ball), start))
# The negative control: the picker's sRGB written as the linear value, as the
# header did.
paint._owner('VERTEX_PAINT', 'color').color = (0.5, 0.5, 0.5)
start = held(ball)
begin, chunks, end = stroke(ball, path)
push(end.get("step", "?"))
corners = painted_corners(ball)
darkest = min((p[0] for p in corners), default=None)
check("negative control: sRGB 0.5 written as linear paints sRGB %s, not 0.5" % (darkest and round(darkest, 4)),
      darkest is not None and abs(darkest - 0.737) < 0.01, darkest)
undo()
check("  and its Undo takes it back", apart(held(ball), start) == 0)
run("COLOR_RED")
run("STRENGTH_0.3")
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")

# --------------------------------------------------------------------------
print("\nEvery Essentials brush, with Undo and Redo")

for mode, enter_block in (("WEIGHT_PAINT", "ENTER_WEIGHT"), ("VERTEX_PAINT", "ENTER_VERTEX")):
    select(ball)
    run(enter_block)
    push(mode)
    names = answer("BRUSHES")
    broken = []
    for name in names:
        run("ACTIVATE", brush=name)
        before = held(ball)
        try:
            begin, chunks, end = stroke(ball, line((-0.6, -0.6, 0.3), (0.6, -0.6, 0.0), 16))
        except RuntimeError as error:
            broken.append((name, str(error)))
            continue
        if not end["pushed"]:
            broken.append((name, "nothing pushed"))
            continue
        push(end.get("step", "?"))
        after = held(ball)
        undo()
        back = apart(held(ball), before)
        redo()
        again = apart(held(ball), after)
        if back or again:
            broken.append((name, back, again))
        undo()
    check("%s: all %d Essentials brushes stroke, and Undo and Redo give back exactly what they held"
          % (mode, len(names)), len(names) >= 4 and not broken, broken)
    bpy.ops.object.mode_set(mode='OBJECT')
    push("Object Mode")

# --------------------------------------------------------------------------
print("\nA long stroke stays one of Blender's strokes")

# Six passes back and forth over the ball, 216 dabs. Cut at 64 dabs as a
# sculpt stroke is (round 4's first version), the passes over each other
# added up: 0.456 apart in weight from the same dabs as one stroke. Here every
# replay is counted as dear and the next held back for good, so most chunks
# are held (the 3D View shows Blender's last replay) and the stroke's end
# replays everything after it (`_flush`); the stroke kept is the one stroke.
a, b = (-0.7, -0.5, 0.4), (0.7, -0.6, 0.1)
passes = []
for k in range(6):
    ends = (a, b) if k % 2 == 0 else (b, a)
    passes += [(p[0], p[1] + 3 * k) for p in line(ends[0], ends[1], 40)]
long_path = [(x, y, 1.0, i / 60.0) for i, (x, y) in enumerate(passes)]


def throttled(name, pts, budget=0.0, duty=1e6, cap=None):
    kept = paint.REPLAY_BUDGET_MS, paint.REPLAY_DUTY, paint.MAX_STROKE_DABS
    paint.REPLAY_BUDGET_MS, paint.REPLAY_DUTY = budget, duty
    if cap is not None:
        paint.MAX_STROKE_DABS = cap
    try:
        return stroke(name, pts)
    finally:
        paint.REPLAY_BUDGET_MS, paint.REPLAY_DUTY, paint.MAX_STROKE_DABS = kept


for mode, enter_block, brush in (("WEIGHT_PAINT", "ENTER_WEIGHT", "Paint"),
                                 ("VERTEX_PAINT", "ENTER_VERTEX", "Paint Hard")):
    select(ball)
    run(enter_block)
    push(mode)
    run("ACTIVATE", brush=brush)
    run("STRENGTH_0.3")
    start = held(ball)
    start_index = undo_module._index
    del handed[:]
    begin, chunks, end = throttled(ball, long_path)
    state = push(end.get("step", "?"))
    streamed = held(ball)
    held_back = sum(1 for c in chunks if c.get("held"))
    check("%s: %d dabs, %d of %d chunks held back, the end replayed all %d, no cut, one history step"
          % (mode, end["dabs"], held_back, len(chunks), end.get("flushed", 0)),
          end["dabs"] > 150 and held_back >= len(chunks) - 2 and end.get("flushed") == end["dabs"]
          and end["cuts"] == 0 and end["pushed"] == 1 and undo_module._index == start_index + 1, end)
    data = [h for h in handed if h[0] == ball]
    check("  the 3D View was last handed exactly what Blender holds after the end's replay",
          bool(data) and data[-1][2] == paint.values(obj(ball)), len(data))
    undo()
    check("  Undo: what Blender held before it, exactly", apart(held(ball), start) == 0, apart(held(ball), start))
    count = one_call(ball, long_path)
    one = held(ball)
    check("  the same %d dabs as one of Blender's strokes leave exactly what it left (%.1g apart)"
          % (count, apart(one, streamed)), count == end["dabs"] and apart(one, streamed) < 1e-6,
          (count, apart(one, streamed)))
    bpy.ops.ed.undo()
    # The negative control: cut into strokes of 64 dabs, as before.
    begin, chunks, cut_end = throttled(ball, long_path, budget=paint.REPLAY_BUDGET_MS,
                                       duty=paint.REPLAY_DUTY, cap=64)
    push(cut_end.get("step", "?"))
    cut = held(ball)
    check("  negative control: cut into strokes of 64 dabs (%d cuts) it is not (%.3f apart)"
          % (cut_end["cuts"], apart(cut, one)), cut_end["cuts"] >= 2 and apart(cut, one) > 0.1,
          (cut_end["cuts"], apart(cut, one)))
    undo()
    check("  and its Undo takes the whole of it back", apart(held(ball), start) == 0, apart(held(ball), start))
    bpy.ops.object.mode_set(mode='OBJECT')
    push("Object Mode")

# --------------------------------------------------------------------------
print("\nA mirror dearer than the budget holds the replays back")

# The throttle counts the mirror after a replay (`values`, handed to the
# viewport) as well as the replay and its rewind: round 4's review measured
# 95.7 ms for the mirror of a 40,962-vertex colour layer, which the throttle
# did not see. With the budget at 50 ms, a mirror made to cost 120 ms here
# holds the chunks after it back; with the mirror as it is (a few ms on this
# ball) none is held, which shows it is the mirror's cost that holds them.
import time as _time

for mode, enter_block in (("WEIGHT_PAINT", "ENTER_WEIGHT"), ("VERTEX_PAINT", "ENTER_VERTEX")):
    select(ball)
    run(enter_block)
    push(mode)
    run("ACTIVATE", brush="Paint" if mode == 'WEIGHT_PAINT' else "Paint Hard")
    run("STRENGTH_0.3")
    start = held(ball)
    real_push = paint.push

    def slow_push(target, depsgraph=None):
        _time.sleep(0.12)
        real_push(target, depsgraph)

    budget = paint.REPLAY_BUDGET_MS
    paint.push, paint.REPLAY_BUDGET_MS = slow_push, 50.0
    try:
        begin, chunks, end = stroke(ball, path)
    finally:
        paint.push = real_push
    push(end.get("step", "?"))
    slow_held = sum(1 for c in chunks if c.get("held"))
    slow = held(ball)
    undo()
    try:
        begin, chunks, quick_end = stroke(ball, path)
    finally:
        paint.REPLAY_BUDGET_MS = budget
    push(quick_end.get("step", "?"))
    quick_held = sum(1 for c in chunks if c.get("held"))
    quick = held(ball)
    undo()
    check("%s: a 120 ms mirror holds %d of %d chunks back and the end replays them (%d dabs); "
          "the mirror as it is holds %d" % (mode, slow_held, len(chunks), end.get("flushed", 0), quick_held),
          slow_held >= len(chunks) - 3 and end.get("flushed", 0) == end["dabs"] and quick_held == 0
          and end["pushed"] == 1, (end, quick_end))
    check("  and both leave the same stroke (%.1g apart)" % apart(slow, quick), apart(slow, quick) < 1e-6)
    check("  whose Undo takes it back", apart(held(ball), start) == 0)
    bpy.ops.object.mode_set(mode='OBJECT')
    push("Object Mode")

# --------------------------------------------------------------------------
print("\nA refused chunk ends the stroke without replaying what was held back")

select(ball)
run("ENTER_WEIGHT")
push("Weight Paint Mode")
run("ACTIVATE", brush="Paint")
start = held(ball)
for name, block in (("CANCEL", "CANCEL"), ("END", "END")):
    kept = paint.REPLAY_BUDGET_MS, paint.REPLAY_DUTY
    paint.REPLAY_BUDGET_MS, paint.REPLAY_DUTY = 0.0, 1e6
    del handed[:]
    try:
        answer("BEGIN", object=ball, camera=camera_literal(CAMERA))
        chunks = [answer("CHUNK", points=literal(path[i:i + 4])) for i in range(0, len(path), 4)]
        ending = answer(block)
    finally:
        paint.REPLAY_BUDGET_MS, paint.REPLAY_DUTY = kept
    push(ending.get("step", "?"))
    shown = [h for h in handed if h[0] == ball]
    replayed = max(c["dabs"] for c in chunks)
    if name == "CANCEL":
        check("PaintModeBpy.cancel: %d dabs, %d replayed, none of the rest (flushed %d), one step, and "
              "Blender holds what the 3D View was last handed" % (ending["dabs"], replayed, ending["flushed"]),
              ending["flushed"] == 0 and replayed < ending["dabs"] and ending["pushed"] == 1
              and bool(shown) and shown[-1][2] == paint.values(obj(ball)), ending)
    else:
        check("negative control: PaintModeBpy.end replays them (flushed %d of %d)"
              % (ending["flushed"], ending["dabs"]), ending["flushed"] == ending["dabs"] > replayed, ending)
    undo()
check("and Undo takes each back", apart(held(ball), start) == 0, apart(held(ball), start))
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")

# --------------------------------------------------------------------------
print("\nA Line stroke is spaced, as Blender's is")

# Blender's line end adds a dab at the start and spaces the rest to the end
# (paint_stroke_line_end calls paint_space_stroke); RNA 5.2.1: "Draw a line
# with dabs separated according to spacing". The app used to send the two
# ends alone.
select(ball)
run("ENTER_WEIGHT")
push("Weight Paint Mode")
run("ACTIVATE", brush="Paint")
run("SIZE_60")
brush = paint._brush('WEIGHT_PAINT')
method = brush.stroke_method
brush.stroke_method = 'LINE'
start = held(ball)
try:
    begin, chunks, end = stroke(ball, path)
    push(end.get("step", "?"))
    line_painted = painted(ball)
    window, area, region = sculpt._knife.view3d()
    space = area.spaces.active
    with bpy.context.temp_override(window=window, area=area, region=region):
        mapped = sculpt.aim(space, space.region_3d, region, CAMERA, VIEW)
        first, last = sculpt.to_region(path[0], mapped), sculpt.to_region(path[-1], mapped)
    brush = paint._brush('WEIGHT_PAINT')
    step = max(1.0, max(1.0, paint._owner('WEIGHT_PAINT', 'size').size / 2.0) * brush.spacing / 50.0)
    expected = 1 + int(math.hypot(last[0] - first[0], last[1] - first[1]) // step)
    undo()
    # The two ends alone, as before, through Blender's operator.
    with bpy.context.temp_override(window=window, area=area, region=region):
        sculpt.aim(space, space.region_3d, region, CAMERA, VIEW)
        ends = [first + (1.0, 0.0), last + (1.0, 0.1)]
        bpy.ops.paint.weight_paint('EXEC_DEFAULT', True, stroke=paint._elements(dict(mode='WEIGHT_PAINT'), ends),
                                   mode='NORMAL', override_location=True)
    ends_painted = painted(ball)
    bpy.ops.ed.undo()
finally:
    paint._brush('WEIGHT_PAINT').stroke_method = method
check("a Line of %.0f px at a %.1f px spacing sends %d dabs, Blender's spacing from the start (%d)"
      % (math.hypot(last[0] - first[0], last[1] - first[1]), step, end["dabs"], expected),
      end["dabs"] == expected > 2 and end["strategy"] == 'line', end)
check("and paints the line's length (%d weighted), where its two ends alone paint %d"
      % (line_painted, ends_painted), line_painted > ends_painted + 5, (line_painted, ends_painted))
check("Undo takes it back", apart(held(ball), start) == 0, apart(held(ball), start))
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")

# --------------------------------------------------------------------------
print("\nA stroke past MAX_STROKE_DABS, at its own value")

# Only past MAX_STROKE_DABS (2,048) is a stroke kept and gone on with as a new
# one; round 4's review found no check reaching it. Size 10 spaces dabs a
# pixel apart, so passes back and forth over the ball pass it.
select(ball)
run("ENTER_WEIGHT")
push("Weight Paint Mode")
run("ACTIVATE", brush="Paint")
run("SIZE_10")
run("STRENGTH_0.3")
many = []
for k in range(9):
    ends = (a, b) if k % 2 == 0 else (b, a)
    many += [(p[0], p[1] + 2 * k) for p in line(ends[0], ends[1], 60)]
many_path = [(x, y, 1.0, i / 60.0) for i, (x, y) in enumerate(many)]
start = held(ball)
start_index = undo_module._index
begin, chunks, end = stroke(ball, many_path, per_chunk=6)
state = push(end.get("step", "?"))
step_now = undo_module._steps[undo_module._index]
check("%d dabs (cap %d): %d cut(s), %d of Blender's steps, one history step %r that deep"
      % (end["dabs"], paint.MAX_STROKE_DABS, end["cuts"], end["pushed"], state["undo_label"]),
      end["dabs"] > paint.MAX_STROKE_DABS and end["cuts"] == 1 and end["pushed"] == 2
      and state["undo_label"] == "Weight Paint" and step_now.get("depth") == end["pushed"],
      (end["cuts"], end["pushed"], state, {k: v for k, v in step_now.items() if k != 'file'},
       undo_module._index - start_index))
check("  and the 3D View was last handed what Blender holds",
      [h for h in handed if h[0] == ball][-1][2] == paint.values(obj(ball)))
undo()
check("  Undo takes all of it back", apart(held(ball), start) == 0, apart(held(ball), start))
run("SIZE_60")
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")

# --------------------------------------------------------------------------
print("\nWhat the viewport is handed costs little on a dense mesh")

# The corner average used to be a Python loop over every corner: round 4's
# review measured 95.7 ms at 40,962 vertices (245,760 corners). numpy's
# bincount now, the same values; the loop is what runs without numpy.
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=7, location=(0, 30, 0))
dense = bpy.context.object
dense.name = "Dense"
layer = dense.data.color_attributes.new("Col", 'BYTE_COLOR', 'CORNER')
import random as _random
_random.seed(7)
fill = [_random.random() for _ in range(4 * len(layer.data))]
layer.data.foreach_set('color_srgb', fill)
dense.data.color_attributes.active_color = layer
point_layer = dense.data.color_attributes.new("Points", 'FLOAT_COLOR', 'POINT')
point_layer.data.foreach_set('color_srgb', [_random.random() for _ in range(4 * len(point_layer.data))])
group = dense.vertex_groups.new(name="Group")
group.add(list(range(0, len(dense.data.vertices), 3)), 0.5, 'REPLACE')
push("Dense")


def timed(fn, *args):
    best, out = None, None
    for _ in range(3):
        t = _time.perf_counter()
        out = fn(*args)
        ms = (_time.perf_counter() - t) * 1000
        best = ms if best is None else min(best, ms)
    return out, best


fast, fast_ms = timed(paint.values, dense, 'VERTEX_PAINT')
real_numpy = paint._numpy
paint._numpy = lambda: None
try:
    slow, slow_ms = timed(paint.values, dense, 'VERTEX_PAINT')
    dense.data.color_attributes.active_color = point_layer
    slow_points = paint.values(dense, 'VERTEX_PAINT')
finally:
    paint._numpy = real_numpy
fast_points = paint.values(dense, 'VERTEX_PAINT')
dense.data.color_attributes.active_color = layer
weights_data, weights_ms = timed(paint.values, dense, 'WEIGHT_PAINT')
fa, sa = array('f'), array('f')
fa.frombytes(fast)
sa.frombytes(slow)
check("%d vertices, %d corners: the corner average with numpy is the loop's to %.1g, %.1f ms where the "
      "loop takes %.1f (weights %.1f ms)" % (len(dense.data.vertices), len(dense.data.loops),
                                              apart(list(fa), list(sa)), fast_ms, slow_ms, weights_ms),
      len(fa) == 4 * len(dense.data.vertices) and apart(list(fa), list(sa)) < 1e-5
      and fast_ms < 30 and fast_ms * 4 < slow_ms, (len(fa), fast_ms, slow_ms))
check("a point layer reads the same both ways", fast_points == slow_points and len(fast_points) > 0)
bpy.data.objects.remove(dense)
push("Removed")

# --------------------------------------------------------------------------
print("\nWhat the viewport draws, through a modifier")

select(ball)
obj(ball).modifiers.new("Subdivision", 'SUBSURF').levels = 1
push("Subdivision")
run("ENTER_WEIGHT")
push("Weight Paint Mode")
run("ACTIVATE", brush="Paint")
begin, chunks, end = stroke(ball, path)
push(end.get("step", "?"))
depsgraph = bpy.context.evaluated_depsgraph_get()
drawn = len(obj(ball).evaluated_get(depsgraph).data.vertices)
data = array('f')
data.frombytes(paint.values(obj(ball)))
check("one weight per vertex of the subdivided mesh drawn (%d over %d), and the stroke's reach in them "
      "(%d weighted)" % (len(data), len(obj(ball).data.vertices), sum(1 for w in data if w > 0)),
      len(data) == drawn > len(obj(ball).data.vertices) and sum(1 for w in data if w > 0) > 20)

# --------------------------------------------------------------------------
print("\nA stroke held open")

select(ball)
run("ENTER_WEIGHT")
push("Weight Paint Mode")
answer("BEGIN", object=ball, camera=camera_literal(CAMERA))
answer("CHUNK", points=literal(path[:4]))
said = None
try:
    undo()
except RuntimeError as error:
    said = str(error)
check("the history's Undo mid-stroke is refused", said is not None and "stroke" in said, said)
for block, fill in (("ACTIVATE", {"brush": "Blur"}), ("SIZE_60", {}), ("TOOL_BLUR", {})):
    said = refused(block, **fill)
    check("%s mid-stroke is refused in words" % block, said is not None and "stroke" in said, said)
answer("CHUNK", points=literal(path[4:12]))
end = answer("END")
push(end.get("step", "?"))
check("and the stroke ends as one step", end["pushed"] >= 1 and end.get("step") == "Weight Paint", end)

# --------------------------------------------------------------------------
print("\nAfter a file load has freed Blender's undo stack")

bpy.ops.object.mode_set(mode='OBJECT')
saved = os.path.join(WORK, "painting.blend")
bpy.ops.wm.save_as_mainfile(filepath=saved, copy=True)
# The app's file-read guard makes the stack again at once
# (`_blenderkit_undo.ensure_stack`, round 4's review: a mask fill or Face Sets
# ▸ Initialize after a load segfaulted Blender). Entering Weight Paint is then
# a step of the history's, as the bar's mode row makes it, and a stroke
# paints over it.
bpy.ops.wm.open_mainfile(filepath=saved, load_ui=False)
check("a load through the app's file-read guard leaves Blender with an undo stack",
      bool(undo_module.blender_steps()), undo_module.blender_steps())
select(ball)
bpy.ops.object.mode_set(mode='WEIGHT_PAINT')
push("Weight Paint Mode")
before = held(ball)
begin, chunks, end = stroke(ball, path)
check("a stroke after it paints (%d weighted) and is a step" % painted(ball),
      apart(held(ball), before) > 0 and end["pushed"] >= 1, end)
# The stroke's own `_require_undo_stack` is what remains if the guard ever
# fails: switched off for this load, the stroke meets no stack.
bpy.ops.object.mode_set(mode='OBJECT')
_ensure_stack = undo_module.ensure_stack
undo_module.ensure_stack = lambda label: False
bpy.ops.wm.open_mainfile(filepath=saved, load_ui=False)
undo_module.ensure_stack = _ensure_stack
check("with the guard off, a load leaves Blender with no undo stack here", not undo_module.blender_steps(),
      undo_module.blender_steps())
select(ball)
bpy.ops.object.mode_set(mode='WEIGHT_PAINT')
before = held(ball)
begin, chunks, end = stroke(ball, path)
check("a stroke starts Blender's undo itself, paints (%d weighted) and is a step" % painted(ball),
      apart(held(ball), before) > 0 and end["pushed"] >= 1, end)

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
