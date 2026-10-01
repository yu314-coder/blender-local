"""The simulator's side of animation, on the Mac, against a model of the app.

The simulator is how the app is photographed, and it cannot be booted to check
this, so the shim's animation is run here with `_blenderkit` replaced by a
small model of the Swift it calls: BKScene's animation state and BKObject's
keys, answering the way `bk_anim_*` and `bk_scene_keyframe` do. What is checked
is the shim's Python — Resources/python/site/bpy and _blenderkit_anim — and the
calls it makes. The Swift behind those calls is tests/animation/main.swift's.
"""
import contextlib
import io
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources/python/site"))
sys.dont_write_bytecode = True

fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


class App(types.ModuleType):
    """A model of the Swift the shim's bridge reaches."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.reset()

    def reset(self):
        self.objects = {}
        self.order = []
        self.active = None
        self.editing = False
        # SceneAnimation's defaults, which are Blender 5.2.1's factory settings.
        self.state = [1, 250, 1, 0.0, 24.0, 0, 0, 0, 0, 0, 1, 1, 0]
        self.notices = []

    def add(self, name, selected=True):
        self.objects[name] = dict(location=[0.0, 0.0, 0.0], rotation_euler=[0.0, 0.0, 0.0],
                                  scale=[1.0, 1.0, 1.0], selected=selected, keys={})
        self.order.append(name)
        if selected:
            self.active = name

    def keys(self, name):
        return {path: dict(frames) for path, frames in self.objects[name]["keys"].items() if frames}

    # The scene, as the shim reads it.
    def object_names(self):
        return list(self.order)

    def is_selected(self, name):
        return self.objects[name]["selected"]

    def active_name(self):
        return self.active

    def mode(self):
        return "EDIT" if self.editing else "OBJECT"

    def get_vec(self, name, prop):
        return tuple(self.objects[name][prop])

    def set_vec(self, name, prop, x, y, z):
        self.objects[name][prop] = [x, y, z]

    def transform_operator(self, call):
        """bk_scene_transform_operator, for the one call this suite makes: a
        plain move of the selection. The rest of TransformOperation is
        tests/tools/main.swift's."""
        import json
        request = json.loads(call)
        assert request["kind"] == "translate" and request["proportional"] is None, request
        moved = 0
        for obj in self.objects.values():
            if not obj["selected"]:
                continue
            obj["location"] = [a + b for a, b in zip(obj["location"], request["value"])]
            moved += 1
        return moved

    def set_frame(self, frame):
        if frame >= 0:
            self.state[2] = int(frame)
        return self.state[2]

    def keyframe(self, name, path, frame, insert):
        """bk_scene_keyframe: the channel's value now, at that frame."""
        frames = self.objects[name]["keys"].setdefault(path, {})
        if insert:
            frames[frame] = list(self.objects[name][path])
        else:
            frames.pop(frame, None)

    # The animation calls.
    def anim_state(self, *values):
        self.state = list(values)

    def anim_state_get(self):
        return tuple(self.state)

    def anim_channels(self, name):
        """AnimationMirror.channels: 'path:frame,frame' per keyed channel."""
        return "\n".join("%s:%s" % (path, ",".join(str(f) for f in sorted(frames)))
                         for path, frames in sorted(self.objects[name]["keys"].items()) if frames)

    def anim_notice(self, text):
        self.notices.append(text)


app = App()
sys.modules["_blenderkit"] = app
import bpy  # noqa: E402  the shim, over the model
import _blenderkit_anim as anim  # noqa: E402


def quietly(fn):
    buffer = io.StringIO()
    result, error = None, None
    with contextlib.redirect_stdout(buffer):
        try:
            result = fn()
        except Exception as exc:
            error = str(exc)
    return buffer.getvalue(), result, error


def run(source):
    exec(compile(source, "<ui>", "exec"), {"bpy": bpy})


print("the shim")
check("is not Blender, and the module can tell", not anim.is_real_blender())

print("\nthe scene's animation settings")
sc = bpy.context.scene
sc.frame_start = 300
check("a start past the end takes the end with it, as Blender's does", (sc.frame_start, sc.frame_end) == (300, 300),
      (sc.frame_start, sc.frame_end))
