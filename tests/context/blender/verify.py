"""temp_override off the main thread, run by a headless Blender.

scripts/run-context-blender-check.sh starts Blender with `-b --factory-startup`.
In background mode desktop Blender has one window and a screen on the main
thread, as the iPad does, and gives none of them out on any other thread, so
the bug reproduces here exactly: a `temp_override` naming the window on a worker
thread leaves the main thread with no window and no screen, and
`ed.undo_push` fails its poll from then on.

The module is the one the app ships, Resources/python/site/_blenderkit_context.py.
The unwrapped call runs last, because what it breaks cannot be put back.
"""
import bpy, importlib.util, pathlib, sys, threading, warnings

ROOT = pathlib.Path(__file__).resolve().parents[3]
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


spec = importlib.util.spec_from_file_location(
    "_blenderkit_context", ROOT / "Resources/python/site/_blenderkit_context.py")
ctx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctx)


def main_context_intact():
    c = bpy.context
    return c.window is not None and c.screen is not None and bpy.ops.ed.undo_push.poll()


def on_thread(body):
    """Runs body on a worker thread; returns (value, error, warning messages)."""
    out = {}

    def worker():
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            try:
                out["value"] = body()
            except Exception as error:
                out["error"] = error
        out["warnings"] = [str(w.message) for w in caught]

    thread = threading.Thread(target=worker)
    thread.start()
    thread.join()
    return out.get("value"), out.get("error"), out.get("warnings", [])


window = bpy.context.window_manager.windows[0]
screen = window.screen
area = next(a for a in screen.areas if a.type == 'VIEW_3D')
region = next(r for r in area.regions if r.type == 'WINDOW')
cube = bpy.data.objects["Cube"]
original = bpy.types.Context.temp_override

check("the main thread starts with a window, a screen and undo_push", main_context_intact())

check("install wraps temp_override", ctx.install(bpy) is True
      and bpy.types.Context.temp_override is not original)
wrapped = bpy.types.Context.temp_override
check("installing twice wraps it once", ctx.install(bpy) is True
      and bpy.types.Context.temp_override is wrapped)

# The main thread: the override is Blender's, untouched.
with bpy.context.temp_override(window=window, area=area, region=region):
    inside = (bpy.context.area == area, bpy.context.region == region)
check("on the main thread the window, area and region still apply", inside == (True, True), inside)
check("and the main thread's context is intact after", main_context_intact())

# The script thread: each shape a script might use.
for label, members in [
    ("window", lambda: {"window": window}),
    ("window and screen", lambda: {"window": window, "screen": screen}),
    ("window and area", lambda: {"window": window, "area": area}),
    ("window, area and region", lambda: {"window": window, "area": area, "region": region}),
    ("area only", lambda: {"area": area}),
    ("context.copy() with an area", lambda: dict(bpy.context.copy(), area=area)),
]:
    def body(members=members):
        with bpy.context.temp_override(**members()):
            return bpy.context.window
    value, error, caught = on_thread(body)
    check(f"thread, {label}: no error", error is None, error)
    check(f"thread, {label}: warned that the UI members were ignored",
          len(caught) == 1 and "temp_override ignored" in caught[0], caught)
    check(f"thread, {label}: the main thread keeps its window and screen", main_context_intact())


def data_member():
    with bpy.context.temp_override(window=window, active_object=cube, selected_objects=[cube]):
        return bpy.context.active_object, list(bpy.context.selected_objects)

value, error, caught = on_thread(data_member)
check("thread: data members still apply beside a dropped window",
      error is None and value == (cube, [cube]), (value, error))


def no_ui_members():
    with bpy.context.temp_override(active_object=cube):
        return bpy.context.active_object

value, error, caught = on_thread(no_ui_members)
check("thread: an override with no UI members passes through without a warning",
      error is None and value == cube and not caught, (value, error, caught))

check("the undo operators still poll on the main thread after all of it",
      main_context_intact() and bpy.ops.ed.undo_push(message="context check") == {'FINISHED'})


