"""Object constraints: what the Object Constraints tab shows and what its
controls do, as Blender's Properties editor has them.

`record` reads an object's constraint stack for the interface (`push` hands
it over through `_blenderkit.sync_record`); every other function is one
control of the tab, held to the conditions Blender's own are.

Measured in desktop Blender 5.2.1 under `-b --factory-startup` with the app's
context — its undo push, `gpu.init()`, a window and a screen and no area
(round 4, group 7; tests/relations/blender):

  * `object.constraint_add(type=…)` FINISHED for all eleven types the tab
    has rows for, on the active object. `constraint.delete`, `move_up`,
    `move_down`, `move_to_index`, `childof_set_inverse`,
    `childof_clear_inverse` and `followpath_path_animate` each run given
    `constraint=<name>, owner='OBJECT'`: with no `constraint` pointer in the
    context their poll takes the active object (`edit_constraint_poll`), so
    every control here acts on the active object and names it first. Their
    steps, called with their undo on: Add Constraint, Delete Constraint, Move
    Constraint Up, Move Constraint Down, Move Constraint to Index.
  * The viewport's matrix is the evaluated one: a cube at the origin with
    Copy Location from a sphere at (3, 0, 0) read `matrix_world` (3, 0, 0)
    while its `location` stayed (0, 0, 0); at Influence 0.5, (1.5, 0, 0);
    with the constraint off, (0, 0, 0).
  * Child Of sets its inverse on the first evaluation with a target
    (`set_inverse_pending` starts True): the cube stayed at (0, 0, 0) with the
    sphere at (3, 0, 0) as its parent. Clear Inverse put it at (3, 0, 0), Set
    Inverse back. Follow Path on a Bézier circle of radius 2 put the cube at
    (0, -2, 0); Animate Path keyed the curve's evaluation time.
  * An object owner's spaces are World, Custom and Local only: 'POSE' was
    refused with "enum "POSE" not found in ('WORLD', 'CUSTOM', 'LOCAL')".
"""

import bpy

Refusal = RuntimeError

_ESCAPES = (('%', '%25'), (';', '%3B'), ('|', '%7C'), ('=', '%3D'), ('\n', '%0A'))

# The settings each modelled type's panel shows, in the order Blender's
# panel draws them (properties_constraint.py, 5.2.1). Anything else a
# constraint has is reached through the Data API.
FIELDS = {
    'COPY_LOCATION': ('target', 'use_x', 'use_y', 'use_z', 'invert_x', 'invert_y', 'invert_z',
                      'use_offset', 'target_space', 'owner_space'),
    'COPY_ROTATION': ('target', 'euler_order', 'use_x', 'use_y', 'use_z', 'invert_x', 'invert_y',
                      'invert_z', 'mix_mode', 'target_space', 'owner_space'),
    'COPY_SCALE': ('target', 'use_x', 'use_y', 'use_z', 'power', 'use_make_uniform', 'use_offset',
                   'use_add', 'target_space', 'owner_space'),
    'COPY_TRANSFORMS': ('target', 'remove_target_shear', 'mix_mode', 'target_space', 'owner_space'),
    'TRACK_TO': ('target', 'track_axis', 'up_axis', 'use_target_z', 'target_space', 'owner_space'),
    'DAMPED_TRACK': ('target', 'track_axis'),
    'LIMIT_LOCATION': ('use_min_x', 'min_x', 'use_min_y', 'min_y', 'use_min_z', 'min_z',
                       'use_max_x', 'max_x', 'use_max_y', 'max_y', 'use_max_z', 'max_z',
                       'use_transform_limit', 'owner_space'),
    'LIMIT_ROTATION': ('use_limit_x', 'min_x', 'max_x', 'use_limit_y', 'min_y', 'max_y',
                       'use_limit_z', 'min_z', 'max_z', 'euler_order', 'use_transform_limit',
                       'use_legacy_behavior', 'owner_space'),
    'LIMIT_SCALE': ('use_min_x', 'min_x', 'use_min_y', 'min_y', 'use_min_z', 'min_z',
                    'use_max_x', 'max_x', 'use_max_y', 'max_y', 'use_max_z', 'max_z',
                    'use_transform_limit', 'owner_space'),
    'CHILD_OF': ('target', 'use_location_x', 'use_location_y', 'use_location_z',
                 'use_rotation_x', 'use_rotation_y', 'use_rotation_z',
                 'use_scale_x', 'use_scale_y', 'use_scale_z'),
    'FOLLOW_PATH': ('target', 'use_fixed_location', 'offset', 'offset_factor', 'forward_axis',
                    'up_axis', 'use_curve_radius', 'use_curve_follow'),
}

