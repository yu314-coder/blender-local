"""The N panel's Item tab: Blender's Transform panel, typed into.

In Edit Mode Blender's Item ▸ Transform panel is `v3d_editvertex_buts`
(view3d_buttons.cc, read in the 5.3 source the app is built from): the
selection's Median (or one Vertex) as X, Y and Z, Global or Local, then the
Vertex Data and Edge Data rows — Bevel Weight and Vertex Crease, Bevel Weight
and Crease, "Mean …" with more than one selected. Typing a number moves every
selected vertex by the difference, or puts a lone vertex at it, and scales the
weights towards the typed mean. That code runs only from a button, which a bpy
module has none of, so this is it, on the edit mesh through bmesh, as one
command the bridge records as one undo step.

In Object Mode the panel's Dimensions are `v3d_object_dimension_buts`: a
typed size sets the scale on that axis (`BKE_object_dimensions_set_ex`), and
the panel hands it the scale and world matrix from before, so a parent's or a
delta scale is allowed for. `obj.dimensions = …` does not: its setter passes
neither, and under a parent scaled 2 a cube typed to 2 came back 4 (the
transformtools check's negative control). So `set_dimension` is the panel's
arithmetic, one axis at a time. It is offered in Object Mode only, as
Blender's Item tab offers it: Blender's Edit Mode undo keeps only the mesh.

Blender's fields take any number up to FLT_MAX and keep whatever comes of it;
these refuse, and put back, a result that is not a finite number in Blender's
float32 — a coordinate, a scale, or the Median and Dimensions the panels read
back — and what they read back is JSON the app can always parse, a
non-finite number in it written as Blender's UI prints it ('inf', 'nan').
"""

import json
import math

import bpy
from mathutils import Vector

# The edit mesh's float attributes the rows read and write, as 5.x names
# them (`CustomData_get_offset_named(…, CD_PROP_FLOAT, "bevel_weight_vert")`).
LAYERS = {
    'bevel_weight_vert': 'verts',
    'crease_vert': 'verts',
    'bevel_weight_edge': 'edges',
    'crease_edge': 'edges',
}
# Blender's names for those fields (the Item tab's Vertex Data and Edge Data).
_DATA_LABELS = {'bevel_weight_vert': 'Vertex Bevel Weight', 'crease_vert': 'Vertex Crease',
                'bevel_weight_edge': 'Edge Bevel Weight', 'crease_edge': 'Edge Crease'}


# The object types Blender's Item tab draws Dimensions for
# (`view3d_panel_transform`: OB_TYPE_SUPPORT_EDITMODE, Volume, Curves, Point
# Cloud). An Empty, a Camera, a Light, a Speaker, a Light Probe get none.
DIMENSIONED = {'MESH', 'FONT', 'CURVE', 'SURFACE', 'META', 'LATTICE', 'ARMATURE',
               'CURVES', 'POINTCLOUD', 'GREASEPENCIL', 'VOLUME'}


def _number(x):
    """A float for the JSON the app reads: a non-finite one as Blender's UI
    prints it ('inf', '-inf', 'nan'), a string, because json.dumps would
    write Infinity or NaN, which JSONSerialization refuses — and the Item
    tab then stuck on "Reading the selection from Blender" while Dimensions
    went missing (round 4's review, after Median X 3e38)."""
    x = float(x)
    if math.isfinite(x):
        return x
    return 'nan' if math.isnan(x) else ('inf' if x > 0 else '-inf')


def _finite(values):
    return all(math.isfinite(float(c)) for c in values)


def _edit_mesh():
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH' or obj.mode != 'EDIT':
        return None
    return obj


def _bmesh(obj):
    import bmesh
    return bmesh.from_edit_mesh(obj.data)


def _layer(bm, name):
    return getattr(bm, LAYERS[name]).layers.float.get(name)


def _gather(obj):
    """What `v3d_editvertex_buts` sums: the selected vertices (`tot`), their
    location and vertex weights, and the selected edges (`totedgedata`) and
    their weights — every selected edge counted even with neither edge
    layer, whose means are then 0."""
    bm = _bmesh(obj)
    vw = _layer(bm, 'bevel_weight_vert')
    vc = _layer(bm, 'crease_vert')
    ew = _layer(bm, 'bevel_weight_edge')
    ec = _layer(bm, 'crease_edge')
    verts = [v for v in bm.verts if v.select]
    edges = [e for e in bm.edges if e.select]
    sums = {'bevel_weight_vert': 0.0, 'crease_vert': 0.0,
            'bevel_weight_edge': 0.0, 'crease_edge': 0.0}
    location = Vector((0.0, 0.0, 0.0))
    for v in verts:
        location += v.co
        if vw is not None:
            sums['bevel_weight_vert'] += v[vw]
        if vc is not None:
            sums['crease_vert'] += v[vc]
    for e in edges:
        if ew is not None:
            sums['bevel_weight_edge'] += e[ew]
        if ec is not None:
            sums['crease_edge'] += e[ec]
    return bm, verts, edges, location, sums


