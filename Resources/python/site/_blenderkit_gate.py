"""The one gate every write goes through before Blender evaluates it
(round 4's fix round 2, October 21).

Every budget review of round 4 found the next bypass, because each repair
priced the paths a reviewer named: the Shape Keys panel's Value, the
Constraints tab, the Transform fields' constrained preview, Object Mode's
Shear and Parent, `transform.transform` from the search. The paths differ;
what they share is that a property is written and Blender then evaluates
the scene. A property write does not evaluate anything by itself: Blender
tags what it changed and evaluates when something asks for the evaluated
depsgraph — the mirror after a run (`_blenderkit_sync.sync`), an operator
called from Python (`bpy_op_fn_call` updates the view layer before and after
every call, bpy_operator_function.cc), a script's own
`evaluated_depsgraph_get`, `view_layer.update` or `frame_set`.

So the price sits there, once, and prices the state, not the path:

  * What changed is what Blender will evaluate again. Before an evaluation
    the depsgraph lists every data-block tagged since the last one
    (`view_layer.depsgraph.updates`: measured in desktop 5.2.1, a location
    written lists its object, a shape key's Value lists the Key, a curve's
    Bevel Depth its curve), and its evaluated copy of each still holds the
    values Blender evaluated last (the copy-on-write copy is replaced only by
    the evaluation: a location written 1 → 0.5 read 1.0 there, an Array's Fit
    Length 40 → 41 read 40, a pose bone's scale 1 → 3 read 1, a vertex moved
    read where it was). The fingerprint of an object (`_diff`) is every
    writable setting of it, its modifiers, constraints, particle systems and
    pose bones, of its data — a curve's, a text's, a metaball's elements, a
    lattice's points, a mesh's vertices outside Edit and Sculpt Mode — and of
    its shape keys, read from the original and from that copy. At rest the
    two agree (measured over all 55 modifier types and 31 constraint types on
    one cube, nested settings two deep) except for the four runtime values a
    simulation writes into its copy (`_RUNTIME`).
  * What it reaches is what the one model counts (`_blenderkit_budget`):
    every object that uses changed data and every object that reads one of
    those, through parents, constraint targets, modifier pointers, curve
    bevels and shape keys.
  * The changed values are put back as Blender last evaluated them, the
    change is priced laid over them (`price_state`, the judgement every other
    price uses), and only when it passes are the new values written again.
    So nothing the price evaluates for its own measures can be the change
    itself. A change refused stays put back, and the refusal is said in
    words.
  * What cannot be put back by writing a value — an object linked by a
    script, a mesh or a curve given more elements, a metaball given more
    elements — is priced as it is, with the modifiers of what it reaches
    hidden while the price is made, so the price's own evaluations stay
    within what was there; refused, those modifiers stay hidden (or, when
    the object alone is past the budget, it is taken out of the scene), and
    the words say so.

Where it runs: before every operator `bpy.ops` hands out (the wrappers of
`_blenderkit_context`, which refuse in words before the operator runs), at
the start of every mirroring pass (`_blenderkit_sync.sync`), and — for every
other way an evaluation is asked for, a script's own `evaluated_depsgraph_get`
among them — in `depsgraph_update_pre` and `frame_change_pre`, where nothing
can be raised: there the change is put back and the refusal is kept for the
mirror to report. The same handler, during an operator's own update after
its run, prices what the operator changed before Blender evaluates it
(`_RESULT`): Shear, Parent, `transform.transform`, the constraint operators
and the rest of the operators that only set values are held there without
a list of them.

Round 4's fix round 2 review (October 21) measured seventeen ways past this,
and each is closed here or in the budget's model:
  * a script's handlers (a checkpoint after each, `_guard_handlers`; the
    gate's own put back wherever it runs, `install`; a script's handlers out
    of the lists while the gate prices, `_Busy`; a load's and an undo's
    handlers priced against a fingerprint, `_price_since_load`);
  * the evaluations a script asks for, of any view layer, a fresh one
    priced whole (`before_evaluation`, `_fresh`), and what Blender evaluates
    as a dependency outside every view layer (`_dependencies`);
  * animation: the frame (`_frame_pre`, the Scene's frame in `_diff`),
    drivers, an action's keys, an NLA, and drivers reading a change
    (`_animation`, `_blenderkit_budget.animation_pairs`, Blender's own
    evaluation with the counts hidden where only it can say,
    `probe_values`);
  * what the fingerprint did not hold: collection items (`_diff_owned_items`),
    a mesh's attributes (`_diff_attributes`), node groups and a Geometry
    Nodes modifier's inputs (`_diff_tree`, `_diff_node_inputs`), a Grease
    Pencil's drawings (`_gp_shape`), the paint modes' and Sculpt Mode's
    vertices (`_held`), bulk writes inside an operator (`_diff_bulk`),
    Proportional Editing's other objects (`_proportional`);
  * `wm.append` and `wm.link` priced (not `_LOADS`), and a text's Edit Mode
    held as a transaction (`_FontGuard`).

Fix round 3 (October 29) closed what a script line still reached: what a
refusal leaves is priced too (`_blenderkit_budget._left_over`); a scene's
Background Scene and Rigid Body World (`_diff_scene_pointer`,
`_scene_reads`); hair curves; custom-property arrays of any length; images a
modifier reads (`_images_touched`); a file a script loads
(`_price_script_load`, the app's own loads marked by `opening`); a script's
handlers known by identity and checked at their own return (`_gate_own`,
`_monitor`); and an evaluation made with the gate's handler taken out of its
list, held right after (`_unpriced`).
"""

import math
import sys
import threading as _threading
import types as _types

import bpy

# Settings a simulation writes into its evaluated copy, which the original
# never holds (measured at rest, desktop 5.2.1: a Soft Body's estimates read
# (0, 0, 0) and the identity in the original, the mass centre and the
# estimated matrices in the copy), and what Blender's copy marks as its own.
_RUNTIME = frozenset(('location_mass_center', 'rotation_estimate', 'scale_estimate', 'is_runtime_data'))
# What a struct's own panel shows rather than what is evaluated, and the
# values Blender derives from others (an object's matrices from its channels,
# its Dimensions from its scale and mesh), which follow from what is read.
# Not `color`: a texture's colour ramp stops are colours a Displace reads
# (fix round 3's review, October 29, sandboxed desktop 5.2.1: a cube under a
# Displace along its normals reading a Blend texture at Contrast 0 through a
# colour ramp held at grey 0.5, then an Array fitted to 40; a script line
# setting both stops to grey 0.25 built 168 -> 3,199,472 with no refusal,
# `_props(ColorRampElement)` having left the colour out), and a driver can
# read any colour.
_NEVER = frozenset(('rna_type', 'name', 'name_full', 'show_expanded', 'is_active', 'is_override_data',
                    'execution_time', 'persistent_uid', 'active', 'is_valid', 'error_location',
                    'error_rotation', 'matrix_world', 'matrix_local', 'matrix_basis', 'dimensions',
                    'select', 'select_head', 'select_tail', 'select_control_point', 'select_left_handle',
                    'select_right_handle', 'hide_select', 'show_in_front', 'show_name', 'show_axis',
                    'show_wire', 'show_bounds', 'show_texture_space', 'show_transparent',
                    'active_material_index', 'active_material', 'show_viewport_expanded',
                    'is_override_data_editable', 'use_apply_on_spline', 'show_only_shape_key_expanded',
                    'lock_shape', 'ui_expand_flag',
                    # A tool's own mark on a data-block (`ID.tag`): Transform sets it on
                    # what it moves, measured, and it is never evaluated.
                    'tag')) | _RUNTIME
# The order a struct's settings are written in, put back or set again:
# Blender converts the rotation it finds when the mode is set, and a Hook's
# object setter resets its inverse, so the mode goes first and the Hook's own
# matrix after its object.
_AFTER_POINTERS = frozenset(('matrix_inverse', 'center'))
# A scene's Time Stretching (see `_diff`): the time its animation is
# evaluated at, as much as its frame is.
_TIME_STRETCH = ('frame_map_old', 'frame_map_new')

# Edit Mode, Sculpt Mode and the paint modes hold a mesh apart from its data
# (an edit mesh, a sculpt session): its elements are changed by operators,
# priced as they are called, never by a write.
_HELD_MODES = frozenset(('EDIT', 'SCULPT', 'VERTEX_PAINT', 'WEIGHT_PAINT', 'TEXTURE_PAINT'))
# Operators whose own run re-reads the whole scene from somewhere else — a
# file, an undo step, the history — and whose update afterwards is therefore
# not a change to price: what they load is what Blender held before.
_LOADS = frozenset(('ed.undo', 'ed.redo', 'ed.undo_history', 'ed.undo_redo', 'wm.open_mainfile',
                    'wm.revert_mainfile', 'wm.read_homefile', 'wm.read_factory_settings',
                    'wm.recover_last_session', 'wm.recover_auto_save', 'screen.redo_last'))
# Not `wm.append` or `wm.link`: they bring in what was never priced. Round 4's
# fix round 2 review, desktop 5.2.1: a script wrote an object it never
# linked, under an Array of 400,000, to a .blend with
# `bpy.data.libraries.write`, then `wm.append` brought it in at 3,200,000
# with no refusal, where linking the same object directly is refused. Their
# update is priced as any other: what they link is new (`pending`).

_busy = 0              # inside the gate: its own evaluations pass
_calls = []            # operator paths being called through bpy.ops, innermost last
_refusals = []         # refusals kept where nothing could be raised: (operator path or None, words)
_approved = {}         # (pointer, key) -> value priced and passed, not evaluated yet
_accepted = None       # what no value puts back, as last priced and passed (`_signature`)
_props_cache = {}
_installed = False
_object_count = -1
# What Blender last evaluated of the curves and lattices in Edit Mode, by the
# data's pointer (`_EditSnap`): their evaluated copies share the edit points
# with the originals, so there is no copy to compare with (see `_diff_edit`).
_edit_snaps = {}


def _real():
    try:
        return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type') and hasattr(bpy.types, 'Depsgraph')
    except AttributeError:
        return False


def _object_mode():
    try:
        return bpy.context.mode == 'OBJECT'
    except AttributeError:
        return False


def _budget():
    module = sys.modules.get('_blenderkit_budget')
    if module is not None:
        return module
    try:
        import _blenderkit_budget as module
        return module
    except ImportError:
        import importlib.util
        import os
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_blenderkit_budget.py')
        spec = importlib.util.spec_from_file_location('_blenderkit_budget', path)
        module = importlib.util.module_from_spec(spec)
        sys.modules['_blenderkit_budget'] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop('_blenderkit_budget', None)
            raise
        return module


def _depsgraph():
    try:
        layer = bpy.context.view_layer
    except AttributeError:
        return None
    return layer.depsgraph if layer is not None else None


# --------------------------------------------------------------------------
# The originals behind the depsgraph's copies

# The data-block types a change can reach a count through, by the RNA name of
# the evaluated copy, and where their originals are.
_COLLECTIONS = {'Object': 'objects', 'Mesh': 'meshes', 'Curve': 'curves', 'TextCurve': 'curves',
                'SurfaceCurve': 'curves', 'MetaBall': 'metaballs', 'Key': 'shape_keys',
                'Lattice': 'lattices', 'ParticleSettings': 'particles', 'Scene': 'scenes',
                'Armature': 'armatures', 'Collection': 'collections', 'Action': 'actions',
                'GeometryNodeTree': 'node_groups', 'GreasePencil': 'grease_pencils',
                # Hair curves (fix round 3, October 29): see `_diff`.
                'Curves': 'hair_curves'}


def _texture_kinds():
    """Every legacy Texture type's RNA name (`BlendTexture`, `CloudsTexture`,
    ...), each a data-block of `bpy.data.textures`. Fix round 3 (October 29):
    a texture was compared nowhere, and the Displace, Warp and Wave modifiers
    and the Vertex Weight modifiers' masks read one. Measured in sandboxed
    desktop 5.2.1 with the app's context, a cube under a Displace (Blend
    texture, Strength 20) and a Remesh at 0.5, budget 20,000: the texture's
    Brightness 1 → 2 passed through the Data API row, a script line and a
    key at frame 10, and Blender built 20,692 vertices from 1,564 each time."""
    base = getattr(getattr(bpy, 'types', None), 'Texture', None)
    if base is None:
        return {}
    found = {}
    for name in dir(bpy.types):
        kind = getattr(bpy.types, name, None)
        try:
            if isinstance(kind, type) and issubclass(kind, base):
                found[name] = 'textures'
        except TypeError:
            continue
    return found


_COLLECTIONS.update(_texture_kinds())


def _address(block, dg):
    """Where the depsgraph keeps `block`'s evaluated copy (its own address
    when it has none yet)."""
    try:
        return block.evaluated_get(dg).as_pointer()
    except (AttributeError, ReferenceError, RuntimeError):
        return block.as_pointer()


def _original(copy, dg):
    """The original whose evaluated copy is `copy`, found by name and the
    copy's address, or None when it no longer exists. Never `copy.original`:
    measured in desktop 5.2.1, removing a curve's data removes its object
    too, and the next update list still holds that object's copy, whose
    `original` is freed memory (`_blenderkit_anim.frame_set` measured the
    same pointer segfaulting Blender)."""
    name = _COLLECTIONS.get(type(copy).__name__)
    collection = getattr(bpy.data, name, None) if name else None
    if collection is None:
        return None
    try:
        address, key = copy.as_pointer(), copy.name
    except (AttributeError, ReferenceError):
        return None
    candidate = collection.get(key)
    if candidate is not None and _address(candidate, dg) == address:
        return candidate
    for candidate in collection:       # renamed since Blender last evaluated it
        if _address(candidate, dg) == address:
            return candidate
    return None


# --------------------------------------------------------------------------
# What of Blender's copies the gate may read (fix round 3, October 29)
#
# The gate runs in depsgraph_update_pre, before Blender brings its copies up
# to date, and two kinds of memory a copy points at can be freed by then.
# Fix round 2's final check measured the first of them crashing Blender in
# ordinary use: a 61 x 61 grid under a one-node Geometry Nodes group, Edit Mode,
# Select All, Extrude, leaving Edit Mode — exit 139 on the first leave under
# MallocScribble, in rna_AttributeGroup_iterator_begin under `_diff_attributes`
# (tests/budget/blender/freed.py, which crashed 12 of its 25 cases on
# 6d31b90's code, the first of them that one).
#
#  * Edit Mode data. deg_update_eval_copy_datablock (deg_eval_copy_on_write.cc)
#    does not copy a mesh, curve, lattice, metaball or armature again while it
#    is in Edit Mode: it points the copy at the original's edit data
#    (`update_edit_mode_pointers`: `mesh_cow->runtime->edit_mesh =
#    mesh_orig->runtime->edit_mesh`, the curve's `editnurb` and `editfont`, the
#    lattice's `editlatt`, the armature's `edbo`). Leaving Edit Mode frees that
#    data (a mesh's BMesh, `BKE_editmesh_free_data`), and the copy points at it
#    until the evaluation after depsgraph_update_pre copies it again. RNA reads
#    through those pointers: a mesh's `attributes` (rna_attribute.cc reads
#    `edit_mesh->bm` whenever it is set), a curve's `splines`
#    (`BKE_curve_nurbs_get`), a lattice's `points`, an armature's `edit_bones`.
#    `is_editmode` reads only whether the pointer is set (rna_mesh.cc,
#    rna_curve.cc, rna_lattice.cc, rna_armature.cc), and so do the lengths of
#    a mesh's elements (`verts_num`...). So a copy whose `is_editmode` is set
#    is read for nothing else (`_holds_edit_data`), whatever its original's
#    mode: what Blender evaluated last of its elements is then what the gate
#    kept (`_edit_mesh_states` for a mesh, `_edit_snaps` for the rest).
#  * Data-blocks Blender does not copy (`ID_TYPE_USE_COPY_ON_EVAL`, DNA_ID.h:
#    images, fonts, brushes, palettes, screens, workspaces, window managers,
#    libraries, paint curves). A copy points at the original itself, and
#    removing it remaps the originals' pointers only (lib_remap.cc walks Main).
#    Measured on 6d31b90's code: an image removed from an image empty, a
#    custom property and a driver, and a text's font removed, each segfaulted
#    the gate's next read of the copy (pyrna_prop_to_py under `_diff_struct`).
#    Freeing one tags its type on every depsgraph (`DEG_id_type_tag` in
#    lib_id_delete.cc's `id_free`) until that depsgraph evaluates, and the
#    remap tags each user for a copy again then. So such a pointer of a copy is
#    read only while `Depsgraph.id_type_updated` says no data-block of its kind
#    changed since that depsgraph last evaluated (`_pointer_readable`); while
#    one did, the setting counts as changed, with nothing to put back, and is
#    priced as it is.
#  * A copy's `original` is never read: it is freed memory once the original
#    is removed (an action removed while assigned, measured: `.original` of
#    the copy's action came back as an 'ID' at the freed address).

# RNA struct name -> the id_type `Depsgraph.id_type_updated` takes, for each
# kind Blender's copies point at uncopied.
_UNCOPIED = {'Image': 'IMAGE', 'VectorFont': 'FONT', 'Brush': 'BRUSH', 'Palette': 'PALETTE', 'Screen': 'SCREEN',
             'WindowManager': 'WINDOWMANAGER', 'WorkSpace': 'WORKSPACE', 'Library': 'LIBRARY',
             'PaintCurve': 'PAINTCURVE'}
_UNCOPIED_TYPES = frozenset(_UNCOPIED.values())
# (RNA type key, identifier) -> the id_type of an ID pointer setting whose
# fixed type is uncopied, or 'ANY' for one typed only as an ID (`_props`).
_uncopied_props = {}
# The depsgraph `pending` is reading and what it said of each kind.
_freed_seen = [None, {}]


def _holds_edit_data(copy):
    """Whether Blender's copy points at its original's Edit Mode data (see
    the note above): read from the pointer alone."""
    try:
        return bool(getattr(copy, 'is_editmode', False))
    except (AttributeError, ReferenceError, RuntimeError):
        return True


def _freed(dg, id_type):
    """Whether a data-block of `id_type` may have been freed since `dg` last
    evaluated (see the note above). True where that cannot be asked."""
    if dg is None:
        return True
    seen = _freed_seen[1] if _freed_seen[0] is dg else None
    if seen is None:
        _freed_seen[0], _freed_seen[1] = dg, {}
        seen = _freed_seen[1]
    found = seen.get(id_type)
    if found is None:
        try:
            found = bool(dg.id_type_updated(id_type))
        except (AttributeError, TypeError, ReferenceError, RuntimeError):
            found = True
        seen[id_type] = found
    return found


def _updates(dg):
    """(copy, update) for each data-block `dg` lists as changed. A data-block
    Blender does not copy keeps its node in `dg`, its own address as its
    "copy", until Blender rebuilds the depsgraph — after
    depsgraph_update_pre — so once one is freed `dg.updates` still lists it,
    and `update.id` wraps the freed memory: measured with the rest of this
    round's repairs in, an image removed by a script line exited 139 there
    (pyrna_prop_to_py under `pending`, tests/budget/blender/freed.py's
    image_removed). While one may be freed (`_freed`), the addresses listed
    are matched against the copies of the live originals the gate reads
    (`update.as_pointer()` is the listed address, read without touching what
    is there; 2.8 to 3.8 ms for 6,006 data-blocks in desktop 5.2.1), and
    only those are wrapped. Blender's own iterator still reads the freed
    block's update flags as it goes (`DEG_iterator_ids_step`), four bytes
    the gate cannot keep it from reading."""
    if not any(_freed(dg, t) for t in _UNCOPIED_TYPES):
        for update in dg.updates:
            yield update.id, update
        return
    known = {}
    for name in set(_COLLECTIONS.values()):
        for orig in getattr(bpy.data, name, ()):
            try:
                known[_address(orig, dg)] = orig
            except (AttributeError, ReferenceError, RuntimeError):
                continue
    for update in dg.updates:
        orig = known.get(update.as_pointer())
        if orig is None:
            continue
        try:
            copy = orig.evaluated_get(dg)
        except (AttributeError, ReferenceError, RuntimeError):
            continue
        if copy.as_pointer() == update.as_pointer():
            yield copy, update


def _pointer_readable(orig, ident, dg):
    """Whether the ID pointer setting `ident` of `orig`'s copy may be read
    (see the note above): always where its type is one Blender copies (the
    copy then points at a copy, alive until the depsgraph's next rebuild,
    which comes after depsgraph_update_pre)."""
    rna = orig.bl_rna
    kind = _uncopied_props.get((rna.identifier, rna.as_pointer(), ident))
    if kind is None:
        return True
    if kind == 'ANY':
        if ident == 'data' and isinstance(orig, bpy.types.Object):
            # An object's data is of its own type (a mesh, a curve...),
            # copied, except an empty's image.
            return orig.type != 'EMPTY' or not _freed(dg, 'IMAGE')
        return not any(_freed(dg, t) for t in _UNCOPIED_TYPES)
    return not _freed(dg, kind)


# --------------------------------------------------------------------------
# The fingerprint: every writable setting, the original's and the copy's


class Change:
    """One setting that differs from what Blender evaluated last: `owner`
    (the original struct) and `key`, the value Blender evaluated (`old`) and
    the one written since (`new`). `bulk` is a numpy array set with
    `foreach_set` (a mesh's vertices, a key's points, a curve's points)."""
    __slots__ = ('owner', 'key', 'old', 'new', 'rank', 'bulk', 'block', 'path', 'pointer', 'derived')

    def __init__(self, owner, key, old, new, rank=4, bulk=None):
        self.owner, self.key, self.old, self.new, self.rank, self.bulk = owner, key, old, new, rank, bulk
        # A setting Blender works out itself (`_derived`): put back with the
        # rest, never priced (`Pending.derived`).
        self.derived = False
        # Where the owner is, read while it is alive: a write can free a
        # struct another change is on (see `_live`).
        self.block = self.path = None
        self.pointer = 0
        if not isinstance(owner, bpy.types.ID):
            try:
                self.block, self.path, self.pointer = owner.id_data, owner.path_from_id(), owner.as_pointer()
            except (AttributeError, ValueError, TypeError, RuntimeError, ReferenceError):
                pass

    def __repr__(self):
        return "Change(%r, %r, %r -> %r)" % (getattr(self.owner, 'name', self.owner), self.key, self.old, self.new)


class Struct:
    """What a write did that no value can put back: a modifier or constraint
    added or removed, the modifiers' order, an object new to the scene, a
    mesh, curve or metaball given other elements."""
    __slots__ = ('kind', 'obj', 'item', 'data', 'note', 'state')

    def __init__(self, kind, obj=None, item=None, data=None, note="", state=None):
        self.kind, self.obj, self.item, self.data, self.note = kind, obj, item, data, note
        self.state = state

    def __repr__(self):
        return "Struct(%s, %s, %s)" % (self.kind, getattr(self.obj, 'name', None), getattr(self.item, 'name', None))


def _props(struct):
    """(identifier, type, flags) of `struct`'s settings worth comparing, by
    its RNA type, once."""
    rna = struct.bl_rna
    # By the type itself: a Geometry Nodes modifier's inputs are types made
    # per group, all named after the socket (`Socket_1`), an Int in one group
    # and an Object in another.
    key = (rna.identifier, rna.as_pointer())
    found = _props_cache.get(key)
    if found is not None:
        return found
    found = []
    for p in rna.properties:
        ident = p.identifier
        if ident in _NEVER:
            continue
        if p.type == 'COLLECTION':
            # Items a struct holds of its own, compared item by item where they
            # are few and not compared elsewhere (`_ITEMS`): a constraint's
            # targets, a particle system's settings' weights. Round 4's fix
            # round 2 review, desktop 5.2.1: O, the offset of A's Array fitted
            # to 40, under an Armature constraint whose bone is posed −0.9999
            # at target weight 0; `O.constraints[0].targets[0].weight = 1.0`
            # took A from 328 to 3,199,472 with no refusal, from a script
            # line and from the Data API row.
            fixed = p.fixed_type
            if fixed is not None and not issubclass(getattr(bpy.types, fixed.identifier, object), bpy.types.ID) \
                    and (rna.identifier, ident) not in _NOT_ITEMS and not isinstance(struct, bpy.types.Object):
                found.append((ident, 'COLLECTION', 4))
            continue
        if ident == 'mute' and rna.properties.get('enabled') is not None:
            # A constraint's Mute is its Enabled inverted (the same flag:
            # turned off, it reads mute True), so Enabled says it. Only
            # there: a shape key's Mute is a setting of its own, and once
            # this skipped every `mute`, unmuting a key at Value 1 under an
            # Array fitted to 3 passed the gate and Blender built 6,000,000
            # vertices (desktop 5.2.1).
            continue
        if p.type == 'POINTER':
            fixed = p.fixed_type
            is_id = fixed is not None and fixed.identifier != 'ID' and issubclass(
                getattr(bpy.types, fixed.identifier, object), bpy.types.ID) or (
                fixed is not None and fixed.identifier == 'ID')
            if is_id:
                if p.is_readonly:
                    continue
                if fixed.identifier == 'ID':
                    _uncopied_props[(rna.identifier, rna.as_pointer(), ident)] = 'ANY'
                elif fixed.identifier in _UNCOPIED:
                    _uncopied_props[(rna.identifier, rna.as_pointer(), ident)] = _UNCOPIED[fixed.identifier]
                found.append((ident, 'ID', 1))
            else:
                found.append((ident, 'STRUCT', 0))
            continue
        if p.is_readonly:
            continue
        matrix = p.type in ('FLOAT', 'INT', 'BOOLEAN') and getattr(p, 'is_array', False) and \
            len(tuple(getattr(p, 'array_dimensions', (0, 0, 0)))) > 1 and p.array_dimensions[1] > 0
        rank = 0 if ident == 'rotation_mode' else (2 if p.type == 'STRING' else (3 if p.type == 'ENUM' else 4))
        if ident in _AFTER_POINTERS:
            rank = 5
        found.append((ident, 'MATRIX' if matrix else p.type + ('_SET' if p.type == 'ENUM' and p.is_enum_flag else ''),
                      rank))
    _props_cache[key] = found
    return found


