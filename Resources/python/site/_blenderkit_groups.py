"""Vertex groups and shape keys: what the Data tab shows and what its controls
do, as Blender's Object Data tab has them.

`record` reads a mesh's groups and keys for the interface (`push` hands it
over through `_blenderkit.sync_groups`); every other function is one control
of the two panels, held to the conditions Blender's own buttons are, and
refusing in words where Blender would do nothing without saying so.

Everything below was measured in desktop Blender 5.2.1 under
`-b --factory-startup`, with an undo stack as the app has one
(scripts/run-groups-blender-check.sh):

  * `object.vertex_group_assign`, `_remove_from`, `_select` and `_deselect`
    run headless in Edit Mode and fail their poll in Object Mode. They act on
    the ACTIVE group, so each control names its group and makes it active
    first: a stale index can never act on another group than the one shown.
    Assign takes its weight from `tool_settings.vertex_group_weight`.
  * With nothing selected Assign returns FINISHED and Remove CANCELLED,
    both changing nothing and saying nothing; here both say so. On a locked
    group both fail their poll, which Blender words as "Operator
    bpy.ops.object.vertex_group_assign.poll() The active vertex group is
    locked"; here the refusal names the group instead. With no group at all
    Blender raises "No active vertex group to operate on" itself.
  * `VertexGroup.add()` refuses Edit Mode ("cannot be called while object is
    in edit mode"), which is why the operators are used, not the RNA.
  * `object.shape_key_add` and `_remove` fail their poll in Edit Mode, where
    Blender's own + and - are greyed out; here they say so. The first key
    added is Basis.
  * In Edit Mode the mesh being edited IS the active shape key, at full
    strength whatever its value: with Key 1 active, a cube whose Key 1 top is
    at z = 2 read z = 2 in the edit mesh and in the evaluated mesh at value
    0.5, and a move of +0.3 in x changed Key 1 (x max 1.3) and left Basis
    (x max 1.0). Changing the active key in Edit Mode reloads the edit mesh
    with that key (`rna_Object_active_shape_update`), keeping what was edited.
  * A key's value is clamped to its slider range (1.5 set with a maximum of
    1.0 read back 1.0), so the interface clamps its draft the same way.
  * Undo: in Object Mode every control here is taken back by one Undo; in
    Edit Mode the group controls and the active key are, and nothing else.
    The Weight field is a scene tool setting no undo step holds (0.4 set,
    undone: still 0.4), and the edit-mesh undo step holds the mesh and none of
    the Key's settings or the object's two switches: value, range, mute, lock,
    relative key, vertex group, name, Relative, Shape Key Lock and Edit Mode
    each stayed changed after Undo in Edit Mode. The interface pushes no step
    for those, as the mirror row does for the symmetry flags.
  * A modifier's `vertex_group` set to a name that is not a group reads back
    '' (Blender clears it); the panel only offers the object's groups.
"""

import bpy

Refusal = RuntimeError

# Vertex groups whose members are counted for the panel, at most: counting is
# a Python walk of every vertex's groups, 60 ms for 100,489 vertices in three
# groups in desktop 5.2.1 on this Mac (0.74 ms for 2,025). Only the active
# object is counted, in a pass that runs after every command.
COUNT_LIMIT = 20000

# The record's separators, escaped inside a value — the same table as
# `_blenderkit_sync._RECORD_ESCAPES`, read by `Modifier.fields` in Swift.
# Blender lets a group or a key be called anything.
_ESCAPES = (('%', '%25'), (';', '%3B'), ('|', '%7C'), ('=', '%3D'), ('\n', '%0A'))


def _value(value):
    if isinstance(value, bool):
        return '1' if value else '0'
    if isinstance(value, (int, float)):
        return repr(float(value))
    text = str(value)
    for raw, escaped in _ESCAPES:
        text = text.replace(raw, escaped)
    return text


def _entry(pairs):
    return ';'.join(k + '=' + _value(v) for k, v in pairs)


def counts(obj):
    """How many vertices each vertex group of `obj` holds, by index, or None
    past `COUNT_LIMIT`. Read from the mesh, so in Edit Mode only after
    `update_from_editmode` (the mirroring pass does that first)."""
    data = obj.data
    if len(data.vertices) > COUNT_LIMIT:
        return None
    found = [0] * len(obj.vertex_groups)
    for vertex in data.vertices:
        for element in vertex.groups:
            if element.group < len(found):
                found[element.group] += 1
    return found


