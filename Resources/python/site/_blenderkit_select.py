"""Blender's pick selections from the app's own picking, the selection order a
tap leaves, Select Grouped, and the Select menu's refusals.

Blender's Alt+click (`mesh.loop_select`), Ctrl+Alt+click
(`mesh.edgering_select`), Ctrl+click (`mesh.shortest_path_pick`) and L
(`mesh.select_linked_pick`) find the element under the mouse in their invoke
and then hand its index to their exec, which does the selecting. Round 3's
review measured all four returning CANCELLED under the borrowed 3D View: they
were called without an index (-1, the default), so the exec found nothing.
Given the index, the exec is the whole operator. Measured in desktop 5.2.1
with the app's context (its undo push, gpu.init(), temp_override_view3d),
round 4 group 4:

  * `loop_select(object_index=0, edge_index=e)` FINISHED on every edge of a
    7 x 7 grid, a cube, a 12 x 6 UV sphere and an 8-sided cylinder (252 edges)
    in vertex, edge and face mode; `edgering_select` the same. A second click
    on a grid's boundary edge took the loop (6 edges) to the whole boundary
    (24) and a third back, as Blender's Alt+click cycles. An index past the
    mesh, or another object's, returns CANCELLED.
  * Without a 3D View the first three fail their poll ("Expected a view3d
    region & editmesh"); `select_linked_pick` needs none. None crashed.
  * `shortest_path_pick(index=i)` goes from the active element — the last in
    `bm.select_history`, or a selected active face — and returns CANCELLED,
    changing nothing, with no active element or one of another kind.
  * The app's taps never set Blender's selection history, so before this
    there was no active element for Ctrl+click, Next Active or Side of Active
    to start from (`Bpy.pushEditSelection` now writes it, and the mirror reads
    it back: `history_bytes`).

The checks here say in words what Blender would answer with a bare CANCELLED,
before anything runs: the mesh the viewport picked on is not Blender's any
more, the element is hidden, or there is nothing to start a path from.
scripts/run-selectpick-blender-check.sh holds every call the app makes to
Blender's own pick at the same point of the same view.
"""

import array

import bpy

# How much of Blender's selection order the mirror hands the interface, and
# the interface hands back: the most recent entries. Next Active needs the
# last two and Previous Active walks back one at a time; a click adds one
# entry, so a history this long is hundreds of clicks without a Box Select
# (which clears it, `BM_mesh_elem_hflag_disable_test`).
HISTORY_LIMIT = 256

# Element kinds, as the mirror's report carries them.
VERT, EDGE, FACE = 0, 1, 2


def _is_real_blender():
    # The simulator's stand-in has no RNA behind its operators.
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _edited_mesh(what):
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        raise RuntimeError(what + " selects on the mesh being edited, and no object is active.")
    if obj.type != 'MESH':
        raise RuntimeError(what + " selects on a mesh, and %s is a %s." % (obj.name, obj.type.lower()))
    if obj.mode != 'EDIT':
        raise RuntimeError(what + " selects on the mesh being edited. Go into Edit Mode first.")
    return obj


def _bmesh(obj):
    import bmesh
    bm = bmesh.from_edit_mesh(obj.data)
    for seq in (bm.verts, bm.edges, bm.faces):
        seq.ensure_lookup_table()
    return bm


def _object_index(obj):
    # Blender's `object_index`: the place among the objects in Edit Mode,
    # active first (BKE_view_layer_array_from_bases_in_edit_mode).
    in_mode = list(getattr(bpy.context, 'objects_in_mode', None) or [obj])
    for i, other in enumerate(in_mode):
        if other == obj:
            return i
    return -1


_KIND_WORDS = {VERT: 'vertex', EDGE: 'edge', FACE: 'face'}


