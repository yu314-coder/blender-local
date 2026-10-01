"""Snapping, the pivot point and proportional editing — Blender's precision
trio — plus the 3D cursor they all work against.

Blender keeps these on `scene.tool_settings` and its 3D View header reads them
straight back out. They are settings, not operators, so everything written here
is reported back as well: `report()` runs at the end of every mirroring pass,
so a control shows what Blender holds rather than what the interface last asked
for. A pivot menu that cannot show the current pivot is not a pivot menu.

Two things could not be done the way Blender's own 3D View does them. Both were
measured in Blender 5.2.1 LTS under `-b --factory-startup`, which is the bpy an
iPad has — no window, no area, no region:

  * All four `bpy.ops.view3d.snap_*` fail their poll: `poll()` is False for
    snap_cursor_to_center, snap_cursor_to_selected, snap_selected_to_grid and
    snap_selected_to_cursor ("Expected a view3d region"), because they read the
    grid step and the pivot from the region. `snap()` does what they do from
    the same RNA instead — the compromise `_blenderkit_anim.keyframe_insert`
    already makes for `bpy.ops.anim.keyframe_insert`, for the same reason.

  * `tool_settings` alone changes nothing about a transform run headless.
    Measured: with `use_proportional_edit = True` one vertex of 121 moved, the
    same as with it False; all five `transform_pivot_point` identifiers rotated
    cubes at x = 0, 4 and 10 about x = 5, the centre of their bounds — with no
    View3D, `initTransInfo` falls back to V3D_AROUND_CENTER_BOUNDS. The same
    values passed as *operator arguments* do work — 69 of 121 vertices, and
    `center_override=(0,0,0)` moving a cube at (2,0,0) to (0,2,0) on a 90
    degree Z rotate — so TransformGizmo.python appends them per transform.
    What is written here is still real scene state: it survives into the
    .blend and means what it says when the file opens on a desktop.

  * Snapping during a transform does not happen headless either: the exec
    path takes the operator's `value` as final. The gizmo snaps its own
    result and sends the snapped value (TransformSnap in
    TransformEvaluation.swift).

The simulator's shim keeps the same values in Swift, behind the same property
names (`_AnimToolSettings` and `_ToolCursor` in bpy/__init__.py), so writing is one
code path for both backends. What a transform then does with them is one code
path too: the shim's `bpy.ops.transform.*` hand their arguments to
TransformOperation, the Swift the gizmo previews with.
"""

import math

import bpy
import _blenderkit

from mathutils import Vector

from _blenderkit_anim import is_real_blender

# scene.tool_settings enums, in the order Blender's RNA lists them — which is
# the order the interface numbers them by (TransformTools.swift). Read back
# from bl_rna in 5.2.1; a build that grows an identifier reports index 0 rather
# than raising in the middle of a mirroring pass.
ELEMENTS = ('INCREMENT', 'GRID', 'VERTEX', 'EDGE', 'FACE', 'VOLUME',
            'EDGE_MIDPOINT', 'EDGE_PERPENDICULAR', 'FACE_MIDPOINT')
INDIVIDUAL = ('FACE_PROJECT', 'FACE_NEAREST')
TARGETS = ('CLOSEST', 'CENTER', 'MEDIAN', 'ACTIVE')
PIVOTS = ('BOUNDING_BOX_CENTER', 'CURSOR', 'INDIVIDUAL_ORIGINS',
          'MEDIAN_POINT', 'ACTIVE_ELEMENT')
FALLOFFS = ('SMOOTH', 'SPHERE', 'ROOT', 'INVERSE_SQUARE', 'SHARP', 'LINEAR',
            'CONSTANT', 'RANDOM')

# proportional_size's hard range, read from bl_rna in 5.2.1. Measured: bpy
# clamps to it rather than raising (0.0 became 1e-5, 9000 became 5000), so an
# unclamped field would show a number Blender never held until the next
# mirroring pass corrected it.
SIZE_MIN, SIZE_MAX = 1e-5, 5000.0

