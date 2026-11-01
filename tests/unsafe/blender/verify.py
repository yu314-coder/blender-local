"""Operators that must not run as they are called, run by a headless Blender
with the app's context: its modules from Resources/python/site,
`_blenderkit_context.install(bpy)` (the app's console prelude), gpu.init(),
its undo push, and a script thread that is not Blender's main thread.

`_blenderkit_context.UNSAFE_OPERATORS` is the one table: every route an
operator is called by reads it, and each entry refuses every call in words or
gives the call what it needs first. Round 4's final review found the
operator search refusing `uv.stitch` and `uv.select_edge_ring` by a list of
its own while the same call as a script line segfaulted or hung Blender, and
`brush.asset_activate` crashing Blender from the search and a script line on
a file opened in Vertex Paint, where only the Brush menu gave it the tool it
needs. Here, for every entry, every route:

  * a script line on the main thread (a script that mentions temp_override or
    picks a brush, or with Run Scripts Off the Main Thread off);
  * Run and the console, which run off the main thread by default;
  * under the borrowed 3D View, and an operator looked up outside it and
    called inside it;
  * `_bpy.ops.create_function` called by hand, and a reload of `bpy.ops`;
  * a script's own macro (`bpy.types.Macro.define`), whose steps Blender runs
    past every wrapper: each entry, and a priced primitive, refused as a step;
  * the operator search's form and Run (`_blenderkit_sync`).

Round 4's second fix-round review found what still went round them, and
each is a case here with a control that crashes without the guard: the
module spelled in upper or mixed case (`bpy.ops.UV.stitch`, which Blender
reads as UV_OT_stitch), named every way Blender takes it as a call and as a
macro's step (and a str whose methods lie); a step of Loop Cut with its edge
set, of a load, of Sculpt Mode's way in; a BLOCKING macro with its undo in
an area; a brush pick under an overridden `active_object`, outside a brush
mode and under an Image Editor; and an operator, or a second load, inside a
load's handlers (`refuse_mid_load`). Those run in a Blender of their own
each (`SCENARIOS`), guarded and not, so a guard that misses fails the check
in words instead of taking it down.

Then a context member given what Blender's own type for it would not hold
(`CONTEXT_CASES`: scene=None, another scene's view layer, an edit_object in
Object Mode, a removed Object in selected_editable_objects, ...) and an
override a block takes its members away from (Delete inside it, then Shade
Smooth): each in a Blender of its own, four at a time, refused in words with
the guard and crashing in its measured frame without it. And the wrapper's
own slot (`bpy.ops.uv.stitch._operator`), refused in words, with a control
showing what it holds still crashes Blender when called.

Then the negative controls, each a Blender of its own without the guard (the
check can fail): the same calls, and a macro of Stitch, segfault or hang it. And the Mask Fill crash
round 4 found in desktop Blender (`paint.mask_flood_fill` with no undo stack):
a file opened before any guard, with no undo push at all, then Sculpt Mode and
Mask Fill by the Sculpt header, the search, a script line and the script
thread — none reaches the crash.

    scripts/run-unsafe-blender-check.sh
"""
import bpy, bmesh, gc, gpu, sys, os, types, tempfile, subprocess, importlib, importlib.util, pathlib, threading

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = pathlib.Path(os.environ.get("BK_SITE", ROOT / "Resources/python/site"))
sys.dont_write_bytecode = True
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
CHILD = ARGS[0] if ARGS else None
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


class _App(types.ModuleType):
    # The app's C module: Blender's main thread is this process's main
    # thread, and the script thread is any other (`BpySession.scriptQueue`).
    def is_main_thread(self):
        return threading.current_thread() is threading.main_thread()

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules['_blenderkit'] = _App('_blenderkit')


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
for name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(name)
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
load("_blenderkit_knife")
load("_blenderkit_multires")
sculpt = load("_blenderkit_sculpt")
vwpaint = load("_blenderkit_vwpaint")
HIST = tempfile.mkdtemp(prefix="bk-unsafe-")
gpu.init()


def attempt(body):
    try:
        return "ran " + repr(body())
    except Exception as error:
        return "refused: " + str(error).strip().replace("\n", " ")


def on_script_thread(body):
    """`body` on a thread of its own, as Run and the console run a script by
    default (Run Scripts Off the Main Thread)."""
    out = {}

    def worker():
        out["said"] = attempt(body)
    thread = threading.Thread(target=worker)
    thread.start()
    thread.join()
    return out["said"]


def line(path, *args):
    """The script line `bpy.ops.<path>(<args>)`, as a script has it."""
    return lambda: exec("bpy.ops.%s(%s)" % (path, ", ".join(args)), {"bpy": bpy})


def op(path):
    module, name = path.split(".")
    return getattr(getattr(bpy.ops, module), name)


def unwrapped_cube():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.mesh.primitive_cube_add(size=2)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.unwrap()


VIEW_TOOL_KEYS = {'VERTEX_PAINT': 'PAINT_VERTEX', 'WEIGHT_PAINT': 'PAINT_WEIGHT', 'SCULPT': 'SCULPT'}
BRUSHES = {'VERTEX_PAINT': 'brushes/essentials_brushes-mesh_vertex.blend/Brush/Paint Hard',
           'WEIGHT_PAINT': 'brushes/essentials_brushes-mesh_weight.blend/Brush/Blur',
           'SCULPT': 'brushes/essentials_brushes-mesh_sculpt.blend/Brush/Clay Strips'}


def view_tool(mode):
    window, area, region = sculpt._knife.view3d()
    with bpy.context.temp_override(window=window, area=area, region=region):
        tool = bpy.context.workspace.tools.from_space_view3d_mode(VIEW_TOOL_KEYS[mode], create=False)
        return tool.idname if tool is not None else None


def held_brush(mode):
    paint = (bpy.context.scene.tool_settings.sculpt if mode == 'SCULPT'
             else vwpaint._paint(mode))
    return paint.brush.name if paint.brush is not None else None


def saved_in(mode, folder):
    """A sphere saved in `mode` by this Blender."""
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16)
    bpy.context.object.name = "Saved"
    bpy.ops.object.mode_set(mode=mode)
    path = os.path.join(folder, mode.lower() + ".blend")
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    bpy.ops.object.mode_set(mode='OBJECT')
    return path


def opened_without_tool(path):
    """`path` opened as the app opens its autosave (the wrapped open_mainfile,
    `load_ui=False`) in a session whose workspace has no tools: the startup
    file's own interface read first, which holds none (measured in 5.2.1:
    `read_homefile(load_ui=True)` empties every workspace's tools, as a fresh
    launch has them)."""
    bpy.ops.wm.read_homefile(use_empty=True, load_ui=True)
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    return bpy.data.objects["Saved"].mode


def child(args, timeout=120, env=None):
    """A Blender of its own (this file, `-- <args>`), in this check's home,
    with `env` added to its environment. `.crash` is the backtrace Blender
    wrote if it went down (its `<file>.crash.txt` in TMPDIR), or ''."""
    folder = tempfile.gettempdir()
    for old in pathlib.Path(folder).glob("*.crash.txt"):
        old.unlink()
    run = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup", "--python", __file__, "--", *args],
                         capture_output=True, text=True, timeout=timeout,
                         cwd=os.environ.get("HOME", folder), env=dict(os.environ, **(env or {})))
    run.crash = "".join(p.read_text(errors="replace") for p in pathlib.Path(folder).glob("*.crash.txt"))
    return run


def crashed_in(run, frame):
    """Whether the child went down with `frame` in Blender's backtrace."""
    return run.returncode != 0 and frame in run.crash


# --------------------------------------------------------------------------
# The negative controls and the Mask Fill cases: a Blender of their own each.
if CHILD == "raw-uv":
    # Unguarded: an unwrapped cube in Edit Mode, then the script line.
    path, where = ARGS[1], ARGS[2]
    undo.push(HIST, "Original")
    unwrapped_cube()
    print("CHILD about to run %s (%s)" % (path, where), flush=True)
    if where == "view":
        with context.temp_override_view3d("negative"):
            line(path)()
    else:
        line(path)()
    print("CHILD survived", flush=True)
    sys.exit(0)

if CHILD == "raw-macro":
    # Unguarded: a script's macro with `path` as its one step, on an unwrapped
    # cube in Edit Mode.
    path = ARGS[1]
    undo.push(HIST, "Original")
    unwrapped_cube()
    module, name = path.split(".")

    class BK_OT_unsafe_raw_macro(bpy.types.Macro):
        bl_idname = "wm.bk_unsafe_raw_macro"
        bl_label = "Unsafe Raw Macro"
    bpy.utils.register_class(BK_OT_unsafe_raw_macro)
    BK_OT_unsafe_raw_macro.define(module.upper() + "_OT_" + name)
    print("CHILD about to run a macro of %s" % path, flush=True)
    bpy.ops.wm.bk_unsafe_raw_macro()
    print("CHILD survived", flush=True)
    sys.exit(0)

if CHILD == "raw-brush":
    # Unguarded: the app's opening of a file saved in the mode, then the line
    # Blender's Info editor logs for a brush pick; `thread` makes the tool
    # first and picks on the script thread.
    path, mode, where = ARGS[1], ARGS[2], ARGS[3]
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    # The app's undo push after the load, so what takes Blender down is the
    # pick, not Sculpt Mode's undo code reading no stack.
    undo.push(HIST, "Original")
    print("CHILD opened in %s, 3D View tool %s" % (bpy.data.objects["Saved"].mode, view_tool(mode)), flush=True)
    pick = line("brush.asset_activate", "asset_library_type='ESSENTIALS'",
                "relative_asset_identifier=%r" % BRUSHES[mode])
    print("CHILD about to run brush.asset_activate (%s)" % where, flush=True)
    if where == "thread":
        window, area, region = sculpt._knife.view3d()
        with bpy.context.temp_override(window=window, area=area, region=region):
            bpy.ops.wm.tool_set_by_id(name='builtin.brush', space_type='VIEW_3D')
        print("CHILD tool made: %s" % view_tool(mode), flush=True)
        thread = threading.Thread(target=pick)
        thread.start()
        thread.join()
    else:
        pick()
    print("CHILD survived", flush=True)
    sys.exit(0)

