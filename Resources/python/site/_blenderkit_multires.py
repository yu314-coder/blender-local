"""Multiresolution's four operators — Subdivide, Unsubdivide, Delete Higher and
Apply Base — as the Modifiers panel's buttons run them, and the vertex budget
the Sculpt header's Subdivide shares.

Everything below was measured in desktop Blender 5.2.1 with the app's context
(an undo stack made by `ed.undo_push` under the startup window and screen, and
`gpu.init()`), unless it says otherwise.

  * Object Mode, and nothing else. All four operators pass their poll in Edit
    Mode and Sculpt Mode. In Edit Mode, Apply Base segfaults Blender in
    `multires_reshape_create_subdiv`. In Sculpt Mode, Apply Base pushes a
    sculpt undo step (`push_multires_mesh_begin`), and with no undo stack —
    after a file load, or under the checkpoint history — that segfaults in
    `sculpt_paint::undo::push_begin_ex`. In Object Mode all four run with or
    without an undo stack (scripts/run-modifier-blender-check.sh runs them in
    bare `-b`, which has none). So the object is taken to Object Mode first,
    and when Blender will not take it there — "Cannot edit hidden object" for
    an object in Sculpt Mode with Disable in Viewports on — nothing runs and
    the refusal says why. The mode guard every bare operator gets
    (BpyModeGuard.swift) used to swallow that failure, and the operator then
    ran in Sculpt Mode anyway.

  * Blender's own meaning in Sculpt Mode. Delete Higher and Apply Base work
    from the level Blender is showing, which in Sculpt Mode is the sculpt
    level and elsewhere the viewport level (`multires_get_level`); Subdivide
    raises the viewport level to the new top level except in Sculpt Mode
    (`multires_set_tot_level`). Run from Object Mode they would act on the
    viewport level and raise it: with viewport 1, sculpt 2 and total 3,
    Blender's Delete Higher from Sculpt Mode leaves total 2, the guarded call
    left total 1 and the sculpted level 2 was gone. So from Sculpt Mode the
    viewport level stands in for the sculpt level while the operator runs, and
    is put back after it.

  * A budget. Each Subdivide gives every face four, and Blender evaluates the
    new top level at once — in Object Mode it raises the viewport level to
    it, in Sculpt Mode the sculpt level. Peak memory on a 2 m cube, over the
    286 MB Blender starts at: level 8 is 393,218 vertices and 142 MB; level 9
    is 1,572,866 vertices, 557 MB and 0.98 s; level 10 is 6,291,458
    vertices, 1.65 GB and 3.4 s (2.55 GB with an undo step per press, as the
    app pushes one, round 3's review). Level 11 would be 25 million, past the
    mirror's 10,000,000-vertex limit (`_MAX_VERTS` in _blenderkit_sync.py)
    and an iPad's memory. A 32x16 UV sphere's level 6 is 2,031,618 vertices
    and 870 MB. The count is exact (`level_vertices`): it matched Blender's
    evaluated mesh at every level of a cube, a UV sphere and an open grid.

    In the app itself (Designed for iPad on an M-series Mac: Blender, the
    mirror and the Metal viewport), from a footprint of 478 MB with one cube:
    the cube's level 9 peaked at 1.45 GB resident and settled at a 908 MB
    footprint; the UV sphere's level 6 peaked at 2.05 GB and settled at
    1.32 GB. That is 560 and 730 bytes at the peak for each vertex of the new
    level.

    So a Subdivide is refused, before anything runs, when its new level
    would pass `BUDGET` vertices — the most this app subdivides to on any
    device — or would need more memory than the system says this process
    has left (`os_proc_available_memory`, as Image to 3D's Full 3D checks it),
    at `PEAK_BYTES_PER_VERTEX`. The second is what holds on a device with
    less memory than the one measured: an iPhone, or an older iPad.
"""

import re

import bpy

