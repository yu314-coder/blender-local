"""Animation on an iPad, checked in the Blender it runs.

scripts/run-animation-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: no user settings, and no 3D View area —
`bpy.context.area` is None, as it is for the bpy module on a device. Every
string run here comes from the Swift that sends it, printed by
tests/animation/blender/main.swift.

Where Blender has an operator for what the app does headless — Insert Keyframe,
Delete Keyframe, keyframe jumps — that operator is run too, under an override
into the startup file's editors that the iPad does not have, and the two
results are held against each other, attribute for attribute.
"""
import bpy, sys, io, json, time, types, pathlib, contextlib, importlib.util
from array import array

# The modules under test are loaded from the source tree, which other checks
# read at the same time; nothing is written into it.
sys.dont_write_bytecode = True

ARGS = sys.argv[sys.argv.index('--') + 1:]
CALLS, MIRROR_JSON = ARGS[0], ARGS[1]
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
    """Stands in for the app's `_blenderkit` module and records what it is told."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.shown = "OBJECT"
        # What the last pass left on screen, and whether one is under way:
        # `sync_local` is held to the device's rule for both below.
        self.screen = set()
        self.in_pass = False
        # Set to refuse every set of channels, as the device first did for
        # a name it did not hold.
        self.refuse_local = False
        self.reset()

    def reset(self):
        self.state = None
        self.keys = None
        self.scene_keys = None
        self.raw_keys = None
        self.frames = []
        self.meshes = []
        self.notices = []
        self.pushed = {}
        self.local = {}
        # Records sizes only, so timing the frame path does not time this.
        self.light = False

    # What _blenderkit_sync.sync needs.
    def sync_begin(self):
        self.pushed = {}
        self.in_pass = True

    def sync_push(self, name, *rest):
        self.pushed[name] = True

    def sync_end(self):
        self.screen = set(self.pushed)
        self.in_pass = False

    def sync_local(self, name, values):
        """bk_sync_local through PythonBootstrap.c, as SceneMirror.carryLocal
        decides it: in a pass, the name must have been pushed; outside one,
        a name not on screen is skipped. Anything refused is a ValueError."""
        channels = array('d')
        channels.frombytes(values)
        if self.refuse_local or len(channels) != 10:
            raise ValueError("transform channels for %s were refused" % name)
        if self.in_pass and name not in self.pushed:
            raise ValueError("this pass pushed no object named %s" % name)
        if not self.in_pass and name not in self.screen:
            return None
        self.local[name] = list(channels)

    def mode(self):
        return self.shown

    def set_mode(self, mode):
        self.shown = mode

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

    # The animation calls.
    def anim_state(self, *values):
        self.state = values

    def anim_keys(self, names, counts, frames, selected, scene_frames, scene_selected):
        def typed(code, raw):
            values = array(code)
            values.frombytes(raw)
            return list(values)
        raw = dict(names=names.decode().split('\0') if names else [], counts=typed('I', counts),
                   frames=typed('f', frames), selected=typed('B', selected),
                   sceneFrames=typed('f', scene_frames), sceneSelected=typed('B', scene_selected))
        self.raw_keys = raw
        self.keys = {}
        offset = 0
        for name, count in zip(raw['names'], raw['counts']):
            self.keys[name] = list(zip(raw['frames'][offset:offset + count],
                                       raw['selected'][offset:offset + count]))
            offset += count
        self.scene_keys = list(zip(raw['sceneFrames'], raw['sceneSelected']))

    def anim_frame(self, frame, subframe, names, matrices):
        if self.light:
            self.frames.append(len(matrices))
            return 0
        values = array('d')
        values.frombytes(matrices)
        listed = names.decode().split('\0') if names else []
        self.frames.append(dict(frame=frame, subframe=subframe, names=listed,
                                matrices={n: list(values[16 * i:16 * (i + 1)])
                                          for i, n in enumerate(listed)}))
        return len(listed)

    def anim_mesh(self, name, verts, normals, tris, edges=None):
        # `edges` comes with a mesh that has no faces (push_mesh).
        # bk_anim_set_mesh answers -1 for a name not on screen, a ValueError.
        if name not in self.screen:
            raise ValueError("no object named %s to deform, or a malformed mesh" % name)
        if self.light:
            self.meshes.append(name)
            return 1
        co = array('f')
        co.frombytes(verts)
        self.meshes.append(dict(name=name, co=list(co), tris=len(tris) // 12))
        return 1

    def anim_notice(self, text):
        self.notices.append(text)


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


anim = load("_blenderkit_anim", "Resources/python/site/_blenderkit_anim.py")
sync = load("_blenderkit_sync", "Resources/python/site/_blenderkit_sync.py")

EDIT = bpy.context.preferences.edit
EDIT_DEFAULTS = {name: getattr(EDIT, name) for name in (
    'key_insert_channels', 'use_keyframe_insert_needed', 'use_visual_keying',
    'use_keyframe_insert_available', 'use_auto_keyframe_insert_needed')}


def restore_preferences():
    for name, value in EDIT_DEFAULTS.items():
        setattr(EDIT, name, value)


def run_text(text, name="<ui>"):
    namespace = {"bpy": bpy}
    exec(compile(text, name, "exec"), namespace)
    return namespace


def run(name):
    return run_text(blocks[name], "<" + name + ">")


def quietly(fn):
    """Runs fn, returning (what it printed, result, error)."""
    buffer = io.StringIO()
    result, error = None, None
    with contextlib.redirect_stdout(buffer):
        try:
            result = fn()
        except Exception as exc:
            error = str(exc)
    return buffer.getvalue(), result, error


def fresh():
    """The factory startup file, emptied. Its Layout screen stays: that is where
    the 3D View and the Timeline the overrides borrow come from."""
    bpy.ops.wm.read_homefile(app_template="")
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    return bpy.context.scene


def cube(name, location=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=2, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.data.name = name
    return obj


def select_only(*objects):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    if objects:
        bpy.context.view_layer.objects.active = objects[0]


def override(kind='VIEW_3D'):
    window = bpy.context.window_manager.windows[0]
    for area in window.screen.areas:
        if area.type == kind:
            region = next(r for r in area.regions if r.type == 'WINDOW')
            return dict(window=window, screen=window.screen, area=area, region=region)
    raise RuntimeError("the startup file has no " + kind)


def animation(idblock):
    """Every attribute of an ID's keys that Blender's operators and the app
    could disagree on."""
    bag = anim.channelbag(getattr(idblock, 'animation_data', None))
    if bag is None:
        return None
    return [(fc.data_path, fc.array_index, fc.group.name if fc.group else None, fc.color_mode,
             fc.auto_smoothing, fc.extrapolation, fc.lock, fc.select,
             [(round(k.co.x, 4), round(k.co.y, 4), k.interpolation, k.easing,
               k.handle_left_type, k.handle_right_type, k.type, k.select_control_point,
               k.select_left_handle, k.select_right_handle,
               tuple(round(c, 3) for c in k.handle_left), tuple(round(c, 3) for c in k.handle_right))
              for k in fc.keyframe_points])
            for fc in bag.fcurves]


def everything():
    return {obj.name: (animation(obj), animation(obj.data) if obj.data is not None else None)
            for obj in bpy.data.objects}


def first_difference(want, got):
    for name in sorted(set(want) | set(got)):
        if want.get(name) != got.get(name):
            return name, "Blender:", want.get(name), "app:", got.get(name)
    return None


def both_ways(label, setup, operator, block):
    """Blender's operator under an override, then the Swift's string headless,
    each on a scene built the same way."""
    setup()
    _, _, want_error = quietly(lambda: _with_override(operator))
    want = everything()
    restore_preferences()
    setup()
    headless = bpy.context.area is None
    printed, _, got_error = quietly(lambda: run(block))
    got = everything()
    restore_preferences()
    check(label, headless and want == got, first_difference(want, got) or "not headless")
    return want_error, got_error, printed


def _with_override(operator):
    with bpy.context.temp_override(**override()):
        return operator()


print("headless, as on an iPad")
check("there is no 3D View area here, as there is none for bpy on a device",
      bpy.context.area is None, bpy.context.area)
check("which is why Blender's own Insert and Delete Keyframe refuse to run",
      not bpy.ops.anim.keyframe_insert.poll() and not bpy.ops.anim.keyframe_delete_v3d.poll())
check("and Blender 5 keeps keys in layered actions: there is no action.fcurves",
      not hasattr(bpy.types.Action, 'fcurves'))


# ---------------------------------------------------------------------------
print("\nI: what anim.keyframe_insert does, done headless")


def insert_default():
    sc = fresh()
    a = cube("A")
    cube("B", (4, 0, 0))
    select_only(a)
    sc.frame_set(1)


def insert_again():
    sc = fresh()
    a = cube("A")
    select_only(a)
    sc.frame_set(1)
    for path in ('location', 'rotation_euler', 'scale'):
        a.keyframe_insert(path, group='Object Transforms')
    a.location = (3, 2, 1)
    a.rotation_euler = (0.1, 0.2, 0.3)


def insert_modes_and_properties():
    sc = fresh()
    a = cube("Quat")
    a.rotation_mode = 'QUATERNION'
    a["amount"] = 1.5
    a["count"] = 3
    a["flag"] = True
    a["vec"] = [1.0, 2.0, 3.0]
    a["label"] = "text"
    b = cube("Axis", (4, 0, 0))
    b.rotation_mode = 'AXIS_ANGLE'
    select_only(a, b)
    sc.frame_set(7)


def insert_beside_older_keys():
    sc = fresh()
    a = cube("A")
    b = cube("B", (4, 0, 0))
    select_only(a)
    a.keyframe_insert("location", frame=1, group='Object Transforms')
    b.keyframe_insert("location", frame=1, group='Object Transforms')
    sc.frame_set(12)
    a.location.x = 5


def insert_breakdown_and_channels():
    sc = fresh()
    a = cube("A")
    select_only(a)
    sc.frame_set(4)
    sc.tool_settings.keyframe_type = 'BREAKDOWN'
    EDIT.key_insert_channels = {'LOCATION', 'ROTATE_MODE'}


def insert_only_needed():
    sc = fresh()
    a = cube("A")
    select_only(a)
    sc.frame_set(1)
    for path in ('location', 'rotation_euler', 'scale'):
        a.keyframe_insert(path, group='Object Transforms')
    sc.frame_set(10)
    a.location.x = 2
    EDIT.use_keyframe_insert_needed = True


def insert_pose():
    sc = fresh()
    bpy.ops.object.armature_add()
    rig = bpy.context.object
    rig.name = "Rig"
    bpy.ops.object.mode_set(mode='POSE')
    bone = rig.pose.bones[0]
    bone.select = True
    bone["twist"] = 0.5
    sc.frame_set(3)


insert = lambda: bpy.ops.anim.keyframe_insert()
both_ways("a selected cube gets location, rotation and scale, in Blender's group and colours; "
          "the cube beside it gets nothing", insert_default, insert, "INSERT")
both_ways("keying a frame that already has keys replaces them rather than adding more",
          insert_again, insert, "INSERT")
both_ways("quaternion and axis-angle rotation key their own properties, and custom properties "
          "are keyed where they can be", insert_modes_and_properties, insert, "INSERT")
both_ways("the keys already there are deselected, so the new ones are the selected ones",
          insert_beside_older_keys, insert, "INSERT")
both_ways("the key type, and the Default Key Channels preference, are Blender's",
          insert_breakdown_and_channels, insert, "INSERT")
both_ways("with Only Insert Needed, only what changed is keyed",
          insert_only_needed, insert, "INSERT")
both_ways("in pose mode the selected bone is keyed, in its own group", insert_pose, insert, "INSERT")


def insert_edit_mode():
    sc = fresh()
    a = cube("A")
    select_only(a)
    bpy.ops.object.mode_set(mode='EDIT')


def insert_nothing_selected():
    sc = fresh()
    cube("A")
    bpy.ops.object.select_all(action='DESELECT')


want_error, got_error, _ = both_ways("in edit mode nothing is keyed", insert_edit_mode, insert, "INSERT")
check("and both refuse with Blender's words", want_error is not None and got_error is not None
      and "Unsupported context mode" in want_error and "Unsupported context mode" in got_error,
      (want_error, got_error))
insert_nothing_selected()
printed, _, _ = quietly(lambda: _with_override(insert))
insert_nothing_selected()
_, _, got_error = quietly(lambda: run("INSERT"))
check("with nothing selected, the app says what Blender's status bar says",
      "Nothing selected to key" in printed and got_error == "Nothing selected to key",
      (printed, got_error))
bpy.ops.object.mode_set(mode='OBJECT') if bpy.context.object and bpy.context.object.mode != 'OBJECT' else None


# ---------------------------------------------------------------------------
print("\nAlt I: what anim.keyframe_delete_v3d does, done headless")


def keyed(obj, frames, paths=('location', 'rotation_euler', 'scale')):
    sc = bpy.context.scene
    for frame in frames:
        sc.frame_set(frame)
        obj.location.x += 1
        for path in paths:
            obj.keyframe_insert(path, group='Object Transforms')


def delete_two_of_three():
    sc = fresh()
    a, b, c = cube("A"), cube("B", (4, 0, 0)), cube("C", (8, 0, 0))
    for obj in (a, b, c):
        keyed(obj, (1, 10))
    select_only(a, b)
    sc.frame_set(1)


def delete_last_keys():
    sc = fresh()
    a = cube("A")
    keyed(a, (1,))
    select_only(a)
    sc.frame_set(1)


def delete_beside_data_and_other_frames():
    sc = fresh()
    a = cube("A")
    select_only(a)
    a.keyframe_insert("location", frame=1)
    a.keyframe_insert("scale", frame=5)
    a["amount"] = 2.0
    a.keyframe_insert('["amount"]', frame=1)
    a.data.keyframe_insert('vertices[0].co', frame=1)
    sc.frame_set(1)


def delete_locked():
    sc = fresh()
    a = cube("A")
    keyed(a, (1, 3))
    select_only(a)
    anim.channelbag(a.animation_data).fcurves.find("location", index=1).lock = True
    sc.frame_set(1)


def delete_subframe():
    sc = fresh()
    a = cube("A")
    select_only(a)
    a.keyframe_insert("location", frame=4.5)
    a.keyframe_insert("location", frame=8)
    sc.frame_set(4, subframe=0.5)


def delete_pose():
    sc = fresh()
    bpy.ops.object.armature_add()
    rig = bpy.context.object
    rig.name = "Rig"
    rig.keyframe_insert("location", frame=2)
    bpy.ops.object.mode_set(mode='POSE')
    bone = rig.pose.bones[0]
    bone.keyframe_insert("location", frame=2)
    bone.select = True
    sc.frame_set(2)


delete = lambda: bpy.ops.anim.keyframe_delete_v3d()
_, _, printed = both_ways("the selected objects lose this frame's keys, and the one not selected keeps its own",
                          delete_two_of_three, delete, "DELETE")
check("and the app reports it as Blender's status bar does",
      "2 object(s) successfully had 18 keyframes removed" in printed, printed)
both_ways("the last key on a curve takes the curve with it, and the action stays",
          delete_last_keys, delete, "DELETE")
both_ways("keys on other frames, and on the object's data, are left alone",
          delete_beside_data_and_other_frames, delete, "DELETE")
both_ways("a locked curve keeps its key", delete_locked, delete, "DELETE")
both_ways("a key on a subframe goes when the subframe is current", delete_subframe, delete, "DELETE")
both_ways("in pose mode only the selected bones' keys go", delete_pose, delete, "DELETE")


def delete_nothing_here():
    sc = fresh()
    a = cube("A")
    keyed(a, (1,))
    select_only(a)
    sc.frame_set(5)


want_error, got_error, _ = both_ways("where there is no key, nothing changes", delete_nothing_here, delete, "DELETE")
check("and the app says so in Blender's words", got_error == "No keyframes removed from 1 object(s)", got_error)


# ---------------------------------------------------------------------------
print("\nthe timeline's state comes back from Blender")
sc = fresh()
sc.frame_start, sc.frame_end = 10, 120
sc.render.fps, sc.render.fps_base = 30000, 1001
sc.frame_set(42)
sc.use_preview_range = True
sc.frame_preview_start, sc.frame_preview_end = 20, 60
sc.tool_settings.use_keyframe_insert_auto = True
sc.tool_settings.auto_keying_mode = 'REPLACE_KEYS'
sc.show_keys_from_selected_only = False
sc.playback_loop_mode = 'BOUNCE'
cube("Cube")
bridge.reset()
sync.sync()
state = bridge.state or ()
check("a full mirror reports it", bridge.state is not None)
check("the start, end and current frame", state[:3] == (10, 120, 42), state)
check("the rate is fps / fps_base, as Blender plays it", abs(state[4] - 30000 / 1001) < 1e-6, state)
check("the preview range", state[5:8] == (1, 20, 60), state)
check("auto keying and its Replace mode", state[8:10] == (1, 1), state)
check("Only Insert Available, a preference", state[10] == int(EDIT.use_keyframe_insert_available), state)
check("Only Show Selected, and the loop mode", state[11] == 0 and anim.LOOP_MODES[state[12]] == 'BOUNCE', state)


print("\nevery object's keys, across all its channels and all its data")
sc = fresh()
a = cube("A")
a.keyframe_insert("location", frame=1)
a.keyframe_insert("rotation_euler", frame=10)
a.keyframe_insert("scale", frame=10.004)
a["amount"] = 1.0
a.keyframe_insert('["amount"]', frame=15)
a.keyframe_insert("location", frame=4.5)
bpy.ops.object.light_add(type='POINT', location=(0, 0, 4))
lamp = bpy.context.object
lamp.name = "Lamp"
lamp.data.keyframe_insert("energy", frame=3)
bpy.ops.object.camera_add(location=(0, -8, 2))
cam = bpy.context.object
cam.name = "Cam"
cam.data.keyframe_insert("lens", frame=12)
shapey = cube("Shapey", (4, 0, 0))
shapey.shape_key_add(name="Basis")
shapey.shape_key_add(name="Up").keyframe_insert("value", frame=7)
material = bpy.data.materials.new("Keyed")
shader = next(n for n in material.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
shader.inputs["Base Color"].keyframe_insert("default_value", frame=21)
material.keyframe_insert("diffuse_color", frame=22)
shapey.data.materials.append(material)
sc.world.keyframe_insert("color", frame=30)
cube("Still", (8, 0, 0))
anim.channelbag(a.animation_data).fcurves.find("location", index=0).keyframe_points[0].select_control_point = False
for fcurve in anim.channelbag(a.animation_data).fcurves:
    if fcurve.data_path == 'location':
        for point in fcurve.keyframe_points:
            if abs(point.co.x - 1) < 0.01:
                point.select_control_point = False
bridge.reset()
sync.sync()
keys = bridge.keys or {}
frames = lambda name: [round(f, 3) for f, _ in keys.get(name, [])]
check("channels keyed at the same frame make one column, and near-equal frames merge",
      frames("A") == [1.0, 4.5, 10.0, 15.0], keys.get("A"))
check("a light is keyed on its data", frames("Lamp") == [3.0], keys.get("Lamp"))
check("and a camera's lens", frames("Cam") == [12.0], keys.get("Cam"))
check("shape keys, a material and its node tree count as the object's",
      frames("Shapey") == [7.0, 21.0, 22.0], keys.get("Shapey"))
check("an object with no keys is not in the report", "Still" not in keys, list(keys))
check("the world's keys are the scene's", [round(f, 3) for f, _ in bridge.scene_keys] == [30.0],
      bridge.scene_keys)
check("a key Blender left selected shows selected, and one deselected shows not",
      dict(keys.get("A", []))[1.0] == 0 and dict(keys.get("A", []))[10.0] == 1, keys.get("A"))


# ---------------------------------------------------------------------------
print("\na frame change hands over only what the frame changed")


def depsgraph_scene():
    sc = fresh()
    mover = cube("Mover")
    mover.keyframe_insert("location", frame=1)
    mover.location = (5, 0, 0)
    mover.keyframe_insert("location", frame=11)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 2, 0))
    child = bpy.context.object
    child.name = "Child"
    child.parent = mover
    static = cube("StaticSubsurf", (0, -4, 0))
    static.modifiers.new("Subdivision", 'SUBSURF')
    shapey = cube("Shapey", (4, 4, 0))
    shapey.shape_key_add(name="Basis")
    up = shapey.shape_key_add(name="Up")
    for point in up.data:
        point.co.z += 1.0
    up.value = 0.0
    up.keyframe_insert("value", frame=1)
    up.value = 1.0
    up.keyframe_insert("value", frame=11)
    bpy.ops.object.armature_add(location=(-4, 4, 0))
    rig = bpy.context.object
    rig.name = "Rig"
    bone = rig.pose.bones[0]
    bone.rotation_mode = 'XYZ'
    bone.keyframe_insert("rotation_euler", frame=1)
    bone.rotation_euler = (1.0, 0, 0)
    bone.keyframe_insert("rotation_euler", frame=11)
    rigged = cube("Rigged", (-4, 4, 0.5))
    rigged.modifiers.new("Armature", 'ARMATURE').object = rig
    rigged.vertex_groups.new(name=rig.data.bones[0].name).add(
        list(range(len(rigged.data.vertices))), 1.0, 'REPLACE')
    bpy.ops.mesh.primitive_grid_add(size=2, location=(0, 8, 0))
    waver = bpy.context.object
    waver.name = "Waver"
    waver.modifiers.new("Wave", 'WAVE')
    bender = cube("KeyedModifier", (8, 0, 0))
    bend = bender.modifiers.new("Bend", 'SIMPLE_DEFORM')
    bend.deform_method = 'BEND'
    bend.angle = 0
    bender.keyframe_insert('modifiers["Bend"].angle', frame=1)
    bend.angle = 1.0
    bender.keyframe_insert('modifiers["Bend"].angle', frame=11)
    bpy.ops.object.light_add(type='POINT', location=(0, 0, 5))
    lamp = bpy.context.object
    lamp.name = "Lamp"
    lamp.data.energy = 10
    lamp.data.keyframe_insert("energy", frame=3)
    cube("Still", (0, 0, 9))
    sc.frame_set(1)
    return sc


sc = depsgraph_scene()
bridge.reset()
sync.sync()
bridge.reset()
printed, _, error = quietly(lambda: run("FRAME_SET"))
update = bridge.frames[-1] if bridge.frames else {}
check("the Swift's frame change runs", error is None, error)
check("and never costs a mirroring pass", bridge.pushed == {} and bridge.state is None, bridge.pushed)
check("the frame arrives, with its subframe", update.get("frame") == 6 and update.get("subframe") == 0.0, update)
moved = set(update.get("names", []))
check("the keyed object's matrix comes back, and its child's", {"Mover", "Child"} <= moved, moved)
check("and nothing else's", not moved - {"Mover", "Child"}, moved)
depsgraph = bpy.context.evaluated_depsgraph_get()
wanted = [c for row in bpy.data.objects["Mover"].evaluated_get(depsgraph).matrix_world for c in row]
check("the matrix is Blender's evaluated one, row-major",
      all(abs(g - w) < 1e-5 for g, w in zip(update.get("matrices", {}).get("Mover", []), wanted)),
      (update.get("matrices", {}).get("Mover"), wanted))
deformed = {m["name"] for m in bridge.meshes}
check("a mesh comes back only where the frame deformed it: shape keys, an armature, "
      "a keyed modifier, a time-dependent one", deformed == {"Shapey", "Rigged", "KeyedModifier", "Waver"},
      deformed)
evaluated = bpy.data.objects["Shapey"].evaluated_get(depsgraph).to_mesh()
wanted = [c for v in evaluated.vertices for c in v.co]
bpy.data.objects["Shapey"].evaluated_get(depsgraph).to_mesh_clear()
shape = next((m for m in bridge.meshes if m["name"] == "Shapey"), {"co": []})
check("the deformed mesh is the evaluated mesh at that frame",
      len(shape["co"]) == len(wanted) and all(abs(g - w) < 1e-5 for g, w in zip(shape["co"], wanted)))
check("no full mirror is asked for", anim.FULL_MIRROR not in printed, printed)

hider = cube("Hider", (0, 12, 0))
hider.hide_viewport = False
hider.keyframe_insert("hide_viewport", frame=1)
hider.hide_viewport = True
hider.keyframe_insert("hide_viewport", frame=10)
sc.frame_set(1)
bridge.reset()
sync.sync()
printed, _, _ = quietly(lambda: anim.frame_set(10))
check("keyed visibility asks for a whole mirror, which is the only way an object appears or goes",
      anim.FULL_MIRROR in printed, printed)



# `push_frame` also hands over each moved object's own channels, for the Apply
# menu. That push once raised for a name the screen did not hold — before
# `anim_frame` was sent — and the timeline stopped a frame behind Blender. The
# objects here are ones the mirror has held back at some point: a plain curve
# and an emptied mesh (no triangles), and two keyed after the last pass. A
# deformed mesh's push, `anim_mesh`, raised the same way.
print("\na frame change arrives whatever becomes of the objects' own channels")
sc = fresh()
keyed = cube("Keyed")
bpy.ops.curve.primitive_bezier_curve_add(location=(0, 4, 0))
curve = bpy.context.object
curve.name = "Curve"
emptied = cube("Emptied", (0, -4, 0))
emptied.data.clear_geometry()
for obj, offset in ((keyed, (3, 0, 0)), (curve, (0, 3, 0)), (emptied, (0, 0, 3))):
    obj.keyframe_insert("location", frame=1)
    obj.location = [a + b for a, b in zip(obj.location, offset)]
    obj.keyframe_insert("location", frame=10)
sc.frame_set(1)
bridge.reset()
sync.sync()
late = cube("Late", (0, 0, 6))
late.keyframe_insert("location", frame=1)
late.location = (0, 0, 9)
late.keyframe_insert("location", frame=10)
# And one deformed by a keyed shape key, which reaches `anim_mesh` instead.
late_shape = cube("LateShape", (6, 0, 0))
late_shape.shape_key_add(name="Basis")
up = late_shape.shape_key_add(name="Up")
for point in up.data:
    point.co.z += 1.0
up.value = 0.0
up.keyframe_insert("value", frame=1)
up.value = 1.0
up.keyframe_insert("value", frame=10)
sc.frame_set(1)
bridge.reset()
printed, _, error = quietly(lambda: anim.frame_set(10))
update = bridge.frames[-1] if bridge.frames else {}
check("a keyed object the mirror has not held yet does not stop the frame", error is None, error)
check("and one it cannot deform asks for the whole mirror that brings it in",
      anim.FULL_MIRROR in printed, printed)
check("every keyed object's matrix arrives, the mirrored cube's included",
      set(update.get("names", [])) == {"Keyed", "Curve", "Emptied", "Late"}, update.get("names"))
check("the channels of the objects on screen follow the playhead",
      abs(bridge.local.get("Keyed", [0])[0] - 3.0) < 1e-5 and "Curve" in bridge.local
      and "Emptied" in bridge.local, bridge.local)
check("and the object not on screen has none, rather than an error", "Late" not in bridge.local,
      bridge.local)
bridge.refuse_local = True
try:
    bridge.reset()
    _, _, error = quietly(lambda: anim.frame_set(5))
    update = bridge.frames[-1] if bridge.frames else {}
    check("with every object's channels refused, the frame still arrives, with all four",
          error is None and update.get("frame") == 5 and len(update.get("names", [])) == 4,
          (error, update.get("frame"), update.get("names")))
    bridge.reset()
    printed, _, error = quietly(lambda: sync.sync())
    check("and a mirroring pass still completes, saying whose channels were not taken",
          error is None and {"Keyed", "Curve", "Emptied", "Late"} <= bridge.screen
          and "Keyed transform channels were not taken" in printed, (error, printed[-300:]))
finally:
    bridge.refuse_local = False

# ---------------------------------------------------------------------------
print("\nauto keying: the gizmo's own transforms, as BpyBridge.run sends them")
check("with the record button off, a transform is sent exactly as it was",
      blocks["GIZMO_TRANSLATE_OFF"] == blocks["GIZMO_TRANSLATE_BARE"],
      (blocks["GIZMO_TRANSLATE_OFF"], blocks["GIZMO_TRANSLATE_BARE"]))
check("with it on, the auto keying follow-up comes after the transform, in the same evaluation",
      blocks["GIZMO_TRANSLATE"].startswith(blocks["GIZMO_TRANSLATE_BARE"] + "\n")
      and blocks["GIZMO_TRANSLATE"].endswith("after_transform('TRANSLATE')"), blocks["GIZMO_TRANSLATE"])


def gizmo(block, keyed_first=False, two=False, replace=False, edit=False):
    sc = fresh()
    objects = [cube("A")]
    if two:
        objects.append(cube("B", (4, 0, 0)))
    select_only(*objects)
    if keyed_first:
        for obj in objects:
            obj.keyframe_insert("location", frame=1, group='Object Transforms')
    sc.tool_settings.use_keyframe_insert_auto = True
    if replace:
        sc.tool_settings.auto_keying_mode = 'REPLACE_KEYS'
    if edit:
        bpy.ops.object.mode_set(mode='EDIT')
    sc.frame_set(10)
    bridge.reset()
    _, _, error = quietly(lambda: run(block))
    if edit:
        bpy.ops.object.mode_set(mode='OBJECT')
    curves = {obj.name: sorted({fc.data_path for fc in (anim.channelbag(obj.animation_data).fcurves
                                                       if anim.channelbag(obj.animation_data) else [])})
              for obj in objects}
    at_ten = {obj.name: sorted({fc.data_path for fc in (anim.channelbag(obj.animation_data).fcurves
                                                       if anim.channelbag(obj.animation_data) else [])
                                if any(abs(k.co.x - 10) < 0.01 for k in fc.keyframe_points)})
              for obj in objects}
    return error, curves, at_ten, list(bridge.notices)


report = lambda n: anim.AUTOKEY_REPORT % n
check("Blender 5.2.1's factory preferences only auto key what is already animated",
      EDIT.use_keyframe_insert_available is True, EDIT.use_keyframe_insert_available)
error, curves, at_ten, notices = gizmo("GIZMO_TRANSLATE")
check("so a move of an unkeyed cube keys nothing, as in Blender", error is None and curves == {"A": []},
      (error, curves))
check("and the app says why, in Blender's words", notices == [report(1)], notices)
error, curves, at_ten, notices = gizmo("GIZMO_TRANSLATE", keyed_first=True)
check("a move of a keyed cube keys its location on the frame, inside Blender's transform",
      at_ten == {"A": ["location"]} and notices == [], (at_ten, notices))
error, curves, at_ten, notices = gizmo("GIZMO_ROTATE_VIEW", keyed_first=True)
check("a rotation of it creates no rotation curve", at_ten == {"A": []}, at_ten)
check("and that is said too, counted as Blender counts it", notices == [report(3)], notices)
EDIT.use_keyframe_insert_available = False
error, curves, at_ten, notices = gizmo("GIZMO_TRANSLATE")
check("with Only Insert Available off, a move keys location", at_ten == {"A": ["location"]} and not notices,
      (at_ten, notices))
error, curves, at_ten, notices = gizmo("GIZMO_RESIZE")
check("a scale keys scale", at_ten == {"A": ["scale"]}, at_ten)
error, curves, at_ten, notices = gizmo("GIZMO_ROTATE_VIEW", two=True)
check("the view ring on two objects keys location and rotation on both, about their median",
      at_ten == {"A": ["location", "rotation_euler"], "B": ["location", "rotation_euler"]}, at_ten)
check("which is exactly the set the app predicts from Blender's transform code",
      all(sorted(anim.autokey_paths(bpy.data.objects[n], 'ROTATE', True)) == at_ten[n] for n in at_ten),
      [anim.autokey_paths(bpy.data.objects[n], 'ROTATE', True) for n in at_ten])
error, curves, at_ten, notices = gizmo("GIZMO_TRANSLATE", keyed_first=True, replace=True)
check("in Replace mode, a frame with no key gets none, and nothing is reported",
      at_ten == {"A": []} and notices == [], (at_ten, notices))
error, curves, at_ten, notices = gizmo("GIZMO_TRANSLATE", edit=True)
check("in edit mode a transform moves vertices and keys nothing", curves == {"A": []} and not notices,
      (curves, notices))
restore_preferences()
EDIT.use_keyframe_insert_available = False
sc = fresh()
unkeyed = cube("A")
select_only(unkeyed)
sc.tool_settings.use_keyframe_insert_auto = True
two = cube("B", (4, 0, 0))
select_only(unkeyed, two)
EDIT.use_keyframe_insert_available = True
bridge.reset()
quietly(lambda: run("GIZMO_ROTATE_VIEW"))
check("two unkeyed objects rotated: Blender counts two curves it could not create",
      bridge.notices == [report(2)], bridge.notices)
restore_preferences()


# ---------------------------------------------------------------------------
print("\nthe timeline's settings reach Blender")
sc = fresh()
cube("A")
bridge.reset()
run("AUTOKEY_ON")
check("the record button turns on Blender's auto keying, and says so back",
      sc.tool_settings.use_keyframe_insert_auto and bridge.state and bridge.state[8] == 1, bridge.state)
run("AUTOKEY_REPLACE")
check("Replace", sc.tool_settings.auto_keying_mode == 'REPLACE_KEYS' and bridge.state[9] == 1)
run("AUTOKEY_ADD_REPLACE")
check("and Add & Replace", sc.tool_settings.auto_keying_mode == 'ADD_REPLACE_KEYS' and bridge.state[9] == 0)
run("ONLY_AVAILABLE_OFF")
check("Only Insert Available, which is a preference in Blender",
      EDIT.use_keyframe_insert_available is False and bridge.state[10] == 0)
run("ONLY_AVAILABLE_ON")
check("both ways", EDIT.use_keyframe_insert_available is True and bridge.state[10] == 1)
run("ONLY_SELECTED_OFF")
check("Only Show Selected", sc.show_keys_from_selected_only is False)
run("LOOP_BOUNCE")
check("the loop mode", sc.playback_loop_mode == 'BOUNCE')
run("PREVIEW_ON")
check("the preview range", sc.use_preview_range is True)
restore_preferences()

print("\nthe frame range follows Blender's rules, in the Swift as in Blender")
for name, before, label in (("START_300", (1, 250), "a start past the end takes the end with it"),
                            ("END_NEGATIVE", (1, 250), "an end below 0 is 0, and takes the start with it"),
                            ("END_BEFORE_START", (20, 30), "an end before the start takes the start with it")):
    sc = fresh()
    sc.frame_start, sc.frame_end = before
    run(name)
    wanted = tuple(int(x) for x in blocks[name + "_EXPECT"].split())
    check(label, (sc.frame_start, sc.frame_end) == wanted, ((sc.frame_start, sc.frame_end), wanted))
sc.frame_current = -3
check("a negative current frame is frame 0 in both", sc.frame_current == int(blocks["CURRENT_NEGATIVE_EXPECT"]))
check("and the Start field sends the value Blender keeps, as one command",
      blocks["DRIVER_START"] == "bpy.context.scene.frame_start = 300", blocks["DRIVER_START"])


def preview():
    return (bpy.context.scene.frame_preview_start, bpy.context.scene.frame_preview_end)


def expected(name):
    return tuple(int(x) for x in blocks[name].split())


print("\nthe preview range follows Blender's rules too")
sc = fresh()
sc.frame_start, sc.frame_end = 12, 90
run("PREVIEW_ON")
check("switched on with none set, it takes the scene range, as the Swift predicts",
      sc.use_preview_range and preview() == expected("PREVIEW_SEED_EXPECT"), (preview(), expected("PREVIEW_SEED_EXPECT")))
sc.frame_preview_start, sc.frame_preview_end = 30, 40
sc.use_preview_range = False
run("PREVIEW_ON")
check("switched on again, it keeps the range it had", preview() == expected("PREVIEW_KEEP_EXPECT"),
      (preview(), expected("PREVIEW_KEEP_EXPECT")))
run("PREVIEW_START_50")
check("a start past its end takes the end with it", preview() == expected("PREVIEW_START_50_EXPECT"),
      (preview(), expected("PREVIEW_START_50_EXPECT")))
sc.frame_preview_start, sc.frame_preview_end = 30, 40
run("PREVIEW_END_10")
check("an end before its start takes the start with it", preview() == expected("PREVIEW_END_10_EXPECT"),
      (preview(), expected("PREVIEW_END_10_EXPECT")))


# ---------------------------------------------------------------------------
print("\nBlender's own keyframe jumps, recorded for the Swift to replay")


def jump_scene():
    sc = fresh()
    j1 = cube("J1")
    for frame in (1, 20, 4.4):
        j1.keyframe_insert("location", frame=frame)
    j2 = cube("J2", (3, 0, 0))
    j2.keyframe_insert("location", frame=8)
    j3 = cube("J3", (6, 0, 0))
    j3.keyframe_insert("location", frame=5)
    j3.data.keyframe_insert('vertices[0].co', frame=13)
    bpy.ops.object.light_add(type='POINT', location=(0, 0, 4))
    lamp = bpy.context.object
    lamp.name = "Lamp"
    lamp.data.keyframe_insert("energy", frame=16)
    sc.world.keyframe_insert("color", frame=30)
    select_only(j1, j2)
    return sc


def blender_walk(sc, start, forward):
    sc.frame_set(int(start), subframe=start - int(start))
    visited = []
    for _ in range(12):
        _, result, _ = quietly(lambda: _jump(forward))
        if not result or 'FINISHED' not in result:
            break
        visited.append(round(sc.frame_float, 4))
    return visited


def _jump(forward):
    with bpy.context.temp_override(**override('DOPESHEET_EDITOR')):
        return bpy.ops.screen.keyframe_jump(next=forward)


scenarios = []
for only_selected in (True, False):
    sc = jump_scene()
    sc.show_keys_from_selected_only = only_selected
    bridge.reset()
    sync.sync()
    label = "Only Show Selected " + ("on" if only_selected else "off")
    forward = blender_walk(sc, 0.0, True)
    backward = blender_walk(sc, 31.0, False)
    print("        %s: Blender's Next Keyframe from 0 visits %s" % (label, forward))
    scenarios.append(dict(label=label, objects=[o.name for o in sc.objects],
                          selected=[o.name for o in sc.objects if o.select_get()],
                          onlySelected=only_selected, report=bridge.raw_keys,
                          startFrame=0.0, next=forward, previous=backward, previousFrom=31.0))
check("both recorded", len(scenarios) == 2 and all(s["next"] for s in scenarios))
with open(MIRROR_JSON, "w") as handle:
    json.dump(scenarios, handle)


# ---------------------------------------------------------------------------
print("\nhow long a frame change takes, on a typical scene")
sc = fresh()
for i in range(20):
    obj = cube("Anim%02d" % i, (i % 5 * 3, i // 5 * 3, 0))
    obj.keyframe_insert("location", frame=1)
    obj.keyframe_insert("rotation_euler", frame=1)
    obj.location.z += 2
    obj.rotation_euler.z = 3.0
    obj.keyframe_insert("location", frame=60)
    obj.keyframe_insert("rotation_euler", frame=60)
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, location=(0, -6, 0))
sphere = bpy.context.object
sphere.name = "ShapeKeyed"
sphere.shape_key_add(name="Basis")
bulge = sphere.shape_key_add(name="Bulge")
for point in bulge.data:
    point.co *= 1.3
bulge.value = 0.0
bulge.keyframe_insert("value", frame=1)
bulge.value = 1.0
bulge.keyframe_insert("value", frame=60)
bpy.ops.object.armature_add(location=(8, -6, 0))
rig = bpy.context.object
bone = rig.pose.bones[0]
bone.rotation_mode = 'XYZ'
bone.keyframe_insert("rotation_euler", frame=1)
bone.rotation_euler = (1.2, 0, 0)
bone.keyframe_insert("rotation_euler", frame=60)
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, location=(8, -6, 1))
skinned = bpy.context.object
skinned.name = "Skinned"
skinned.modifiers.new("Armature", 'ARMATURE').object = rig
skinned.vertex_groups.new(name=rig.data.bones[0].name).add(
    list(range(len(skinned.data.vertices))), 1.0, 'REPLACE')
static = cube("Static", (-8, -6, 0))
static.modifiers.new("Subdivision", 'SUBSURF').levels = 2
# The set the animation plays on: dense, and never animated.
bpy.ops.mesh.primitive_grid_add(x_subdivisions=316, y_subdivisions=316, size=60, location=(0, 0, -2))
ground = bpy.context.object
ground.name = "Ground"
sc.frame_set(1)
bridge.reset()
sync.sync()
bridge.light = True
start = time.perf_counter()
for frame in range(2, 122):
    anim.frame_set(frame % 60 + 1)
partial = (time.perf_counter() - start) / 120 * 1000
bridge.light = False
counts_per_frame = len(bridge.meshes) / 120
start = time.perf_counter()
for frame in range(2, 62):
    sc.frame_set(frame)
    sync.sync()
whole = (time.perf_counter() - start) / 60 * 1000
start = time.perf_counter()
for _ in range(20):
    anim.report()
keys_report = (time.perf_counter() - start) / 20 * 1000
vertex_total = sum(len(o.data.vertices) for o in sc.objects if o.type == 'MESH')
print("        scene: 20 keyed cubes, a shape-keyed sphere and an armature-skinned one (%d vertices each), "
      "a subdivided cube, and a %d-vertex ground nothing animates"
      % (len(sphere.data.vertices), len(ground.data.vertices)))
print("        frame change, only what changed:   %.2f ms  (%.1f meshes a frame)" % (partial, counts_per_frame))
print("        frame change, whole mirror (before): %.2f ms" % whole)
print("        the keys report after a command:  %.2f ms" % keys_report)
check("a frame change fits in a quarter of 24 fps' 41.7 ms", partial < 41.7 / 4, partial)
check("and in a quarter of a 60 Hz refresh too", partial < 16.7 / 4, partial)
check("it is cheaper than the whole mirroring pass it replaces", partial < whole, (partial, whole))
check("only the two deformed spheres' meshes are read back each frame", abs(counts_per_frame - 2) < 1e-9,
      counts_per_frame)

# A frame change while editing, with faces hidden: round 2's review measured
# the evaluated mesh keeping all 200 triangles of a Wave grid with 50 faces
# hidden, and the frame drawing them again where the pass drew 150. Here a
# 10 x 10 grid, 100 faces, 50 of them hidden.
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10, size=4)
waved = bpy.context.object
waved.name = "Waved"
waved.modifiers.new("Wave", 'WAVE')
bpy.ops.object.mode_set(mode='EDIT')
import bmesh
bm = bmesh.from_edit_mesh(waved.data)
bm.faces.ensure_lookup_table()
for f in list(bm.faces)[:50]:
    f.hide_set(True)
bmesh.update_edit_mesh(waved.data)
sc.frame_set(1)
bridge.reset()
sync.sync()
bridge.meshes = []
anim.frame_set(9)
sent = next((m for m in bridge.meshes if isinstance(m, dict) and m["name"] == "Waved"), None)
check("a frame change in Edit Mode sends the grid without its 50 hidden faces (100 of 200 triangles)",
      sent is not None and sent["tris"] == 100, sent and sent["tris"])
bpy.ops.object.mode_set(mode='OBJECT')
bridge.meshes = []
anim.frame_set(8)
sent = next((m for m in bridge.meshes if isinstance(m, dict) and m["name"] == "Waved"), None)
check("and in Object Mode, where Blender draws hidden faces, all 200",
      sent is not None and sent["tris"] == 200, sent and sent["tris"])

# Every object keyed: round 2's review measured the Swift side of this walking
# the screen per moved object, and desktop 5.2.1's cProfile showed the Python
# side doing the same — `scene.objects.get` per changed name, 154 of 212 ms a
# frame at 3,000 keyed empties (28.8 ms at 1,000). push_frame now looks names
# up in one table a frame, built from scene.objects. (Round 2 took each object
# from the update's `id.original` instead, which segfaulted once a frame
# handler deleted objects: handler_removes.py.) Measured with the table, on
# this Mac: 37.3 ms at 3,000, of which a bare frame_set is 13.9 ms.
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
count = 3000
for i in range(count):
    e = bpy.data.objects.new("Keyed.%04d" % i, None)
    sc.collection.objects.link(e)
    e.location = (i % 60, i // 60, 0)
    e.keyframe_insert("location", frame=1)
    e.location.z = 5
    e.keyframe_insert("location", frame=10)
sc.frame_set(1)
bridge.reset()
sync.sync()
bridge.light = True
start = time.perf_counter()
for frame in range(2, 10):
    anim.frame_set(frame)
every = (time.perf_counter() - start) / 8 * 1000
bridge.light = False
start = time.perf_counter()
for frame in range(2, 10):
    sc.frame_set(frame)
bare = (time.perf_counter() - start) / 8 * 1000
print("        %d keyed empties: a frame change %.1f ms, of which Blender's own frame_set %.1f ms"
      % (count, every, bare))
# What remains is push_local reading each object's channels (8.7 µs apiece
# in cProfile), linear in what moved.
# The bound leaves room for a loaded machine: with the load average at 92 the
# same run measured 45 ms, and the lookups alone made it 191 unloaded.
check("with 3,000 objects keyed, the mirror's share of a frame is under 100 ms "
      "(the name lookups made it 191)", every - bare < 100, (every, bare))

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
