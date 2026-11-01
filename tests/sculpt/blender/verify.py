"""Sculpt Mode with Blender's own brushes, run by a headless Blender the way
the app runs it.

scripts/run-sculpt-blender-check.sh starts Blender with `-b --factory-startup`
and a home of its own. Every string run is what the Swift sends, printed by
tests/sculpt/blender/main.swift, and the modules are the ones the app ships
from Resources/python/site. Nothing is set up for the strokes that the app
does not set up: the undo stack comes from the history's first push, and the
GPU module and the 3D View from `_blenderkit_sculpt` itself.

What is checked:
  * the view: a point where the app's camera draws it is the region pixel
    Blender's aimed 3D View draws it at, in perspective and orthographic;
  * refusals: object mode, a camera, a worker thread, an object that leaves
    Sculpt Mode part way through a stroke — each a sentence, none a crash;
  * a Draw stroke streamed in chunks is Blender's one stroke exactly, whatever
    the chunks; one history step, which Undo and Redo take back and forth to
    the vertex;
  * Grab dragged past the silhouette, and a Snake Hook long enough to be cut;
  * every Essentials brush strokes, and Undo and Redo give back the mesh,
    the mask and the face sets exactly;
  * every brush strokes with the mesh's X, Y and Z symmetry on, and the core
    brushes reach the mirrored side;
  * Dynamic Topology, Voxel Remesh, Multires Subdivide, the Mask menu and Face
    Sets, each one Undo deep, and the brush settings read back as written;
  * after a file load has freed Blender's undo stack, a stroke starts one
    rather than segfaulting.
"""
import bpy, sys, os, math, time, json, threading, importlib.util, pathlib, io, contextlib
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


# _blenderkit_multires: the Multires budget the Sculpt header's Subdivide asks.
for module in ("_blenderkit_context", "_blenderkit_knife", "_blenderkit_undo", "_blenderkit_multires",
               "_blenderkit_sculpt"):
    spec = importlib.util.spec_from_file_location(module, SITE / (module + ".py"))
    sys.modules[module] = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sys.modules[module])
sys.modules["_blenderkit_context"].install(bpy)
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
    """One block, in the namespace the app's interpreter shares between
    statements, returning what it printed."""
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
    """The sentence a block raised, or None when it ran."""
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


# --------------------------------------------------------------------------
# The app's camera, as ViewportCamera draws with it

FOV = 2 * math.atan(18.0 / 50.0)
VIEW = (1100.0, 800.0)


def camera_literal(cam):
    """SculptCamera.python, for the same numbers."""
    n = lambda v: "%.9g" % v
    t = cam["target"]
    return ("dict(target=(%s, %s, %s), distance=%s, azimuth=%s, elevation=%s, fov_y=%s, "
            "ortho=%s, near=%s, far=%s)" % (n(t[0]), n(t[1]), n(t[2]), n(cam["distance"]),
                                            n(cam["azimuth"]), n(cam["elevation"]), n(cam["fov_y"]),
                                            "True" if cam["ortho"] else "False", n(cam["near"]),
                                            n(cam["far"])))


def basis(cam):
    a, e = cam["azimuth"], cam["elevation"]
    right = Vector((math.cos(a), math.sin(a), 0))
    up = Vector((-math.sin(e) * math.sin(a), math.sin(e) * math.cos(a), math.cos(e)))
    back = Vector((math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e)))
    return right, up, back


def app_project(cam, p, view=VIEW):
    """ViewportCamera.viewProjection, to the 3D View's points (top-left)."""
    w, h = view
    right, up, back = basis(cam)
    eye = Vector(cam["target"]) + back * cam["distance"]
    d = Vector(p) - eye
    if cam["ortho"]:
        half = cam["distance"] * math.tan(cam["fov_y"] / 2)
        return (w / 2 + d.dot(right) * (h / 2) / half, h / 2 - d.dot(up) * (h / 2) / half)
    f = (h / 2) / math.tan(cam["fov_y"] / 2)
    z = -d.dot(back)
    return (w / 2 + d.dot(right) / z * f, h / 2 - d.dot(up) / z * f)


def camera_on(obj, azimuth=0.6, elevation=0.4, ortho=False, fill=1.8):
    centre = obj.matrix_world @ (sum((Vector(c) for c in obj.bound_box), Vector()) / 8)
    size = max(obj.dimensions)
    return dict(target=tuple(centre), distance=size * fill / math.tan(FOV / 2) * 0.5 + size * 0.5,
                azimuth=azimuth, elevation=elevation, fov_y=FOV, ortho=ortho, near=0.05, far=1000.0)


def points(cam, a, b, count):
    pa, pb = app_project(cam, a), app_project(cam, b)
    return [(pa[0] + (pb[0] - pa[0]) * i / (count - 1), pa[1] + (pb[1] - pa[1]) * i / (count - 1),
             1.0, i / 60.0) for i in range(count)]


def literal(pts):
    """SculptBpy.chunk's list, for these points."""
    return ", ".join("(%.3f, %.3f, %.4f, %.4f)" % p for p in pts)


def stroke(name, cam, pts, per_chunk=4, mode="NORMAL"):
    """Begin, chunks and end, as SculptStrokeInput sends them."""
    begin = answer("BEGIN" if mode == "NORMAL" else "BEGIN_INVERT", object=name,
                   camera=camera_literal(cam))
    chunks = [answer("CHUNK", points=literal(pts[i:i + per_chunk]))
              for i in range(0, len(pts), per_chunk)]
    end = answer("END")
    return begin, chunks, end


# --------------------------------------------------------------------------
# Reading the mesh

def obj(name):
    return bpy.data.objects[name]


def positions(name):
    o = obj(name)
    if o.mode == 'SCULPT' and (o.use_dynamic_topology_sculpting
                               or any(m.type == 'MULTIRES' for m in o.modifiers)):
        bpy.ops.ed.flush_edits()
    values = array('f', [0.0]) * (3 * len(o.data.vertices))
    o.data.vertices.foreach_get('co', values)
    return values


def evaluated(name):
    o = obj(name)
    o.data.update_tag()
    e = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
    m = e.to_mesh()
    values = array('f', [0.0]) * (3 * len(m.vertices))
    m.vertices.foreach_get('co', values)
    e.to_mesh_clear()
    return values


def attribute(name, key, domain):
    values = sculpt._attribute_values(obj(name).data, key, domain)
    return list(values) if values is not None else None


def moved(a, b):
    """(vertices moved, the furthest), or (-1, inf) when the counts differ."""
    if len(a) != len(b):
        return (-1, float("inf"))
    count, most = 0, 0.0
    for i in range(0, len(a), 3):
        d = math.sqrt((a[i] - b[i]) ** 2 + (a[i + 1] - b[i + 1]) ** 2 + (a[i + 2] - b[i + 2]) ** 2)
        if d > 1e-6:
            count += 1
        most = max(most, d)
    return (count, most)


def colours(name):
    """The active colour attribute, which the paint brushes write."""
    layer = obj(name).data.color_attributes.active_color
    if layer is None:
        return None
    values = array('f', [0.0]) * (4 * len(layer.data))
    layer.data.foreach_get('color', values)
    return list(values)


def snapshot(name):
    """The mesh, the mask, the face sets and the colours, as Blender holds
    them. No mask reads as zeros, no face sets as every face in set 1 and no
    colour layer as white: what Blender treats them as."""
    count = len(obj(name).data.vertices)
    faces = len(obj(name).data.polygons)
    mask = attribute(name, '.sculpt_mask', 'POINT') or [0.0] * count
    sets = attribute(name, '.sculpt_face_set', 'FACE') or [1] * faces
    colour = colours(name)
    return (positions(name), mask, sets, colour)


def same(a, b, tolerance=1e-5):
    if len(a[0]) != len(b[0]) or moved(a[0], b[0])[1] > tolerance:
        return False
    for x, y in ((a[1], b[1]), (a[2], b[2])):
        if len(x) != len(y) or max((abs(p - q) for p, q in zip(x, y)), default=0) > tolerance:
            return False
    if a[3] is not None and b[3] is not None:
        if len(a[3]) != len(b[3]) or max((abs(p - q) for p, q in zip(a[3], b[3])), default=0) > tolerance:
            return False
    elif (a[3] or b[3]) and any(abs(v - 1.0) > tolerance for v in (a[3] or b[3])):
        return False
    return True


def fresh(name="Ball", segments=64, rings=32, location=(0, 0, 0)):
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=1,
                                         location=location)
    bpy.context.object.name = name
    return bpy.context.object.name


def select(name):
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    obj(name).select_set(True)
    bpy.context.view_layer.objects.active = obj(name)


def enter(name):
    select(name)
    run("ENTER")
    push("Sculpt Mode")
    return obj(name).mode


# --------------------------------------------------------------------------
print("\nThe strings, and the view")

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
ball = fresh()
first = push("Original")
check("the history's first push runs Blender's undo", first["mode"] == "blender", first)
check("the Swift's camera is the dict begin() reads",
      set(eval(blocks["CAMERA"], {}).keys()) == {"target", "distance", "azimuth", "elevation",
                                                  "fov_y", "ortho", "near", "far"},
      blocks["CAMERA"])
check("a Sculpt Mode entry runs Blender's own mode_set", enter(ball) == 'SCULPT')