# The most vertices a Multires's top level may have, on any device: above a
# UV sphere's level 6 (2,031,618) and a cube's level 9 (1,572,866), below the
# cube's level 10 (6,291,458), and a quarter of the mirror's limit.
BUDGET = 2_500_000
# Memory a Subdivide needs at its peak, per vertex of the new level: the
# measured 560 to 730 (above), rounded up.
PEAK_BYTES_PER_VERTEX = 800

LABELS = {'subdivide': 'Subdivide', 'unsubdivide': 'Unsubdivide',
          'deleteHigher': 'Delete Higher', 'applyBase': 'Apply Base'}
_OPERATORS = {'subdivide': 'multires_subdivide', 'unsubdivide': 'multires_unsubdivide',
              'deleteHigher': 'multires_higher_levels_delete', 'applyBase': 'multires_base_apply'}
_MODE_NAMES = {'OBJECT': 'Object Mode', 'EDIT': 'Edit Mode', 'SCULPT': 'Sculpt Mode',
               'VERTEX_PAINT': 'Vertex Paint', 'WEIGHT_PAINT': 'Weight Paint',
               'TEXTURE_PAINT': 'Texture Paint'}


def _is_real_blender():
    # The simulator's stand-in has no RNA behind its operators.
    return hasattr(bpy.ops.object.mode_set, 'get_rna_type')


def _on_main_thread():
    try:
        from _blenderkit_context import _is_main_thread
    except ImportError:
        import threading
        return threading.current_thread() is threading.main_thread()
    return _is_main_thread()


def level_vertices(mesh, level):
    """The vertices a Multires at `level` evaluates to on `mesh`.

    Catmull-Clark, which Multires's grids follow: the first level puts a
    vertex on every face and edge and turns each face corner into a quad, and
    from then on each corner's quad grid doubles in each direction. With V, E,
    F and C the base mesh's vertices, edges, faces and corners, and
    s = 2**(level-1) - 1, that is C*s*s + (2E + C)*s + (V + E + F). Measured:
    exact against `to_mesh()` at levels 0 to 9 on a cube (8, 26, 98 … 1,572,866),
    0 to 6 on a 32x16 UV sphere (482, 1,986 … 2,031,618) and 0 to 7 on a
    10x10 grid, whose boundary is open (121, 441 … 1,640,961).
    """
    v, f, c = len(mesh.vertices), len(mesh.polygons), len(mesh.loops)
    edges = getattr(mesh, 'edges', None)
    e = len(edges) if edges is not None else c // 2
    if level <= 0:
        return v
    s = (1 << (level - 1)) - 1
    return c * s * s + (2 * e + c) * s + (v + e + f)


def _subdivided(counts, levels):
    """(vertices, edges, faces, corners) after `levels` Catmull-Clark levels.

    One level puts a vertex on every face and edge, splits each edge in two
    and adds one from each face's centre to each of its edges, and turns every
    corner into a quad. Iterated, this is `level_vertices` (the cube's 8, 26,
    98 … 1,572,866), and unlike it can be applied to a mesh a Multires has
    already subdivided, which is what a Subdivision Surface below one sees."""
    v, e, f, c = counts
    for _ in range(max(0, int(levels))):
        v, e, f, c = v + e + f, 2 * e + c, c, 4 * c
    return v, e, f, c


def _copies(modifier):
    """How many copies of the mesh `modifier` makes, at most: Mirror one per
    axis combination, Array its fixed count, Solidify an inner shell. 1 for
    every modifier that does not multiply the mesh, and for an Array fitted to
    a length or a curve, whose count is not known before it runs."""
    kind = modifier.type
    if kind == 'MIRROR':
        return 2 ** sum(1 for axis in modifier.use_axis if axis)
    if kind == 'ARRAY' and modifier.fit_type == 'FIXED_COUNT':
        return max(1, modifier.count)
    if kind == 'SOLIDIFY':
        return 2
    return 1