def _value(v, kind):
    if kind == 'MATRIX':
        return tuple(x for row in v for x in row)
    if kind == 'ENUM_SET':
        return frozenset(v)
    if kind in ('FLOAT', 'INT', 'BOOLEAN') and hasattr(v, '__len__'):
        return tuple(v)
    return v


_owned_cache = {}


def _owned(orig, ident, value):
    """Whether `orig.ident` is a struct `orig` holds (a Fluid modifier's
    domain settings, an object's soft body) rather than one it points at
    elsewhere (its active shape key, which is the Key's): only the first is
    compared. Measured: compared as its own, an object's active shape key
    read the copy's active key against the original's — Thin's Value
    against Basis's — whenever the active key had just changed."""
    key = (orig.bl_rna.identifier, orig.bl_rna.as_pointer(), ident)
    known = _owned_cache.get(key)
    if known is not None:
        return known
    try:
        if value.id_data != orig.id_data:
            found = False
        else:
            base = '' if isinstance(orig, bpy.types.ID) else orig.path_from_id()
            found = value.path_from_id() == (base + '.' if base else '') + ident
    except (ValueError, AttributeError, TypeError, RuntimeError):
        found = False
    _owned_cache[key] = found
    return found


# Collections compared elsewhere, or that hold nothing a count reads.
_NOT_ITEMS = frozenset((('AnimData', 'drivers'), ('AnimData', 'nla_tracks'), ('Mesh', 'vertices'),
                        ('Mesh', 'edges'), ('Mesh', 'polygons'), ('Mesh', 'loops'), ('Mesh', 'attributes'),
                        ('Key', 'key_blocks'), ('ShapeKey', 'data'), ('ShapeKey', 'points'),
                        ('Curve', 'splines'), ('TextCurve', 'splines'), ('SurfaceCurve', 'splines'),
                        ('Spline', 'points'), ('Spline', 'bezier_points'), ('MetaBall', 'elements'),
                        ('Lattice', 'points'), ('Pose', 'bones'), ('PoseBone', 'constraints'),
                        ('FCurve', 'keyframe_points'), ('FCurve', 'sampled_points'), ('FCurve', 'modifiers'),
                        ('Scene', 'view_layers'), ('Scene', 'objects'), ('Scene', 'timeline_markers'),
                        ('Scene', 'keying_sets'), ('Scene', 'keying_sets_all')))
_ITEMS_MOST = 256


def _diff_owned_items(orig, ident, a, b, dg, out, structs, depth):
    """A collection `orig` holds of its own (see `_props`), item by item
    against Blender's copy: each item's settings set back by value; items
    added or removed are what no value puts back, held with what owns them
    (`_judge`: a constraint turned off, a modifier hidden)."""
    try:
        n, m = len(a), len(b)
    except (TypeError, AttributeError, ReferenceError):
        return
    if n > _ITEMS_MOST or m > _ITEMS_MOST:
        return
    owner = orig
    if n != m:
        obj = orig.id_data if isinstance(orig.id_data, bpy.types.Object) else None
        structs.append(Struct('items', obj, owner, None, "its %s" % ident))
        return
    for x, y in zip(a, b):
        if hasattr(x, 'bl_rna'):
            _diff_struct(x, y, dg, out, depth + 1, structs)


def _diff_struct(orig, copy, dg, out, depth=0, structs=None):
    """Every writable setting of `orig` that differs from `copy`, Blender's
    evaluated copy of it, into `out` — and of the structs it owns, two
    deep."""
    editing = isinstance(orig, bpy.types.Object) and getattr(orig, 'mode', 'OBJECT') == 'EDIT'
    for ident, kind, rank in _props(orig):
        if editing and ident == 'data':
            # In Edit Mode Blender keeps an object's data whatever is written
            # (measured in desktop 5.2.1: `obj.data = other` left it), and the
            # copy's data, read in the update before Blender evaluates, is
            # built out of its edit mesh first: 144 ms of a Move on a
            # 90,601-vertex grid under a Subdivision and an Array, the gate's
            # whole cost of that Move. Not read then.
            continue
        if kind == 'ID' and ident == 'data' and isinstance(orig, bpy.types.Object) and orig.type == 'EMPTY':
            # An empty's data is an image, which makes no vertex, and which
            # Blender's copy points at uncopied (see `_pointer_readable`).
            continue
        if kind == 'ID' and not _pointer_readable(orig, ident, dg):
            # The copy may point at freed memory (see the note above
            # `_UNCOPIED`): counted as changed, with nothing to put back.
            try:
                a = getattr(orig, ident)
            except (AttributeError, RuntimeError, ReferenceError, TypeError):
                continue
            out.append(Change(orig, ident, Struct('gone'), a, 1))
            continue
        try:
            a = getattr(orig, ident)
            b = getattr(copy, ident)
        except (AttributeError, RuntimeError, ReferenceError, TypeError):
            continue
        if kind == 'STRUCT':
            if depth < 2 and a is not None and b is not None and hasattr(a, 'bl_rna') and _owned(orig, ident, a):
                _diff_struct(a, b, dg, out, depth + 1, structs)
            continue
        if kind == 'COLLECTION':
            if depth < 2 and structs is not None:
                _diff_owned_items(orig, ident, a, b, dg, out, structs, depth)
            continue
        if kind == 'ID' and ident == 'data' and isinstance(orig, bpy.types.Object):
            # An evaluated object's data is what its modifiers made, not the
            # copy of its own (measured: a cube under an Array, and one with
            # no modifiers, whose evaluated data is not a copy at all); the
            # name is its own's, which is what is compared.
            now = (type(a).__name__, a.name) if a is not None else None
            then = (type(b).__name__, b.name) if b is not None else None
            if now != then:
                collection = getattr(bpy.data, _COLLECTIONS.get(then[0], ''), None) if then else None
                old = collection.get(then[1]) if collection is not None else None
                out.append(Change(orig, ident, old if (old is not None or then is None) else Struct('gone'), a, 1))
            continue
        if kind == 'ID':
            now = _address(a, dg) if a is not None else 0
            then = b.as_pointer() if b is not None else 0
            if now != then:
                old = _original(b, dg) if b is not None else None
                if b is not None and old is None:
                    # What it pointed at is gone: nothing to put back.
                    old = Struct('gone')
                out.append(Change(orig, ident, old, a, 1))
            continue
        try:
            va, vb = _value(a, kind), _value(b, kind)
        except (TypeError, ValueError):
            continue
        if va != vb:
            derived = _derived(orig, ident)
            if kind == 'MATRIX':
                # Held as a Matrix, which RNA takes back as it was and the
                # model reads: flattened (as it is compared), the value would
                # not go back and was priced as a change stuck where it is,
                # from the matrices Blender held. Fix round 3 (October 29),
                # sandboxed desktop 5.2.1 with the app's context: a Move with
                # Affect Only Parents writes the child's Parent Inverse, which
                # read so, and the price passed at the child's old place while
                # Blender built 3,199,472. Not as nested tuples either: RNA
                # stores a matrix by columns and takes each inner tuple as a
                # column (measured: rows with a translation of 0.5 written
                # back read a translation of 0, and the gate's own put-back
                # turned the inverse over).
                va, vb = _matrix_copy(a), _matrix_copy(b)
            change = Change(orig, ident, vb, va, rank)
            change.derived = derived
            out.append(change)


def _matrix_copy(matrix):
    try:
        from mathutils import Matrix
        return Matrix(matrix)
    except (ImportError, TypeError, ValueError):
        return _value(matrix, 'MATRIX')


def _derived(struct, ident):
    """Whether `struct`'s setting `ident` cannot be written now, so a
    difference from Blender's copy is Blender's own working-out, not a write:
    a text's Texture Space with Auto Texture Space on is read-only, and the
    original's and the copy's were found apart. Measured (fix round 3's
    verification): the budget check's parts 1 to 8 then 11, in one desktop
    5.2.1, stopped at part 11's first mirror pass with "The vertex budget
    could not price this change (bpy_struct: attribute "texspace_location"
    from "TextCurve" is read-only)", the same on 6d31b90's code; parts 8 and
    11 alone passed. The price had tried to write it on its copy. Asked only
    where the two differ.

    Fix round 3's review asked for a case of its own (tests/budget/blender/
    smoke.py, run by run-budget-tests.sh): Auto Texture Space turned back on
    by a script line, on a text whose Texture Space was moved — the
    original's place is worked out at once (rna_Curve_texspace_set), the
    copy's when Blender evaluates. And for what this lets go: in Blender
    5.2.1's RNA a setting turns read-only at run time only through an
    editable function, and on what the gate compares those are the Texture
    Space of meshes, curves, texts, surfaces and metaballs, a lattice's
    resolution once it has a shape key, a Cloth's internal springs under
    Linear bending, and Mirror Y/Z of an object that is not a mesh — none
    makes a vertex (smoke.py lists them on a fixture of every kind). Such a
    difference is still put back with the rest (`Pending.derived`): until
    then it was dropped, and a refused line that had also turned Auto
    Texture Space on left the text's Texture Space at the automatic place,
    not the (5, 5, 5) Blender had evaluated."""
    try:
        return bool(struct.is_property_readonly(ident))
    except (AttributeError, TypeError, ReferenceError):
        return False


# The longest custom-property array compared element by element (`_same`,
# which allows float rounding); a longer one is compared whole, as Python
# compares two tuples. Until fix round 3 (October 29) a longer one was not
# compared at all, "no driver's input" — but a driver reads one index of it:
# desktop 5.2.1 with the app's context, the budget lowered to 100,000, an
# Array's Count driven by `E["arr"][0]`, then the script line
# `E['arr'] = [20000] + [2] * 69` and `E.update_tag()`, built 16 → 160,000
# with no refusal, where 64 elements were refused.
_CUSTOM_MOST = 64


def _custom(struct):
    """{name: value} of `struct`'s custom properties a driver can read (a
    number, a string, a short array), or {} where it holds none."""
    try:
        keys = struct.keys()
    except (TypeError, AttributeError, ReferenceError, RuntimeError):
        return {}
    out = {}
    for name in keys:
        try:
            value = struct[name]
        except (KeyError, TypeError, ReferenceError):
            continue
        if isinstance(value, (bool, int, float, str)):
            out[name] = value
        elif hasattr(value, 'to_list') and not hasattr(value, 'keys'):
            try:
                out[name] = tuple(value.to_list())
            except (TypeError, ValueError):
                continue
    return out


def _diff_custom(orig, copy, out, dg):
    """A custom property written since Blender evaluated (`obj["n"] = …`):
    nothing counts it, but a driver can read it. Measured in desktop 5.2.1
    with the app's context (fix round 2's re-measure): a cube's Array Count
    driven by an empty's `["n"]`, the script line `E["n"] = 400000`, then
    `E.update_tag()` and the mirror's pass: 3,200,000 vertices with no
    refusal, because no setting the gate compared had changed. Compared
    here, the change makes `_animation` work out the drivers that read it.

    The copy's are not read while a data-block Blender does not copy may
    have been freed since `dg` last evaluated (see the note above
    `_UNCOPIED`): a custom property can hold one (`obj["img"] = image`), and
    reading it converts it, which reads the freed data-block (measured on
    6d31b90's code, an image removed: a segfault). Python has no way to ask a
    property's type without converting it. They are then each a value with
    nothing before it (`_ABSENT`): the drivers that read them are worked out."""
    a = _custom(orig)
    if not a:
        return
    if any(_freed(dg, t) for t in _UNCOPIED_TYPES):
        b = {}
    else:
        b = _custom(copy)
    for name, value in a.items():
        then = b.get(name, _ABSENT)
        if then is _ABSENT:
            out.append(Change(orig, '["%s"]' % name, then, value, 4))
        elif isinstance(value, tuple) and len(value) > _CUSTOM_MOST:
            if value != then:
                out.append(Change(orig, '["%s"]' % name, then, value, 4))
        elif not _same(value, then):
            out.append(Change(orig, '["%s"]' % name, then, value, 4))


class _Absent:
    """A custom property the copy does not have: set since Blender last
    copied the data-block (a write with `obj["n"] = …` tags nothing, so a
    value set long ago can still be missing from the copy — measured in
    desktop 5.2.1, a pose bone's). Its value before is not known, so it is
    not put back (removing it lost a value set before; writing None makes a
    property holding None): the drivers that read it are held off for the
    price and stay muted when refused (`pending`)."""
    __slots__ = ()

    def __repr__(self):
        return "absent"


_ABSENT = _Absent()


def _tree_shape(tree):
    """A node group's nodes and links, as what no value puts back."""
    nodes = tuple(sorted((n.name, n.bl_idname, getattr(getattr(n, 'node_tree', None), 'name', ''))
                         for n in tree.nodes))
    links = tuple(sorted((l.from_node.name, l.from_socket.identifier, l.to_node.name, l.to_socket.identifier,
                          l.is_muted) for l in tree.links))
    interface = tuple((getattr(i, 'item_type', ''), getattr(i, 'in_out', ''), getattr(i, 'identifier', ''),
                       getattr(i, 'socket_type', '')) for i in tree.interface.items_tree)
    return nodes, links, interface


def _diff_tree(orig, copy, dg, out, structs):
    """A Geometry Nodes group against Blender's copy: each node's settings and
    its inputs' values set back by value; nodes, links or the group's
    interface changed are what no value puts back (round 4's fix round 2
    review: a Grid's Vertices X and Y raised from 10 to 1,900, by a script
    line and by the Data API row, built 3,610,000 vertices unpriced)."""
    try:
        if _tree_shape(orig) != _tree_shape(copy):
            structs.append(Struct('nodes', None, None, orig, "other nodes or links"))
            return
        theirs = {n.name: n for n in copy.nodes}
        for node in orig.nodes:
            other = theirs.get(node.name)
            if other is None:
                continue
            _diff_struct(node, other, dg, out, 0, structs)
    except (AttributeError, ReferenceError, RuntimeError):
        structs.append(Struct('nodes', None, None, orig, "other nodes or links"))


def _diff_node_inputs(orig, copy, dg, out, structs):
    """A Geometry Nodes modifier's inputs (`properties.inputs.Socket_2`,
    three structs below the modifier, past `_diff_struct`'s depth) against
    Blender's copy."""
    counting = _budget()._sibling('_blenderkit_nodecount')
    theirs = {getattr(h, 'path_from_id', lambda: '')(): h for h in counting.inputs_of(copy)}
    for holder in counting.inputs_of(orig):
        try:
            other = theirs.get(holder.path_from_id())
        except (ValueError, AttributeError):
            other = None
        if other is not None:
            _diff_struct(holder, other, dg, out, 0, structs)


def _named(collection):
    return {getattr(item, 'name', str(i)): item for i, item in enumerate(collection)}


def _diff_items(obj, orig_items, copy_items, dg, out, structs, kind):
    """A collection of named items (modifiers, constraints): each item's
    settings, and what was added, removed or moved."""
    mine, theirs = _named(orig_items), _named(copy_items)
    for name, item in mine.items():
        other = theirs.get(name)
        if other is None or getattr(other, 'type', None) != getattr(item, 'type', None):
            structs.append(Struct(kind + '_added', obj, item))
            continue
        _diff_struct(item, other, dg, out, 0, structs)
        if getattr(item, 'type', None) == 'NODES':
            _diff_node_inputs(item, other, dg, out, structs)
    for name, other in theirs.items():
        if name not in mine:
            structs.append(Struct(kind + '_removed', obj, None, other))
    order = [n for n in mine if n in theirs]
    then = [n for n in theirs if n in mine]
    if order != then:
        structs.append(Struct(kind + '_order', obj, None, then))


def _bulk(collection, attribute, size):
    import numpy as np
    out = np.empty(len(collection) * size, dtype=np.float32)
    if len(out):
        collection.foreach_get(attribute, out)
    return out


def _diff_bulk(owner, copy, path, attribute, size, out, keys=False):
    """A collection's attribute (a mesh's vertices, a key's points, a
    spline's points, an F-curve's keys) compared at once; a change of it is
    set back at once. False when the collections differ in length (no value
    puts that back).

    Never from a mesh Blender evaluated last in Edit Mode (`_edit_meshes_then`)
    or one in Edit Mode now: the copy's elements can then be the edit mesh
    Blender has just freed. Measured in desktop 5.2.1 — this module's own
    crash, found by the measure check: `object.mode_set(mode='OBJECT')` from
    a mesh's Edit Mode, and this read of the mesh's evaluated copy in the
    update after it, segfaulted (`foreach_get`, here). An edited mesh's
    elements are the transaction's to price (`_EditGuard`). Until this round
    every bulk read was skipped inside any operator's own update for it, and
    round 4's fix round 2 review measured what that let through: the same
    vertex-thinning code as a registered `bpy.types.Operator`, and as a Text
    run by `text.run_script`, each took a cube under an Array fitted to 40
    from 168 to 3,200,008 vertices with no refusal."""
    import numpy as np
    if not keys:
        if getattr(copy, 'is_editmode', False) or getattr(owner, 'is_editmode', False):
            return True
        try:
            data = owner.id_data
            if data is not None and data.as_pointer() in _edit_meshes_then:
                return True
        except (AttributeError, ReferenceError):
            return True
    mine, theirs = getattr(owner, path), getattr(copy, path)
    if len(mine) != len(theirs):
        return False
    a = _bulk(mine, attribute, size)
    b = _bulk(theirs, attribute, size)
    if not np.array_equal(a, b):
        out.append(Change(owner, '#%s.%s' % (path, attribute), b, a, 6, bulk=mine))
    return True


# The meshes Blender evaluated last in Edit Mode (`_post`), by pointer.
_edit_meshes_then = set()


def _note_edit_meshes():
    """The meshes in Edit Mode now; returns the objects of those that were
    not at the last evaluation (they have just entered it)."""
    before = set(_edit_meshes_then)
    _edit_meshes_then.clear()
    try:
        objects = bpy.context.objects_in_mode_unique_data or ()
    except (AttributeError, RuntimeError):
        objects = ()
    entered = []
    for obj in objects:
        try:
            if obj is not None and obj.type == 'MESH' and obj.mode == 'EDIT':
                p = obj.data.as_pointer()
                _edit_meshes_then.add(p)
                if p not in before:
                    entered.append(obj)
        except (AttributeError, ReferenceError):
            continue
    return entered


def _users(data):
    return [o for o in bpy.data.objects if o.data == data]


def _held(data):
    """Whether `data` is held apart from its elements by a mode, so its
    elements are not what Blender evaluates next: Edit Mode's mesh, and
    Sculpt Mode's with Dynamic Topology (a BMesh of its own). Weight, Vertex
    and Texture Paint and plain Sculpt Mode work on the mesh's own arrays,
    and are compared as Object Mode is. Round 4's fix round 2 review, desktop
    5.2.1: a cube under an Array fitted to 40 (168), a script line scaling x
    by 0.00005 and `me.update()`, made 3,200,008 in each of those four modes
    when they were held, and was refused at 3,200,008 in Object Mode."""
    if getattr(data, 'is_editmode', False):
        return True
    for o in _users(data):
        mode = getattr(o, 'mode', 'OBJECT')
        if mode == 'EDIT':
            return True
        if mode == 'SCULPT' and getattr(o, 'use_dynamic_topology_sculpting', False):
            return True
    return False


def _readers(mesh):
    """(whether anything that uses or reads `mesh` has a count or a time that
    follows where its vertices are, `_PLACE_SENSITIVE`; the names of its
    attributes some count reads: a Bevel limited by Weight reads the Bevel
    Weights, Geometry Nodes any of them, None standing for all). Only then
    is a move of its vertices or a write of an attribute a change to price:
    a cube under a Subdivision is not compared vertex by vertex on every
    stroke of a brush."""
    budget = _budget()
    probe = budget.Prices()
    try:
        reach = budget.affected([mesh], probe)
    finally:
        probe.close()
    places, names = False, set()
    for obj in reach:
        if obj.type == 'META' or len(getattr(obj, 'particle_systems', ())):
            places = True
        for m in obj.modifiers:
            if not m.show_viewport:
                continue
            if _reads_places(m):
                places = True
            if m.type == 'NODES':
                names = None
            elif m.type == 'BEVEL' and names is not None and getattr(m, 'limit_method', '') == 'WEIGHT':
                names.update(('bevel_weight_edge', 'bevel_weight_vert'))
    return places, names


# An attribute's array, by its data type: (the field `foreach_get` reads,
# its size, the numpy type Blender hands it over in).
_ATTRIBUTE_FIELDS = {'FLOAT': ('value', 1, 'f4'), 'INT': ('value', 1, 'i4'), 'BOOLEAN': ('value', 1, '?'),
                     'INT8': ('value', 1, 'i1'), 'FLOAT_VECTOR': ('vector', 3, 'f4'),
                     'FLOAT2': ('vector', 2, 'f4'), 'FLOAT_COLOR': ('color', 4, 'f4'),
                     'BYTE_COLOR': ('color', 4, 'f4'), 'INT32_2D': ('value', 2, 'i4'),
                     'QUATERNION': ('value', 4, 'f4'), 'FLOAT4X4': ('value', 16, 'f4')}


def _attribute_array(attribute):
    import numpy as np
    field, size, kind = _ATTRIBUTE_FIELDS[attribute.data_type]
    out = np.empty(len(attribute.data) * size, dtype=kind)
    if len(out):
        attribute.data.foreach_get(field, out)
    return out


def _diff_attributes(orig, copy, out, structs, names):
    """The attributes of `orig` some count reads (`_readers`), against
    Blender's copy: each one's values set back at once when they differ; one
    made, removed or of another kind is what no value puts back. Round 4's
    fix round 2 review, desktop 5.2.1: a 120 × 120 grid under a Bevel
    limited by Weight at 14 segments (14,400 vertices) made 3,139,984 with no
    refusal when a script line wrote its Bevel Weights in Object Mode — the
    gate compared the vertices' places alone."""
    if names is not None and not names:
        return
    if _holds_edit_data(copy):
        # Never through a copy's edit mesh (see the note above `_UNCOPIED`):
        # this read was fix round 2's use-after-free. `_diff` sends such a
        # mesh to `_diff_left_edit`; this stands guard for any other caller.
        return
    import numpy as np
    try:
        mine = {a.name: a for a in orig.attributes if not a.name.startswith('.')}
        theirs = {a.name: a for a in copy.attributes if not a.name.startswith('.')}
    except (AttributeError, ReferenceError, RuntimeError):
        return
    wanted = set(mine) | set(theirs) if names is None else set(names)
    wanted.discard('position')
    for name in sorted(wanted):
        a, b = mine.get(name), theirs.get(name)
        if a is None and b is None:
            continue
        if a is None or b is None or (a.domain, a.data_type) != (b.domain, b.data_type) \
                or len(a.data) != len(b.data):
            structs.append(Struct('grown', None, None, orig, "its attribute %s" % name))
            continue
        if a.data_type not in _ATTRIBUTE_FIELDS:
            continue
        now, then = _attribute_array(a), _attribute_array(b)
        if not np.array_equal(now, then):
            field = _ATTRIBUTE_FIELDS[a.data_type][0]
            out.append(Change(a, '#data.%s' % field, then, now, 6, bulk=a.data))


# --------------------------------------------------------------------------
# Edit Mode's curves and lattices
#
# Blender's evaluated copy of a curve or a lattice in Edit Mode shares the
# edit points with the original (deg_eval_copy_on_write.cc keeps the copy's
# `editnurb` and `editlatt` the original's). Measured in desktop 5.2.1: a
# Bézier point written in Edit Mode read the new value in the copy before
# anything was evaluated, and so did a lattice point. A metaball's copy keeps
# elements of its own, which only a write through RNA copies again: in its
# Edit Mode Blender evaluates the original's elements, and an operator's
# edit tags only the geometry, so the copy keeps what it had (measured: the
# search's Resize of 30 took an element from 1.2 to 36 and the copy read 1.2
# after Blender had evaluated 36, after `view_layer.update` too, until Edit
# Mode was left; a script line's size read the new value in the copy once
# evaluated). Compared with that copy, the gate put back to 1.2 a Resize
# Blender had evaluated and the gate had passed, and leaving Edit Mode was
# refused for it (the budget check's 9.5e, its control left the element at
# 36). So what Blender evaluated last of them is kept here instead, taken
# after each evaluation that evaluated them (`_post`). Before this, round 4's fix round 2
# measured each of these passing the gate, with the budget lowered to
# 100,000: a Bézier curve under an Array fitted to 100, its points resized to
# a thousandth in Edit Mode — by `transform.resize` or by a script line —
# 650,013 vertices; a lattice's points the same over a cube under a Lattice
# and the Array, 399,944; a metaball's element made 20 times larger by a
# script line in its Edit Mode, 152 → 53,944.

# A spline's points, compared and set back at once, as `_diff` compares them
# outside Edit Mode.
_SPLINE_BULK = (('bezier_points', 'co', 3), ('bezier_points', 'handle_left', 3),
                ('bezier_points', 'handle_right', 3), ('bezier_points', 'radius', 1),
                ('bezier_points', 'tilt', 1), ('bezier_points', 'weight_softbody', 1),
                ('points', 'co', 4), ('points', 'radius', 1), ('points', 'tilt', 1),
                ('points', 'weight_softbody', 1))
_LATTICE_BULK = (('points', 'co_deform', 3), ('points', 'weight_softbody', 1))


