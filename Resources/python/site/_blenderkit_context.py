"""`Context.temp_override` on the thread scripts run on.

Scripts run on a thread of their own so the interface keeps drawing (the
Scripting tab's Options > Run Scripts Off the Main Thread). Blender's context gives out its window,
screen, area and region on the main thread only: anywhere else they read None.
`temp_override` reads those same members to learn what to put back. Off the
main thread it read None, and at the end of the block it wrote None into the
one context the main thread shares.

From then on the main thread had no window and no screen either. Every
operator that needs one failed its poll, Blender's undo included, which fell
back to .blend checkpoints until the app was restarted. One
`temp_override(window=...)` on a worker thread is enough, in desktop Blender
too.

Those members never reach the operators off the main thread anyway: inside
the block `context.area` still reads None there. So off the main thread they
are left out, and a warning says so. The other members, such as
`active_object` or `selected_objects`, still apply.

The session runs a script that mentions `temp_override` on the main thread
to begin with (`ScriptThread` in BpyRuntime.swift), where the override works
as it does in Blender. This covers the calls that check cannot see, such as
one in a module the script imports.

Loading a file is the other thing that needs the main thread. It takes down
Blender's screen on the way (`guard_file_reads`), and on the script thread
that crashed the app, so off the main thread the operators that do it are
refused in words instead.
"""
import sys
import threading
import warnings

# The members Blender reads back through the main-thread-only accessors.
UI_MEMBERS = ('window', 'screen', 'area', 'region')

# The `bpy.ops.wm` operators that load a .blend over the scene. The same names
# as `ScriptThread.fileReads` in the Swift, which runs a script that mentions
# one on the main thread; run-scriptthread-tests.sh compares the two.
FILE_READS = ('read_homefile', 'read_factory_settings', 'open_mainfile',
              'revert_mainfile', 'recover_last_session', 'recover_auto_save')
# Of those, the ones with a Load UI option.
LOAD_UI_OPTION = ('read_homefile', 'open_mainfile')

# The `bpy.ops.mesh` operators that segfault Blender when the context has no
# 3D View region. Measured in desktop 5.2.1 with the app's context (its undo
# push, gpu.init(), window and screen but no area, which is what a script and
# the operator search have): `mesh.loopcut(edge_index=0)` and the line Blender's
# Info editor logs for every loop cut, `mesh.loopcut_slide(MESH_OT_loopcut={...,
# "edge_index": 4}, ...)`, both crashed in `loopcut_init` (called from
# `wm_macro_exec`). Under `temp_override_view3d` both work: the factory cube in
# Edit Mode went from 8/12/6 to 12/20/10 vertices/edges/faces.
NEEDS_VIEW = ('loopcut', 'loopcut_slide')


def _is_main_thread():
    try:
        import _blenderkit
        return _blenderkit.is_main_thread()
    except (ImportError, AttributeError):
        # Desktop Blender, in the checks: Python was started on its main thread.
        return threading.current_thread() is threading.main_thread()


def install(bpy):
    """Wrap `bpy.types.Context.temp_override`, once. Returns whether it is wrapped.

    Guards the file-reading operators too (`guard_file_reads`).
    """
    guard_file_reads(bpy)
    context_type = getattr(bpy.types, 'Context', None)
    original = getattr(context_type, 'temp_override', None)
    if original is None:
        return False
    if getattr(original, '_blenderkit_original', None) is not None:
        return True

    def temp_override(self, **members):
        if not _is_main_thread():
            dropped = [name for name in UI_MEMBERS if name in members]
            if dropped:
                for name in dropped:
                    del members[name]
                warnings.warn(
                    'temp_override ignored ' + ', '.join(dropped) + ': Blender gives out '
                    'the window, screen, area and region on the main thread only, and this '
                    'call ran on the script thread. A script that calls temp_override itself '
                    'runs on the main thread; for a call from somewhere else, such as an '
                    'imported module, turn off Run Scripts Off the Main Thread in the '
                    "Scripting tab's Options menu.",
                    RuntimeWarning, stacklevel=2)
        return original(self, **members)

    temp_override.__doc__ = original.__doc__
    temp_override.__name__ = 'temp_override'
    temp_override._blenderkit_original = original
    context_type.temp_override = temp_override
    return True


