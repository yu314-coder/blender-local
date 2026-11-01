"""Blender's Local View (View ▸ Local View, numpad /), for the app's 3D View.

Local View is a 3D View's own state: the view keeps a bit (`local_view_uid`)
that each object in it carries in its base (`local_view_bits`), and Blender
draws, selects, snaps and frames only those. The app draws its own viewport,
so it borrows the startup screen's 3D View — the one `temp_override_view3d`
lends every operator that polls for a view — and that view's state is the one
the app shows: the mirroring pass reads which objects it holds (`state`) and
marks the others as not drawn, as Blender does not draw them.

Measured in desktop Blender 5.2.1 under `-b --factory-startup` with the app's
context — its undo push, `gpu.init()`, the borrowed view (round 4, group 7;
tests/relations/blender):

  * `view3d.localview` polls False with no 3D View in the context and
    FINISHED under the borrowed one, putting the selected objects in local
    view; with nothing selected, CANCELLED. Called again it leaves.
    `frame_selected` (on by default) frames the selection in the borrowed
    view (a 2 m cube: view distance 3.208 in its 1574 × 954 region, Blender's
    `(size / 2) × 1.4 / tan(fov / 2) × aspect`) and restores that view on the
    way out; the app frames its own camera the same way (LocalViewFraming).
  * Both operators are UNDO, not REGISTER: no redo panel, and Blender's
    history holds a "Local View" / "Remove from Local View" step, which the
    app pushes under those names. That matters: an undo whose step has no
    object carrying the view's bit ends Local View
    (`view3d_data_consistency_ensure`, blendfile.cc) — measured, entering
    without a step and undoing the next change left Local View.
  * `view3d.localview_remove_from` takes the selected objects out, deselects
    them, clears the active object if it was one, and leaves Local View when
    none is left; with nothing selected, "No object selected".
  * Under the view, `object.select_all(action='SELECT')` selected only the
    objects in local view; without it, every object. A duplicate made
    without the view stayed in local view (its base's bits are copied); an
    object added without the view did not, as one a script adds does not in
    Blender. Deleting every object in local view left the view in it with
    none: Blender leaves it on its next redraw (`space_view3d_refresh`), which
    a Blender with no window never does, so `state` does it.
  * `Object.local_view_get` raises "Viewport not in local view" outside it.
  * Blender's Add from the 3D View puts the new object in Local View; the
    app's adds run without the view, so `include_active` follows each one
    while Local View is on (`LastOperator.addingIntoLocalView`).
"""

import bpy

Refusal = RuntimeError


def space():
    """The borrowed 3D View's `SpaceView3D`, or None (the simulator's
    stand-in has no screen). The same area `temp_override_view3d` finds: the
    first 3D View of the first window's screen."""
    wm = getattr(bpy.context, 'window_manager', None)
    for window in getattr(wm, 'windows', ()):
        screen = window.screen
        if screen is None:
            continue
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                return area.spaces.active
    return None


def active(view=None):
    view = view if view is not None else space()
    return view is not None and getattr(view, 'local_view', None) is not None


def members(view=None):
    """The names of the objects in local view, or None outside it."""
    view = view if view is not None else space()
    if not active(view):
        return None
    found = set()
    for obj in bpy.context.view_layer.objects:
        try:
            if obj.local_view_get(view):
                found.add(obj.name)
        except RuntimeError:
            return None
    return found


def _in_view(call):
    import _blenderkit_context
    with _blenderkit_context.temp_override_view3d('Local View'):
        return call()


def state():
    """What the mirroring pass draws: the names in local view, or None.

    Leaves Local View first when nothing is left in it — Blender's own redraw
    does that (`ED_localview_exit_if_empty`), and without it the app would
    show an empty scene that no control explains. Only on the main thread,
    where the view can be borrowed; elsewhere the empty set stands until the
    next pass there."""
    view = space()
    if active(view):
        # What `local_view_set` changed reads back after an evaluation.
        bpy.context.evaluated_depsgraph_get()
    names = members(view)
    if names is not None and not names:
        try:
            import _blenderkit_context
            if _blenderkit_context._is_main_thread():
                _in_view(lambda: bpy.ops.view3d.localview(frame_selected=False))
                return None
        except RuntimeError:
            pass
    return names


def include_active():
    """An object added while the view is in Local View joins it, as Blender's
    Add does from its 3D View (`ED_object_add_type`: the new base gets the
    view's bit). The app adds without the view in the context, so it is done
    here, after the add. Measured in desktop 5.2.1: a cone added without the
    view was outside Local View; `local_view_set` put it in, readable once the
    depsgraph had been evaluated (read straight after, it still said False)."""
    view = space()
    if not active(view):
        return False
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        return False
    obj.local_view_set(view, True)
    bpy.context.evaluated_depsgraph_get()
    return True


def _selected():
    return [o for o in bpy.context.view_layer.objects if o.select_get()]