def check_pick(what, kind, index, counts, object_index=0):
    """Refuses in words what the pick would do nothing with: a mesh that is
    not the one the viewport picked on (`counts`, its vertices, edges and
    faces when the mirror last read it — an index into another mesh names
    another element), an element that is not there or is hidden (Blender's
    exec returns CANCELLED on a hidden edge, editmesh_select.cc), and an
    `object_index` that names another object in Edit Mode."""
    if not _is_real_blender():
        raise NotImplementedError(what + " needs Blender's 3D View, which the simulator's "
                                  "stand-in for Blender does not have")
    obj = _edited_mesh(what)
    bm = _bmesh(obj)
    have = (len(bm.verts), len(bm.edges), len(bm.faces))
    if have != tuple(counts):
        raise RuntimeError("The mesh changed after the viewport last drew it. Select again.")
    seq = (bm.verts, bm.edges, bm.faces)[kind]
    if not isinstance(index, int) or not 0 <= index < len(seq):
        raise RuntimeError("%s: the mesh has %d %s, and there is no %s %r."
                           % (what, len(seq), ('vertices', 'edges', 'faces')[kind],
                              _KIND_WORDS[kind], index))
    if seq[index].hide:
        raise RuntimeError("%s: that %s is hidden. Reveal it (Alt+H) first."
                           % (what, _KIND_WORDS[kind]))
    if _object_index(obj) != object_index:
        raise RuntimeError("%s: %s is not the first of the objects in Edit Mode, so Blender "
                           "would select on another one. Leave Edit Mode on the others first."
                           % (what, obj.name))
    return obj


def active_kind(bm):
    """The kind of Blender's active element — what Ctrl+click starts its path
    from (`edbm_elem_active_elem_or_face_get`): the last in the selection
    order, or else the active face while it is selected. None without one."""
    import bmesh
    active = bm.select_history.active
    if active is None:
        face = bm.faces.active
        if face is not None and face.select:
            active = face
    if active is None:
        return None
    if isinstance(active, bmesh.types.BMVert):
        return VERT
    if isinstance(active, bmesh.types.BMEdge):
        return EDGE
    return FACE


def check_path(kind, index, counts):
    """`check_pick`, and an active element of the same kind to start from:
    without one Blender's exec returns CANCELLED and changes nothing
    (measured: no active element, and an active vertex with a face picked)."""
    what = "Pick Shortest Path"
    obj = check_pick(what, kind, index, counts)
    have = active_kind(_bmesh(obj))
    if have is None:
        raise RuntimeError("Pick Shortest Path goes from the active element (the one selected "
                           "last) to the one picked, and nothing is active. Tap one first.")
    if have != kind:
        raise RuntimeError("Pick Shortest Path goes from the active element to one of the same "
                           "kind, and the active element is a %s. Tap a %s first."
                           % (_KIND_WORDS[have], _KIND_WORDS[kind]))
    return obj


def history_bytes(bm):
    """Blender's selection order on `bm`, for the mirror: (kind, index) as
    int32 pairs, oldest first, the last HISTORY_LIMIT entries; then, when
    the active face is selected and is not the last entry, one more pair
    with kind 3 — Blender keeps that face apart from the order (`act_face`),
    and Ctrl+click in Face mode starts from it when the order has no face.
    Indices are Blender's, as the report's other arrays number them."""
    import bmesh
    history = list(bm.select_history)[-HISTORY_LIMIT:]
    out = array.array('i')
    kinds = set()
    for element in history:
        if isinstance(element, bmesh.types.BMVert):
            kinds.add(VERT)
        elif isinstance(element, bmesh.types.BMEdge):
            kinds.add(EDGE)
        else:
            kinds.add(FACE)
    face = bm.faces.active
    if face is not None and face.select:
        kinds.add(FACE)
    # Indices are only good after an update (a delete leaves them dirty);
    # the report's arrays are in this same order, the edit mesh's own.
    for kind in kinds:
        (bm.verts, bm.edges, bm.faces)[kind].index_update()
    last = None
    for element in history:
        if isinstance(element, bmesh.types.BMVert):
            kind = VERT
        elif isinstance(element, bmesh.types.BMEdge):
            kind = EDGE
        else:
            kind = FACE
        out.extend((kind, element.index))
        last = element
    if face is not None and face.select and last is not face:
        out.extend((3, face.index))
    return out.tobytes()


