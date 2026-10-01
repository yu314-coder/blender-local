"""Edit Mode for curves and lattices: their control points.

A curve or a lattice in Edit Mode is edited by its points, not by a mesh: a
Bézier spline by each point's knot and two handles, a NURBS or poly spline by
its control points, a lattice by its grid. This module reads them out for the
3D View to draw, tap, box and move (`cage`, `push`), writes a selection made
there back (`select`), and runs a drag's preview through Blender's own
transform operator (`begin_drag`, `restore`, `settle`).

Everything below was measured in desktop Blender 5.2.1 under
`-b --factory-startup` (scripts/run-points-blender-check.sh):

  * In Edit Mode the RNA reads the edit data: `Curve.splines` the edit nurbs,
    `Lattice.points` the edit lattice, so `foreach_get` of `co`, the handles,
    their types and the selection flags is the state the operators act on.
    A lattice point's `co` is not: `rna_LatticePoint_co_get` takes the point's
    index from the object-mode array, which an edit point is not in, and read
    (-0.5, -0.5, 0.5) for every point of a 3 x 2 x 2 lattice. Only
    `co_deform` is used.

  * A drag cannot be previewed in Swift and committed in Blender and come out
    the same. `transform.translate` on a Bézier knot first changes handle
    types by the selection (`BKE_nurb_handles_test`), moves the handles of an
    Auto or Aligned point with it (`bezt_select_to_transform_triple_flag`),
    then recalculates every Auto handle (`BKE_nurb_handles_calc`) — the
    neighbour's too: on a Bézier circle, a knot moved by (0, 0, 1) moved the
    next point's left handle from (-0.552, 1, 0) to (-0.614, 1.062, 0.276).
    And a lattice point moves the meshes its Lattice modifiers deform. So each
    frame of a drag puts the points back as they were (`restore`), runs the
    operator itself and shows what it did (`settle`); the commit is the same
    restore and the same call. Called from Python, the operator pushes no undo step (ten frames
    left Blender's stack as it was), and the restore is exact: every field it
    writes read back equal.
"""

from array import array

import bpy

# One byte of flags per point. Bit 0: selected; bit 1: hidden; bits 2-3: the
# point's part — 0 a knot, a NURBS or poly point or a lattice point, 1 a
# Bézier point's left handle, 2 its right handle; bits 4-5: a handle's type,
# in Blender's enum order; bit 6: a point of a NURBS or poly spline, which
# Blender joins by its control polygon.
SELECTED = 1
HIDDEN = 2
LEFT = 1 << 2
RIGHT = 2 << 2
TYPE_SHIFT = 4
POLYGON = 64
HANDLE_TYPES = ('FREE', 'AUTO', 'VECTOR', 'ALIGNED')

# What a drag changes, and so what `restore` writes back. A Bézier point's
# handle types too: the transform changes them by the selection before it
# moves anything. Radius and tilt too: Scale moves a NURBS or poly point's
# radius with it (`td->val = &bp->radius` for TFM_RESIZE).
_BEZIER_FIELDS = (('co', 'f', 3), ('handle_left', 'f', 3), ('handle_right', 'f', 3),
                  ('handle_left_type', 'i', 1), ('handle_right_type', 'i', 1),
                  ('radius', 'f', 1), ('tilt', 'f', 1))
_POINT_FIELDS = (('co', 'f', 4), ('radius', 'f', 1), ('tilt', 'f', 1),
                 ('weight_softbody', 'f', 1))

# The drag in progress: the object's name, its points as they were, and the
# objects whose geometry follows it (a mesh under its Lattice modifier).
_drag = None


def edits_points(obj):
    """Whether Edit Mode edits this object by its control points here."""
    return obj is not None and obj.type in ('CURVE', 'LATTICE')


def _read(collection, key, kind, width):
    values = array(kind, [0]) * (len(collection) * width)
    collection.foreach_get(key, values)
    return values


# ---------------------------------------------------------------------------
# The points

def cage(obj):
    """(positions, flags, lines): every control point in the object's own
    space, three floats each; a byte of flags each; and the lines Blender
    draws between them — a handle to its knot, a NURBS or poly point to the
    next, a lattice point to its neighbours — two indices each."""
    if obj.type == 'LATTICE':
        return _lattice_cage(obj.data)
    return _curve_cage(obj.data)