def record(obj, with_counts=False):
    """`kind=head;…|kind=group;…|kind=key;…`: the object's vertex groups and
    shape keys as the Data tab shows them. Counts only when asked for."""
    groups = obj.vertex_groups
    keys = getattr(obj.data, 'shape_keys', None)
    blocks = list(keys.key_blocks) if keys is not None else []
    tool = bpy.context.scene.tool_settings
    head = [('kind', 'head'), ('active_group', groups.active_index),
            ('weight', tool.vertex_group_weight),
            ('active_key', obj.active_shape_key_index if blocks else -1),
            ('use_relative', keys.use_relative if keys is not None else True),
            ('reference', keys.reference_key.name if keys is not None and keys.reference_key else ''),
            ('show_only', obj.show_only_shape_key),
            ('key_edit_mode', obj.use_shape_key_edit_mode)]
    found = counts(obj) if with_counts and len(groups) else None
    if with_counts and len(groups) and found is None:
        head.append(('counted', False))
    entries = [_entry(head)]
    for group in groups:
        pairs = [('kind', 'group'), ('name', group.name), ('lock', group.lock_weight)]
        if found is not None:
            pairs.append(('count', found[group.index]))
        entries.append(_entry(pairs))
    for key in blocks:
        relative = key.relative_key
        entries.append(_entry([
            ('kind', 'key'), ('name', key.name), ('value', key.value),
            ('min', key.slider_min), ('max', key.slider_max),
            ('relative', relative.name if relative is not None else ''),
            ('mute', key.mute), ('lock', getattr(key, 'lock_shape', False)),
            ('vertex_group', key.vertex_group)]))
    return '|'.join(entries)


def push(obj, during_pass=True, with_counts=False):
    """Hands the interface the record of one mesh: during a pass onto the
    object the pass just pushed, otherwise onto the one on screen."""
    if obj is None or obj.type != 'MESH':
        return
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_groups', None)
    if send is None:
        return
    send(obj.name, record(obj, with_counts), 1 if during_pass else 0)


# ---------------------------------------------------------------------------
# What every control needs

def _object(name, modes=('OBJECT', 'EDIT'), active=False):
    """The mesh `name`, in one of `modes`, refused in words otherwise.

    Two modes, not every mode: Blender allows several of these in Sculpt and
    the paint modes too, and none of those paths has been run headless with
    the app's context, so they are refused rather than discovered."""
    obj = bpy.data.objects.get(name)
    if obj is None:
        raise Refusal("There is no object called " + repr(name) + ".")
    if obj.type != 'MESH':
        raise Refusal(obj.name + " is not a mesh: vertex groups and shape keys here are a mesh's.")
    if obj.mode not in modes:
        where = ' or '.join(m.title() + ' Mode' for m in modes)
        raise Refusal("This works in " + where + "; " + obj.name + " is in "
                      + obj.mode.replace('_', ' ').title() + " Mode.")
    if active and bpy.context.view_layer.objects.active != obj:
        raise Refusal(obj.name + " is not the active object.")
    return obj


def _group(obj, name):
    group = obj.vertex_groups.get(name)
    if group is None:
        raise Refusal(obj.name + " has no vertex group called " + repr(name) + ".")
    return group


def _key(obj, name):
    keys = obj.data.shape_keys
    block = keys.key_blocks.get(name) if keys is not None else None
    if block is None:
        raise Refusal(obj.name + " has no shape key called " + repr(name) + ".")
    return block


def _finished(result, refusal):
    if 'FINISHED' not in result:
        raise Refusal(refusal)


# ---------------------------------------------------------------------------
# Vertex groups

def add_group(name):
    """Blender's + : a new group called Group (Group.001, …), made active."""
    obj = _object(name, active=True)
    _finished(bpy.ops.object.vertex_group_add(), "Blender did not add a vertex group.")


def remove_group(name, group):
    obj = _object(name, active=True)
    obj.vertex_groups.active_index = _group(obj, group).index
    _finished(bpy.ops.object.vertex_group_remove(all=False), "Blender did not remove " + group + ".")


def remove_all_groups(name):
    obj = _object(name, active=True)
    if not len(obj.vertex_groups):
        raise Refusal(obj.name + " has no vertex groups to delete.")
    _finished(bpy.ops.object.vertex_group_remove(all=True), "Blender did not delete the vertex groups.")


def rename_group(name, group, wanted):
    obj = _object(name)
    if not wanted.strip():
        raise Refusal("A vertex group needs a name.")
    _group(obj, group).name = wanted


def set_active_group(name, group):
    obj = _object(name)
    obj.vertex_groups.active_index = _group(obj, group).index