# double_threshold's hard range, read from bl_rna in 5.2.1.
MERGE_MIN, MERGE_MAX = 0.0, 1.0

# The tool settings that are one switch each, packed into one int in this
# order (TransformToolsMirror.SnapTargetFlag): snapping's two Target Selection
# options, Auto Merge's Split Edges & Faces, and the Options popover's Affect
# Only Parents and Affect Only Origins. The last three were not mirrored, and
# the translate the gizmo commits reads each of them from the scene (measured
# in 5.2.1): a move that Blender committed with a split edge, a child left in
# place or only the origin moved was previewed as none of those.
SNAP_FLAGS = ('use_snap_self', 'use_snap_nonedit', 'use_mesh_automerge_and_split',
              'use_transform_skip_children', 'use_transform_data_origin')

# The Shift+S menu, in Blender's order: VIEW3D_MT_snap in 5.2.1's
# scripts/startup/bl_ui/space_view3d.py.
SNAP_ACTIONS = ('SELECTED_TO_GRID', 'SELECTED_TO_CURSOR', 'SELECTED_TO_ACTIVE',
                'CURSOR_TO_SELECTED', 'CURSOR_TO_CENTER', 'CURSOR_TO_GRID',
                'CURSOR_TO_ACTIVE')


def _bits(names, values):
    return sum(1 << i for i, name in enumerate(names) if name in values)


def _index(names, value):
    return names.index(value) if value in names else 0


# ---------------------------------------------------------------------------
# The mirror
# ---------------------------------------------------------------------------

def report():
    """Hand the interface Blender's tool settings and 3D cursor.

    Called from `_blenderkit_sync.sync`, which runs after every command, so a
    setting changed by a script shows in the header too. `sync_selection` — the
    tap path — deliberately does not call it: a tap cannot change a setting,
    and avoiding the full pass is what that path is for.

    The eleven ints and five doubles are in one fixed order, written out four
    times: here, in `tool_state` in PythonBootstrap.c, in
    `TransformToolsMirror` in Swift and in the shim's `_TOOL_FIELDS`. A field
    added to one and not the others shifts every value after it, silently.
    """
    if not hasattr(_blenderkit, 'tool_state') or not is_real_blender():
        # The shim's tool settings are Swift's to begin with.
        return
    scene = bpy.context.scene
    ts = scene.tool_settings
    cursor = scene.cursor.location
    _blenderkit.tool_state(
        int(ts.use_snap),
        _bits(ELEMENTS, ts.snap_elements_base),
        _bits(INDIVIDUAL, ts.snap_elements_individual),
        _index(TARGETS, ts.snap_target),
        _index(PIVOTS, ts.transform_pivot_point),
        int(ts.use_proportional_edit),
        int(ts.use_proportional_edit_objects),
        int(ts.use_proportional_connected),
        _index(FALLOFFS, ts.proportional_edit_falloff),
        int(ts.use_mesh_automerge),
        sum(1 << i for i, name in enumerate(SNAP_FLAGS) if getattr(ts, name)),
        float(ts.proportional_size),
        float(cursor[0]), float(cursor[1]), float(cursor[2]),
        float(ts.double_threshold))


# ---------------------------------------------------------------------------
# Writing, from the header's menus and the N-panel
# ---------------------------------------------------------------------------