def _curve_cage(curve):
    positions, flags, lines = array('f'), array('B'), array('I')
    for spline in curve.splines:
        start = len(flags)
        if spline.type == 'BEZIER':
            points = spline.bezier_points
            n = len(points)
            co = _read(points, 'co', 'f', 3)
            left = _read(points, 'handle_left', 'f', 3)
            right = _read(points, 'handle_right', 'f', 3)
            left_type = _read(points, 'handle_left_type', 'i', 1)
            right_type = _read(points, 'handle_right_type', 'i', 1)
            knot = _read(points, 'select_control_point', 'b', 1)
            left_sel = _read(points, 'select_left_handle', 'b', 1)
            right_sel = _read(points, 'select_right_handle', 'b', 1)
            hide = _read(points, 'hide', 'b', 1)
            for i in range(n):
                hidden = HIDDEN if hide[i] else 0
                positions.extend(left[3 * i:3 * i + 3])
                positions.extend(co[3 * i:3 * i + 3])
                positions.extend(right[3 * i:3 * i + 3])
                flags.append((SELECTED if left_sel[i] else 0) | hidden | LEFT
                             | (left_type[i] & 3) << TYPE_SHIFT)
                flags.append((SELECTED if knot[i] else 0) | hidden)
                flags.append((SELECTED if right_sel[i] else 0) | hidden | RIGHT
                             | (right_type[i] & 3) << TYPE_SHIFT)
                if not hidden:
                    k = start + 3 * i
                    lines.extend((k, k + 1, k + 1, k + 2))
        else:
            points = spline.points
            n = len(points)
            co = _read(points, 'co', 'f', 4)
            sel = _read(points, 'select', 'b', 1)
            hide = _read(points, 'hide', 'b', 1)
            for i in range(n):
                positions.extend(co[4 * i:4 * i + 3])
                flags.append((SELECTED if sel[i] else 0) | (HIDDEN if hide[i] else 0) | POLYGON)
            count = n if spline.use_cyclic_u and n > 2 else n - 1
            for i in range(max(count, 0)):
                a, b = i, (i + 1) % n
                if not (hide[a] or hide[b]):
                    lines.extend((start + a, start + b))
    return positions, flags, lines


def lattice_lines(u, v, w):
    """A lattice's grid: each point to its next along U, V and W, by Blender's
    index `(w * points_v + v) * points_u + u`."""
    lines = array('I')
    for k in range(w):
        for j in range(v):
            for i in range(u):
                p = (k * v + j) * u + i
                if i + 1 < u:
                    lines.extend((p, p + 1))
                if j + 1 < v:
                    lines.extend((p, p + u))
                if k + 1 < w:
                    lines.extend((p, p + u * v))
    return lines


def _lattice_cage(lattice):
    points = lattice.points
    positions = _read(points, 'co_deform', 'f', 3)
    sel = _read(points, 'select', 'b', 1)
    flags = array('B', [SELECTED if s else 0 for s in sel])
    return positions, flags, lattice_lines(lattice.points_u, lattice.points_v, lattice.points_w)


def lattice_wire(obj, depsgraph=None):
    """(positions, lines) a lattice is drawn with: its grid where Blender
    draws it — the edit lattice while editing, otherwise the evaluated one, a
    hook or a shape key included. None for no points."""
    data = obj.data
    if getattr(obj, 'mode', '') != 'EDIT':
        depsgraph = depsgraph or bpy.context.evaluated_depsgraph_get()
        data = obj.evaluated_get(depsgraph).data
    points = data.points
    if not len(points):
        return None
    return (_read(points, 'co_deform', 'f', 3),
            lattice_lines(data.points_u, data.points_v, data.points_w))


# ---------------------------------------------------------------------------
# The Data tab's settings

def _value(value):
    if isinstance(value, bool):
        return '1' if value else '0'
    if isinstance(value, (int, float)):
        return repr(float(value))
    return str(value)


def record(obj):
    """`key=value;…`: the curve's or the lattice's settings, by Blender's
    property names, as the Data tab shows them."""
    data = obj.data
    if obj.type == 'LATTICE':
        values = [('points_u', data.points_u), ('points_v', data.points_v),
                  ('points_w', data.points_w),
                  ('interpolation_type_u', data.interpolation_type_u),
                  ('interpolation_type_v', data.interpolation_type_v),
                  ('interpolation_type_w', data.interpolation_type_w),
                  ('use_outside', data.use_outside),
                  # Blender greys the resolution out on a lattice with shape
                  # keys (`rna_Lattice_size_editable`), and a write raises
                  # "attribute "points_u" from "Lattice" is read-only".
                  ('points_editable', not data.is_property_readonly('points_u'))]
    else:
        splines = list(data.splines)
        values = [('dimensions', data.dimensions), ('resolution_u', data.resolution_u),
                  ('bevel_depth', data.bevel_depth), ('bevel_resolution', data.bevel_resolution),
                  ('extrude', data.extrude), ('offset', data.offset),
                  ('fill_mode', data.fill_mode),
                  ('splines', len(splines)),
                  ('points', sum(len(s.bezier_points) if s.type == 'BEZIER' else len(s.points)
                                 for s in splines)),
                  ('bezier', sum(1 for s in splines if s.type == 'BEZIER')),
                  ('cyclic', sum(1 for s in splines if s.use_cyclic_u))]
    return ';'.join(k + '=' + _value(v) for k, v in values)