if CHILD == "libwrite":
    # `bpy.data.libraries.write` of a scene whose view layers Blender has not
    # brought in sync (round 4's fix round 2 review: a new scene, exit 139 in
    # BKE_view_layer_copy_data). `raw` leaves the guards out.
    variant, where = ARGS[1], ARGS[2]
    undo.push(HIST, "Original")
    if where != "raw":
        context.install(bpy)
    path = os.path.join(HIST, "written.blend")
    if variant == "new scene":
        written = {bpy.data.scenes.new("S2")}
    elif variant == "a new scene given a second view layer":
        s2 = bpy.data.scenes.new("S2")
        s2.view_layers.new("VL2")
        written = {s2}
    else:   # a compositor group whose Render Layers node names a new scene
        group = bpy.data.node_groups.new("C", 'CompositorNodeTree')
        group.nodes.new('CompositorNodeRLayers').scene = bpy.data.scenes.new("S2")
        written = {group}
    print("CHILD about to run bpy.data.libraries.write (%s)" % variant, flush=True)
    said = attempt(lambda: bpy.data.libraries.write(path, written))
    print("CHILD said: %s" % said, flush=True)
    print("CHILD survived: %s, %d bytes written" % (said[:40], os.path.getsize(path) if os.path.exists(path) else 0),
          flush=True)
    sys.exit(0)

if CHILD == "mask":
    # A file saved in Sculpt Mode, opened before any guard is installed and
    # with no undo push at all: Blender has no undo stack. Then the guards, as
    # the app's prelude installs them, and Mask Fill by `where`; `raw` leaves
    # the guards out.
    path, where = ARGS[1], ARGS[2]
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    if where != "raw":
        context.install(bpy)
    steps = undo.blender_steps()
    print("CHILD opened in %s, %d undo steps" % (bpy.data.objects["Saved"].mode, len(steps or [])), flush=True)
    print("CHILD about to run Mask Fill (%s)" % where, flush=True)
    fill = line("paint.mask_flood_fill", "mode='VALUE'", "value=1.0")
    if where == "header":
        said = attempt(lambda: sculpt.mask('FILL'))
    elif where == "search":
        said = attempt(lambda: sync.run_operator('paint.mask_flood_fill', {'mode': 'VALUE', 'value': 1.0}))
    elif where == "thread":
        said = on_script_thread(fill)
    else:
        said = attempt(fill)
    print("CHILD survived: %s; %d undo steps" % (said[:160], len(undo.blender_steps() or [])), flush=True)
    sys.exit(0)


# --------------------------------------------------------------------------
# The routes round 4's second fix-round review found past the guards, and the
# ones its fixer found beside them, each a Blender of its own (`SCENARIOS`),
# so a route that is not refused takes down that Blender, not the check:
# `guarded` installs the guards as the app's prelude does, `raw` leaves them
# out (the negative control). Each prints what it was told ("CHILD said:")
# and "CHILD survived" if Blender did.
VP_BRUSH = dict(asset_library_type='ESSENTIALS', relative_asset_identifier=BRUSHES['VERTEX_PAINT'])
TX_BRUSH = dict(asset_library_type='ESSENTIALS',
                relative_asset_identifier='brushes/essentials_brushes-mesh_texture.blend/Brush/Paint Hard')


def on_thread_raising(body):
    """`body` on a script thread, its exception raised again here."""
    out = {}

    def worker():
        try:
            out["value"] = body()
        except Exception as error:
            out["error"] = error
    thread = threading.Thread(target=worker)
    thread.start()
    thread.join()
    if "error" in out:
        raise out["error"]
    return out.get("value")


def scenario_macro(idname, steps, options=None):
    """A script's own Macro `wm.<idname>` with `steps` [(step, {property: value})]."""
    attrs = dict(bl_idname="wm." + idname, bl_label=idname.replace("_", " ").title())
    if options:
        attrs['bl_options'] = options
    macro = type("BK_OT_" + idname, (bpy.types.Macro,), attrs)
    bpy.utils.register_class(macro)
    for step, values in steps:
        properties = macro.define(step).properties
        for key, value in values.items():
            setattr(properties, key, value)
    return getattr(bpy.ops.wm, idname)


def scenario_opened(mode, other=False):
    """A sphere called Saved, saved in `mode` (beside a cube called Other in
    Object Mode), opened as the app opens its autosave (`opened_without_tool`)."""
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    if other:
        bpy.ops.mesh.primitive_cube_add(location=(3, 0, 0))
        bpy.context.object.name = "Other"
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16)
    bpy.context.object.name = "Saved"
    if mode != 'OBJECT':
        bpy.ops.object.mode_set(mode=mode)
    path = os.path.join(tempfile.mkdtemp(prefix="bk-unsafe-case-"), "case.blend")
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    if mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    opened_without_tool(path)
    undo.push(HIST, "Original")


def view_tool_made():
    window, area, region = sculpt._knife.view3d()
    with bpy.context.temp_override(window=window, area=area, region=region):
        bpy.ops.wm.tool_set_by_id(name='builtin.brush', space_type='VIEW_3D')


def in_image_editor(body):
    """`body` under an area of the startup screen turned into an Image Editor."""
    window = bpy.context.window
    area = next(a for a in window.screen.areas if a.type == 'PROPERTIES')
    area.type = 'IMAGE_EDITOR'
    region = next(r for r in area.regions if r.type == 'WINDOW')
    with bpy.context.temp_override(window=window, area=area, region=region):
        return body()


def mesh_vertices():
    return sum(len(o.data.vertices) for o in bpy.data.objects if o.type == 'MESH')


def grid_past_budget():
    before = mesh_vertices()
    said = attempt(lambda: bpy.ops.MESH.primitive_grid_add(x_subdivisions=1700, y_subdivisions=1700))
    return "%s | %d vertices made" % (said, mesh_vertices() - before)


def macro_load_then_fill():
    path = saved_in('SCULPT', tempfile.mkdtemp(prefix="bk-unsafe-load-"))
    bpy.ops.object.mode_set(mode='SCULPT')
    return scenario_macro("bk_unsafe_load_fill", [
        ("WM_OT_open_mainfile", {'filepath': path, 'load_ui': False}),
        ("PAINT_OT_mask_flood_fill", {'mode': 'VALUE', 'value': 1.0})])()


def blocking_macro_with_undo():
    op = bpy.ops.wm.bk_unsafe_blocking
    with context.temp_override_view3d("Check"):
        return op('EXEC_DEFAULT', True)


def pick_under_other():
    other = bpy.data.objects["Other"]
    with bpy.context.temp_override(active_object=other, object=other):
        return bpy.ops.brush.asset_activate(**VP_BRUSH)


def load_post_in_sculpt(action, first=True):
    """A file saved in Sculpt Mode, and a persistent load_post handler, first
    (or last) in load_post, that runs `action(<another file>)`; then the file
    opened, and Mask Fill after it. Returns what the handler, the load and Mask
    Fill were told."""
    folder = tempfile.mkdtemp(prefix="bk-unsafe-load-")
    path = saved_in('SCULPT', folder)
    other = os.path.join(folder, "other.blend")
    bpy.ops.wm.save_as_mainfile(filepath=other, copy=True)
    told = []

    @bpy.app.handlers.persistent
    def bk_unsafe_load_post(*_):
        # Once: marked before the call, since a load inside it runs the
        # handler again (unguarded, that recursed until the stack ran out).
        if told:
            return
        told.append("running")
        told[0] = attempt(lambda: action(other))
    if first:
        bpy.app.handlers.load_post.insert(0, bk_unsafe_load_post)
    else:
        bpy.app.handlers.load_post.append(bk_unsafe_load_post)
    opened = attempt(lambda: bpy.ops.wm.open_mainfile(filepath=path))
    bpy.app.handlers.load_post.remove(bk_unsafe_load_post)
    saved = bpy.data.objects.get("Saved")
    after = (attempt(lambda: bpy.ops.paint.mask_flood_fill(mode='VALUE', value=1.0))
             if saved is not None and saved.mode == 'SCULPT' else "not in Sculpt Mode")
    return "the handler %s | open %s | after it, Mask Fill %s" % (
        told[0] if told else "never ran", opened, after)


def no_setup():
    pass