def stack_vertices(obj, levels=None, add=None, sculpt=None):
    """The vertices Blender's viewport evaluates `obj` to: its mesh, then each
    modifier shown in the viewport, in stack order.

    The Multires level counted is the one Blender shows (the sculpt level in
    Sculpt Mode, else the viewport level); a Subdivision Surface counts its
    viewport level. `levels` maps a modifier's name to a level to count in
    place of its own, which is how a change is priced before it is made, and
    counts that modifier even while it is hidden. `add` is (kind, level) for a
    Multires or Subdivision Surface not added yet: Blender puts a new Multires
    first and a new Subdivision last.

    Round 3's review measured why the Multires level alone is not enough: with
    the cube's default Subdivision at level 1 below a Multires, levels 1 to 7
    evaluated 98 to 393,218 vertices where the level alone counted 26 to
    98,306, four times fewer; at Subdivision level 2, sixteen."""
    levels = levels or {}
    if sculpt is None:
        sculpt = obj.mode == 'SCULPT'
    mesh = obj.data
    edges = getattr(mesh, 'edges', None)
    corners = len(mesh.loops)
    counts = (len(mesh.vertices), len(edges) if edges is not None else corners // 2,
              len(mesh.polygons), corners)
    if add is not None and add[0] == 'MULTIRES':
        counts = _subdivided(counts, add[1])
    for modifier in obj.modifiers:
        if modifier.name not in levels and not modifier.show_viewport:
            continue
        if modifier.type == 'MULTIRES':
            shown = modifier.sculpt_levels if sculpt else modifier.levels
            counts = _subdivided(counts, levels.get(modifier.name, shown))
        elif modifier.type == 'SUBSURF':
            counts = _subdivided(counts, levels.get(modifier.name, modifier.levels))
        else:
            copies = levels.get(modifier.name, _copies(modifier)) if modifier.type == 'ARRAY' \
                else _copies(modifier)
            counts = tuple(n * copies for n in counts)
    if add is not None and add[0] == 'SUBSURF':
        counts = _subdivided(counts, add[1])
    return counts[0]


def refuse_count(obj, count, change, instead, note=""):
    """Raises, in words, when `count` vertices would pass `BUDGET` or need
    more memory than this process has left. `change` says what would make
    them ("Level 4", "Subdivision level 5"), `instead` what to do, and `note`
    follows the count."""
    if count > BUDGET:
        raise RuntimeError(
            "%s would give %s %s vertices%s, and this app stops at %s so it does not run "
            "out of memory. %s" % (change, obj.name, format(count, ','), note, format(BUDGET, ','),
                                   instead))
    free = available_memory()
    need = count * PEAK_BYTES_PER_VERTEX
    if free is not None and need > free:
        raise RuntimeError(
            "%s would give %s %s vertices%s, which needs about %.1f GB of memory, and %.1f GB "
            "is free. Close other apps, or %s" % (change, obj.name, format(count, ','), note, need / 1e9,
                                                  free / 1e9, instead[0].lower() + instead[1:]))
    return count