def edit_selection_state():
    """What Blender holds selected on the meshes in Edit Mode, and its
    selection order, to tell a run that changed the selection from one that
    did not: Select Next Element and Select Previous Element answer FINISHED
    either way (measured in 5.2.1: with no selection order, "Selection pair
    not found" is only a report a bpy module cannot read). None without
    bmesh (the simulator's stand-in), where nothing is compared."""
    try:
        import bmesh
    except ImportError:
        return None
    state = []
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or [bpy.context.object])
    for obj in objects:
        if obj is None or getattr(obj, 'type', '') != 'MESH' or obj.mode != 'EDIT':
            continue
        bm = bmesh.from_edit_mesh(obj.data)
        state.append((tuple(v.select for v in bm.verts), tuple(e.select for e in bm.edges),
                      tuple(f.select for f in bm.faces), tuple(bm.select_history)))
    return state


class refuse_unchanged_selection:
    """Raises `refusal` when the block leaves the edit selection and its order
    as they were (`edit_selection_state`)."""

    def __init__(self, refusal):
        self.refusal = refusal
        self.before = None

    def __enter__(self):
        self.before = edit_selection_state()
        return self

    def __exit__(self, kind, error, traceback):
        if kind is None and self.before is not None and edit_selection_state() == self.before:
            raise RuntimeError(self.refusal)
        return False


class aimed_view:
    """The borrowed 3D View (`_blenderkit_context.temp_override_view3d`),
    turned to look along `forward` with `up` as near its up as it allows —
    where the app's 3D View looks — for an operator that reads the view's
    rotation: Side of Active's View axis (`mesh.select_axis`,
    orientation='VIEW', which takes the region's view matrix). Measured in
    5.2.1: with no view in the context View selected what Global does; inside
    the borrowed view, unaimed, it took the startup screen's view. The view
    is put back afterwards, whether or not the operator worked."""

    def __init__(self, what, forward, up):
        self.what = what
        self.forward = forward
        self.up = up
        self._override = None
        self._rotation = None
        self._region = None

    def __enter__(self):
        import math
        from mathutils import Vector, Matrix
        import _blenderkit_context
        flat = list(self.forward) + list(self.up)
        if len(self.forward) != 3 or len(self.up) != 3 or not all(math.isfinite(float(c)) for c in flat):
            raise RuntimeError(self.what + " was given a view direction that is not three numbers.")
        # `RegionView3D.update()` with no GPU context current takes the
        # process down rather than raising; the Knife's check says so first.
        import _blenderkit_knife
        _blenderkit_knife.require_gpu_context(self.what)
        self._override = _blenderkit_context.temp_override_view3d(self.what)
        self._override.__enter__()
        # Python runs `__exit__` only for a `with` whose `__enter__` returned,
        # so anything raised from here on would leave the borrowed view
        # entered for the rest of the script. Round 4's review: measured in
        # desktop 5.2.1, an `up` of two numbers raised in the Vector maths and
        # `bpy.context.area` still read VIEW_3D after the failed `with`.
        # So the view is turned back, if it was turned, and the override left.
        try:
            return self._aim(Vector, Matrix)
        except BaseException:
            import sys
            self.__exit__(*sys.exc_info())
            raise

    def _aim(self, Vector, Matrix):
        area = bpy.context.area
        region = area.spaces.active.region_3d if area is not None else None
        if region is None:
            return self
        forward = Vector(self.forward)
        up = Vector(self.up)
        if forward.length < 1e-9:
            return self
        forward.normalize()
        # -Z is the line of sight (`to_track_quat('-Z', 'Y')`), as the Knife
        # aims the same view (`_blenderkit_knife._view_rotation`).
        z = -forward
        y = up - z * up.dot(z)
        if y.length < 1e-6:
            rotation = forward.to_track_quat('-Z', 'Y')
        else:
            y.normalize()
            rotation = Matrix((y.cross(z), y, z)).transposed().to_quaternion()
        self._region = region
        self._rotation = region.view_rotation.copy()
        region.view_rotation = rotation
        region.update()
        return self

    def __exit__(self, *exc):
        try:
            if self._region is not None and self._rotation is not None:
                self._region.view_rotation = self._rotation
                self._region.update()
        except Exception:
            # The override is left whatever happened to the view.
            if self._override is not None:
                self._override.__exit__(*exc)
            raise
        if self._override is not None:
            return self._override.__exit__(*exc)
        return False