def check_toggle():
    """Toggle Local View's refusals, in words: entering needs something
    selected (Blender answers CANCELLED and says nothing)."""
    if active():
        return
    edit = bpy.context.edit_object
    if edit is None and not _selected():
        raise Refusal("Local View shows the selected objects by themselves, and none is selected. "
                      "Select one first.")


def toggle():
    """View ▸ Local View ▸ Toggle Local View, under the borrowed view."""
    check_toggle()
    result = _in_view(lambda: bpy.ops.view3d.localview())
    if 'FINISHED' not in result:
        raise Refusal("Blender did not change Local View.")
    return result


def check_remove():
    if not active():
        raise Refusal("Remove from Local View works in Local View.")
    if bpy.context.edit_object is not None:
        raise Refusal("Remove from Local View works in Object Mode, as in Blender.")
    if not _selected():
        raise Refusal("Remove from Local View takes the selected objects out, and none is "
                      "selected.")


def remove_from():
    """View ▸ Local View ▸ Remove from Local View, under the borrowed view."""
    check_remove()
    return _in_view(lambda: bpy.ops.view3d.localview_remove_from())


# ---------------------------------------------------------------------------
# What the 3D View's commands act on while it is in Local View
#
# Blender runs every command of its 3D View — its menus, its keys, its gizmo,
# the redo panel's re-run — in that view's context, where `selected_objects`,
# `selectable_objects`, `visible_objects` and an object-mode proportional
# transform's neighbours hold only the objects in Local View
# (`BKE_base_is_visible` checks the view's bit). The app ran them with no
# view, so objects it does not draw were acted on. Round 4's review of group 7
# measured it in desktop 5.2.1 with the app's context and Cube alone in Local
# View: without the view `select_by_type(MESH)` selected Cone, Cube and Sphere
# and `select_random` / `select_pattern('*')` all five objects; with all five
# selected a translate moved all five and a delete left only Camera and
# Light. Under the view each took Cube alone.
#
# So the bridge runs an Object Mode command under the borrowed view while it
# is in Local View (`run`). Measured on 124 of the app's Object Mode command
# bodies (the Select menu, Delete, Duplicate, the Object menu's rows, a gizmo
# Move, Rotate and Scale in every orientation, proportional and Individual
# Origins, the adds with `include_active`, Move and Link to Collection, Local
# View's own rows), each run from the same fixture with every object in
# Local View, plain and under the view: the same scene after every one but
# one kind. An unconstrained `transform.rotate` turned the other way: in a 3D
# View Blender flips the axis of a rotation with no constraint axis, "so the rotation
# direction matches the mouse movement in view space"
# (`transform_mode_rotation_axis_get`, transform_mode.cc; ROTATE with value
# 0.4 about Z took a cube from 0.7 to 0.3 rad under the view, 1.1 without).
# The app's rotations are the headless Blender's — the gizmo previews them so
# (TransformGizmo) — so under the scope a rotation with no constraint axis
# is sent with its value negated, which is the same turn about the flipped
# axis (`_blenderkit_context._Rotate`). Measured: all 124 bodies then the
# same plain and under the view, and none crashed. With Cube and Cone in
# Local View and Sphere and Light outside it and selected, 16 of them
# (tests/relations/blender) each left the objects outside it as they were,
# 15 changing what it holds (Select Random may pick what is picked); bare,
# those 15 each changed an object outside it.
#
# Only in Object Mode: in Edit Mode the mesh operators act on the objects
# being edited, all of which Local View holds (it takes them when entered from
# Edit Mode, and an object entering Edit Mode from it under this scope is one
# it holds), and some read the view's direction when it is there (`mesh.spin`'s
# axis, `uv.project_from_view`). Not for scripts and the console, which Blender
# runs from the Text Editor and the Python Console, with no 3D View.

_scope_depth = 0


def in_scope():
    """Whether a command is running under the borrowed view because of Local
    View (`scope`)."""
    return _scope_depth > 0


class scope:
    """Runs what is inside it as Blender's 3D View runs a command in Local
    View: under the borrowed view, when Blender is in Local View and in Object
    Mode, on the main thread. Otherwise it does nothing — outside Local View
    nothing changes."""

    def __init__(self):
        self._view = None

    def __enter__(self):
        global _scope_depth
        try:
            import _blenderkit_context
        except ImportError:
            return self
        if not _blenderkit_context._is_main_thread():
            return self
        if not active() or getattr(bpy.context, 'mode', 'OBJECT') != 'OBJECT':
            return self
        view = _blenderkit_context.temp_override_view3d('Local View')
        view.__enter__()
        self._view = view
        _scope_depth += 1
        return self

    def __exit__(self, *exc):
        global _scope_depth
        if self._view is None:
            return False
        _scope_depth -= 1
        view, self._view = self._view, None
        return view.__exit__(*exc)


def run(source, namespace):
    """One command of the 3D View's, as the bridge sends it (`BpyBridge.execute`):
    `source` compiled and run in `namespace` — the interpreter's own globals, so
    what it defines stays defined, as when it ran bare — inside `scope`."""
    code = compile(source, '<command>', 'exec')
    with scope():
        exec(code, namespace)
