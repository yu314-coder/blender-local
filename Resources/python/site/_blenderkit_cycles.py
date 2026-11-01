"""The warning a script's first Cycles render on the GPU gets.

Cycles compiles its Metal kernels the first time it renders on a device:
minutes, once, cached after. The Render panel says so before that render
(`bl_cycles_kernels_built`, PaintRenderWorkspaces.swift); a script's
`bpy.ops.render.render()` said nothing — on the user's iPad M3 a script render
was still running at 195 s with no word why. So while a script that renders
runs before the kernels are known to be built (BpySession arms this), a
`render_pre` handler prints the panel's warning once, before Blender starts
the render, if the render is Cycles on the GPU; and a `render_complete`
handler notes that one finished there, so the app can stop asking.

Measured in desktop Blender 5.2.1 under `-b` (tests/render/blender/verify.py):
`bpy.ops.render.render()` called from a script runs `render_pre` on the
calling thread before the render starts and `render_complete` after it, and
what the handler prints is written before Blender's own render output.
"""

import bpy

_warning = None
_said = False
_built = False


def renders_on_gpu(scene):
    """Whether `scene` renders with Cycles on a GPU: Cycles, the scene's
    device GPU, and a GPU compute device chosen and enabled in Cycles'
    preferences — without one, Cycles renders on the CPU whatever the scene
    says."""
    if scene is None or scene.render.engine != 'CYCLES':
        return False
    cycles = getattr(scene, 'cycles', None)
    if cycles is None or cycles.device != 'GPU':
        return False
    addon = bpy.context.preferences.addons.get('cycles')
    if addon is None:
        return False
    prefs = addon.preferences
    if getattr(prefs, 'compute_device_type', 'NONE') == 'NONE':
        return False
    return any(device.use and device.type != 'CPU' for device in getattr(prefs, 'devices', ()))


@bpy.app.handlers.persistent
def _bk_cycles_render_pre(scene, *_):
    global _said
    if _said or _warning is None:
        return
    try:
        on_gpu = renders_on_gpu(scene)
    except Exception:                               # noqa: BLE001 - a warning must never stop a render
        return
    if on_gpu:
        _said = True
        print(_warning, flush=True)


@bpy.app.handlers.persistent
def _bk_cycles_render_complete(scene, *_):
    global _built
    try:
        if renders_on_gpu(scene):
            _built = True
    except Exception:                               # noqa: BLE001
        pass


_HANDLERS = ((lambda: bpy.app.handlers.render_pre, _bk_cycles_render_pre),
             (lambda: bpy.app.handlers.render_complete, _bk_cycles_render_complete))


def arm(warning):
    """Before a script that may render runs: the warning is printed before
    its first Cycles render on the GPU. Handlers are found and replaced by
    name, so arming twice keeps one of each."""
    global _warning, _said, _built
    _warning, _said, _built = str(warning), False, False
    for collection, function in _HANDLERS:
        handlers = collection()
        for existing in list(handlers):
            if getattr(existing, '__name__', '') == function.__name__:
                handlers.remove(existing)
        handlers.append(function)


def disarm():
    """After the script: the handlers go, and the answer is whether a Cycles
    render finished on the GPU while they were there (the kernels are built)."""
    global _warning
    for collection, function in _HANDLERS:
        handlers = collection()
        for existing in list(handlers):
            if getattr(existing, '__name__', '') == function.__name__:
                handlers.remove(existing)
    _warning = None
    return _built
