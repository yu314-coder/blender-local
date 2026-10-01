"""A user's frame handler that deletes objects, then a frame change from the app.

Run by scripts/run-animation-blender-check.sh, in a Blender process of its own,
because the defect it guards against killed Blender: round 3's review measured
`_blenderkit_anim.frame_set` segfaulting 2 runs of 2 (exit 139, in
pyrna_struct_CreatePyObject under the frame handler's `getattr`) when it read
`update.id.original` for objects a user's `frame_change_post` handler had just
removed. `depsgraph.updates` still lists them, its evaluated copies are the
depsgraph's own memory, and their `original` is the freed object. With the
freed memory reused by cameras the same read raised `'ID' object has no
attribute 'matrix_world'` instead, and the frame never reached the timeline.

    Blender -b --factory-startup --python handler_removes.py -- MODULE VARIANT

MODULE is the _blenderkit_anim.py to load (the tree's, or an old copy to show
the defect). VARIANT is what the handler allocates after it deletes, so that
freed memory is reused: `meshes`, `geometry` (meshes with faces), `cameras`,
or `none`.

Exit 0 when every check passes; 1 when one fails; a crash is the exit code
Blender dies with.
"""
import bpy, sys, io, types, pathlib, contextlib, importlib.util
from array import array

sys.dont_write_bytecode = True
ARGS = sys.argv[sys.argv.index('--') + 1:]
MODULE, VARIANT = ARGS[0], ARGS[1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)),
          flush=True)
    if not ok:
        fail += 1