def set_tools(**changes):
    """Write one or more tool settings, as Blender's header does.

    Named arguments rather than one dict so a misspelling is a TypeError here
    instead of a setting that silently never changes.
    """
    ts = bpy.context.scene.tool_settings
    if 'use_snap' in changes:
        ts.use_snap = bool(changes.pop('use_snap'))
    if 'elements' in changes:
        # snap_elements_base, not snap_elements. Measured in 5.2.1: assigning
        # {'FACE_NEAREST'} to the alias moves the value into
        # snap_elements_individual and leaves the base set empty.
        ts.snap_elements_base = set(changes.pop('elements'))
    if 'individual' in changes:
        ts.snap_elements_individual = set(changes.pop('individual'))
    if 'target' in changes:
        ts.snap_target = changes.pop('target')
    if 'pivot' in changes:
        ts.transform_pivot_point = changes.pop('pivot')
    if 'proportional_edit' in changes:
        ts.use_proportional_edit = bool(changes.pop('proportional_edit'))
    if 'proportional_objects' in changes:
        ts.use_proportional_edit_objects = bool(changes.pop('proportional_objects'))
    if 'connected' in changes:
        ts.use_proportional_connected = bool(changes.pop('connected'))
    if 'falloff' in changes:
        ts.proportional_edit_falloff = changes.pop('falloff')
    if 'size' in changes:
        ts.proportional_size = min(max(float(changes.pop('size')), SIZE_MIN), SIZE_MAX)
    if 'automerge' in changes:
        ts.use_mesh_automerge = bool(changes.pop('automerge'))
    if 'merge_threshold' in changes:
        ts.double_threshold = min(max(float(changes.pop('merge_threshold')), MERGE_MIN), MERGE_MAX)
    if 'snap_self' in changes:
        ts.use_snap_self = bool(changes.pop('snap_self'))
    if 'snap_nonedit' in changes:
        ts.use_snap_nonedit = bool(changes.pop('snap_nonedit'))
    if 'automerge_split' in changes:
        ts.use_mesh_automerge_and_split = bool(changes.pop('automerge_split'))
    if 'skip_children' in changes:
        ts.use_transform_skip_children = bool(changes.pop('skip_children'))
    if 'data_origin' in changes:
        ts.use_transform_data_origin = bool(changes.pop('data_origin'))
    if changes:
        raise TypeError("set_tools() got unexpected keyword arguments: %s"
                        % ', '.join(sorted(changes)))
    report()


def set_cursor(x, y, z):
    """The N-panel's 3D Cursor fields.

    Blender keeps the cursor on the scene rather than in tool_settings, but it
    rides in the same mirror because the Snap menu is the thing that moves it.
    """
    bpy.context.scene.cursor.location = (float(x), float(y), float(z))
    report()


# ---------------------------------------------------------------------------
# The Shift+S snap menu
# ---------------------------------------------------------------------------

def _editing_mesh():
    return bpy.context.mode == 'EDIT_MESH'


def _selected_editable():
    """What Blender's snap operators act on. The shim's context has no
    `selected_editable_objects`; nothing in it is ever non-editable."""
    context = bpy.context
    return list(getattr(context, 'selected_editable_objects', None)
                or context.selected_objects)


def _selected_world_points(objects):
    """What Cursor to Selected measures: the selected vertices in edit mode,
    the selected objects' origins otherwise.

    Blender's snap_curs_to_sel_ex uses the object's world-space *origin* in
    object mode, not its bounding box, for both the median and the bounds.
    """
    if _editing_mesh():
        points = []
        for obj in objects:
            if getattr(obj, 'type', '') != 'MESH':
                continue
            # The edits live in the BMesh until this is called; without it the
            # mesh data still holds the positions from when edit mode started.
            obj.update_from_editmode()
            matrix = obj.matrix_world
            points += [matrix @ v.co for v in obj.data.vertices if v.select]
        return points
    return [obj.matrix_world.translation.copy() for obj in objects]


def _selection_point():
    """Where Cursor to Selected puts the cursor, or None with nothing selected.

    Blender picks the bounding-box centre of those points when the pivot is
    BOUNDING_BOX_CENTER and their median otherwise. That reading could not be
    held against the operator — its poll fails headless — so it is Blender's
    documented behaviour, not a measurement. The two differ: origins at 0, 4
    and 10 give a median of 4.667 and a bounds centre of 5.0.
    """
    points = _selected_world_points(_selected_editable())
    if not points:
        return None
    if bpy.context.scene.tool_settings.transform_pivot_point == 'BOUNDING_BOX_CENTER':
        return Vector([(min(p[i] for p in points) + max(p[i] for p in points)) / 2.0
                       for i in range(3)])
    total = Vector((0.0, 0.0, 0.0))
    for p in points:
        total += Vector(p)
    return total / float(len(points))