class _Guarded:
    # An operator as `bpy.ops` hands it out, with a check before the call.
    # Everything but the call is the operator's own: poll, idname,
    # get_rna_type, bl_options, and the signature Blender prints for it.
    __slots__ = ('_operator', '_name')

    def __init__(self, operator, name):
        self._operator = operator
        self._name = name

    def __getattr__(self, name):
        return getattr(self._operator, name)

    def __dir__(self):
        return dir(self._operator)

    def __repr__(self):
        return repr(self._operator)

    @property
    def __doc__(self):
        return self._operator.__doc__


class _FileRead(_Guarded):
    # One of FILE_READS, refused off the main thread.
    __slots__ = ()
    # A class body sets __doc__ (None without a docstring), which would hide
    # the operator's own, Blender's signature line.
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        if not _is_main_thread():
            raise RuntimeError(
                'bpy.ops.wm.' + self._name + ' was not run: loading a file takes down '
                "Blender's screen, which exists on the main thread only, and on the "
                'script thread it crashed the app. A script that calls it by name runs '
                'on the main thread; for a call from somewhere else, such as an imported '
                'module, turn off Run Scripts Off the Main Thread in the Scripting '
                "tab's Options menu.")
        if self._name in LOAD_UI_OPTION:
            keywords.setdefault('load_ui', False)
        return self._operator(*args, **keywords)


class _NeedsView(_Guarded):
    # One of NEEDS_VIEW, refused unless the context has a 3D View region.
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        import bpy
        area, region = bpy.context.area, bpy.context.region
        if area is None or area.type != 'VIEW_3D' or region is None or region.type != 'WINDOW':
            raise RuntimeError(
                'bpy.ops.mesh.' + self._name + ' was not run: it cuts at the edge under '
                "the pointer in a 3D View, and with no 3D View in the context Blender "
                'crashes in it. Use Mesh > Loop Cut with an edge ring selected, or run it '
                "inside `with _blenderkit_context.temp_override_view3d('Loop Cut'):`.")
        return self._operator(*args, **keywords)


def guard_file_reads(bpy):
    """Refuse the operators that load a file anywhere but the main thread, once.

    Every one of FILE_READS goes through `wm_file_read_setup_wm_init`, which
    calls `ED_screen_exit` for every window before it looks at `load_ui`, and
    that asks the context for the window. Blender gives the window out on the
    main thread only (`ctx_wm_python_context_get`), so on the script thread it
    read NULL and `WM_event_modal_handler_region_replace` read `win->runtime`
    at 0xf0: EXC_BAD_ACCESS at 0xf0 in the app, from a script's
    `bpy.ops.wm.read_homefile()` (reports BlenderLocal-2026-09-22-100656 and
    -100743). A script that names one runs on the main thread
    (`ScriptThread.needsMainThread`); this refuses the calls that check cannot
    see, such as one in a module the script imports.

    On the main thread each is Blender's, measured in desktop 5.2.1 with the
    app's context (undo stack, gpu.init, a 3D View override): all six return
    FINISHED and the undo push and the view override still work after. One
    thing differs from Blender: `read_homefile` and `open_mainfile` keep the
    app's screen unless the call asks for the file's (`load_ui=True`), as
    File > New and File > Open do. The app draws its own interface, and Knife
    Project, sculpting and hiding borrow the 3D View of the screen Blender
    started with; a file saved with no 3D View on its screen, opened with its
    own interface, left them nothing to borrow.

    `bpy.ops.wm.read_homefile` is made on every access, by
    `bpy.ops._op_create_function`, so that is what is wrapped. The same wrapper
    refuses NEEDS_VIEW outside a 3D View. Returns whether the operators are
    guarded: the simulator's stand-in has no such function and needs no guard.
    """
    ops = sys.modules.get('bpy.ops')
    # From the module's own namespace: its __getattr__ answers any name.
    create = getattr(ops, '__dict__', {}).get('_op_create_function')
    if create is None:
        return False
    if getattr(create, '_blenderkit_original', None) is not None:
        return True

    def _op_create_function(module, name):
        operator = create(module, name)
        if module == 'wm' and name in FILE_READS:
            return _FileRead(operator, name)
        if module == 'mesh' and name in NEEDS_VIEW:
            return _NeedsView(operator, name)
        return operator

    _op_create_function._blenderkit_original = create
    ops._op_create_function = _op_create_function
    return True