class _EditSnap:
    """A curve's, a lattice's or a metaball's edit points as Blender
    evaluated them: their shape (the splines' types and sizes, the points' or
    elements' count), each spline's or element's settings, and each
    collection's attributes."""
    __slots__ = ('name', 'shape', 'settings', 'bulk')

    def __init__(self, data):
        self.name = data.name
        self.settings, self.bulk = [], []
        if isinstance(data, bpy.types.MetaBall):
            elements = data.elements
            self.shape = ('META', len(elements))
            for element in elements:
                self.settings.append({ident: _value(getattr(element, ident), kind)
                                      for ident, kind, rank in _props(element) if kind not in ('STRUCT', 'ID')})
                self.bulk.append({})
            return
        if isinstance(data, bpy.types.Lattice):
            points = data.points
            self.shape = ('LATTICE', len(points))
            self.bulk.append({(path, attribute, size): _bulk(getattr(data, path), attribute, size)
                              for path, attribute, size in _LATTICE_BULK})
            return
        shape = []
        for spline in data.splines:
            shape.append((spline.type, len(spline.bezier_points), len(spline.points)))
            self.settings.append({ident: _value(getattr(spline, ident), kind)
                                  for ident, kind, rank in _props(spline) if kind not in ('STRUCT', 'ID')})
            arrays = {}
            for path, attribute, size in _SPLINE_BULK:
                collection = getattr(spline, path)
                if len(collection):
                    arrays[(path, attribute, size)] = _bulk(collection, attribute, size)
            self.bulk.append(arrays)
        self.shape = ('CURVE', tuple(shape))


def _edit_data(block):
    """Whether `block` is a curve or lattice whose edit points Blender's copy
    shares, or a metaball whose copy does not follow its elements (see the
    note above): in Edit Mode now (`is_editmode` reads only whether the edit
    data is there, never the data, so it is safe on the copy too; a copy
    reads True still in the update that leaves Edit Mode, measured)."""
    if isinstance(block, bpy.types.TextCurve):
        return False
    if not isinstance(block, (bpy.types.Curve, bpy.types.Lattice, bpy.types.MetaBall)):
        return False
    return bool(getattr(block, 'is_editmode', False))


def _edit_objects():
    """The objects in Edit Mode whose data is a curve, a surface, a lattice
    or a metaball. Nothing outside those modes (one look at the context)."""
    try:
        mode = bpy.context.mode
    except AttributeError:
        return []
    if mode not in ('EDIT_CURVE', 'EDIT_SURFACE', 'EDIT_LATTICE', 'EDIT_METABALL'):
        return []
    try:
        objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or ())
    except (AttributeError, RuntimeError):
        objects = []
    if not objects:
        edited = getattr(bpy.context, 'edit_object', None)
        objects = [edited] if edited is not None else []
    return [o for o in objects if o is not None and o.data is not None and _edit_data(o.data)]


def _diff_edit(orig, out, structs, values_only=False):
    """A curve's or a lattice's edit points, or a metaball's elements,
    against what Blender evaluated last (`_EditSnap`): each changed setting
    and attribute a change to set back, a change of their shape (a spline,
    point or element more) what no value puts back. The first look at one
    takes what it is as Blender's."""
    p = orig.as_pointer()
    then = _edit_snaps.get(p)
    if then is None or then.name != orig.name:
        _edit_snaps[p] = _EditSnap(orig)
        return
    import numpy as np
    if isinstance(orig, bpy.types.MetaBall):
        if then.shape[0] != 'META' or len(orig.elements) != then.shape[1]:
            if not values_only:
                structs.append(Struct('grown', None, None, orig, "%d elements" % len(orig.elements)))
            return
        owners = list(orig.elements)
    elif isinstance(orig, bpy.types.Lattice):
        if len(orig.points) != then.shape[1]:
            if not values_only:
                structs.append(Struct('grown', None, None, orig, "its points"))
            return
        owners = [orig]
    else:
        shape = tuple((spline.type, len(spline.bezier_points), len(spline.points)) for spline in orig.splines)
        if shape != then.shape[1]:
            if not values_only:
                structs.append(Struct('grown', None, None, orig, "its splines"))
            return
        owners = list(orig.splines)
    for index, owner in enumerate(owners):
        if then.settings:
            for ident, kind, rank in _props(owner):
                if kind in ('STRUCT', 'ID') or ident not in then.settings[index]:
                    continue
                try:
                    now = _value(getattr(owner, ident), kind)
                except (AttributeError, TypeError, ValueError):
                    continue
                old = then.settings[index][ident]
                if now != old:
                    out.append(Change(owner, ident, old, now, rank))
        for (path, attribute, size), old in then.bulk[index].items():
            collection = getattr(owner, path)
            now = _bulk(collection, attribute, size)
            if not np.array_equal(now, old):
                out.append(Change(owner, '#%s.%s' % (path, attribute), old, now, 6, bulk=collection))


def _refresh_edit(depsgraph=None):
    """After an evaluation: what Blender has just evaluated of the curves and
    lattices in Edit Mode is kept as theirs; those no longer in Edit Mode
    are let go. Only what this evaluation evaluated (its data, or its
    object's geometry) is taken again: a point changed without telling
    Blender is not evaluated, and stays a change."""
    objects = _edit_objects()
    if not objects:
        if _edit_snaps:
            _edit_snaps.clear()
        return
    updated = set()
    if depsgraph is not None:
        try:
            for update in depsgraph.updates:
                block = update.id
                if isinstance(block, bpy.types.Object):
                    if update.is_updated_geometry:
                        updated.add(('Object', block.name))
                else:
                    updated.add((type(block).__name__, block.name))
        except (AttributeError, ReferenceError, RuntimeError):
            updated = None
    keep = set()
    for obj in objects:
        data = obj.data
        p = data.as_pointer()
        keep.add(p)
        then = _edit_snaps.get(p)
        if (then is None or then.name != data.name or updated is None
                or ('Object', obj.name) in updated or (type(data).__name__, data.name) in updated):
            _edit_snaps[p] = _EditSnap(data)
    for p in [p for p in _edit_snaps if p not in keep]:
        del _edit_snaps[p]


def _diff(orig, copy, dg, out, structs, edit_only=False):
    """The fingerprint of one data-block, the original against Blender's
    evaluated copy (see the module's note). `edit_only`: only what Edit Mode
    holds of a curve, a lattice or a metaball, and only its values (inside
    an operator priced before it ran, whose own price does not reach the
    points it moves)."""
    if edit_only:
        if _edit_data(orig) or _edit_data(copy):
            _diff_edit(orig, out, structs, values_only=True)
        return
    _diff_custom(orig, copy, out, dg)
    if isinstance(orig, bpy.types.Object):
        _diff_struct(orig, copy, dg, out, 0, structs)
        _diff_items(orig, orig.modifiers, copy.modifiers, dg, out, structs, 'modifier')
        _diff_items(orig, orig.constraints, copy.constraints, dg, out, structs, 'constraint')
        for name, system in _named(orig.particle_systems).items():
            other = copy.particle_systems.get(name)
            if other is not None:
                _diff_struct(system, other, dg, out, 0, structs)
        if orig.type == 'ARMATURE' and orig.pose is not None and copy.pose is not None:
            for name, bone in _named(orig.pose.bones).items():
                other = copy.pose.bones.get(name)
                if other is None:
                    continue
                _diff_struct(bone, other, dg, out, 0, structs)
                _diff_custom(bone, other, out, dg)
                _diff_items(orig, bone.constraints, other.constraints, dg, out, structs, 'bone_constraint')
        return
    if isinstance(orig, bpy.types.Mesh):
        if _held(orig):
            return
        if _holds_edit_data(copy) or orig.as_pointer() in _edit_meshes_then:
            # Out of Edit Mode since Blender last evaluated it: the copy's
            # elements are the edit mesh just freed (see the note above
            # `_UNCOPIED`), and what Blender evaluated last is the edit mesh
            # the gate priced (`_diff_left_edit`).
            _diff_left_edit(orig, copy, structs)
            return
        counts = (len(orig.vertices), len(orig.edges), len(orig.polygons), len(orig.loops))
        then = (len(copy.vertices), len(copy.edges), len(copy.polygons), len(copy.loops))
        if counts != then:
            structs.append(Struct('grown', None, None, orig, "%s vertices" % format(counts[0], ',')))
            return
        places, names = _readers(orig)
        if places:
            _diff_bulk(orig, copy, 'vertices', 'co', 3, out)
        _diff_attributes(orig, copy, out, structs, names)
        return
    if isinstance(orig, bpy.types.Key):
        _diff_struct(orig, copy, dg, out, 0, structs)
        for name, block in _named(orig.key_blocks).items():
            other = copy.key_blocks.get(name)
            if other is None:
                structs.append(Struct('key_added', None, block, orig))
                continue
            _diff_struct(block, other, dg, out, 0, structs)
            rel_a, rel_b = block.relative_key, other.relative_key
            if (rel_a.name if rel_a else None) != (rel_b.name if rel_b else None):
                out.append(Change(block, 'relative_key', orig.key_blocks.get(rel_b.name) if rel_b else None,
                                  rel_a, 1))
            _diff_bulk(block, other, 'data', 'co', 3, out)
        return
    if isinstance(orig, bpy.types.Curve):
        _diff_struct(orig, copy, dg, out, 0, structs)
        if not hasattr(orig, 'splines'):
            return
        if _edit_data(orig) or _edit_data(copy):
            # Edit Mode's points, which the copy shares: against what Blender
            # evaluated last (`_diff_edit`). The copy's splines are never read
            # then — just out of Edit Mode they are the edit data Blender
            # has freed, as the mesh's were (`_diff_bulk`).
            _diff_edit(orig, out, structs)
            return
        if len(orig.splines) != len(copy.splines) or any(
                a.type != b.type or len(a.points) != len(b.points) or len(a.bezier_points) != len(b.bezier_points)
                for a, b in zip(orig.splines, copy.splines)):
            if not _held(orig):
                structs.append(Struct('grown', None, None, orig, "its splines"))
            return
        if _held(orig):
            return
        for a, b in zip(orig.splines, copy.splines):
            _diff_struct(a, b, dg, out, 0, structs)
            if a.type == 'BEZIER':
                for attribute in ('co', 'handle_left', 'handle_right'):
                    _diff_bulk(a, b, 'bezier_points', attribute, 3, out)
                for attribute in ('radius', 'tilt'):
                    _diff_bulk(a, b, 'bezier_points', attribute, 1, out)
            else:
                _diff_bulk(a, b, 'points', 'co', 4, out)
                for attribute in ('radius', 'tilt', 'weight_softbody'):
                    _diff_bulk(a, b, 'points', attribute, 1, out)
        return
    if isinstance(orig, bpy.types.MetaBall):
        # Its own settings against the copy, which a write through RNA copies
        # again; in Edit Mode its elements against what Blender evaluated
        # last of them (see the note above `_EditSnap`).
        _diff_struct(orig, copy, dg, out, 0, structs)
        if _edit_data(orig) or _edit_data(copy):
            _diff_edit(orig, out, structs)
            return
        if len(orig.elements) != len(copy.elements):
            structs.append(Struct('grown', None, None, orig, "%d elements" % len(orig.elements)))
            return
        for a, b in zip(orig.elements, copy.elements):
            _diff_struct(a, b, dg, out, 0, structs)
        return
    if isinstance(orig, bpy.types.Lattice):
        _diff_struct(orig, copy, dg, out, 0, structs)
        if _edit_data(orig) or _edit_data(copy):
            _diff_edit(orig, out, structs)
            return
        if not _diff_bulk(orig, copy, 'points', 'co_deform', 3, out):
            structs.append(Struct('grown', None, None, orig, "its points"))
        return
    if isinstance(orig, bpy.types.ParticleSettings):
        _diff_struct(orig, copy, dg, out, 0, structs)
        return
    if isinstance(orig, bpy.types.Scene):
        render, other = orig.render, copy.render
        for key in ('use_simplify', 'simplify_subdivision', 'simplify_child_particles', 'simplify_volumes'):
            a, b = getattr(render, key, None), getattr(other, key, None)
            if a != b:
                out.append(Change(render, key, b, a, 4))
        # Time Stretching: Blender evaluates the frame's animation at frame ×
        # Map Old / Map New (`BKE_scene_frame_to_ctime`), so a new map is a
        # new time, priced as a frame change is (`pending` sets the frame).
        # Fix round 3 (October 29), sandboxed desktop 5.2.1 with the app's
        # context: an Array's Count keyed 2 at frame 1 and 400,000 at frame
        # 10, then `scene.render.frame_map_new = 10` at frame 1 — the script
        # line and the Data API row each built 3,200,000 vertices with no
        # refusal; this branch compared the Simplify settings and the frame
        # only.
        for key in _TIME_STRETCH:
            a, b = getattr(render, key, None), getattr(other, key, None)
            if a != b:
                out.append(Change(render, key, b, a, 0))
        # The frame: what Blender evaluates the animation at (round 4's fix
        # round 2 review: the Data API row's `frame_current` 10, and a script
        # line's, each built a key's 3,200,000 vertices unpriced). Priced
        # from what the animation sets there (`_judge`), put back refused.
        for key in ('frame_current', 'frame_subframe'):
            a, b = getattr(orig, key, None), getattr(copy, key, None)
            if a != b:
                out.append(Change(orig, key, b, a, 0))
        # What a scene reads beside its view layer (`_scene_reads`): a
        # Background Scene, a Rigid Body World's collections. Fix round 3
        # (October 29), desktop 5.2.1 with the app's context, the budget
        # lowered to 100,000: `scene.background_set = S2`, S2 holding X under
        # an Array of 20,000, built X at 160,000 with no refusal, and so did
        # `rigidbody.world_add()` then `rigidbody_world.collection = C`, C
        # holding X — the Scene branch compared neither, and X, in no view
        # layer, was looked for nowhere. Compared here, put back refused; what
        # they bring in is priced as new (`pending`).
        _diff_scene_pointer(orig, 'background_set', orig.background_set, copy.background_set, dg, out)
        world, then = getattr(orig, 'rigidbody_world', None), getattr(copy, 'rigidbody_world', None)
        if world is not None:
            for key in ('collection', 'constraints'):
                _diff_scene_pointer(world, key, getattr(world, key, None),
                                    getattr(then, key, None) if then is not None else None, dg, out)
            if then is None or bool(world.enabled) != bool(then.enabled):
                out.append(Change(world, 'enabled', False if then is None else bool(then.enabled),
                                  bool(world.enabled), 1))
        return
    if isinstance(orig, bpy.types.Action):
        _diff_action(orig, copy, out, structs)
        return
    if isinstance(orig, bpy.types.NodeTree):
        _diff_tree(orig, copy, dg, out, structs)
        return
    if isinstance(orig, bpy.types.Texture):
        # A legacy texture's settings (see `_texture_kinds`), its colour
        # ramp's stops among them: what a Displace, Warp or Wave moves
        # vertices by, which a Remesh, a Boolean or a fitted Array after it
        # reads. Priced on copies of the texture (`_blenderkit_budget.Prices`).
        _diff_struct(orig, copy, dg, out, 0, structs)
        return
    if type(orig).__name__ == 'Curves':
        # Hair curves: given points or curves by a script (`add_curves`,
        # `resize`), priced as they are, as a mesh given vertices is. Fix
        # round 3 (October 29), desktop 5.2.1, the budget lowered to 100,000:
        # `add_curves([1000] * 200)` on a Curves object in the scene took it
        # 40 → 200,040 points with no refusal; the type was compared nowhere.
        counts = (len(orig.points), len(orig.curves))
        if counts != (len(copy.points), len(copy.curves)):
            structs.append(Struct('grown', None, None, orig, "%s points" % format(counts[0], ',')))
        return
    if type(orig).__name__ == 'GreasePencil':
        # Its own settings, and its drawings' points as no value puts back:
        # strokes drawn or removed, or points moved where a modifier reads
        # their length (`_blenderkit_budget._gp_measures`).
        _diff_struct(orig, copy, dg, out, 0, structs)
        if _gp_shape(orig) != _gp_shape(copy):
            structs.append(Struct('grown', None, None, orig, "its strokes"))
        return


def _diff_scene_pointer(owner, key, now, then, dg, out):
    """A scene's pointer to a scene or a collection, the original's against
    the copy's (which points at the depsgraph's copy of it)."""
    try:
        before = _original(then, dg) if then is not None else None
        a = now.as_pointer() if now is not None else 0
        b = before.as_pointer() if before is not None else 0
    except (AttributeError, ReferenceError):
        return
    if a != b:
        out.append(Change(owner, key, before, now, 1))


def _scene_reads(scene):
    """The objects Blender evaluates for `scene` that its view layers do not
    hold: its Background Scene's (and that one's, on down), and its Rigid
    Body World's collections' (see `_diff`'s Scene branch). Each scene's
    shown objects, whichever of its collections its view layer excludes: a
    bound of what Blender takes."""
    found = []
    seen = set()
    try:
        other = scene.background_set
        while other is not None and other.as_pointer() not in seen:
            seen.add(other.as_pointer())
            found.extend(o for o in other.collection.all_objects if o is not None and not o.hide_viewport)
            other = other.background_set
        world = getattr(scene, 'rigidbody_world', None)
        if world is not None:
            for key in ('collection', 'constraints'):
                group = getattr(world, key, None)
                if group is not None:
                    found.extend(o for o in group.all_objects if o is not None)
    except (AttributeError, ReferenceError, RuntimeError, TypeError):
        pass
    return found


# --------------------------------------------------------------------------
# Images: what a texture's image holds, which Blender tags nothing for
#
# A Displace, Warp or Wave moves vertices by its texture, and an Image
# texture reads its image's pixels. Writing them tags nothing
# (`rna_Image_pixels_set` marks the image dirty and sends a notifier), and
# Blender does not copy images for its evaluation, so there is no copy to
# compare with. Fix round 3 (October 29), desktop 5.2.1 with the app's
# context, the budget lowered to 100,000: an icosphere under a Displace of a
# 64 × 64 image and a Remesh at 0.02 (47,052 vertices); the script line
# `image.pixels = <noise up to 3>` passed, and the next evaluation of the
# sphere's geometry built 163,358 with no refusal. So the gate keeps the
# images a script or an operator may have changed (`_images_touched`): every
# Image's `__setattr__`, and its members that write pixels when read (the
# pixel array, Scale, Reload, Pack and the rest, `_IMAGE_WRITES`), and every
# image a modifier reads after an operator that paints or edits images
# (`_IMAGE_OPERATORS`: Texture Paint's, the Image menu's, a bake; not Vertex
# or Weight Paint's). Each object reading one is priced as it is
# (`_image_structs`), against what Blender holds, before anything evaluates
# it again. An image sequence or a movie whose frame follows the scene's is
# not priced on a frame change (still open).
_images_touched = set()
_IMAGE_WRITES = frozenset(('pixels', 'scale', 'reload', 'update', 'pack', 'unpack', 'buffers_free',
                           'colorspace_settings', 'generated_color', 'tiles', 'render_slots', 'gl_load',
                           'gl_free', 'save', 'save_render'))
_IMAGE_OPERATORS = ('paint.image_paint', 'paint.project_image', 'paint.image_from_view',
                    'paint.add_texture_paint_slot', 'image.', 'object.bake')


def _touch_image(image):
    try:
        _images_touched.add(bpy.types.bpy_struct.as_pointer(image))
    except (AttributeError, ReferenceError, TypeError):
        pass


def touch_images_read():
    """Every image a modifier reads, as possibly changed (an operator that
    paints or edits images ran)."""
    try:
        for texture in bpy.data.textures:
            image = getattr(texture, 'image', None)
            if image is not None:
                _images_touched.add(image.as_pointer())
        for tree in bpy.data.node_groups:
            for image in _tree_images(tree):
                _images_touched.add(image.as_pointer())
    except (AttributeError, ReferenceError, RuntimeError):
        pass


def _tree_images(tree):
    found = []
    try:
        for node in tree.nodes:
            image = getattr(node, 'image', None)
            if isinstance(image, bpy.types.Image):
                found.append(image)
            for socket in node.inputs:
                value = getattr(socket, 'default_value', None)
                if isinstance(value, bpy.types.Image):
                    found.append(value)
    except (AttributeError, ReferenceError, RuntimeError, TypeError):
        pass
    return found


def _image_structs(layer, out):
    """Each object `layer` evaluates whose modifiers read a touched image (a
    texture's or a Geometry Nodes group's), as an object to price as it
    is."""
    textures = {}         # texture pointer -> the image's name
    trees = {}
    try:
        for texture in bpy.data.textures:
            image = getattr(texture, 'image', None)
            if image is not None and image.as_pointer() in _images_touched:
                textures[texture.as_pointer()] = image.name
        for tree in bpy.data.node_groups:
            for image in _tree_images(tree):
                if image.as_pointer() in _images_touched:
                    trees[tree.as_pointer()] = image.name
    except (AttributeError, ReferenceError, RuntimeError):
        return
    if not textures and not trees:
        _images_touched.clear()          # nothing reads them
        return
    budget = _budget()
    try:
        objects = _dependencies(list(layer.objects))
    except (AttributeError, ReferenceError):
        return
    for obj in objects:
        try:
            for m in obj.modifiers:
                hit = next((textures[getattr(m, ident).as_pointer()] for ident in budget._texture_props(m)
                            if getattr(m, ident, None) is not None
                            and getattr(m, ident).as_pointer() in textures), None)
                if hit is None and m.type == 'NODES':
                    hit = next((trees[tree.as_pointer()] for tree in budget._modifier_trees(obj)
                                if tree.as_pointer() in trees), None)
                if hit is not None:
                    out.structs.append(Struct('image', obj, m, None, hit))
                    break
        except (AttributeError, ReferenceError, RuntimeError, TypeError):
            continue


def _install_images():
    """`_touch_image` on every Image's writes (see the note above)."""
    cls = getattr(bpy.types, 'Image', None)
    struct = getattr(bpy.types, 'bpy_struct', None)
    if cls is None or struct is None or _gate_own(cls.__dict__.get('__setattr__')):
        return
    base_get, base_set = struct.__getattribute__, struct.__setattr__

    def getattribute(self, name, _base=base_get):
        if name in _IMAGE_WRITES:
            _touch_image(self)
        return _base(self, name)

    def setattribute(self, name, value, _base=base_set):
        _touch_image(self)
        _base(self, name, value)
    cls.__getattribute__ = getattribute
    cls.__setattr__ = setattribute
    global _OWN_FUNCTIONS
    _OWN_FUNCTIONS = _OWN_FUNCTIONS + (getattribute, setattribute)


# --------------------------------------------------------------------------
# Animation: what the coming evaluation writes that no setting holds yet
#
# Blender writes animated and driven values inside its evaluation, past
# everything that reads a write (round 4's fix round 2 review, a cube under
# an Array, desktop 5.2.1: a driver on Count with the simple expression
# '400000', added by a script line, made 3,200,000; so did a key's value
# written at the current frame, and the frame moved by the Data API row, a
# script line, `frame_set`, or the search's `screen.frame_offset`,
# `screen.frame_jump` and `screen.keyframe_jump`). So the gate prices what
# the animation would set (`_blenderkit_budget.animation_pairs`) whenever
# Blender is about to evaluate it differently: the frame changes, an action's
# keys change (`_diff_action`), or a data-block's drivers, NLA or action
# change (`_animation_changed`) — and drivers that read what changed.


def _fcurves(action):
    """Every F-curve of a (layered) action, with where it is."""
    found = []
    try:
        for i, layer in enumerate(action.layers):
            for j, strip in enumerate(layer.strips):
                for k, bag in enumerate(getattr(strip, 'channelbags', ())):
                    for curve in bag.fcurves:
                        found.append(((i, j, k, curve.data_path, curve.array_index), curve))
    except (AttributeError, ReferenceError, RuntimeError):
        pass
    return found


def _gp_shape(data):
    """A Grease Pencil's drawings: each one's points and strokes, and a sum
    of where its points are."""
    import numpy as np
    shape = []
    try:
        for layer in data.layers:
            for frame in layer.frames:
                drawing = frame.drawing
                if drawing is None:
                    continue
                position = drawing.attributes.get('position')
                n = len(position.data) if position is not None else 0
                total = 0.0
                if n:
                    co = np.empty(3 * n, dtype=np.float32)
                    position.data.foreach_get('vector', co)
                    total = float(np.abs(co).sum())
                shape.append((layer.name, frame.frame_number, n, len(drawing.strokes), total))
    except (AttributeError, ReferenceError, RuntimeError):
        return None
    return tuple(shape)


def _diff_action(orig, copy, out, structs):
    """An action's F-curves against Blender's copy: each curve's own settings
    and its keys' places and handles, set back at once (round 4's fix round 2
    review: a key written to 400,000 at the current frame by a script line
    built 3,200,000 vertices). Keys or curves added or removed are what no
    value puts back."""
    mine, theirs = _fcurves(orig), _fcurves(copy)
    if [k for k, _ in mine] != [k for k, _ in theirs]:
        structs.append(Struct('keys', None, None, orig, "its F-curves"))
        return
    for (key, a), (_, b) in zip(mine, theirs):
        if len(a.keyframe_points) != len(b.keyframe_points):
            structs.append(Struct('keys', None, None, orig, "its keys"))
            return
        # An F-curve's modifiers make its value as much as its keys do: one
        # added or removed is held (the curve muted for the price, and kept
        # muted refused), a setting of one put back by value. Fix round 3
        # (October 29), sandboxed desktop 5.2.1 with the app's context: a
        # Generator of (400,000, 0) added by a script line to an Array's
        # keyed Count was refused in words, and the same mirror pass built
        # 3,200,000 vertices anyway — the modifiers were compared nowhere,
        # so nothing was put back or muted.
        if len(a.modifiers) != len(b.modifiers) or any(
                x.type != y.type for x, y in zip(a.modifiers, b.modifiers)):
            structs.append(Struct('keys', None, None, orig, "its F-curve modifiers"))
            return
        _diff_struct(a, b, None, out, 0, structs)
        for x, y in zip(a.modifiers, b.modifiers):
            _diff_struct(x, y, None, out, 0, structs)
        for attribute in ('co', 'handle_left', 'handle_right'):
            _diff_bulk(a, b, 'keyframe_points', attribute, 2, out, keys=True)