# What a context member may hold (`_blenderkit_context.refuse_members`). Every
# value refused here crashed the next operator in desktop 5.2.1, or is one
# Blender's own context never holds there (the module's comment above
# `_MEMBER_TYPES`); the crashes themselves are tests/unsafe/blender's
# CONTEXT_CASES, each in a Blender of its own. Here the override is only made,
# never entered with an operator inside, so without the guard these checks
# FAIL in words instead of taking this Blender down.
print("\nWhat a context member may hold")
import gc
ctx.install(bpy)


def made(**members):
    """What `temp_override(**members)` did: 'made' or the error's words."""
    try:
        bpy.context.temp_override(**members)
        return "made"
    except Exception as error:
        return "refused: " + str(error)


def runs(members, call):
    """`call()` inside `temp_override(**members)`: its result, or the error."""
    try:
        with bpy.context.temp_override(**members):
            return call()
    except Exception as error:
        return "raised " + type(error).__name__ + ": " + str(error)


mesh = cube.data
other_scene = bpy.data.scenes.new("Other Scene")
gone = bpy.data.objects.new("Gone", None)
bpy.data.objects.remove(gone)
evaluated = cube.evaluated_get(bpy.context.evaluated_depsgraph_get())
view_layer = bpy.context.view_layer
REFUSED = {
    "scene=None": dict(scene=None),
    "scene=<an Object>": dict(scene=cube),
    "scene='Cube'": dict(scene="Cube"),
    "scene=[scene]": dict(scene=[bpy.context.scene]),
    "scene=5": dict(scene=5),
    "view_layer=None": dict(view_layer=None),
    "view_layer=<another scene's>": dict(view_layer=other_scene.view_layers[0]),
    "scene=<another scene>, view_layer=<the window's>": dict(scene=other_scene, view_layer=view_layer),
    "blend_data=None": dict(blend_data=None),
    "layer_collection=None": dict(layer_collection=None),
    "tool_settings=None": dict(tool_settings=None),
    "workspace=None (the main thread has one)": dict(workspace=None),
    "active_object=<a Mesh>": dict(active_object=mesh),
    "active_object=<a removed Object>": dict(active_object=gone),
    "active_object=<an evaluated copy>": dict(active_object=evaluated),
    "active_object=<a RenderSettings>": dict(active_object=bpy.context.scene.render),
    "edit_object=<the cube, in Object Mode>": dict(edit_object=cube),
    "selected_objects=<one Object>": dict(selected_objects=cube),
    "selected_objects=[<a Mesh>]": dict(selected_objects=[mesh]),
    "selected_editable_objects=[cube, <a removed Object>]": dict(selected_editable_objects=[cube, gone]),
    "selected_objects='Cube'": dict(selected_objects="Cube"),
    "selected_objects=[None]": dict(selected_objects=[None]),
}
said = {label: made(**members) for label, members in REFUSED.items()}
wrong = {k: v[:100] for k, v in said.items() if not v.startswith("refused: temp_override was not entered: ")}
check("each value Blender's own type would not hold is refused in words as the override is made (%d values)"
      % len(said), not wrong, wrong)
check("  the words name the member and what it was given",
      "scene was given None" in said["scene=None"]
      and "scene holds a Scene, and was given an Object" in said["scene=<an Object>"]
      and "item 0 of it is a Mesh" in said["selected_objects=[<a Mesh>]"]
      and "item 1 of it is an Object that has been removed" in said["selected_editable_objects=[cube, <a removed Object>]"]
      and "is not one of the scene's view layers" in said["view_layer=<another scene's>"]
      and "where Blender's context holds the one in Edit Mode" in said["edit_object=<the cube, in Object Mode>"],
      {k: said[k][40:160] for k in ("scene=None", "selected_objects=[<a Mesh>]", "edit_object=<the cube, in Object Mode>")})
in_force = lambda: len(getattr(ctx, "_in_force", ()))
check("  and nothing was left in force", in_force() == 0, in_force())

# What still works: the app's own overrides and a script's usual ones.
bpy.context.view_layer.objects.active = cube
cube.select_set(True)
found = {}
with ctx.temp_override_view3d("Check"):
    found["temp_override_view3d"] = bpy.context.area.type
found["window, area and region"] = runs(dict(window=window, area=area, region=region),
                                        lambda: bpy.context.region == region)
