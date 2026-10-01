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
      getattr(create, '_blenderkit_original', None) is not None)
check("installing again guards them once",
      ctx.install(bpy) is True and bpy.ops._op_create_function is create)
op = bpy.ops.wm.read_homefile
check("the guarded operator reads as Blender's: its signature, idname, RNA, poll",
      repr(op).startswith('bpy.ops.wm.read_homefile(filepath=""')
      and op.idname() == 'WM_OT_read_homefile' and op.get_rna_type().identifier == 'WM_OT_read_homefile'
      and op.poll() is True and (op.__doc__ or '').startswith('bpy.ops.wm.read_homefile('), repr(op))
check("other operators are Blender's own objects, saving included",
      type(bpy.ops.mesh.primitive_cube_add).__name__ == 'BPyOpFunction'
      and type(bpy.ops.wm.save_as_mainfile).__name__ == 'BPyOpFunction')
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
if getattr(create, '_blenderkit_original', None) is not None:
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