class _Unknown:
    """A driver's target on Blender's copy that is not read (see
    `_pointer_readable`): equal to nothing, so the driver counts as changed."""
    __slots__ = ()

    def __eq__(self, other):
        return False

    def __ne__(self, other):
        return True

    def __hash__(self):
        return id(self)

    def __repr__(self):
        return "unread"


def _block_key(block, dg, copy):
    """Where a data-block an animation names is, the same for an original
    and for Blender's copy of it: on the copy, the pointer it holds (a copy
    the depsgraph keeps, or a data-block Blender does not copy); on the
    original, where `dg` keeps that one's copy (`_address`). Never the copy's
    `original`, which is freed memory once the original is removed (fix
    round 2's final check counted 90 such reads in 30 rounds of a script line
    removing an action, and 30 for removed driver targets; measured here, the
    copy's action's `original` came back as an 'ID' at the freed address).
    Without `dg` (the gate's own record of what it priced, `_animated_signature`)
    both sides are originals. Fix round 2's review of the frame plan, part
    13.7, measured why the copy is not compared by its own address with the
    original's: a keyed empty's copy held an action at another address, every
    animated object a frame updated read as animation changed, and the
    timeline's plan was made again on every frame a handler wrote anything."""
    if block is None:
        return 0
    if copy or dg is None:
        return block.as_pointer()
    return _address(block, dg)


def _driver_signature(curve, dg=None, copy=False):
    """What a driver works out to, as its settings say."""
    driver = curve.driver
    variables = []
    for var in driver.variables:
        targets = []
        for t in var.targets:
            if copy and getattr(t, 'id_type', 'OBJECT') in _UNCOPIED_TYPES and _freed(dg, t.id_type):
                # The copy points at the original itself, which may be freed
                # (see `_pointer_readable`).
                key = _Unknown()
            else:
                key = _block_key(getattr(t, 'id', None), dg, copy)
            targets.append((key, t.data_path, t.transform_type,
                            t.transform_space, t.rotation_mode, t.bone_target, getattr(t, 'context_property', '')))
        variables.append((var.name, var.type, tuple(targets)))
    keys = tuple(tuple(k.co) for k in curve.keyframe_points)
    modifiers = tuple((m.type, m.mute, tuple(getattr(m, 'coefficients', ()) or ())) for m in curve.modifiers)
    return (curve.data_path, curve.array_index, curve.mute, driver.type, driver.expression, driver.use_self,
            tuple(variables), keys, modifiers)


def _animation_signature(block, dg=None, copy=False):
    """`block`'s drivers, NLA and action as their settings say; `copy`: it is
    Blender's copy in `dg` (see `_block_key`)."""
    try:
        ad = block.animation_data
    except (AttributeError, ReferenceError):
        return None
    if ad is None:
        return None
    try:
        drivers = tuple(_driver_signature(c, dg, copy) for c in ad.drivers)
        tracks = tuple((t.name, t.mute, t.is_solo,
                        tuple((st.name, _block_key(st.action, dg, copy), st.mute, st.influence,
                               st.use_animated_influence, st.blend_type, st.extrapolation, st.frame_start,
                               st.frame_end, st.action_frame_start, st.action_frame_end, st.scale, st.repeat,
                               st.use_reverse, st.blend_in, st.blend_out) for st in t.strips))
                       for t in ad.nla_tracks)
        return (drivers, tracks, _block_key(ad.action, dg, copy), ad.use_nla, ad.use_tweak_mode,
                ad.action_influence, ad.action_blend_type, ad.action_extrapolation)
    except (AttributeError, ReferenceError, RuntimeError):
        return None


def _animation_changed(orig, copy, dg=None):
    """Whether `orig`'s drivers, NLA or action differ from Blender's copy
    (measured in desktop 5.2.1: after `driver_add` and an expression written,
    the copy's drivers stay as they were until Blender evaluates)."""
    try:
        if getattr(orig, 'animation_data', None) is None and getattr(copy, 'animation_data', None) is None:
            return False
    except (AttributeError, ReferenceError):
        return False
    return _animation_signature(orig, dg) != _animation_signature(copy, dg, copy=True)


def _action_users(actions):
    """The data-blocks that `actions` animate: as their action, or in a
    strip of their NLA."""
    wanted = {a.as_pointer() for a in actions}
    found = []
    budget = _budget()
    for block in budget.animated_blocks():
        try:
            ad = block.animation_data
            uses = (ad.action is not None and ad.action.as_pointer() in wanted) or any(
                st.action is not None and st.action.as_pointer() in wanted
                for t in ad.nla_tracks for st in t.strips)
        except (AttributeError, ReferenceError):
            continue
        if uses:
            found.append(block)
    return found


# --------------------------------------------------------------------------
# Edit Mode's meshes changed outside an operator
#
# A script's bmesh edit of an edited mesh (`bmesh.from_edit_mesh`, then
# `bmesh.update_edit_mesh`) is no operator's, and Blender's copy of an edited
# mesh is its edit mesh too, so there is no copy to compare with. Measured in
# desktop 5.2.1 before this, the budget lowered to 100,000: a cube under an
# Array fitted to 100 in Edit Mode, a script line scaling its vertices' x by
# 0.001 with bmesh, passed the mirror's gate and Blender made 400,000. So an
# edited mesh whose stack, or whatever reads it, could grow from it is read
# (`update_from_editmode`) when Blender has been told of a change of its
# geometry outside an operator, and at every mirroring pass (a bmesh edit
# that tells Blender nothing is still evaluated by the next evaluation of the
# object); it is priced as it is when it is not the state last priced and
# passed, and refused, its modifiers stay hidden (`price_state`).

_edit_mesh_states = {}     # mesh pointer -> (name, counts, vertices) priced and passed


def _edited_meshes():
    """The objects in a mesh's Edit Mode (one look at the context first)."""
    try:
        if bpy.context.mode != 'EDIT_MESH':
            return []
        objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or ())
    except (AttributeError, RuntimeError):
        return []
    return [o for o in objects if o is not None and o.type == 'MESH' and o.mode == 'EDIT']


def _attribute_arrays(mesh, names):
    found = []
    for attribute in mesh.attributes:
        if attribute.name.startswith('.') or attribute.name == 'position':
            continue
        if names is not None and attribute.name not in names:
            continue
        if attribute.data_type in _ATTRIBUTE_FIELDS:
            found.append((attribute.name, attribute.domain, attribute.data_type, _attribute_array(attribute)))
    return tuple(sorted(found, key=lambda a: a[0]))


def _entry_state(obj):
    """An edited mesh as it entered Edit Mode, read in `_post` (`_mesh_state`
    without its copy in `bpy.data`: adding and removing a data-block there
    would tag the depsgraph's relations in the middle of its update). The
    original's own arrays are what Blender built the edit mesh from, and
    `Object.to_mesh` of an original copies them outside `bpy.data`
    (`mesh_new_from_mesh`, mesh_convert.cc), with no edit mesh to read
    through."""
    mesh = obj.data
    names = _readers(mesh)[1]
    attributes = ()
    if names is None or names:
        temp = obj.to_mesh()
        try:
            attributes = _attribute_arrays(temp, names) if temp is not None else ()
        finally:
            obj.to_mesh_clear()
    return (mesh.name, (len(mesh.vertices), len(mesh.edges), len(mesh.polygons), len(mesh.loops)),
            _bulk(mesh.vertices, 'co', 3), attributes)


def _mesh_state(mesh, names=()):
    """An edited mesh as `update_from_editmode` last wrote it: its counts,
    its vertices' places, and the attributes `names` some count reads (None:
    all of them; `_readers`). In Edit Mode RNA hands an attribute over from
    the edit mesh element by element only (measured in desktop 5.2.1:
    `foreach_get` raised "sequence length mismatch, needed 0"), so they are
    read from a copy, which costs one copy of the mesh, and only where a
    Bevel limited by Weight or Geometry Nodes reads them. Round 4's fix
    round 2 review: the Item tab's Edge Data ▸ Bevel Weight on a 120 × 120
    grid under such a Bevel at 14 segments made 3,139,984 with no refusal."""
    attributes = ()
    if (names is None or names) and not mesh.is_editmode:
        # Out of Edit Mode (`_diff_left_edit`), read where they are.
        attributes = _attribute_arrays(mesh, names)
    elif names is None or names:
        import numpy as np
        copy = mesh.copy()
        try:
            found = []
            for attribute in copy.attributes:
                if attribute.name.startswith('.') or attribute.name == 'position':
                    continue
                if names is not None and attribute.name not in names:
                    continue
                if attribute.data_type in _ATTRIBUTE_FIELDS:
                    found.append((attribute.name, attribute.domain, attribute.data_type,
                                  _attribute_array(attribute)))
            attributes = tuple(sorted(found, key=lambda a: a[0]))
        finally:
            keys = copy.shape_keys
            bpy.data.meshes.remove(copy)
            if keys is not None and keys.users == 0:
                bpy.data.shape_keys.remove(keys)
    return (mesh.name, (len(mesh.vertices), len(mesh.edges), len(mesh.polygons), len(mesh.loops)),
            _bulk(mesh.vertices, 'co', 3), attributes)


def _same_mesh_state(a, b):
    import numpy as np
    if a is None or b is None or a[0] != b[0] or a[1] != b[1] or not np.array_equal(a[2], b[2]):
        return False
    if len(a[3]) != len(b[3]):
        return False
    return all(x[:3] == y[:3] and np.array_equal(x[3], y[3]) for x, y in zip(a[3], b[3]))


def _edit_mesh_passed(mesh, state=None):
    """`mesh`, in Edit Mode, priced as it is now and passed."""
    try:
        _edit_mesh_states[mesh.as_pointer()] = state if state is not None else _mesh_state(
            mesh, _readers(mesh)[1])
    except (AttributeError, ReferenceError):
        pass


def _grows_from_cage(mesh):
    """Whether anything that reads the edited `mesh` — its objects, and what
    reads them — has a modifier shown whose count follows the mesh's
    elements or places."""
    budget = _budget()
    probe = budget.Prices()
    try:
        reach = budget.affected([mesh], probe)
    finally:
        probe.close()
    for obj in reach:
        for m in obj.modifiers:
            if m.show_viewport and (m.type not in budget._KEEPS_TOPOLOGY or _reads_places(m)):
                return True
    return False


def _edited_mesh_structs(tagged, every, structs):
    """The edited meshes changed since they were last priced (see the note
    above): those Blender was told of (`tagged`, mesh pointers), or `every`
    one."""
    for obj in _edited_meshes():
        mesh = obj.data
        p = mesh.as_pointer()
        if not every and p not in tagged:
            continue
        if not _grows_from_cage(mesh):
            continue
        obj.update_from_editmode()
        now = _mesh_state(mesh, _readers(mesh)[1])
        if _same_mesh_state(_edit_mesh_states.get(p), now):
            continue
        structs.append(Struct('edited', None, None, mesh, "%s vertices" % format(now[1][0], ','), state=now))


def _diff_left_edit(orig, copy, structs):
    """A mesh out of Edit Mode since Blender last evaluated it (its copy still
    points at the freed edit mesh, see the note above `_UNCOPIED`): what
    leaving wrote into it, against the Edit Mode state the gate last priced
    and passed (`_edit_mesh_states`: taken as it entered Edit Mode, `_post`,
    and after every priced edit), never against the copy. The same, it is
    what Blender evaluated last; else — a script's bmesh edit that told
    Blender nothing, left in the same line (an operator's call prices only
    what was told, `pending`) — it is priced as it is. With nothing priced of
    its Edit Mode, its counts are held to the copy's, which are numbers the
    copy holds of its own (`verts_num`..., rna_mesh.cc)."""
    p = orig.as_pointer()
    then = _edit_mesh_states.get(p)
    counts = (len(orig.vertices), len(orig.edges), len(orig.polygons), len(orig.loops))
    if not _grows_from_cage(orig):
        known = then[1] if then is not None else (
            len(copy.vertices), len(copy.edges), len(copy.polygons), len(copy.loops))
        if counts != known:
            structs.append(Struct('grown', None, None, orig, "%s vertices" % format(counts[0], ',')))
        return
    now = _mesh_state(orig, _readers(orig)[1])
    if _same_mesh_state(then, now):
        return
    structs.append(Struct('edited', None, None, orig, "%s vertices" % format(counts[0], ','), state=now))


class Pending:
    """What changed since Blender last evaluated, and what cannot be put
    back by a value. `animated`: data-blocks whose animation the coming
    evaluation can write differently from what Blender holds (a driver or an
    action changed, an action's keys) — priced from what that animation
    sets (`_blenderkit_budget.animation_pairs`); `frame`: the frame it is
    about to evaluate, when that is not the one it holds."""

    def __init__(self):
        self.changes = []
        self.structs = []
        self.animated = {}
        self.held = {}      # of those, the ones no value puts back (`_hold_animation`)
        self.frame = None
        # The frame's time changed with Time Stretching (`_TIME_STRETCH`):
        # priced even where the timeline approved that frame.
        self.stretched = False
        # Differences in settings Blender works out itself (`_derived`): not
        # writes, so they neither make `found` true nor are priced; `_judge`
        # puts them back after the changes, so a refusal leaves exactly what
        # Blender evaluated.
        self.derived = []

    def __bool__(self):
        return bool(self.changes or self.structs or self.animated)


# What instances or is read as a whole object (`_dependencies`).
_INSTANCING_KEYS = frozenset(('instance_type', 'instance_collection', 'instance_object', 'render_type',
                              'use_instance', 'parent', 'bevel_object', 'taper_object', 'follow_curve'))


def _dependencies(objects):
    """Every object Blender evaluates because one of `objects` reads it,
    whether or not a view layer holds it: a parent, a modifier's or a
    constraint's object or collection, an instanced collection, a particle
    system's object or collection, a curve's Bevel and Taper objects, a
    text's curve, a Geometry Nodes modifier's object and collection inputs —
    and what those read. Round 4's fix round 2 review measured an object X,
    never linked to the scene, with an Array of 400,000, evaluated at
    3,200,000 with no refusal three ways: instanced through an empty's
    Collection instance, as A's Shrinkwrap target, as A's Data Transfer
    source."""
    budget = _budget()
    found = {}
    stack = [o for o in objects if o is not None]
    while stack:
        obj = stack.pop()
        try:
            p = obj.as_pointer()
        except (AttributeError, ReferenceError):
            continue
        if p in found:
            continue
        found[p] = obj
        reads = []
        try:
            if obj.parent is not None:
                reads.append(obj.parent)
            for m in obj.modifiers:
                for identifier, kind in budget._pointer_props(m):
                    value = getattr(m, identifier, None)
                    if value is None:
                        continue
                    if kind == 'Object':
                        reads.append(value)
                    else:
                        reads.extend(value.all_objects)
                if m.type == 'NODES':
                    for holder in budget._sibling('_blenderkit_nodecount').inputs_of(m):
                        value = getattr(holder, 'value', None)
                        if isinstance(value, bpy.types.Object):
                            reads.append(value)
                        elif isinstance(value, bpy.types.Collection):
                            reads.extend(value.all_objects)
                    reads.extend(_tree_objects(getattr(m, 'node_group', None)))
            for c in obj.constraints:
                reads.extend(budget._targets_of(c))
            if obj.instance_collection is not None:
                # Whatever its Instancing: Blender's depsgraph builds an
                # instanced collection whenever one is set
                # (`build_object_instance_collection`, deg_builder_nodes.cc),
                # and Geometry Nodes realize it (fix round 3).
                reads.extend(obj.instance_collection.all_objects)
            for system in getattr(obj, 'particle_systems', ()):
                settings = system.settings
                if getattr(settings, 'instance_object', None) is not None:
                    reads.append(settings.instance_object)
                if getattr(settings, 'instance_collection', None) is not None:
                    reads.extend(settings.instance_collection.all_objects)
            data = obj.data
            for key in ('bevel_object', 'taper_object', 'follow_curve'):
                other = getattr(data, key, None) if data is not None else None
                if isinstance(other, bpy.types.Object):
                    reads.append(other)
        except (AttributeError, ReferenceError, RuntimeError, TypeError):
            pass
        stack.extend(o for o in reads if o is not None)
    return list(found.values())


def _tree_objects(tree, seen=None):
    """The objects and collections a node tree names in its nodes' own
    settings and inputs (Object Info, Collection Info, an Object socket's
    value), and in the groups it uses."""
    if tree is None:
        return []
    seen = set() if seen is None else seen
    try:
        p = tree.as_pointer()
    except (AttributeError, ReferenceError):
        return []
    if p in seen:
        return []
    seen.add(p)
    found = []
    try:
        for node in tree.nodes:
            for socket in node.inputs:
                value = getattr(socket, 'default_value', None)
                if isinstance(value, bpy.types.Object):
                    found.append(value)
                elif isinstance(value, bpy.types.Collection):
                    found.extend(value.all_objects)
            for key in ('object', 'collection'):
                value = getattr(node, key, None)
                if isinstance(value, bpy.types.Object):
                    found.append(value)
                elif isinstance(value, bpy.types.Collection):
                    found.extend(value.all_objects)
            inner = getattr(node, 'node_tree', None)
            if inner is not None:
                found.extend(_tree_objects(inner, seen))
    except (AttributeError, ReferenceError, RuntimeError, TypeError):
        pass
    return found


def _unevaluated(objects, dg, out, seen=()):
    """Each of `objects` Blender has not evaluated in `dg`, as a new one."""
    for obj in objects:
        if obj is None:
            continue
        try:
            if obj.as_pointer() in seen:
                continue
            copy = obj.evaluated_get(dg)
            if copy != obj and not _shell(copy):
                continue
        except (RuntimeError, ReferenceError, TypeError, AttributeError):
            continue
        out.structs.append(Struct('new', obj))


def _fresh(layer):
    """A view layer Blender has never evaluated (see `_loaded_layers`):
    everything it is about to evaluate, priced as new. Round 4's fix round 2
    review measured a new scene holding a cube under an Array of 400,000,
    evaluated by `with temp_override(scene=s2, view_layer=...):
    evaluated_depsgraph_get()`, at 3,200,000 with no refusal; and a
    collection excluded from the view layer, evaluated through a second view
    layer the same way. Blender builds a new depsgraph with no callback
    (`DEG_id_type_any_updated` reads nothing tagged yet), so no handler sees
    it."""
    found = Pending()
    # Every object of the view layer's scene that is not turned off for the
    # viewport, whichever of its collections the layer excludes: a view
    # layer Blender has never evaluated has not been brought in sync with its
    # collections, and measured in desktop 5.2.1 a new scene's view layer
    # listed no object (`layer.objects`), and its objects all read not
    # visible (`visible_get` reads flags Blender sets as it evaluates).
    try:
        scene = layer.id_data
        shown = [o for o in scene.collection.all_objects if o is not None and not o.hide_viewport]
        shown.extend(_scene_reads(scene))
    except (AttributeError, ReferenceError, RuntimeError, TypeError):
        return found
    seen = set()
    for obj in _dependencies(shown):
        try:
            if obj.as_pointer() in seen:
                continue
            seen.add(obj.as_pointer())
        except (AttributeError, ReferenceError):
            continue
        found.structs.append(Struct('new', obj))
    return found


def _shell(copy):
    """Whether `copy` is a copy Blender has allocated and not made yet: the
    depsgraph's build allocates each data-block's copy empty and fills it as
    its evaluation begins (`deg_expand_eval_copy_datablock`), and RNA types
    an empty one by its blank name as a bare ID."""
    return type(copy).__name__ == 'ID'


def _never_evaluated(dg):
    """Whether Blender has made `dg` and not evaluated it: no data-block in
    it, or its relations built and its copies not made yet (`_shell`).
    Removing the window's own scene measured the second (fix round 3,
    October 29): Blender gives the window another scene and starts its frame
    on a depsgraph built that moment (`ED_scene_change_update` ->
    `ED_update_for_newframe`), and the gate's frame_change_pre read the frame
    of an empty copy — "The vertex budget could not price this change ('ID'
    object has no attribute 'frame_current')". Everything such a view layer
    is about to evaluate is new (`_fresh`)."""
    try:
        for _ in dg.ids:
            break
        else:
            return True
        return _shell(dg.scene.evaluated_get(dg))
    except (AttributeError, ReferenceError, RuntimeError):
        return False


def _scene_frame(scene):
    try:
        return (scene.frame_current, scene.frame_subframe)
    except (AttributeError, ReferenceError):
        return None


def pending(dg=None, edit_only=False, every_edit_mesh=False, layer=None, frame=False):
    """Every change Blender has been told about and not evaluated yet (see
    the module's note), less what a price has passed already. `edit_only`:
    only the values Edit Mode holds of curves, lattices and metaballs
    (`_diff`). `every_edit_mesh`: every edited mesh is read, told of or not
    (the mirror's pass). `layer`: the view layer `dg` evaluates (the
    context's when not given). `frame`: a frame change about to be evaluated
    (`_frame_pre`), whose frame is compared with the one Blender holds."""
    dg = dg if dg is not None else _depsgraph()
    found = Pending()
    if dg is None:
        return found
    # Asked again for each pass: a handler between two of them can free one.
    _freed_seen[0], _freed_seen[1] = dg, {}
    if layer is None:
        try:
            layer = dg.view_layer
        except (AttributeError, ReferenceError, RuntimeError):
            layer = bpy.context.view_layer
    global _object_count
    structural = False
    seen = set()
    tagged = set()
    actions = []
    for copy, update in _updates(dg):
        name = type(copy).__name__
        if name in ('Scene', 'Collection'):
            structural = True
        if name == 'ID':
            # A copy not made yet (`_shell`): what it is the copy of is new to
            # this depsgraph, and is looked for as one (`_unevaluated`).
            structural = True
            continue
        if name == 'Action':
            orig = _original(copy, dg)
            if orig is not None:
                actions.append(orig)
                if not edit_only:
                    _diff(orig, copy, dg, found.changes, found.structs)
            continue
        if name not in _COLLECTIONS or name == 'Collection':
            continue
        orig = _original(copy, dg)
        if orig is None:
            continue
        seen.add(orig.as_pointer())
        if name == 'Mesh' and update.is_updated_geometry:
            tagged.add(orig.as_pointer())
        _diff(orig, copy, dg, found.changes, found.structs, edit_only)
        if not edit_only and _animation_changed(orig, copy, dg):
            found.animated[orig.as_pointer()] = orig
            found.held[orig.as_pointer()] = orig
    if any(c.derived for c in found.changes):
        found.derived = [c for c in found.changes if c.derived]
        found.changes = [c for c in found.changes if not c.derived]
    if any(c.key == 'color' and isinstance(c.owner, bpy.types.Object) for c in found.changes):
        found.changes = [c for c in found.changes if not _display_colour(c)]
    if not edit_only:
        _hold_readers([c for c in found.changes if c.old is _ABSENT], found)
    if frame:
        # `frame_set` and the frame operators tag nothing: the frame Blender
        # is about to evaluate against the one its copy of the scene holds
        # (measured in desktop 5.2.1: in `frame_change_pre` the copy read 1
        # while the scene read 10).
        try:
            scene = dg.scene
            copy = scene.evaluated_get(dg)
        except (AttributeError, ReferenceError, RuntimeError):
            scene = copy = None
        if scene is not None and copy is not scene and not _shell(copy) and scene.as_pointer() not in seen:
            for key in ('frame_current', 'frame_subframe'):
                a, b = getattr(scene, key), getattr(copy, key)
                if a != b:
                    found.changes.append(Change(scene, key, b, a, 0))
    for c in found.changes:
        if isinstance(c.owner, bpy.types.Scene) and c.key in ('frame_current', 'frame_subframe'):
            found.frame = (c.owner, c.owner.frame_current + c.owner.frame_subframe)
    if found.frame is not None and _frame_approved(found.frame):
        # The timeline priced this frame just now (`price_frame`): not judged
        # again, and not put back and set again, which tags the scene. Measured
        # in desktop 5.2.1 (the budget check's 11.1): that tag made the app's
        # `frame_set` drop the frame plan on every frame, 9.7 ms to make again.
        scene = found.frame[0]
        found.changes = [c for c in found.changes
                         if not (c.owner == scene and c.key in ('frame_current', 'frame_subframe'))]
        found.frame = None
    for c in found.changes:
        if c.key in _TIME_STRETCH and isinstance(c.owner, bpy.types.RenderSettings):
            # A new Time Stretching is a new time for the frame Blender holds
            # (see `_diff`): its animation priced there, whoever approved
            # the frame before.
            try:
                scene = c.owner.id_data
                found.frame = (scene, scene.frame_current + scene.frame_subframe)
                found.stretched = True
            except (AttributeError, ReferenceError):
                continue
    if actions and not edit_only:
        # An action's keys or settings changed: every data-block it animates.
        # Keys moved are put back by value (`_diff_action`); keys or curves
        # added or removed are not, and are held off for the price.
        grown = {st.data.as_pointer() for st in found.structs if st.kind == 'keys'}
        for block in _action_users(actions):
            found.animated[block.as_pointer()] = block
            try:
                ad = block.animation_data
                if ad.action is not None and ad.action.as_pointer() in grown:
                    found.held[block.as_pointer()] = block
            except (AttributeError, ReferenceError):
                continue
    # Edit Mode's curves and lattices whether or not Blender was told: a
    # point set with `foreach_set` tags nothing, and the next evaluation of
    # the object's geometry would build it all the same.
    for obj in _edit_objects():
        if obj.data.as_pointer() not in seen:
            _diff_edit(obj.data, found.changes, found.structs, values_only=edit_only)
    if edit_only:
        if found and _same_state(found):
            found.changes, found.structs, found.animated, found.held = [], [], {}, {}
        return found
    # An edited mesh changed by a script (bmesh) between operators; inside an
    # operator's own update an edited mesh is the transaction's
    # (`_EditGuard`) or no element of it changed.
    if not _calls:
        _edited_mesh_structs(tagged, every_edit_mesh, found.structs)
    count = len(bpy.data.objects)
    # What a change makes Blender evaluate that it did not: an object linked,
    # shown again, or newly read by another (a pointer to it, an instanced
    # collection, a modifier or a constraint added) — evaluated as a
    # dependency whether or not a view layer holds it.
    reading = set()
    for c in found.changes:
        if isinstance(c.new, (bpy.types.Object, bpy.types.Collection, bpy.types.Scene)) \
                or c.key in _INSTANCING_KEYS or (c.key == 'enabled' and type(c.owner).__name__ == 'RigidBodyWorld'):
            try:
                block = c.owner.id_data
            except (AttributeError, ReferenceError):
                continue
            if isinstance(block, bpy.types.Object):
                reading.add(block)
            elif isinstance(block, bpy.types.ParticleSettings):
                reading.update(o for o in bpy.data.objects
                               if any(ps.settings == block for ps in getattr(o, 'particle_systems', ())))
            elif isinstance(block, bpy.types.Scene):
                # A Background Scene or a Rigid Body World's collection
                # (`_scene_reads`): what it brings in, priced as new.
                reading.update(_scene_reads(block))
    for st in found.structs:
        if st.kind in ('modifier_added', 'constraint_added', 'bone_constraint_added') and st.obj is not None:
            reading.add(st.obj)
    if _images_touched:
        # Images a script or an operator may have changed (see the note
        # above `_images_touched`): what reads one, priced as it is.
        _image_structs(layer, found)
    if structural or count != _object_count or reading:
        candidates = []
        if structural or count != _object_count:
            # An object Blender has not evaluated: a script's new one, one shown
            # again, one in a collection shown again.
            for obj in layer.objects:
                if obj is None:
                    continue
                try:
                    if obj.visible_get(view_layer=layer):
                        candidates.append(obj)
                except (RuntimeError, ReferenceError, TypeError):
                    continue
            # And what the scene reads beside its view layer: an object
            # linked into its Background Scene's collections, or its Rigid
            # Body World's (`_scene_reads`).
            try:
                candidates.extend(_scene_reads(layer.id_data))
            except (AttributeError, ReferenceError):
                pass
            # Scanned: until the next object is added or removed, there is
            # nothing new to look for (a frame change has no update after it
            # to say so, and scanning 3,000 objects every frame cost 5 ms of
            # it).
            _object_count = count
        candidates.extend(reading)
        _unevaluated(_dependencies(candidates), dg, found)
    # A pass is reused only for exactly the state it priced: every change
    # waiting is one priced and passed, at that value, and every one passed
    # still waits, and what no value puts back is as it was priced. Measured
    # in desktop 5.2.1 when passes were reused per setting: a Copy Location's
    # Target set at Influence 0 passed, the Influence went back to the 1.0
    # Blender had last evaluated — no change any more — and the Target alone
    # was waiting, passed, and Blender built 3,200,008 vertices.
    if found and _same_state(found):
        found.changes, found.structs, found.animated, found.held = [], [], {}, {}
    return found