window, area, region = sculpt._knife.view3d()
space = area.spaces.active
from bpy_extras import view3d_utils
for label, cam in (("perspective", camera_on(obj(ball))),
                   ("orthographic", camera_on(obj(ball), ortho=True)),
                   ("straight down", camera_on(obj(ball), azimuth=0.0, elevation=math.pi / 2)),
                   ("from below, turned", camera_on(obj(ball), azimuth=2.5, elevation=-0.9))):
    with bpy.context.temp_override(window=window, area=area, region=region):
        mapped = sculpt.aim(space, space.region_3d, region, cam, VIEW)
        worst = 0.0
        for p in ((0.3, 0.2, 0.9), (-0.8, 0.1, 0.4), (0.1, -0.9, -0.2), (0.7, 0.7, 0.0)):
            want = view3d_utils.location_3d_to_region_2d(region, space.region_3d, Vector(p))
            got = sculpt.to_region(app_project(cam, p), mapped)
            worst = max(worst, abs(want.x - got[0]), abs(want.y - got[1]))
    check("%s: where the app draws a point is where Blender's aimed view does (%.5f px)"
          % (label, worst), worst < 0.01, worst)
check("a 1100 x 800 point view fits Blender's region one pixel to a point",
      mapped[0] == 1.0, mapped)
for i, case in enumerate(json.loads(blocks["PROJECTIONS"])):
    swift_camera = eval(case["camera"], {})
    with bpy.context.temp_override(window=window, area=area, region=region):
        mapped = sculpt.aim(space, space.region_3d, region, swift_camera, VIEW)
        worst = 0.0
        for wx, wy, wz, vx, vy in case["points"]:
            want = view3d_utils.location_3d_to_region_2d(region, space.region_3d, Vector((wx, wy, wz)))
            got = sculpt.to_region((vx, vy), mapped)
            worst = max(worst, abs(want.x - got[0]), abs(want.y - got[1]))
    check("ViewportCamera %d (%s): a point where the Swift draws it is where Blender's aimed "
          "view does (%.4f px)" % (i + 1, "ortho" if swift_camera["ortho"] else "persp", worst),
          worst < 0.05, worst)

# --------------------------------------------------------------------------
print("\nRefusals: each a sentence, none a crash")

cam = camera_on(obj(ball))
line = points(cam, (-0.5, -0.6, 0.6), (0.5, -0.6, 0.6), 24)
bpy.ops.object.mode_set(mode='OBJECT')
said = refused("BEGIN", object=ball, camera=camera_literal(cam))
check("object mode: refused", said is not None and "Sculpt Mode" in said, said)
bpy.ops.object.camera_add(location=(0, -8, 0))
lens = bpy.context.object.name
said = refused("BEGIN", object=lens, camera=camera_literal(cam))
check("a camera: refused, by name", said is not None and "meshes" in said and lens in said, said)
bpy.data.objects.remove(obj(lens))
select(ball)
bpy.ops.object.mode_set(mode='SCULPT')
push("Sculpt Mode")
found = []
worker = threading.Thread(target=lambda: found.append(refused("BEGIN", object=ball,
                                                              camera=camera_literal(cam))))
worker.start()
worker.join()
check("a worker thread: refused, and the main thread's context kept",
      found and found[0] is not None and "main thread" in found[0]
      and bpy.context.window is not None, found)
answer("BEGIN", object=ball, camera=camera_literal(cam))
answer("CHUNK", points=literal(line[:4]))
bpy.ops.object.mode_set(mode='OBJECT')
said = refused("CHUNK", points=literal(line[4:8]))
check("leaving Sculpt Mode part way through a stroke: the next chunk is refused",
      said is not None and "left Sculpt Mode" in said, said)
ended = answer("END")
check("and the stroke ends with what it made kept as its steps", ended["pushed"] >= 1, ended)
push("Draw Brush")
bpy.ops.object.mode_set(mode='SCULPT')
push("Sculpt Mode")

# --------------------------------------------------------------------------
print("\nA Draw stroke: Blender's one stroke, one step")

base = snapshot(ball)
results = {}
for per in (24, 8, 4, 1):
    begin, chunks, end = stroke(ball, cam, line, per_chunk=per)
    results[per] = (positions(ball), end)
    push("Draw Brush")
    undo()
check("streamed in chunks of 8, 4 and 1 point, the result is the one stroke's to the bit",
      all(moved(results[24][0], results[p][0]) == (0, 0.0) for p in (8, 4, 1)),
      {p: moved(results[24][0], results[p][0]) for p in (8, 4, 1)})
check("and the stroke moved vertices", moved(base[0], results[24][0])[0] > 20,
      moved(base[0], results[24][0]))
check("each is one of Blender's undo steps (and its zero-strength anchor), counted from the stack",
      all(results[p][1]["counted"] and results[p][1]["pushed"] in (1, 2) for p in results),
      {p: results[p][1] for p in results})
check("Undo took each back to the vertex", same(base, snapshot(ball)))
begin, chunks, end = stroke(ball, cam, line, per_chunk=4)
after = snapshot(ball)
state = push(end.get("step", "Sculpt"))
check("the history records it as one step as deep as Blender's, under Blender's own name for it",
      undo_module._steps[-1]["depth"] == end["pushed"] and end.get("step") == "Draw Brush"
      and state["undo_label"] == "Draw Brush", (undo_module._steps[-1], end))
undo()
check("one Undo: the mesh before the stroke", same(base, snapshot(ball)))
redo()
check("one Redo: the mesh after it", same(after, snapshot(ball)))
check("still in Sculpt Mode after both", obj(ball).mode == 'SCULPT')
e = obj(ball).evaluated_get(bpy.context.evaluated_depsgraph_get())
m = e.to_mesh()
stale = array('f', [0.0]) * (3 * len(m.vertices))
m.vertices.foreach_get('co', stale)
e.to_mesh_clear()
print("        the evaluated mesh after the Redo, not refreshed: %d vertices off the mesh, by %.4f"
      % moved(positions(ball), stale), flush=True)
sculpt.refresh_evaluated(obj(ball))
e = obj(ball).evaluated_get(bpy.context.evaluated_depsgraph_get())
m = e.to_mesh()
fresh_read = array('f', [0.0]) * (3 * len(m.vertices))
m.vertices.foreach_get('co', fresh_read)
e.to_mesh_clear()
check("refreshed as the mirroring pass refreshes it, the evaluated mesh is the mesh",
      moved(positions(ball), fresh_read) == (0, 0.0), moved(positions(ball), fresh_read))
begin, chunks, end = stroke(ball, cam, line, per_chunk=4, mode="INVERT")
push("Draw Brush")
inverted = positions(ball)
check("Invert digs where Draw raised (the vertices move back toward the centre)",
      sum(Vector(inverted[i:i + 3]).length for i in range(0, len(inverted), 3))
      < sum(Vector(after[0][i:i + 3]).length for i in range(0, len(after[0]), 3)))

# --------------------------------------------------------------------------
print("\nA Line stroke is spaced, as Blender's is")

# Blender's line end adds a dab at the start and spaces the rest to the end
# (paint_stroke_line_end calls paint_space_stroke); the module sent the
# line's two ends alone (round 4's review).
before_line = positions(ball)
method = sculpt._brush().stroke_method
sculpt._brush().stroke_method = 'LINE'
try:
    begin, chunks, end = stroke(ball, cam, line, per_chunk=4)
    push(end.get("step", "Draw Brush"))
    line_moved = moved(before_line, positions(ball))[0]
    undo()
finally:
    sculpt._brush().stroke_method = method
window, area, region = sculpt._knife.view3d()
with bpy.context.temp_override(window=window, area=area, region=region):
    mapped = sculpt.aim(area.spaces.active, area.spaces.active.region_3d, region, cam, VIEW)
    first, last = sculpt.to_region(line[0], mapped), sculpt.to_region(line[-1], mapped)