# ---------------------------------------------------------------- objects

class object_select:
    """An Object Mode Select row, with Blender's CANCELLED said in words and
    anything it changed on the way to a CANCELLED or an error put back.

    Measured in 5.2.1: Select Linked by Material on an object with none
    returns CANCELLED having deselected everything first, and with no active
    object raises "No active object", again after deselecting; Select
    Hierarchy's poll fails with no active object. `needs_active` names the
    row when it starts from the active object, refused before anything
    changes. `unchanged`: the operator finishes whatever it did — Select
    Pattern, Select by Type, Mirror and Random always return FINISHED — so a
    run that leaves the selection and the active object as they were is
    refused in the same words, and the bridge records no step for it.

    The row's call goes inside the block (`LastOperator.within`), so the redo
    panel re-runs it the same way."""

    def __init__(self, refusal, unchanged=False, needs_active=None):
        self.refusal = refusal
        self.unchanged = unchanged
        self.needs_active = needs_active
        self.was = None
        self.active = None

    def _state(self):
        layer = bpy.context.view_layer
        return {o.name for o in layer.objects if o.select_get()}, layer.objects.active

    def __enter__(self):
        layer = bpy.context.view_layer
        if self.needs_active and layer.objects.active is None:
            raise RuntimeError(self.needs_active + " starts from the active object, and no object "
                               "is active. Tap one first.")
        self.was, self.active = self._state()
        return self

    def _restore(self):
        layer = bpy.context.view_layer
        for o in layer.objects:
            if o.select_get() != (o.name in self.was):
                o.select_set(o.name in self.was)
        layer.objects.active = self.active

    def __exit__(self, kind, error, traceback):
        if kind is not None:
            self._restore()
            return False
        if self.unchanged and self._state() == (self.was, self.active):
            raise RuntimeError(self.refusal)
        return False


# Blender's `object.select_grouped` types (prop_select_grouped_types,
# object_select.cc), as its menu lists them.
GROUPED_TYPES = ('CHILDREN_RECURSIVE', 'CHILDREN', 'PARENT', 'SIBLINGS', 'TYPE', 'COLLECTION',
                 'HOOK', 'PASS', 'COLOR', 'KEYINGSET', 'LIGHT_TYPE')

# `select_grouped_collection` offers at most this many collections.
COLLECTION_MENU_MAX = 24


def _grouped_collections(ob):
    # Blender walks `bmain->collections`, which holds no scene's master
    # collection, and tests direct membership (BKE_collection_has_object).
    found = []
    for collection in bpy.data.collections:
        if len(found) >= COLLECTION_MENU_MAX:
            break
        if ob.name in collection.objects and collection.objects[ob.name] == ob:
            found.append(collection)
    return found