def lock_group(name, group, locked):
    obj = _object(name)
    _group(obj, group).lock_weight = bool(locked)


def _editing(name, group):
    """The edited mesh with `group` made active, for the four Edit Mode
    buttons, which act on the active group."""
    obj = _object(name, modes=('EDIT',), active=True)
    found = _group(obj, group)
    obj.vertex_groups.active_index = found.index
    return obj, found


def assign(name, group, weight):
    """Assign: the selected vertices into `group` at `weight`.

    The weight goes through `tool_settings.vertex_group_weight`, which is
    where Blender's operator reads it from and what the Weight field shows."""
    obj, found = _editing(name, group)
    if found.lock_weight:
        raise Refusal(group + " is locked: unlock it to change its weights.")
    if not obj.data.total_vert_sel:
        raise Refusal("Nothing is selected to assign to " + group + ".")
    bpy.context.scene.tool_settings.vertex_group_weight = max(0.0, min(1.0, float(weight)))
    _finished(bpy.ops.object.vertex_group_assign(), "Blender did not assign to " + group + ".")


def remove_from(name, group):
    obj, found = _editing(name, group)
    if found.lock_weight:
        raise Refusal(group + " is locked: unlock it to change its weights.")
    if not obj.data.total_vert_sel:
        raise Refusal("Nothing is selected to remove from " + group + ".")
    _finished(bpy.ops.object.vertex_group_remove_from(),
              "Blender did not remove the selection from " + group + ".")


def select_group(name, group, select=True):
    _editing(name, group)
    if select:
        _finished(bpy.ops.object.vertex_group_select(), "Blender did not select " + group + ".")
    else:
        _finished(bpy.ops.object.vertex_group_deselect(), "Blender did not deselect " + group + ".")


# ---------------------------------------------------------------------------
# Shape keys

def add_key(name, from_mix=False):
    """Blender's + (from_mix False: a copy of the basis) and New Shape from
    Mix (the shape as it is now drawn). The first key is Basis."""
    obj = _object(name, modes=('OBJECT',), active=True)
    _finished(bpy.ops.object.shape_key_add(from_mix=bool(from_mix)), "Blender did not add a shape key.")


def remove_key(name, key):
    obj = _object(name, modes=('OBJECT',), active=True)
    found = _key(obj, key)
    obj.active_shape_key_index = list(obj.data.shape_keys.key_blocks).index(found)
    _finished(bpy.ops.object.shape_key_remove(all=False), "Blender did not remove " + key + ".")


def remove_all_keys(name, apply_mix=False):
    """Delete All Shape Keys, or Apply All Shape Keys (the mix becomes the
    mesh, then every key goes)."""
    obj = _object(name, modes=('OBJECT',), active=True)
    if obj.data.shape_keys is None:
        raise Refusal(obj.name + " has no shape keys.")
    _finished(bpy.ops.object.shape_key_remove(all=True, apply_mix=bool(apply_mix)),
              "Blender did not remove the shape keys.")


def set_active_key(name, key):
    """Makes `key` the one Edit Mode edits and Shape Key Lock shows."""
    obj = _object(name)
    found = _key(obj, key)
    obj.active_shape_key_index = list(obj.data.shape_keys.key_blocks).index(found)


# A key's settings the panel writes, by Blender's names.
_KEY_SETTINGS = {'value', 'slider_min', 'slider_max', 'mute', 'lock_shape', 'name',
                 'relative_key', 'vertex_group'}


def set_key(name, key, prop, value):
    obj = _object(name)
    found = _key(obj, key)
    if prop not in _KEY_SETTINGS:
        raise Refusal("A shape key has no setting " + repr(prop) + " here.")
    if prop == 'relative_key':
        value = _key(obj, value)
    elif prop == 'vertex_group' and value:
        value = _group(obj, value).name
    elif prop == 'name' and not str(value).strip():
        raise Refusal("A shape key needs a name.")
    setattr(found, prop, value)


def set_keys(name, prop, value):
    """The object's and its keys' own switches: Relative (`use_relative`),
    Shape Key Lock (`show_only_shape_key`) and Edit Mode
    (`use_shape_key_edit_mode`)."""
    obj = _object(name)
    if prop == 'use_relative':
        if obj.data.shape_keys is None:
            raise Refusal(obj.name + " has no shape keys.")
        obj.data.shape_keys.use_relative = bool(value)
    elif prop in ('show_only_shape_key', 'use_shape_key_edit_mode'):
        setattr(obj, prop, bool(value))
    else:
        raise Refusal("There is no shape key switch " + repr(prop) + " here.")