sc.frame_start = 1
sc.frame_end = -5
check("an end below 0 is 0, and takes the start with it", (sc.frame_start, sc.frame_end) == (0, 0),
      (sc.frame_start, sc.frame_end))
sc.frame_end = 250
sc.frame_start = 1
run("bpy.context.scene.frame_end = 120")
check("the Python the End field sends works here too", sc.frame_end == 120 and app.state[1] == 120)
sc.render.fps = 30
check("the rate", app.state[4] == 30.0 and sc.render.fps == 30, app.state)
sc.render.fps_base = 1.001
check("which fps_base divides, as Blender plays it", abs(app.state[4] - 30 / 1.001) < 1e-9 and sc.render.fps == 30,
      app.state)
sc.render.fps_base = 1.0
sc.render.fps = 24
sc.render.resolution_percentage = 50
check("and the resolution beside it: one RenderSettings, as in Blender, not the rate's or the cameras'",
      sc.render.resolution_percentage == 50 and sc.render.resolution_x == 1920 and sc.render.fps == 24,
      (sc.render.resolution_percentage, sc.render.resolution_x, sc.render.fps))
sc.render.resolution_percentage = 100
_, _, error = quietly(lambda: setattr(sc.render, "frames_per_second", 30))
check("which still refuses a name Blender's has not got", error is not None and "frames_per_second" in error, error)
run("bpy.context.scene.use_preview_range = True")
check("switching on a preview range that was never set copies the scene range, as Blender does",
      app.state[5] == 1 and app.state[6:8] == [sc.frame_start, sc.frame_end] == [1, 120], app.state)
sc.frame_preview_end = 40
sc.frame_preview_start = 50
check("the preview range, with Blender's rule for its ends", app.state[5] == 1 and app.state[6:8] == [50, 50],
      app.state)
run("bpy.context.scene.use_preview_range = False")
run("bpy.context.scene.playback_loop_mode = 'BOUNCE'")
check("the loop mode", app.state[12] == 4 and sc.playback_loop_mode == 'BOUNCE')
_, _, error = quietly(lambda: setattr(sc, "playback_loop_mode", "SIDEWAYS"))
check("and a loop mode Blender has not got is refused", error is not None and "SIDEWAYS" in error, error)
run("bpy.context.scene.playback_loop_mode = 'INFINITE'")
run("bpy.context.scene.show_keys_from_selected_only = False")
check("Only Show Selected", app.state[11] == 0)
run("bpy.context.scene.show_keys_from_selected_only = True")
sc.tool_settings.use_keyframe_insert_auto = True
check("scene.tool_settings.use_keyframe_insert_auto, for scripts", app.state[8] == 1)
sc.tool_settings.use_keyframe_insert_auto = False
check("the shim's own frame_set is kept, not replaced",
      "how a script moves the playhead" in (bpy.types.Scene.__dict__["frame_set"].__doc__ or ""))

print("\nI and Alt I")
app.add("Cube")
app.add("Other", selected=False)
anim.frame_set(5)
check("the frame changes through the shim", app.state[2] == 5)
run("import _blenderkit_anim\n_blenderkit_anim.keyframe_insert()")
check("I keys the selection's location, rotation and scale at the current frame",
      app.keys("Cube") == {"location": {5: [0.0, 0.0, 0.0]}, "rotation_euler": {5: [0.0, 0.0, 0.0]},
                           "scale": {5: [1.0, 1.0, 1.0]}}, app.keys("Cube"))
check("and nothing else", app.keys("Other") == {})
app.objects["Cube"]["location"] = [2.0, 0.0, 0.0]
anim.keyframe_insert()
check("keying the frame again replaces its key", app.keys("Cube")["location"] == {5: [2.0, 0.0, 0.0]})
app.editing = True
_, _, error = quietly(anim.keyframe_insert)
check("in edit mode it refuses, in Blender's words", error == "Unsupported context mode", error)
app.editing = False
app.objects["Cube"]["selected"] = False
_, _, error = quietly(anim.keyframe_insert)
check("with nothing selected, it says so", error == "Nothing selected to key", error)
app.objects["Cube"]["selected"] = True
printed, _, error = quietly(lambda: run("import _blenderkit_anim\n_blenderkit_anim.keyframe_delete_v3d()"))
check("Alt I removes this frame's keys", app.keys("Cube") == {} and error is None, (app.keys("Cube"), error))
check("and reports it as Blender does", "1 object(s) successfully had 3 keyframes removed" in printed, printed)
_, _, error = quietly(anim.keyframe_delete_v3d)
check("with nothing left to remove, it says that too", error == "No keyframes removed from 1 object(s)", error)