def _display_colour(change):
    """Whether `change` is an object's viewport display Color that no driver
    reads: what the 3D View draws it with, which no model reads and the
    app's own material picker writes (`BpyBridge.setMaterial`). Priced, it
    would cost a whole price of the object (a Boolean's evaluation on a copy:
    12 s on an 80,000-vertex Self Intersection, fix round 3) for a colour;
    `color` is compared since fix round 3 for a colour ramp's stops (see
    `_NEVER`)."""
    if change.key != 'color' or not isinstance(change.owner, bpy.types.Object):
        return False
    budget = _budget()
    if budget is None:
        return False
    try:
        wanted = change.owner.as_pointer()
        scene = bpy.context.scene
        for block in budget.animated_blocks():
            for curve in block.animation_data.drivers:
                for var in curve.driver.variables:
                    for key, _ in budget._driver_inputs(var, scene):
                        if key[0] == wanted and key[1] == 'color':
                            return False
    except (AttributeError, ReferenceError, RuntimeError):
        return False
    return True


def _hold_readers(changes, found):
    """Custom properties with no value to put back (`_Absent`): every
    data-block with a driver reading what holds them is animated and held
    (`_hold_animation`), so a refusal leaves its drivers muted."""
    if not changes:
        return
    ids = set()
    for c in changes:
        try:
            ids.add(c.owner.id_data.as_pointer())
        except (AttributeError, ReferenceError):
            continue
    for block in _budget().animated_blocks():
        try:
            drivers = block.animation_data.drivers
            reads = any(t.id is not None and t.id.as_pointer() in ids
                        for curve in drivers for v in curve.driver.variables for t in v.targets)
        except (AttributeError, ReferenceError, RuntimeError):
            continue
        if reads:
            found.animated[block.as_pointer()] = block
            found.held[block.as_pointer()] = block


def _signature(structs):
    """What the structural changes are, to tell a state priced from one that
    is not: their kinds, what they are on, and a new object's settings."""
    out = []
    for item in structs:
        what = []
        for part in (item.obj, item.item, item.data):
            try:
                what.append(part.as_pointer() if part is not None else 0)
            except (AttributeError, ReferenceError):
                what.append(0)
        if item.kind == 'new' and item.obj is not None:
            what.append(_fingerprint(item.obj))
        elif item.kind in ('grown', 'edited') and item.data is not None:
            what.append(_data_counts(item.data))
        out.append((item.kind, tuple(what), item.note))
    return tuple(sorted(out, key=repr))


def _data_counts(data):
    counts = []
    for name in ('vertices', 'edges', 'polygons', 'loops', 'splines', 'elements', 'points', 'curves'):
        collection = getattr(data, name, None)
        if collection is not None:
            counts.append(len(collection))
    return tuple(counts)


def _fingerprint(obj):
    """An object Blender has not evaluated, as the price read it: its own
    settings, its modifiers' and its data's size (no copy to compare with)."""
    values = []
    for struct in [obj] + list(obj.modifiers) + list(obj.constraints):
        for ident, kind, rank in _props(struct):
            if kind in ('STRUCT', 'ID'):
                continue
            try:
                values.append(_value(getattr(struct, ident), kind))
            except (AttributeError, TypeError, ValueError, RuntimeError):
                continue
    if obj.data is not None:
        values.append(_data_counts(obj.data))
    return repr(values)


def _same_state(found):
    """Whether `found` is the state the last pass priced (see `pending`)."""
    if any(c.bulk is not None for c in found.changes):
        return False
    keys = set()
    for c in found.changes:
        try:
            keys.add((c.owner.as_pointer(), c.key))
        except (AttributeError, ReferenceError):
            return False
        if not _is_approved(c):
            return False
    if keys != set(_approved):
        return False
    if found.animated and _animated_signature(found) != _accepted_animated:
        return False
    if found.structs:
        return _accepted is not None and _signature(found.structs) == _accepted
    return True


def _same(a, b):
    if isinstance(a, (tuple, list)) and isinstance(b, (tuple, list)):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        try:
            a, b = float(a), float(b)
        except (TypeError, ValueError):
            return False
        return a == b or abs(a - b) <= 1e-6 * max(1.0, abs(a), abs(b))
    try:
        return a == b
    except Exception:
        return False


def _is_approved(change):
    if change.bulk is not None:
        return False
    try:
        key = (change.owner.as_pointer(), change.key)
    except (AttributeError, ReferenceError):
        return False
    if key not in _approved:
        return False
    value = _approved[key]
    new = change.new
    try:
        if hasattr(new, 'as_pointer') and hasattr(value, 'as_pointer'):
            return new.as_pointer() == value.as_pointer()
        if hasattr(new, '__len__') and not isinstance(new, str) and hasattr(value, '__len__'):
            try:
                return _same(tuple(new), tuple(value))
            except TypeError:
                return False
        return _same(new, value)
    except ReferenceError:
        # What was passed is gone: a data-block removed since, and its
        # setting's struct's pointer given to a new one. Measured in desktop
        # 5.2.1 (the modifier check, Geometry Nodes modifiers made and the
        # file reloaded between them): the mirror's pass raised "StructRNA
        # of type GeometryNodeTree has been removed" here, and the whole pass
        # was lost.
        return False


def approve(changes):
    """Called by every price that passed (`price_all`): those values are
    priced, and the gate lets them through until Blender evaluates them."""
    for owner, key, value in changes:
        try:
            if key == 'dimensions' or key.startswith('matrix_'):
                continue
            if isinstance(owner, bpy.types.Scene) and key.startswith('frame_'):
                # A frame is priced from what its animation sets, which no
                # setting's price reads (round 4's fix round 2 review: the
                # Data API row's `frame_current` 10 passed its price and was
                # let through, 3,200,000 vertices).
                continue
            _approved[(owner.as_pointer(), key)] = value
        except (AttributeError, ReferenceError):
            continue


# --------------------------------------------------------------------------
# Putting a change back, and setting it again


def _live(change):
    """Whether the struct `change` is on still exists. A write can free
    another change's struct: measured in desktop 5.2.1 (the budget check's
    Fluid sweep), a domain's `sndparticle_combined_export` and
    `use_bubble_particles` put back made Blender remove and remake its
    secondary particle systems, and setting the old system's `settings`
    again then crashed Blender in `psys_changed_type`. Found again by the
    path read when the change was made, on its data-block, which a write
    does not free; a struct at another address is not the one changed."""
    if change.path is None:
        return True
    try:
        found = change.block.path_resolve(change.path, False)
        return found is not None and found.as_pointer() == change.pointer
    except (AttributeError, ValueError, TypeError, RuntimeError, ReferenceError):
        return False


def _write(change, value):
    if not _live(change):
        raise ReferenceError("its struct was freed")
    if change.bulk is not None:
        change.bulk.foreach_set(change.key.rpartition('.')[2], value)
        data = change.owner.id_data
        if hasattr(data, 'update'):
            try:
                data.update()
            except (TypeError, RuntimeError):
                pass
        return
    if isinstance(value, Struct):
        raise ValueError("gone")
    if change.key.startswith('["'):
        if value is _ABSENT:
            raise ValueError("no value before")
        change.owner[change.key[2:-2]] = value
        return
    setattr(change.owner, change.key, value)


def _revert(changes):
    """Each change set back to what Blender evaluated, in the order the
    settings depend on. Returns the ones that would not go back."""
    stuck = []
    for change in sorted(changes, key=lambda c: c.rank):
        try:
            _write(change, change.old)
        except (AttributeError, TypeError, ValueError, RuntimeError, ReferenceError):
            stuck.append(change)
    return stuck


def _reapply(changes):
    for change in sorted(changes, key=lambda c: c.rank):
        try:
            _write(change, change.new)
        except (AttributeError, TypeError, ValueError, RuntimeError, ReferenceError):
            pass


# --------------------------------------------------------------------------
# The gate


class _Busy:
    """The gate pricing: its own evaluations pass, and a script's handlers
    are out of the lists Blender calls inside an evaluation meanwhile (see
    the note above `_EVALUATION_LISTS`)."""

    def __enter__(self):
        global _busy
        if _busy == 0:
            _suspend_handlers()
        _busy += 1

    def __exit__(self, *exc):
        global _busy
        _busy -= 1
        if _busy == 0:
            _resume_handlers()
        return False


def busy():
    """Whether the gate is pricing now (its own evaluations pass)."""
    return _busy > 0


def _inputs_of(found):
    """The data-blocks a change is written to: what a driver may read."""
    blocks = {}
    for c in found.changes:
        try:
            block = c.owner.id_data
        except (AttributeError, ReferenceError):
            continue
        if block is not None:
            blocks[block.as_pointer()] = block
    for st in found.structs:
        for block in (st.obj, st.data):
            if isinstance(block, bpy.types.ID):
                blocks[block.as_pointer()] = block
    # What follows an object moves with it: a driver reading a child in
    # World Space reads a change of its parent. Fix round 3, desktop 5.2.1:
    # E, the child of P, read by a Count driver (x × 40,000 + 2), and P moved
    # 10 by the Data API row or a Move, built 3,200,016 with no refusal.
    stack = [b for b in blocks.values() if isinstance(b, bpy.types.Object)]
    while stack:
        try:
            children = stack.pop().children
        except (AttributeError, ReferenceError):
            continue
        for child in children:
            if child.as_pointer() not in blocks:
                blocks[child.as_pointer()] = child
                stack.append(child)
    return list(blocks.values())


def _animation(found):
    """What the coming evaluation's animation would set (see the note above
    `_fcurves`), worked out from the state as written — before the changes
    are put back for the price."""
    inputs = _inputs_of(found)
    frame = found.frame
    if frame is not None and _frame_approved(frame) and not found.stretched:
        frame = None
    if frame is None and not found.animated and not inputs:
        return None
    budget = _budget()
    if frame is None and not found.animated and not _any_driver():
        return None
    return budget.animation_pairs(frame, list(found.animated.values()), inputs)


def _any_driver():
    budget = _budget()
    for block in budget.animated_blocks():
        try:
            if len(block.animation_data.drivers):
                return True
        except (AttributeError, ReferenceError):
            continue
    return False


_frame_ok = None        # (scene pointer, frame + subframe) the timeline's price passed


def approve_frame(scene, t):
    """`_blenderkit_budget.price_frame` passed the frame `t`: the gate's
    frame handler need not price it again."""
    global _frame_ok
    try:
        _frame_ok = (scene.as_pointer(), float(t))
    except (AttributeError, ReferenceError):
        _frame_ok = None


def _frame_approved(frame):
    scene, t = frame
    try:
        return _frame_ok == (scene.as_pointer(), float(t))
    except (AttributeError, ReferenceError):
        return False


def _mute(animated, found, held):
    """Refused: what no value puts back of the animation — a driver added or
    edited, an NLA strip, keys added — stays muted where it set a refused
    value (or could not be worked out ahead); the rest of what the price
    held off is let go. Returns their names."""
    if animated is None:
        _release_animation(held)
        return []
    culprits = set()
    for sources in animated.sources.values():
        for block, curve in sources:
            culprits.add(curve.as_pointer())
    for block, curve, words in animated.unknown:
        culprits.add(curve.as_pointer())
    for block, curve in getattr(animated, 'probed', ()):
        culprits.add(curve.as_pointer())
    keep = set()
    named = []
    for block, curve, is_driver in held:
        try:
            if curve.as_pointer() in culprits:
                keep.add(curve.as_pointer())
                named.append("%s's %s on %s" % (block.name, 'driver' if is_driver else 'F-curve',
                                                 curve.data_path + ('[%d]' % curve.array_index
                                                                    if curve.array_index else '')))
        except (AttributeError, ReferenceError):
            continue
    _release_animation(held, keep)
    return named


def _unknown_refusal(animated):
    block, curve, words = animated.unknown[0]
    return ("%s's driver on %s would be worked out by Blender alone (%s): the app prices every value "
            "that can change a count before Blender evaluates it, and only Blender's simple "
            "expressions (numbers, the variables, frame, arithmetic and math functions) can be "
            "worked out ahead." % (block.name, curve.data_path, words))


def _judge(found, title=None):
    """Puts back what changed, prices the change laid over it — with what
    the animation would set once Blender evaluates it — and writes it again
    when it passes; returns the refusal's words, or None. `title` names what
    made the change (an operator), where it is known."""
    budget = _budget()
    changes = list(found.changes)
    structs = list(found.structs)
    # Worked out from the state as written, before anything is put back.
    failed = None
    try:
        animated = _animation(found)
    except Exception as error:                           # noqa: BLE001 - refused below
        animated, failed = None, error
    hidden = []           # (modifier, show_viewport it had) hidden for the price
    disabled = []         # (constraint, enabled it had)
    stuck = _revert(changes)
    # A struct a put-back value freed (`_live`) is not read again: its change
    # went with it.
    stuck = [c for c in stuck if _live(c)]
    keep = [c for c in changes if c not in stuck and _live(c)]
    # Then what Blender works out itself (`Pending.derived`), where the
    # put-back made it writable again: Auto Texture Space put back off, the
    # text's Texture Space goes back to where Blender evaluated it. What will
    # not go back is Blender's to work out again, and is not priced.
    derived = list(getattr(found, 'derived', ()))
    _revert(derived)
    for s in structs:
        if s.kind == 'modifier_added' and s.item.show_viewport:
            hidden.append((s.item, True))
            s.item.show_viewport = False
        elif s.kind in ('constraint_added', 'bone_constraint_added') and s.item.enabled:
            disabled.append((s.item, True))
            s.item.enabled = False
        elif s.kind == 'items':
            # Items added to or taken from what owns them (a constraint's
            # targets): the constraint or modifier they are in held off.
            holder = _holder(s.item)
            if isinstance(holder, bpy.types.Constraint) and holder.enabled:
                disabled.append((holder, True))
                holder.enabled = False
            elif isinstance(holder, bpy.types.Modifier) and holder.show_viewport:
                hidden.append((holder, True))
                holder.show_viewport = False
    # The animation no value puts back, held off while the price evaluates:
    # the price's own evaluations evaluate the scene, and measured before this
    # in desktop 5.2.1, a driver of '400000' on an Array's Count, refused,
    # had built its 3,200,000 vertices inside the price that refused it.
    held_curves = _hold_animation(found)
    try:
        if failed is not None:
            raise failed
        if animated is not None and animated.unknown:
            refusal = _unknown_refusal(animated)
        else:
            refusal = budget.price_state(keep, stuck, structs, hidden, disabled, title, animated=animated)
    except Exception as error:                           # noqa: BLE001 - refused, closed
        # What could not be priced is refused as it stands: the values stay as
        # Blender evaluated them, a new modifier hidden, a new constraint off,
        # the animation held off muted. Until fix round 3 (October 29) the
        # change was written again and the error raised, and where nothing can
        # raise (a frame's handler) Blender then evaluated it: part 12.17's
        # sweep keyed a legacy texture's Brightness and called frame_set(2),
        # the price failed inside ('NoneType' object has no attribute
        # 'action'), and Blender built 4,000,001 and 3,199,472 vertices under
        # the words "so it was put back".
        return ("The vertex budget could not price this change (%s), so it was put back." % error)
    if refusal is None:
        _reapply(keep)
        # Read-only again once the rest is written (Auto Texture Space on):
        # Blender works it out, and the write is refused and let go.
        _reapply(derived)
        for item, value in hidden:
            item.show_viewport = value
        for item, value in disabled:
            item.enabled = value
        _release_animation(held_curves)
        global _accepted, _accepted_animated
        # Passed: exactly this state is priced, until Blender evaluates it.
        _approved.clear()
        for c in keep:
            if c.bulk is None:
                try:
                    _approved[(c.owner.as_pointer(), c.key)] = c.new
                except (AttributeError, ReferenceError):
                    pass
        _accepted = _signature(structs) if structs else None
        _accepted_animated = _animated_signature(found)
        for item in structs:
            if item.kind == 'edited':
                _edit_mesh_passed(item.data, item.state)
        return None
    # Refused: the values stay as Blender evaluated them. A new modifier stays
    # hidden and a new constraint off, so nothing evaluates them past the
    # budget; what was hidden or taken out for what could not be put back
    # is said in the words (`price_state`). Animation that no value puts back
    # — a driver added or edited, keys added, an NLA strip — is muted.
    muted = _mute(animated, found, held_curves)
    if muted:
        refusal = refusal.rstrip() + (" The animation it came from is muted: %s." % ", ".join(muted))
    return refusal


def _holder(struct):
    """The constraint or modifier `struct` is, or is in, or None."""
    if isinstance(struct, (bpy.types.Constraint, bpy.types.Modifier)):
        return struct
    try:
        path = struct.path_from_id()
        block = struct.id_data
    except (AttributeError, ReferenceError, ValueError, RuntimeError):
        return None
    import re
    match = re.match(r'^((?:pose\.bones\[".*?"\]\.)?(?:constraints|modifiers)\[".*?"\])', path)
    if match is None:
        return None
    try:
        return block.path_resolve(match.group(1))
    except (ValueError, AttributeError):
        return None


def _hold_animation(found):
    """The drivers and F-curves of every data-block whose animation changed
    (`found.animated`) muted for the price: [(block, F-curve)]."""
    held = []
    for block in found.held.values():
        try:
            ad = block.animation_data
        except (AttributeError, ReferenceError):
            continue
        if ad is None:
            continue
        curves = [(c, True) for c in ad.drivers]
        try:
            from bpy_extras import anim_utils
            if ad.action is not None and getattr(ad, 'action_slot', None) is not None:
                bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
                if bag is not None:
                    curves.extend((c, False) for c in bag.fcurves)
        except (ImportError, AttributeError, RuntimeError, TypeError):
            pass
        for curve, is_driver in curves:
            try:
                if not curve.mute:
                    curve.mute = True
                    held.append((block, curve, is_driver))
            except (AttributeError, ReferenceError, RuntimeError):
                continue
    return held


def _release_animation(held, keep=()):
    for block, curve, is_driver in held:
        try:
            if curve.as_pointer() not in keep:
                curve.mute = False
        except (AttributeError, ReferenceError, RuntimeError):
            continue


_accepted_animated = None


def _animated_signature(found):
    if not found.animated:
        return None
    return frozenset((p, repr(_animation_signature(block))) for p, block in found.animated.items())


def _run(where, title=None, edit_only=False, dg=None, layer=None, frame=False, beyond=None):
    """The gate, once: (whether anything was waiting to be evaluated, the
    refusal's words or None). `dg`, or `layer`'s depsgraph, is the one about
    to be evaluated (the context's when neither is given); `frame`: in
    `frame_change_pre`, where the frame Blender is about to evaluate is a
    change too. `beyond`: in an Object Mode move's own update, the objects
    its price priced (`_move_scope`); what changed is priced only when it is
    more than their channels."""
    if _busy or not _real():
        return False, None
    install()
    if where == 'mirror':
        tidy_handlers()
    if dg is None:
        if layer is None:
            try:
                layer = bpy.context.view_layer
            except AttributeError:
                layer = None
        if layer is None:
            return False, None
        try:
            dg = layer.depsgraph
        except (AttributeError, ReferenceError, RuntimeError):
            return False, None
    else:
        try:
            layer = dg.view_layer
        except (AttributeError, ReferenceError, RuntimeError):
            layer = None
    with _Busy():
        if dg is None or _never_evaluated(dg):
            # A view layer Blender has never evaluated (no depsgraph, or one
            # made and not built yet — `scene.frame_set` on another scene
            # makes one as it begins): everything in it is about to be
            # evaluated for the first time (`_fresh`), at the frame it is at.
            try:
                if layer.as_pointer() in _loaded_layers:
                    return False, None
            except (AttributeError, ReferenceError):
                return False, None
            found = _fresh(layer)
            if found and frame:
                scene = layer.id_data
                found.frame = (scene, scene.frame_current + scene.frame_subframe)
        else:
            found = pending(dg, edit_only, every_edit_mesh=(where == 'mirror'), layer=layer, frame=frame)
        if not found:
            return False, None
        if beyond is not None and _within_move(found, beyond):
            return False, None
        # The timeline's frame plan hears of what changed here: its evaluation
        # may come with no update after it (a frame's second pass, the price's
        # own evaluations), see `_blenderkit_budget.note_pending`.
        note = getattr(_budget(), 'note_pending', None)
        if note is not None:
            note(found)
        return True, _judge(found, title)


def gate(where=None):
    """Prices every change Blender has not evaluated yet, before anything
    evaluates it, and raises the refusal in words. Called before the mirror
    reads the scene (`_blenderkit_sync.sync`) and, through `settle`, before
    every operator `bpy.ops` hands out and every price. Returns whether a
    change was waiting and passed."""
    waiting, refusal = _run(where)
    if refusal is not None:
        raise RuntimeError(refusal)
    return waiting


def settle(where=None):
    """`gate`, then — when a change was waiting and passed — Blender's
    evaluation of it, so what follows (an operator's own price from where
    things are, an operator that moves what a write just moved) reads the
    scene as it now is. The evaluation is the one the operator's call would
    make first anyway (`bpy_op_view_layer_update`), and the handlers find
    nothing left to price in it."""
    if gate(where):
        try:
            bpy.context.view_layer.update()
        except (AttributeError, RuntimeError):
            pass


def take_refusals(where=None):
    """The refusals kept by the handlers since they were last taken (for
    `where`, an operator path, or all of them), oldest first."""
    if where is None:
        taken = [text for _, text in _refusals]
        _refusals.clear()
        return taken
    taken = [text for path, text in _refusals if path == where]
    _refusals[:] = [(path, text) for path, text in _refusals if path != where]
    return taken


# --------------------------------------------------------------------------
# Operators: priced before the call by `gate`, and what they changed priced
# in the update Blender runs after them, before it evaluates (`_result`).