# ---------------------------------------------------------------------------
# To the interface

def push(obj, during_pass=True):
    """Hands the interface the object's settings and, while it is being
    edited, its points. Outside Edit Mode the points go as none, which is how
    the viewport stops drawing them."""
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_points', None)
    if send is None or not edits_points(obj):
        return
    if getattr(obj, 'mode', '') == 'EDIT':
        positions, flags, lines = cage(obj)
    else:
        positions, flags, lines = array('f'), array('B'), array('I')
    send(obj.name, record(obj), positions.tobytes(), flags.tobytes(), lines.tobytes(),
         1 if during_pass else 0)


# ---------------------------------------------------------------------------
# Selecting

def select(name, chosen):
    """Selects exactly the points numbered `chosen`, by the numbering `cage`
    gives, and deselects the rest. An index past the points is ignored: the
    interface's numbering can be a pass behind Blender's."""
    obj = bpy.data.objects.get(name)
    if obj is None or not edits_points(obj) or obj.mode != 'EDIT':
        raise RuntimeError("Selecting points works in Edit Mode on a curve or a lattice")
    chosen = set(int(i) for i in chosen)
    # Blender takes every selected curve (or lattice) into Edit Mode with the
    # active one, and its transform moves the selected points of all of them.
    # The 3D View draws and picks the active one's alone, so a point left
    # selected on another would move with a drag that showed nothing there:
    # they are deselected, as Blender's own click deselects everything first.
    for other in edited_objects():
        if other != obj:
            _select_flags(other, set())
    _select_flags(obj, chosen)


def edited_objects():
    """Every curve and lattice in Edit Mode."""
    return [o for o in bpy.context.view_layer.objects if edits_points(o) and o.mode == 'EDIT']


def _select_flags(obj, chosen):
    if obj.type == 'LATTICE':
        points = obj.data.points
        points.foreach_set('select', array('b', [1 if i in chosen else 0 for i in range(len(points))]))
    else:
        start = 0
        for spline in obj.data.splines:
            if spline.type == 'BEZIER':
                points = spline.bezier_points
                n = len(points)
                points.foreach_set('select_left_handle',
                                   array('b', [1 if start + 3 * i in chosen else 0 for i in range(n)]))
                points.foreach_set('select_control_point',
                                   array('b', [1 if start + 3 * i + 1 in chosen else 0 for i in range(n)]))
                points.foreach_set('select_right_handle',
                                   array('b', [1 if start + 3 * i + 2 in chosen else 0 for i in range(n)]))
                start += 3 * n
            else:
                points = spline.points
                n = len(points)
                points.foreach_set('select', array('b', [1 if start + i in chosen else 0 for i in range(n)]))
                start += n
    obj.data.update_tag()


# ---------------------------------------------------------------------------
# The Curve and Lattice menus

def _edited():
    obj = bpy.context.view_layer.objects.active
    if obj is None or not edits_points(obj) or obj.mode != 'EDIT':
        raise RuntimeError("This works in Edit Mode on a curve or a lattice")
    return obj


def point_count():
    """(points, splines) of the curve or lattice being edited."""
    obj = _edited()
    if obj.type == 'LATTICE':
        return (len(obj.data.points), 1)
    return (sum(len(s.bezier_points) if s.type == 'BEZIER' else len(s.points) for s in obj.data.splines),
            len(obj.data.splines))


def fingerprint():
    """Everything a Curve or Lattice menu row can change in the objects being
    edited — every spline's kind, length and Cyclic, and every point's fields —
    for telling a row that changed nothing from one that did.

    Counting points was not enough: Delete ▸ Segments on a segment of a cyclic
    spline opens it and keeps every point (measured in 5.2.1 on the Bézier
    circle Add ▸ Curve ▸ Circle makes, knots 1 and 2 and again the closing
    pair: `use_cyclic_u` True → False, 4 points before and after), so the row
    said it had been refused over a curve Blender had changed, and recorded no
    undo step for it."""
    _edited()
    found = []
    for obj in edited_objects():
        if obj.type == 'LATTICE':
            shape = (obj.data.points_u, obj.data.points_v, obj.data.points_w)
        else:
            shape = tuple((s.type, len(s.bezier_points) if s.type == 'BEZIER' else len(s.points),
                           s.use_cyclic_u, s.use_cyclic_v) for s in obj.data.splines)
        found.append((obj.name, shape, _snapshot(obj)))
    return found