def _grid(value, step):
    """One coordinate onto the grid, as view3d_snap.cc rounds it:
    `gridf * floorf(0.5f + v / gridf)` — halves go up. Python's round() sends
    them to the even neighbour, so 0.5 on a grid of 1 went to 0 where Blender
    puts it at 1."""
    return step * math.floor(0.5 + value / step)


def _active_point():
    """What Blender's `calc_active_center` gives the two "to Active" actions,
    or None: the active object's origin, or while editing the active vertex,
    edge midpoint or face median — the last element selected."""
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        return None
    if _editing_mesh() and getattr(obj, 'type', '') == 'MESH':
        import bmesh
        element = bmesh.from_edit_mesh(obj.data).select_history.active
        if element is None:
            return None
        if isinstance(element, bmesh.types.BMVert):
            co = element.co.copy()
        elif isinstance(element, bmesh.types.BMEdge):
            co = (element.verts[0].co + element.verts[1].co) / 2.0
        else:
            co = element.calc_center_median()
        return obj.matrix_world @ co
    return obj.matrix_world.translation.copy()


def _movable(objects):
    """The selection minus anything whose parent is moving too.

    Blender's snap operators skip a child of a transformed parent, and so must
    this: `matrix_world` is derived from the parent's, so moving the parent
    first and then reading the child's world matrix back reads a matrix the
    depsgraph has not recomputed.
    """
    chosen = set(objects)
    out = []
    for obj in objects:
        parent = obj.parent
        while parent is not None and parent not in chosen:
            parent = parent.parent
        if parent is None:
            out.append(obj)
    return out


def _edit_vertices(objects):
    """The selected vertices of every mesh being edited, as BMesh verts.

    bmesh is imported here rather than at the top: it is only the edit-mode
    branch that needs it, and nothing else in this app's Python imports it.
    Writing `mesh.vertices[i].co` would not do — in edit mode the positions
    Blender is editing are the BMesh's, and the mesh data is a stale copy.
    """
    import bmesh
    out = []
    for obj in objects:
        if getattr(obj, 'type', '') != 'MESH':
            continue
        bm = bmesh.from_edit_mesh(obj.data)
        verts = [v for v in bm.verts if v.select]
        if verts:
            out.append((obj, bm, verts))
    return out