def state(use_global=True):
    """One line of JSON: the panel's rows as Blender draws them now. It reads
    after every change and tap, so it never raises: what went wrong comes back
    as no mesh, with the error."""
    obj = _edit_mesh()
    if obj is None:
        return json.dumps({'mesh': False})
    try:
        return _state(obj, use_global)
    except Exception as error:
        return json.dumps({'mesh': False, 'error': '%s: %s' % (type(error).__name__, error)})


def _state(obj, use_global):
    bm, verts, edges, location, sums = _gather(obj)
    tot = len(verts)
    out = {'mesh': True, 'object': obj.name, 'tot': tot, 'edges': len(edges)}
    if tot:
        median = _median(obj, location, tot, use_global)
        out['median'] = [_number(c) for c in median]
        out['bevel_weight_vert'] = _number(sums['bevel_weight_vert'] / tot)
        out['crease_vert'] = _number(sums['crease_vert'] / tot)
    if edges:
        out['bevel_weight_edge'] = _number(sums['bevel_weight_edge'] / len(edges))
        out['crease_edge'] = _number(sums['crease_edge'] / len(edges))
    return json.dumps(out, allow_nan=False)


def _median(obj, location, tot, use_global):
    """The Median as the panel shows it: the float32 sum over the count, in
    the world's space or the object's."""
    median = location / tot
    if use_global:
        median = obj.matrix_world @ median
    return median


def _refuse_without_selection(obj):
    if obj is None:
        raise RuntimeError("The Item tab's Median edits a mesh in Edit Mode, and no mesh is being edited.")


def set_median(axis, value, use_global=True):
    """The Median (or Vertex) X, Y or Z field: the selection's median moved to
    `value` on `axis`, in the object's own space or the world's."""
    obj = _edit_mesh()
    _refuse_without_selection(obj)
    axis = int(axis)
    if axis not in (0, 1, 2):
        raise ValueError("axis is 0, 1 or 2")
    value = float(value)
    if not math.isfinite(value):
        raise RuntimeError("Type a number for the Median.")
    bm, verts, _edges, location, _sums = _gather(obj)
    tot = len(verts)
    if tot == 0:
        raise RuntimeError("Nothing selected")
    median = location / tot
    shown = median.copy()
    if use_global:
        shown = obj.matrix_world @ median
    typed = shown.copy()
    typed[axis] = value
    if use_global:
        # "invert_m4_m4(world_to_object, object_to_world)" — both the median
        # it showed and the one typed go back into the object's space.
        try:
            inverse = obj.matrix_world.inverted()
        except ValueError:
            raise RuntimeError("The object's scale is zero on an axis, so a world position "
                               "cannot be turned back into its own space.") from None
        old = inverse @ shown
        new = inverse @ typed
    else:
        old = median
        new = typed
    diff = new - old
    if tot != 1 and diff.length_squared == 0.0:
        return
    # Where the vertices are is what a Remesh, an Array's size or a Boolean
    # after them reads: priced, exactly, before Blender evaluates the move,
    # and taken back when that is past the budget (_blenderkit_gate.editing).
    with _gate().editing("Median", moving=True):
        _move_median(obj, bm, axis, tot, verts, new, diff)


def _gate():
    import sys
    gate = sys.modules.get('_blenderkit_gate')
    if gate is None:
        try:
            import _blenderkit_gate as gate
        except ImportError:
            import contextlib

            class _NoGate:
                @staticmethod
                def editing(*_a, **_k):
                    return contextlib.nullcontext()
            return _NoGate
    return gate