def refuse_subdivision_set(level=1, relative=False, ensure_modifier=True, **_):
    """Prices `object.subdivision_set` before it runs, for each object it
    would change, the way Blender's operator (bl_operators/object.py) decides:
    the active object in a paint or sculpt mode, else every selected editable
    object; on each, the first Multires or Subdivision Surface in the stack,
    or a new one (a Multires in Sculpt Mode, a Subdivision elsewhere).
    Absolute on a Multires, it calls Subdivide once per missing level, each
    evaluating the new top level. The operator search reaches it with a Level
    field from -100 to 100, and with the budget only on Multires Subdivide it
    went to 196 times the budget (round 3's review)."""
    active = bpy.context.view_layer.objects.active
    if active is not None and active.mode in ('SCULPT', 'VERTEX_PAINT', 'WEIGHT_PAINT', 'TEXTURE_PAINT'):
        objects = [active]
    else:
        objects = list(getattr(bpy.context, 'selected_editable_objects', None) or [])
    if relative and level == 0:
        return
    if not relative and level < 0:
        level = 0
    for obj in objects:
        if obj.type != 'MESH':
            continue
        sculpt = obj.mode == 'SCULPT'
        target = next((m for m in obj.modifiers if m.type in ('MULTIRES', 'SUBSURF')), None)
        if target is not None and target.type == 'MULTIRES':
            if relative:
                new = (target.sculpt_levels if sculpt else target.levels) + level
                if new > target.total_levels:
                    continue  # Blender leaves it as it is
                count = stack_vertices(obj, {target.name: new}, sculpt=sculpt)
            else:
                count = stack_vertices(obj, {target.name: max(level, target.total_levels)}, sculpt=sculpt)
            change = "Multires level %d" % (new if relative else max(level, target.total_levels))
        elif target is not None:
            new = target.levels + level if relative else level
            count = stack_vertices(obj, {target.name: new}, sculpt=sculpt)
            change = "Subdivision level %d" % new
        elif ensure_modifier:
            kind = 'MULTIRES' if sculpt else 'SUBSURF'
            count = stack_vertices(obj, add=(kind, level), sculpt=sculpt)
            change = ("Multires" if sculpt else "Subdivision") + " level %d" % level
        else:
            continue
        refuse_count(obj, count, change, "Use a lower level, or start from a lighter mesh.")


# The modifier settings that multiply the mesh, which `check_setting` prices.
_LEVEL_KEYS = {'SUBSURF': ('levels', 'render_levels'),
               'MULTIRES': ('levels', 'sculpt_levels', 'render_levels'),
               'ARRAY': ('count',)}


def check_setting(name, key, value, obj=None):
    """Refuses, in words, a modifier setting whose mesh would pass the budget,
    before it is set: the Subdivision row's Levels stepper, which had no size
    check (round 3's review), and Every Property. Anything else passes.
    A render level is priced as if shown, which is what a render evaluates."""
    try:
        if not _is_real_blender():
            return
    except AttributeError:
        return  # a stand-in with no mode_set at all
    obj = obj if obj is not None else bpy.context.object
    if obj is None or obj.type != 'MESH':
        return
    modifier = obj.modifiers.get(name)
    if modifier is None or key not in _LEVEL_KEYS.get(modifier.type, ()):
        return
    value = int(value)
    if modifier.type == 'MULTIRES':
        value = min(value, modifier.total_levels)
    count = stack_vertices(obj, {name: value})
    what = {'SUBSURF': 'Subdivision', 'MULTIRES': 'Multires', 'ARRAY': 'Array'}[modifier.type]
    change = ("%s count %d" if key == 'count' else "%s level %d") % (what, value)
    refuse_count(obj, count, change, "Use a lower value, or start from a lighter mesh.")


def available_memory():
    """What this process may still allocate before the system ends it
    (`os_proc_available_memory`), or None where that cannot be read."""
    try:
        import ctypes
        function = ctypes.CDLL(None).os_proc_available_memory
    except (ImportError, OSError, AttributeError):
        return None
    function.restype = ctypes.c_size_t
    function.argtypes = []
    return function() or None


def refuse_over_budget(obj, total_levels, what):
    """Raises, in words, when one more level on `obj` would pass `BUDGET` or
    the memory left. Returns the new level's vertex count otherwise.

    `total_levels` is the Multires's own (0 for one not added yet); the mesh
    is read as Blender holds it, so in Edit Mode it must have been left first.
    The count is the whole stack's (`stack_vertices`): a Subdivision Surface
    below the Multires multiplies the new level again.
    `what` is unused in the sentence, which the banner shows after the
    operation's own name.
    """
    level = total_levels + 1
    alone = level_vertices(obj.data, level)
    existing = next((m for m in obj.modifiers if m.type == 'MULTIRES'), None)
    if existing is not None:
        # The new top level is what Blender evaluates after the press, in
        # either mode, and the modifiers below it see that level.
        count = stack_vertices(obj, {existing.name: level})
    else:
        count = stack_vertices(obj, add=('MULTIRES', level))
    count = max(count, alone)
    return refuse_count(obj, count, "Level %d" % level,
                        "Sculpt at level %d, or start from a lighter mesh." % total_levels,
                        " once the modifiers below it are counted" if count > alone else "")