def require_selection(message):
    """Raises `message` when nothing of the edited object is selected, and
    otherwise answers `fingerprint()`. Measured in 5.2.1: with nothing
    selected, `curve.subdivide`, `curve.extrude_move`, `curve.switch_direction`
    and `curve.handle_type_set` return FINISHED and change nothing, so the row
    read as done and pushed an undo step for nothing."""
    obj = _edited()
    if not any(f & SELECTED for f in cage(obj)[1]):
        raise RuntimeError(message)
    return fingerprint()


# ---------------------------------------------------------------------------
# Dragging

def _snapshot(obj):
    if obj.type == 'LATTICE':
        return [_read(obj.data.points, 'co_deform', 'f', 3)]
    state = []
    for spline in obj.data.splines:
        if spline.type == 'BEZIER':
            state.append(('BEZIER', len(spline.bezier_points),
                          [_read(spline.bezier_points, k, t, w) for k, t, w in _BEZIER_FIELDS]))
        else:
            state.append((spline.type, len(spline.points),
                          [_read(spline.points, k, t, w) for k, t, w in _POINT_FIELDS]))
    return state


def _put_back(obj, state):
    if obj.type == 'LATTICE':
        if len(obj.data.points) * 3 != len(state[0]):
            raise RuntimeError("the lattice changed during the drag")
        obj.data.points.foreach_set('co_deform', state[0])
    else:
        splines = list(obj.data.splines)
        if len(splines) != len(state):
            raise RuntimeError("the curve changed during the drag")
        for spline, (kind, count, values) in zip(splines, state):
            bezier = spline.type == 'BEZIER'
            points = spline.bezier_points if bezier else spline.points
            if (kind == 'BEZIER') != bezier or len(points) != count:
                raise RuntimeError("the curve changed during the drag")
            for (key, _, _), saved in zip(_BEZIER_FIELDS if bezier else _POINT_FIELDS, values):
                points.foreach_set(key, saved)
    obj.data.update_tag()


def begin_drag(name, followers=()):
    """Remembers the points of every curve or lattice in Edit Mode as they
    are, before a drag moves them — the transform moves the selected points
    of each, not only the active one's. `followers` are the objects whose
    geometry follows the active one; those that follow the others are found
    here. All are mirrored with every frame."""
    global _drag
    obj = bpy.data.objects.get(name)
    if obj is None or not edits_points(obj) or obj.mode != 'EDIT':
        _drag = None
        raise RuntimeError("Moving points works in Edit Mode on a curve or a lattice")
    edited = edited_objects()
    names = {o.name for o in edited}
    following = [f for f in followers if f not in names]
    if len(edited) > 1:
        try:
            import _blenderkit_sync
            for other in bpy.context.view_layer.objects:
                if other.name not in names and other.name not in following \
                        and names.intersection(_blenderkit_sync._relations(other)[1]):
                    following.append(other.name)
        except (ImportError, AttributeError, RuntimeError) as error:
            print(f"[Blender Local] the drag's followers could not all be found: {error}")
    states = {o.name: _snapshot(o) for o in edited}
    # `last`: what the last frame left Blender holding — at first what the
    # drag found. `restore` holds Blender to it, so a change made between two
    # frames by anything but the drag is caught rather than overwritten.
    _drag = dict(name=name, states=states, last=states, followers=following)
    return True


def _check(drag):
    """Raises, in the words the banner shows, when Blender no longer holds
    what the drag left it: an object gone or out of Edit Mode, or points
    changed between two frames by something other than the drag.

    Every frame used to run its call whatever it found. Measured in 5.2.1
    with the app's context and its exact frame strings: Edit Curve, a knot
    tapped, one frame, then Undo, which put Blender back in Object Mode; the
    frames showing 0.4, 0.5 and 0.6 then ran `transform.translate` on the
    object, moving it to z 0.4, 0.9 and 1.5, and the release left it at 2.1,
    where the gesture had shown one knot moved 0.6."""
    for name in drag['states']:
        obj = bpy.data.objects.get(name)
        if obj is None:
            raise RuntimeError(f"{name} was removed during the drag, so the drag moved nothing")
        if obj.mode != 'EDIT':
            raise RuntimeError(f"{name} left Edit Mode during the drag, so the drag moved nothing")
    last = drag['last']
    if last is not None:
        for name, state in last.items():
            if _snapshot(bpy.data.objects[name]) != state:
                raise RuntimeError(f"{name}'s points were changed during the drag, so the drag moved nothing")