found["area=None, region=None (the search's)"] = runs(dict(area=None, region=None), lambda: bpy.context.area)
found["selected_objects=[cube], Shade Smooth"] = runs(
    dict(selected_objects=[cube], selected_editable_objects=[cube]), lambda: bpy.ops.object.shade_smooth())
found["selected_editable_objects=scene.objects, Shade Flat"] = runs(
    dict(selected_editable_objects=bpy.context.scene.objects), lambda: bpy.ops.object.shade_flat())
found["**context.copy(), Select All"] = runs(bpy.context.copy(), lambda: bpy.ops.object.select_all(action='SELECT'))
found["active_object=None, object=None"] = runs(dict(active_object=None, object=None),
                                               lambda: bpy.context.active_object)
found["scene, view_layer, the master collection, a layer collection"] = runs(
    dict(scene=bpy.context.scene, view_layer=view_layer, collection=bpy.context.scene.collection,
         layer_collection=view_layer.layer_collection.children[0]), lambda: bpy.ops.object.empty_add())
found["another scene with its own view layer"] = runs(
    dict(scene=other_scene, view_layer=other_scene.view_layers[0]), lambda: bpy.context.scene.name)
found["selected_objects=None (what Blender gives where there are none)"] = runs(
    dict(selected_objects=None), lambda: bpy.context.selected_objects)
bpy.context.view_layer.objects.active = cube   # Add Empty made the empty active
bpy.ops.object.mode_set(mode='EDIT')
found["edit_object=cube in Edit Mode, mesh Select All"] = runs(
    dict(edit_object=cube), lambda: bpy.ops.mesh.select_all(action='SELECT'))
bpy.ops.object.mode_set(mode='OBJECT')


def nested():
    with bpy.context.temp_override(window=window, area=area, region=region):
        with bpy.context.temp_override(active_object=cube, selected_objects=[cube]) as held:
            return (bpy.context.area == area, bpy.context.active_object == cube,
                    type(held).__name__, callable(getattr(held, "logging_set", None)))


found["nested, `as` and logging_set"] = runs({}, nested)
expected = {
    "temp_override_view3d": 'VIEW_3D', "window, area and region": True,
    "area=None, region=None (the search's)": None,
    "selected_objects=[cube], Shade Smooth": {'FINISHED'},
    "selected_editable_objects=scene.objects, Shade Flat": {'FINISHED'},
    "**context.copy(), Select All": {'FINISHED'}, "active_object=None, object=None": None,
    "scene, view_layer, the master collection, a layer collection": {'FINISHED'},
    "another scene with its own view layer": "Other Scene",
    "selected_objects=None (what Blender gives where there are none)": None,
    "edit_object=cube in Edit Mode, mesh Select All": {'FINISHED'},
    "nested, `as` and logging_set": (True, True, '_Override', True),
}
wrong = {k: found[k] for k in expected if found[k] != expected[k]}
check("valid overrides still work: the borrowed 3D View, window/area/region, lists, copy(), None, nesting "
      "(%d)" % len(expected), not wrong, wrong)
check("  and none is left in force after", in_force() == 0, in_force())
bpy.data.scenes.remove(other_scene)

# The wrapper's own slot: refused from a script, Blender's inside the module.
stitch = bpy.ops.uv.stitch
slot = {}
for label, read in (("bpy.ops.uv.stitch._operator", lambda: stitch._operator),
                    ("bpy.ops.object.empty_add._operator", lambda: bpy.ops.object.empty_add._operator),
                    ("bpy.ops.uv.stitch.poll.__self__", lambda: stitch.poll.__self__),
                    ("bpy.ops.uv.stitch.get_rna_type.__self__", lambda: stitch.get_rna_type.__self__),
                    ("an override's _inner", lambda: bpy.context.temp_override(active_object=cube)._inner)):
    try:
        slot[label] = "handed out " + type(read()).__name__
    except AttributeError as error:
        slot[label] = "refused: " + str(error)
wrong = {k: v[:90] for k, v in slot.items()
         if not (v.startswith("refused: ") and ("holds Blender's own object" in v or "__self__" in v))}
check("the wrapper's own slot, its methods' __self__ and an override's _inner are refused from a script",
      not wrong, wrong)