# Operators called in a mesh's Edit Mode that change no element and move
# none, and write nothing a count reads: their run needs no copy of the mesh
# to take back (`_EditGuard`). By the start of their name. Not
# `mesh.attribute_`: `mesh.attribute_set` writes any attribute, a Bevel
# Weight among them (round 4's fix round 2 review, desktop 5.2.1: on a
# 120 × 120 grid under a Bevel limited by Weight at 14 segments, 14,400 →
# 3,139,984 with no refusal). tests/budget/blender/verify.py (part 9) runs each
# one the operator search lists on meshes in Edit Mode and fails one that
# changes the vertices, edges, faces, their sizes, valences or places.
EDIT_STILL = ('mesh.select', 'mesh.hide', 'mesh.reveal', 'mesh.mark_', 'mesh.loop_select',
              'mesh.loop_multi_select', 'mesh.edgering_select', 'mesh.region_to_loop', 'mesh.loop_to_region',
              'mesh.shortest_path', 'mesh.faces_select', 'mesh.edges_select', 'mesh.normals_', 'mesh.flip_normals',
              'mesh.average_normals', 'mesh.point_normals', 'mesh.smooth_normals', 'mesh.set_normals_from_faces',
              'mesh.set_sharpness_by_angle', 'mesh.faces_shade_', 'mesh.customdata_',
              'mesh.uv_texture_', 'mesh.color_attribute_', 'object.vertex_group_', 'uv.', 'view3d.', 'wm.', 'ed.',
              'object.mode_set', 'object.editmode_toggle', 'screen.', 'object.select', 'object.hide',
              'mesh.uvs_', 'mesh.colors_', 'mesh.mod_weighted_strength', 'mesh.select_')
# The moves of an edited mesh's selected vertices: in Edit Mode the gate
# cannot read the vertices (Blender holds them in its edit mesh), and Blender
# evaluates the stack in its update after the call, so the move is held as a
# transaction too. Measured in desktop 5.2.1 before it was: a cube under an
# Array fitted to 40, all selected, Resize 0.0001 on X built 1,599,736
# vertices, with nothing priced and a budget lowered to 100,000.
EDIT_MOVES = ('transform.', 'view3d.snap_selected_to_')
# The kinds whose count reads where the vertices are, for which an Edit Mode
# move (`EDIT_MOVES`) is a change to price as well: a Remesh's surface, an
# Array's size or its fitted length, a Boolean's crossings, a Bevel's angle.
_PLACE_SENSITIVE = ('REMESH', 'BOOLEAN', 'ARRAY', 'BEVEL', 'MESH_TO_VOLUME', 'NODES', 'FLUID', 'VOLUME_TO_MESH')


def _reads_places(m):
    """Whether `m`'s count or time follows where its vertices are, as the
    budget's model counts it: a Remesh's surface, a Boolean's crossings, a
    volume's voxels, Geometry Nodes, a Fluid domain's size; an Array only
    fitted to a length or a curve (a Fixed Count's copies are its Count); a
    Bevel only limited by Angle. Not Solidify, Skin, Weld, Decimate or Edge
    Split, whose counts the model makes from what is connected to what (and
    Weld and Decimate only take away). Measured in desktop 5.2.1 at a load
    average of 5, on a 90,601-vertex grid under a Subdivision and an Array
    of Count 2, all selected: with the Array taken for place-reading, a Move
    and the evaluation after it took 95 ms against 58 with the gate off (the
    Array hidden for the move and evaluated again after it). An Edge Split
    by angle reads the angles."""
    kind = m.type
    if kind == 'ARRAY':
        return getattr(m, 'fit_type', 'FIXED_COUNT') != 'FIXED_COUNT'
    if kind == 'BEVEL':
        return getattr(m, 'limit_method', '') == 'ANGLE'
    if kind == 'EDGE_SPLIT':
        # Its bound is the corners, but where that is past the budget the
        # count is made exact (`_final`), and the angles then decide it.
        return bool(getattr(m, 'use_edge_angle', False))
    return kind in _PLACE_SENSITIVE


def _read_in_edit_mode(m):
    """Whether Edit Mode's own operators read `m` while they run, so hiding it
    for the transaction would change what they do: a Mirror with Clipping,
    whose plane Extrude keeps its edges off (`edbm_extrude_edge_exclude_mirror`)
    and a move keeps the vertices on. Measured in desktop 5.2.1, the +X half
    of a 4 × 4 grid under a Mirror with Clipping, every edge selected:
    Blender's Extrude Region made 30/53/24 vertices, edges and faces bare, and
    30/56/28 with the Mirror hidden by this transaction (the meshmenu check's
    Extrude to Cursor or Add the same). Left shown, it makes at most eight
    times the mesh for the run's own update (three axes), and the price after
    the run counts it as shown either way."""
    return m.type == 'MIRROR' and bool(getattr(m, 'use_clip', False))


def _now_of(obj, shown):
    """What works out `obj`'s (count, seconds) as the transaction's 'now',
    the modifiers `shown` counted as shown (hidden for the run)."""
    def work():
        budget = _budget()
        s = budget.Prices()
        try:
            for m in shown:
                s.change(m, 'show_viewport', True)
            try:
                w = budget._final(obj, s)
            except budget.Unpriceable:
                return (budget.BUDGET * 1000, 0.0)
            try:
                seconds = budget._subdivision_seconds(w)[0]
            except budget.Unpriceable:
                seconds = 0.0
            return (w.final.v, seconds)
        finally:
            s.close()
    return work


class _EditGuard:
    """One operator's run in a mesh's Edit Mode, held like a transaction for
    each edited mesh whose stack could turn its result heavy or slow: the
    mesh copied, the modifiers that make more hidden so Blender's update
    after the run does not build them, the run priced from the mesh it left
    — its counts exact, its N-Gons and high-valence vertices read for
    Subdivision Surface's limit surface — and taken back, before anything
    builds it, when that is past the budget or SUBDIVISION_SECONDS. Round 4's
    second fix-round review measured each of these passing: Dissolve Faces on
    a 62 × 62 grid under Subdivision 1 (one 248-gon, 7.99 s), Fill on a
    250-vertex wire circle (8.46 s), Add ▸ Circle of 250 as an N-Gon into a
    cube (8.40 s), Add ▸ Monkey three times into a cube under Subdivision 6
    (6,074,312 vertices). An Edit Mode edit has no undo step to go back to
    inside a run, so the copy is the way back.

    What reads an edited mesh is held with it: another object that shares it
    (a linked duplicate) or reads it (a Boolean's operand, a Surface Deform's
    target), and what reads those. Measured in desktop 5.2.1 before it was,
    the budget lowered to 100,000: a cube in Edit Mode with no modifier of
    its own, all selected, Resize 0.001 on X, and B — its linked duplicate,
    under an Array fitted to 100 — went from 408 to 400,008 vertices, with
    nothing priced."""

    def __init__(self, path):
        self.path = path
        self.held = []      # (object, hidden modifiers, (count, seconds) before, or what works it out)
        self.copies = []    # (edited object, its mesh's copy)
        self.stands = []    # stand-ins of the edited objects with those copies, for 'before'

    @classmethod
    def begin(cls, path, moving=None, own=False, args=(), keywords=None):
        # Only around what can change the edited mesh's elements: Blender's
        # mesh operators, the app's own bmesh code (`own`, `editing`), and the
        # moves of the selected vertices (`EDIT_MOVES`, executed). Not around
        # a pick or the Cursor, which read Blender's evaluated mesh while they
        # run: measured in desktop 5.2.1 (the measure check), with the
        # modifiers hidden around a call that invokes Blender's Cursor tool,
        # its clicks met the bare mesh, not the Mirror's or the Array's, at 43
        # to 66 pixels of 1,333 per stack. So not around the Cursor's own drag
        # (`cursor_transform`) or a move invoked to run modal, which would end
        # after the call returns.
        if not path:
            return None
        move = path.startswith(EDIT_MOVES)
        if move:
            if (keywords or {}).get('cursor_transform') or (
                    args and isinstance(args[0], str) and args[0].startswith('INVOKE')):
                return None
        elif path.startswith(EDIT_STILL) or not (own or path.startswith('mesh.')):
            return None
        objects = _edited_meshes()
        if not objects:
            return None
        budget = _budget()
        if moving is None:
            moving = move
        guard = cls(path)
        edited = set(objects)
        # What reads the edited meshes, by the model's own walk.
        probe = budget.Prices()
        try:
            reach = [o for o in budget.affected([o.data for o in objects], probe) if o not in edited]
        finally:
            probe.close()

        def growing(obj):
            return [m for m in obj.modifiers
                    if (m.show_viewport or (obj in edited and m.show_in_editmode))
                    and (_reads_places(m) if moving else m.type not in budget._KEEPS_TOPOLOGY)
                    and not (obj in edited and _read_in_edit_mode(m))]

        holding = [(obj, growing(obj)) for obj in objects + reach]
        holding = [(obj, grows) for obj, grows in holding if grows]
        if not holding:
            return None
        for obj in objects:
            obj.update_from_editmode()
        for obj in objects:
            guard.copies.append((obj, obj.data.copy()))
        copies = {obj.as_pointer(): copy for obj, copy in guard.copies}
        for obj, grows in holding:
            # The 'now' the run is judged against, worked out only where the
            # judgement needs it (`_blenderkit_budget._Lazy`): from a stand-in
            # with the mesh as it is before the run and its modifiers as
            # they are now. Measured in desktop 5.2.1, under a load average
            # of about 20, on a 90,601-vertex grid under a Subdivision and an
            # Array of 2, all selected: worked out before every run it was 31
            # ms of the 95 the gate added to a Remove Doubles of 160.
            stand = obj.copy() if obj.as_pointer() in copies else None
            if stand is not None:
                stand.data = copies[obj.as_pointer()]
                guard.stands.append(stand)
            hidden = []
            for m in grows:
                hidden.append((m, m.show_viewport, m.show_in_editmode))
                m.show_viewport = False
                m.show_in_editmode = False
            # Hiding them makes nothing more: not a change for the gate to price.
            approve([(m, key, False) for m, _, _ in hidden for key in ('show_viewport', 'show_in_editmode')])
            now = _now_of(stand if stand is not None else obj,
                          [] if stand is not None else [m for m, _, _ in hidden])
            # Worked out later only from a stand-in holding the one edited
            # mesh's copy. What else the run changes under an object — a
            # linked duplicate's shared mesh, a Boolean's edited operand,
            # another edited mesh — would by then read as the run left it,
            # and 'now' would be 'after': measured in desktop 5.2.1 (the
            # budget check's 9.5f), B, a linked duplicate under an Array fitted
            # to 100, priced lazily, passed the cube's Resize 0.001 and built
            # 400,008 vertices. So those are worked out here, before the run.
            lazy = stand is not None and len(objects) == 1
            guard.held.append((obj, hidden, now if lazy else now()))
        return guard

    def finish(self, ran):
        """The run priced (`ran`: it returned), taken back when refused;
        the modifiers shown again either way. Returns the refusal's words."""
        budget = _budget()
        refusal = None
        try:
            if ran:
                for obj, copy in self.copies:
                    obj.update_from_editmode()
                refusal = budget.edit_price_after_all(
                    [(obj, [m for m, shown, _ in hidden if shown], before) for obj, hidden, before in self.held],
                    _operator_words(self.path))
                if refusal is not None:
                    import bmesh
                    for obj, copy in self.copies:
                        bm = bmesh.from_edit_mesh(obj.data)
                        bm.clear()
                        bm.from_mesh(copy)
                        bmesh.update_edit_mesh(obj.data, loop_triangles=False, destructive=True)
                else:
                    # Priced just now from the mesh the run left: the gate need
                    # not price it again before Blender evaluates it.
                    for obj, copy in self.copies:
                        _edit_mesh_passed(obj.data)
        finally:
            shown_again = []
            for obj, hidden, before in self.held:
                for m, shown, in_edit in hidden:
                    try:
                        m.show_viewport = shown
                        m.show_in_editmode = in_edit
                        shown_again += [(m, 'show_viewport', shown), (m, 'show_in_editmode', in_edit)]
                    except ReferenceError:
                        pass
            for stand in self.stands:
                try:
                    bpy.data.objects.remove(stand)
                except (ReferenceError, RuntimeError):
                    pass
            for obj, copy in self.copies:
                keys = copy.shape_keys
                bpy.data.meshes.remove(copy)
                if keys is not None:
                    try:
                        if keys.users == 0:
                            bpy.data.shape_keys.remove(keys)
                    except (AttributeError, ReferenceError, RuntimeError):
                        pass
            # Priced just now with the mesh the run left: showing them again is
            # not a change to price twice.
            approve(shown_again)
        return refusal


# Text Edit Mode. Blender types a text object's body into an edit buffer of
# its own (`EditFont`), which RNA does not reach: `data.body` reads the text
# from before Edit Mode whatever was typed (measured in desktop 5.2.1, and
# in rna_curve.cc's body setter, "TODO: how to handle editmode?"). Round 4's
# fix round 2 review: a text under an Array of 3 (2,124 vertices) in Edit
# Mode, `bpy.ops.font.text_insert(text='W' * 20000)` built 3,122,124 vertices
# with no refusal; only leaving Edit Mode was refused. Leaving Edit Mode
# writes the buffer into `body` and keeps the cursor and the selection
# (`cu->pos`), measured: a toggle out and in, then an insert, put the insert
# where the cursor was. So an operator that can change the characters runs
# as a transaction (`_FontGuard`): the buffer read before it by a toggle,
# the modifiers that make more hidden while it runs, the buffer read after it,
# and the new body priced by the text's own model (`_judge`) — written back
# as it was when refused.

# The text Edit Mode operators that change no character (or only take some
# away): no transaction.
FONT_STILL = ('font.move', 'font.move_select', 'font.select_all', 'font.select_word', 'font.selection_set',
              'font.text_copy', 'font.text_cut', 'font.delete', 'font.line_break', 'font.change_spacing',
              'font.textbox_add', 'font.textbox_remove')


def _text_editing():
    try:
        if bpy.context.mode != 'EDIT_TEXT':
            return None
        obj = bpy.context.edit_object
    except AttributeError:
        return None
    return obj if obj is not None and obj.type == 'FONT' else None


class _FontGuard:
    def __init__(self, obj, path):
        self.obj, self.path = obj, path
        self.before = None
        self.hidden = []

    @classmethod
    def begin(cls, path):
        if not path.startswith('font.') or path.startswith(FONT_STILL):
            return None
        obj = _text_editing()
        if obj is None:
            return None
        guard = cls(obj, path)
        budget = _budget()
        with _Busy():
            # The buffer as it is: written into `body` by leaving Edit Mode,
            # and Edit Mode entered again with the cursor where it was.
            bpy.ops.object.mode_set(mode='OBJECT')
            guard.before = obj.data.body
            probe = budget.Prices()
            try:
                reach = budget.affected([obj], probe)
            finally:
                probe.close()
            for other in set(reach) | {obj}:
                for m in other.modifiers:
                    if m.show_viewport and m.type not in budget._KEEPS_TOPOLOGY:
                        guard.hidden.append((m, True))
                        m.show_viewport = False
            approve([(m, 'show_viewport', False) for m, _ in guard.hidden])
            bpy.ops.object.mode_set(mode='EDIT')
        return guard

    def finish(self, ran):
        """The run priced (`ran`: it returned); the buffer written back as it
        was when refused. Returns the refusal's words."""
        obj, refusal = self.obj, None
        with _Busy():
            bpy.ops.object.mode_set(mode='OBJECT')
            after = obj.data.body
            for m, shown in self.hidden:
                try:
                    m.show_viewport = shown
                except ReferenceError:
                    pass
        if ran and after != self.before:
            found = Pending()
            found.changes.append(Change(obj.data, 'body', self.before, after, 2))
            # Priced as the panel's Body Text is: the body laid over the one
            # Blender holds (put back first, `_judge`).
            with _Busy():
                refusal = _judge(found, _operator_words(self.path) + " in Edit Mode")
        with _Busy():
            bpy.ops.object.mode_set(mode='EDIT')
        return refusal


class editing:
    """The Edit Mode transaction (`_EditGuard`) around code of the app's own
    that edits a mesh with bmesh, which no operator's call holds: priced
    exactly, from the mesh it leaves, before Blender evaluates it, and taken
    back when refused (`_blenderkit_meshmenu.to_cursor`; with `moving`, an
    edit that only moves vertices, priced on the modifiers that read where
    they are: the Item tab's Median, `_blenderkit_tools.snap`)."""

    def __init__(self, name, moving=False):
        self.name, self.moving, self.guard = name, moving, None

    def __enter__(self):
        settle(self.name)
        if _real() and not _busy:
            self.guard = _EditGuard.begin(self.name, self.moving, own=True)
        return self

    def __exit__(self, kind, error, traceback):
        if self.guard is None:
            return False
        with _Busy():
            refusal = self.guard.finish(kind is None)
        if refusal is not None and kind is None:
            raise RuntimeError(refusal)
        return False


def _operator_words(path):
    if '.' not in path:
        return path
    module, _, name = path.partition('.')
    try:
        return getattr(getattr(bpy.ops, module), name).get_rna_type().name or name
    except (AttributeError, KeyError, RuntimeError):
        return name.replace('_', ' ').title()


class calling:
    """Around one operator's call through `bpy.ops` (the wrappers of
    `_blenderkit_context`): the gate first, raising; then, for the call,
    the handlers know which operator's update they are in; and in a mesh's
    Edit Mode the run is held as a transaction (`_EditGuard`)."""

    __slots__ = ('path', 'priced', 'edit', 'args', 'keywords', 'font')

    def __init__(self, path, priced=False, args=(), keywords=None):
        self.path, self.priced, self.edit = path, priced, None
        self.args, self.keywords = args, keywords
        self.font = None

    def __enter__(self):
        if _calls and _calls[-1][0] == self.path:
            # The wrapper inside a wrapper (`_PricedOperator` around
            # `_UndoInArea`): one call, priced as the outer one says.
            _calls.append(_calls[-1])
            return self
        settle(self.path)
        if _real() and not _busy:
            self.edit = _EditGuard.begin(self.path, args=self.args, keywords=self.keywords)
            self.font = _FontGuard.begin(self.path)
        _calls.append((self.path, self.priced, self.priced and _proportional(self.path, self.keywords),
                       _move_scope(self.path) if self.priced else None))
        return self

    def __exit__(self, kind, error, traceback):
        _calls.pop()
        if self.path.startswith(_IMAGE_OPERATORS):
            # It may have painted or edited an image a modifier reads.
            touch_images_read()
        said = take_refusals(self.path)
        if self.edit is not None:
            with _Busy():
                held = self.edit.finish(kind is None)
            if held is not None:
                said.append(held)
        if self.font is not None:
            held = self.font.finish(kind is None)
            if held is not None:
                said.append(held)
        if said and kind is None:
            raise RuntimeError(said[-1])
        return False


def _in_call():
    return _calls[-1] if _calls else None


# Settings of an object a move writes: what an Object Mode move's own price
# (`_blenderkit_budget.price_object_moves`) prices, on the objects it moves.
_MOVE_KEYS = frozenset(('location', 'rotation_euler', 'rotation_quaternion', 'rotation_axis_angle',
                        'rotation_mode', 'scale', 'matrix_parent_inverse', 'parent'))
# The tool settings (the Options popover's Affect Only, `_blenderkit_tools.
# set_tools`) with which an Object Mode move moves something its own price
# does not: Origins moves the data the other way, Locations turns or sizes
# no object, Parents leaves the children where they are. Fix round 2's
# re-check, desktop 5.2.1 with the app's context: with Affect Only Parents,
# A translated 0.9999 with its child O (A's Array offset, fitted to 40) left
# in place built 328 -> 3,199,472; with Affect Only Origins, a 90-degree
# rotate of a thin cube under an Array fitted to 40 by its size built 40 ->
# 3,186,080 — neither refused.
_AFFECT_ONLY = ('use_transform_data_origin', 'use_transform_pivot_point_align', 'use_transform_skip_children')


# Priced operators whose own price lays the whole change on the objects it
# is called on and judges every object that reads them (`affected`):
# `price_add`, `price_copy`, `price_copy_to_selected`,
# `price_modifiers_copy_to_selected`, `check_move` and `check_move_to`
# (through `price_order`). Their update in Object Mode is compared for Edit
# Mode's values only, as before: compared whole it was priced a second time,
# measured in desktop 5.2.1 (fix round 3) as Add Modifier ▸ Weld on a legal
# 399,254-vertex Boolean taking 2.25 to 2.33 s against 1.39 to 1.51 s
# (Blender's own evaluation 0.48 to 0.56 s).
_PRICED_WITH_READERS = frozenset(('object.modifier_add', 'object.modifier_copy', 'object.modifier_copy_to_selected',
                                  'object.modifiers_copy_to_selected', 'object.modifier_move_up',
                                  'object.modifier_move_down', 'object.modifier_move_to_index'))


def _object_moves():
    return tuple(getattr(_budget(), '_MOVES', ())) + ('transform.rotate',)


def _move_scope(path):
    """For an Object Mode move priced before it runs (`_object_moves`): the
    objects it may move, the selected editable ones, by pointer. In its
    update every change is compared, and one on anything else, or anything
    but their channels, is priced whole (`_run`'s `beyond`). None for any
    other operator, or another mode."""
    try:
        if bpy.context.mode != 'OBJECT' or path not in _object_moves():
            return None
        # What an earlier move priced is not this one's (`_within_move`).
        forget = getattr(_budget(), 'forget_places', None)
        if forget is not None:
            forget()
        chosen = getattr(bpy.context, 'selected_editable_objects', None) or ()
        return frozenset(o.as_pointer() for o in chosen)
    except (AttributeError, ReferenceError, RuntimeError):
        return None


def _place_after(obj):
    """The world matrix Blender will evaluate for `obj` from the channels the
    original holds now, its parent where Blender last evaluated it; None where
    a constraint or a parent other than an object decides it."""
    try:
        for constraint in obj.constraints:
            if getattr(constraint, 'enabled', True) and constraint.influence > 0.0:
                return None
        basis = obj.matrix_basis
        parent = obj.parent
        if parent is None:
            return basis.copy()
        if obj.parent_type != 'OBJECT':
            return None
        return parent.matrix_world @ obj.matrix_parent_inverse @ basis
    except (AttributeError, ReferenceError, TypeError):
        return None


def _plain(value):
    """A value as nested tuples of numbers (a Matrix, a Vector, an array)
    for `_same`; anything else as it is."""
    if isinstance(value, (str, bytes)) or not hasattr(value, '__len__'):
        return value
    try:
        return tuple(_plain(v) for v in value)
    except TypeError:
        return value


# How far a moved object's evaluated place may lie from the place its move
# was priced at and still be that place: Blender works a transform out in
# floats in its own order. Measured in desktop 5.2.1 (fix round 3, October
# 29) over Moves, Rotates and Resizes in all seven orientations of an empty
# turned and scaled at random, the largest difference was 2.4e-7 of the
# matrix's own size (at least 1); a wrong orientation is off by the whole
# move.
PLACE_TOLERANCE = 2e-6


def _same_place(a, b):
    try:
        for i in range(4):
            for j in range(4):
                x, y = float(a[i][j]), float(b[i][j])
                if not abs(x - y) <= PLACE_TOLERANCE * max(1.0, abs(x), abs(y)):
                    return False
    except (TypeError, ValueError, IndexError):
        return False
    return True


def _within_move(found, scope):
    """Whether everything `found` holds is the channels of objects in
    `scope` (`_move_scope`), each where the move's own price priced it
    (`_blenderkit_budget.priced_places`): a world matrix held to the one
    Blender will evaluate from the channels written (`_place_after`), or the
    values a clear was priced with. Fix round 3's review (October 29): a
    Scale and a Move in Local orientation were priced as Global and their
    update let through on the scope alone, A 328 -> 3,199,472."""
    if found.structs or found.animated or found.frame is not None:
        return False
    places = getattr(_budget(), 'priced_places', None) or {}
    moved = []
    held = set()
    for c in found.changes:
        if c.bulk is not None or c.key not in _MOVE_KEYS or not isinstance(c.owner, bpy.types.Object):
            return False
        try:
            pointer = c.owner.as_pointer()
        except (AttributeError, ReferenceError):
            return False
        if pointer not in scope:
            return False
        record = places.get(pointer)
        if record is None:
            return False
        kind, priced = record
        if kind == 'values':
            if c.key not in priced or not _same(_plain(c.new), _plain(priced[c.key])):
                return False
        elif pointer not in held:
            held.add(pointer)
            after = _place_after(c.owner)
            if after is None or not _same_place(after, priced):
                return False
        moved.append(c.owner)
    # A driver that reads what moved (or what follows it) works out to
    # something else now, which the move's own price could only work out
    # where the driver is Blender's simple arithmetic (`_readers_of`): priced
    # whole, where Blender's own evaluation of it can be read.
    reads = getattr(_budget(), 'read_by_drivers', None)
    return not (moved and reads is not None and reads(moved))


def _proportional(path, keywords):
    """Whether an Object Mode move moves objects it was not priced for: with
    Proportional Editing, Blender moves every object within its size as
    well as the selection (`transform.*` reads `use_proportional_edit`, or
    the scene's tool setting when the call does not set it). Round 4's fix
    round 2 review, desktop 5.2.1: E selected 0.05 m from O, the offset of
    A's Array fitted to 40, `transform.translate(value=(-0.9999, 0, 0),
    use_proportional_edit=True, proportional_edit_falloff='CONSTANT',
    proportional_size=1.0)` moved O to 0.0001 and took A from 328 to
    3,199,472 with no refusal: the move's own price counts the selection
    (`price_object_moves`), and in its update the gate looked at Edit Mode's
    points alone. The gizmo's commit and its redo panel send the setting
    (TransformCommit.swift). Such a move's update is priced whole — and so
    is an Object Mode move made with one of the Options popover's Affect
    Only settings (`_AFFECT_ONLY`)."""
    try:
        if bpy.context.mode == 'OBJECT' and path in _object_moves():
            settings = bpy.context.scene.tool_settings
            if any(getattr(settings, key, False) for key in _AFFECT_ONLY):
                return True
    except AttributeError:
        pass
    if not path.startswith('transform.'):
        return False
    keywords = keywords or {}
    if 'use_proportional_edit' in keywords:
        return bool(keywords['use_proportional_edit'])
    try:
        settings = bpy.context.scene.tool_settings
        mode = bpy.context.mode
    except AttributeError:
        return False
    if mode == 'OBJECT':
        return bool(getattr(settings, 'use_proportional_edit_objects', False))
    return bool(getattr(settings, 'use_proportional_edit', False))