def _is_real_blender(bpy):
    """Blender's operators carry their RNA; the simulator's stand-in's are
    plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


class temp_override_view3d:
    """The startup screen's 3D View, for an operator whose poll asks for one.

    Measured in Blender 5.2.1 under `-b --factory-startup`, the bpy an iPad
    has: `object.hide_view_set` and `object.hide_view_clear` fail their poll
    ("context is incorrect"), because both check for a 3D View (`object_hide_poll`
    wants `ED_operator_view3d_active`). The window manager still holds the
    startup screen and its 3D View; under `temp_override(window, area, region)`
    with that view both poll True and act exactly as on a desktop — Hide
    deselects what it hides, Show Hidden selects what it shows, and each
    returns CANCELLED when there is nothing to do.

    Named for `temp_override` on purpose: a script that mentions it runs on the
    main thread (`ScriptThread.needsMainThread`), which is the only thread
    Blender gives a window, area and region out on. Off it this refuses in
    words rather than letting the poll fail. In the simulator's stand-in, which
    has no screen and no poll, it does nothing.

    `what` names the command in the refusal.
    """

    def __init__(self, what):
        self.what = what
        self._override = None

    def __enter__(self):
        import bpy
        if not _is_real_blender(bpy):
            return self
        if not _is_main_thread():
            raise RuntimeError(
                self.what + " works through Blender's 3D View, which exists on the main "
                "thread only. To run it from a script, turn off Run Scripts Off the Main "
                "Thread in the Scripting tab's Options menu.")
        for window in bpy.context.window_manager.windows:
            screen = window.screen
            if screen is None:
                continue
            for area in screen.areas:
                if area.type != 'VIEW_3D':
                    continue
                for region in area.regions:
                    if region.type == 'WINDOW':
                        self._override = bpy.context.temp_override(
                            window=window, area=area, region=region)
                        self._override.__enter__()
                        return self
        raise RuntimeError(self.what + " works through Blender's 3D View, and Blender's "
                           "screen has none to borrow")

    def __exit__(self, *exc):
        if self._override is not None:
            return self._override.__exit__(*exc)
        return False


class needs_essentials:
    """Says why an operator that loads from Blender's Essentials asset library
    failed, when that library is not there.

    `object.shade_auto_smooth` adds the "Smooth by Angle" node group from
    `datafiles/assets/nodes/geometry_nodes_essentials.blend`. The bpy staged
    into the app has no `datafiles/assets` at all (its datafiles are
    colormanagement, fonts, icons and locale), and a desktop Blender with that
    folder removed answers `RuntimeError: Error: No asset found at path ""`
    and adds nothing (5.2.1, measured). That sentence names neither the
    library nor what to do instead, so it is replaced with one that does.
    Any other failure passes through unchanged.
    """

    def __init__(self, what, instead):
        self.what = what
        self.instead = instead

    def __enter__(self):
        return self

    def __exit__(self, kind, error, traceback):
        # The words stay for the case `essentials_available` cannot see: a
        # library that is there and does not hold the asset.
        if kind is not None and issubclass(kind, RuntimeError) and 'No asset found' in str(error):
            raise RuntimeError(
                self.what + " adds a node group from Blender's Essentials asset library, "
                "which this build of Blender does not include. " + self.instead) from None
        return False


# The file `object.shade_auto_smooth` takes "Smooth by Angle" from, relative to
# the Essentials library (`relative_asset_identifier` in object_edit.cc).
ESSENTIALS_NODES = ('nodes', 'geometry_nodes_essentials.blend')


def essentials_available():
    """Whether Blender's Essentials asset library is installed, with the node
    group Shade Auto Smooth adds.

    The interface asks once and greys the row out without it, rather than
    offer an operator that fails every time. Blender finds the library at
    `BKE_appdir_folder_id(BLENDER_SYSTEM_DATAFILES, "assets")`, which is what
    `bpy.utils.system_resource('DATAFILES', path='assets')` answers — an empty
    string when the folder is not there. Measured in 5.2.1: the desktop app
    answers its `datafiles/assets` and Auto Smooth adds its modifier; an APFS
    clone of it with that folder removed answers '' and Auto Smooth fails with
    'No asset found at path ""'. The bpy staged into the device app has
    colormanagement, fonts, icons and locale in its datafiles and no assets.
    The simulator's stand-in has no `bpy.utils.system_resource`, and no
    Auto Smooth either.
    """
    import os
    try:
        import bpy
        folder = bpy.utils.system_resource('DATAFILES', path='assets')
    except Exception:                               # noqa: BLE001 - no library is the answer
        return False
    return bool(folder) and os.path.isfile(os.path.join(folder, *ESSENTIALS_NODES))