def restore(end=False):
    """Puts the points back as `begin_drag` found them, for a frame's or the
    commit's call to move them once. Raises, writing nothing, when Blender no
    longer holds what the drag left it (`_check`) or there is no drag: the
    call that follows must not run then. `end` forgets the drag: the commit
    ends it, a frame does not."""
    global _drag
    drag = _drag
    if end:
        _drag = None
    if drag is None:
        raise RuntimeError("No drag is in progress, so nothing was moved")
    _check(drag)
    for name, state in drag['states'].items():
        _put_back(bpy.data.objects[name], state)
    # Unknown until the frame's call has run and `settle` has read it: a call
    # that raised leaves points only this drag changed, which `cancel` may
    # put back.
    drag['last'] = None
    return True


def settle():
    """The end of a frame: what its call left Blender holding is remembered,
    for the next frame to be held to, and shown."""
    drag = _drag
    if drag is None:
        return
    drag['last'] = {name: _snapshot(bpy.data.objects[name]) for name in drag['states']}
    mirror()


def cancel():
    """A drag that ends without a commit: the points put back, shown put
    back, and the drag forgotten. Never raises. A curve that left Edit Mode or
    was changed under the drag (by an Undo) keeps what Blender holds now: put
    back, the drag's points would undo what that change did."""
    global _drag
    try:
        if _drag is not None:
            restore()
            mirror()
    except RuntimeError as error:
        print(f"[Blender Local] the drag was dropped without putting the points back: {error}")
    finally:
        _drag = None


def dragging():
    return _drag is not None


def mirror():
    """The frame a drag previews, to the viewport: the edited object's wire or
    surface and its points, and every follower's place and geometry, without
    a mirroring pass.

    A follower's place too: an object that rides the curve — Follow Path or
    Clamp To, a camera or an empty on a path, the main use of a curve — is
    moved by the points, not deformed. Measured in 5.2.1: an empty following
    the Bézier curve went from (-1, 0, 0) to (-1, 0, 1) in Blender on a frame
    that moved the first knot by z 1, and the frame sent the viewport its
    geometry alone, so it stood still until the release."""
    drag = _drag
    if drag is None:
        return
    try:
        import _blenderkit
        import _blenderkit_anim
    except ImportError:
        return
    depsgraph = bpy.context.evaluated_depsgraph_get()
    try:
        _mirror_points(drag, depsgraph, _blenderkit, _blenderkit_anim)
    finally:
        # The frame path's last call, as a frame change ends with it: the
        # followers' matrices, the frame unchanged (`AnimationMirror.applyFrame`
        # leaves an unchanged frame and an unmoved object as they are), and the
        # name index the frame's `anim_mesh` calls shared is dropped with it.
        names, matrices = [], array('d')
        for name in drag['followers']:
            follower = bpy.data.objects.get(name)
            if follower is None or _blenderkit_anim._is_hidden(follower):
                continue
            names.append(name)
            matrices.extend(v for row in follower.evaluated_get(depsgraph).matrix_world for v in row)
        scene = bpy.context.scene
        _blenderkit.anim_frame(scene.frame_current, float(scene.frame_subframe),
                               '\0'.join(names).encode(), matrices.tobytes())


def _mirror_points(drag, depsgraph, _blenderkit, _blenderkit_anim):
    for name in drag['states']:
        obj = bpy.data.objects.get(name)
        if obj is None:
            continue
        if obj.type == 'LATTICE':
            wire = lattice_wire(obj, depsgraph)
            if wire is not None:
                positions, lines = wire
                normals = array('f', [0.0]) * len(positions)
                _blenderkit.anim_mesh(obj.name, positions.tobytes(), normals.tobytes(), b'',
                                      lines.tobytes())
        else:
            _blenderkit_anim.push_mesh(obj, depsgraph)
        if name == drag['name']:
            push(obj, during_pass=False)
    for name in drag['followers']:
        follower = bpy.data.objects.get(name)
        if follower is None or follower.type not in _blenderkit_anim._DRAWN \
                or _blenderkit_anim._is_hidden(follower):
            continue
        try:
            _blenderkit_anim.push_mesh(follower, depsgraph)
        except ValueError:
            # Refused for an object the viewport does not hold (one added by
            # a script since the last pass): it is left out of the preview,
            # not allowed to cost the frame, and the commit's pass brings it.
            pass