# name: (setup, the call; its return value is what it was told).
SCENARIOS = {
    # Every guard keyed on the module as typed, where Blender upper-cases it
    # (`bpy.ops.UV.stitch` is UV_OT_stitch).
    "bpy.ops.UV.stitch()": (unwrapped_cube, lambda: bpy.ops.UV.stitch()),
    "_bpy.ops.create_function('Uv', 'stitch')()": (unwrapped_cube, lambda: _bpy.ops.create_function("Uv", "stitch")()),
    "bpy.ops.WM.call_menu(name='VIEW3D_MT_object')": (no_setup, lambda: bpy.ops.WM.call_menu(name='VIEW3D_MT_object')),
    "bpy.ops.BRUSH.asset_activate(...) in a file opened in Vertex Paint": (
        lambda: scenario_opened('VERTEX_PAINT'), lambda: bpy.ops.BRUSH.asset_activate(**VP_BRUSH)),
    "bpy.ops.UV.select_edge_ring()": (unwrapped_cube, lambda: bpy.ops.UV.select_edge_ring()),
    "bpy.ops.MESH.primitive_grid_add(x_subdivisions=1700, y_subdivisions=1700)": (no_setup, grid_past_budget),
    "bpy.ops.WM.read_homefile() off the main thread": (
        no_setup, lambda: on_thread_raising(lambda: bpy.ops.WM.read_homefile())),
    # A script's own macro, whose steps Blender runs past every wrapper.
    "a macro of Loop Cut with its edge set (edge_index 4)": (
        lambda: bpy.ops.object.mode_set(mode='EDIT'),
        lambda: scenario_macro("bk_unsafe_cut", [("MESH_OT_loopcut", {'edge_index': 4, 'object_index': 0})])()),
    "a macro that opens a file saved in Sculpt Mode, then Mask Fill, from Sculpt Mode": (no_setup, macro_load_then_fill),
    "a macro of read_homefile off the main thread": (
        no_setup, lambda: (lambda op: on_thread_raising(lambda: op()))(
            scenario_macro("bk_unsafe_read", [("WM_OT_read_homefile", {})]))),
    "a BLOCKING macro of Set Object Mode (Edit), with its undo under the borrowed 3D View": (
        None, blocking_macro_with_undo),
    # The brush pick, which gives the brush to the tool Blender finds from
    # the view layer's active object and the context's area.
    "a brush pick in Vertex Paint under temp_override(active_object=<an object in Object Mode>)": (
        lambda: scenario_opened('VERTEX_PAINT', other=True), pick_under_other),
    "a Texture Paint brush picked in Object Mode": (
        lambda: scenario_opened('OBJECT'), lambda: bpy.ops.brush.asset_activate(**TX_BRUSH)),
    "a Texture Paint brush picked in Edit Mode": (
        lambda: bpy.ops.object.mode_set(mode='EDIT'), lambda: bpy.ops.brush.asset_activate(**TX_BRUSH)),
    "a Texture Paint brush picked in Vertex Paint under an Image Editor, the 3D View's tool made": (
        lambda: (scenario_opened('VERTEX_PAINT'), view_tool_made()),
        lambda: in_image_editor(lambda: bpy.ops.brush.asset_activate(**TX_BRUSH))),
    # Inside a file load, before Blender has set up the file's modes.
    "Mask Fill in a load_post handler, opening a file saved in Sculpt Mode": (
        no_setup, lambda: load_post_in_sculpt(lambda other: bpy.ops.paint.mask_flood_fill(mode='VALUE', value=1.0))),
    # The outer load goes on with the database the inner one freed
    # (`wm_file_read_post` holds `bmain` across load_post): a use after free,
    # which crashes Blender now and then (round 4's second fix round: 2 runs
    # in 12 with an undo push after the inner load, as `_FileRead` made one)
    # and every time with freed memory filled (`SCRIBBLE`).
    "a load in a load_post handler": (
        no_setup, lambda: load_post_in_sculpt(lambda other: bpy.ops.wm.open_mainfile(filepath=other))),
}

if CHILD == "case":
    import _bpy
    name, guarded = ARGS[1], ARGS[2] == "guarded"
    setup, call = SCENARIOS[name]
    undo.push(HIST, "Original")
    if setup is None:
        # The BLOCKING macro: its step is defined before the guards, since
        # its define is refused now (SCULPT_ENTRIES), so this holds the
        # call's own guard (`refuse_undo_in_area`, 'MACRO') alone.
        scenario_macro("bk_unsafe_blocking", [("OBJECT_OT_mode_set", {'mode': 'EDIT'})], {'BLOCKING'})
        setup = no_setup
    if guarded:
        context.install(bpy)
    setup()
    print("CHILD about to run %s (%s)" % (name, ARGS[2]), flush=True)
    said = attempt(call)
    print("CHILD said: " + said.replace("\n", " "), flush=True)
    print("CHILD survived", flush=True)
    sys.exit(0)


# --------------------------------------------------------------------------
# A context member given what Blender's own type for it would not hold, and
# an override whose members a block takes away from under it
# (`_blenderkit_context.refuse_members`, `refuse_stale_members`). Measured in
# desktop 5.2.1 with the app's context, each crashed Blender with or without
# the guards before them (the module's comment above `_MEMBER_TYPES`). Each a
# Blender of its own, `guarded` or `raw`, so a guard that misses fails the
# check in words.
def context_fixture():
    scene = bpy.context.scene
    f = types.SimpleNamespace(scene=scene, view_layer=bpy.context.view_layer, cube=bpy.data.objects["Cube"])
    f.mesh = f.cube.data
    f.other = bpy.data.objects.new("Other", bpy.data.meshes.new("Other"))
    scene.collection.objects.link(f.other)
    f.scene2 = bpy.data.scenes.new("Scene 2")
    f.gone = bpy.data.objects.new("Gone", bpy.data.meshes.new("Gone"))
    scene.collection.objects.link(f.gone)
    bpy.data.objects.remove(f.gone)
    return f


def within(members, *calls):
    """The calls inside `with bpy.context.temp_override(**members):`, the last one's result."""
    with bpy.context.temp_override(**members):
        for call in calls[:-1]:
            call()
        return calls[-1]()


SELECT_ALL = lambda: bpy.ops.object.select_all(action='SELECT')
MOVE = lambda: bpy.ops.transform.translate(value=(0.1, 0, 0))
SMOOTH = lambda: bpy.ops.object.shade_smooth()


def made_removed_entered(f):
    override = bpy.context.temp_override(selected_objects=[f.other], selected_editable_objects=[f.other])
    bpy.data.objects.remove(f.other)
    with override:
        return SMOOTH()


def view_layer_removed_inside(f):
    # Written out: a call between the removal and Select All (a lambda) would
    # be the one refused (`_blenderkit_context._refuse_freed`).
    layer = f.scene.view_layers.new("Layer 2")
    with bpy.context.temp_override(view_layer=layer):
        f.scene.view_layers.remove(layer)
        return bpy.ops.object.select_all(action='SELECT')


def edit_object_left(f):
    bpy.context.view_layer.objects.active = f.cube
    bpy.ops.object.mode_set(mode='EDIT')
    return within(dict(edit_object=f.cube), lambda: bpy.ops.object.mode_set(mode='OBJECT'),
                  lambda: bpy.ops.mesh.primitive_cube_add())


def removed_inside(then):
    """A second view layer given to `temp_override`, removed inside its block
    (`ViewLayers.remove` sets the one it is given to null), then a call that
    is not an operator, so `refuse_stale_members` never sees it
    (`_blenderkit_context`'s section after `_Override`). Written out, with
    nothing called between the two, as a script would write it."""
    def body(f):
        layer = f.scene.view_layers.new("Layer 2")
        with bpy.context.temp_override(view_layer=layer):
            f.scene.view_layers.remove(layer)
            if then == "select_set":
                return f.cube.select_set(True)
            return bpy.context.evaluated_depsgraph_get()
    return body


def scene_removed_inside(f):
    # Another scene and its view layer; the scene removed inside the block
    # frees the view layer, which Python does not mark.
    with bpy.context.temp_override(scene=f.scene2, view_layer=f.scene2.view_layers[0]):
        bpy.data.scenes.remove(f.scene2)
        return bpy.context.evaluated_depsgraph_get()


def collection_removed_inside(f):
    collection = bpy.data.collections.new("Coll")
    f.scene.collection.children.link(collection)
    layer = bpy.context.view_layer.layer_collection.children["Coll"]
    with bpy.context.temp_override(layer_collection=layer):
        bpy.data.collections.remove(collection)
        return bpy.context.layer_collection.name


def left_in_force(f):
    """A script that enters an override with no `with` and removes its scene,
    then the app's mirror after the run (`_blenderkit_sync.sync`), what it
    said captured."""
    def script():
        override = bpy.context.temp_override(scene=f.scene2, view_layer=f.scene2.view_layers[0])
        override.__enter__()
        bpy.data.scenes.remove(f.scene2)
    script()
    import io, contextlib
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        sync.sync()
    return printed.getvalue().strip()


def scene_switch_in(members_of, kind):
    """scene.new(type=kind) inside an override that sets view_layer (fix round
    3: Blender gives the window the new scene, which clears the override's
    `scene` and keeps its `view_layer`, and its update after the call
    evaluates the two together)."""
    def body(f):
        return within(members_of(f), lambda: bpy.ops.scene.new(type=kind))
    return body


def scene_deleted_in(f):
    return within(dict(scene=f.scene2, view_layer=f.scene2.view_layers[0]), lambda: bpy.ops.scene.delete())


def window_scene_set_inside(f):
    # Written out: the window given another scene by a script line, then the
    # next operator.
    with bpy.context.temp_override(scene=f.scene, view_layer=f.view_layer):
        bpy.context.window.scene = f.scene2
        return bpy.ops.object.select_all(action='SELECT')


def window_scene_set_then(then):
    """The same, then a call that is not an operator, which
    `refuse_stale_members` never sees (fix round 3's verification: each
    exited 139 in BKE_object_eval_eval_base_flags with the round's guards).
    Written out, with nothing called between the two."""
    def body(f):
        with bpy.context.temp_override(scene=f.scene, view_layer=f.view_layer):
            bpy.context.window.scene = f.scene2
            if then == "view_layer.update":
                return bpy.context.view_layer.update()
            return bpy.context.evaluated_depsgraph_get()
    return body


def under_view(members, call):
    def body(f):
        with context.temp_override_view3d("Check"):
            return within(members(f), call)
    return body