def _move_median(obj, bm, axis, tot, verts, new, diff):
    saved = [v.co.copy() for v in verts]
    if tot == 1:
        # apply_raw_diff_v3: one vertex is put where it was typed.
        verts[0].co = new
    else:
        for v in verts:
            v.co += diff
    _finish(obj, bm)
    # Blender's panel takes any number up to FLT_MAX and leaves what it
    # makes; here a result that is not a finite number in Blender's float32 —
    # a coordinate, the Median the panel reads back, the Dimensions — is put
    # back and refused. Measured in 5.2.1 before this: Median X 3e38 on a
    # selected cube left the median [inf, nan, nan], and a -3e38 after it
    # the vertices at -inf.
    if not _finite_after(obj):
        bm = _bmesh(obj)
        for v, co in zip([v for v in bm.verts if v.select], saved):
            v.co = co
        _finish(obj, bm)
        raise RuntimeError("%s %s would leave a coordinate, the Median or the Dimensions that is not a "
                           "finite number in Blender (its 32-bit floats reach about 3.4e38), so nothing "
                           "was moved." % ("Vertex" if tot == 1 else "Median", 'XYZ'[axis]))


def _finite_after(obj):
    """Whether the edit mesh, the Median the panel reads (in both spaces) and
    the object's Dimensions are all finite numbers."""
    bm, verts, _edges, location, _sums = _gather(obj)
    if not all(_finite(v.co) for v in bm.verts):
        return False
    if verts:
        for space in (True, False):
            if not _finite(_median(obj, location, len(verts), space)):
                return False
    bpy.context.evaluated_depsgraph_get()
    return _finite(obj.dimensions)


def _scale_factor(new, diff):
    """compute_scale_factor: 0 or 1 to set outright, a positive factor to
    scale down, a negative one to scale up."""
    if new <= 0.0:
        return 0.0
    if new >= 1.0:
        return 1.0
    median_new = min(max(new, 0.0), 1.0)
    median_orig = min(max(new - diff, 0.0), 1.0)
    if median_new <= median_orig:
        return median_new / median_orig
    return -(1.0 - median_new) / (1.0 - median_orig)


def _apply_clamped(val, tot, new, sca):
    """apply_scale_factor_clamp."""
    if tot == 1:
        return min(max(new, 0.0), 1.0)
    if sca in (0.0, 1.0):
        return sca
    val = val * sca if sca > 0.0 else 1.0 + (1.0 - val) * sca
    return min(max(val, 0.0), 1.0)


def set_data(name, value):
    """A Vertex Data or Edge Data field: the selection's mean weight moved to
    `value` as Blender's panel moves it, the layer added the first time.
    `tot` is the number of selected vertices for the edges too, as in
    Blender's apply (`apply_scale_factor_clamp(b_weight, tot, …)`)."""
    if name not in LAYERS:
        raise ValueError("one of " + ", ".join(sorted(LAYERS)))
    obj = _edit_mesh()
    _refuse_without_selection(obj)
    value = float(value)
    if not math.isfinite(value):
        raise RuntimeError("Type a number between 0 and 1.")
    # The field's own range, 0 to 1.
    value = min(max(value, 0.0), 1.0)
    bm, verts, edges, _location, sums = _gather(obj)
    tot = len(verts)
    elements = verts if LAYERS[name] == 'verts' else edges
    if not elements:
        raise RuntimeError("Nothing selected")
    mean = sums[name] / len(elements)
    diff = value - mean
    if diff == 0.0:
        return
    seq = getattr(bm, LAYERS[name])
    layer = seq.layers.float.get(name)
    if layer is None:
        layer = seq.layers.float.new(name)
        # A new layer moves every element's data: the references gathered
        # above are gone ("BMesh data of type BMVert has been removed",
        # measured in 5.2.1), so they are gathered again.
        bm, verts, edges, _location, _sums = _gather(obj)
        elements = verts if LAYERS[name] == 'verts' else edges
    sca = _scale_factor(value, diff)
    # A Bevel limited by Weight bevels the edges with a weight, so the field
    # can make a Bevel's count: priced, exactly, before Blender evaluates
    # it, and taken back when that is past the budget
    # (_blenderkit_gate.editing). Round 4's fix round 2 review: Bevel Weight
    # 1 on a 120 × 120 grid under such a Bevel at 14 segments made 3,139,984
    # with no refusal.
    with _gate().editing(_DATA_LABELS.get(name, name)):
        for ele in elements:
            ele[layer] = _apply_clamped(ele[layer], tot, value, sca)
        _finish(obj, bm)


def _finish(obj, bm):
    import bmesh
    bm.normal_update()
    bmesh.update_edit_mesh(obj.data)


# ---------------------------------------------------------------------------
# Dimensions
# ---------------------------------------------------------------------------