class Bridge(types.ModuleType):
    """The app's `_blenderkit` as far as a frame change uses it."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.frames = []
        self.meshes = []
        self.since = []

    def anim_state(self, *values):
        pass

    def anim_keys(self, *values):
        pass

    def anim_frame(self, frame, subframe, names, matrices):
        values = array('d')
        values.frombytes(matrices)
        listed = names.decode().split('\0') if names else []
        self.frames.append(dict(frame=frame, names=listed, meshes=self.since,
                                matrices={n: list(values[16 * i:16 * (i + 1)])
                                          for i, n in enumerate(listed)}))
        self.since = []
        return len(listed)

    def anim_mesh(self, name, *buffers):
        # The frame's meshes come before its anim_frame.
        self.since.append(name)
        return 1

    def sync_local(self, name, values):
        return None

    # What the whole mirror a deletion asks for (`_blenderkit_sync.sync`)
    # calls, as tests/animation/blender/verify.py stands in for them.
    def sync_begin(self):
        self.pushed = set()

    def sync_push(self, name, *rest):
        self.pushed.add(name)

    def sync_end(self):
        self.screen = set(self.pushed)

    def mode(self):
        return "OBJECT"

    def set_mode(self, mode):
        pass

    def sync_edit_selection(self, *args):
        pass

    def material_set(self, *args):
        pass

    def set_timeline(self, *args):
        pass

    def select_all(self, on=True):
        pass

    def select(self, name, on=True):
        pass

    def set_active(self, name):
        pass


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


anim = load("_blenderkit_anim", MODULE)
sync = load("_blenderkit_sync", ROOT / "Resources/python/site/_blenderkit_sync.py")

scene = bpy.context.scene
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)

# Twenty keyed grids, each with a Wave, so a frame both moves and deforms them.
keyed = []
for i in range(20):
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=8, y_subdivisions=8, size=1,
                                    location=(i * 1.5, 0, 0))
    obj = bpy.context.object
    obj.name = "Keyed.%02d" % i
    obj.modifiers.new("Wave", 'WAVE')
    obj.keyframe_insert("location", frame=1)
    obj.location.z = 3
    obj.keyframe_insert("location", frame=10)
    keyed.append(obj.name)
removed = keyed[::2]


def user_handler(sc, _depsgraph):
    """What a user's script might do: at frame 5, delete half the keyed
    objects with their meshes, then make new data-blocks."""
    if sc.frame_current != 5 or not any(n in bpy.data.objects for n in removed):
        return
    for name in removed:
        obj = bpy.data.objects[name]
        mesh = obj.data
        bpy.data.objects.remove(obj, do_unlink=True)
        bpy.data.meshes.remove(mesh)
    for i in range(200):
        if VARIANT == 'meshes':
            junk = bpy.data.meshes.new("JunkMesh.%03d" % i)
            ob = bpy.data.objects.new("JunkOb.%03d" % i, junk)
            ob.location = (0, -50, i)
        elif VARIANT == 'geometry':
            junk = bpy.data.meshes.new("JunkMesh.%03d" % i)
            junk.from_pydata([(x, y, 0) for x in range(10) for y in range(10)], [],
                             [(x * 10 + y, x * 10 + y + 1, x * 10 + y + 11, x * 10 + y + 10)
                              for x in range(9) for y in range(9)])
        elif VARIANT == 'cameras':
            bpy.data.cameras.new("JunkCam.%03d" % i)


bpy.app.handlers.frame_change_post.append(user_handler)
scene.frame_set(1)
# What a mirroring pass ends with: the timeline's state, and the objects the
# screen holds, which a frame change compares against.
anim.report()

errors = []
printed = io.StringIO()
for frame in range(2, 8):
    with contextlib.redirect_stdout(printed):
        try:
            anim.frame_set(frame)
        except Exception as error:
            errors.append((frame, repr(error)))
print("  (%s) Blender survived 6 frame changes with the handler deleting at frame 5"
      % VARIANT, flush=True)

check("no frame change raised", not errors, errors)
sent = [f["frame"] for f in bridge.frames]
check("every frame reached the timeline, 2 to 7", sent == list(range(2, 8)), sent)
at5 = next((f for f in bridge.frames if f["frame"] == 5), None)
names = set(at5["names"]) if at5 else set()
check("frame 5 sends none of the deleted objects", not (names & set(removed)),
      sorted(names & set(removed)))
check("and every keyed object that is left", names == set(keyed) - set(removed), sorted(names))
wrong = []
for frame in bridge.frames:
    if frame["frame"] != scene.frame_current:
        continue
    for name, matrix in frame["matrices"].items():
        live = bpy.data.objects.get(name)
        expected = [v for row in live.matrix_world for v in row] if live else None
        if expected is None or any(abs(a - b) > 1e-6 for a, b in zip(matrix, expected)):
            wrong.append(name)
check("each matrix sent for the last frame is its object's own", not wrong, wrong)
check("the deletion asks for a whole mirror, which takes the deleted objects off the screen",
      anim.FULL_MIRROR in printed.getvalue(), printed.getvalue()[-200:])
late = {name for f in bridge.frames if f["frame"] >= 5 for name in f["meshes"]}
check("the deleted objects' meshes are not sent from frame 5 on either",
      not (late & set(removed)), sorted(late & set(removed)))
check("the others' meshes are, every frame",
      all(set(f["meshes"]) == (set(keyed) - set(removed) if f["frame"] >= 5 else set(keyed))
          for f in bridge.frames), [(f["frame"], len(f["meshes"])) for f in bridge.frames])

# The whole mirror the app runs on BK_ANIM_FULL_MIRROR, after the deletion.
try:
    with contextlib.redirect_stdout(io.StringIO()):
        sync.sync()
    mirrored = None
except Exception as error:
    mirrored = repr(error)
check("the whole mirror after it completes, with the ten that are left on screen",
      mirrored is None and {n for n in bridge.screen if n.startswith("Keyed")} == set(keyed) - set(removed),
      mirrored or sorted(bridge.screen))

bpy.app.handlers.frame_change_post.remove(user_handler)
print("  " + ("ALL PASS" if not fail else "%d FAILED" % fail), flush=True)
sys.exit(1 if fail else 0)