NOT_ENTERED = "refused: temp_override was not entered: "
# name: (the call, given the fixture; what the guarded Blender is told; the
# frame the unguarded one goes down in, from its backtrace, or a tuple of
# them, any of which will do).
CONTEXT_CASES = {
    "temp_override(scene=None): Select All": (
        lambda f: within(dict(scene=None), SELECT_ALL), NOT_ENTERED + "scene was given None", "CTX_data_view_layer"),
    "temp_override(scene=<an Object>): Select All": (
        lambda f: within(dict(scene=f.cube), SELECT_ALL),
        NOT_ENTERED + "scene holds a Scene, and was given an Object",
        # An Object read as a Scene: where Blender trips on it varies. In 6
        # unguarded runs of 7 it was BKE_view_layer_find (from
        # CTX_data_view_layer); the 7th went down elsewhere (its backtrace
        # was not kept), so any crash inside the operator's call will do.
        ("BKE_view_layer_find", "bpy_op_fn_call")),
    "temp_override(scene='Cube'): Select All": (
        lambda f: within(dict(scene="Cube"), SELECT_ALL),
        NOT_ENTERED + "scene holds a Scene, and was given the str 'Cube'", "CTX_data_view_layer"),
    "temp_override(view_layer=None): Select All": (
        lambda f: within(dict(view_layer=None), SELECT_ALL), NOT_ENTERED + "view_layer was given None",
        "base_deselect_all_ex"),
    "temp_override(view_layer=<another scene's>): Select All": (
        lambda f: within(dict(view_layer=f.scene2.view_layers[0]), SELECT_ALL),
        NOT_ENTERED + "view_layer holds a ViewLayer, and was given a ViewLayer that is not one of the scene's",
        "deg_update_eval_copy_datablock"),
    "temp_override(scene=<another scene>, view_layer=<the window's>): Select All": (
        lambda f: within(dict(scene=f.scene2, view_layer=f.view_layer), SELECT_ALL),
        NOT_ENTERED + "view_layer holds a ViewLayer, and was given a ViewLayer that is not one of the scene's",
        "BKE_object_eval_eval_base_flags"),
    "temp_override(blend_data=None): Select All": (
        lambda f: within(dict(blend_data=None), SELECT_ALL), NOT_ENTERED + "blend_data was given None",
        "bpy_op_view_layer_update"),
    "temp_override(tool_settings=None): Move": (
        lambda f: within(dict(tool_settings=None), MOVE), NOT_ENTERED + "tool_settings was given None",
        "initTransInfo"),
    "temp_override(layer_collection=None): context.layer_collection": (
        lambda f: within(dict(layer_collection=None), lambda: bpy.context.layer_collection),
        NOT_ENTERED + "layer_collection was given None", "CTX_data_layer_collection"),
    "temp_override(active_object=<a Mesh>): Move": (
        lambda f: within(dict(active_object=f.mesh), MOVE),
        NOT_ENTERED + "active_object holds an Object, and was given a Mesh", "transform_orientations_create_from_axis"),
    "temp_override(edit_object=<the cube, in Object Mode>): Add Cube": (
        lambda f: within(dict(edit_object=f.cube), lambda: bpy.ops.mesh.primitive_cube_add()),
        NOT_ENTERED + "edit_object holds an Object, and was given an object in Object Mode",
        "make_prim_from_bmo_args"),
    "temp_override(selected_editable_objects=[<a removed Object>]): Shade Smooth": (
        lambda f: within(dict(selected_editable_objects=[f.gone]), SMOOTH),
        NOT_ENTERED + "selected_editable_objects holds a list of Objects, and item 0 of it is an Object that has "
        "been removed", "shade_smooth_exec"),
    "temp_override(selected_editable_objects=[<a Mesh>]): Apply Location": (
        lambda f: within(dict(selected_editable_objects=[f.mesh]),
                         lambda: bpy.ops.object.transform_apply(location=True)),
        NOT_ENTERED + "selected_editable_objects holds a list of Objects, and item 0 of it is a Mesh",
        "append_sorted_object_parent_hierarchy"),
    "inside temp_override(selected_objects=[cube, other], ...): Delete, then Shade Smooth": (
        lambda f: within(dict(selected_objects=[f.cube, f.other], selected_editable_objects=[f.cube, f.other]),
                         lambda: bpy.ops.object.delete(), SMOOTH),
        "refused: bpy.ops.object.shade_smooth was not run: in the temp_override around it, selected_objects holds "
        "a list of Objects, and item 0 of it is an Object that has been removed", "shade_smooth_exec"),
    "temp_override(selected_objects=[other], ...) made, other removed, then entered: Shade Smooth": (
        made_removed_entered,
        NOT_ENTERED + "selected_objects holds a list of Objects, and item 0 of it is an Object that has been removed",
        "shade_smooth_exec"),
    "a view layer removed inside its own temp_override, then Select All": (
        view_layer_removed_inside,
        "refused: bpy.ops.object.select_all was not run: in the temp_override around it, view_layer holds a "
        "ViewLayer, and was given a ViewLayer that has been removed", "base_deselect_all_ex"),
    "edit_object's cube taken to Object Mode inside its temp_override, then Add Cube": (
        edit_object_left,
        "refused: bpy.ops.mesh.primitive_cube_add was not run: in the temp_override around it, edit_object holds "
        "an Object, and was given an object in Object Mode", "make_prim_from_bmo_args"),
    "under the borrowed 3D View, temp_override(scene=None): Select All": (
        under_view(lambda f: dict(scene=None), SELECT_ALL), NOT_ENTERED + "scene was given None",
        "CTX_data_view_layer"),
    # Fix round 2's in-app pass: what a block frees, then a call that is not
    # an operator, which Blender's C reads the context for.
    "a view layer removed inside its own temp_override, then Object.select_set": (
        removed_inside("select_set"),
        "refused: Object.select_set was not run: in the temp_override around it, view_layer holds a ViewLayer, "
        "and was given a ViewLayer that has been removed", "rna_Object_select_set"),
    "a view layer removed inside its own temp_override, then context.evaluated_depsgraph_get()": (
        removed_inside("evaluated_depsgraph_get"),
        "refused: bpy.context.evaluated_depsgraph_get was not run: in the temp_override around it, view_layer "
        "holds a ViewLayer, and was given a ViewLayer that has been removed", "CTX_data_ensure_evaluated_depsgraph"),
    "another scene removed inside its own temp_override, then context.evaluated_depsgraph_get()": (
        scene_removed_inside,
        "refused: bpy.context.evaluated_depsgraph_get was not run: in the temp_override around it, view_layer "
        "holds a ViewLayer, and was given a ViewLayer whose Scene has been removed",
        "CTX_data_ensure_evaluated_depsgraph"),
    "a collection removed inside its layer collection's temp_override, then context.layer_collection.name": (
        collection_removed_inside,
        "refused: bpy.context.layer_collection was not run: in the temp_override around it, layer_collection "
        "holds a LayerCollection, and was given a LayerCollection that is no longer Blender's",
        "LayerCollection_name_length"),
    "an override entered with no `with`, its scene removed, then the mirror after the run": (
        left_in_force,
        "ran '[Blender Local] A temp_override left in force by the run was left: its view_layer holds a ViewLayer, "
        "and was given a ViewLayer whose Scene has been removed",
        # Where the freed view layer is read first varies (measured: the
        # depsgraph build, or the collections' walk).
        ("CTX_data_ensure_evaluated_depsgraph", "rna_")),
    # Fix round 3: the operators that give the window another scene, inside
    # an override that sets view_layer (`_blenderkit_context.SCENE_SWITCHES`).
    "temp_override(scene=<another scene>, view_layer=<its own>): New Scene, Full Copy": (
        scene_switch_in(lambda f: dict(scene=f.scene2, view_layer=f.scene2.view_layers[0]), 'FULL_COPY'),
        "refused: bpy.ops.scene.new was not run: it gives the window another scene", "deg_update_eval_copy_datablock"),
    "temp_override(scene=<the window's>, view_layer=<its own>): New Scene": (
        scene_switch_in(lambda f: dict(scene=f.scene, view_layer=f.view_layer), 'NEW'),
        "refused: bpy.ops.scene.new was not run: it gives the window another scene",
        "BKE_object_eval_eval_base_flags"),
    "temp_override(scene=<another scene>, view_layer=<its own>): Delete Scene": (
        scene_deleted_in, "refused: bpy.ops.scene.delete was not run: it gives the window another scene",
        # The freed view layer read as the depsgraph is built from it: in
        # BKE_view_layer_synced_ensure, build_material or build_idproperties
        # (3 runs), each under build_view_layer.
        "build_view_layer"),
    "inside temp_override(scene=<the window's>, view_layer=<its own>), the window given another scene, then "
    "Select All": (
        window_scene_set_inside,
        "refused: bpy.ops.object.select_all was not run: in the temp_override around it, view_layer holds a "
        "ViewLayer, and was given a ViewLayer that is not one of the scene's", "BKE_object_eval_eval_base_flags"),
    "inside temp_override(scene=<the window's>, view_layer=<its own>), the window given another scene, then "
    "context.evaluated_depsgraph_get()": (
        window_scene_set_then("evaluated_depsgraph_get"),
        "refused: bpy.context.evaluated_depsgraph_get was not run: in the temp_override around it, view_layer "
        "holds a ViewLayer, and was given a ViewLayer that is not one of the scene's view layers: the window was "
        "given another scene", "BKE_object_eval_eval_base_flags"),
    "inside temp_override(scene=<the window's>, view_layer=<its own>), the window given another scene, then "
    "context.view_layer.update()": (
        window_scene_set_then("view_layer.update"),
        "refused: bpy.context.view_layer was not run: in the temp_override around it, view_layer holds a "
        "ViewLayer, and was given a ViewLayer that is not one of the scene's view layers: the window was given "
        "another scene", "BKE_object_eval_eval_base_flags"),
}
# The unguarded runs of these read freed memory, which does not fail every
# time (the scene's case passed one raw run of three): MallocScribble=1 makes
# every such read fail, as the slot's control does.
SCRIBBLED = {"another scene removed inside its own temp_override, then context.evaluated_depsgraph_get()",
             "temp_override(scene=<another scene>, view_layer=<its own>): New Scene, Full Copy",
             "temp_override(scene=<the window's>, view_layer=<its own>): New Scene",
             "temp_override(scene=<another scene>, view_layer=<its own>): Delete Scene",
             "inside temp_override(scene=<the window's>, view_layer=<its own>), the window given another scene, "
             "then Select All",
             "inside temp_override(scene=<the window's>, view_layer=<its own>), the window given another scene, "
             "then context.evaluated_depsgraph_get()",
             "inside temp_override(scene=<the window's>, view_layer=<its own>), the window given another scene, "
             "then context.view_layer.update()",
             "an override entered with no `with`, its scene removed, then the mirror after the run"}