def snap(action, use_offset=False, step=1.0):
    """Blender's Shift+S menu: VIEW3D_MT_snap.

    `bpy.ops.view3d.snap_*` cannot be called from here. Measured in 5.2.1
    headless, `poll()` is False for all of them — "Expected a view3d region" —
    because they take the grid step and the pivot from the region a bpy module
    has none of. What they do is done from the same RNA instead.
    """
    if action not in SNAP_ACTIONS:
        raise ValueError("unknown snap action %r; expected one of %s"
                         % (action, ', '.join(SNAP_ACTIONS)))
    if not is_real_blender():
        # The shim implements them as operators of its own, over the display
        # cache (BKScene's snap* in SceneOperators.swift).
        view3d = bpy.ops.view3d
        if action == 'CURSOR_TO_CENTER':
            view3d.snap_cursor_to_center()
        elif action == 'CURSOR_TO_SELECTED':
            view3d.snap_cursor_to_selected()
        elif action == 'CURSOR_TO_GRID':
            view3d.snap_cursor_to_grid(step=float(step))
        elif action == 'CURSOR_TO_ACTIVE':
            view3d.snap_cursor_to_active()
        elif action == 'SELECTED_TO_CURSOR':
            view3d.snap_selected_to_cursor(use_offset=bool(use_offset))
        elif action == 'SELECTED_TO_ACTIVE':
            view3d.snap_selected_to_active()
        else:
            view3d.snap_selected_to_grid(step=float(step))
        return

    scene = bpy.context.scene
    step = abs(float(step)) or 1.0
    if action == 'CURSOR_TO_CENTER':
        scene.cursor.location = (0.0, 0.0, 0.0)
        scene.cursor.rotation_euler = (0.0, 0.0, 0.0)
        report()
        return

    if action == 'CURSOR_TO_GRID':
        scene.cursor.location = [_grid(c, step) for c in scene.cursor.location]
        report()
        return

    if action == 'CURSOR_TO_SELECTED':
        point = _selection_point()
        if point is None:
            raise RuntimeError("Nothing selected to snap the cursor to")
        scene.cursor.location = point
        report()
        return

    if action == 'CURSOR_TO_ACTIVE':
        point = _active_point()
        if point is None:
            raise RuntimeError("No active element found!")
        scene.cursor.location = point
        report()
        return

    objects = _selected_editable()
    if not objects:
        raise RuntimeError("Nothing selected to snap")
    if action == 'SELECTED_TO_ACTIVE':
        # snap_selected_to_active is Selection to Cursor, with no offset, at
        # the active element instead of the cursor.
        target = _active_point()
        if target is None:
            raise RuntimeError("No active element found!")
        use_offset = False
    else:
        target = Vector(scene.cursor.location)

    if _editing_mesh():
        import bmesh
        offset = target - _selection_point() if use_offset else None
        for obj, bm, verts in _edit_vertices(objects):
            matrix = obj.matrix_world
            inverse = matrix.inverted()
            for v in verts:
                world = matrix @ v.co
                if action == 'SELECTED_TO_GRID':
                    world = Vector([_grid(world[i], step) for i in range(3)])
                elif offset is not None:
                    world = world + offset
                else:
                    world = Vector(target)
                v.co = inverse @ world
            bmesh.update_edit_mesh(obj.data)
        report()
        return

    offset = target - _selection_point() if use_offset else None
    for obj in _movable(objects):
        world = obj.matrix_world.translation
        if action == 'SELECTED_TO_GRID':
            destination = Vector([_grid(world[i], step) for i in range(3)])
        elif offset is not None:
            destination = Vector(world) + offset
        else:
            destination = Vector(target)
        # matrix_world.translation, not location: it is parent-safe. Measured,
        # a parented child asked for a world target of (2,2,2) had its local
        # location recomputed rather than being moved twice by the parent.
        obj.matrix_world.translation = destination
    report()


# ---------------------------------------------------------------------------
# Pivot that no single operator call can express
# ---------------------------------------------------------------------------

_PROPORTIONAL_KEYS = ('use_proportional_edit', 'proportional_edit_falloff',
                      'proportional_size', 'use_proportional_connected')


def _falloff(name, dist):
    """calculatePropRatio's curves (transform_generics.cc), over
    dist = (size - d) / size. Random is random, as Blender's is: it seeds from
    the clock for every transform."""
    if name == 'SHARP':
        return dist * dist
    if name == 'SMOOTH':
        return min(1.0, 3.0 * dist * dist - 2.0 * dist * dist * dist)
    if name == 'ROOT':
        return math.sqrt(dist)
    if name == 'LINEAR':
        return dist
    if name == 'CONSTANT':
        return 1.0
    if name == 'SPHERE':
        return math.sqrt(max(0.0, 2.0 * dist - dist * dist))
    if name == 'RANDOM':
        import random
        return random.random() * dist
    if name == 'INVERSE_SQUARE':
        return dist * (2.0 - dist)
    return 1.0


def _in_reach(objects):
    """The unselected objects an object-mode proportional transform can move:
    visible, selectable, and neither a parent nor a child of anything
    selected (set_trans_object_base_flags; count_proportional_objects).
    Measured in 5.2.1: a light, a camera and an empty moved; a hidden cube
    and a cube with hide_select did not."""
    # The simulator's objects have no parents, no hide_select and no
    # visible_get; the defaults below are what those mean there.
    def parent_of(obj):
        return getattr(obj, 'parent', None)

    def visible(obj):
        if hasattr(obj, 'visible_get'):
            return obj.visible_get()
        return not getattr(obj, 'hide_viewport', False)

    chosen = set(objects)
    parents = set()
    for obj in objects:
        parent = parent_of(obj)
        while parent is not None:
            parents.add(parent)
            parent = parent_of(parent)

    def child_of_selection(obj):
        parent = parent_of(obj)
        while parent is not None:
            if parent in chosen:
                return True
            parent = parent_of(parent)
        return False

    out = []
    for obj in bpy.context.view_layer.objects:
        if obj in chosen or obj in parents or child_of_selection(obj):
            continue
        if getattr(obj, 'hide_select', False) or not visible(obj):
            continue
        out.append(obj)
    return out