# The spaces an object's constraint takes (measured, see above). Custom Space
# needs an object of its own to be relative to, which the tab does not pick;
# a constraint set to it shows it and is changed through the Data API.
SPACES = ('WORLD', 'LOCAL')


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


def _type_label(con):
    try:
        return con.bl_rna.properties['type'].enum_items[con.type].name
    except (KeyError, AttributeError):
        return con.type.replace('_', ' ').title()


def _options(con, name):
    """`ID:Name,ID:Name` — an enum's items as this Blender has them, so the
    tab offers the choices Blender's panel does, in its words."""
    prop = con.bl_rna.properties[name]
    items = [(e.identifier, e.name) for e in prop.enum_items]
    if name in ('owner_space', 'target_space'):
        items = [i for i in items if i[0] in SPACES or i[0] == getattr(con, name)]
    return ','.join(i.replace('%', '%25').replace(',', '%2C').replace(':', '%3A') + ':'
                    + n.replace('%', '%25').replace(',', '%2C').replace(':', '%3A')
                    for i, n in items)


def _constraint_entry(con):
    pairs = [('kind', con.type), ('name', con.name), ('label', _type_label(con)),
             ('enabled', bool(con.enabled)), ('influence', float(con.influence)),
             ('active', bool(getattr(con, 'active', False))),
             ('valid', bool(getattr(con, 'is_valid', True))),
             ('expanded', bool(getattr(con, 'show_expanded', True)))]
    fields = FIELDS.get(con.type)
    if fields is None:
        return _entry(pairs)
    try:
        for name in fields:
            value = getattr(con, name)
            if name == 'target':
                pairs.append(('target', value.name if value is not None else ''))
                pairs.append(('target_type', value.type if value is not None else ''))
                continue
            prop = con.bl_rna.properties[name]
            if prop.type == 'ENUM':
                pairs.append(('options.' + name, _options(con, name)))
            pairs.append((name, value))
    except (AttributeError, KeyError, TypeError) as error:
        # A setting this Blender does not have: the constraint keeps the
        # controls every one has, and its settings stay Blender's alone.
        print("[Blender Local] " + con.name + ": its settings could not be read: " + str(error))
        pairs = pairs[:8] + [('unread', True)]
    return _entry(pairs)


def record(obj):
    """`kind=TYPE;name=…;…|…`: the object's constraints, top first."""
    return '|'.join(_constraint_entry(c) for c in obj.constraints)


def push(obj):
    """Hands the interface the constraint stack of the object the pass just
    pushed. An object without constraints sends nothing: the object a pass
    pushes arrives with none (`BKObject.constraints`), and the merge takes
    that onto the one on screen, so one whose last constraint went shows
    none — without a call per object per pass for the many with none."""
    if not hasattr(obj, 'constraints') or len(obj.constraints) == 0:
        return
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_record', None)
    if send is None:
        return
    send('constraints', obj.name, record(obj))


# ---------------------------------------------------------------------------
# What every control needs

def _object(name):
    """The active object called `name`: Blender's constraint operators act
    on the active object, and the tab shows the active object's stack."""
    obj = bpy.data.objects.get(name)
    if obj is None:
        raise Refusal("There is no object called " + repr(name) + ".")
    if bpy.context.view_layer.objects.active != obj:
        raise Refusal(obj.name + " is not the active object, whose constraints the tab shows.")
    if getattr(obj, 'mode', 'OBJECT') not in ('OBJECT', 'EDIT', 'POSE'):
        raise Refusal("Object constraints are changed in Object Mode or Edit Mode; " + obj.name
                      + " is in " + obj.mode.replace('_', ' ').title() + " Mode.")
    return obj


def _constraint(obj, name):
    con = obj.constraints.get(name)
    if con is None:
        raise Refusal(obj.name + " has no constraint called " + repr(name) + ".")
    return con


def _finished(result, refusal):
    if 'FINISHED' not in result:
        raise Refusal(refusal)
    return result


TYPES = tuple(e.identifier for e in bpy.types.Constraint.bl_rna.properties['type'].enum_items) \
    if hasattr(bpy.types, 'Constraint') and hasattr(bpy.types.Constraint, 'bl_rna') else ()


# ---------------------------------------------------------------------------
# The controls

def add(name, type):
    """Add Object Constraint: Blender's `object.constraint_add`, which names
    it after its type and makes it active."""
    obj = _object(name)
    if TYPES and type not in TYPES:
        raise Refusal("Blender has no constraint of the type " + repr(type) + ".")
    return _finished(bpy.ops.object.constraint_add(type=type),
                     "Blender did not add the constraint to " + obj.name + ".")