if CHILD == "slot":
    # The wrapper's own slot, which round 4's fix round 2 left open: Blender's
    # Stitch, held by the guard that refuses it. `script` reads it as a script
    # would; `module` reads it the way the guards do, inside their module, to
    # show what the slot holds still crashes Blender when called.
    undo.push(HIST, "Original")
    context.install(bpy)
    unwrapped_cube()
    print("CHILD about to run the slot (%s)" % ARGS[1], flush=True)
    if ARGS[1] == "script":
        said = attempt(lambda: bpy.ops.uv.stitch._operator._operator())
    else:
        said = attempt(lambda: eval("op._operator._operator()", vars(context), {"op": bpy.ops.uv.stitch}))
    print("CHILD said: " + said.replace("\n", " "), flush=True)
    print("CHILD survived", flush=True)
    sys.exit(0)

if CHILD == "context":
    name, guarded = ARGS[1], ARGS[2] == "guarded"
    call = CONTEXT_CASES[name][0]
    undo.push(HIST, "Original")
    if guarded:
        context.install(bpy)
    fixture = context_fixture()
    print("CHILD about to run %s (%s)" % (name, ARGS[2]), flush=True)
    said = attempt(lambda: call(fixture))
    print("CHILD said: " + said.replace("\n", " "), flush=True)
    # And Blender goes on: nothing is left in force, and the next operator
    # runs (Undo Push, which finishes whatever the case left in the scene).
    after = attempt(lambda: bpy.ops.ed.undo_push(message="After"))
    print("CHILD after: %s, %d in force" % (after, len(getattr(context, "_in_force", ()))), flush=True)
    print("CHILD survived", flush=True)
    sys.exit(0)


# --------------------------------------------------------------------------
context.install(bpy)
undo.push(HIST, "Original")

print("\nOne table")
import _bpy
table = context.UNSAFE_OPERATORS
check("the search keeps no list of its own: _blenderkit_sync has no _UNSAFE_OPERATORS",
      not hasattr(sync, "_UNSAFE_OPERATORS"))
check("Stitch, Edge Ring Select and Activate Brush Asset are in it, beside the interface's own operators",
      {'uv.stitch', 'uv.select_edge_ring', 'brush.asset_activate'} <= set(table)
      and set(context.INTERFACE_ONLY) <= set(table), sorted(table))
check("every entry says what was measured, and what the banner says",
      all(entry.measured and entry.refusal for entry in table.values()))
check("every entry names an operator this Blender has",
      all(hasattr(op(path), "get_rna_type") for path in table), [p for p in table if not hasattr(op(p), "get_rna_type")])
check("the search refuses exactly the entries that refuse every call, in the table's words",
      all(sync._refusal(path) == (entry.refusal if entry.prepare is None else None) for path, entry in table.items()),
      [(p, sync._refusal(p)) for p in table])
wrapped = op("uv.stitch")
check("a wrapped operator keeps its own poll, RNA, idname and signature",
      wrapped.get_rna_type().identifier == "UV_OT_stitch" and wrapped.idname() == "UV_OT_stitch"
      and repr(wrapped).startswith("bpy.ops.uv.stitch(") and (wrapped.__doc__ or "").startswith("bpy.ops.uv.stitch("),
      (repr(wrapped), wrapped.__doc__))

# Blender upper-cases the module part of a name in ASCII and takes the name
# part as written (`pyop_create_function`, `WM_operator_bl_idname`), so
# `bpy.ops.UV.stitch` is UV_OT_stitch. Round 4's second fix-round review
# found every guard keyed on the module as typed: the mixed-case spelling got
# the generic wrapper alone and crashed, hung or ran past the budget.
GUARDED = {'uv.stitch': '_Unsafe', 'wm.call_menu': '_Unsafe', 'brush.asset_activate': '_Unsafe',
           'wm.read_homefile': '_FileRead', 'wm.open_mainfile': '_FileRead', 'mesh.loopcut': '_NeedsView',
           'object.mode_set': '_SculptEntry', 'sculpt.sculptmode_toggle': '_SculptEntry',
           'transform.rotate': '_Rotate', 'mesh.primitive_grid_add': '_PricedAdd',
           'transform.translate': '_PricedOperator', 'object.join': '_PricedOperator',
           # Priced too, since round 4's second fix round: in a mesh's Edit Mode
           # Blender adds the cube into the edited mesh, under its stack.
           'mesh.primitive_cube_add': '_PricedAdd', 'object.empty_add': '_UndoInArea',
           # Fix round 3: refused inside an override that sets view_layer.
           'scene.new': '_SceneSwitch', 'scene.delete': '_SceneSwitch'}
spelled = {}
for path, kind in GUARDED.items():
    module, name = path.split(".")
    for typed in (module, module.upper(), module.title(), module[:1] + module[1:].upper()):
        found = getattr(getattr(bpy.ops, typed), name)
        spelled[typed + "." + name] = (type(found).__name__, kind, found.idname())
wrong = {k: v for k, v in spelled.items() if v[0] != v[1]}
check("every guard is asked of the operator however its module is spelled (%d spellings: uv, UV, Uv, uV, ...)"
      % len(spelled), not wrong, wrong)
check("and each spelling is the one operator Blender runs (UV.stitch and uv.stitch are both UV_OT_stitch)",
      len({(k.split(".")[0].lower(), v[2]) for k, v in spelled.items()}) == len(GUARDED), sorted(spelled.items())[:6])
check("the table and the search read a name as Blender does: UV.stitch, Uv.stitch and UV_OT_stitch are uv.stitch",
      all(context.refusal(n) == table['uv.stitch'].refusal == sync._refusal(n)
          for n in ("UV.stitch", "Uv.stitch", "UV_OT_stitch")),
      [(n, context.refusal(n), sync._refusal(n)) for n in ("UV.stitch", "Uv.stitch", "UV_OT_stitch")])
check("operator_path reads every spelling Blender takes, and a name part as it is",
      [context.operator_path(n) for n in ("uv.stitch", "UV.stitch", "Uv.stitch", "UV_OT_stitch",
                                          "GREASE_PENCIL_OT_brush_stroke", "uv.STITCH")]
      == ["uv.stitch"] * 4 + ["grease_pencil.brush_stroke", "uv.STITCH"],
      [context.operator_path(n) for n in ("UV.stitch", "GREASE_PENCIL_OT_brush_stroke", "uv.STITCH")])
check("no guard hands a script the function it wraps (round 4's second fix-round review: "
      "`._blenderkit_original` did)",
      not any(hasattr(f, "_blenderkit_original") for f in (bpy.ops._op_create_function, _bpy.ops.create_function,
                                                           _bpy.ops.macro_define, bpy.types.Context.temp_override))
      and all(getattr(f, "_blenderkit_guard", False) for f in (bpy.ops._op_create_function, _bpy.ops.macro_define,
                                                               bpy.types.Context.temp_override)))
# Nor in a wrapper's closure (fix round 3: fix round 2's final check ran
# `bpy.ops._op_create_function.__closure__[0].cell_contents('uv', 'stitch')()`
# past every guard, exit 139 in stitch_exit): each cell holds a sealed holder,
# which a script can neither call nor open.
cells = {}
for label, f, call in (("bpy.ops._op_create_function", bpy.ops._op_create_function, lambda c: c("uv", "stitch")),
                       ("_bpy.ops.create_function", _bpy.ops.create_function, lambda c: c("uv", "stitch")),
                       ("_bpy.ops.macro_define", _bpy.ops.macro_define, lambda c: c(None, "UV_OT_stitch")),
                       ("bpy.types.Context.temp_override", bpy.types.Context.temp_override,
                        lambda c: c(bpy.context))):
    for i, cell in enumerate(getattr(f, "__closure__", None) or ()):
        held = cell.cell_contents
        key = "%s.__closure__[%d]" % (label, i)
        if type(held).__name__ in ("builtin_function_or_method", "method_descriptor"):
            cells[key] = "holds Blender's " + type(held).__name__
            continue
        if not callable(held):
            continue
        try:
            call(held)
            cells[key] = "called: ran"
        except TypeError as error:
            cells[key] = "called: refused" if "Blender's own" in str(error) else "called: " + str(error)[:60]
        try:
            held._inner
            cells[key] += ", ._inner handed out"
        except AttributeError:
            pass
check("no wrapper's closure holds the function it wraps, and what it holds, called or opened from a script, "
      "is refused (%d cells)" % len(cells),
      len(cells) >= 4 and all(v == "called: refused" for v in cells.values()), cells)