def _leave_for_object_mode(obj, what):
    """Takes `obj` to Object Mode, or raises saying why Blender would not."""
    start = obj.mode
    if start == 'OBJECT':
        return start
    mode = _MODE_NAMES.get(start, start.replace('_', ' ').title())
    try:
        bpy.ops.object.mode_set(mode='OBJECT')
    except RuntimeError as error:
        # "Operator bpy.ops.object.mode_set.poll() Cannot edit hidden object"
        reason = re.sub(r'^(Error: )?Operator bpy\.ops\.\S+\.poll\(\)\s*', '', str(error))
        reason = reason.strip().rstrip('.') or 'its poll failed'
        raise RuntimeError("%s runs only in Object Mode, and Blender would not take %s out of "
                           "%s: %s." % (what, obj.name, mode, reason)) from None
    if obj.mode != 'OBJECT':
        raise RuntimeError("%s runs only in Object Mode, and Blender left %s in %s."
                           % (what, obj.name, mode))
    return start


def run(op, name):
    """Multires operator `op` (a key of `LABELS`) on the active object's
    modifier `name`, from whatever mode it is in, and back to that mode.
    Returns the modifier's total levels after it."""
    what = LABELS.get(op)
    if what is None:
        raise RuntimeError("Multiresolution has no operation %r" % (op,))
    if not _on_main_thread():
        raise RuntimeError(what + " changes modes, which Blender does on its main thread only.")
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH':
        raise RuntimeError(what + " works on a mesh, and the active object is not one.")
    modifier = obj.modifiers.get(name)
    if modifier is None or modifier.type != 'MULTIRES':
        raise RuntimeError("%s has no Multiresolution called %r." % (obj.name, name))
    operator = getattr(bpy.ops.object, _OPERATORS[op])
    arguments = dict(modifier=name)
    if op == 'subdivide':
        arguments['mode'] = 'CATMULL_CLARK'

    start = _leave_for_object_mode(obj, what)
    try:
        if not _is_real_blender():
            # The simulator's stand-in keeps the levels in Swift and draws at
            # most level 3 (ModifierStack), so it has no budget to keep and
            # no sculpt level to read; its operators raise what they cannot do.
            operator(**arguments)
            return None
        if op == 'subdivide':
            if not obj.data.polygons:
                # Measured: on a wire circle Blender answers FINISHED having
                # made no level.
                raise RuntimeError(obj.name + " has no faces for Multiresolution to subdivide.")
            refuse_over_budget(obj, modifier.total_levels, what)
        # From Sculpt Mode, what Blender's own operator would do there.
        # Unsubdivide is left alone: it sets the viewport and sculpt levels
        # to 0 in every mode.
        as_in_sculpt = start == 'SCULPT' and op in ('subdivide', 'deleteHigher', 'applyBase')
        viewport = modifier.levels
        if as_in_sculpt and op != 'subdivide':
            modifier.levels = modifier.sculpt_levels
        try:
            result = operator(**arguments)
        finally:
            if as_in_sculpt:
                # RNA keeps a level within the total. Blender's own Delete
                # Higher from Sculpt Mode can leave the viewport level above
                # it — measured: viewport 3, sculpt 2, total 3 becomes
                # viewport 3 over a total of 2, which draws level 3 in Object
                # Mode (386 vertices on a cube). A property set cannot do
                # that, so here it reads 2 and draws level 2 (98). Every
                # other case measured matched Blender's own.
                modifier.levels = min(viewport, modifier.total_levels)
        if 'FINISHED' not in result:
            raise RuntimeError("Blender did not %s %s." % (what.lower(), name))
        return modifier.total_levels
    finally:
        if start != 'OBJECT':
            bpy.ops.object.mode_set(mode=start)
