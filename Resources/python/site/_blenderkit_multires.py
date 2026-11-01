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

# The vertex budget itself — the count, its model of every modifier and the one
# entry point every path prices through — is _blenderkit_budget.py (round 4's
# fix round). These names stay here for the modules and checks that call them.
import sys
import types

try:
    import _blenderkit_budget
except ImportError:
    # Loaded from its file, the site folder not on the path (the desktop checks).
    import importlib.util
    import os
    _spec = importlib.util.spec_from_file_location(
        '_blenderkit_budget', os.path.join(os.path.dirname(__file__), '_blenderkit_budget.py'))
    _blenderkit_budget = importlib.util.module_from_spec(_spec)
    sys.modules['_blenderkit_budget'] = _blenderkit_budget
    _spec.loader.exec_module(_blenderkit_budget)
from _blenderkit_budget import (GEOMETRY_TYPES, OCEAN_BYTES_PER_SAMPLE,  # noqa: F401,E402
                                available_memory, refuse_count, level_vertices, _subdivided, curve_counts,
                                base_counts, stack_vertices, skin_loops, refuse_slow_skin, ocean_samples,
                                refuse_ocean, check_move, _geometry_object, _skin_refusal)

# The budget's numbers live in one place. `_blenderkit_multires.BUDGET = n`,
# which the desktop checks use to reach a refusal on a small mesh, sets the
# budget's own.
_FORWARDED = ('BUDGET', 'PEAK_BYTES_PER_VERTEX', 'SKIN_MAX_LOOPS')


class _Module(types.ModuleType):
    def __getattr__(self, name):
        if name in _FORWARDED:
            return getattr(_blenderkit_budget, name)
        raise AttributeError(name)

    def __setattr__(self, name, value):
        if name in _FORWARDED:
            setattr(_blenderkit_budget, name, value)
            return
        super().__setattr__(name, value)


sys.modules[__name__].__class__ = _Module

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


def check_add(kind, obj=None, settings=None):
    """Refuses, in words, Add Modifier ▸ `kind` on an object whose result
    would pass the budget or the memory left, before anything is added — and
    Skin on more loops of edges than it finishes in reasonable time
    (`_blenderkit_budget.price_add`). `settings` are what the row sets in the
    same evaluation (Remesh's voxel floor)."""
    _blenderkit_budget.price_add(kind, obj, settings)


def refuse_subdivision_set(level=1, relative=False, ensure_modifier=True, **_):
    """Prices `object.subdivision_set` before it runs, for each object it
    would change, the way Blender's operator (bl_operators/object.py) decides:
    the active object in a paint or sculpt mode, else every selected editable
    object; on each, the first Multires or Subdivision Surface in the stack,
    or a new one (a Multires in Sculpt Mode, a Subdivision elsewhere).
    Absolute on a Multires, it calls Subdivide once per missing level, each
    evaluating the new top level. The operator search reaches it with a Level
    field from -100 to 100, and with the budget only on Multires Subdivide it
    went to 196 times the budget (round 3's review). Blender's operator adds a
    Subdivision Surface to a text, a curve or a surface as well, so those are
    priced too."""
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
        obj = _geometry_object(obj)
        if obj is None:
            continue
        sculpt = obj.mode == 'SCULPT'
        base = base_counts(obj)
        loops_now = skin_loops(obj, base=base)[0]
        target = next((m for m in obj.modifiers if m.type in ('MULTIRES', 'SUBSURF')), None)
        levels, add = None, None
        if target is not None and target.type == 'MULTIRES':
            if relative:
                new = (target.sculpt_levels if sculpt else target.levels) + level
                if new > target.total_levels:
                    continue  # Blender leaves it as it is
            else:
                new = max(level, target.total_levels)
            levels = {target.name: new}
            change = "Multires level %d" % new
        elif target is not None:
            new = target.levels + level if relative else level
            levels = {target.name: new}
            change = "Subdivision level %d" % new
        elif ensure_modifier:
            kind = 'MULTIRES' if sculpt else 'SUBSURF'
            add = (kind, level)
            change = ("Multires" if sculpt else "Subdivision") + " level %d" % level
        else:
            continue
        count = stack_vertices(obj, levels, add=add, sculpt=sculpt, base=base)
        refuse_count(obj, count, change, "Use a lower level, or start from a lighter mesh.")
        refuse_slow_skin(obj, change, levels, add=add, base=base, before=loops_now)


def check_setting(name, key, value, obj=None):
    """Refuses, in words, setting `key` of the modifier `name` to `value` when
    what Blender would then evaluate passes the budget
    (`_blenderkit_budget.price`). Any setting: the price no longer lists the
    ones that matter (round 4's review found the Bevel's Segments, the Mirror's
    axes and an Array's Fit Length off the list), it counts the stack again
    with the value in place. A render setting is priced as rendered, a hidden
    modifier's setting as if shown."""
    if not _is_real_blender():
        return
    obj = obj if obj is not None else bpy.context.object
    if obj is None:
        return
    modifier = obj.modifiers.get(name)
    if modifier is None:
        return
    _blenderkit_budget.price(modifier, key, value)


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
    refuse_count(obj, count, "Level %d" % level,
                 "Sculpt at level %d, or start from a lighter mesh." % total_levels,
                 " once the modifiers below it are counted" if count > alone else "")
    if existing is not None:
        refuse_slow_skin(obj, "Level %d" % level, {existing.name: level},
                         before=skin_loops(obj)[0])
    return count


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

    if op == 'subdivide' and obj.mode == 'SCULPT' and _is_real_blender():
        # From Sculpt Mode the new level is the sculpt level (Blender's
        # `multires_set_tot_level`), which Sculpt Mode then evaluates after
        # every stroke and Undo: held to the base mesh budget Sculpt Mode's
        # way in keeps (`_blenderkit_sculpt.refuse_heavy_level`).
        import _blenderkit_sculpt
        _blenderkit_sculpt.refuse_heavy_level(obj, modifier.total_levels + 1, what)
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
            try:
                bpy.ops.object.mode_set(mode=start)
            except RuntimeError as error:
                # Sculpt Mode's way back in refuses a level too heavy to
                # sculpt (`_blenderkit_context.refuse_sculpt_entry`): an
                # object opened in Sculpt Mode on one, whose Delete Higher
                # leaves it heavy still. What was done is kept, in Object
                # Mode, rather than reported as not done.
                print('[Blender Local] %s left %s in Object Mode: %s' % (what, obj.name, error))