# Nor a guard a script makes around the holder (fix round 3's review: a
# `_SceneSwitch` calls what it holds from the app's module, which the holder
# lets through, and `type(bpy.ops.scene.new)(holder, 'scene.new')('object',
# 'select_all')` handed back Blender's raw BPyOpFunction). Only the function
# object is asked for, never called; every guard class is tried.
holder = next((c.cell_contents for c in (_bpy.ops.create_function.__closure__ or ())
               if type(c.cell_contents).__name__ == "_Sealed"), None)
made = {}
for path in GUARDED:
    module, name = path.split(".")
    kind = type(getattr(getattr(bpy.ops, module), name))
    if kind.__name__ in made or holder is None:
        continue
    try:
        wrapper = kind(holder, "scene.new")
    except TypeError as error:
        made[kind.__name__] = "refused" if "made by the app" in str(error) else "raised: " + str(error)[:60]
        continue
    made[kind.__name__] = "made"
    if kind.__name__ == "_SceneSwitch":
        try:
            made[kind.__name__] += ", handed out " + type(wrapper("object", "select_all")).__name__
        except Exception as error:      # noqa: BLE001 - what it said is the finding
            made[kind.__name__] += ", called: " + str(error)[:60]
check("no guard can be made by a script around a wrapper's holder, so none calls it from the app's module "
      "(%d guard classes)" % len(made),
      holder is not None and len(made) >= 8 and all(v == "refused" for v in made.values()), made)
# Nor the operator a wrapper holds (round 4's fix round 2 left
# `bpy.ops.uv.stitch._operator` open, and `.poll.__self__` handed out the same
# object): refused in words from a script, however the wrapper is reached.
slot = {}
for label, read in (("bpy.ops.uv.stitch._operator", lambda: bpy.ops.uv.stitch._operator),
                    ("bpy.ops.UV.stitch._operator", lambda: bpy.ops.UV.stitch._operator),
                    ("_bpy.ops.create_function('uv', 'stitch')._operator",
                     lambda: _bpy.ops.create_function("uv", "stitch")._operator),
                    ("bpy.ops.wm.call_menu._operator", lambda: bpy.ops.wm.call_menu._operator),
                    ("bpy.ops.mesh.primitive_grid_add._operator", lambda: bpy.ops.mesh.primitive_grid_add._operator),
                    ("bpy.ops.uv.stitch.poll.__self__", lambda: bpy.ops.uv.stitch.poll.__self__),
                    ("bpy.ops.uv.stitch.idname.__self__", lambda: bpy.ops.uv.stitch.idname.__self__),
                    ("bpy.ops.uv.stitch.get_rna_type.__self__", lambda: bpy.ops.uv.stitch.get_rna_type.__self__)):
    try:
        slot[label] = "handed out " + type(read()).__name__
    except AttributeError as error:
        slot[label] = "refused: " + str(error)
check("no wrapper hands a script the operator it holds: `._operator` is refused in words, and its methods "
      "have no `__self__` (%d routes)" % len(slot),
      all(v.startswith("refused: ") for v in slot.values())
      and all("holds Blender's own object" in v for k, v in slot.items() if k.endswith("._operator")),
      {k: v[:80] for k, v in slot.items()})
reached = [type(r).__name__ for r in gc.get_referents(bpy.ops.uv.stitch)]
inner = next((r for r in gc.get_referents(bpy.ops.uv.stitch) if type(r).__name__ == "_UndoInArea"), None)
print("Still open (Python's introspection): gc.get_referents(bpy.ops.uv.stitch) holds %s, and that one's %s"
      % (reached, [type(r).__name__ for r in gc.get_referents(inner)] if inner is not None else "-"))
# And code run in the module's own globals, whose frames are the module's:
# the function object is asked for, never called.
own = vars(context)
own["_unsafe_check_holder"] = holder
try:
    exec("_unsafe_check_found = _unsafe_check_holder('object', 'select_all')", own)
    found_type = type(own.get("_unsafe_check_found")).__name__
except Exception as error:              # noqa: BLE001 - what it said is the finding
    found_type = "refused: " + str(error)[:60]
finally:
    own.pop("_unsafe_check_holder", None)
    own.pop("_unsafe_check_found", None)
print("Still open (Python's introspection): code exec'd in the guards' module's own globals calls the holder: %s"
      % found_type)

print("\nEvery entry that refuses every call, by every route")
refused = [path for path, entry in table.items() if entry.prepare is None]
routes = {}
for path in refused:
    unwrapped_cube()
    sentence = 'bpy.ops.' + path + ' was not run: ' + table[path].refusal
    looked_up = op(path)

    def in_view(call):
        def body():
            with context.temp_override_view3d("Check"):
                return call()
        return body
    module, name = path.split(".")
    routes[path] = {
        "script line": attempt(line(path)),
        "script line, EXEC_DEFAULT": attempt(line(path, "'EXEC_DEFAULT'")),
        "Run (off the main thread)": on_script_thread(line(path)),
        "under the borrowed 3D View": attempt(in_view(line(path))),
        "looked up outside the view, called inside": attempt(in_view(lambda: looked_up())),
        "_bpy.ops.create_function by hand": attempt(lambda: _bpy.ops.create_function(module, name)()),
    }
    if path != 'uv.select_edge_ring':
        # The module upper-cased, as Blender reads it. Edge Ring Select's is
        # a scenario of its own below, with a time limit: unguarded it never
        # returns, and in this Blender it would hang the check. Called only
        # when wrapped, so a guard that misses them fails here in words
        # rather than taking this Blender down.
        for label, typed, found in (
                ("script line, MODULE.name", module.upper(), lambda: getattr(getattr(bpy.ops, module.upper()), name)),
                ("script line, Module.name", module.title(), lambda: getattr(getattr(bpy.ops, module.title()), name)),
                ("create_function('MODULE', ...)", module.upper(), lambda: _bpy.ops.create_function(module.upper(), name))):
            kind = type(found()).__name__
            routes[path][label] = (attempt(lambda: found()()) if kind == '_Unsafe'
                                   else "not wrapped as the table's: " + kind)
    search = attempt(lambda: sync.run_operator(path, {}))
    form = sync.operator_info(path)
    ok = all(said == "refused: " + sentence for said in routes[path].values())
    check("%s: refused in the table's words by a script line (however its module is spelled), Run, the "
          "borrowed view, an early lookup and create_function" % path, ok, {k: v[:120] for k, v in routes[path].items() if v != "refused: " + sentence})
    check("%s: the search refuses it in the same words, and its form cannot run it" % path,
          search == "refused: " + table[path].refusal and form["available"] is False
          and form["refused"] == table[path].refusal, (search[:120], form.get("available"), form.get("refused")))
importlib.reload(sys.modules["bpy.ops"])
after_reload = {path: attempt(line(path)) for path in refused}
check("after importlib.reload(bpy.ops) every one is still refused (`_bpy.ops.create_function` is the guard)",
      all(said == "refused: bpy.ops." + path + " was not run: " + table[path].refusal
          for path, said in after_reload.items()), {p: s[:100] for p, s in after_reload.items()})
if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
    bpy.ops.object.mode_set(mode='OBJECT')

print("\nA macro's steps: refused as they are named, since a macro runs them past every wrapper")


class BK_OT_unsafe_check_macro(bpy.types.Macro):
    bl_idname = "wm.bk_unsafe_check_macro"
    bl_label = "Unsafe Check Macro"


bpy.utils.register_class(BK_OT_unsafe_check_macro)


def define_step(idname):
    return attempt(lambda: BK_OT_unsafe_check_macro.define(idname) and "defined")


class Lying(str):
    # A str whose methods name another operator; Blender reads its own data.
    def partition(self, separator):
        return ("mesh", separator, "primitive_cube_add")

    def lower(self):
        return "mesh"

    def upper(self):
        return "MESH"


def spellings(path):
    """Every way Blender takes the step `path` names (`WM_operator_bl_idname`),
    each with a label of its own (a Lying str equals the plain one as a key)."""
    module, name = path.split(".")
    plain = (module.upper() + "_OT_" + name, path, module.upper() + "." + name, module.title() + "." + name)
    return [(n, n) for n in plain] + [(Lying(n), "lying " + n) for n in plain[:1] + plain[2:3]]


macro_said = {}
for path, entry in table.items():
    for idname, label in spellings(path):
        macro_said[(path, label)] = define_step(idname)
wrong = {(p, i): s[:140] for (p, i), s in macro_said.items()
         if not (s.startswith("refused: Macro.define was not given " + p + ":") and s.endswith(table[p].refusal))}
check("every entry, named every way Blender takes it (UV_OT_stitch, uv.stitch, UV.stitch, Uv.stitch, and a str "
      "whose methods lie), is refused as a macro's step in the table's words (%d names)" % len(macro_said),
      not wrong, wrong)
said = define_step("MESH_OT_primitive_uv_sphere_add")
check("so is a priced primitive, whose step's settings nothing counts (%s)" % said[9:70],
      said.startswith("refused: Macro.define was not given mesh.primitive_uv_sphere_add:")
      and "vertex budget" in said, said)
# What the guards ask of a call that a step's settings, set after the step is
# defined, never meet (round 4's second fix-round review: a step of Loop Cut
# with its edge set, a load, and Sculpt Mode's way in each passed).
STEPS = {"mesh.loopcut": "It cuts at an edge", "mesh.loopcut_slide": "It cuts at an edge",
         "object.mode_set": "into Sculpt Mode", "object.mode_set_with_submode": "into Sculpt Mode",
         "sculpt.sculptmode_toggle": "into Sculpt Mode", "transform.rotate": "vertex budget",
         "transform.translate": "vertex budget", "mesh.primitive_grid_add": "vertex budget"}