# --------------------------------------------------------------------------
# The handlers
#
# Blender calls these inside an evaluation: `depsgraph_update_pre` and
# `frame_change_pre` before it, `depsgraph_update_post` and
# `frame_change_post` after its first pass — and what a post handler writes,
# a second pass evaluates with no callback at all (scene.cc,
# `scene_graph_update_tagged` and `BKE_scene_graph_update_for_newframe_ex`).
# Round 4's fix round 2 review measured a script's handlers going round the
# gate, a cube under an Array of 2 (16 vertices) in sandboxed desktop 5.2.1:
# a `depsgraph_update_post` handler writing Count 400000 made 3,200,000; so
# did a `depsgraph_update_pre` handler appended after the gate's, and a
# `frame_change_post` handler with `frame_set(2)`; and
# `bpy.app.handlers.depsgraph_update_pre.clear()` took the gate out for the
# rest of the session (the gate installed itself once), after which moving
# an Array's offset object built 3,200,008.
#
# So now:
#   * The gate's own handlers are put back wherever the gate runs, and before
#     every evaluation a script can ask for (`before_evaluation`), not once.
#   * After every callable of a script's in those four lists stands a
#     checkpoint of the gate's (`_checkpoint`), which prices what that
#     callable wrote before Blender evaluates it — in a post list, before the
#     second pass. Blender reads each list item by item as it goes
#     (`bpy_app_generic_callback`: "don't store the list size since the
#     scripts may remove themselves"), so a checkpoint the gate's own handler
#     inserts after a handler further down is called in the same evaluation.
#     The script's callable stays in its list as it is, so `remove`, `in` and
#     `index` find it.
#   * While the gate prices (`_busy`), a script's handlers are out of the four
#     lists: the price's own evaluations of its copies and stand-ins are not
#     the script's to see, and what a handler wrote in one would be evaluated
#     by its second pass with the gate standing aside.

_EVALUATION_LISTS = ('depsgraph_update_pre', 'depsgraph_update_post', 'frame_change_pre', 'frame_change_post')


def _own(function):
    """Whether `function` needs no checkpoint after it: the gate's own
    (`_gate_own`), a script's callable the gate already wraps (`_Guarded`,
    which runs its own checkpoint), or one the app or Blender put in a list
    (`_trusted`) — all known by identity, never by anything a script can
    copy or name.

    Fix round 3 (October 29) first measured, in desktop 5.2.1 with the app's
    context and the budget lowered to 100,000, a script's
    depsgraph_update_post handler given `fn._blenderkit_gate = True` taken as
    the gate's, with no checkpoint after it, and its Count of 20,000 built
    (16 → 160,000). Its answer knew a module's handlers by the module Python
    had loaded the file as (its globals that module's, its `__file__` the
    code's file), and the review of that work measured each of those held
    by a script (budget 100,000, Count 20,000, 160,000 built, no refusal):
    a `types.ModuleType('_blenderkit_zz_fake')` registered in `sys.modules`
    with `__file__` set beside this module (the file need not exist) and
    the handler compiled under that path into its dict; the same compiled
    into a real app module's globals (`_blenderkit_tools.__dict__`); and a
    fake module under Blender's scripts folder. A module, a file name and a
    function's globals are all a script's to make, so only identity is
    left: the callables in every list when the gate first installed itself,
    before any script could run (Blender's bundled handlers and the app's),
    and those the app's own modules name to the gate as they add them
    (`trust`)."""
    if _gate_own(function) or type(function) is _Guarded:
        return True
    return _trusted.get(id(function)) is function


# id -> callable, each kept alive here so its id is never another's.
_trusted = {}
_trusted_taken = False


def trust(function):
    """For the app's own modules (`_blenderkit_budget`'s frame plan,
    `_blenderkit_undo`'s load handlers, `_blenderkit_anim`'s frame
    collectors): `function`, about to be put in a handler list, is the app's
    own and needs no checkpoint after it. Kept by identity. A script that
    calls this reaches into the gate (see the gate's limits in
    docs/blender-local.md)."""
    _trusted[id(function)] = function
    return function


def distrust(function):
    """The app's own `function` taken out of its list again: no longer
    trusted (`_blenderkit_anim`'s collectors are made for each frame)."""
    if _trusted.get(id(function)) is function:
        del _trusted[id(function)]


def _take_trusted():
    """Everything in every handler list at the gate's first `install`, which
    the app makes as it starts (`_blenderkit_context.install`), before any
    script runs: Blender's bundled handlers (Cycles' and the pose library's,
    measured in desktop 5.2.1: `_on_blendfile_load_post` twice and
    `do_versions` in load_post and version_update) and the app's own."""
    global _trusted_taken
    if _trusted_taken:
        return
    _trusted_taken = True
    try:
        handlers = bpy.app.handlers
    except AttributeError:
        return
    for name in dir(handlers):
        items = getattr(handlers, name, None)
        if isinstance(items, list):
            for item in items:
                _trusted[id(item)] = item


def _gate_own(function):
    """Whether `function` is one of the gate's own handlers or entry
    wrappers, by identity (`_OWN_FUNCTIONS`, filled at the end of this
    module)."""
    return any(function is f for f in _OWN_FUNCTIONS)


_OWN_FUNCTIONS = ()


# The checkpoint at a script's handler's own return. Fix round 3 (October
# 29), desktop 5.2.1 with the app's context, the budget lowered to 100,000: a
# depsgraph_update_post handler that took the checkpoint after it out of its
# list (`lst.remove(lst[lst.index(h) + 1])`) and then set an Array's Count of
# 20,000 built 16 → 160,000, because Blender's second pass after the post
# handlers runs no handler (`BKE_scene_graph_update_tagged`); and a
# frame_change_post handler doing the same while adding an Array let frame 30
# through at 160,008, since the frame plan hears of a handler's write only
# through that checkpoint. A list is the script's to change, so the
# checkpoint is also kept where no list operation reaches it: Python itself
# calls it when the handler's code returns or raises (`sys.monitoring`'s
# PY_RETURN, local to that code object, and PY_UNWIND, which Python sends for
# every frame an exception leaves and which is filtered to those code
# objects at once).
#
# The review of that work (fix round 3, October 29) measured three ways
# past it, each in desktop 5.2.1 with the app's context, the budget at
# 100,000 and the handler setting Count 20,000:
#   * A callable with no code of its own — a `functools.partial`, an
#     instance with `__call__` — had nothing watched (its `__code__` was read
#     as an attribute, which a class can also hand out for any code) and kept
#     only the list's checkpoint, which it took out: 160,000 built, each. Such
#     a callable is now wrapped where it stands in its list (`_Guarded`): the
#     wrapper calls it, then the checkpoint, in the wrapper's own code.
#     Blender keeps only a plain function (or a method of one) across a file
#     load (`BPY_app_handlers_reset`, bpy_app_handlers.cc), so a wrapper
#     changes nothing there, and it compares equal to what it wraps, so
#     `remove`, `in` and `index` still find the script's callable. A plain
#     function keeps its identity (a persistent one must stay a function)
#     and is watched, its code read by type (`_handler_code`).
#   * `sys.monitoring.set_local_events(tool, handler.__code__, 0)` from
#     inside the handler, before taking its checkpoint out: 160,000 built.
#     What a script does to Python's own hooks is past the gate (its limits,
#     docs/blender-local.md). Every guard pass sets the tool, its callbacks
#     and its events again (`_watch_again`), and what such a handler built
#     is held at the mirror's pass (`hold_unseen`).
#   * The checkpoint ran at every return of a watched code object: a
#     function that was a handler and also a bpy.props getter a driver read
#     ran the gate's whole `_in_handler` inside Blender's evaluation. Blender
#     calls every callable in these lists with the scene and the depsgraph,
#     or the scene alone where a plain function takes one argument
#     (`bpy_app_generic_callback`, `choose_arguments`), and a getter is
#     called with the struct it belongs to: the arguments are read as the
#     call began (PY_START, `_started`), not at its return, where the
#     handler could have written over them, and a return whose call did not
#     begin so is not a handler's.
_monitor_tool = None
_MONITOR_NAME = 'Blender Local budget checkpoint'
_monitored = {}        # id(code) -> code, for each script handler's code
_started = {}          # id(frame) -> (frame, scene, depsgraph, as Blender calls a handler)
_FunctionType = _types.FunctionType
_MethodType = _types.MethodType
_thread_ident = _threading.get_ident
_MAIN_THREAD = _threading.main_thread().ident


def _take_monitor_tool():
    global _monitor_tool
    monitoring = getattr(sys, 'monitoring', None)
    if monitoring is None:
        return None
    if _monitor_tool is not None:
        try:
            if monitoring.get_tool(_monitor_tool) == _MONITOR_NAME:
                return _monitor_tool
        except ValueError:
            pass
        # Freed, or taken, by a script: every watched code is set again on
        # the tool found next (`_watch_again`).
        _monitor_tool = None
    for tool in (2, 3, 4, 1, 0):
        try:
            if monitoring.get_tool(tool) is None:
                monitoring.use_tool_id(tool, _MONITOR_NAME)
                _monitor_tool = tool
                _register_callbacks(tool)
                return tool
        except ValueError:
            continue
    return None


def _register_callbacks(tool):
    """Ours, again; whether another was there (a script's)."""
    monitoring = sys.monitoring
    events = monitoring.events
    replaced = False
    for event, callback in ((events.PY_START, _on_start), (events.PY_RETURN, _on_return),
                            (events.PY_UNWIND, _on_unwind)):
        before = monitoring.register_callback(tool, event, callback)
        replaced = replaced or (before is not None and before is not callback)
    return replaced


def _handler_code(function):
    """The code object whose return ends a call of `function`: a plain
    function's, or a bound method's function's, read by type — a class can
    give anything a `__code__` attribute. None for anything else."""
    if type(function) is _MethodType:
        function = function.__func__
    if type(function) is _FunctionType:
        return function.__code__
    return None


def _local_events():
    events = sys.monitoring.events
    return events.PY_START | events.PY_RETURN


def _monitor(function):
    """Whether `function`'s returns now run the checkpoint (see the note
    above)."""
    code = _handler_code(function)
    if code is None:
        return False
    if id(code) in _monitored:
        return True
    tool = _take_monitor_tool()
    if tool is None:
        return False
    monitoring = sys.monitoring
    try:
        monitoring.set_local_events(tool, code, _local_events())
        if not _monitored:
            monitoring.set_events(tool, monitoring.events.PY_UNWIND)
    except (ValueError, TypeError):
        return False
    _monitored[id(code)] = code
    return True


def _watch_again():
    """The tool, its callbacks and its events set again, for every watched
    code: a script can take them off (see the note above). Measured cost on
    a guard pass with one watched handler: a few microseconds."""
    if not _monitored:
        return
    monitoring = getattr(sys, 'monitoring', None)
    tool = _take_monitor_tool()
    if monitoring is None or tool is None:
        return
    try:
        if _register_callbacks(tool):
            # A script's callback on our tool may have answered DISABLE for
            # our code; Python keeps that until events are restarted.
            monitoring.restart_events()
        if monitoring.get_events(tool) != monitoring.events.PY_UNWIND:
            monitoring.set_events(tool, monitoring.events.PY_UNWIND)
        wanted = _local_events()
        for code in list(_monitored.values()):
            if monitoring.get_local_events(tool, code) != wanted:
                monitoring.set_local_events(tool, code, wanted)
    except (ValueError, TypeError):
        pass


def _call_arguments(frame, code):
    """The positional values a call of `code` began with, read from its
    frame at PY_START."""
    try:
        values = frame.f_locals
    except (AttributeError, RuntimeError):
        return ()
    names = code.co_varnames
    found = [values.get(name) for name in names[:code.co_argcount]]
    if code.co_flags & 0x04:                   # CO_VARARGS
        extra = values.get(names[code.co_argcount + code.co_kwonlyargcount])
        if isinstance(extra, tuple):
            found.extend(extra)
    return found


def _as_handler(arguments, single=False):
    """(scene, depsgraph) where `arguments` are a handler's as Blender calls
    one — the scene and the depsgraph next to each other (a method's self
    first), or, for a plain function of one argument (`single`), the scene
    alone — else None."""
    for i, value in enumerate(arguments):
        if isinstance(value, bpy.types.Scene):
            following = arguments[i + 1] if i + 1 < len(arguments) else None
            if isinstance(following, bpy.types.Depsgraph):
                return value, following
            if single and len(arguments) == 1:
                return value, None
            return None
    return None


def _handler_arguments(frame):
    """(scene, depsgraph) a handler was called with, read from its frame."""
    scene = depsgraph = None
    try:
        values = list(frame.f_locals.values())
    except (AttributeError, RuntimeError):
        return None, None
    for value in values:
        for item in (value if isinstance(value, tuple) else (value,)):
            if depsgraph is None and isinstance(item, bpy.types.Depsgraph):
                depsgraph = item
            elif scene is None and isinstance(item, bpy.types.Scene):
                scene = item
    return scene, depsgraph


def _off_dispatch(frame):
    """Whether a call that began at `frame` runs on a thread of Blender's own
    with no Python under it: Blender calls the handler lists on the thread
    that asked for the evaluation, which in the app is always running the
    bridge's Python (the main thread or the script's); a driver or a getter
    it evaluates on one of its worker threads has no caller frame. Measured
    in desktop 5.2.1 (the review of fix round 3): a Scene property's getter
    a driver read under an Exact Boolean ran on worker threads as well as
    the main one."""
    return frame.f_back is None and _thread_ident() != _MAIN_THREAD


def _on_start(code, offset):
    if id(code) not in _monitored:
        return
    try:
        frame = sys._getframe(1)
    except ValueError:
        return
    if _off_dispatch(frame):
        found = None
    else:
        found = _as_handler(_call_arguments(frame, code), code.co_argcount == 1)
    if len(_started) > 64:
        _started.clear()
    _started[id(frame)] = (frame, found)


def _checkpoint_at(code):
    if id(code) not in _monitored:
        return
    try:
        frame = sys._getframe(2)
    except ValueError:
        frame = None
    record = _started.pop(id(frame), None)
    if record is not None and record[0] is frame:
        if record[1] is None:
            return                 # not called as Blender calls a handler
        scene, depsgraph = record[1]
    else:
        # Watched only once the call had begun (the guard ran inside it):
        # Blender's own call, the first time round.
        scene, depsgraph = _handler_arguments(frame) if frame is not None else (None, None)
    if _busy:
        return
    try:
        # A list a script cleared is put back first (the gate's own handlers).
        install()
        _checkpoint(scene, depsgraph)
    except Exception as error:                       # noqa: BLE001 - never raised into a handler's return
        _refusals.append((None, "The vertex budget could not price this change (%s), so it was put back."
                          % error))


def _on_return(code, offset, value):
    _checkpoint_at(code)


def _on_unwind(code, offset, error):
    if id(code) in _monitored:
        _checkpoint_at(code)


class _Guarded:
    """A script's callable with no code of its own (a `functools.partial`,
    an instance with `__call__`, a builtin), as it stands in its handler
    list: calls it, then the checkpoint, in this code, which nothing the
    callable does to the list can skip (see the note above). Equal to what
    it wraps, so the script's `remove`, `in` and `index` find it."""

    __slots__ = ('_function', '__weakref__')

    def __init__(self, function):
        object.__setattr__(self, '_function', function)

    def __call__(self, *arguments, **keywords):
        function = object.__getattribute__(self, '_function')
        try:
            return function(*arguments, **keywords)
        finally:
            _guarded_return(arguments)

    def __eq__(self, other):
        function = object.__getattribute__(self, '_function')
        if other is self or other is function:
            return True
        if type(other) is _Guarded:
            return object.__getattribute__(other, '_function') is function
        try:
            return bool(function == other)
        except Exception:                            # noqa: BLE001 - the script's own __eq__
            return False

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        function = object.__getattribute__(self, '_function')
        try:
            return hash(function)
        except TypeError:
            return id(function)

    def __getattr__(self, name):
        return getattr(object.__getattribute__(self, '_function'), name)

    def __repr__(self):
        return repr(object.__getattribute__(self, '_function'))


def _guarded_return(arguments):
    """The checkpoint after a wrapped callable (`_Guarded`): Blender calls
    every such one with the scene and the depsgraph."""
    if _busy:
        return
    try:
        if _off_dispatch(sys._getframe(1)):
            return
    except ValueError:
        pass
    found = _as_handler(list(arguments))
    if found is None:
        return                     # not Blender's call (see `_on_start`)
    scene, depsgraph = found
    try:
        install()
        _checkpoint(scene, depsgraph)
    except Exception as error:                       # noqa: BLE001 - never raised into a handler's return
        _refusals.append((None, "The vertex budget could not price this change (%s), so it was put back."
                          % error))


def _guard_handlers():
    """A checkpoint after every callable of a script's in the four lists
    (and in a load's and an undo's, `_load_checkpoint`), and at each one's own
    return (`_monitor`), or around it where it has no code of its own
    (`_Guarded`). Only inserts, or replaces in place: a list Blender is going
    through may be this one, and an item taken out before where Blender is
    would make it skip the next."""
    try:
        handlers = bpy.app.handlers
    except AttributeError:
        return
    _watch_again()
    for names, point in ((_EVALUATION_LISTS, _checkpoint), (_LOAD_LISTS, _load_checkpoint)):
        for name in names:
            items = getattr(handlers, name, None)
            if items is None:
                continue
            i = 0
            while i < len(items):
                item = items[i]
                if _own(item):
                    i += 1
                    continue
                if point is _checkpoint:
                    if _handler_code(item) is None:
                        # Replaced where it stands: the wrapper keeps it alive
                        # while Blender may be calling it (Blender holds a
                        # borrowed reference to the item it calls).
                        items[i] = _Guarded(item)
                        i += 1
                        continue
                    _monitor(item)
                following = items[i + 1] if i + 1 < len(items) else None
                if following is not point:
                    items.insert(i + 1, point)
                i += 2


def tidy_handlers():
    """The checkpoints left with no script's callable before them (a file
    load drops a script's handlers that are not persistent, and their
    checkpoints stay), taken out. Only from the mirror's pass, which no
    handler list is being gone through around."""
    try:
        handlers = bpy.app.handlers
    except AttributeError:
        return
    for name in _EVALUATION_LISTS + _LOAD_LISTS:
        items = getattr(handlers, name, None)
        if items is None:
            continue
        kept = []
        for item in items:
            if item in (_checkpoint, _load_checkpoint) and (not kept or _own(kept[-1])):
                continue
            kept.append(item)
        if len(kept) != len(items):
            items[:] = kept


_suspended = {}


def _suspend_handlers():
    """A script's handlers out of the four lists while the gate prices."""
    try:
        handlers = bpy.app.handlers
    except AttributeError:
        return
    for name in _EVALUATION_LISTS:
        items = getattr(handlers, name, None)
        if items is None:
            continue
        if any(not _gate_own(item) for item in items):
            _suspended[name] = (items, list(items))
            items[:] = [item for item in items if _gate_own(item)]


def _resume_handlers():
    for name, (items, kept) in list(_suspended.items()):
        items[:] = kept
    _suspended.clear()


def _depsgraphs_of(scene):
    """The depsgraphs of `scene`'s view layers that Blender has made, the
    context's first."""
    found = []
    context_dg = _depsgraph()
    try:
        context_scene = bpy.context.scene
    except AttributeError:
        context_scene = None
    if scene is None or scene == context_scene:
        if context_dg is not None:
            found.append(context_dg)
        if scene is None:
            return found
    try:
        for layer in scene.view_layers:
            dg = layer.depsgraph
            if dg is not None and all(dg != f for f in found):
                found.append(dg)
    except (AttributeError, ReferenceError, RuntimeError):
        pass
    return found


def _in_handler(scene=None, depsgraph=None, frame=False):
    """The gate in a handler: every change waiting in the depsgraph being
    evaluated priced, put back when refused, and the refusal kept for the
    mirror (nothing can be raised here)."""
    if _busy or not _real():
        return
    call = _in_call()
    edit_only = False
    beyond = None
    if call is not None:
        path, priced, proportional, scope = call
        if path in _LOADS:
            # A load re-reads the scene: what it loads is Blender's to
            # evaluate as it was saved. But a script's load_post, undo_post,
            # redo_post or version_update handler runs between the load and
            # this update, and what it wrote is priced (`_since_load`).
            _price_since_load(path)
            return
        # A priced operator was priced from what it was called with, before it
        # ran — except where Edit Mode's points are, which no such price
        # reads: Move, Resize and Mirror are priced for Object Mode only
        # (`price_object_moves`), and moved a curve's, a lattice's or a
        # metaball's points unpriced (see `_diff_edit`'s note) — and except a
        # move with Proportional Editing, which moves objects it was not
        # priced for (see `calling`).
        edit_only = priced and not proportional
        if edit_only and scope is not None:
            # An Object Mode move: everything compared, and priced whole when
            # it moved more than its own price priced (`_within_move`).
            edit_only, beyond = False, scope
        elif edit_only and _object_mode() and path not in _PRICED_WITH_READERS:
            # Any other priced operator in Object Mode: its own price priced
            # the objects it was called on, not what it adds to the scene and
            # what reads that. Fix round 3's review (October 29), sandboxed
            # desktop 5.2.1 with the app's context: G runs Collection Info (C)
            # -> Realize Instances, C holds a 1000 x 1000 grid M; two
            # `object.duplicate_move()` of M took G 1,002,001 -> 2,004,002 ->
            # 3,006,003 with no refusal, the copies joining C (Shift+D, Duplicate
            # Linked and `object.duplicate` alike). Everything is compared and
            # priced as the state it leaves, as a script line's is.
            edit_only = False
    graphs = [depsgraph] if depsgraph is not None else _depsgraphs_of(scene)
    for dg in graphs:
        try:
            # In an operator's own update the change is the operator's, named so.
            refusal = _run(call[0] if call else None, _operator_words(call[0]) if call else None, edit_only,
                           dg=dg, frame=frame, beyond=beyond)[1]
        except Exception as error:                       # noqa: BLE001 - a handler cannot raise
            refusal = "The vertex budget could not price this change (%s), so it was put back." % error
        if refusal is not None:
            _refusals.append((call[0] if call else None, refusal))


def _handler(scene=None, depsgraph=None):
    """`depsgraph_update_pre`: before Blender evaluates what was tagged."""
    global _pre_ran
    _pre_ran = True
    if _busy or not _real():
        return
    # A script's handlers further down this list (or in the post list) get a
    # checkpoint before Blender reaches them.
    _guard_handlers()
    _in_handler(scene, depsgraph)


def _frame_pre(scene=None, depsgraph=None):
    """`frame_change_pre`: before Blender evaluates a frame. The frame itself
    is read after this list has run (`BKE_scene_frame_get` in pass 0 of
    `BKE_scene_graph_update_for_newframe_ex`), so a refused frame is put
    back here and Blender evaluates the one it had (measured in desktop
    5.2.1: `frame_set(10)` with a handler here writing `frame_current = 1`
    left a keyed Count at frame 1's value, 16 vertices)."""
    global _pre_ran
    _pre_ran = True
    if _busy or not _real():
        return
    _guard_handlers()
    _in_handler(scene, depsgraph, frame=True)


def _frame_post(scene=None, depsgraph=None):
    """`frame_change_post`: the frame the timeline priced is evaluated; the
    next one is priced again."""
    global _frame_ok
    if not _busy:
        _frame_ok = None


# Whether the gate's own `_handler` or `_frame_pre` ran since the last
# depsgraph_update_post: Blender runs both lists for an evaluation or
# neither (`BKE_scene_graph_update_tagged`'s `run_callbacks`), so a post with
# no pre before it is an evaluation a script made after taking the gate's
# handler out of its list — and asking for it through the base type's own
# `__getattribute__`, past the entries' wrappers (`before_evaluation`), which
# put the handler back. Fix round 3 (October 29), desktop 5.2.1 with the
# app's context, the budget lowered to 100,000: `depsgraph_update_pre.clear()`,
# an offset object moved, then `bpy.types.bpy_struct.__getattribute__(
# view_layer, 'update')()` built 328 → 3,200,008 with no refusal, and the
# mirror's pass then carried it (an object past the budget can be changed in
# ways that do not make it heavier). Nothing in Python runs between that
# clear and Blender's evaluation, so the build itself is not prevented (still
# open); what it built is held at once (`_unpriced`).
_pre_ran = False


def _unpriced(depsgraph):
    """After an evaluation no price came before: the gate's handlers put
    back, and every object it updated past the budget has the modifiers that
    make more hidden, which Blender's own second pass then evaluates lighter,
    and the refusal is kept for the mirror."""
    install()
    if depsgraph is None:
        return
    budget = _budget()
    held = []
    try:
        updated = [update.id for update in depsgraph.updates]
    except (AttributeError, ReferenceError, RuntimeError):
        return
    for copy in updated:
        if type(copy).__name__ != 'Object':
            continue
        try:
            obj = _original(copy, depsgraph)
            if obj is None or obj.type not in budget.COUNTED_TYPES:
                continue
            if obj.type == 'MESH':
                count = len(copy.data.vertices)
            elif obj.type == 'CURVES':
                count = len(copy.data.points)
            else:
                mesh = copy.to_mesh()
                try:
                    count = len(mesh.vertices) if mesh is not None else 0
                finally:
                    copy.to_mesh_clear()
        except (AttributeError, ReferenceError, RuntimeError, TypeError):
            continue
        if count <= budget.BUDGET:
            continue
        for m in obj.modifiers:
            if m.show_viewport and m.type not in budget._KEEPS_TOPOLOGY:
                m.show_viewport = False
        held.append("%s (%s vertices)" % (obj.name, format(count, ',')))
    if held:
        _refusals.append((None, "Blender evaluated %s with the vertex budget's own handler taken out of "
                                "depsgraph_update_pre, so nothing priced it first, past this app's %s. Its "
                                "modifiers that make more are hidden in the viewport until it is lighter."
                          % (", ".join(held), format(budget.BUDGET, ','))))