def remove(name, constraint):
    obj = _object(name)
    _constraint(obj, constraint)
    return _finished(bpy.ops.constraint.delete(constraint=constraint, owner='OBJECT'),
                     "Blender did not delete " + constraint + ".")


def move(name, constraint, direction):
    """Move Constraint Up (-1) or Down (+1). At the top or the bottom Blender
    answers CANCELLED, which is said here before it is asked."""
    obj = _object(name)
    _constraint(obj, constraint)
    index = obj.constraints.find(constraint)
    if direction < 0 and index == 0:
        raise Refusal(constraint + " is already the first constraint.")
    if direction > 0 and index == len(obj.constraints) - 1:
        raise Refusal(constraint + " is already the last constraint.")
    run = bpy.ops.constraint.move_up if direction < 0 else bpy.ops.constraint.move_down
    return _finished(run(constraint=constraint, owner='OBJECT'),
                     "Blender did not move " + constraint + ".")


def move_to(name, constraint, index):
    """Move to First / Move to Last: `constraint.move_to_index`."""
    obj = _object(name)
    _constraint(obj, constraint)
    index = max(0, min(int(index), len(obj.constraints) - 1))
    if obj.constraints.find(constraint) == index:
        raise Refusal(constraint + " is already there.")
    return _finished(bpy.ops.constraint.move_to_index(constraint=constraint, owner='OBJECT',
                                                      index=index),
                     "Blender did not move " + constraint + ".")


def operate(name, constraint, operator):
    """One of the operators Blender's panel has a button or a menu row for,
    on one constraint: apply, copy (Duplicate), copy_to_selected,
    childof_set_inverse, childof_clear_inverse, followpath_path_animate."""
    if operator not in ('apply', 'copy', 'copy_to_selected', 'childof_set_inverse',
                        'childof_clear_inverse', 'followpath_path_animate'):
        raise Refusal("The constraint panel has no control called " + repr(operator) + ".")
    obj = _object(name)
    con = _constraint(obj, constraint)
    if operator.startswith('childof_') and con.type != 'CHILD_OF':
        raise Refusal(constraint + " is not a Child Of constraint.")
    if operator == 'followpath_path_animate':
        if con.type != 'FOLLOW_PATH':
            raise Refusal(constraint + " is not a Follow Path constraint.")
        if con.target is None:
            raise Refusal("Animate Path animates the path " + constraint + " follows, and it has "
                          "no Target curve yet.")
    if operator == 'copy_to_selected':
        others = [o for o in bpy.context.selected_objects if o != obj]
        if not others:
            raise Refusal("Copy to Selected copies " + constraint + " onto the other selected "
                          "objects, and none is selected.")
    if operator == 'apply' and getattr(obj, 'mode', 'OBJECT') != 'OBJECT':
        raise Refusal("Apply works in Object Mode.")
    run = getattr(bpy.ops.constraint, operator)
    return _finished(run(constraint=constraint, owner='OBJECT'),
                     "Blender did not run that on " + constraint + ".")


def set_value(name, constraint, prop, value):
    """One setting, as the panel's field writes it. Enabled and Influence are
    every constraint's; the rest are those `FIELDS` lists for its type."""
    obj = _object(name)
    con = _constraint(obj, constraint)
    allowed = ('enabled', 'influence', 'name') + FIELDS.get(con.type, ())
    if prop not in allowed or prop == 'target':
        raise Refusal(con.name + " has no setting " + repr(prop) + " in this panel.")
    if prop == 'name':
        wanted = str(value).strip()
        if not wanted:
            raise Refusal("A constraint needs a name.")
        con.name = wanted
        return con.name
    setattr(con, prop, value)
    return getattr(con, prop)


def set_target(name, constraint, target):
    """The Target field: another object, or none ('')."""
    obj = _object(name)
    con = _constraint(obj, constraint)
    if 'target' not in FIELDS.get(con.type, ()):
        raise Refusal(con.name + " has no Target in this panel.")
    if not target:
        con.target = None
        return ''
    other = bpy.data.objects.get(target)
    if other is None:
        raise Refusal("There is no object called " + repr(target) + ".")
    if other == obj:
        raise Refusal(obj.name + " cannot be its own target.")
    if con.type == 'FOLLOW_PATH' and other.type != 'CURVE':
        raise Refusal("Follow Path follows a curve, and " + other.name + " is not one.")
    con.target = other
    return con.target.name if con.target is not None else ''