def dimensions(name):
    """The object's Dimensions as Blender reports them, after evaluating — in
    Edit Mode the edit mesh's, as Blender's are, edits included — or null for
    a type Blender's Item tab draws no Dimensions for."""
    obj = bpy.data.objects[name]
    if obj.type not in DIMENSIONED:
        return json.dumps(None)
    bpy.context.evaluated_depsgraph_get()
    d = obj.dimensions
    return json.dumps([_number(d[0]), _number(d[1]), _number(d[2])], allow_nan=False)


def _budget():
    """The vertex budget (_blenderkit_budget.py), imported or — where the site
    folder is not on the path, as in the desktop checks — loaded from its file."""
    import sys
    module = sys.modules.get('_blenderkit_budget')
    if module is None:
        try:
            import _blenderkit_budget as module
        except ImportError:
            import importlib.util
            import os
            spec = importlib.util.spec_from_file_location(
                '_blenderkit_budget', os.path.join(os.path.dirname(__file__), '_blenderkit_budget.py'))
            module = importlib.util.module_from_spec(spec)
            sys.modules['_blenderkit_budget'] = module
            try:
                spec.loader.exec_module(module)
            except BaseException:
                sys.modules.pop('_blenderkit_budget', None)
                raise
    return module


def set_dimension(name, axis, value):
    """One Dimensions field, as Blender's N panel writes it
    (`BKE_object_dimensions_set_ex` with the other axes masked): the scale on
    `axis` that gives the object `value` across in the world."""
    obj = bpy.data.objects[name]
    axis = int(axis)
    if axis not in (0, 1, 2):
        raise ValueError("axis is 0, 1 or 2")
    if obj.type not in DIMENSIONED:
        kind = bpy.types.Object.bl_rna.properties['type'].enum_items[obj.type].name
        raise RuntimeError("Blender's Item tab has no Dimensions for %s: it is %s %s."
                           % (obj.name, 'an' if kind[0] in 'AEIOU' else 'a', kind))
    # Blender's Item tab has no Dimensions in Edit Mode, and its Edit Mode
    # undo keeps only the mesh: measured with the app's undo in 5.2.1, X
    # typed 5 there made the scale (2.5, 1, 1) and Undo left it so, its step
    # gone (round 4's review). So the size is set in Object Mode.
    if bpy.context.mode.startswith('EDIT'):
        raise RuntimeError("Dimensions are set in Object Mode, as Blender's Item tab offers them: "
                           "in Edit Mode Blender's undo keeps only the mesh, so a scale set here "
                           "could not be undone.")
    value = float(value)
    if not math.isfinite(value) or value < 0.0:
        raise RuntimeError("A dimension is a size: type a number of 0 or more.")
    bpy.context.evaluated_depsgraph_get()
    corners = [Vector(c) for c in obj.bound_box]
    if not corners:
        raise RuntimeError(obj.name + " has no size to set.")
    low = Vector([min(c[i] for c in corners) for i in range(3)])
    high = Vector([max(c[i] for c in corners) for i in range(3)])
    length = high[axis] - low[axis]
    scale = obj.scale[axis]
    if scale != 0.0:
        delta = obj.matrix_world.col[axis].xyz.length / scale
        if math.isfinite(delta):
            length *= delta
    new = math.copysign(value / length, scale) if length != 0.0 else math.inf
    if not math.isfinite(new):
        raise RuntimeError("%s has no size along %s for a dimension to scale."
                           % (obj.name, 'XYZ'[axis]))
    old = obj.scale[axis]
    # Priced first, as the Data API row and the Transform fields are: the
    # scale is what an Array fitted to a length, or anything that reads this
    # object's place, counts by (round 4's fix-round review).
    scale_after = list(obj.scale)
    scale_after[axis] = new
    _budget().price(obj, 'scale', tuple(scale_after), "Dimensions %s %g" % ('XYZ'[axis], value))
    obj.scale[axis] = new
    # Finite in Blender's float32 too, and the Dimensions it reads back: a
    # scale past about 1.8e19 makes the world matrix's axis length (a float32
    # square root of a sum of squares) infinite. Measured in 5.2.1 before
    # this: X typed 3e38 left the scale 1.5e38 and the Dimensions [inf, 2, 2].
    bpy.context.evaluated_depsgraph_get()
    if not (_finite(obj.scale) and _finite(obj.dimensions)
            and all(_finite(c) for c in obj.matrix_world.col)):
        obj.scale[axis] = old
        bpy.context.evaluated_depsgraph_get()
        raise RuntimeError("Dimensions %s would leave a scale or a size that is not a finite number in "
                           "Blender (its 32-bit floats reach about 3.4e38), so nothing was changed."
                           % 'XYZ'[axis])