step = max(1.0, max(1.0, sculpt._size_owner().size / 2.0) * sculpt._brush().spacing / 50.0)
expected = 1 + int(math.hypot(last[0] - first[0], last[1] - first[1]) // step)
check("a Line of %.0f px at a %.1f px spacing sends %d dabs, Blender's spacing from the start (%d), and "
      "moves %d vertices" % (math.hypot(last[0] - first[0], last[1] - first[1]), step, end["dabs"], expected,
                             line_moved),
      end["strategy"] == 'line' and end["dabs"] == expected > 2 and line_moved > 20, end)
check("Undo takes it back", moved(before_line, positions(ball))[0] == 0)

# --------------------------------------------------------------------------
print("\nGrab past the silhouette, and a Snake Hook long enough to be cut")

run("ACTIVATE", brush="Grab")
side = camera_on(obj(ball), azimuth=0.0, elevation=0.0)
before = snapshot(ball)
begin, chunks, end = stroke(ball, side, points(side, (0.95, -0.2, 0.0), (1.7, -0.2, 0.0), 20), per_chunk=3)
push("Draw Brush")
furthest = max(positions(ball)[i] for i in range(0, len(positions(ball)), 3))
check("Grab is streamed anchored: [first dab, current dab] each chunk",
      begin["strategy"] == "anchored", begin)
check("dragged past the silhouette it keeps pulling (x from 1.0 to %.3f)" % furthest,
      furthest > 1.15, furthest)
check("as one of Blender's steps", end["pushed"] in (1, 2) and end["counted"], end)
undo()
check("Undo: back to the vertex", same(before, snapshot(ball)))
redo()
run("ACTIVATE", brush="Snake Hook")
before = snapshot(ball)
long = points(cam, (-0.6, -0.7, 0.3), (0.6, -0.7, 0.3), 90)
sculpt.REPLAY_BUDGET_MS, budget = 0.0, sculpt.REPLAY_BUDGET_MS
begin, chunks, end = stroke(ball, cam, long, per_chunk=6)
sculpt.REPLAY_BUDGET_MS = budget
push("Draw Brush")
check("a replay over budget is cut, and goes on as a new stroke (%d cuts)" % end["cuts"],
      end["cuts"] >= 2 and moved(before[0], positions(ball))[0] > 0, end)
check("every piece is counted into the one step", undo_module._steps[-1]["depth"] == end["pushed"]
      and end["counted"], (undo_module._steps[-1], end))
undo()
check("one Undo takes all the pieces back", same(before, snapshot(ball)))
redo()

# --------------------------------------------------------------------------
print("\nEvery Essentials brush")

names = answer("BRUSHES")
check("Blender's Essentials sculpt brushes are listed (%d)" % len(names), len(names) >= 60, names)
bpy.ops.object.mode_set(mode='OBJECT')
sweep = fresh("Sweep", segments=48, rings=24, location=(4, 0, 0))
push("Add Sweep")
enter(sweep)
sweep_cam = camera_on(obj(sweep))
path = points(sweep_cam, (3.5, -0.8, 0.5), (4.5, -0.8, 0.5), 16)
broken, lost, unchanged, refusals = [], [], [], []
for name in names:
    print("        " + name, flush=True)
    run("ACTIVATE", brush=name)
    before = snapshot(sweep)
    try:
        begin, chunks, end = stroke(sweep, sweep_cam, path, per_chunk=4)
    except RuntimeError as error:
        (refusals if "multiresolution mode" in str(error) else broken).append((name, str(error)))
        continue
    after = snapshot(sweep)
    if end["pushed"]:
        push("Draw Brush")
        undo()
        if not same(before, snapshot(sweep)):
            lost.append((name, "undo"))
        redo()
        if not same(after, snapshot(sweep)):
            lost.append((name, "redo"))
        # Every brush strokes the same sphere: one brush's mask would hold the
        # next ones still.
        undo()
    if same(before, after):
        unchanged.append(name)
check("every brush strokes without an error", not broken, broken)
check("Multires's two brushes are refused on a mesh with no Multires level, in a sentence "
      "(desktop 5.2.1 segfaulted on Erase Multires Displacement there)",
      sorted(n for n, _ in refusals) == ["Erase Multires Displacement", "Smear Multires Displacement"],
      refusals)
check("Undo and Redo give back every brush's mesh, mask, face sets and colours", not lost, lost)
changed = set(names) - set(unchanged) - {n for n, _ in refusals}
core = {"Draw", "Draw Sharp", "Clay", "Clay Strips", "Clay Thumb", "Crease Polish", "Crease Sharp",
        "Blob", "Inflate/Deflate", "Smooth", "Flatten/Contrast", "Layer", "Pinch/Magnify", "Grab",
        "Snake Hook", "Pull", "Elastic Grab", "Thumb", "Nudge", "Mask", "Face Set Paint",
        "Paint Hard", "Pose", "Drag Cloth"}
check("the core brushes each change the sphere", core <= changed, sorted(core - changed))
print("        changed nothing on a closed sphere stroked across its front: " + ", ".join(unchanged),
      flush=True)

# --------------------------------------------------------------------------
print("\nEvery brush with the mesh's X, Y and Z symmetry on")

# The 3D View's mirror row writes the mesh's own flags (`use_mirror_x/y/z`),
# and Blender's brushes read them there: nothing the stroke sends changes.
# A tap away now, so held here — measured in desktop 5.2.1 before the row
# shipped, every brush that strokes the sphere above stroked with all three
# on and none crashed, and Draw moved 168 vertices, 84 of them on the -X side.
bpy.ops.object.mode_set(mode='OBJECT')
mirrored = fresh("Mirrored", segments=48, rings=24, location=(0, -4, 0))
for flag in ("use_mirror_x", "use_mirror_y", "use_mirror_z"):
    setattr(obj(mirrored).data, flag, True)
push("Add Mirrored")
enter(mirrored)
mirrored_cam = camera_on(obj(mirrored))
mirrored_path = points(mirrored_cam, (0.3, -4.8, 0.5), (0.7, -4.8, 0.3), 16)
broken, one_sided = [], []
for name in names:
    print("        mirrored: " + name, flush=True)
    run("ACTIVATE", brush=name)
    before = positions(mirrored)
    try:
        begin, chunks, end = stroke(mirrored, mirrored_cam, mirrored_path, per_chunk=4)
    except RuntimeError as error:
        if "multiresolution mode" not in str(error):
            broken.append((name, str(error)))
        continue
    after = positions(mirrored)
    # On the mirrored side: the mesh's own -X, where the path never goes.
    far = sum(1 for i in range(0, len(before), 3) if before[i] < -0.05
              and abs(after[i] - before[i]) + abs(after[i + 1] - before[i + 1]) + abs(after[i + 2] - before[i + 2]) > 1e-6)
    if name in core and moved(before, after)[0] > 0 and far == 0:
        one_sided.append(name)
    if end["pushed"]:
        push("Draw Brush")
        undo()
check("every brush strokes with X, Y and Z symmetry on, none crashes", not broken, broken)
check("each core brush that moves the sphere moves its mirror image too", not one_sided, one_sided)
# The sections below go on with the first sphere.
enter(sweep)

# --------------------------------------------------------------------------
print("\nThe brush's Size and Strength, written and read back")

run("ACTIVATE", brush="Draw")
run("SIZE_80")
run("STRENGTH_0.8")
state = answer("STATE")
check("Size reads back as written (80 px), in the unified setting Blender uses",
      state["size"] == 80 and state["unified_size"] and
      bpy.context.scene.tool_settings.sculpt.unified_paint_settings.size == 80, state)
check("Strength reads back as written (0.8), on the brush Blender uses",
      abs(state["strength"] - 0.8) < 1e-4 and not state["unified_strength"], state)
check("the brush is Blender's Draw, from the Essentials", state["brush"] == "Draw"
      and state["strategy"] == "replay", state)

# --------------------------------------------------------------------------
print("\nDynamic Topology")

before = snapshot(sweep)
count = len(before[0])
run("DYNTOPO_ON")
push("Dynamic Topology Toggle")
check("on", obj(sweep).use_dynamic_topology_sculpting)
run("DETAIL_6")
check("the Relative detail size reads back", abs(answer("STATE")["detail_size"] - 6) < 1e-4)
begin, chunks, end = stroke(sweep, sweep_cam, path, per_chunk=4)
push("Draw Brush")
check("a stroke under it changes the topology (%d -> %d vertices)" % (count, len(positions(sweep))),
      len(positions(sweep)) != count)
check("the viewport's mesh follows (the evaluated mesh, flushed)",
      len(evaluated(sweep)) == len(positions(sweep)))
undo()
check("Undo: the stroke's topology back", len(positions(sweep)) == count)
undo()
check("Undo: Dynamic Topology off again", not obj(sweep).use_dynamic_topology_sculpting)
redo()
redo()
check("Redo, Redo: on, and the stroke back",
      obj(sweep).use_dynamic_topology_sculpting and len(positions(sweep)) != count)

# A stroke over a Global Undo step: a labelled change made in Sculpt Mode, or
# the history's first step after a relaunch. Round 3's review measured
# Dynamic Topology turned off at the stroke's second chunk: its rewind landed
# on the memfile step, which comes back without the dynamic topology mesh, and
# the rest of the stroke replayed without it. The stroke's anchor dab (zero
# strength, detail at Manual) now puts a Sculpt step under it to rewind onto,
# and that step joins the labelled change's history step
# (`_blenderkit_undo.join_current`), so the stroke's Undo stops on it too.
def over_labelled(label):
    """A Draw stroke over a labelled change, then Undo and Redo of it, and of
    the labelled change under it: what each left."""
    push(label)
    below = sculpt._below_is_sculpt_step()
    state = answer("STATE")
    labelled = len(positions(sweep))
    under = undo_module._index
    answer("BEGIN", object=sweep, camera=camera_literal(sweep_cam))
    on_each_chunk = []
    for i in range(0, len(path), 4):
        answer("CHUNK", points=literal(path[i:i + 4]))
        on_each_chunk.append(obj(sweep).use_dynamic_topology_sculpting)
    end = answer("END")
    push("Draw Brush")
    made = len(positions(sweep))
    seen = dict(below=below, labelled=labelled, made=made, chunks=on_each_chunk, end=end,
                detail=bpy.context.scene.tool_settings.sculpt.detail_type_method,
                index=(under, undo_module._index))
    undo()
    seen["undo"] = (len(positions(sweep)), obj(sweep).use_dynamic_topology_sculpting, undo_module._index)
    redo()
    seen["redo"] = (len(positions(sweep)), obj(sweep).use_dynamic_topology_sculpting, undo_module._index)
    undo()
    undo()
    seen["undo_both"] = (len(positions(sweep)), obj(sweep).mode, undo_module._index)
    redo()
    redo()
    seen["redo_both"] = (len(positions(sweep)), obj(sweep).mode, obj(sweep).use_dynamic_topology_sculpting,
                         undo_module._index)
    return seen


def round3_anchor(stroke):
    """Round 3's anchor under dynamic topology, for the negative control: a
    zero-strength dab with the detail method at Manual, counted into the
    stroke."""
    brush, owner = sculpt._brush(), sculpt._strength_owner()
    settings = bpy.context.scene.tool_settings.sculpt
    saved, smooth, detail = owner.strength, brush.auto_smooth_factor, settings.detail_type_method
    owner.strength, brush.auto_smooth_factor, settings.detail_type_method = 0.0, 0.0, 'MANUAL'
    try:
        pushed = sculpt._run(stroke, sculpt._stroke_elements([stroke['open'][-1]], stroke['location']),
                             stroke['location'] is None)
    finally:
        owner.strength, brush.auto_smooth_factor, settings.detail_type_method = saved, smooth, detail
    if not pushed:
        return None
    stroke['pushed'] += 1
    return True


# The negative control first: the module as round 3 left it, the anchor a
# zero-strength dab counted into the stroke, gives back what the review
# measured.
detail_before = bpy.context.scene.tool_settings.sculpt.detail_type_method
anchored = sculpt._anchor_dyntopo
sculpt._anchor_dyntopo = round3_anchor
try:
    old = over_labelled("Labelled change")
finally:
    sculpt._anchor_dyntopo = anchored
check("negative control: with round 3's anchor, the stroke's Undo turns Dynamic Topology off "
      "(%d vertices, %s) and the Redo has no stroke to give back (%d, the stroke made %d)"
      % (old["undo"][0], old["undo"][1], old["redo"][0], old["made"]),
      old["undo"][1] is False and old["redo"][0] != old["made"], old)
if not obj(sweep).use_dynamic_topology_sculpting:
    run("DYNTOPO_ON")
    push("Dynamic Topology Toggle")
seen = over_labelled("Labelled change")
check("precondition: the step under the next stroke is a Global Undo step", seen["below"] is False, seen)
check("over it, Dynamic Topology stays on through every chunk (%d chunks)" % len(seen["chunks"]),
      len(seen["chunks"]) >= 3 and all(seen["chunks"]), seen["chunks"])
check("and the stroke changed the topology (%d -> %d vertices)" % (seen["labelled"], seen["made"]),
      seen["made"] != seen["labelled"])
check("the detail method is put back after the anchor's dab", seen["detail"] == detail_before, seen["detail"])
check("the stroke is one history step above the labelled change (%d -> %d)" % seen["index"],
      seen["index"][1] == seen["index"][0] + 1, seen["index"])
check("Undo of the stroke: the topology from before it (%d vertices), Dynamic Topology still on"
      % seen["undo"][0], seen["undo"][0] == seen["labelled"] and seen["undo"][1] is True
      and seen["undo"][2] == seen["index"][0], seen["undo"])
check("Redo: the stroke back (%d vertices), Dynamic Topology still on" % seen["redo"][0],
      seen["redo"][0] == seen["made"] and seen["redo"][1] is True and seen["redo"][2] == seen["index"][1],
      seen["redo"])
check("Undo, Undo: one step each, past the labelled change, still in Sculpt Mode (index %d)"
      % seen["undo_both"][2], seen["undo_both"][2] == seen["index"][0] - 1
      and seen["undo_both"][1] == 'SCULPT', seen["undo_both"])
check("Redo, Redo: the stroke back again (%d vertices, index %d)" % (seen["redo_both"][0], seen["redo_both"][3]),
      seen["redo_both"][0] == seen["made"] and seen["redo_both"][3] == seen["index"][1], seen["redo_both"])
check("and Dynamic Topology on again after it: the Redo crossed the labelled change's memfile step, "
      "and the anchor's Dynamic Topology Toggle rebuilt the mesh the stroke replays onto",
      seen["redo_both"][2] is True, seen["redo_both"])
if not obj(sweep).use_dynamic_topology_sculpting:
    run("DYNTOPO_ON")
    push("Dynamic Topology Toggle")
run("ACTIVATE", brush="Paint Hard")
said = refused("BEGIN", object=sweep, camera=camera_literal(sweep_cam))
check("Paint Hard is refused under it, in Blender's words (desktop 5.2.1 aborted)",
      said is not None and "dynamic topology mode" in said, said)
run("ACTIVATE", brush="Draw")
run("DYNTOPO_OFF")
push("Dynamic Topology Toggle")
check("off", not obj(sweep).use_dynamic_topology_sculpting)

# --------------------------------------------------------------------------
print("\nVoxel Remesh and Multires")

before = snapshot(sweep)
run("VOXEL_0.05")
check("the voxel size reads back", abs(answer("STATE")["voxel_size"] - 0.05) < 1e-6)
run("VOXEL_REMESH")
push("Voxel Remesh")
remeshed = len(positions(sweep))
check("Voxel Remesh from Sculpt Mode remeshes (%d -> %d vertices)" % (len(before[0]) // 3, remeshed // 3),
      remeshed != len(before[0]) and obj(sweep).mode == 'SCULPT')
undo()
check("one Undo: the mesh before it", same(before, snapshot(sweep)))
redo()
check("Redo: remeshed again", len(positions(sweep)) == remeshed)
undo()
bpy.ops.object.mode_set(mode='OBJECT')
cube = fresh("Orb", segments=24, rings=12, location=(-4, 0, 0))
push("Add Orb")
enter(cube)
before = evaluated(cube)
run("MULTIRES")
push("Multires Subdivide")
state = answer("STATE")
check("Multires Subdivide adds the modifier and a level, back in Sculpt Mode",
      state["multires"] is not None and state["multires"]["total_levels"] == 1
      and obj(cube).mode == 'SCULPT', state)
run("MULTIRES")
push("Multires Subdivide")
check("again: a second level", answer("STATE")["multires"]["total_levels"] == 2)
# The Modifiers panel's budget holds here too (_blenderkit_multires): each
# press is four times the mesh. Shown with the budget lowered to this level's
# count, so the next press passes it.
_blenderkit_multires = sys.modules["_blenderkit_multires"]
kept_budget = _blenderkit_multires.BUDGET
_blenderkit_multires.BUDGET = _blenderkit_multires.level_vertices(obj(cube).data, 2)
try:
    said = refused("MULTIRES")
finally:
    _blenderkit_multires.BUDGET = kept_budget
check("a Subdivide past the budget is refused in words, makes no level and stays in Sculpt Mode",
      said is not None and "so it does not run out of memory" in said
      and answer("STATE")["multires"]["total_levels"] == 2 and obj(cube).mode == 'SCULPT', said)
cube_cam = camera_on(obj(cube))
base = evaluated(cube)
levels = sculpt.multires_display(obj(cube))
check("in Sculpt Mode the evaluated mesh is Multires's base (%d vertices), the level Blender "
      "draws is read from a temporary object (%d)" % (len(base) // 3, len(levels[0]) // 3),
      len(levels[0]) > len(base), (len(base), len(levels[0])))
begin, chunks, end = stroke(cube, cube_cam, points(cube_cam, (-4.5, -0.9, 0.2), (-3.5, -0.9, 0.2), 16))
push("Draw Brush")
drawn = sculpt.multires_display(obj(cube))
check("a stroke on the Multires level shows in the level the viewport draws",
      moved(levels[0], drawn[0])[0] > 0 and moved(base, evaluated(cube))[0] == 0,
      (moved(levels[0], drawn[0]), moved(base, evaluated(cube))))
for name in ("Erase Multires Displacement", "Smear Multires Displacement", "Mask"):
    run("ACTIVATE", brush=name)
    said = None
    try:
        stroke(cube, cube_cam, points(cube_cam, (-4.5, -0.9, -0.2), (-3.5, -0.9, -0.2), 12))
        push("Draw Brush")
    except RuntimeError as error:
        said = str(error)
    check("%s strokes on the Multires level%s" % (name, " (its grid mask made first: desktop 5.2.1 "
          "crashed on a Mask stroke without it)" if name == "Mask" else ""), said is None, said)
for name in ("Paint Hard", "Blur"):
    run("ACTIVATE", brush=name)
    said = refused("BEGIN", object=cube, camera=camera_literal(cube_cam))
    check("%s is refused on a Multires level, in Blender's words (desktop 5.2.1 aborted)" % name,
          said is not None and "multiresolution mode" in said, said)
run("ACTIVATE", brush="Draw")
for _ in range(6):
    undo()
check("Undo back past the strokes and Multires Subdivide: the sphere with no Multires", obj(cube).modifiers.get("Multires") is None
      and moved(before, evaluated(cube)) == (0, 0.0), [m.name for m in obj(cube).modifiers])
redo()
said = refused("DYNTOPO_ON")
check("Dynamic Topology is refused with Multires, in a sentence", said is not None and "Multires" in said, said)
said = refused("VOXEL_REMESH")
check("and so is Voxel Remesh", said is not None and "Multires" in said, said)
undo()

# --------------------------------------------------------------------------
print("\nMask and Face Sets")

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
enter(sweep)
before = snapshot(sweep)
run("MASK_FILL")
push("Mask Flood Fill")
check("Fill masks every vertex", answer("STATE")["masked"] == len(positions(sweep)) // 3)
run("ACTIVATE", brush="Draw")
held = positions(sweep)
begin, chunks, end = stroke(sweep, sweep_cam, path, per_chunk=4)
push("Draw Brush")
check("a Draw stroke moves nothing that is masked", moved(held, positions(sweep))[0] == 0,
      moved(held, positions(sweep)))
run("MASK_INVERT")
push("Mask Flood Fill")
check("Invert: nothing masked", answer("STATE")["masked"] == 0)
run("ACTIVATE", brush="Mask")
begin, chunks, end = stroke(sweep, sweep_cam, path, per_chunk=4)
push("Draw Brush")
masked = answer("STATE")["masked"]
check("the Mask brush masks what it strokes (%d vertices)" % masked, 0 < masked < len(held) // 3)
run("FACE_SET_FROM_MASK")
push("Create Face Set")
check("Face Set from Masked makes a second face set", answer("STATE")["face_sets"] == 2)
undo()
check("Undo: one face set", answer("STATE")["face_sets"] <= 1)
run("MASK_CLEAR")
push("Mask Flood Fill")
check("Clear: nothing masked", answer("STATE")["masked"] == 0)
undo()
check("Undo: the Mask brush's mask back", answer("STATE")["masked"] == masked)
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 5, 0))
first_part = bpy.context.object.name
bpy.ops.mesh.primitive_cube_add(size=1, location=(2, 5, 0))
bpy.context.object.select_set(True)
obj(first_part).select_set(True)
bpy.ops.object.join()
parts = bpy.context.object.name
push("Join")
enter(parts)
run("FACE_SETS_LOOSE_PARTS")
push("Init Face Sets")
check("Initialize by Loose Parts: two parts, two face sets", answer("STATE")["face_sets"] == 2)
for mode in ("MATERIALS", "NORMALS", "UV_SEAMS", "CREASES", "SHARP_EDGES"):
    said = refused("FACE_SETS_" + mode)
    check("Initialize %s runs" % mode.replace("_", " ").title(), said is None, said)
    push("Init Face Sets")

# --------------------------------------------------------------------------
print("\nEvery brush and operation under Dynamic Topology and on a Multires level")

# DYNTOPO_OFF last: before it, the Face Sets steps of the "dyntopo" fixture
# ran with Dynamic Topology already off (round 3's review).
FACE_SET_OPERATIONS = ["FACE_SETS_" + mode for mode in ("LOOSE_PARTS", "MATERIALS", "NORMALS",
                                                        "UV_SEAMS", "CREASES", "SHARP_EDGES")]
OPERATIONS = (["MASK_CLEAR", "MASK_INVERT", "MASK_FILL", "FACE_SET_FROM_MASK", "VOXEL_REMESH",
               "MULTIRES", "DYNTOPO_ON"] + FACE_SET_OPERATIONS + ["DYNTOPO_OFF"])


def fixture(kind):
    bpy.ops.object.mode_set(mode='OBJECT') if bpy.context.object and bpy.context.object.mode != 'OBJECT' else None
    name = fresh("Fixture " + kind, segments=24, rings=12, location=(0, 8, 0))
    push("Add")
    enter(name)
    if kind == "dyntopo":
        run("DYNTOPO_ON")
        push("Dynamic Topology Toggle")
    elif kind == "multires":
        run("MULTIRES")
        push("Multires Subdivide")
    return name


for kind in ("dyntopo", "multires"):
    name = fixture(kind)
    kind_cam = camera_on(obj(name))
    kind_path = points(kind_cam, (-0.5, 7.1, 0.3), (0.5, 7.1, 0.3), 12)
    ran, said = [], []
    for brush in names:
        print("        %s: %s" % (kind, brush), flush=True)
        run("ACTIVATE", brush=brush)
        try:
            stroke(name, kind_cam, kind_path, per_chunk=4)
            push("Draw Brush")
            ran.append(brush)
            # Back to the fixture as it was: under dynamic topology every
            # stroke adds detail, and 64 of them in a row made the cloth
            # brushes' constraints take minutes.
            undo()
        except RuntimeError as error:
            said.append((brush, str(error)))
    expected = ({"Erase Multires Displacement", "Smear Multires Displacement"} if kind == "dyntopo"
                else set())
    expected |= {b for b in names if b.startswith(("Paint", "Blend", "Airbrush"))
                 or b in ("Blur", "Smear", "Sharpen")}
    check("%s: every brush strokes or is refused in a sentence, none crashes (%d ran, %d refused)"
          % (kind, len(ran), len(said)), {b for b, _ in said} == expected,
          sorted(set(b for b, _ in said) ^ expected))
    for operation in OPERATIONS:
        print("        %s: %s" % (kind, operation), flush=True)
        name_now = bpy.context.view_layer.objects.active.name
        if bpy.context.view_layer.objects.active.mode != 'SCULPT':
            bpy.ops.object.mode_set(mode='SCULPT')
        said_now = refused(operation)
        if said_now is None:
            push(operation)
        # Blender's face set operators cancel under dynamic topology without a
        # word (sculpt_face_set.cc): refused here, saying so.
        refusals_expected = {
            "dyntopo": {"VOXEL_REMESH", "MULTIRES", "FACE_SET_FROM_MASK"} | set(FACE_SET_OPERATIONS),
            "multires": {"VOXEL_REMESH", "DYNTOPO_ON"},
        }[kind]
        if operation in refusals_expected and kind == "dyntopo" and "FACE_SET" in operation:
            check("%s: %s refused, saying Face Sets do not work under Dynamic Topology"
                  % (kind, operation), said_now is not None and "Dynamic Topology" in said_now, said_now)
        elif operation in refusals_expected:
            check("%s: %s refused in a sentence" % (kind, operation), said_now is not None, said_now)
        else:
            # FACE_SET_FROM_MASK comes right after MASK_FILL: everything is
            # masked, so "nothing is masked" is not a pass.
            check("%s: %s runs" % (kind, operation), said_now is None, said_now)
    bpy.ops.object.mode_set(mode='OBJECT')
    push("Object Mode")


# --------------------------------------------------------------------------
print("\nRound 3's review: Multires, strokes held open, Voxel Remesh, a reopened file")

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 20, 0))
bpy.context.object.name = "Box"
push("Add Box")
enter("Box")
run("MULTIRES")
push("Multires Subdivide")
run("MULTIRES")
push("Multires Subdivide")


def level(name):
    sculpt._display_cache.clear()
    return sculpt.multires_display(obj(name))[0]


check("a 2-level Multires cube: 98 level vertices", len(level("Box")) // 3 == 98, len(level("Box")) // 3)
check("the mask on a Multires level reads as unknown, not 0 (Blender keeps it in grids)",
      answer("STATE")["masked"] is None, answer("STATE"))
run("ACTIVATE", brush="Grab")
box_cam = camera_on(obj("Box"), azimuth=0.0, elevation=0.0)
before = level("Box")
begin, chunks, end = stroke("Box", box_cam, points(box_cam, (0.3, 19.0, 0.3), (0.3, 19.0, 0.9), 12),
                            per_chunk=3)
push("Draw Brush")
after = level("Box")
check("on Multires a stroke is gathered and made when it ends: no chunk runs Blender",
      begin["strategy"] == "deferred" and not any(c["applied"] for c in chunks), (begin, chunks))
check("a Grab anchors on the level Blender sculpts and moves it (%d level vertices, up to %.3f; "
      "the base mesh is hit 0.272 away, where it moved none)" % moved(before, after),
      moved(before, after)[0] > 0, end)
check("as one of Blender's steps", end["pushed"] == 1 and end["counted"], end)
undo()
check("Undo: the level back", moved(before, level("Box"))[1] < 1e-5)
redo()
check("Redo: the Grab again", moved(after, level("Box"))[1] < 1e-5)

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
heavy = fresh("Heavy", segments=128, rings=64, location=(6, 20, 0))
push("Add Heavy")
enter(heavy)
said = refused("MULTIRES")
check("Multires Subdivide on an 8,066-vertex base is refused, with the measured cost",
      said is not None and "2,000" in said and not obj(heavy).modifiers, said)
bpy.ops.object.mode_set(mode='OBJECT')
obj(heavy).modifiers.new("Multires", 'MULTIRES')
bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
push("Multires by script")
said = refused("ENTER")
check("Sculpt Mode's way in is refused for a Multires that heavy, before Blender enters",
      said is not None and "Sculpt level to 0" in said and obj(heavy).mode == 'OBJECT', said)
# A script line's mode_set is asked the same now (`_blenderkit_context.
# refuse_sculpt_entry`, round 4's review); a file saved in Sculpt Mode on the
# level still opens in it, which is entered here past that guard.
try:
    bpy.ops.object.mode_set(mode='SCULPT')
    said = None
except RuntimeError as error:
    said = str(error)
check("and so is a script line's mode_set", said is not None and "Sculpt level to 0" in said
      and obj(heavy).mode == 'OBJECT', said)
context_module = sys.modules["_blenderkit_context"]
real_entry = context_module.refuse_sculpt_entry
context_module.refuse_sculpt_entry = lambda *arguments: None
try:
    bpy.ops.object.mode_set(mode='SCULPT')
finally:
    context_module.refuse_sculpt_entry = real_entry
push("Sculpt Mode by script")
check("opened in Sculpt Mode anyway (as a file can be), its level is not read back",
      sculpt.multires_display(obj(heavy)) is None)
heavy_cam = camera_on(obj(heavy))
said = refused("BEGIN", object=heavy, camera=camera_literal(heavy_cam))
check("a stroke on it is refused in words", said is not None and "base mesh" in said, said)
said = refused("MASK_FILL")
check("and so is the header's Mask ▸ Fill", said is not None and "base mesh" in said, said)
obj(heavy).modifiers["Multires"].sculpt_levels = 0
check("at Sculpt level 0 its base mesh strokes", refused("BEGIN", object=heavy,
                                                       camera=camera_literal(heavy_cam)) is None)
run("END")
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")

held = fresh("Held", segments=64, rings=32, location=(-6, 20, 0))
push("Add Held")
enter(held)
run("ACTIVATE", brush="Draw")
run("MASK_CLEAR")
push("Mask Flood Fill")
held_cam = camera_on(obj(held))
held_line = points(held_cam, (-6.5, 19.4, 0.6), (-5.5, 19.4, 0.6), 24)
start = snapshot(held)
answer("BEGIN", object=held, camera=camera_literal(held_cam))
answer("CHUNK", points=literal(held_line[:4]))
said = None
try:
    undo()
except RuntimeError as error:
    said = str(error)
check("the history's Undo mid-stroke is refused (it used to undo, and the next chunk undid one "
      "more)", said is not None and "stroke" in said, said)
for block, fill in (("MASK_FILL", {}), ("ACTIVATE", {"brush": "Clay Strips"}), ("SIZE_80", {}),
                    ("FACE_SETS_LOOSE_PARTS", {})):
    said = refused(block, **fill)
    check("%s mid-stroke is refused in words" % block, said is not None and "stroke" in said, said)
for i in range(4, 24, 4):
    answer("CHUNK", points=literal(held_line[i:i + 4]))
end = answer("END")
state = push(end.get("step", "Sculpt"))
stroked = snapshot(held)
check("the stroke is one history step, named as Blender's history names it",
      state["undo_label"] == end.get("step") and end.get("step", "").endswith(" Brush")
      and undo_module._steps[-1]["depth"] == end["pushed"], (state, end))
undo()
check("one Undo: the mesh and the mask from before it", same(start, snapshot(held)))
redo()
check("one Redo: the stroke", same(stroked, snapshot(held)))
answer("BEGIN", object=held, camera=camera_literal(held_cam))
answer("CHUNK", points=literal(held_line[:4]))
bpy.ops.ed.undo()                          # past every guard, as nothing in the app can
said = refused("CHUNK", points=literal(held_line[4:8]))
check("when the history moves under a stroke anyway, the next chunk is refused rather than "
      "rewind a step that is not its own", said is not None and "moved" in said, said)
end = answer("END")
check("and its end records nothing it cannot account for", end["pushed"] == 0, end)
bpy.ops.ed.redo()
before = snapshot(held)
answer("BEGIN", object=held, camera=camera_literal(held_cam))
answer("CHUNK", points=literal(held_line[:8]))
answer("BEGIN", object=held, camera=camera_literal(held_cam))        # its END never came
answer("CHUNK", points=literal(held_line[8:16]))
end = answer("END")
push("Draw Brush")
check("a stroke whose end never came is counted into the next stroke's step (%d steps)" % end["pushed"],
      end["pushed"] >= 2 and end["counted"], end)
undo()
check("so one Undo takes both back", same(before, snapshot(held)))
redo()

# The zero-strength anchor dab, with a brush whose Auto-Smooth runs at any
# strength: Density's 0.1 moved 10 vertices by up to 0.003 before. An anchor is
# made only onto a step that is not a sculpt step, as right after entering
# Sculpt Mode.
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
enter(held)
run("ACTIVATE", brush="Density")
density = sculpt._brush()
answer("BEGIN", object=held, camera=camera_literal(held_cam))
open_stroke = sculpt._stroke
window, area, region = sculpt._knife.view3d()
space = area.spaces.active
pre = positions(held)
with bpy.context.temp_override(window=window, area=area, region=region):
    sculpt.aim(space, space.region_3d, region, open_stroke['camera'], open_stroke['view'])
    dab = sculpt.to_region(held_line[10], open_stroke['mapped']) + (1.0, 0.0)
    anchored = sculpt._anchor(open_stroke, dab)
check("the anchor dab moves nothing, Auto-Smooth and all (%d moved), and the brush keeps its "
      "Auto-Smooth (%.2f)" % (moved(pre, positions(held))[0], density.auto_smooth_factor),
      anchored is True and moved(pre, positions(held))[0] == 0 and density.auto_smooth_factor > 0,
      anchored)
answer("END")
push("Draw Brush")
undo()
run("ACTIVATE", brush="Draw")

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=100, location=(0, 26, 0))
bpy.context.object.scale = (0.01, 0.01, 0.01)
bpy.context.object.name = "Imported"
push("Add Imported")
enter("Imported")
said = refused("VOXEL_REMESH")
estimate = int(sculpt.remesh_estimate(obj("Imported").data, 0.1, 2_500_000)[0])
check("Voxel Remesh at Blender's default 0.1 on a 2 m model imported at scale 0.01 (200 of its own "
      "units across) is refused, in its own units (about %s vertices)" % format(estimate, ','),
      said is not None and "own units" in said and format(estimate, ',')[:6] in said
      and estimate > 2_500_000, said)
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
bpy.ops.mesh.primitive_plane_add(size=2, location=(4, 26, 0))
bpy.context.object.name = "Sheet"
push("Add Sheet")
enter("Sheet")
sculpt.set_voxel_size(0.0001)
said = refused("VOXEL_REMESH")
smallest = sculpt.remesh_smallest(obj("Sheet").data, 2_500_000)
check("a 2 m plane at the field's 0.0001 minimum (about 800 million vertices) is refused, "
      "naming the smallest size the budget allows (%.4g)" % smallest,
      said is not None and ("Use %.4g or larger" % smallest) in said
      and abs(sculpt.remesh_estimate(obj("Sheet").data, smallest)[0] / 2_500_000 - 1) < 1e-6, said)
for size in (0.02, 0.01):
    sculpt.set_voxel_size(size)
    estimate, _ = sculpt.remesh_estimate(obj("Sheet").data, size)
    run("VOXEL_REMESH")
    push("Voxel Remesh")
    made = len(obj("Sheet").data.vertices)
    check("at %g it remeshes, into %d vertices, under the guard's estimate of %d" % (size, made, estimate),
          0 < made <= estimate)
    undo()

# Thin and open shapes. OpenVDB rebuilds a feature thinner than a voxel as a
# tube or a blob about a voxel across, so area alone undercounted them: up to
# 53 times (round 4's measurements, REMESH_OFFSET). Each is remeshed by
# Blender here and held to the estimate; the old 2.5 x area / voxel squared
# is the negative control, under the count on every thin one.
import random, bmesh
bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")


def joined(name, add, count, seed):
    random.seed(seed)
    for _ in range(count):
        add(random)
    bpy.ops.object.select_all(action='DESELECT')
    made = [o for o in bpy.context.view_layer.objects if o.name.startswith("_bk_part")]
    for o in made:
        o.select_set(True)
    bpy.context.view_layer.objects.active = made[0]
    bpy.ops.object.join()
    bpy.context.object.name = name
    return bpy.context.object


def part(kind, **arguments):
    getattr(bpy.ops.mesh, "primitive_" + kind + "_add")(**arguments)
    bpy.context.object.name = "_bk_part"


shapes = {
    "rod": lambda: part("cylinder", radius=0.01, depth=2, location=(10, 0, 0)),
    "thin torus": lambda: part("torus", major_radius=1, minor_radius=0.01, location=(10, 4, 0)),
    "hair": lambda: joined("Hair", lambda r: part("cylinder", radius=0.004, depth=1.5, vertices=6,
                                                   location=(10 + r.uniform(-1, 1), 8 + r.uniform(-1, 1), 0),
                                                   rotation=(r.uniform(0, 3), r.uniform(0, 3), 0)), 30, 3),
    "dust": lambda: joined("Dust", lambda r: part("cube", size=0.004,
                                                   location=(10 + r.uniform(-1, 1), 12 + r.uniform(-1, 1),
                                                             r.uniform(-1, 1))), 200, 4),
    "leaves": lambda: joined("Leaves", lambda r: part("plane", size=0.2,
                                                       location=(10 + r.uniform(-1, 1), 16 + r.uniform(-1, 1),
                                                                 r.uniform(-1, 1)),
                                                       rotation=(r.uniform(0, 3), r.uniform(0, 3), 0)), 40, 5),
    "cube": lambda: part("cube", size=2, location=(14, 0, 0)),
    "sphere": lambda: part("uv_sphere", radius=1, location=(14, 4, 0)),
    "open tube": lambda: part("cylinder", radius=1, depth=2, end_fill_type='NOTHING', location=(14, 8, 0)),
}
under, over, old_under = [], [], []
for label, make in shapes.items():
    make()
    target = bpy.context.object
    for size in (0.1, 0.05):
        target.data.remesh_voxel_size = size
        estimate = sculpt.remesh_estimate(target.data, size)[0]
        area = sum(p.area for p in target.data.polygons)
        old = 2.5 * area / (size * size)
        copy = target.copy()
        copy.data = target.data.copy()
        bpy.context.scene.collection.objects.link(copy)
        bpy.ops.object.select_all(action='DESELECT')
        copy.select_set(True)
        bpy.context.view_layer.objects.active = copy
        bpy.ops.object.voxel_remesh()
        made = len(copy.data.vertices)
        bpy.data.objects.remove(copy)
        if made > estimate:
            under.append((label, size, made, int(estimate)))
        if label in ("cube", "sphere", "open tube") and estimate > 3.5 * made:
            over.append((label, size, made, int(estimate)))
        if label not in ("cube", "sphere", "open tube") and made > old:
            old_under.append((label, size, made, int(old)))
    # Out of the scene, so the next shape's parts are joined without it.
    mesh = target.data
    bpy.data.objects.remove(target)
    bpy.data.meshes.remove(mesh)
check("every thin, open and ordinary shape remeshes within its estimate (8 shapes, 2 sizes)", not under, under)
check("ordinary shapes are not overestimated past 3.5 times", not over, over)
check("negative control: the old 2.5 x area / voxel squared undercounts every thin shape "
      "(%d of 10 remeshes)" % len(old_under), len(old_under) == 10, old_under)
# Where it matters: a refusal near the budget. 30 rods 0.1 mm thick, 2 m
# long, at a 1 mm voxel, remeshed for real; then the same rods eleven times
# over, which area alone put under the budget and this does not.
rods = joined("Rods", lambda r: part("cylinder", radius=0.0001, depth=2, vertices=6,
                                     location=(18 + r.uniform(-1, 1), r.uniform(-1, 1), 0)), 30, 6)
rods.data.remesh_voxel_size = 0.001
estimate = sculpt.remesh_estimate(rods.data, 0.001)[0]
area_alone = 2.5 * sum(p.area for p in rods.data.polygons) / 0.001 ** 2
select("Rods")
bpy.ops.object.voxel_remesh()
made = len(rods.data.vertices)
check("30 rods of 0.1 mm at a 1 mm voxel: %d vertices, within the estimate of %d (area alone said %d)"
      % (made, estimate, area_alone), area_alone < made <= estimate, (made, estimate, area_alone))
# The refusal, at a budget the 30 rods pass: area alone would have let them
# through (the negative control), the estimate stops them.
import _blenderkit_multires
undo_module_budget = _blenderkit_multires.BUDGET
_blenderkit_multires.BUDGET = 100_000
try:
    # The same 30 rods again, not yet remeshed.
    again = joined("Rods Again", lambda r: part("cylinder", radius=0.0001, depth=2, vertices=6,
                                                location=(18 + r.uniform(-1, 1), r.uniform(-1, 1), 0)), 30, 6)
    again.data.remesh_voxel_size = 0.001
    before = len(again.data.vertices)
    said = None
    try:
        sculpt.refuse_voxel_remesh(again)
    except RuntimeError as error:
        said = str(error)
finally:
    _blenderkit_multires.BUDGET = undo_module_budget
check("at a budget of 100,000, those rods (%d vertices remeshed) are refused, where area alone (%d) "
      "would have let them through" % (made, area_alone),
      said is not None and "100,000" in said and area_alone < 100_000 < made and before < made, said)

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
smooth = fresh("Smooth", segments=16, rings=8, location=(-4, 26, 0))
obj(smooth).modifiers.new("Subdivision", 'SUBSURF').levels = 2
push("Add Smooth")
enter(smooth)
run("ACTIVATE", brush="Grab")
smooth_cam = camera_on(obj(smooth), azimuth=0.0, elevation=0.0)
window, area, region = sculpt._knife.view3d()
space = area.spaces.active
from mathutils.bvhtree import BVHTree
with bpy.context.temp_override(window=window, area=area, region=region):
    sculpt.aim(space, space.region_3d, region, smooth_cam, VIEW)
    dab = sculpt.to_region(app_project(smooth_cam, (-3.7, 25.0, 0.3)),
                           sculpt.mapping((region.width, region.height), VIEW))
    got = sculpt._surface_location(obj(smooth), region, space.region_3d, dab)
    inverse = obj(smooth).matrix_world.inverted()
    origin = inverse @ view3d_utils.region_2d_to_origin_3d(region, space.region_3d, dab)
    ray = (inverse.to_3x3() @ view3d_utils.region_2d_to_vector_3d(region, space.region_3d, dab)).normalized()
    base_tree = BVHTree.FromPolygons([v.co[:] for v in obj(smooth).data.vertices],
                                     [p.vertices[:] for p in obj(smooth).data.polygons])
    want = base_tree.ray_cast(origin, ray)[0]
check("with a Subdivision modifier a Grab starts on the base mesh Blender sculpts (%.6f off it)"
      % (got - want).length, got is not None and (got - want).length < 1e-5, (got, want))
# Begun at that sphere's silhouette and dragged far, Blender's Grab pushes
# nothing past about 270 px (desktop 5.2.1, under Subdivision only), and the
# chunk's rewind used to leave the mesh as it was before the stroke while the
# viewport showed the last chunk. The step is put back now.
far_view = (1194.0, 730.0)
far_cam = dict(target=(-4.0, 26.0, 0.0), distance=6.936, azimuth=0.60415244, elevation=0.4908738,
               fov_y=FOV, ortho=False, near=0.05, far=1000.0)
centre = app_project(far_cam, (-4.0, 26.0, 0.0), far_view)
far_points = [(centre[0] - 179 + 450 * i / 59, centre[1] + 14.6 * i / 59, 1.0, i / 60) for i in range(60)]
far_literal = lambda pts: ", ".join("(%.3f, %.3f, %.4f, %.4f)" % p for p in pts)
begin_far = blocks["BEGIN"].replace("(1100.000, 800.000)", "(1194.000, 730.000)")
assert begin_far != blocks["BEGIN"]
printed = io.StringIO()
with contextlib.redirect_stdout(printed):
    exec(compile(begin_far.replace("@OBJECT@", smooth).replace("@CAMERA@", camera_literal(far_cam)),
                 "<BEGIN far>", "exec"), namespace)
shown, mismatched, kept = positions(smooth), 0, 0
for i in range(0, 60, 2):
    result = answer("CHUNK", points=far_literal(far_points[i:i + 2]))
    now = positions(smooth)
    if result["applied"]:
        shown = now
    elif moved(shown, now)[1] > 1e-6:
        mismatched += 1
    kept += 1 if result.get("kept") else 0
end = answer("END")
push("Draw Brush")
check("a chunk whose replay makes nothing puts the rewound step back (%d such chunks): Blender "
      "holds what the viewport shows after every chunk, and at the end" % kept,
      kept > 0 and mismatched == 0 and moved(shown, positions(smooth))[1] < 1e-6, (kept, mismatched, end))

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
select(held)
bpy.ops.object.mode_set(mode='SCULPT')
push("Sculpt Mode")
saved = os.path.join(WORK, "sculpting.blend")
undo_module.autosave(saved)
bpy.ops.wm.open_mainfile(filepath=saved, load_ui=False)
window, area, region = sculpt._knife.view3d()
with bpy.context.temp_override(window=window, area=area, region=region):
    polled = bpy.ops.sculpt.brush_stroke.poll()
check("a file saved in Sculpt Mode opens with Blender's brush_stroke.poll() False",
      obj(held).mode == 'SCULPT' and not polled)
before = positions(held)
begin, chunks, end = stroke(held, held_cam, held_line)
check("and a stroke on it starts the brush tool, sculpts (%d moved) and is a step"
      % moved(before, positions(held))[0], moved(before, positions(held))[0] > 0 and end["pushed"] >= 1, end)
push("Draw Brush")

# --------------------------------------------------------------------------
print("\nWhat a chunk costs (desktop Blender, not the device)")

bpy.ops.object.mode_set(mode='OBJECT')
push("Object Mode")
big = fresh("Big", segments=256, rings=196, location=(0, -12, 0))
push("Add Big")
enter(big)
run("ACTIVATE", brush="Draw")
big_cam = camera_on(obj(big))
path = points(big_cam, (-0.6, -12.8, 0.4), (0.6, -12.8, 0.4), 120)
begin, chunks, end = stroke(big, big_cam, path, per_chunk=3)
push("Draw Brush")
costs = sorted(c["stroke_ms"] for c in chunks)
print("        Draw on %d triangles: %d chunks, %d dabs, %d cut(s); chunk %.1f ms median, %.1f max"
      % (len(obj(big).data.polygons) * 2, len(chunks), end["dabs"], end["cuts"],
         costs[len(costs) // 2], costs[-1]), flush=True)
check("a chunk on a 100k-triangle mesh stays under the budget's reach (%.1f ms)" % costs[-1],
      costs[-1] < 80, costs[-5:])
# Under Dynamic Topology the rewind is most of a chunk (45-54 ms of 80-105 on
# this mesh, round 3's review), and the budget counted only the replay. It
# counts the rewind now: after the first, every chunk is cut, and none rewinds.
run("DYNTOPO_ON")
push("Dynamic Topology Toggle")
begin, chunks, end = stroke(big, big_cam, path, per_chunk=3)
push("Draw Brush")
costs = sorted(c["stroke_ms"] for c in chunks)
rewinds = [c["undo_ms"] for c in chunks if c.get("undo_ms") is not None]
print("        Dynamic Topology on %d triangles: %d chunks, %d cut(s), %d rewind(s) of up to %.1f ms; "
      "chunk %.1f ms median, %.1f max" % (len(obj(big).data.polygons) * 2, len(chunks), end["cuts"],
                                          len(rewinds), max(rewinds or [0]), costs[len(costs) // 2],
                                          costs[-1]), flush=True)
# With no rewind at all (the first chunk already dear, so cut), every chunk
# that strokes is cut from the first; this used to count from the end of the
# list then, and passed on none at all ("0 of 0 cut", round 4's review).
stroked = [i for i, c in enumerate(chunks) if c["dabs"]]
rewound = next((i for i, c in enumerate(chunks) if c.get("undo_ms") is not None),
               stroked[0] if stroked else len(chunks))
after_rewind = [c for c in chunks[rewound:] if c["dabs"]]
check("under Dynamic Topology a dear rewind is paid once, and every chunk that strokes after it "
      "is cut rather than rewound (%d rewind, %d of %d cut)"
      % (len(rewinds), sum(1 for c in after_rewind if c.get("cut")), len(after_rewind)),
      len(rewinds) <= 1 and len(after_rewind) >= 2 and all(c.get("cut") for c in after_rewind),
      (rewinds, after_rewind[:3]))
check("and no chunk passes 80 ms (%.1f)" % costs[-1], costs[-1] < 80, costs[-5:])
run("DYNTOPO_OFF")
push("Dynamic Topology Toggle")

# --------------------------------------------------------------------------
print("\nAfter a file load has freed Blender's undo stack")

# A load frees Blender's undo stack, and the app's file-read guard makes it
# again at once (`_blenderkit_undo.ensure_stack`, round 4's review: a mask
# fill or Face Sets ▸ Initialize after a load segfaulted Blender,
# run-undostack-blender-check.sh). The stroke's own `_require_undo_stack` is
# what remains if that ever fails: the guard is switched off for this load so
# the stroke still meets no stack.
bpy.ops.wm.read_homefile(use_empty=True)
check("a load through the app's file-read guard leaves Blender with an undo stack",
      bool(undo_module.blender_steps()), undo_module.blender_steps())
_ensure_stack = undo_module.ensure_stack
undo_module.ensure_stack = lambda label: False
bpy.ops.wm.read_homefile(use_empty=True)
undo_module.ensure_stack = _ensure_stack
check("with the guard off, a load leaves Blender with no undo stack here", undo_module.blender_steps() == [],
      undo_module.blender_steps())
fresh("Again")
bpy.ops.object.mode_set(mode='SCULPT')
again_cam = camera_on(obj("Again"))
before = positions("Again")
begin, chunks, end = stroke("Again", again_cam, points(again_cam, (-0.5, -0.6, 0.6), (0.5, -0.6, 0.6), 16))
check("a stroke starts Blender's undo itself rather than segfaulting, and sculpts",
      bool(undo_module.blender_steps()) and moved(before, positions("Again"))[0] > 0, end)

# --------------------------------------------------------------------------
print("\nA relaunch under Dynamic Topology")

# The app opens its autosave with no undo stack, and the first stroke starts
# one with a Global Undo step. Round 3's review: Dynamic Topology went off at
# that stroke's second chunk, and the stroke changed no topology. And the
# stroke's Undo went down to the memfile step, where Dynamic Topology was off
# again and the Redo brought nothing back.
run("DYNTOPO_ON")
saved = os.path.join(WORK, "dyntopo.blend")
undo_module.autosave(saved)
# A relaunch is a new process: Blender has no undo stack, and its history has
# not probed Blender's undo yet; the probe waits while an object is in Sculpt
# Mode (`probe`). The load is made with the file-read guard off, so Blender
# comes back with no stack, as a new process does.
_ensure_stack = undo_module.ensure_stack
undo_module.ensure_stack = lambda label: False
bpy.ops.wm.open_mainfile(filepath=saved, load_ui=False)
undo_module.ensure_stack = _ensure_stack
check("precondition: reopened under Dynamic Topology with no undo stack",
      obj("Again").use_dynamic_topology_sculpting and undo_module.blender_steps() == [],
      undo_module.blender_steps())
# This Blender's history probed long ago; it is set back. The first push,
# its probe deferred, makes Blender's stack (`ensure_stack`, round 4's
# review): before it the first stroke did, and until then entering Sculpt
# Mode with its undo on, or a mask fill, segfaulted Blender. The stroke that
# follows has to keep Dynamic Topology on as it did when it made the stack.
undo_module._mode = None
push("Original")
check("precondition: the history's first push, its probe deferred, makes Blender's undo stack",
      undo_module._mode is None and bool(undo_module.blender_steps()), undo_module.blender_steps())
again_cam = camera_on(obj("Again"))
reopened = len(positions("Again"))
answer("BEGIN", object="Again", camera=camera_literal(again_cam))
on_each_chunk = []
line = points(again_cam, (-0.5, -0.6, 0.4), (0.5, -0.6, 0.4), 24)
for i in range(0, len(line), 4):
    answer("CHUNK", points=literal(line[i:i + 4]))
    on_each_chunk.append(obj("Again").use_dynamic_topology_sculpting)
end = answer("END")
push("Draw Brush")
stroked = len(positions("Again"))
check("the first stroke keeps Dynamic Topology on through every chunk (%d) and remeshes "
      "(%d -> %d vertices)" % (len(on_each_chunk), reopened, stroked),
      len(on_each_chunk) >= 3 and all(on_each_chunk) and stroked != reopened, (on_each_chunk, end))
undo()
check("Undo: the reopened mesh, Dynamic Topology still on",
      len(positions("Again")) == reopened and obj("Again").use_dynamic_topology_sculpting,
      (len(positions("Again")), obj("Again").use_dynamic_topology_sculpting))
redo()
check("Redo: the stroke back, Dynamic Topology on",
      len(positions("Again")) == stroked and obj("Again").use_dynamic_topology_sculpting,
      (len(positions("Again")), obj("Again").use_dynamic_topology_sculpting))

# --------------------------------------------------------------------------
print("\nA stroke under an Array fitted to a length is priced (round 4's fix round 2)")

# Round 4's fix round 2 review: Sculpt Mode held a mesh apart from its data for
# the vertex budget's gate, and a stroke without Dynamic Topology was priced
# for nothing, so a stroke that narrows a mesh under an Array fitted to a
# length could multiply it unpriced. A ball of 1,986 vertices under an Array
# fitted to 2,513.9 m (1,258 copies, 2,498,388 vertices), dug at its +X side
# by an inverted Draw stroke: narrower, more copies, past the budget.
gate = sys.modules.get("_blenderkit_gate")


def narrow_fixture(name):
    fresh(name, location=(0, 40 if name == "Narrow" else 50, 0))
    # Aimed at the ball before the Array is added: framed after, the camera
    # takes in the Array's 2,500 m and the ball is a pixel.
    narrow_cam = camera_on(obj(name), azimuth=math.pi / 2, elevation=0.0)
    array = obj(name).modifiers.new("Array", 'ARRAY')
    array.fit_type, array.fit_length = 'FIT_LENGTH', 2513.9
    bpy.context.view_layer.update()
    enter(name)
    centre = obj(name).matrix_world.translation
    path = points(narrow_cam, (1.0, centre.y - 0.3, 0.0), (1.0, centre.y + 0.3, 0.0), 24)
    return narrow_cam, path


def width(name):
    xs = positions(name)[0::3]
    return max(xs) - min(xs)


def strong():
    brush = sculpt._brush()
    keep = (brush.strength, sculpt._size_owner().size)
    brush.strength = 1.0
    sculpt._size_owner().size = 80
    return keep


def held_count(name):
    o = obj(name)
    e = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
    m = e.to_mesh()
    try:
        return len(m.vertices)
    finally:
        e.to_mesh_clear()


narrow_cam, path = narrow_fixture("Narrow")
before_width, before_count = width("Narrow"), held_count("Narrow")
run("ACTIVATE", brush="Draw")
keep = strong()
said = None
try:
    stroke("Narrow", narrow_cam, path, per_chunk=4, mode="INVERT")
except RuntimeError as error:
    said = str(error)
    # The interface ends a stroke whose chunk was refused (SculptStrokeInput).
    try:
        answer("END")
    except RuntimeError:
        pass
# What the mirror's pass would say: the gate's refusals kept during the
# stroke's own updates, then the gate itself.
kept = gate.take_refusals()
try:
    gate.gate('mirror')
except RuntimeError as error:
    kept.append(str(error))
said = said or (kept[-1] if kept else None)
check("an inverted Draw stroke narrowing a ball under an Array fitted to 2,513.9 m (%s vertices) is refused, "
      "the ball as wide as before (%.4f) and Blender at %s" % (format(before_count, ','), width("Narrow"),
                                                                  format(held_count("Narrow"), ',')),
      said is not None and "2,500,000" in said and abs(width("Narrow") - before_width) < 1e-6
      and held_count("Narrow") == before_count, said)
undo()
redo()
check("an Undo and a Redo after it leave Blender at %s, inside the budget" % format(held_count("Narrow"), ','),
      held_count("Narrow") <= 2_500_000, held_count("Narrow"))
narrow_cam, path = narrow_fixture("Narrowed")
run("ACTIVATE", brush="Draw")
strong()
gate._busy += 1
try:
    stroke("Narrowed", narrow_cam, path, per_chunk=4, mode="INVERT")
    bpy.context.view_layer.update()
finally:
    gate._busy -= 1
check("control: with the gate off, the same stroke narrows it to %.4f and Blender makes %s"
      % (width("Narrowed"), format(held_count("Narrowed"), ',')),
      width("Narrowed") < before_width and held_count("Narrowed") > 2_500_000,
      (width("Narrowed"), held_count("Narrowed")))
sculpt._brush().strength, sculpt._size_owner().size = keep

print()
print("ALL PASS" if fail == 0 else "%d FAILED" % fail)
sys.exit(1 if fail else 0)