def transform_individual(kind, **arguments):
    """INDIVIDUAL_ORIGINS: one operator per object, about that object's own
    origin.

    `center_override` is a single point, so a whole selection rotating in place
    cannot be one call. This is the same compromise, for the same reason, as
    `_blenderkit_anim.keyframe_insert`: one undo step, because `bridge.run`
    pushes one per call however many operators the body runs.

    Proportional editing cannot ride along on those calls: each one selects a
    single object, so the rest of the selection counts as unselected
    neighbours, and a neighbour is pulled once per call. Measured in 5.2.1
    with A (x = 0) and B (x = 3) selected, C at x = 1 and D at (1.5, 1), a 2x
    resize at LINEAR size 2: passing the arguments along moved C to x = 1.125
    at scale 1.875 and D to (1.474, 1.24) at 1.24. Desktop Blender, given a
    VIEW_3D area to read the pivot from (a context override), leaves both
    where they are at 1.5 and 1.099 — the selection turns in place at full
    strength and each neighbour in reach turns in place by its own share. That
    is what this does, and it measured 1.5 and 1.099; a turn goes the same way.
    """
    operator = {'ROTATE': bpy.ops.transform.rotate,
                'RESIZE': bpy.ops.transform.resize}.get(kind)
    if operator is None:
        raise ValueError("transform_individual takes 'ROTATE' or 'RESIZE', not %r" % (kind,))
    proportional = {key: arguments.pop(key) for key in _PROPORTIONAL_KEYS if key in arguments}
    objects = _selected_editable()
    if not objects:
        raise RuntimeError("Nothing selected to transform")

    shares = []
    if proportional.get('use_proportional_edit'):
        size = float(proportional.get('proportional_size', 1.0))
        falloff = proportional.get('proportional_edit_falloff', 'SMOOTH')
        origins = [obj.matrix_world.translation.copy() for obj in objects]
        for obj in _in_reach(objects):
            here = obj.matrix_world.translation
            d = min((here - o).length for o in origins)
            if size > 0 and d <= size:
                share = _falloff(falloff, max((size - d) / size, 0.0))
                if share > 0:
                    shares.append((obj, share))

    def scaled(share):
        """The arguments for a neighbour that gets `share` of the transform:
        the angle times it for a turn, 1 + (s - 1) times it for a scale
        (transform_mode_rotate.cc, ElementResize)."""
        out = dict(arguments)
        value = arguments.get('value', 0.0 if kind == 'ROTATE' else (1.0, 1.0, 1.0))
        if kind == 'ROTATE':
            out['value'] = float(value) * share
        else:
            out['value'] = tuple(1.0 + (float(v) - 1.0) * share for v in value)
        return out

    view_layer = bpy.context.view_layer
    active = view_layer.objects.active
    everyone = objects + [obj for obj, _ in shares]
    try:
        for obj in objects:
            for other in everyone:
                other.select_set(other is obj)
            view_layer.objects.active = obj
            operator(center_override=obj.matrix_world.translation[:], **arguments)
        for obj, share in shares:
            for other in everyone:
                other.select_set(other is obj)
            view_layer.objects.active = obj
            operator(center_override=obj.matrix_world.translation[:], **scaled(share))
    finally:
        # A failure part way through would otherwise leave one object selected
        # and the rest not, which is not what the gesture started with.
        for obj, _ in shares:
            obj.select_set(False)
        for obj in objects:
            obj.select_set(True)
        view_layer.objects.active = active
