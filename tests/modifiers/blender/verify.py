"""The modifier rows, run by the Blender they run on.

scripts/run-modifier-blender-check.sh starts desktop Blender with
`-b --factory-startup`: no user settings and no 3D View area, as for the bpy
module on a device. Every string run here is the one the Swift sends, printed
by tests/modifiers/blender/main.swift.

Three things per row, and a Swift-only test can hold down none of them:

  * Blender accepts the Python at all. Shrinkwrap's pointer is `target`; the
    same assignment spelled `object`, as Boolean's is, raises AttributeError.
  * The value lands on Blender's modifier, and the evaluated mesh changes the
    way that modifier changes it.
  * The mirror sends it back. The app's own `sync()` from the source tree is
    run, in the order the app runs it, and what it hands `sync_modifiers` is
    written out for the Swift half to parse.

And an edit mid-session: Blender's record goes to the Swift (`main.swift
--edit`), which makes the row's change and prints what the row sends; that
runs here. The row used to send every setting, after writing the new value
into the display cache — so one setting Blender refused went on failing with
every later edit of the others.
"""
import bpy, sys, types, math, pathlib, importlib.util, subprocess, tempfile

# The module under test is read from the source tree; nothing is written into it.
sys.dont_write_bytecode = True

CALLS, RECORDS, DUMP = sys.argv[sys.argv.index("--") + 1:][:3]
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


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit` module and keeps what the mirror
    hands the Modifiers panel. Everything else `sync()` reports is guarded by a
    getattr in the module, so leaving it off here skips it."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.modifiers = {}

    def sync_begin(self):
        self.modifiers = {}

    def sync_push(self, *args):
        pass

    def sync_end(self):
        pass

    def material_set(self, *args):
        pass

    def sync_modifiers(self, name, record):
        self.modifiers[name] = record


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# `sync()` reports the paint, animation and tool state after the meshes, from
# these modules; the app has them on its path and this check has to load them.
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
sync = load("_blenderkit_sync")
# What Multires's buttons call (`Bpy.multires`); their lines import it by name.
multires_module = load("_blenderkit_multires")

out = []


def scene():
    """A 32x16 UV sphere, active, inside a 4 m cube named Target."""
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=4)
    bpy.context.object.name = "Target"
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=1)
    sphere = bpy.context.object
    sphere.name = "Sphere"
    return sphere


def evaluated(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = obj.evaluated_get(depsgraph).to_mesh()
    try:
        return len(mesh.vertices), len(mesh.polygons), [tuple(v.co) for v in mesh.vertices]
    finally:
        obj.evaluated_get(depsgraph).to_mesh_clear()


def cage():
    """A lattice object named Cage around the sphere, one corner pulled out,
    so a Lattice modifier pointed at it visibly deforms the sphere."""
    data = bpy.data.lattices.new("Cage")
    obj = bpy.data.objects.new("Cage", data)
    bpy.context.scene.collection.objects.link(obj)
    obj.scale = (2.5, 2.5, 2.5)
    data.points[0].co_deform.x -= 0.5
    return obj


def run(name, setup=None):
    """Run the row's Python on a fresh sphere; the modifier, or None if it raised."""
    obj = scene()
    if setup:
        setup(obj)
    base = evaluated(obj)
    try:
        exec(compile(blocks[name], "<" + name + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        check(name + ": Blender accepts every line the row sends", False,
              type(error).__name__ + ": " + str(error))
        return None, None, base
    check(name + ": Blender accepts every line the row sends", True)
    # The app's own pass, not `_modifier_record` called directly: `face_count`
    # is written when the depsgraph evaluates the modifier, so a record built
    # before evaluation reports the undecimated count (measured: 512 against
    # an evaluated 220). `sync()` evaluates first, and this holds it to that.
    sync.sync()
    out.append("### " + name + "\n" + bridge.modifiers.get(obj.name, ""))
    return obj, obj.modifiers[-1], base


print("Shrinkwrap")
obj, m, base = run("SHRINKWRAP")
if m:
    check("the target is the picked object", m.target is not None and m.target.name == "Target",
          m.target)
    check("wrap_method", m.wrap_method == 'NEAREST_VERTEX', m.wrap_method)
    check("offset", abs(m.offset - 0.05) < 1e-6, m.offset)
    check("the sphere is wrapped onto the cube", evaluated(obj)[2] != base[2])

obj, m, base = run("SHRINKWRAP_NONE")
if m:
    # The measured reason the row has an empty state: no target, no change,
    # and no error anywhere.
    check("with no target Blender leaves the mesh untouched",
          m.target is None and evaluated(obj)[2] == base[2])

print("\nScrew")
obj, m, base = run("SCREW")
if m:
    check("steps", m.steps == 8, m.steps)
    check("render_steps follows steps", m.render_steps == 8, m.render_steps)
    check("axis", m.axis == 'X', m.axis)
    check("screw_offset", abs(m.screw_offset - 0.5) < 1e-5, m.screw_offset)
    check("angle is a full turn", abs(m.angle - 2 * math.pi) < 1e-4, m.angle)
    check("the sweep adds geometry", evaluated(obj)[0] > base[0], (evaluated(obj)[0], base[0]))

print("\nDecimate")
obj, m, base = run("DECIMATE")
if m:
    faces = evaluated(obj)[1]
    check("decimate_type is pinned to COLLAPSE", m.decimate_type == 'COLLAPSE', m.decimate_type)
    check("ratio", abs(m.ratio - 0.25) < 1e-6, m.ratio)
    check("the face count drops", faces < base[1], (faces, base[1]))
    check("face_count is the evaluated face count", m.face_count == faces, (m.face_count, faces))
    out.append("### DECIMATE_FACES\n%d" % faces)

print("\nRemesh")
obj, m, base = run("REMESH_VOXEL")
if m:
    check("mode", m.mode == 'VOXEL', m.mode)
    check("voxel_size", abs(m.voxel_size - 0.2) < 1e-6, m.voxel_size)
    check("the surface is rebuilt", evaluated(obj)[0] != base[0], (evaluated(obj)[0], base[0]))
obj, m, base = run("REMESH_BLOCKS")
if m:
    check("mode", m.mode == 'BLOCKS', m.mode)
    check("octree_depth", m.octree_depth == 5, m.octree_depth)
    check("the surface is rebuilt", evaluated(obj)[0] != base[0], (evaluated(obj)[0], base[0]))

print("\nSubdivision")
obj, m, base = run("SUBSURF")
if m:
    check("levels", m.levels == 2 and m.render_levels == 2, (m.levels, m.render_levels))

print("\nWave")
obj, m, base = run("WAVE")
if m:
    check("Motion X off, as sent", m.use_x is False, m.use_x)
    check("Motion Y on", m.use_y is True, m.use_y)
    check("height", abs(m.height - 0.3) < 1e-6, m.height)

print("\nMirror")
obj, m, base = run("MIRROR")
if m:
    check("the three axes in one assignment", tuple(m.use_axis) == (False, False, True),
          tuple(m.use_axis))
obj, m, base = run("MIRROR_FULL")
if m:
    check("Bisect, as a triple", tuple(m.use_bisect_axis) == (True, False, False),
          tuple(m.use_bisect_axis))
    check("Flip, as a triple", tuple(m.use_bisect_flip_axis) == (True, False, True),
          tuple(m.use_bisect_flip_axis))
    check("Clipping on", m.use_clip is True, m.use_clip)
    check("Merge off", m.use_mirror_merge is False, m.use_mirror_merge)
    check("merge distance", abs(m.merge_threshold - 0.0025) < 1e-7, m.merge_threshold)
    # Moved half a unit along X the sphere spans -0.5 to 1.5. Bisect X with
    # Flip keeps what lies below the plane and mirrors that: ±0.5. The same
    # sphere mirrored whole spans ±1.5.
    for v in obj.data.vertices:
        v.co.x += 0.5
    obj.data.update()
    xs = [v[0] for v in evaluated(obj)[2]]
    check("Bisect X with Flip keeps the half below the plane and mirrors it: the sphere spans ±0.5",
          abs(min(xs) + 0.5) < 1e-4 and abs(max(xs) - 0.5) < 1e-4, (min(xs), max(xs)))
    m.use_bisect_axis = (False, False, False)
    xs = [v[0] for v in evaluated(obj)[2]]
    check("(and without Bisect, ±1.5)", abs(min(xs) + 1.5) < 1e-4 and abs(max(xs) - 1.5) < 1e-4,
          (min(xs), max(xs)))
    m.merge_threshold = -1
    check("(Blender clamps a negative merge distance to 0 rather than raising, as the simulator does)",
          m.merge_threshold == 0.0, m.merge_threshold)


def cube(size):
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=size)
    return bpy.context.object


print("\nRemesh, added to a large object")
floor = float(blocks["REMESH_FLOOR_LARGE"])
big = cube(100)
exec(compile(blocks["REMESH_ADD_LARGE"], "<REMESH_ADD_LARGE>", "exec"), {"bpy": bpy})
m = big.modifiers[-1]
check("the Remesh on a 100 m cube starts at the floor for its size",
      m.type == 'REMESH' and abs(m.voxel_size - floor) < 1e-6, (m.type, m.voxel_size, floor))
verts = evaluated(big)[0]
# 6.05 N^2 on a cube N voxels across (measured): at 256 across, about 400,000.
check("and evaluates to a few hundred thousand vertices, far inside the mirror's limit",
      0 < verts < 450_000 and verts < sync._MAX_VERTS, verts)
sync.sync()
out.append("### REMESH_ADD_LARGE\n" + bridge.modifiers.get(big.name, ""))
small = cube(2)
exec(compile(blocks["REMESH_ADD_SMALL"], "<REMESH_ADD_SMALL>", "exec"), {"bpy": bpy})
check("on a 2 m cube Blender's own 0.1 is left alone",
      abs(small.modifiers[-1].voxel_size - 0.1) < 1e-6, small.modifiers[-1].voxel_size)
sync.sync()
out.append("### REMESH_ADD_SMALL\n" + bridge.modifiers.get(small.name, ""))

print("\nRemesh's Voxel Size row, dragged to its floor on an object Blender has remeshed")
# The mesh on screen is Blender's evaluated one — what the Remesh made — and the
# floor used to be read off it: at Voxel Size 2.0 a 2 m cube evaluates to a
# 0.667 m cube, and the floor fell to 0.0026, which remeshes to 3,548,168
# vertices (measured). The row's own ceiling is 2.0, so the case is the row's.
for size, voxel in ((2, 2.0), (100, 60.0)):
    obj = cube(size)
    remesh = obj.modifiers.new("Remesh", 'REMESH')
    remesh.mode, remesh.voxel_size = 'VOXEL', voxel
    sync.sync()
    _, _, co = evaluated(obj)
    shown = max(max(c[a] for c in co) - min(c[a] for c in co) for a in range(3))
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as record, \
            tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as positions:
        record.write(bridge.modifiers.get(obj.name, ""))
        positions.write("\n".join("%r %r %r" % c for c in co))
    lines = subprocess.run([DUMP, "--remesh-floor", record.name, positions.name], capture_output=True,
                           text=True, check=True).stdout.strip()
    exec(compile(lines, "<remesh floor>", "exec"), {"bpy": bpy})
    check("a %d m cube at %.1f, shown %.3f m across: the floor is %d/256, from the cube"
          % (size, voxel, shown, size), abs(remesh.voxel_size - size / 256) < 1e-5,
          (remesh.voxel_size, size / 256, lines))
    verts = evaluated(obj)[0]
    check("and committing it remeshes to about 400,000 vertices, as at that floor on any cube",
          0 < verts < 450_000, verts)

print("\nAn edit sends its own change, from what Blender holds")


def edit(case, setup=lambda obj, m: None):
    """The case's modifier added, `setup` done to it in Blender, then the
    row's edit as the Swift makes it from the record. The lines and the
    modifier, or (lines, None) if Blender refused them."""
    obj = scene()
    exec(compile(blocks["EDIT_" + case], "<EDIT_" + case + ">", "exec"), {"bpy": bpy})
    setup(obj, obj.modifiers[-1])
    sync.sync()
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(bridge.modifiers.get(obj.name, ""))
    lines = subprocess.run([DUMP, "--edit", case, f.name], capture_output=True,
                           text=True, check=True).stdout.strip()
    try:
        exec(compile(lines, "<edit " + case + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        check(case + ": Blender accepts the edit", False, type(error).__name__ + ": " + str(error))
        return lines, None
    return lines, obj.modifiers[-1]


def gone(obj, m):
    bpy.data.objects.remove(bpy.data.objects["Target"])
    check("(Blender clears the pointer when its object is deleted)", m.target is None, m.target)


lines, m = edit("SHRINKWRAP_GONE", gone)
check("an Offset edit after the target was deleted sends the offset alone",
      "offset" in lines and "target" not in lines, lines)
if m:
    check("and it lands", abs(m.offset - 0.07) < 1e-6, m.offset)
# The row as it was: every setting, with the name it still held.
stale = [l for l in blocks["EDIT_SHRINKWRAP_GONE"].splitlines() if ".target =" in l]
try:
    exec(compile("\n".join(stale), "<stale>", "exec"), {"bpy": bpy})
    stale_error = None
except KeyError as error:
    stale_error = str(error)
check("(the target line the old row resent with every edit raises KeyError)",
      stale_error is not None and "Target" in stale_error, stale_error)

lines, m = edit("WAVE_MOTION")
check("turning Motion X off sends use_x alone", lines.count("\n") == 0 and "use_x = False" in lines,
      lines)
if m:
    check("and Blender has X off and Y still on", m.use_x is False and m.use_y is True,
          (m.use_x, m.use_y))

lines, m = edit("MIRROR_Y")
check("turning Mirror's Y on sends the three axes Blender had, Y changed",
      lines.endswith("use_axis = (True, True, False)") and lines.count("\n") == 0, lines)
if m:
    check("and Blender has X and Y", tuple(m.use_axis) == (True, True, False), tuple(m.use_axis))


lines, m = edit("MIRROR_CLIP")
check("turning Clipping on sends use_clip alone", lines.endswith("use_clip = True") and "\n" not in lines,
      lines)
if m:
    check("and Blender clips", m.use_clip is True)
lines, m = edit("MIRROR_BISECT_Y")
check("Bisect Y sends the triple Blender had, Y changed",
      lines.endswith("use_bisect_axis = (False, True, False)") and "\n" not in lines, lines)
if m:
    check("and Blender bisects on Y", tuple(m.use_bisect_axis) == (False, True, False),
          tuple(m.use_bisect_axis))
lines, m = edit("MIRROR_DISTANCE")
check("a merge distance edit sends the distance alone, at six places",
      lines.endswith("merge_threshold = 0.000500") and "\n" not in lines, lines)
if m:
    check("and it lands", abs(m.merge_threshold - 0.0005) < 1e-9, m.merge_threshold)


def unsubdiv(obj, m):
    m.decimate_type = 'UNSUBDIV'


lines, m = edit("DECIMATE_UNSUBDIV", unsubdiv)
check("a Ratio edit on a Decimate a script left on Un-Subdivide sends the type with it",
      'decimate_type = "COLLAPSE"' in lines and "ratio = 0.5000" in lines, lines)
if m:
    check("and both land", m.decimate_type == 'COLLAPSE' and abs(m.ratio - 0.5) < 1e-6,
          (m.decimate_type, m.ratio))


def voxel(obj, m):
    m.voxel_size = 0.3


lines, m = edit("REMESH_MODE", voxel)
check("changing Remesh's mode sends the mode alone", "mode" in lines and "voxel_size" not in lines,
      lines)
if m:
    check("and leaves the voxel size Blender had", m.mode == 'BLOCKS' and abs(m.voxel_size - 0.3) < 1e-6,
          (m.mode, m.voxel_size))

lines, m = edit("UNCHANGED")
check("an edit that changes nothing sends nothing", lines == "", lines)

print("\nThe Geometry Nodes row: Smooth by Angle, which Shade Auto Smooth adds")


def sharp_edges(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        flags = mesh.attributes.get('sharp_edge')
        return sum(1 for d in flags.data if d.value) if flags else 0
    finally:
        evaluated.to_mesh_clear()


lines, m = edit("SMOOTH_BY_ANGLE_ANGLE",
                lambda obj, m: check("(at 30 degrees no edge of the UV sphere is sharp: its faces "
                                     "meet at 11.25)", sharp_edges(obj) == 0, sharp_edges(obj)))
check("an Angle edit sends the angle alone, through the mirror's helper",
      lines.count("\n") == 0 and "set_node_input" in lines and '"Angle"' in lines, lines)
if m:
    obj = bpy.data.objects["Sphere"]
    check("and Blender's input reads 5 degrees", abs(sync.node_input(m, "Angle") - math.radians(5)) < 1e-4,
          math.degrees(sync.node_input(m, "Angle")))
    check("and the evaluated sphere changes with it: its edges come out sharp",
          sharp_edges(obj) > 0, sharp_edges(obj))
lines, m = edit("SMOOTH_BY_ANGLE_IGNORE")
check("the Ignore Sharpness toggle sends itself alone", lines.count("\n") == 0 and "Ignore Sharpness" in lines,
      lines)
if m:
    check("and Blender has it on", sync.node_input(m, "Ignore Sharpness") is True)
lines, m = edit("NODES_OTHER")
check("a Geometry Nodes modifier with another group sends nothing, whatever the row's fields",
      lines == "", lines)
for name, setup in (("NODES_EMPTY", "bpy.ops.object.modifier_add(type='NODES')"),
                    ("NODES_OTHER", blocks["EDIT_NODES_OTHER"])):
    obj = scene()
    exec(compile(setup, "<" + name + ">", "exec"), {"bpy": bpy})
    sync.sync()
    out.append("### " + name + "\n" + bridge.modifiers.get(obj.name, ""))


print("\nThe two switches and the new rows' fields, edited from Blender's record")
lines, m = edit("VIEWPORT_OFF")
check("Show in Viewport sends show_viewport alone", lines.count("\n") == 0 and lines.endswith(".show_viewport = False"),
      lines)
if m:
    check("and Blender has it off, render still on", m.show_viewport is False and m.show_render is True)
lines, m = edit("RENDER_OFF")
check("Show in Render sends show_render alone", lines.count("\n") == 0 and lines.endswith(".show_render = False"),
      lines)
if m:
    check("and Blender has it off, the viewport still on", m.show_render is False and m.show_viewport is True)
lines, m = edit("OTHER_VIEWPORT_OFF")
check("on a Wireframe, which has no settings rows, the same", lines.count("\n") == 0
      and 'modifiers["Wireframe"].show_viewport = False' in lines, lines)
if m:
    obj = bpy.data.objects["Sphere"]
    check("and the sphere is drawn without it again", evaluated(obj)[0] == len(obj.data.vertices),
          (evaluated(obj)[0], len(obj.data.vertices)))
lines, m = edit("WN_WEIGHT")
check("a Weight edit sends the weight alone", lines.count("\n") == 0 and lines.endswith(".weight = 70"), lines)
if m:
    check("and it lands", m.weight == 70, m.weight)
lines, m = edit("LAPLACIAN_Z")
check("turning Laplacian's Z off sends use_z alone", lines.count("\n") == 0 and lines.endswith(".use_z = False"),
      lines)
if m:
    check("and Blender has X and Y on, Z off", m.use_x and m.use_y and not m.use_z)
lines, m = edit("MULTIRES_LEVEL")
check("a Multires level edit sends the viewport level alone", lines.count("\n") == 0
      and lines.endswith(".levels = 1"), lines)
if m:
    check("and Blender has 1 of 2, sculpt and render still 2",
          m.levels == 1 and m.total_levels == 2 and m.sculpt_levels == 2 and m.render_levels == 2)
lines, m = edit("LATTICE_PICK", lambda obj, m: cage())
check("picking the cage sends the object alone", lines.count("\n") == 0
      and lines.endswith('.object = bpy.data.objects["Cage"]'), lines)
if m:
    check("and Blender holds it", m.object is not None and m.object.name == "Cage", m.object)



def picked_cage(obj, m):
    m.object = cage()


lines, m = edit("LATTICE_CLEAR", picked_cage)
check("the picker's None sends object = None alone", lines.count("\n") == 0
      and lines.endswith('.object = None'), lines)
if m:
    check("and Blender's Lattice points at nothing again", m.object is None, m.object)

# A modifier whose settings cannot be read (`unread`) keeps its two switches as
# Blender holds them. Made to happen by a reader that raises: round 3's
# reviewer could not make `_modifier_entry` raise in 5.2.1.
obj = scene()
bpy.ops.object.modifier_add(type='SUBSURF')
obj.modifiers[-1].show_viewport = False
real_entry = sync._modifier_entry


def unreadable(o, m, first):
    raise AttributeError("unreadable for the check")


sync._modifier_entry = unreadable
try:
    sync.sync()
finally:
    sync._modifier_entry = real_entry
unread = bridge.modifiers.get(obj.name, "")
check("an unread entry carries Blender's switches, Show in Viewport off included",
      "unread=" in unread and "show_viewport=0" in unread and "show_render=1" in unread, unread)
out.append("### UNREAD\n" + unread)

print("\nThe header's Apply, moves and remove, and Multires's buttons, from Blender's record")


def action(name, setup, verb, target, prepare=None, make=None):
    """A scene made by `make` (the sphere by default), `setup` run, `prepare`
    done in Blender, then the Swift's `--action` for `verb` on `target`, as the
    row sends it — the object, the lines, and the error Blender raised or None."""
    obj = make() if make else scene()
    exec(compile(setup, "<" + name + ">", "exec"), {"bpy": bpy})
    if prepare:
        prepare(obj)
    sync.sync()
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(bridge.modifiers.get(obj.name, ""))
    lines = subprocess.run([DUMP, "--action", verb, target, f.name], capture_output=True,
                           text=True, check=True).stdout.strip()
    try:
        exec(compile(lines, "<" + name + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the error is the finding
        return obj, lines, error
    return obj, lines, None


def names(obj):
    return [m.name for m in obj.modifiers]


two = "bpy.ops.object.modifier_add(type='SUBSURF')\nbpy.ops.object.modifier_add(type='WIREFRAME')"
obj, lines, error = action("up", two, "up", "Wireframe")
check("Move Up on a Wireframe, a kind with no settings rows, moves it up",
      error is None and names(obj) == ["Wireframe", "Subdivision"], (error, names(obj)))
obj, lines, error = action("down", two, "down", "Subdivision")
check("Move Down likewise", error is None and names(obj) == ["Wireframe", "Subdivision"], (error, names(obj)))
locked = "bpy.ops.object.modifier_add(type='MULTIRES')\nbpy.ops.object.modifier_add(type='WEIGHTED_NORMAL')"
obj, lines, error = action("down refused", locked, "down", "Multires")
check("a move Blender cancels is refused in words, not reported done",
      isinstance(error, RuntimeError) and "Blender keeps" in str(error) and names(obj) == ["Multires", "WeightedNormal"],
      (error, names(obj)))
obj, lines, error = action("up refused", locked, "up", "WeightedNormal")
check("(the same above a Multires)", isinstance(error, RuntimeError) and names(obj) == ["Multires", "WeightedNormal"],
      (error, names(obj)))

obj, lines, error = action("apply other", "bpy.ops.object.modifier_add(type='WIREFRAME')", "apply", "Wireframe")
wire_count = len(obj.data.vertices)
check("Apply on a Wireframe bakes it into the mesh", error is None and names(obj) == [] and wire_count > 482,
      (error, names(obj), wire_count))
obj, lines, error = action("apply lattice", "bpy.ops.object.modifier_add(type='LATTICE')", "apply", "Lattice")
check("Apply on a Lattice with no lattice raises Blender's refusal",
      isinstance(error, RuntimeError) and "disabled" in str(error) and names(obj) == ["Lattice"], (error, names(obj)))
# The same for the other two kinds that point at an object
# (`Modifier.isDisabled`, which the simulator's Apply now keeps).
for kind, row in (("BOOLEAN", "Boolean"), ("SHRINKWRAP", "Shrinkwrap")):
    obj, lines, error = action("apply " + row, "bpy.ops.object.modifier_add(type='%s')" % kind, "apply", row)
    check("and on a %s with nothing picked" % row,
          isinstance(error, RuntimeError) and "disabled" in str(error) and names(obj) == [row], (error, names(obj)))


def edit_mode(obj):
    bpy.ops.object.mode_set(mode='EDIT')


obj, lines, error = action("apply in edit mode", "bpy.ops.object.modifier_add(type='SUBSURF')", "apply",
                           "Subdivision", prepare=edit_mode)
check("Apply from edit mode runs in object mode and comes back to edit mode",
      error is None and names(obj) == [] and obj.mode == 'EDIT', (error, names(obj), obj.mode))
bpy.ops.object.mode_set(mode='OBJECT')
check("(having baked the subdivided sphere)", len(obj.data.vertices) > 482, len(obj.data.vertices))
obj, lines, error = action("remove", two, "remove", "Wireframe")
check("remove on a Wireframe removes it", error is None and names(obj) == ["Subdivision"], (error, names(obj)))
obj, lines, error = action("viewport", two, "viewport", "Wireframe")
check("the header's Show in Viewport turns a Wireframe off",
      error is None and obj.modifiers["Wireframe"].show_viewport is False, error)

multires = "bpy.ops.object.modifier_add(type='MULTIRES')"
obj, lines, error = action("subdivide", multires, "subdivide", "Multires")
check("Subdivide makes a level", error is None and obj.modifiers[0].total_levels == 1
      and obj.modifiers[0].levels == 1, (error, obj.modifiers[0].total_levels))


def circle():
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_circle_add(fill_type='NOTHING')
    return bpy.context.object


obj, lines, error = action("subdivide wire", multires, "subdivide", "Multires", make=circle)
check("Subdivide on a wire circle, which Blender answers FINISHED having made no level, is refused",
      isinstance(error, RuntimeError) and "no faces" in str(error) and obj.modifiers[0].total_levels == 0,
      (error, obj.modifiers[0].total_levels))


def two_levels_at_one(obj):
    for _ in range(2):
        bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
    obj.modifiers[0].levels = 1


obj, lines, error = action("delete higher", multires, "deleteHigher", "Multires", prepare=two_levels_at_one)
check("Delete Higher drops the level above the viewport's", error is None and obj.modifiers[0].total_levels == 1,
      (error, obj.modifiers[0].total_levels))


def subdivided_cube():
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=2)
    obj = bpy.context.object
    bpy.ops.object.modifier_add(type='SUBSURF')
    obj.modifiers[0].levels = 2
    bpy.ops.object.modifier_apply(modifier="Subdivision")
    return obj


obj, lines, error = action("unsubdivide", multires, "unsubdivide", "Multires", make=subdivided_cube)
# One level per press (measured: a cube subdivided twice, 98 vertices, goes
# to a 26-vertex base at one level, and a second press to the 8-vertex cube).
check("Unsubdivide rebuilds a level under a cube subdivided twice, one per press",
      error is None and obj.modifiers[0].total_levels == 1 and len(obj.data.vertices) == 26,
      (error, obj.modifiers[0].total_levels, len(obj.data.vertices)))
obj, lines, error = action("unsubdivide sphere", multires, "unsubdivide", "Multires")
check("and on a UV sphere raises Blender's own refusal",
      isinstance(error, RuntimeError) and "No valid subdivisions" in str(error), error)


def one_level(obj):
    bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')


def cube2():
    return cube(2)


obj, lines, error = action("apply base", multires, "applyBase", "Multires", prepare=one_level, make=cube2)
corner = max(abs(c) for v in obj.data.vertices for c in v.co)
check("Apply Base pulls the cube's base towards its subdivided shape",
      error is None and corner < 0.99 and len(obj.data.vertices) == 8, (error, corner, len(obj.data.vertices)))


# Measured in 5.2.1: every Multires operator passes its poll in Edit Mode and
# Sculpt Mode. In Edit Mode Blender's own Apply Base segfaults in
# multires_reshape_create_subdiv; in Sculpt Mode it pushes a sculpt undo step,
# and with no undo stack — this check's bare `-b` has none — that segfaults in
# sculpt_paint::undo::push_begin_ex. Blender's own Unsubdivide in Edit Mode
# does not crash, but leaving Edit Mode writes the 98-vertex edit mesh back
# over the 26-vertex base it rebuilt. The buttons go through
# _blenderkit_multires, which takes the object to Object Mode first; were it
# run in the object's mode, this check would die here with Blender.
def one_level_in(mode):
    def prepare(obj):
        one_level(obj)
        bpy.ops.object.mode_set(mode=mode)
    return prepare


for mode in ('EDIT', 'SCULPT'):
    obj, lines, error = action("apply base in " + mode, multires, "applyBase", "Multires",
                               prepare=one_level_in(mode), make=cube2)
    back = obj.mode
    bpy.ops.object.mode_set(mode='OBJECT')
    corner = max(abs(c) for v in obj.data.vertices for c in v.co)
    check("Apply Base from %s Mode runs in object mode, reshapes the base and returns to %s Mode"
          % (mode.title(), mode.title()), error is None and back == mode and corner < 0.99,
          (error, back, corner))
obj, lines, error = action("unsubdivide in edit mode", multires, "unsubdivide", "Multires",
                           prepare=edit_mode, make=subdivided_cube)
back = obj.mode
bpy.ops.object.mode_set(mode='OBJECT')
check("Unsubdivide from Edit Mode likewise, and the rebuilt base survives leaving Edit Mode",
      error is None and back == 'EDIT'
      and obj.modifiers[0].total_levels == 1 and len(obj.data.vertices) == 26,
      (error, back, obj.modifiers[0].total_levels, len(obj.data.vertices)))
obj, lines, error = action("subdivide in edit mode", multires, "subdivide", "Multires", prepare=edit_mode,
                           make=cube2)
back = obj.mode
bpy.ops.object.mode_set(mode='OBJECT')
check("and Subdivide", error is None and back == 'EDIT' and obj.modifiers[0].total_levels == 1,
      (error, back, obj.modifiers[0].total_levels))


# Round 3's review: F3's Sculpt Mode, then the Object tab's Show in Viewports
# off. Blender then refuses to leave Sculpt Mode ("Cannot edit hidden
# object"), and the mode guard the buttons used to rely on swallowed that and
# ran the operator in Sculpt Mode. This check has no undo stack, so Apply Base
# run there would segfault; each button must refuse in words and change
# nothing.
def three_levels_hidden_in_sculpt(obj):
    for _ in range(3):
        bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
    obj.modifiers[0].levels = 1
    obj.modifiers[0].sculpt_levels = 2
    bpy.ops.object.mode_set(mode='SCULPT')
    obj.hide_viewport = True


for op in ("subdivide", "unsubdivide", "deleteHigher", "applyBase"):
    obj, lines, error = action("hidden " + op, multires, op, "Multires",
                               prepare=three_levels_hidden_in_sculpt, make=cube2)
    m = obj.modifiers[0]
    corner = max(abs(c) for v in obj.data.vertices for c in v.co)
    check("%s on an object Blender will not take out of Sculpt Mode is refused, and nothing ran" % op,
          isinstance(error, RuntimeError) and "Cannot edit hidden object" in str(error)
          and "Object Mode" in str(error) and obj.mode == 'SCULPT'
          and (m.levels, m.sculpt_levels, m.total_levels) == (1, 2, 3) and abs(corner - 1) < 1e-6,
          (error, obj.mode, m.levels, m.sculpt_levels, m.total_levels, corner))
    obj.hide_viewport = False
    bpy.ops.object.mode_set(mode='OBJECT')


# The header's Apply is a bare operator under BpyModeGuard, which used to
# swallow the same refused mode_set and run it where Blender was. It refuses
# now, in words, and nothing is applied.
def subsurf_hidden_in_sculpt(obj):
    bpy.ops.object.mode_set(mode='SCULPT')
    obj.hide_viewport = True


obj, lines, error = action("apply hidden in sculpt", "bpy.ops.object.modifier_add(type='SUBSURF')", "apply",
                           "Subdivision", prepare=subsurf_hidden_in_sculpt, make=cube2)
check("Apply on an object Blender will not take out of Sculpt Mode is refused by the mode guard",
      isinstance(error, RuntimeError) and "This runs in Object Mode" in str(error)
      and "Cannot edit hidden object" in str(error) and names(obj) == ["Subdivision"]
      and len(obj.data.vertices) == 8 and obj.mode == 'SCULPT', (error, names(obj), obj.mode))
obj.hide_viewport = False
bpy.ops.object.mode_set(mode='OBJECT')


# Blender's own operators in Sculpt Mode work from the sculpt level, and
# Subdivide there leaves the viewport level alone (multires_get_level,
# multires_set_tot_level). Measured with an undo stack in desktop 5.2.1, from
# viewport 1, sculpt 2, total 3: Delete Higher leaves 1 / 2 / 2, Subdivide
# 1 / 4 / 4. Run from Object Mode unadjusted they left 1 / 1 / 1 — the
# sculpted level gone — and 4 / 4 / 4.
def three_levels_in_sculpt(obj):
    for _ in range(3):
        bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')
    obj.modifiers[0].levels = 1
    obj.modifiers[0].sculpt_levels = 2
    bpy.ops.object.mode_set(mode='SCULPT')


for op, expected in (("deleteHigher", (1, 2, 2)), ("subdivide", (1, 4, 4))):
    obj, lines, error = action("sculpt " + op, multires, op, "Multires",
                               prepare=three_levels_in_sculpt, make=cube2)
    m = obj.modifiers[0]
    got = (m.levels, m.sculpt_levels, m.total_levels)
    check("%s from Sculpt Mode does what Blender's own does there: viewport, sculpt and total %s"
          % (op, "/".join(map(str, expected))),
          error is None and obj.mode == 'SCULPT' and got == expected, (error, obj.mode, got))
    bpy.ops.object.mode_set(mode='OBJECT')


# The budget. Measured: a cube's level 10 is 6,291,458 vertices and 1.65 GB
# over the scene. A 100 x 100 grid gets there sooner: level 3 is 641,601
# vertices, level 4 would be 2,563,201, past the 2,500,000 budget.
def grid():
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=100, y_subdivisions=100)
    return bpy.context.object


def three_levels(obj):
    for _ in range(3):
        bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')


obj, lines, error = action("budget", multires, "subdivide", "Multires", prepare=three_levels, make=grid)
check("a Subdivide whose level would pass the budget is refused before it runs",
      isinstance(error, RuntimeError) and "2,563,201" in str(error) and "2,500,000" in str(error)
      and obj.modifiers[0].total_levels == 3, (error, obj.modifiers[0].total_levels))
depsgraph = bpy.context.evaluated_depsgraph_get()
check("and the count it refused on is Blender's: level 3 evaluates to the 641,601 it predicts",
      len(obj.evaluated_get(depsgraph).to_mesh().vertices) == 641601
      == multires_module.level_vertices(obj.data, 3))
obj.evaluated_get(depsgraph).to_mesh_clear()

# F3's operator search reaches the same operator (`run_operator`), and keeps
# the same budget.
said = None
try:
    sync.run_operator('object.multires_subdivide', {'modifier': 'Multires', 'mode': 'CATMULL_CLARK'})
except RuntimeError as error:
    said = str(error)
check("F3's Multires Subdivide past the budget is refused in the same words",
      said is not None and "2,500,000" in said and obj.modifiers[0].total_levels == 3,
      (said, obj.modifiers[0].total_levels))


# And the memory the system says is left (`os_proc_available_memory`), at
# 800 bytes a vertex: the app measured 560 to 730 at the peak. Desktop
# Blender, a macOS process, reads none (the app, an iOS process, read 16.3 GB
# on this Mac), so the check is shown with 400 MB left: the grid's level 3,
# 641,601 vertices, would need about 0.5 GB.
def two_levels(obj):
    for _ in range(2):
        bpy.ops.object.multires_subdivide(modifier="Multires", mode='CATMULL_CLARK')


real_available = multires_module.available_memory
check("desktop Blender reads no figure for the memory left, so only the budget applies here", real_available() is None
      or real_available() > 1e9, real_available())
multires_module.available_memory = lambda: 400_000_000
try:
    obj, lines, error = action("memory", multires, "subdivide", "Multires", prepare=two_levels, make=grid)
finally:
    multires_module.available_memory = real_available
check("a Subdivide that would need more memory than is left is refused before it runs",
      isinstance(error, RuntimeError) and "641,601" in str(error) and "0.5 GB" in str(error)
      and "0.4 GB is free" in str(error) and obj.modifiers[0].total_levels == 2,
      (error, obj.modifiers[0].total_levels))
cube_counts = [multires_module.level_vertices(cube(2).data, level) for level in (0, 1, 2, 9, 10)]
check("the count for a cube, level by level", cube_counts == [8, 26, 98, 1572866, 6291458], cube_counts)

# Where Add Modifier puts a Multires, and which moves Blender takes around
# it: the rules the simulator now keeps (`ModifierStack.insertionIndex`,
# `canMove`, tests/modifiers/main.swift).
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2)
rules = bpy.context.object
for kind in ('WAVE', 'SUBSURF', 'MULTIRES'):
    bpy.ops.object.modifier_add(type=kind)
check("Blender adds a Multires above the first modifier that is not a pure deform",
      names(rules) == ["Wave", "Multires", "Subdivision"], names(rules))
moves = []
for name, up in (("Subdivision", True), ("Multires", False), ("Wave", False)):
    with bpy.context.temp_override(object=rules):
        moves.append(bpy.ops.object.modifier_move_up(modifier=name) if up
                     else bpy.ops.object.modifier_move_down(modifier=name))
check("and refuses a Subdivision above it and it below a Subdivision, but moves a Wave below it",
      moves == [{'CANCELLED'}, {'CANCELLED'}, {'FINISHED'}] and names(rules) == ["Multires", "Wave", "Subdivision"],
      (moves, names(rules)))

# A Soft Body needs the original mesh too, so Blender refuses a Subdivision
# moved above it with no Multires anywhere (round 3's review).
obj, lines, error = action("up under soft body", "bpy.ops.object.modifier_add(type='SOFT_BODY')\n"
                           "bpy.ops.object.modifier_add(type='SUBSURF')", "up", "Subdivision")
check("a Move Up Blender cancels under a Soft Body is refused, naming the Soft Body",
      isinstance(error, RuntimeError) and "Soft Body" in str(error)
      and names(obj) == ["Softbody", "Subdivision"], (error, names(obj)))

# Blender takes any name for a modifier, the record's separators included.
odd = 'a;b|c=d%e'
obj, lines, error = action("odd name", "bpy.ops.object.modifier_add(type='WIREFRAME')\n"
                           "bpy.context.object.modifiers[-1].name = %r\n"
                           "bpy.ops.object.modifier_add(type='SUBSURF')" % odd, "viewport", odd)
check("a modifier named %r keeps its row, and its switch reaches it" % odd,
      error is None and obj.modifiers[odd].show_viewport is False
      and obj.modifiers["Subdivision"].show_viewport is True, (error, lines))
obj.modifiers[odd].show_viewport = True
sync.sync()
out.append("### ODD_NAME\n" + bridge.modifiers.get(obj.name, ""))

# A row with no settings of its own opens Every Property at the modifier: the
# browser's own reader and writer (inspect_data, set_property) on the path the
# Swift builds, as the app runs them.
path = blocks["DATA_PATH_ODD"].strip()
try:
    info = sync.inspect_data(path)
    ids = {p['id']: p for p in info['properties']}
    check("Every Property opens on that Wireframe and lists its settings",
          info['title'] == odd and ids.get('thickness', {}).get('editable') is True
          and 'use_even_offset' in ids, sorted(ids)[:8])
    sync.set_property(path, 'thickness', 0.25)
    check("and a setting set there lands on Blender's modifier",
          abs(obj.modifiers[odd].thickness - 0.25) < 1e-6, obj.modifiers[odd].thickness)
except Exception as error:                         # noqa: BLE001 - the failure is the finding
    check("Every Property opens on that Wireframe", False, "%s: %s" % (type(error).__name__, error))


print("\nEvery modifier Blender can put on a mesh reaches the panel")
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2)
every = bpy.context.object
for item in bpy.types.Modifier.bl_rna.properties['type'].enum_items:
    if item.identifier.startswith('GREASE_PENCIL') or item.identifier == 'LINEART':
        continue
    try:
        bpy.ops.object.modifier_add(type=item.identifier)
    except (TypeError, RuntimeError):
        pass                            # not a mesh modifier in this build
sync.sync()
record = bridge.modifiers.get(every.name, "")
check("Blender holds more than fifty modifiers on one cube", len(every.modifiers) > 50, len(every.modifiers))
check("the mirror sends an entry for every one", len(record.split("|")) == len(every.modifiers),
      (len(record.split("|")), len(every.modifiers)))
out.append("### ALL_TYPES\n" + record)
out.append("### ALL_TYPES_EXPECTED\n" + "\n".join(m.name + "\t" + m.type for m in every.modifiers))

bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2)
reviewer = bpy.context.object
for kind in ('MULTIRES', 'WEIGHTED_NORMAL', 'EDGE_SPLIT', 'LAPLACIANSMOOTH', 'SUBSURF'):
    bpy.ops.object.modifier_add(type=kind)
sync.sync()
out.append("### REVIEWER\n" + bridge.modifiers.get(reviewer.name, ""))

print("\nThe six new rows")


def moved(obj, base, axis=None):
    after = evaluated(obj)[2]
    if len(after) != len(base[2]):
        return float('inf')
    return max(abs(a[i] - b[i]) for a, b in zip(after, base[2])
               for i in ((axis,) if axis is not None else range(3)))


obj, m, base = run("WEIGHTED_NORMAL")
if m:
    check("mode, weight, threshold, Keep Sharp, Face Influence",
          m.mode == 'CORNER_ANGLE' and m.weight == 70 and abs(m.thresh - 0.5) < 1e-6
          and m.keep_sharp and m.use_face_influence,
          (m.mode, m.weight, m.thresh, m.keep_sharp, m.use_face_influence))
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = obj.evaluated_get(depsgraph).to_mesh()
    check("and the evaluated mesh carries custom normals", mesh.has_custom_normals)
    obj.evaluated_get(depsgraph).to_mesh_clear()
obj, m, base = run("MULTIRES")
if m:
    check("Subdivide twice made two levels, and the three levels landed",
          m.total_levels == 2 and m.levels == 1 and m.sculpt_levels == 2 and m.render_levels == 2,
          (m.total_levels, m.levels, m.sculpt_levels, m.render_levels))
    check("the sphere is drawn at level 1", evaluated(obj)[0] > base[0], (evaluated(obj)[0], base[0]))
obj, m, base = run("EDGE_SPLIT")
if m:
    check("split angle 5 degrees, Sharp Edges off",
          abs(m.split_angle - math.radians(5)) < 1e-4 and m.use_edge_angle and not m.use_edge_sharp,
          (m.split_angle, m.use_edge_angle, m.use_edge_sharp))
    check("and the sphere, whose faces meet at 11.25 degrees, comes apart at every edge",
          evaluated(obj)[0] > base[0] * 3, (evaluated(obj)[0], base[0]))
obj, m, base = run("LAPLACIANSMOOTH")
if m:
    check("repeat 4 at 0.5, border 0.2, Y off, Preserve Volume and Normalized off",
          m.iterations == 4 and abs(m.lambda_factor - 0.5) < 1e-6 and abs(m.lambda_border - 0.2) < 1e-6
          and m.use_x and not m.use_y and m.use_z and not m.use_volume_preserve and not m.use_normalized)
    check("the sphere is smoothed", moved(obj, base) > 1e-3, moved(obj, base))
    check("and not along Y, whose axis is off", moved(obj, base, 1) < 1e-6, moved(obj, base, 1))
obj, m, base = run("CORRECTIVE_SMOOTH")
if m:
    check("factor 0.3, repeat 8, scale 2, Length Weight, Only Smooth, Pin Boundaries",
          abs(m.factor - 0.3) < 1e-6 and m.iterations == 8 and abs(m.scale - 2) < 1e-6
          and m.smooth_type == 'LENGTH_WEIGHTED' and m.use_only_smooth and m.use_pin_boundary)
    check("Only Smooth smooths the sphere outright", moved(obj, base) > 1e-3, moved(obj, base))
obj, m, base = run("LATTICE", setup=lambda obj: cage())
if m:
    check("the Lattice's object is the cage, at strength 0.5",
          m.object is not None and m.object.name == "Cage" and abs(m.strength - 0.5) < 1e-6,
          (m.object, m.strength))
    check("and the pulled corner deforms the sphere", moved(obj, base) > 1e-3, moved(obj, base))
obj, m, base = run("LATTICE_NONE", setup=lambda obj: cage())
if m:
    check("with nothing picked Blender leaves the sphere alone", m.object is None and moved(obj, base) == 0)
obj = scene()
cage()
bpy.ops.object.modifier_add(type='LATTICE')
obj.modifiers[-1].object = bpy.data.objects["Target"]
check("(Blender drops a mesh assigned as a Lattice's object without a word)", obj.modifiers[-1].object is None)
sync.sync()
out.append("### LATTICE_MESH\n" + bridge.modifiers.get(obj.name, ""))

open(RECORDS, "w").write("\n#--\n".join(out) + "\n")

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