# What Blender holds, held to what the gate let through, at every mirror's
# pass (`_blenderkit_sync.sync`, which no script can take out of the app's
# own run). The review of fix round 3 (October 29) measured, in desktop
# 5.2.1 with the app's context and the budget at 100,000: a script line that
# cleared depsgraph_update_post as well as depsgraph_update_pre, set an
# Array's Count of 20,000 and called `bpy.types.bpy_struct.__getattribute__(
# view_layer, 'update')()` had Blender build 160,000 with no refusal, and a
# later move of the object passed, Blender still at 160,000 (`_unpriced`
# runs from the post handler the line had cleared); and a handler that
# switched `sys.monitoring` off for its own code before taking out its
# checkpoint built the same. Nothing in Python stands between such a call
# and Blender's evaluation, so what it builds is not refused before; it is
# held here, after: an object Blender holds past the budget and past the
# most it was let hold (`_allowed`: what it held as the app opened its
# file, or the budget) has the modifiers that make more hidden in the
# viewport, and where its own data is heavy already, or its kind cannot be
# told, it is taken out of the scene (it stays in bpy.data.objects). Every
# depsgraph Blender has made is read, so a view layer evaluated for the
# first time through the same call (S2's X at 160,000) is held too. No
# price lets an object grow past the budget (an object past it may only
# change in ways that do not make it heavier), so nothing the gate passed
# is held. Keyed by `session_uid`, which Blender keeps across undo.
_allowed = {}          # session_uid -> the most vertices the object may hold
_baseline_next = True  # the next pass takes what Blender holds as allowed


def _held_by_copy(copy, obj):
    """The vertices (points, for hair curves and Grease Pencil) Blender
    holds in `copy`, the evaluated `obj`, evaluating nothing; None where it
    cannot be told."""
    kind = obj.type
    if kind == 'MESH':
        return len(copy.data.vertices)
    if kind == 'CURVES':
        return len(copy.data.points)
    if kind == 'GREASEPENCIL':
        n = 0
        for layer in copy.data.layers:
            frame = layer.current_frame()
            if frame is not None and frame.drawing is not None:
                n += len(frame.drawing.attributes['position'].data)
        return n
    if kind in ('CURVE', 'SURFACE', 'FONT', 'META'):
        mesh = copy.to_mesh()
        try:
            return len(mesh.vertices) if mesh is not None else 0
        finally:
            copy.to_mesh_clear()
    return None


def _all_depsgraphs():
    found = []
    try:
        for scene in bpy.data.scenes:
            for layer in scene.view_layers:
                dg = layer.depsgraph
                if dg is not None and all(dg != f for f in found):
                    found.append(dg)
    except (AttributeError, ReferenceError, RuntimeError):
        pass
    return found


def _held_everywhere(budget):
    """(object, session_uid, vertices, depsgraph) for every counted object
    in every depsgraph Blender has made, evaluating nothing. From the live
    originals to their copies, never a copy's `original`: a depsgraph
    Blender has not rebuilt since an object was freed still lists its copy,
    whose original is freed memory. Measured: reading `copy.original` over
    `dg.ids` crashed (SIGSEGV) in the freed-memory check's window_scene_set case
    (pyrna_prop_to_py), the first time this pass ran it."""
    try:
        objects = [o for o in bpy.data.objects if o.type in budget.COUNTED_TYPES]
    except (AttributeError, ReferenceError, RuntimeError):
        return
    for dg in _all_depsgraphs():
        for obj in objects:
            try:
                copy = obj.evaluated_get(dg)
                if copy == obj or _shell(copy):
                    continue
                count = _held_by_copy(copy, obj)
                key = obj.session_uid
            except (AttributeError, ReferenceError, RuntimeError, TypeError, KeyError):
                continue
            if count is not None:
                yield obj, key, count, dg


def _take_as_allowed():
    """What Blender holds now is allowed (`hold_unseen`): at the end of a
    load the app makes and Blender evaluates as saved (`opening`), before
    anything else in the same run can build, and at the first pass."""
    global _baseline_next
    if _busy or not _real():
        _baseline_next = True      # taken at the next pass instead
        return
    _baseline_next = False
    budget = _budget()
    _allowed.clear()
    for obj, key, count, dg in _held_everywhere(budget):
        _allowed[key] = max(_allowed.get(key, budget.BUDGET), count)


def hold_unseen():
    """See the note above. Returns whether anything was held (the mirror
    then asks Blender for the scene again)."""
    if _busy or not _real():
        return False
    if _baseline_next:
        _take_as_allowed()
        return False
    budget = _budget()
    limit = budget.BUDGET
    held = {}
    graphs = []            # the depsgraphs that hold what is held
    for obj, key, count, dg in _held_everywhere(budget):
        if count > _allowed.get(key, limit):
            held[key] = (obj, max(count, held.get(key, (None, 0))[1]))
            if all(dg != g for g in graphs):
                graphs.append(dg)
    if not held:
        return False
    hidden, out = [], []
    for obj, count in held.values():
        try:
            shown = [m for m in obj.modifiers if m.show_viewport and m.type not in budget._KEEPS_TOPOLOGY]
            for m in shown:
                m.show_viewport = False
            if obj.type == 'MESH':
                own = len(obj.data.vertices)
            elif obj.type == 'CURVES':
                own = len(obj.data.points)
            else:
                own = None
            if own is None and shown:
                # A curve's, a text's or a metaball's own: told only by
                # evaluating it, which is what is being held off.
                own = limit + 1
            if obj.mode != 'OBJECT':
                # Another mode's object is not taken out from under it (as
                # `_blenderkit_budget._left_over` leaves it): its modifiers
                # hidden is all.
                hidden.append("%s (%s)" % (obj.name, format(count, ',')))
            elif own is not None and own > limit or not shown:
                for collection in list(obj.users_collection):
                    if obj.name in collection.objects:
                        collection.objects.unlink(obj)
                out.append("%s (%s)" % (obj.name, format(count, ',')))
            else:
                hidden.append("%s (%s)" % (obj.name, format(count, ',')))
        except (AttributeError, ReferenceError, RuntimeError, TypeError):
            continue
    notes = []
    if hidden:
        notes.append("the modifiers of %s that make more are hidden in the viewport until it is lighter"
                     % ", ".join(hidden))
    if out:
        notes.append("%s %s taken out of the scene (still in bpy.data.objects)"
                     % (", ".join(out), "was" if len(out) == 1 else "were"))
    if notes:
        _refusals.append((None, "Blender evaluated past this app's %s vertices with nothing priced first (a "
                                "script reached Blender's evaluation past the vertex budget's handlers): %s."
                          % (format(limit, ','), "; ".join(notes))))
    # Evaluated again, lighter, so Blender lets go of what it built: the
    # context's by the mirror itself, any other view layer's here (measured:
    # S2's X stayed at 160,000 in S2's depsgraph until its layer was
    # evaluated again).
    try:
        context_layer = bpy.context.view_layer
    except AttributeError:
        context_layer = None
    for dg in graphs:
        try:
            layer = dg.view_layer
            if layer is not None and layer != context_layer:
                layer.update()
        except (AttributeError, ReferenceError, RuntimeError):
            continue
    return True


def _checkpoint(scene=None, depsgraph=None):
    """After a script's own handler (see the note above): what it wrote,
    priced before Blender evaluates it."""
    if _busy or not _real():
        return
    _in_handler(scene, depsgraph)


def _post(scene=None, depsgraph=None, *_):
    global _object_count
    # What Edit Mode's curves and lattices hold is what any evaluation of them
    # evaluated, the gate's own included (their copies share it), so it is
    # taken whoever asked: a test's control, which evaluates with the gate
    # off, left the curve it had shrunk waiting as a change once this ran only
    # outside the gate (the budget check, 9.5c).
    try:
        _refresh_edit(depsgraph)
    except (AttributeError, ReferenceError, RuntimeError, TypeError):
        _edit_snaps.clear()
    if _edit_mesh_states:
        editing = {o.data.as_pointer() for o in _edited_meshes()}
        for p in [p for p in _edit_mesh_states if p not in editing]:
            del _edit_mesh_states[p]
    for obj in _note_edit_meshes():
        # Just in Edit Mode: what Blender has just built its edit mesh from,
        # kept as what it evaluated, so leaving with nothing changed is no
        # change to price (`_diff_left_edit`), nor is a script's first bmesh
        # edit priced against nothing (`_edited_mesh_structs`).
        try:
            mesh = obj.data
            if mesh.as_pointer() not in _edit_mesh_states and _grows_from_cage(mesh):
                _edit_mesh_states[mesh.as_pointer()] = _entry_state(obj)
        except (AttributeError, ReferenceError, RuntimeError, TypeError):
            continue
    if _busy:
        return
    global _pre_ran
    if not _pre_ran and _real():
        # Blender evaluated with the gate's own handler out of
        # depsgraph_update_pre (see `_unpriced`).
        _unpriced(depsgraph)
    _pre_ran = False
    _images_touched.clear()
    global _accepted, _accepted_animated, _frame_ok
    _approved.clear()
    _accepted = None
    _accepted_animated = None
    _frame_ok = None
    try:
        _object_count = len(bpy.data.objects)
    except AttributeError:
        pass


# The view layers whose depsgraph Blender may build fresh without the gate
# pricing all of it: the context's, as a file load, an undo or the app's
# start left it. What the app opens is Blender's to evaluate as it was saved
# (an object already past the budget can still be changed in ways that do
# not make it heavier). Any other view layer a script makes Blender evaluate
# for the first time — another scene's, a second view layer — is priced
# whole first (`pending`, `_fresh`).
_loaded_layers = set()


def _note_loaded(*_):
    try:
        layer = bpy.context.view_layer
        if layer is not None:
            _loaded_layers.add(layer.as_pointer())
    except (AttributeError, ReferenceError, RuntimeError):
        layer = None
    _price_script_load(layer)
    _snapshot_load()


# The file loads a script makes. What the app opens — the Open sheet, the
# recovery file at launch, File ▸ New, the history's and the undo's own
# checkpoints — is Blender's to evaluate as it was saved (`opening`). A file
# a script loads is the script's state: fix round 3 (October 29), desktop
# 5.2.1 with the app's context, the budget lowered to 100,000, a script line
# made a scene holding X under an Array of 20,000, wrote it with
# `bpy.data.libraries.write`, and `wm.open_mainfile` on it then built X at
# 160,000 with no refusal (`_LOADS` are not priced, and Blender evaluates the
# new file inside the load, `wm_file_read_post` → `wm_event_do_depsgraph`,
# right after load_post, on a depsgraph it builds fresh with no handler). So
# load_post, the last Python before that evaluation, prices everything the
# new file's view layer would evaluate as new (`_fresh`); refused, what
# makes more is held as any change no value puts back (`_judge`), and the
# words are kept for the mirror.
_FILE_LOADS = frozenset(('wm.open_mainfile', 'wm.revert_mainfile', 'wm.read_homefile', 'wm.read_factory_settings',
                         'wm.recover_last_session', 'wm.recover_auto_save'))
_own_loads = 0
_opening = []          # the app's own loads under way that are priced: the words for each


# The files the app writes and then opens itself — an undo step kept as a
# file, the history's checkpoints, the recovery file — are files a script
# can write too. The review of fix round 3 (October 29) measured it in
# desktop 5.2.1 with the app's context, the history in checkpoint files as
# `BackendHistory` asks for them, the budget at 100,000: one Run line wrote a
# scene S2 holding X under an Array of 20,000 with `bpy.data.libraries.write`
# and copied it over every .blend in the history folder (found with
# `os.listdir`); the next push and `undo.step(-1)` opened it as the app's own
# and Blender built X at 160,000 with no refusal — one Run and one tap of
# Undo. So the app's own open of such a file stands aside only while the
# file is exactly as the app wrote it (`vouch`): its device, inode, size,
# modification time and status-change time, the last of which only the
# system sets (a write, a rename over it or `os.utime` each move it to now).
# Otherwise it is priced as a script's load is. The app writes them with a
# script's save handlers out of their lists (`saving`), so nothing but
# Blender writes what is vouched for.
_vouched = {}          # real path -> (device, inode, size, mtime_ns, ctime_ns)


def _file_key(path):
    import os
    st = os.stat(path)
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def vouch(path):
    """`path` is a file the app has just written itself (see the note
    above)."""
    import os
    try:
        _vouched[os.path.realpath(path)] = _file_key(path)
    except (OSError, TypeError, ValueError):
        pass


def vouched(path):
    """Whether `path` is still exactly as the app wrote it."""
    import os
    try:
        real = os.path.realpath(path)
        return _vouched.get(real) is not None and _vouched[real] == _file_key(path)
    except (OSError, TypeError, ValueError):
        return False


def forget(path):
    import os
    try:
        _vouched.pop(os.path.realpath(path), None)
    except (TypeError, ValueError):
        pass


_SAVE_LISTS = ('save_pre', 'save_post', 'save_post_fail')


class saving:
    """Around a file the app writes itself (see the note above): a script's
    callables out of the save lists meanwhile — a save_post handler is
    called after Blender has written the file and before the app could
    vouch for it — and back after."""

    def __enter__(self):
        self._kept = []
        try:
            handlers = bpy.app.handlers
        except AttributeError:
            return self
        for name in _SAVE_LISTS:
            items = getattr(handlers, name, None)
            if items is not None and any(not _own(item) for item in items):
                self._kept.append((items, list(items)))
                items[:] = [item for item in items if _own(item)]
        return self

    def __exit__(self, *exc):
        for items, kept in self._kept:
            items[:] = kept
        return False


class opening:
    """Around a load the app makes itself (see `_FILE_LOADS`): Blender's to
    evaluate as saved — the Open sheet's choice, with no `path` — or, for a
    file the app wrote itself, `path`, only while it is as the app wrote it
    (`vouched`); otherwise, or with `priced` (File ▸ New's startup file,
    which the app never writes, and a recovery file that changed since the
    app wrote it, `RecoveryRecord.swift`), priced as a script's load, in
    `words`."""

    def __init__(self, path=None, words=None, priced=False):
        self.path = path
        self.words = words
        self.priced = priced

    def __enter__(self):
        global _own_loads
        import os
        self.trusted = not self.priced and (self.path is None or vouched(self.path))
        if self.trusted:
            _own_loads += 1
        else:
            _opening.append(self.words or ("Opening %s, which changed after this app wrote it,"
                                           % os.path.basename(str(self.path or 'this file'))))
        return self

    def __exit__(self, *exc):
        global _own_loads
        if self.trusted:
            _own_loads -= 1
            # What Blender holds now is the file's, as saved (`hold_unseen`):
            # taken here, right after the load, so nothing a script builds
            # later in the same run is taken with it.
            try:
                _take_as_allowed()
            except Exception:                        # noqa: BLE001 - a load the app made stands
                pass
        else:
            _opening.pop()
        return False


def _price_script_load(layer):
    call = _in_call()
    if call is None or call[0] not in _FILE_LOADS or _own_loads or _busy or layer is None or not _real():
        return
    words = _opening[-1] if _opening else "Loading this file from a script"
    try:
        found = _fresh(layer)
        if not found:
            return
        with _Busy():
            refusal = _judge(found, words)
    except Exception as error:                       # noqa: BLE001 - a handler cannot raise
        refusal = "The vertex budget could not price this change (%s), so it was put back." % error
    if refusal is not None:
        # The app's own load is not refused at its call (the history's index,
        # the launch, File ▸ New go on with what was held): the mirror's pass
        # after it says it. A script's load is refused at its line.
        _refusals.append((None if _opening else call[0], refusal))


# What a load left, before a script's handlers in the same load write to it.
# Blender runs a file's version_update and then its load_post handlers (and
# an undo's undo_post or redo_post) after the file has replaced the scene and
# before the load operator's own update evaluates it, which the gate does not
# price (`_LOADS`). A script's persistent handler in one of those lists, say
# writing an Array's Count of 400,000, was evaluated there unpriced. So when
# a script has a callable in one of them, the gate's own first callable in
# them takes a fingerprint of every object (`_fingerprint`) before the
# script's run, and the load's update prices whatever differs
# (`_price_since_load`). With no script's handler in them, nothing is taken.
_LOAD_LISTS = ('version_update', 'load_post', 'undo_post', 'redo_post')
_load_snapshot = None
_load_taken = False


def _scripts_in(names):
    try:
        handlers = bpy.app.handlers
    except AttributeError:
        return False
    for name in names:
        for item in getattr(handlers, name, ()):
            if not _own(item):
                return True
    return False


def _snapshot_load(again=False):
    global _load_snapshot, _load_taken
    if _load_taken and not again:
        return
    _load_taken = True
    if not _scripts_in(_LOAD_LISTS):
        _load_snapshot = None
        return
    found = {}
    try:
        for obj in bpy.data.objects:
            try:
                found[obj.as_pointer()] = _fingerprint(obj)
            except (AttributeError, ReferenceError, RuntimeError):
                continue
    except (AttributeError, RuntimeError):
        found = None
    _load_snapshot = found


def _note_version(*_):
    """`version_update` (before load_post): the load's fingerprint taken
    before a script's version_update handler runs."""
    _snapshot_load()


def _note_load_pre(*_):
    global _load_taken
    _load_taken = False


def _note_undo_pre(*_):
    global _load_taken
    _load_taken = False


def _load_checkpoint(*_):
    """After a script's callable in a load's or an undo's lists: what it
    wrote, priced at once (`_price_since_load`), and the fingerprint taken
    again for the next one. Measured in desktop 5.2.1: the load operator's
    own update, where the handlers would have priced it, runs no handler on
    the new file's depsgraph (Blender builds it fresh)."""
    if _busy or not _real():
        return
    _price_since_load('a script\'s handler in the load', keep=True)


def _price_since_load(path, keep=False):
    """Every object a script's handler changed or added since the load's
    fingerprint, priced as new — over the budget alone, its modifiers stay
    hidden — and the refusal kept for the mirror. `keep`: the fingerprint is
    taken again after (a checkpoint), else let go (the load's own update)."""
    global _load_snapshot, _load_taken
    snapshot, _load_snapshot = _load_snapshot, None
    if not keep:
        _load_taken = False
    if not snapshot or _busy or not _real():
        if keep:
            _snapshot_load(again=True)
        return
    found = Pending()
    for obj in bpy.data.objects:
        try:
            p = obj.as_pointer()
            if snapshot.get(p) != _fingerprint(obj):
                found.structs.append(Struct('new', obj))
        except (AttributeError, ReferenceError, RuntimeError):
            continue
    if found:
        try:
            with _Busy():
                refusal = _judge(found, _operator_words(path) if '.' in path and ' ' not in path
                                 else "What a script's handler wrote as the file loaded")
        except Exception as error:                   # noqa: BLE001 - a handler cannot raise
            refusal = "The vertex budget could not price this change (%s), so it was put back." % error
        if refusal is not None:
            _refusals.append((None, refusal))
    if keep:
        _snapshot_load(again=True)


def _persistent(function):
    try:
        from bpy.app.handlers import persistent
        function = persistent(function)
    except (ImportError, AttributeError):
        pass                                 # the simulator's stand-in
    function._blenderkit_gate = True
    return function


_handler = _persistent(_handler)
_frame_pre = _persistent(_frame_pre)
_frame_post = _persistent(_frame_post)
_checkpoint = _persistent(_checkpoint)
_post = _persistent(_post)
_note_loaded = _persistent(_note_loaded)
_note_version = _persistent(_note_version)
_note_load_pre = _persistent(_note_load_pre)
_note_undo_pre = _persistent(_note_undo_pre)
_load_checkpoint = _persistent(_load_checkpoint)
_checkpoint._blenderkit_checkpoint = True
_OWN_FUNCTIONS = (_handler, _frame_pre, _frame_post, _checkpoint, _post, _note_loaded, _note_version,
                  _note_load_pre, _note_undo_pre, _load_checkpoint)

_OWN_HANDLERS = (('depsgraph_update_pre', _handler), ('frame_change_pre', _frame_pre),
                 ('depsgraph_update_post', _post), ('frame_change_post', _frame_post), ('load_post', _note_loaded),
                 ('undo_post', _note_loaded), ('redo_post', _note_loaded), ('version_update', _note_version),
                 ('load_pre', _note_load_pre), ('undo_pre', _note_undo_pre), ('redo_pre', _note_undo_pre))
# Of those, the ones that must run before a script's callable in the same
# list: put first (`install`).
_FIRST = frozenset(('load_post', 'undo_post', 'redo_post', 'version_update'))


# --------------------------------------------------------------------------
# The evaluations a script can ask for
#
# A script makes Blender evaluate with `bpy.context.evaluated_depsgraph_get()`,
# `ViewLayer.update()`, `Depsgraph.update()` and `Scene.frame_set()`, and an
# operator's call evaluates before and after it (`_calling`). A depsgraph
# Blender builds fresh — another scene's, a second view layer's — evaluates
# with no handler at all, and a script can take the gate's handlers out of
# their lists. So each of those calls asks the gate first, for the view
# layer it is about to evaluate (`before_evaluation`): read through
# `__getattribute__` on Blender's own types, as `_blenderkit_context` reads
# `bpy.context`, because Blender finds an RNA function before anything set
# on the type (`pyrna_struct_getattro`).

_ENTRIES = {'ViewLayer': ('update',), 'Depsgraph': ('update',), 'Scene': ('frame_set',)}


def before_evaluation(owner, name, args=(), keywords=None):
    """Called before Blender evaluates for a script: the gate's handlers put
    back, and the view layer about to be evaluated priced (refused changes
    put back, the words kept for the mirror, as a handler keeps them). A
    script's `frame_set` is priced from what the frame's animation sets, and
    refused in words before it runs."""
    if _busy or not _real():
        return
    install()
    try:
        if name == 'frame_set':
            _before_frame_set(owner, args, keywords or {})
            return
        if isinstance(owner, bpy.types.Depsgraph):
            waiting, refusal = _run(None, dg=owner)
        elif isinstance(owner, bpy.types.Context):
            waiting, refusal = _run(None, layer=owner.view_layer)
        else:
            waiting, refusal = _run(None, layer=owner)
    except RuntimeError:
        raise
    except Exception as error:                       # noqa: BLE001 - said, not lost
        refusal = "The vertex budget could not price this change (%s), so it was put back." % error
    if refusal is not None:
        _refusals.append((None, refusal))


def _before_frame_set(scene, args, keywords):
    """`scene.frame_set(frame, subframe=0.0)` from a script: what the frame
    sets priced first (`_blenderkit_budget.price_frame`), and refused in
    words, with the frame left where it was. Round 4's fix round 2 review:
    a script's `frame_set(10)`, a key of 400,000 there, made 3,200,000."""
    frame = args[0] if args else keywords.get('frame')
    subframe = args[1] if len(args) > 1 else keywords.get('subframe', 0.0)
    try:
        frame = int(frame)
        subframe = float(subframe or 0.0)
    except (TypeError, ValueError):
        return                                   # Blender's own argument error
    try:
        context_scene = bpy.context.scene
    except AttributeError:
        context_scene = None
    # Whatever the script wrote first, priced first.
    waiting, refusal = _run(None)
    if refusal is not None:
        _refusals.append((None, refusal))
    if scene != context_scene:
        return             # its depsgraphs are priced as they evaluate (`_frame_pre`)
    if _frame_approved((scene, frame + subframe)):
        return             # the timeline priced it just now (`price_frame`)
    _budget().price_frame(frame, subframe)


def _wrap_entry(owner, name, function):
    def call(*args, **keywords):
        before_evaluation(owner, name, args, keywords)
        return function(*args, **keywords)
    call.__name__ = name
    call.__doc__ = getattr(function, '__doc__', None)
    return call


def _install_entries():
    """`before_evaluation` in front of each of `_ENTRIES`, once per type."""
    struct = getattr(bpy.types, 'bpy_struct', None)
    if struct is None:
        return
    base = struct.__getattribute__
    for type_name, names in _ENTRIES.items():
        cls = getattr(bpy.types, type_name, None)
        if cls is None or _gate_own(cls.__dict__.get('__getattribute__')):
            continue

        def getattribute(self, name, _names=names, _base=base):
            found = _base(self, name)
            if name in _names and not _busy:
                return _wrap_entry(self, name, found)
            return found
        getattribute._blenderkit_gate = True
        cls.__getattribute__ = getattribute
        global _OWN_FUNCTIONS
        _OWN_FUNCTIONS = _OWN_FUNCTIONS + (getattribute,)


def install():
    """The gate's handlers in their lists, put back wherever one is missing
    (a script can clear a list), with a checkpoint after each callable of a
    script's (`_guard_handlers`); and the evaluations a script can ask for,
    priced before Blender makes them (`before_evaluation`). Called before
    every price and every evaluation the gate hears of, so cheap: a look at
    six short lists."""
    global _installed
    if not _real():
        return False
    try:
        handlers = bpy.app.handlers
    except AttributeError:
        return False
    # Before the gate's own go in, and before any script has run (see `_own`).
    _take_trusted()
    for name, function in _OWN_HANDLERS:
        items = getattr(handlers, name, None)
        if items is None:
            continue
        if not any(item is function for item in items):
            if name in _FIRST:
                items.insert(0, function)
            else:
                items.append(function)
    _guard_handlers()
    if not _installed:
        _note_loaded()
        _install_entries()
        _install_images()
    _installed = True
    return True
