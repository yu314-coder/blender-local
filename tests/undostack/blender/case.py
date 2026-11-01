"""One case of scripts/run-undostack-blender-check.sh, in a Blender of its own.

A Blender with no interface has no undo stack until `ed.undo_push` makes one,
and a file load frees it; Sculpt Mode's undo code dereferences it unchecked.
Measured in desktop 5.2.1 (window and screen in the context, gpu.init()):
`object.mode_set(mode='SCULPT')` with its undo on, and `paint.mask_flood_fill`
or `sculpt.face_sets_init` in Sculpt Mode, segfault with no stack — and the
app hit the first in its own bpy (BlenderLocal-2026-10-19-210858), its
autosave having opened in Vertex Paint, which defers the history's probe.

Two guards make the stack, and each is enough alone:

  * the history's: `_blenderkit_undo.ensure_stack`, with the history's first
    step and after every file load (`_FileRead`);
  * the operators': `_blenderkit_context.require_undo_stack`, as any operator
    is called in Sculpt Mode or into it, which also covers a call no history
    step came before — a console line that does not read as Python
    (`time python -c …`, ncdu's mini-shell; round 4's review of group 7), or
    a launch whose recovery file opened in Sculpt Mode.

Each case reaches one of those calls the way the app can, with the app's
modules and context, and prints SURVIVED after it (or REFUSED, off the main
thread, where no stack can be made). The switches turn the guards off:
`history-only` the operators', `context-only` the history's, `negative` both;
then the case has to crash where its guard was the one that held.

    Blender -b --factory-startup --python case.py -- <case> [switch]
"""
import bpy, gpu, sys, os, types, tempfile, importlib.util, pathlib

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
args = sys.argv[sys.argv.index("--") + 1:]
CASE = args[0]
NEGATIVE = "negative" in args
HISTORY_ONLY = "history-only" in args
CONTEXT_ONLY = "context-only" in args
# Off the main thread: `_blenderkit.is_main_thread()` says so once the case
# has set up (its own load and fixture need the main thread, as the app's do).
MAIN = [True]


class _App(types.ModuleType):
    # The app's C module: this is Blender's main thread unless the case says
    # otherwise; nothing else records.
    def is_main_thread(self):
        return MAIN[0]

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
context.install(bpy)
if NEGATIVE or CONTEXT_ONLY:
    # The history's guard, off: no stack with its first step or after a load.
    undo.ensure_stack = lambda label: False
if NEGATIVE or HISTORY_ONLY:
    # The operators' guard, off.
    context.require_undo_stack = lambda name, keywords: None
gpu.init()
history = tempfile.mkdtemp(prefix="bk-undostack-")
window = bpy.context.window_manager.windows[0]


def steps():
    rows = undo.blender_steps()
    return len(rows) if rows is not None else None


def say(*words):
    print(*words, flush=True)


def mask():
    return bpy.ops.paint.mask_flood_fill(mode='VALUE', value=1.0)


# The app's main-thread context: a window and its screen, no area.
with bpy.context.temp_override(window=window, screen=window.screen):
    cube = bpy.data.objects['Cube']
    bpy.context.view_layer.objects.active = cube
    if CASE.startswith("deferred"):
        # The app's launch with its autosave open in Vertex Paint: the
        # history's first push, with the probe deferred.
        bpy.ops.object.mode_set(mode='VERTEX_PAINT')
        undo.push(history, "Original")
        say("STATE probe", undo._mode, "steps", steps())
        if CASE == "deferred-sculpt-undo":
            say("ABOUT TO RUN mode_set(SCULPT) with its undo on")
            result = bpy.ops.object.mode_set('EXEC_DEFAULT', True, mode='SCULPT')
        else:
            bpy.ops.object.mode_set(mode='SCULPT')
            say("ABOUT TO RUN mask_flood_fill")
            result = mask()
    elif CASE.startswith("load-"):
        # A script that loads a file and sculpts after it.
        undo.push(history, "Original")
        say("STATE probe", undo._mode, "steps", steps())
        if CASE == "load-homefile":
            bpy.ops.wm.read_homefile()
        else:
            path = os.path.join(history, "scene.blend")
            bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
            bpy.ops.wm.open_mainfile(filepath=path)
        say("STATE after the load, steps", steps())
        bpy.context.view_layer.objects.active = bpy.data.objects['Cube']
        bpy.ops.object.mode_set(mode='SCULPT')
        say("ABOUT TO RUN face_sets_init" if CASE == "load-mainfile" else "ABOUT TO RUN mask_flood_fill")
        if CASE == "load-mainfile":
            result = bpy.ops.sculpt.face_sets_init(mode='LOOSE_PARTS')
        else:
            result = mask()
    elif CASE in ("launch-sculpt", "offmain-mask"):
        # The app's launch with its recovery file saved in Sculpt Mode:
        # RootView opens it before anything has imported the history
        # (`_FileRead` finds no `_blenderkit_undo` and makes no stack), and
        # the first command is one no history step came before — on the
        # script thread for `offmain-mask`, where no stack can be made.
        path = os.path.join(history, "sculpting.blend")
        bpy.ops.object.mode_set(mode='SCULPT')
        bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
        hidden = sys.modules.pop('_blenderkit_undo')
        bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
        sys.modules['_blenderkit_undo'] = hidden
        say("STATE after the launch's load, mode", bpy.context.object.mode, "steps", steps())
        say("ABOUT TO RUN mask_flood_fill (" + CASE + ")")
        try:
            MAIN[0] = CASE != "offmain-mask"
            result = mask()
        except RuntimeError as error:
            MAIN[0] = True
            say("REFUSED", error)
            say("STATE after the refusal, steps", steps())
            raise SystemExit(0)
    else:
        # A console line that runs Python without reading as Python (`time
        # python -c …`, ncdu's mini-shell): no history step before it.
        bpy.ops.object.mode_set(mode='SCULPT')
        say("STATE no history step, steps", steps())
        say("ABOUT TO RUN mask_flood_fill (" + CASE + ")")
        try:
            if CASE == "console-search":
                # The Operator Search's runner, the way its row runs.
                result = sync.run_operator('paint.mask_flood_fill', {})
            elif CASE == "console-in-view":
                with context.temp_override_view3d('Mask'):
                    result = mask()
            elif CASE == "console-mask":
                result = mask()
            else:
                raise SystemExit("no case " + CASE)
        except RuntimeError as error:
            say("REFUSED", error)
            raise SystemExit(0)
    say("SURVIVED", CASE, result, "mode", bpy.context.object.mode, "steps", steps())