check("  and the operator still polls, names and describes itself as Blender's",
      stitch.poll() is False and stitch.idname() == 'UV_OT_stitch'
      and stitch.get_rna_type().identifier == 'UV_OT_stitch' and 'REGISTER' in stitch.bl_options
      and repr(stitch).startswith('bpy.ops.uv.stitch(') and not hasattr(stitch, '_operator'),
      (stitch.poll(), stitch.idname(), repr(stitch)[:40]))
# What Python's introspection reaches is not closed, and cannot be from
# Python: said here as measured, for the doc's list of what is left.
reached = [type(r).__name__ for r in gc.get_referents(bpy.ops.object.empty_add)]
print("Still open (Python's introspection): gc.get_referents(bpy.ops.object.empty_add) holds %s" % reached)


# What a block frees from under its own override, past the operators
# (`_blenderkit_context`'s section after `_Override`). The crashes are
# tests/unsafe/blender's CONTEXT_CASES; these are the parts that do not crash
# without the guard, so each fails in words with it removed.
print("\nWhat a block frees from under its own override")
monitoring = sys.monitoring
tool = getattr(ctx, "_tool", None)
events = lambda: monitoring.get_events(tool) if tool is not None else None
# Read by `getattr`, so the check fails in words, and runs on, with the guard
# removed (its negative control).
watched = lambda: len(getattr(ctx, "_watched", ()))
broken = lambda: len(getattr(ctx, "_broken", ()))
check("the guard took a sys.monitoring tool of its own, and its CALL event is off with nothing in force",
      tool is not None and monitoring.get_tool(tool) == "Blender Local temp_override" and events() == 0,
      (tool, tool is not None and monitoring.get_tool(tool), events()))
seen = {}
with bpy.context.temp_override(selected_objects=[cube], active_object=cube, scene=bpy.context.scene):
    seen["IDs only"] = (watched(), events())
with ctx.temp_override_view3d("Check"):
    seen["the borrowed 3D View"] = (watched(), events())
with bpy.context.temp_override(view_layer=bpy.context.view_layer):
    seen["a view layer"] = (watched(), events())
seen["after"] = (watched(), events())
check("only an override holding a struct Blender frees with its owner is watched, and only while it is in force",
      seen == {"IDs only": (0, 0), "the borrowed 3D View": (0, 0), "a view layer": (1, monitoring.events.CALL),
               "after": (0, 0)}, seen)


def removed_last():
    # Cleaning up at the end of the block: nothing is called after the
    # removal inside it, so nothing is refused, and the block leaves.
    layer = bpy.context.scene.view_layers.new("Layer 2")
    with bpy.context.temp_override(view_layer=layer):
        bpy.ops.object.select_all(action='DESELECT')
        bpy.context.scene.view_layers.remove(layer)
    return bpy.context.view_layer.name


said = runs({}, removed_last)
check("a view layer removed as the last thing in its own block is not refused, and the block leaves",
      said == "ViewLayer" and not ctx._in_force and not broken() and events() == 0,
      (said, len(ctx._in_force), broken(), events()))


def caught_and_continued():
    # Nothing is called in the block after the removal but what is refused:
    # the errors are kept by subscript, which is not a call.
    layer = bpy.context.scene.view_layers.new("Layer 3")
    errors = [None, None]
    with bpy.context.temp_override(view_layer=layer):
        bpy.context.scene.view_layers.remove(layer)
        try:
            bpy.context.view_layer
        except RuntimeError as error:
            errors[0] = error
        try:
            len("the block goes on")
        except RuntimeError as error:
            errors[1] = error
    return [str(errors[0]), "then: " + str(errors[1]), bpy.context.view_layer.name]


said = runs({}, caught_and_continued)
check("a read after the removal is refused in words, then every call in the block, and after it all runs",
      isinstance(said, list) and len(said) == 3
      and said[0].startswith("bpy.context.view_layer was not run: in the temp_override around it, view_layer "
                             "holds a ViewLayer, and was given a ViewLayer that has been removed")
      and said[1].startswith("then: len was not run: in the temp_override around it") and said[2] == "ViewLayer"
      and not ctx._in_force and not broken() and events() == 0, said)