STEPS.update({"wm." + n: "It loads a file" for n in context.FILE_READS})
step_said = {(p, label): define_step(i) for p in STEPS for i, label in spellings(p)}
wrong = {(p, i): s[:150] for (p, i), s in step_said.items()
         if not (s.startswith("refused: Macro.define was not given " + p + ":") and STEPS[p] in s)}
check("a step of Loop Cut, of a load (all %d of them) or of Sculpt Mode's way in, and a priced move, is refused "
      "however it is named (%d names)" % (len(context.FILE_READS), len(step_said)), not wrong, wrong)
bpy.utils.unregister_class(BK_OT_unsafe_check_macro)


class BK_OT_unsafe_check_cube(bpy.types.Macro):
    bl_idname = "wm.bk_unsafe_check_cube"
    bl_label = "Unsafe Check Cube"


bpy.utils.register_class(BK_OT_unsafe_check_cube)
# Add Empty, not Add Cube: every Add ▸ Mesh primitive is priced since round
# 4's second fix round (in Edit Mode it adds into the edited mesh), and a
# priced step is refused as one.
said = attempt(lambda: BK_OT_unsafe_check_cube.define("OBJECT_OT_empty_add") and "defined")
before = len(bpy.data.objects)
ran = attempt(lambda: bpy.ops.wm.bk_unsafe_check_cube())
check("and any other step is Blender's: a macro of Add Empty is defined and runs (%s, %s)" % (said, ran),
      said == "ran 'defined'" and ran == "ran {'FINISHED'}" and len(bpy.data.objects) == before + 1,
      (said, ran, len(bpy.data.objects) - before))
bpy.utils.unregister_class(BK_OT_unsafe_check_cube)

print("\nActivate Brush Asset: given the 3D View's tool, on every route")
folder = tempfile.mkdtemp(prefix="bk-unsafe-brush-")
files = {mode: saved_in(mode, folder) for mode in BRUSHES}
for mode, path in files.items():
    brush = BRUSHES[mode]
    name = brush.rsplit("/", 1)[1]
    pick = line("brush.asset_activate", "asset_library_type='ESSENTIALS'", "relative_asset_identifier=%r" % brush)
    keywords = dict(asset_library_type='ESSENTIALS', relative_asset_identifier=brush)

    def view_pick(call):
        def body():
            with context.temp_override_view3d("Check"):
                return call()
        return body
    cases = [
        ("a script line", lambda: attempt(pick)),
        ("the operator search", lambda: attempt(lambda: sync.run_operator("brush.asset_activate", dict(keywords)))),
        ("under the borrowed 3D View", lambda: attempt(view_pick(pick))),
        ("looked up outside the view, called inside",
         lambda: (lambda early: attempt(view_pick(lambda: early(**keywords))))(bpy.ops.brush.asset_activate)),
        ("_bpy.ops.create_function by hand",
         lambda: attempt(lambda: _bpy.ops.create_function("brush", "asset_activate")(**keywords))),
        ("the Brush menu", lambda: attempt(lambda: (sculpt if mode == 'SCULPT' else vwpaint).activate(name))),
    ]
    for label, run in cases:
        opened = opened_without_tool(path)
        before = view_tool(mode)
        said = run()
        check("%s, a file saved in it opened as the app opens it (3D View tool %s): %s picks %s (%s), the tool "
              "made" % (mode, before, label, name, said[:40]),
              opened == mode and before is None and said.startswith("ran") and held_brush(mode) == name
              and view_tool(mode) is not None, (opened, before, said[:200], held_brush(mode), view_tool(mode)))
    opened = opened_without_tool(path)
    held = held_brush(mode)
    said = on_script_thread(pick)
    check("%s: Run, off the main thread, is refused in words, nothing changed" % mode,
          said.startswith("refused: bpy.ops.brush.asset_activate was not run:") and "main thread" in said
          and held_brush(mode) == held and view_tool(mode) is None, (said[:200], held_brush(mode), view_tool(mode)))
    said = on_script_thread(lambda: sync.run_operator("brush.asset_activate", dict(keywords)))
    check("%s: and so is the search's call on that thread" % mode,
          said.startswith("refused") and "main thread" in said, said[:200])
bpy.ops.wm.read_homefile(use_empty=True, load_ui=True)
bpy.ops.mesh.primitive_cube_add()
said = attempt(line("brush.asset_activate", "asset_library_type='ESSENTIALS'",
                    "relative_asset_identifier=%r" % BRUSHES['VERTEX_PAINT']))
# Refused there since round 4's second fix round: a Texture Paint brush
# picked outside a brush mode crashed Blender (the scenarios below), and a
# Vertex Paint brush there changed nothing ("wrong object mode").
check("in Object Mode a script line is refused in words: there is no brush mode to give a tool (%s)" % said[9:90],
      said.startswith("refused: bpy.ops.brush.asset_activate was not run: Activate Brush Asset gives a brush")
      and "Object Mode" in said, said)
said = on_script_thread(line("brush.asset_activate", "asset_library_type='ESSENTIALS'",
                             "relative_asset_identifier=%r" % BRUSHES['VERTEX_PAINT']))
check("off the main thread it is refused there too: Blender's context reads Object Mode there whatever the mode",
      said.startswith("refused") and "main thread" in said, said[:200])

# --------------------------------------------------------------------------
print("\nThe routes round 4's second fix-round review found, each in a Blender of its own, guarded and not")
table_said = lambda path: "refused: bpy.ops." + path + " was not run: " + table[path].refusal
OUTSIDE = "refused: bpy.ops.brush.asset_activate was not run: Activate Brush Asset gives a brush to the tool"
# name: (what the guarded Blender is told, the frame the unguarded one goes down in, or None when it
# survives and `RAW_SAID` says what it did).
EXPECT = {
    "bpy.ops.UV.stitch()": ([table_said("uv.stitch")], "stitch_exit"),
    "_bpy.ops.create_function('Uv', 'stitch')()": ([table_said("uv.stitch")], "stitch_exit"),
    "bpy.ops.WM.call_menu(name='VIEW3D_MT_object')": ([table_said("wm.call_menu")], "popup_menu_create_impl"),
    "bpy.ops.BRUSH.asset_activate(...) in a file opened in Vertex Paint": (
        ["ran {'FINISHED'}"], "WM_toolsystem_activate_brush_and_tool"),
    "bpy.ops.UV.select_edge_ring()": ([table_said("uv.select_edge_ring")], "hang"),
    "bpy.ops.MESH.primitive_grid_add(x_subdivisions=1700, y_subdivisions=1700)": (
        ["refused: Add Grid with X Subdivisions 1,700, Y Subdivisions 1,700 would make 2,893,401 vertices",
         "| 0 vertices made"], None),
    "bpy.ops.WM.read_homefile() off the main thread": (
        ["refused: bpy.ops.wm.read_homefile was not run: loading a file takes down Blender's screen"], "ED_screen_exit"),
    "a macro of Loop Cut with its edge set (edge_index 4)": (
        ["refused: Macro.define was not given mesh.loopcut:"], "loopcut_init"),
    "a macro that opens a file saved in Sculpt Mode, then Mask Fill, from Sculpt Mode": (
        ["refused: Macro.define was not given wm.open_mainfile:"], "push_begin_ex"),
    "a macro of read_homefile off the main thread": (
        ["refused: Macro.define was not given wm.read_homefile:"], "ED_screen_exit"),
    "a BLOCKING macro of Set Object Mode (Edit), with its undo under the borrowed 3D View": (
        ["refused: bpy.ops.wm.bk_unsafe_blocking was not run with its undo on inside an area override"],
        "ED_area_type_hud_ensure"),
    "a brush pick in Vertex Paint under temp_override(active_object=<an object in Object Mode>)": (
        ["ran {'FINISHED'}"], "WM_toolsystem_activate_brush_and_tool"),
    "a Texture Paint brush picked in Object Mode": (
        [OUTSIDE, "the active object is in Object Mode"], "WM_toolsystem_activate_brush_and_tool"),
    "a Texture Paint brush picked in Edit Mode": (
        [OUTSIDE, "the active object is in Edit Mode"], "WM_toolsystem_activate_brush_and_tool"),
    "a Texture Paint brush picked in Vertex Paint under an Image Editor, the 3D View's tool made": (
        ["refused: bpy.ops.brush.asset_activate was not run: Activate Brush Asset gives the brush to the 3D "
         "View's tool, and this context's area is an editor with tools of its own (Image Editor)"],
        "WM_toolsystem_activate_brush_and_tool"),
    "Mask Fill in a load_post handler, opening a file saved in Sculpt Mode": (
        ["the handler refused: bpy.ops.paint.mask_flood_fill was not run: Blender is still opening the file",
         "| open ran {'FINISHED'} | after it, Mask Fill ran {'FINISHED'}"], "sculpt_update_object"),
    "a load in a load_post handler": (
        ["the handler refused: bpy.ops.wm.open_mainfile was not run: Blender is opening a file already",
         "| open ran {'FINISHED'} | after it, Mask Fill ran {'FINISHED'}"], "wm_file_read_post"),
}
# macOS's allocator fills freed memory (malloc(3), MallocScribble), so a read
# of what a load freed fails every time instead of now and then: measured 7
# runs in 7 for the load in a load_post handler, first or last in it (without
# it, 0 in 6).
SCRIBBLE = {"a load in a load_post handler": {"MallocScribble": "1"}}
RAW_SAID = {"bpy.ops.MESH.primitive_grid_add(x_subdivisions=1700, y_subdivisions=1700)":
            ["ran {'FINISHED'}", "| 2893401 vertices made"]}