def select_grouped(type='CHILDREN_RECURSIVE', extend=False):
    """Blender's Select ▸ Select Grouped (`object.select_grouped`), which a
    bpy module cannot run: its poll returns False whenever Blender runs in
    background mode ("Uses popup menus which won't work in background mode",
    object_select.cc), and the bpy module always does (creator.cc sets
    G.background for WITH_PYTHON_MODULE). This is its exec,
    `object_select_grouped_exec`, type by type, on the same data: the
    selectable objects (`selectable_bases`), the visible ones for
    Collection's (`visible_bases`), Blender's 0.005 per channel for Color,
    the active Keying Set's paths. Returns {'FINISHED'} when the selection
    changed and {'CANCELLED'} when it did not, as the exec does — including
    the Deselect All in front of it when Extend is off.

    Two things are refused before anything changes, where Blender would
    report an error after its Deselect All: Light Type with a non-light
    active ("Active object must be a light"), and Keying Set with no active
    set ("No active Keying Set to use"). And Collection with the active
    object in more than one collection, where Blender opens a menu asking
    which (`OBJECT_OT_select_same_collection`); the refusal names them."""
    if type not in GROUPED_TYPES:
        raise RuntimeError("Select Grouped has no type %r." % (type,))
    context = bpy.context
    layer = context.view_layer
    ob = layer.objects.active
    if ob is None:
        raise RuntimeError("No active object")
    if type == 'LIGHT_TYPE' and ob.type != 'LIGHT':
        raise RuntimeError("Active object must be a light")
    keying_set = None
    if type == 'KEYINGSET':
        keying_set = context.scene.keying_sets.active
        if keying_set is None:
            raise RuntimeError("No active Keying Set to use")
        if len(keying_set.paths) == 0:
            raise RuntimeError("Keying Set does not contain any paths")
    collections = None
    if type == 'COLLECTION':
        collections = _grouped_collections(ob)
        if len(collections) > 1:
            raise RuntimeError("%s is in %d collections (%s), and Blender asks which one in a menu. "
                               "Use Select ▸ Select Pattern… or the Outliner for one of them."
                               % (ob.name, len(collections),
                                  ", ".join(c.name for c in collections)))

    changed = False
    if not extend:
        # base_deselect_all(SEL_DESELECT): every visible object.
        for o in context.visible_objects:
            if o.select_get():
                o.select_set(False)
                changed = True

    def selectable():
        return list(context.selectable_objects)

    def take(o):
        nonlocal changed
        if not o.select_get():
            o.select_set(True)
            changed = True

    if type in ('CHILDREN_RECURSIVE', 'CHILDREN'):
        def children(parent):
            for o in selectable():
                if o.parent == parent:
                    take(o)
                    if type == 'CHILDREN_RECURSIVE':
                        children(o)
        children(ob)
    elif type == 'PARENT':
        # Makes the parent active, as `select_grouped_parent` does.
        parent = ob.parent
        if parent is not None and parent.name in layer.objects and parent in selectable():
            take(parent)
            layer.objects.active = parent
            changed = True
    elif type == 'SIBLINGS':
        for o in selectable():
            if o.parent == ob.parent:
                take(o)
    elif type == 'TYPE':
        for o in selectable():
            if o.type == ob.type:
                take(o)
    elif type == 'COLLECTION':
        if collections:
            members = collections[0].objects
            shown = set(context.visible_objects)
            for o in selectable():
                if o in shown and o.name in members and members[o.name] == o:
                    take(o)
    elif type == 'HOOK':
        for modifier in ob.modifiers:
            target = getattr(modifier, 'object', None) if modifier.type == 'HOOK' else None
            if target is not None and target.name in layer.objects and target in selectable():
                take(target)
    elif type == 'PASS':
        for o in selectable():
            if o.pass_index == ob.pass_index:
                take(o)
    elif type == 'COLOR':
        for o in selectable():
            if all(abs(a - b) <= 0.005 for a, b in zip(o.color[:3], ob.color[:3])):
                take(o)
    elif type == 'KEYINGSET':
        ids = {path.id for path in keying_set.paths if path.id is not None}
        for o in selectable():
            if o in ids:
                take(o)
    elif type == 'LIGHT_TYPE':
        for o in selectable():
            if o.type == 'LIGHT' and o.data.type == ob.data.type:
                take(o)
    return {'FINISHED'} if changed else {'CANCELLED'}