# An override a run entered with no `with`: the mirror after the run leaves it
# (`leave_overrides`, which `_blenderkit_sync.sync` calls first). Measured in
# desktop 5.2.1 before this: one of IDs only left in force, its scene then
# removed, kept refusing the app's own undo push, which fell back to .blend
# checkpoints and then could not write one.
other_scene = bpy.data.scenes.new("Left Scene")
left = bpy.context.temp_override(scene=other_scene)
left.__enter__()
in_force = len(ctx._in_force)
bpy.data.scenes.remove(other_scene)
said = getattr(ctx, "leave_overrides", lambda: "")()
check("an override left entered by a run is left by the mirror after it, and said in the console",
      in_force == 1 and not ctx._in_force and said.startswith(
          "[Blender Local] 1 temp_override was still in force when the run ended, and it was left")
      and bpy.ops.ed.undo_push(message="after the left override") == {'FINISHED'}, (in_force, said))
if ctx._in_force:
    # Without the guard it is still in force: left here, as the check's own
    # cleanup, so the checks after this one run in the context they expect.
    left.__exit__(None, None, None)
else:
    check("  and its block's own exit after that does nothing", left.__exit__(None, None, None) is False)


# Loading a file. Every one of these takes down Blender's screen through
# ED_screen_exit, which reads the window from the context: NULL on a worker
# thread, where a script's read_homefile() crashed the app. So the unguarded
# call is never made on a thread here — it would take Blender down.
print("\nLoading a file")
import gpu, os, tempfile

def view3d():
    for w in bpy.context.window_manager.windows:
        for a in (w.screen.areas if w.screen else ()):
            if a.type == 'VIEW_3D':
                return w, a, next(r for r in a.regions if r.type == 'WINDOW')
    return None

def view_override_works():
    found = view3d()
    if found is None:
        return False
    w, a, r = found
    with bpy.context.temp_override(window=w, area=a, region=r):
        a.spaces.active.region_3d.update()
        return bpy.context.area == a

gpu.init()   # the app has it started, for Knife Project
create = bpy.ops._op_create_function
check("install guarded the file-reading operators",
      getattr(create, '_blenderkit_guard', False))
check("installing again guards them once",
      ctx.install(bpy) is True and bpy.ops._op_create_function is create)
op = bpy.ops.wm.read_homefile
check("the guarded operator reads as Blender's: its signature, idname, RNA, poll",
      repr(op).startswith('bpy.ops.wm.read_homefile(filepath=""')
      and op.idname() == 'WM_OT_read_homefile' and op.get_rna_type().identifier == 'WM_OT_read_homefile'
      and op.poll() is True and (op.__doc__ or '').startswith('bpy.ops.wm.read_homefile('), repr(op))
# Every other operator, saving included, is handed out with the undo
# argument's guard only (`_UndoInArea`: asked as it is called, since one
# looked up outside an area override and called inside it with
# 'EXEC_DEFAULT', 1 segfaulted desktop 5.2.1), and reads as Blender's own.
# (Add Empty, not Add Cube, since every Add ▸ Mesh primitive is priced.)
cube_add, save = bpy.ops.object.empty_add, bpy.ops.wm.save_as_mainfile
check("other operators, saving included, carry the undo guard alone and read as Blender's own",
      type(cube_add).__name__ == '_UndoInArea' and type(save).__name__ == '_UndoInArea'
      # Read as the module reads it: from a script the slot is refused
      # (the context members' section above).
      and type(eval("op._operator", vars(ctx), {"op": cube_add})).__name__ == 'BPyOpFunction'
      and cube_add.idname() == 'OBJECT_OT_empty_add'
      and save.get_rna_type().identifier == 'WM_OT_save_as_mainfile'
      and repr(cube_add).startswith('bpy.ops.object.empty_add(')
      and (cube_add.__doc__ or '').startswith('bpy.ops.object.empty_add('),
      (type(cube_add).__name__, repr(cube_add)[:60]))
check("the Swift routes the same operators", tuple(ctx.FILE_READS) == (
      'read_homefile', 'read_factory_settings', 'open_mainfile',
      'revert_mainfile', 'recover_last_session', 'recover_auto_save'))