check("every scenario has what it should be told", set(EXPECT) == set(SCENARIOS), set(EXPECT) ^ set(SCENARIOS))
for name, (told, frame) in EXPECT.items():
    try:
        run = child(["case", name, "guarded"], timeout=60, env=SCRIBBLE.get(name))
    except subprocess.TimeoutExpired:
        check("guarded, %s: returns" % name, False, "still running after 60 s, killed")
        continue
    said = next((l[len("CHILD said: "):] for l in run.stdout.splitlines() if l.startswith("CHILD said: ")), "")
    check("guarded, %s: %s" % (name, said[:110] if said else "exit %d" % run.returncode),
          run.returncode == 0 and "CHILD survived" in run.stdout and all(t in said for t in told),
          (run.returncode, said[:400] or run.stdout[-300:], run.crash[:300]))
    if frame == "hang":
        continue            # the lower-case control below: the same operator, UV_OT_select_edge_ring
    run = child(["case", name, "raw"], timeout=60, env=SCRIBBLE.get(name))
    said = next((l[len("CHILD said: "):] for l in run.stdout.splitlines() if l.startswith("CHILD said: ")), "")
    if frame is None:
        check("control: unguarded, %s: %s" % (name, said[:110]),
              run.returncode == 0 and all(t in said for t in RAW_SAID[name]), (run.returncode, said[:300]))
    else:
        check("control: unguarded, %s takes Blender down (exit %d, in %s)" % (name, run.returncode, frame),
              "CHILD about to run" in run.stdout and "CHILD survived" not in run.stdout and crashed_in(run, frame),
              (run.returncode, run.stdout[-300:], run.crash[:400]))

# --------------------------------------------------------------------------
print("\nA context member given what its type would not hold, each in a Blender of its own, guarded and not")


def child_alone(args, timeout=90, env=None):
    """`child`, with a temporary folder of its own, so several run at once
    without reading each other's backtraces."""
    folder = tempfile.mkdtemp(prefix="bk-unsafe-ctx-")
    run = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup", "--python", __file__, "--", *args],
                         capture_output=True, text=True, timeout=timeout, cwd=os.environ.get("HOME", folder),
                         env=dict(os.environ, TMPDIR=folder, **(env or {})))
    run.crash = "".join(p.read_text(errors="replace") for p in pathlib.Path(folder).glob("*.crash.txt"))
    return run


def context_case(job):
    name, mode = job
    try:
        return job, child_alone(["context", name, mode],
                                env={"MallocScribble": "1"} if mode == "raw" and name in SCRIBBLED else None)
    except subprocess.TimeoutExpired:
        return job, None


import concurrent.futures
jobs = [(name, mode) for name in CONTEXT_CASES for mode in ("guarded", "raw")]
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    ran = dict(pool.map(context_case, jobs))
for name, (_, told, frame) in CONTEXT_CASES.items():
    run = ran[(name, "guarded")]
    lines = run.stdout.splitlines() if run is not None else []
    said = next((l[len("CHILD said: "):] for l in lines if l.startswith("CHILD said: ")), "")
    after = next((l for l in lines if l.startswith("CHILD after: ")), "")
    check("guarded, %s: %s" % (name, said[len("refused: "):][:100] if said else
                               "exit %s" % (run.returncode if run is not None else "timeout")),
          run is not None and run.returncode == 0 and "CHILD survived" in run.stdout and said.startswith(told)
          and after == "CHILD after: ran {'FINISHED'}, 0 in force",
          (run.returncode if run else "timeout", said[:300] or (run.stdout[-300:] if run else ""), after,
           run.crash[:300] if run else ""))
    run = ran[(name, "raw")]
    frames = frame if isinstance(frame, tuple) else (frame,)
    check("control: unguarded, %s takes Blender down (exit %s, in %s)"
          % (name, run.returncode if run is not None else "timeout", " or ".join(frames)),
          run is not None and "CHILD about to run" in run.stdout and "CHILD survived" not in run.stdout
          and any(crashed_in(run, f) for f in frames),
          (run.returncode, run.stdout[-300:], run.crash[:400]) if run is not None else "still running, killed")
for where in ("script", "module"):
    run = child(["slot", where])
    said = next((l[len("CHILD said: "):] for l in run.stdout.splitlines() if l.startswith("CHILD said: ")), "")
    if where == "script":
        check("guarded, bpy.ops.uv.stitch._operator._operator() on an unwrapped cube in Edit Mode: refused in "
              "words (%s)" % said[9:70],
              run.returncode == 0 and "CHILD survived" in run.stdout
              and said.startswith("refused: This operator holds Blender's own object"), (run.returncode, said[:200]))
    else:
        check("control: what that slot holds, read the way the guards read it and called, takes Blender down "
              "(exit %d, in stitch_exit)" % run.returncode,
              "CHILD about to run" in run.stdout and "CHILD survived" not in run.stdout
              and crashed_in(run, "stitch_exit"), (run.returncode, run.stdout[-300:], run.crash[:400]))

print("\nNegative controls: the same calls without the guard, each in a Blender of its own")
for path, where, frame in (("uv.stitch", "script", "stitch_exit"), ("uv.stitch", "view", "ED_region_draw_cb_activate")):
    run = child(["raw-uv", path, where])
    check("control: unguarded, %s %s takes Blender down (exit %d, in %s)"
          % (path, "as a script line" if where == "script" else "under the borrowed 3D View", run.returncode, frame),
          "CHILD about to run" in run.stdout and "CHILD survived" not in run.stdout and crashed_in(run, frame),
          (run.returncode, run.stdout[-300:], run.crash[:400]))
run = child(["raw-macro", "uv.stitch"])
check("control: unguarded, a script's macro of uv.stitch takes Blender down (exit %d, in stitch_exit from "
      "macro_exec)" % run.returncode,
      "CHILD about to run a macro" in run.stdout and "CHILD survived" not in run.stdout
      and crashed_in(run, "stitch_exit") and "macro_exec" in run.crash,
      (run.returncode, run.stdout[-300:], run.crash[:400]))
try:
    run = child(["raw-uv", "uv.select_edge_ring", "script"], timeout=20)
    check("control: unguarded, uv.select_edge_ring as a script line returns (it should not)", False,
          (run.returncode, run.stdout[-200:]))
except subprocess.TimeoutExpired as expired:
    out = expired.stdout.decode() if isinstance(expired.stdout, bytes) else (expired.stdout or "")
    check("control: unguarded, uv.select_edge_ring as a script line has not returned after 20 s (killed)",
          "CHILD about to run" in out and "CHILD survived" not in out, out[-200:])
for mode, where in (("VERTEX_PAINT", "script"), ("SCULPT", "script"), ("VERTEX_PAINT", "thread")):
    run = child(["raw-brush", files[mode], mode, where])
    check("control: unguarded, %s a brush pick in a file opened in %s takes Blender down (exit %d, in "
          "WM_toolsystem_activate_brush_and_tool)"
          % ("with the tool made, off the main thread," if where == "thread" else "as a script line,", mode,
             run.returncode),
          ("opened in %s, 3D View tool None" % mode) in run.stdout and "CHILD about to run" in run.stdout
          and "CHILD survived" not in run.stdout and crashed_in(run, "WM_toolsystem_activate_brush_and_tool")
          and ("tool made: builtin.brush" in run.stdout) == (where == "thread"),
          (run.returncode, run.stdout[-300:], run.crash[:400]))

print("\nMask Fill with no undo stack: no route the app has reaches the crash")
sculpted = files['SCULPT']
run = child(["mask", sculpted, "raw"])
check("control: unguarded, a script line's Mask Fill with no undo stack takes Blender down (exit %d, in "
      "Sculpt Mode's undo push_begin_ex from mask_flood_fill_exec)" % run.returncode,
      "opened in SCULPT, 0 undo steps" in run.stdout and "CHILD about to run" in run.stdout
      and "CHILD survived" not in run.stdout and crashed_in(run, "push_begin_ex")
      and "mask_flood_fill_exec" in run.crash,
      (run.returncode, run.stdout[-300:], run.crash[:400]))
for where, expect in (("header", "ran"), ("search", "ran"), ("script", "ran"), ("thread", "refused")):
    run = child(["mask", sculpted, where])
    survived = [l for l in run.stdout.splitlines() if l.startswith("CHILD survived")]
    check("guarded, Mask Fill by %s with no undo stack: %s" % (where, survived[0][15:120] if survived else run.returncode),
          "opened in SCULPT, 0 undo steps" in run.stdout and run.returncode == 0 and survived
          and survived[0].startswith("CHILD survived: " + expect)
          and (where == "thread" or survived[0].endswith("1 undo steps")), run.stdout[-300:])

print("\nbpy.data.libraries.write of a scene Blender has not brought in sync, a Blender of its own each")
for variant in ("new scene", "a new scene given a second view layer", "a compositor group naming a new scene"):
    run = child_alone(["libwrite", variant, "guarded"])
    survived = [l for l in run.stdout.splitlines() if l.startswith("CHILD survived")]
    check("guarded, %s: %s" % (variant, survived[0][16:] if survived else "exit %d" % run.returncode),
          run.returncode == 0 and survived and survived[0].startswith("CHILD survived: ran None")
          and not survived[0].endswith(" 0 bytes written"), (run.returncode, run.stdout[-300:], run.crash[:300]))
    run = child_alone(["libwrite", variant, "raw"])
    check("control: unguarded, writing %s takes Blender down (exit %d, in BKE_view_layer_copy_data)"
          % (variant, run.returncode),
          "CHILD about to run" in run.stdout and "CHILD survived" not in run.stdout
          and crashed_in(run, "BKE_view_layer_copy_data"), (run.returncode, run.stdout[-300:], run.crash[:400]))

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