print("\na script keying at a frame")
cube = bpy.data.objects["Cube"]
before = list(app.objects["Cube"]["location"])
app.objects["Cube"]["location"] = [0.0, 0.0, 0.0]
cube.keyframe_insert("location", frame=1)
app.objects["Cube"]["location"] = [3.0, 0.0, 0.0]
cube.keyframe_insert("location", frame=60)
check("obj.keyframe_insert(frame=60) keys the value set just before it, at 60",
      app.keys("Cube") == {"location": {1: [0.0, 0.0, 0.0], 60: [3.0, 0.0, 0.0]}}, app.keys("Cube"))
check("and leaves the playhead where it was, as Blender does", app.state[2] == 5, app.state[2])
cube.keyframe_delete("location", frame=60)
check("keyframe_delete(frame=60) removes that key alone, and the playhead stays",
      app.keys("Cube") == {"location": {1: [0.0, 0.0, 0.0]}} and app.state[2] == 5, (app.keys("Cube"), app.state[2]))
cube.keyframe_delete("location", frame=1)
app.objects["Cube"]["location"] = before

print("\nauto keying after a gizmo transform")
anim.set_auto_keying(on=True)
check("the record button", app.state[8] == 1)
app.notices = []
bpy.ops.transform.translate(value=(1, 0, 0))
anim.after_transform('TRANSLATE')
check("with Only Insert Available on, as Blender 5.2.1 starts, an unkeyed cube is not keyed",
      app.keys("Cube") == {}, app.keys("Cube"))
check("and the app says why, in Blender's words", app.notices == [anim.AUTOKEY_REPORT % 1], app.notices)
anim.set_auto_keying(only_available=False)
check("the popover's Only Insert Available", app.state[10] == 0)
bpy.ops.transform.translate(value=(1, 0, 0))
anim.after_transform('TRANSLATE')
check("with it off, a move keys location", list(app.keys("Cube")) == ["location"], app.keys("Cube"))
anim.after_transform('ROTATE')
check("a rotation keys rotation", sorted(app.keys("Cube")) == ["location", "rotation_euler"], app.keys("Cube"))
app.add("Second")
app.objects["Cube"]["selected"] = True
anim.frame_set(9)
anim.after_transform('ROTATE')
check("two objects rotated together key location and rotation on both, as about their median",
      all(9 in app.keys(n).get(p, {}) for n in ("Cube", "Second") for p in ("location", "rotation_euler")),
      (app.keys("Cube"), app.keys("Second")))
anim.set_auto_keying(only_available=True)
app.notices = []
anim.after_transform('RESIZE')
check("with it back on, the keyed channels are keyed and the missing curves reported",
      9 in app.keys("Cube")["location"] and "scale" not in app.keys("Cube")
      and app.notices == [anim.AUTOKEY_REPORT % 3], (app.keys("Cube"), app.notices))
anim.set_auto_keying(replace=True, only_available=False)
anim.frame_set(20)
before = app.keys("Cube")
anim.after_transform('TRANSLATE')
check("Replace keys nothing on a frame with no key", app.keys("Cube") == before)
anim.frame_set(9)
app.objects["Cube"]["location"] = [7.0, 0.0, 0.0]
anim.after_transform('TRANSLATE')
check("and replaces the key on a frame that has one", app.keys("Cube")["location"][9] == [7.0, 0.0, 0.0])
anim.set_auto_keying(on=False, replace=False)
before = app.keys("Cube")
anim.frame_set(30)
anim.after_transform('TRANSLATE')
check("with the record button off, nothing is keyed", app.keys("Cube") == before)
_, _, error = quietly(anim.report)
check("the mirror's report does nothing here: the shim's keys are Swift's already", error is None, error)

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