work = tempfile.mkdtemp()
plain = os.path.join(work, "plain.blend")
bpy.ops.wm.save_as_mainfile(filepath=plain, copy=True)
# A file saved with no 3D View on its screen.
turned = [a for a in bpy.context.window.screen.areas if a.type == 'VIEW_3D']
for a in turned:
    a.type = 'TEXT_EDITOR'
no_view = os.path.join(work, "no_view.blend")
bpy.ops.wm.save_as_mainfile(filepath=no_view, copy=True)
for a in turned:
    a.type = 'VIEW_3D'

marker = bpy.data.objects.new("Marker", None)
bpy.context.scene.collection.objects.link(marker)
arguments = {'open_mainfile': {'filepath': plain}}
if getattr(create, '_blenderkit_guard', False):
    for name in ctx.FILE_READS:
        value, error, _ = on_thread(
            lambda name=name: getattr(bpy.ops.wm, name)(**arguments.get(name, {})))
        check(f"thread: {name} refused in words, not run",
              isinstance(error, RuntimeError) and 'was not run' in str(error)
              and 'Run Scripts Off the Main Thread' in str(error), (value, error))
        check(f"thread: after {name}, the scene and the main thread's context are as they were",
              "Marker" in bpy.data.objects and main_context_intact())
    value, error, _ = on_thread(lambda: bpy.ops.wm.open_mainfile(filepath=plain, load_ui=False))
    check("thread: load_ui=False is refused too — the screen goes down either way",
          isinstance(error, RuntimeError), (value, error))

# The main thread: Blender's own, as File > New and File > Open run them.
screen_name = bpy.context.window.screen.name
check("main thread: read_homefile() loads the startup scene",
      bpy.ops.wm.read_homefile() == {'FINISHED'} and "Marker" not in bpy.data.objects
      and sorted(o.name for o in bpy.data.objects) == ['Camera', 'Cube', 'Light'],
      sorted(o.name for o in bpy.data.objects))
check("  and the window, screen, undo push and a 3D View override still work",
      main_context_intact() and bpy.context.window.screen.name == screen_name
      and bpy.ops.ed.undo_push(message="after New") == {'FINISHED'} and view_override_works())
check("main thread: read_factory_settings() loads, and the context holds",
      bpy.ops.wm.read_factory_settings() == {'FINISHED'} and main_context_intact()
      and view_override_works())
check("main thread: open_mainfile loads a saved file, and the context holds",
      bpy.ops.wm.open_mainfile(filepath=plain) == {'FINISHED'} and main_context_intact()
      and view_override_works())
check("main thread: revert_mainfile reloads it, and the context holds",
      bpy.ops.wm.revert_mainfile() == {'FINISHED'} and main_context_intact()
      and view_override_works())

# load_ui: the app keeps its own screen unless a call asks for the file's.
check("open_mainfile with no load_ui keeps the app's screen and its 3D View",
      bpy.ops.wm.open_mainfile(filepath=no_view) == {'FINISHED'} and view3d() is not None
      and view_override_works())
check("load_ui=True is still Blender's: the file's own screen, which here has no 3D View",
      bpy.ops.wm.open_mainfile(filepath=no_view, load_ui=True) == {'FINISHED'}
      and view3d() is None and main_context_intact())
check("read_homefile(load_ui=True) brings the startup screen's 3D View back",
      bpy.ops.wm.read_homefile(load_ui=True) == {'FINISHED'} and view_override_works())
check("read_homefile() twice more, and the undo push still works",
      bpy.ops.wm.read_homefile() == {'FINISHED'} and bpy.ops.wm.read_homefile() == {'FINISHED'}
      and bpy.ops.ed.undo_push(message="after loads") == {'FINISHED'})
# A load that brings in a file's screen frees the old window's.
window = bpy.context.window_manager.windows[0]

# The control, last: Blender's own temp_override does the damage this prevents.
bpy.types.Context.temp_override = original
on_thread(lambda: bpy.context.temp_override(window=window).__enter__().__exit__(None, None, None))
if main_context_intact():
    print("  NOTE  unwrapped, this Blender no longer loses the main thread's context; "
          "the wrapper may no longer be needed")
else:
    check("control: unwrapped, one thread override loses the main thread's window", True)

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