# ---------------------------------------------------------------------------
# A drag of objects that constraints move: previewed by Blender
#
# The 3D View previews an object drag itself, from the channels it moves —
# and an object a constraint holds is not where its channels say: a cube
# with Copy Location from a sphere stays on the sphere whatever its location
# (measured above), one with Limit Location stops at the limit, and an object
# whose constraint targets the one being dragged follows it. Previewed from
# the channels, the cube slid off the sphere and jumped back on release —
# the preview was not the commit. So while such a drag lasts, each frame puts
# the channels back, runs the very call the release commits, and hands the
# viewport Blender's evaluated matrices (`_blenderkit.anim_frame`, the frame
# change's path), as a curve's point drag does (`_blenderkit_points`).

_drag = None


def _channels(o):
    return (tuple(o.location), o.rotation_mode, tuple(o.rotation_euler), tuple(o.rotation_quaternion),
            tuple(o.rotation_axis_angle), tuple(o.scale))


def _put(o, c):
    # The mode first: setting it converts the rotation it finds.
    if o.rotation_mode != c[1]:
        o.rotation_mode = c[1]
    o.location, o.rotation_euler, o.rotation_quaternion, o.rotation_axis_angle, o.scale = \
        c[0], c[2], c[3], c[4], c[5]


def drag_begin():
    """Remembers every object's channels — a transform with Proportional
    Editing moves objects that are not selected — and which objects the
    viewport has to be told about each frame: the selected ones, every object
    with a constraint, and the children of either.

    A drag still open — one whose end never came (a field's scrub that the
    system cancelled, a view torn down mid-gesture) — is ended first, its
    channels put back: otherwise the preview it left would become this drag's
    baseline, a change with no undo step under it (round 4's review of group
    7)."""
    global _drag
    if _drag is not None:
        drag_end()
    objects = list(bpy.context.view_layer.objects)
    watch = {o.name for o in objects if o.select_get() or len(o.constraints)}
    grew = True
    while grew:
        grew = False
        for o in objects:
            if o.parent is not None and o.parent.name in watch and o.name not in watch:
                watch.add(o.name)
                grew = True
    _drag = dict(states={o.name: _channels(o) for o in objects}, watch=sorted(watch))
    return len(_drag['watch'])


def _restore():
    for name, c in _drag['states'].items():
        o = bpy.data.objects.get(name)
        if o is not None and _channels(o) != c:
            _put(o, c)


def _push():
    from array import array
    import _blenderkit
    bpy.context.evaluated_depsgraph_get()
    names, matrices = [], array('d')
    for name in _drag['watch']:
        o = bpy.data.objects.get(name)
        if o is None:
            continue
        names.append(name)
        matrices.extend(v for row in o.matrix_world for v in row)
    scene = bpy.context.scene
    _blenderkit.anim_frame(scene.frame_current, float(scene.frame_subframe), '\0'.join(names).encode(),
                           matrices.tobytes())


def drag_frame(call):
    """One frame: the channels put back, `call` run, Blender's matrices to
    the viewport."""
    if _drag is None:
        raise Refusal("No constrained drag is under way.")
    _restore()
    # In Local View the release runs under the borrowed view, where only what
    # Local View holds is moved (`_blenderkit_localview.run`), so the frames
    # do too: a selected object outside it, moved here and not by the commit,
    # would drag whatever is constrained to it in the preview alone.
    try:
        import _blenderkit_localview
        scope = _blenderkit_localview.scope()
    except ImportError:
        import contextlib
        scope = contextlib.nullcontext()
    with scope:
        exec(call, {'bpy': bpy})
    # Priced before Blender evaluates the frame (round 4's second fix-round
    # review: an offset object carrying a Limit Rotation, the frame's bare
    # `location[0] = 0.0001`, and Blender built its Array's 3,200,008 vertices
    # inside the preview, with only the release priced). Refused, the frame
    # is put back as Blender last evaluated it and the drag goes on with the
    # viewport's own preview (`BpyBridge.previewConstrainedDrag`).
    _gate_now('the drag')
    _push()


def _gate_now(where):
    import sys
    gate = sys.modules.get('_blenderkit_gate')
    if gate is None:
        try:
            import _blenderkit_gate as gate
        except ImportError:
            return
    gate.gate(where)


def drag_end():
    """The drag over, committed or not: Blender's channels as the drag found
    them, and the viewport told so. The commit then runs once, as its undo
    step. Never raises."""
    global _drag
    if _drag is None:
        return
    try:
        _restore()
        _push()
    except Exception as error:                      # noqa: BLE001 - the release goes on
        print("[Blender Local] the drag's objects were not all put back: " + str(error))
    finally:
        _drag = None
