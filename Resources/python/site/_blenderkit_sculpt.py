"""Blender's own sculpt brushes, stroked from the app's 3D View.

A finger's stroke is streamed to `bpy.ops.sculpt.brush_stroke` in chunks while
it moves, and the sculpted object is mirrored back after every chunk, so what
the 3D View shows during a stroke is Blender's result, not an approximation
of it — and what is kept is exactly what was shown, because there is nothing
else: the last chunk's result is the stroke.

Everything below was measured in desktop Blender 5.2.1 under
`-b --factory-startup` with the app's context (an undo stack from
`ed.undo_push`, `gpu.init()`, a `temp_override` onto the startup screen's 3D
View), and held to it by scripts/run-sculpt-blender-check.sh:

  * The stroke runs in the 3D View Knife Project borrows (`_blenderkit_knife`),
    aimed at the app's camera: the view's rotation, pivot and distance, and a
    lens that makes one of the region's pixels the app's point (`aim`): a
    point ViewportCamera draws is the region pixel Blender's view draws it at
    to within 0.0001 px, in perspective and orthographic. Blender then
    raycasts each dab itself (`override_location`), as its modal stroke does.

  * Called by `EXEC_DEFAULT`, the operator does no spacing: every stroke
    element is one dab (`PaintStroke::exec`). Spacing is done here, the way
    `PaintStroke::space_stroke` does it, and the grab tools and Dots strokes
    get a dab for every point, as Blender gives them one per mouse event.

  * One stroke cut into separate strokes is not the same stroke: Draw
    raycasts the surface as it was when its stroke began, so a 21-dab stroke
    that moved vertices at most 0.225 as one moved them 0.289, 0.391 and 0.413
    sent as strokes of 8, 4 and 1 dabs. So each chunk undoes the stroke so far
    and replays it whole, which gives Blender's one stroke to the bit whatever
    the chunks. A stroke that grows past 64 dabs, or whose replay and rewind
    take over 25 ms, is kept as it is and goes on as a new stroke from there.
    On a Multires level, where a rewind rebuilds the level, the stroke is
    gathered and made once, when it ends (`begin`).

  * Grab, Thumb, Pose, Boundary and Elastic Grab move what is under the
    stroke's first dab by the mouse's whole travel from the original positions
    (`need_delta_from_anchored_origin`), so each chunk strokes just [first dab,
    current dab] again; dragged past the silhouette, Grab keeps pulling.

  * Called from Python without `undo=True`, a stroke pushes no undo step, and
    the step it began is freed by the next stroke's. With `undo=True` each
    pushes one Sculpt step. The steps a stroke leaves are counted on Blender's
    stack and handed to the history (`_blenderkit_undo.note_pushed`), so one
    Undo takes back the whole stroke.

  * The evaluated mesh the mirror reads is left stale by a stroke, by dynamic
    topology (its BMesh) and by an Undo in Sculpt Mode: it is flushed and
    tagged before it is read. A Multires level is not in it at all, and is
    read through a temporary object (`multires_display`), on a base mesh of
    up to MULTIRES_BASE_BUDGET vertices.

  * Nothing else runs while a stroke is open (`_refuse_during_stroke`,
    `_check_history`, `_blenderkit_undo.step`): each chunk rewinds the step on
    top of Blender's stack, taking it for its own.

Nothing here runs anywhere but the main thread, with the undo stack, the GPU,
the 3D View and a mesh in Sculpt Mode checked first, and refused in a sentence
when one is missing: without the undo stack a stroke segfaults
(`orig_position_data_lookup_mesh_all_verts`), and without the GPU
`RegionView3D.update()` does (`GPU_matrix_frustum_set`). The checks Blender's
own `invoke` makes and `exec` skips are made here too (`_require_brush_fits`).
"""

import math
import os
import time
from array import array

import bpy
from mathutils import Matrix, Vector

import _blenderkit_knife as _knife
import _blenderkit_undo as _undo

WHAT = "Sculpting"
ESSENTIALS_FILE = 'essentials_brushes-mesh_sculpt.blend'
ASSET_PREFIX = 'brushes/' + ESSENTIALS_FILE + '/Brush/'

# How a brush has to be streamed. See the module's docstring.
ANCHORED_TYPES = {'GRAB', 'POSE', 'BOUNDARY', 'THUMB', 'ELASTIC_DEFORM'}
# Blender's grab tools (sculpt_is_grab_tool in paint_stroke.cc): no spacing,
# a dab for every mouse event, and no surface needed under a dab after the
# first (paint_brush_type_require_location).
GRAB_TOOL_TYPES = ANCHORED_TYPES | {'ROTATE', 'SNAKE_HOOK'}

# A stroke is replayed whole on every chunk while it is short enough to be:
# until it has this many dabs, or one replay takes longer than this. Then what
# it has made is kept as one of Blender's steps and the next chunk starts a
# new stroke from there. Measured on the dinosaur's body (Sphere.002, 15,872
# triangles, desktop 5.2.1): a Draw stroke of 21 dabs moved vertices at most
# 0.225 as one stroke, and 0.289, 0.391 and 0.413 sent as strokes of 8, 4 and
# 1 dabs — Draw raycasts the surface as it was when the stroke began
# (`cache->accum` is false), so a stroke cut into pieces digs deeper at every
# cut. Replayed, it is Blender's one stroke.
MAX_OPEN_DABS = 64
# Counted against the replay AND the rewind before it: on a heavy state the
# rewind is most of a chunk. Measured in desktop 5.2.1: under Dynamic Topology
# on a 99,840-triangle sphere a chunk took 80-105 ms, 45-54 of them in the
# rewind, and a budget that counted only the replay never cut it.
REPLAY_BUDGET_MS = 25.0

# Sculpting on a Multires level costs what its BASE mesh costs, not what the
# level costs: every re-evaluation of the sculpted object (after a stroke is
# flushed, after any Undo of one) rebuilds the level's subdivision from the
# base mesh. Measured in desktop 5.2.1 on UV spheres at level 1, the level read
# back (`multires_display`) and one stroke step taken back (`ed.undo`):
#   base   482 vertices:    60 ms /    31 ms
#   base 1,986:            312      /   160
#   base 4,514:          1,049      /   520
#   base 8,066:          2,576      / 1,277   (flush_edits alone: 1,248)
#   base 12,642:         5,350      / 2,680
#   base 18,242:         9,822      / 4,840
#   base 49,922 (the review's 99,840-triangle sphere): 26.8 s / 13.3 s
# and the level hardly matters: the 1,986-vertex base read back in 312, 322
# and 366 ms at levels 1, 2 and 3 (8,066 to 129,026 level vertices). The app's
# own Blender does the same work about five times slower. Measured in the app
# (Designed for iPad, on this Mac) at level 1, a Draw stroke's end, its Undo
# and its Redo, each with the level mirrored back:
#   base   482:   0.44 s, 0.71 s, 0.39 s
#   base 1,986:   1.78 s, 2.69 s, 1.73 s
#   base 4,514:   5.43 s, 8.11 s, 5.48 s
# So a Multires is sculpted here only on a base mesh of up to this many
# vertices — a 64 x 32 UV sphere's 1,986 is in, at about 2.7 s for an Undo,
# the dearest thing it does.
MULTIRES_BASE_BUDGET = 2000

# Voxel Remesh's output, from the mesh's surface area in its OWN units — the
# units `object.voxel_remesh` measures `remesh_voxel_size` in
# (voxel_remesh_exec, object_remesh.cc). Measured in desktop 5.2.1, output
# vertices over (local area / voxel size²): closed shapes 1.02 (a cube) to
# 1.71 (a 0.1 sphere at a 0.02 voxel); an open plane or grid, which the
# remesher closes into a sheet with two sides, 2.08 to 2.42. 2.5 bounds all of
# them. The volume, the world size and the object's scale do not enter: an
# unscaled 0.1 sphere and a 1 m sphere scaled to 0.1 look alike in the world
# and remeshed at 0.02 to 536 and 47,648 vertices.
REMESH_VERTICES_PER_AREA = 2.5
# Peak memory per output vertex: 1,178,936 vertices took desktop Blender from
# 395 to 925 MB (450 bytes each); rounded up as the Multires budget's is, for
# the undo step and the viewport's copy (_blenderkit_multires).
REMESH_PEAK_BYTES_PER_VERTEX = 800


# A stroke or an operation that was not made, and why, in words the banner
# shows. A plain RuntimeError, so the banner reads the sentence and not the
# name of an exception class (BpyBridge.readable strips "RuntimeError: ").
Refusal = RuntimeError


def _is_real_blender():
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _refuse_during_stroke(what):
    """Nothing but the stroke's own chunks may touch the sculpt while a stroke
    is open: each chunk rewinds the step the stroke pushed last, so a step
    pushed between chunks would be the one rewound. Measured in desktop 5.2.1
    with this module: Mask ▸ Fill between two chunks was listed in the history
    and then undone by the next chunk's rewind (masked 1,986 -> 0), and the
    first chunk, no longer the step on top, was applied twice."""
    if _stroke is not None:
        raise Refusal(what + " waits until the sculpt stroke in progress has ended.")


def _sculpt_settings():
    return bpy.context.scene.tool_settings.sculpt


def _unified():
    return _sculpt_settings().unified_paint_settings


def _brush():
    return _sculpt_settings().brush


def _is_grab_tool(brush):
    kind = brush.sculpt_brush_type
    if kind == 'CLOTH' and getattr(brush, 'cloth_deform_type', '') == 'GRAB':
        return True
    return kind in GRAB_TOOL_TYPES


def _needs_location(brush):
    """paint_brush_type_require_location: whether a dab with no surface under
    it is dropped (most brushes) or still applied (the grab tools and the
    cloth deform brushes, which carry the first dab's location)."""
    kind = brush.sculpt_brush_type
    cloth_deform = (kind == 'CLOTH' and getattr(brush, 'cloth_deform_type', '') in ('GRAB', 'SNAKE_HOOK')) \
        or (kind != 'CLOTH' and getattr(brush, 'deform_target', 'GEOMETRY') == 'CLOTH_SIM')
    return not (kind in GRAB_TOOL_TYPES or cloth_deform)


def strategy(brush):
    """How a stroke with `brush` is streamed, or None for one this cannot
    make (a Curve stroke, which follows a paint curve Blender edits in a modal
    tool of its own).

    'anchored': the brush moves what is under its first dab by the mouse's
    whole travel, from the original positions (need_delta_from_anchored_origin
    in sculpt.cc, and the Anchored and Drag Dot strokes), so each chunk strokes
    [first dab, current dab] again. 'line': a Line stroke, straight from the
    first point to the current one. 'replay': everything else, replayed whole
    while it fits the budget above.
    """
    kind = brush.sculpt_brush_type
    method = brush.stroke_method
    if method == 'CURVE':
        return None
    cloth_sim = kind == 'CLOTH' or getattr(brush, 'deform_target', 'GEOMETRY') == 'CLOTH_SIM'
    if (kind in ANCHORED_TYPES and not cloth_sim) or method in ('ANCHORED', 'DRAG_DOT'):
        return 'anchored'
    if method == 'LINE':
        return 'line'
    return 'replay'


# --------------------------------------------------------------------------
# The brushes

_names = None


def essentials_path():
    """Blender's Essentials sculpt brushes, or '' when this build has none."""
    try:
        folder = bpy.utils.system_resource('DATAFILES', path='assets/brushes')
    except Exception:                               # noqa: BLE001 - no library is the answer
        return ''
    path = os.path.join(folder, ESSENTIALS_FILE) if folder else ''
    return path if path and os.path.isfile(path) else ''


def brushes():
    """The names of Blender's Essentials sculpt brushes, sorted; [] without
    the library. Read from the file without loading anything into the scene."""
    global _names
    if _names is None:
        path = essentials_path()
        if not path:
            return []
        with bpy.data.libraries.load(path, assets_only=True) as (source, _):
            _names = sorted(source.brushes)
    return list(_names)


def activate(name):
    """Makes an Essentials brush the sculpt brush, as the asset shelf does."""
    if name not in brushes():
        if not essentials_path():
            raise Refusal("Blender's Essentials brushes are not in this build, so there "
                          "is no " + name + " brush to pick.")
        raise Refusal("There is no Essentials sculpt brush called " + repr(name) + ".")
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.mode != 'SCULPT':
        raise Refusal("Pick a sculpt brush in Sculpt Mode.")
    _refuse_during_stroke("Picking a brush")
    result = bpy.ops.brush.asset_activate(asset_library_type='ESSENTIALS',
                                          relative_asset_identifier=ASSET_PREFIX + name)
    if 'FINISHED' not in result or _brush() is None or _brush().name != name:
        raise Refusal("Blender could not load the " + name + " brush.")
    return name


def _size_owner():
    ups = _unified()
    return ups if ups.use_unified_size else _brush()


def _strength_owner():
    ups = _unified()
    return ups if ups.use_unified_strength else _brush()


def set_size(value):
    """Blender's brush Size: the diameter in pixels of the region the stroke
    runs in. Written where Blender reads it — the scene's unified setting while
    Unified Size is on (the default), the brush's own otherwise."""
    owner = _size_owner()
    if owner is None:
        raise Refusal("There is no sculpt brush to size.")
    # Every chunk replays the whole stroke at the size it reads then.
    _refuse_during_stroke("Size")
    owner.size = int(round(value))
    return owner.size


def set_strength(value):
    owner = _strength_owner()
    if owner is None:
        raise Refusal("There is no sculpt brush to set the strength of.")
    _refuse_during_stroke("Strength")
    owner.strength = float(value)
    return owner.strength


def _attribute_values(mesh, name, domain):
    attribute = mesh.attributes.get(name)
    if attribute is None or attribute.domain != domain:
        return None
    count = len(attribute.data)
    kind = 'f' if attribute.data_type == 'FLOAT' else 'i'
    values = array(kind, [0]) * count
    attribute.data.foreach_get('value', values)
    return values


def state():
    """What the sculpt header shows, as Blender holds it."""
    real = _is_real_blender()
    obj = bpy.context.view_layer.objects.active
    brush = _brush() if real else None
    ups = _unified() if real else None
    report = dict(real=real, essentials=bool(essentials_path()) if real else False,
                  object=obj.name if obj is not None else None,
                  mode=getattr(obj, 'mode', 'OBJECT') if obj is not None else 'OBJECT',
                  brush=brush.name if brush is not None else None)
    if not real:
        return report
    try:
        _, _, region = _knife.view3d(WHAT)
        report['region'] = [region.width, region.height]
    except RuntimeError:
        report['region'] = None
    if brush is not None:
        size, strength = _size_owner(), _strength_owner()
        report.update(size=size.size, strength=round(strength.strength, 4),
                      unified_size=ups.use_unified_size, unified_strength=ups.use_unified_strength,
                      brush_type=brush.sculpt_brush_type, stroke_method=brush.stroke_method,
                      spacing=brush.spacing, direction=getattr(brush, 'direction', ''),
                      strategy=strategy(brush))
    steps = _undo.blender_steps()
    report['undo_stack'] = len(steps) if steps is not None else None
    sculpt = _sculpt_settings()
    report.update(detail_type=sculpt.detail_type_method, detail_size=round(sculpt.detail_size, 4),
                  detail_percent=round(sculpt.detail_percent, 4),
                  detail_resolution=round(sculpt.constant_detail_resolution, 4))
    if obj is not None and obj.type == 'MESH':
        mesh = obj.data
        # The voxel size is in the mesh's own units (see REMESH_VERTICES_PER_AREA),
        # so the header says what scale stands between them and the scene's.
        scale = obj.matrix_world.to_scale()
        report.update(dyntopo=bool(obj.use_dynamic_topology_sculpting),
                      voxel_size=round(mesh.remesh_voxel_size, 6),
                      scale=[round(s, 6) for s in scale],
                      vertices=len(mesh.vertices), faces=len(mesh.polygons),
                      multires_base_budget=MULTIRES_BASE_BUDGET)
        multires = next((m for m in obj.modifiers if m.type == 'MULTIRES'), None)
        report['multires'] = (dict(name=multires.name, levels=multires.levels,
                                   sculpt_levels=multires.sculpt_levels,
                                   total_levels=multires.total_levels)
                              if multires is not None else None)
        # Under dynamic topology the mesh holds what was last flushed from the
        # BMesh; the mask and face sets are read from it all the same.
        if active_multires(obj) is not None:
            # On a Multires level the mask lives in grid layers that no Python
            # API reads: after Mask ▸ Fill on a level, the mesh's '.sculpt_mask'
            # still counted 0 (desktop 5.2.1). Unknown, not zero.
            report['masked'] = None
        else:
            mask = _attribute_values(mesh, '.sculpt_mask', 'POINT')
            report['masked'] = sum(1 for v in mask if v > 0.0) if mask is not None else 0
        sets = _attribute_values(mesh, '.sculpt_face_set', 'FACE')
        report['face_sets'] = len(set(sets)) if sets is not None else 0
    return report


# --------------------------------------------------------------------------
# Preconditions

def _require(name):
    """The object a stroke on `name` would sculpt, with everything a stroke
    needs checked, or a Refusal that says what is missing."""
    if not _is_real_blender():
        raise Refusal("Blender's sculpt brushes run in Blender, and the simulator's "
                      "stand-in for Blender does not have them.")
    if not _knife.on_main_thread():
        raise Refusal("Sculpting aims Blender's 3D View, which exists on the main thread only.")
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        raise Refusal("Sculpting needs an object. Select a mesh first.")
    if obj.name != name:
        raise Refusal("Sculpting works on the active object, and " + name + " is not it.")
    if obj.type != 'MESH':
        raise Refusal("Sculpting works on meshes, and " + obj.name + " is not one.")
    if obj.mode != 'SCULPT':
        raise Refusal(obj.name + " is not in Sculpt Mode.")
    if not obj.visible_get():
        raise Refusal(obj.name + " is hidden. Show it to sculpt it.")
    if not obj.data.polygons:
        raise Refusal(obj.name + " has no faces to sculpt.")
    brush = _brush()
    if brush is None:
        raise Refusal("There is no sculpt brush: Blender's Essentials brushes are not in "
                      "this build." if not essentials_path() else
                      "There is no sculpt brush. Pick one in the Brush menu.")
    if strategy(brush) is None:
        raise Refusal("The " + brush.name + " brush draws along a paint curve, which Blender "
                      "edits in a modal tool this app cannot run. Pick a Space or Dots stroke.")
    _require_brush_fits(obj, brush)
    _require_multires_fits(obj)
    _knife.require_gpu_context(WHAT)
    _require_undo_stack()
    return obj


def multires_base_refusal(obj, what=None):
    """Why `obj`'s Multires level is too heavy to sculpt here, or None. See
    MULTIRES_BASE_BUDGET. `what` names an operation that would add a level."""
    count = len(obj.data.vertices)
    if count <= MULTIRES_BASE_BUDGET:
        return None
    lead = (what + ": " if what else "")
    return (lead + "%s's base mesh has %s vertices. On a Multires level Blender rebuilds the "
            "level from the base mesh after every stroke and every Undo (measured in this app: "
            "8 s for an Undo on a 4,514-vertex base, 2.7 s on 1,986), so it sculpts Multires "
            "on base meshes of up to %s vertices. Dynamic Topology or Voxel Remesh add "
            "detail without it." % (obj.name, format(count, ','), format(MULTIRES_BASE_BUDGET, ',')))


def _require_multires_fits(obj):
    if active_multires(obj) is None:
        return
    said = multires_base_refusal(obj)
    if said is not None:
        raise Refusal(said + " To sculpt " + obj.name + "'s base mesh instead, set the "
                      "Multires's Sculpt level to 0.")


def refuse_heavy_multires():
    """Sculpt Mode's way in: refused, before Blender enters it, for an object
    whose Multires level is too heavy to sculpt here (MULTIRES_BASE_BUDGET):
    entering would read the level back, 26.8 s on the review's 49,922-vertex
    base, and every stroke after it would cost as much again. Nothing on the
    simulator's stand-in, which has no Multires."""
    if not _is_real_blender():
        return
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH' or active_multires(obj) is None:
        return
    said = multires_base_refusal(obj)
    if said is not None:
        raise Refusal(said + " Set the Multires's Sculpt level to 0 in the Modifiers panel "
                      "to sculpt " + obj.name + "'s base mesh.")


# The brushes that paint colour, blur it or smear it (brush_type_is_paint).
PAINT_TYPES = {'PAINT', 'SMEAR', 'BLUR'}
# Multires's own brushes, which work on its grids.
MULTIRES_TYPES = {'DISPLACEMENT_ERASER', 'DISPLACEMENT_SMEAR'}
# The brushes that change only an attribute, not the shape.
ATTRIBUTE_TYPES = PAINT_TYPES | {'MASK', 'DRAW_FACE_SETS'}


def active_multires(obj):
    """The Multires modifier Blender sculpts on, or None: enabled in the
    viewport, sculpting at a level above 0 and not on its base mesh, and not
    under dynamic topology (BKE_sculpt_multires_active)."""
    if obj.use_dynamic_topology_sculpting:
        return None
    for modifier in obj.modifiers:
        if modifier.type == 'MULTIRES' and modifier.show_viewport:
            if modifier.sculpt_levels > 0 and modifier.total_levels > 0 \
                    and not getattr(modifier, 'use_sculpt_base_mesh', False):
                return modifier
    return None


def _require_brush_fits(obj, brush):
    """What `sculpt_brush_stroke_invoke` refuses before a stroke starts, and
    `brush_stroke` called by EXEC_DEFAULT, as here, does not: without these
    checks the exec path takes Blender down. Measured in desktop 5.2.1 with the
    app's context: Erase Multires Displacement on a mesh with no Multires
    segfaults in do_brush_action; Paint Hard under dynamic topology aborts
    (std::bad_variant_access), and on a Multires level aborts too
    ("unreachable" in fill_node_data_grids). Blender's invoke says the same
    three things in its own words, which are used here."""
    kind = brush.sculpt_brush_type
    if kind in PAINT_TYPES:
        if obj.use_dynamic_topology_sculpting:
            raise Refusal("The " + brush.name + " brush is not supported in dynamic topology "
                          "mode. Turn Dynamic Topology off to paint.")
        if active_multires(obj) is not None:
            raise Refusal("The " + brush.name + " brush is not supported in multiresolution "
                          "mode.")
    if kind in MULTIRES_TYPES and active_multires(obj) is None:
        raise Refusal("The " + brush.name + " brush is only supported in multiresolution "
                      "mode: " + obj.name + " has no Multires level to sculpt. Use "
                      "Remesh ▸ Multires Subdivide first.")
    if kind not in ATTRIBUTE_TYPES:
        key = obj.active_shape_key
        if key is not None and getattr(key, 'lock_shape', False):
            raise Refusal("The active shape key of " + obj.name + " is locked.")
        if key is not None and key.mute:
            raise Refusal("The active shape key of " + obj.name + " is muted.")


def _ensure_mask_layer(obj):
    """The mask the Mask brush writes. On a Multires level it lives in a grid
    layer that only the brush's invoke and the mask operators create, and a
    Mask stroke by EXEC_DEFAULT on a Multires object without it crashed desktop
    5.2.1. A box mask gesture outside the view creates the layer and masks
    nothing (measured: FINISHED, and the Mask stroke after it ran). Its undo
    step is one of the stroke's, counted with the rest. Without Multires the
    brush makes `.sculpt_mask` itself (measured), and nothing is needed."""
    if active_multires(obj) is None:
        return
    window, area, region = _knife.view3d(WHAT)
    with bpy.context.temp_override(window=window, area=area, region=region):
        result = bpy.ops.paint.mask_box_gesture(xmin=-20, xmax=-10, ymin=-20, ymax=-10, value=1.0)
    if 'FINISHED' not in result:
        raise Refusal("Blender could not make the mask layer the Mask brush writes.")


def _require_undo_stack():
    """Blender's undo stack, which a stroke writes its original positions to:
    without it `brush_stroke` segfaults. Created if Blender has none, in the
    one way it can be (`ed.undo_push`, which needs the main thread's window).
    Returns the number of steps created for it (0 or 1)."""
    steps = _undo.blender_steps()
    if steps:
        return 0
    context = bpy.context
    if context.window is None or context.screen is None:
        raise Refusal("Sculpting needs Blender's undo, which this thread has no window for.")
    if steps is None and bpy.ops.ed.undo.poll():
        # Unreadable, but an undo is possible: the stack is there.
        return 0
    result = bpy.ops.ed.undo_push(message=WHAT)
    if 'FINISHED' not in result:
        raise Refusal("Blender's undo could not be started, and a stroke needs it.")
    return 1


# --------------------------------------------------------------------------
# The view

def _camera_rotation(camera):
    """The app camera's axes in world space: right, up and back (toward the eye).

    `ViewportCamera` builds them from its angles: the eye is at
    target + (cos e sin a, -cos e cos a, sin e) × distance, right is
    (cos a, sin a, 0) and up is (-sin e sin a, sin e cos a, cos e).
    """
    a, e = camera['azimuth'], camera['elevation']
    right = Vector((math.cos(a), math.sin(a), 0.0))
    up = Vector((-math.sin(e) * math.sin(a), math.sin(e) * math.cos(a), math.cos(e)))
    back = Vector((math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e)))
    return Matrix((right, up, back)).transposed()


def mapping(region_size, view):
    """(scale, W, H, w, h): region pixels per app point, and the two sizes.

    One region pixel per point when the app's view fits in Blender's region,
    so Blender's brush Size in pixels is the circle drawn in points; scaled
    down to fit otherwise. The two views share their centre."""
    W, H = region_size
    w, h = view
    scale = min(1.0, W / w, H / h)
    return scale, W, H, w, h


def to_region(point, mapped):
    scale, W, H, w, h = mapped
    x, y = point[0], point[1]
    return (W / 2.0 + (x - w / 2.0) * scale, H / 2.0 + (h / 2.0 - y) * scale)


def aim(space, rv3d, region, camera, view):
    """Points Blender's 3D View where the app's camera looks, with a lens that
    gives it the app's projection under `mapping`.

    Blender's perspective focal length is lens × max(W, H) / 72 pixels
    (measured: 1093.06 px for a 50 mm lens in a 1574 px region, 655.83 for
    30 mm), and orthographic one world unit is lens × max(W, H) / (72 ×
    view_distance) pixels (109.31 at 10 m and 50 mm). The app's is
    (h / 2) / tan(fovY / 2) points in both, orthographic at its pivot distance
    (`ViewportCamera.projectionMatrix`). So one lens serves both."""
    # `update()` below segfaults without a GPU context (GPU_matrix_frustum_set,
    # from view3d_winmatrix_set): measured when this check's own call to aim()
    # came before any stroke had started the GPU module. So aim() asks for it
    # itself, whoever calls it; it costs nothing once the GPU is up.
    _knife.require_gpu_context(WHAT)
    mapped = mapping((region.width, region.height), view)
    scale, W, H, w, h = mapped
    focal = (h / 2.0) / math.tan(camera['fov_y'] / 2.0)
    lens = 72.0 * scale * focal / max(W, H)
    if not 1.0 <= lens <= 250.0:
        raise Refusal("The view is too wide or too narrow for Blender's 3D View to match "
                      "(it would need a %.1f mm lens)." % lens)
    space.lens = lens
    if not camera.get('ortho'):
        space.clip_start = max(camera.get('near', 0.05), 1e-4)
    space.clip_end = max(camera.get('far', 1000.0), space.clip_start * 2)
    rv3d.view_rotation = _camera_rotation(camera).to_quaternion()
    rv3d.view_location = Vector(camera['target'])
    rv3d.view_distance = camera['distance']
    rv3d.view_perspective = 'ORTHO' if camera.get('ortho') else 'PERSP'
    rv3d.update()
    return mapped


# --------------------------------------------------------------------------
# The stroke

_stroke = None


def _stroke_elements(dabs, location=None):
    names = ('name', 'location', 'mouse', 'mouse_event', 'pressure', 'size', 'time',
             'is_start', 'x_tilt', 'y_tilt', 'pen_flip')
    known = {p.identifier for p in bpy.types.OperatorStrokeElement.bl_rna.properties}
    elements = []
    for i, dab in enumerate(dabs):
        x, y, pressure, when = dab
        element = dict(name='', location=tuple(location) if location is not None else (0.0, 0.0, 0.0),
                       mouse=(x, y), mouse_event=(x, y), pressure=pressure,
                       size=float(_size_owner().size), time=when, is_start=i == 0,
                       x_tilt=0.0, y_tilt=0.0, pen_flip=False)
        elements.append({k: v for k, v in element.items() if k in names and k in known})
    return elements


def _spacing(stroke, pressure):
    """PaintStroke::space_stroke's step, in region pixels: the brush radius
    (at least a pixel) times its spacing percentage over 50, with the
    spacing-pressure term Blender applies for a Space stroke."""
    brush = _brush()
    radius = max(1.0, _size_owner().size / 2.0)
    spacing = brush.spacing
    if brush.stroke_method == 'SPACE' and getattr(brush, 'use_pressure_spacing', False):
        spacing = spacing * (1.5 - pressure)
    return max(1.0, radius * spacing / 50.0)


def _space(stroke, points):
    """The dabs Blender's modal stroke would add for `points`, continuing the
    stroke so far. Points are (x, y, pressure, time) in region pixels."""
    dabs = []
    brush = _brush()
    # paint_space_stroke_enabled: a Space stroke, and not a grab tool (the
    # cloth brush is spaced whatever it deforms).
    spaced = brush.stroke_method == 'SPACE' and (brush.sculpt_brush_type == 'CLOTH'
                                                  or not _is_grab_tool(brush))
    for point in points:
        last = stroke['last']
        if last is None:
            dabs.append(point)
            stroke['last'] = point
            continue
        if not spaced:
            if (point[0], point[1]) != (last[0], last[1]):
                dabs.append(point)
                stroke['last'] = point
            continue
        dx, dy = point[0] - last[0], point[1] - last[1]
        length = math.hypot(dx, dy)
        if length <= 0.0:
            continue
        ux, uy = dx / length, dy / length
        x, y, pressure, when = last
        remaining = length
        while True:
            step = _spacing(stroke, pressure)
            if remaining < step:
                break
            x, y = x + ux * step, y + uy * step
            t = 1.0 - (remaining - step) / length
            pressure = last[2] + (point[2] - last[2]) * t
            when = last[3] + (point[3] - last[3]) * t
            dabs.append((x, y, pressure, when))
            remaining -= step
        stroke['last'] = (x, y, pressure, when) if dabs else last
    return dabs


def _surface_location(obj, region, rv3d, point):
    """Where the view's ray under `point` meets the surface Blender sculpts,
    in the object's own space, or None: the location Blender's stroke starts a
    Grab at (`stroke_get_location_bvh` raycasts the sculpt session's PBVH).

    That surface is not always the evaluated mesh. On a Multires level it is
    the level, and the evaluated mesh in Sculpt Mode is the base: measured in
    desktop 5.2.1 on a 2-level Multires cube, the base was hit 0.272 from where
    the level is, and a Grab anchored there moved 0 of the level's 98 vertices
    while pushing two undo steps. With a generative modifier (Subdivision,
    Mirror) it is the base mesh with only the deforming modifiers, where the
    evaluated mesh is the subdivided one (0.003 to 0.011 off on the dinosaur's
    body). Without modifiers the evaluated mesh is the sculpted one."""
    from bpy_extras import view3d_utils
    origin = view3d_utils.region_2d_to_origin_3d(region, rv3d, point[:2])
    direction = view3d_utils.region_2d_to_vector_3d(region, rv3d, point[:2])
    inverse = obj.matrix_world.inverted()
    local_origin = inverse @ origin
    local_direction = (inverse.to_3x3() @ direction).normalized()
    tree = _sculpted_tree(obj)
    if tree is not None:
        location, _, _, _ = tree.ray_cast(local_origin, local_direction)
        return Vector(location) if location is not None else None
    depsgraph = bpy.context.evaluated_depsgraph_get()
    hit, location, _, _ = obj.evaluated_get(depsgraph).ray_cast(local_origin, local_direction)
    return Vector(location) if hit else None


# The BVH of the surface a Grab starts on, when it is not the evaluated
# mesh: (key, tree), by object. See _sculpted_tree.
_tree_cache = {}


def _sculpted_tree(obj):
    """A BVH of the surface Blender sculpts, for `_surface_location`, or None
    when the evaluated mesh is that surface (no modifier in the viewport)."""
    from mathutils.bvhtree import BVHTree
    if active_multires(obj) is not None:
        display = multires_display(obj)
        if display is None:
            return None
        key = ('level', _display_cache[obj.name][0])
        cached = _tree_cache.get(obj.name)
        if cached is not None and cached[0] == key:
            return cached[1]
        co, _, tris = display
        vertices = list(zip(co[0::3], co[1::3], co[2::3]))
        triangles = list(zip(tris[0::3], tris[1::3], tris[2::3]))
        tree = BVHTree.FromPolygons(vertices, triangles, all_triangles=True)
        _tree_cache.clear()
        _tree_cache[obj.name] = (key, tree)
        return tree
    if not any(m.show_viewport for m in obj.modifiers):
        return None
    # Read fresh each time: it is asked once per Grab, at the stroke's start.
    depsgraph = bpy.context.evaluated_depsgraph_get()
    return BVHTree.FromObject(obj, depsgraph, deform=True, cage=True)


# The mark of a stroke whose end never came, for the next stroke to count its
# steps from (see begin).
_orphan_mark = None


def _ensure_brush_tool(window, area, region):
    """The 3D View's brush tool, which `brush_stroke` polls for.

    A file saved in Sculpt Mode — the app's own autosave, written while
    sculpting — opens with `load_ui=False` in Sculpt Mode but with no tool
    running in the 3D View's area, and `brush_stroke.poll()` is False there:
    measured in desktop 5.2.1 on files saved plain, under Dynamic Topology and
    on a Multires level, every stroke was refused until the mode was left and
    entered again. `wm.tool_set_by_id('builtin.brush')` starts the tool: the
    poll passes, the brush is the one it was, Blender's undo stack gains no
    step, and a stroke then sculpts (57 vertices moved on the plain file)."""
    with bpy.context.temp_override(window=window, area=area, region=region):
        if bpy.ops.sculpt.brush_stroke.poll():
            return
        bpy.ops.wm.tool_set_by_id(name='builtin.brush', space_type='VIEW_3D')


def begin(name, camera, view, mode='NORMAL'):
    """Starts a stroke on `name`, with the app's camera and 3D View size.

    `camera`: target, distance, azimuth, elevation, fov_y, ortho, near, far,
    as `ViewportCamera` holds them. `view`: the 3D View's width and height in
    points. `mode`: NORMAL, INVERT (Blender's Ctrl) or SMOOTH (its Shift)."""
    global _stroke, _orphan_mark
    if _stroke is not None:
        # A stroke whose end never came: its steps are on Blender's stack and
        # not in the history. This stroke counts from its mark, so the history
        # step it makes holds both, and one Undo takes both back, rather than
        # leaving them under it where the next Undo would stop short.
        if _orphan_mark is None:
            _orphan_mark = _stroke['mark']
        _stroke = None
    if mode not in ('NORMAL', 'INVERT', 'SMOOTH'):
        raise Refusal("A stroke is NORMAL, INVERT or SMOOTH, not " + repr(mode) + ".")
    # _require makes Blender's undo stack if there is none, before the mark:
    # the step that starts it is the one the stroke is undone back to.
    steps = _undo.blender_steps()
    fresh = steps is not None and not steps
    obj = _require(name)
    brush = _brush()
    window, area, region = _knife.view3d(WHAT)
    space = area.spaces.active
    _ensure_brush_tool(window, area, region)
    with bpy.context.temp_override(window=window, area=area, region=region):
        mapped = aim(space, space.region_3d, region, camera, view)
        if not bpy.ops.sculpt.brush_stroke.poll():
            raise Refusal("Blender's sculpt brush cannot run on " + obj.name + " here.")
    mark = _orphan_mark if _orphan_mark is not None else _undo.mark()
    if brush.sculpt_brush_type == 'MASK':
        _ensure_mask_layer(obj)
    _orphan_mark = None
    # On a Multires level nothing a chunk makes can be shown until the stroke
    # ends (`_mirror`), and taking a chunk back to replay it costs a rebuild
    # of the level (MULTIRES_BASE_BUDGET): 31 ms a chunk on a 482-vertex base,
    # 13.3 s on the review's 49,922. So the stroke is gathered, and made as
    # Blender's one stroke when the finger lifts — what it shows then is
    # exactly what Blender made, and nothing is shown before.
    deferred = active_multires(obj) is not None
    _stroke = dict(object=obj.name, camera=dict(camera), view=tuple(view), mode=mode,
                   brush=brush.name, strategy=strategy(brush), deferred=deferred, mapped=mapped,
                   last=None, dabs=[], open=[], first=None, current=None, location=None,
                   rewindable=False, loads=getattr(_undo, '_loads', 0), segments=0, total=0,
                   anchor=None, mark=mark, top=_undo.mark(), moved=False, rewind_ms=0.0,
                   chunks=0, pushed=0, timings=[], fresh=fresh)
    return dict(strategy='deferred' if deferred else _stroke['strategy'], brush=brush.name,
                scale=mapped[0], region=[mapped[1], mapped[2]])


def _run(stroke, elements, override_location):
    """One `brush_stroke`, and whether it pushed an undo step.

    Whether it did is read from Blender's stack, not from what the operator
    returns: called by EXEC_DEFAULT it answers FINISHED whether or not its
    stroke started (sculpt_brush_stroke_exec returns FINISHED unconditionally),
    and a stroke whose every dab missed the surface starts nothing and pushes
    nothing. Taken for a step, the next chunk's Undo would have taken back the
    step before the stroke. Where the stack cannot be read, FINISHED it is."""
    # Room on Blender's stack for this stroke's steps: it drops its oldest
    # past `undo_steps` when one is pushed, which could be the history's.
    _undo.reserve(stroke['pushed'] + 2)
    before = _undo.mark()
    result = bpy.ops.sculpt.brush_stroke('EXEC_DEFAULT', True, stroke=elements,
                                         mode=stroke['mode'],
                                         override_location=override_location)
    if 'FINISHED' not in result:
        return False
    if before is None:
        return True
    return _undo.mark() != before


def _undo_last():
    """Takes back the step this stroke pushed last, so the next chunk can
    replace it (the anchored and replayed brushes)."""
    result = bpy.ops.ed.undo()
    if 'FINISHED' not in result:
        raise Refusal("Blender's undo could not take the stroke back to replace it.")


def _redo_last():
    """Puts back the step `_undo_last` took back (see `chunk`)."""
    result = bpy.ops.ed.redo()
    if 'FINISHED' not in result:
        raise Refusal("Blender's undo could not put the stroke's last step back.")


def _check_between_chunks(stroke):
    """What `_require` checked at the start and a chunk cannot assume: the
    object is still active and sculpted with the same brush, and no file load
    has freed the undo stack a stroke writes to (a load would, and the stroke
    would then segfault). Cheap, so it runs before every chunk."""
    if not _knife.on_main_thread():
        raise Refusal("Sculpting aims Blender's 3D View, which exists on the main thread only.")
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.name != stroke['object'] or obj.mode != 'SCULPT':
        raise Refusal("The stroke's object left Sculpt Mode part way through.")
    brush = _brush()
    if brush is None or brush.name != stroke['brush']:
        raise Refusal("The brush changed part way through the stroke.")
    if getattr(_undo, '_loads', 0) != stroke['loads']:
        raise Refusal("A file was loaded part way through the stroke.")
    return obj


def _check_history(stroke):
    """Blender's undo stack is where the stroke left it.

    Each chunk rewinds the step on top, taking it for the stroke's own. When
    anything else moved the stack between chunks, that step is not: measured
    in desktop 5.2.1 with this module, an Undo between two chunks put the
    history at the step before, and the next chunk's rewind then undid one
    more (a Mask Clear made before the stroke came undone, and the stroke
    moved nothing). The interface does not let anything run during a stroke
    (BpySession.sculptStrokeOpen); this holds the stroke to it even so."""
    top = stroke.get('top')
    if top is None:
        return
    now = _undo.mark()
    if now is not None and now != top:
        stroke['moved'] = True
        stroke['rewindable'] = False
        raise Refusal("Blender's undo history moved part way through the stroke, so the stroke "
                      "ends here rather than take back a step that is not its own.")


def _start_location(stroke, obj, region, rv3d, dabs):
    """The location a stroke of a brush that needs no surface under its dabs
    starts from: where the view's ray under its first dab over the surface
    meets it. Dabs before that one are dropped, as Blender drops the events
    before its stroke can start (PaintStroke::test_start)."""
    if active_multires(obj) is None:
        # The evaluated mesh (or the deformed one) is raycast: made current.
        # Not on a Multires level, which is raycast in the level read back
        # (`_sculpted_tree`); tagged, the stroke re-evaluated the level first,
        # 2.7 of a Grab's 8.2 s on a 4,514-vertex base in the app.
        obj.data.update_tag()
    while dabs:
        hit = _surface_location(obj, region, rv3d, dabs[0])
        if hit is not None:
            return hit
        dabs.pop(0)
    return None


def _carried_location(stroke, obj, region, rv3d):
    """Where a Snake Hook's location has got to when its stroke is cut: moved
    with the mouse at its own depth, as brush_delta_update moves it
    (`cache->location += grab_delta`, the delta taken at the grab's depth)."""
    from bpy_extras import view3d_utils
    last = stroke['open'][-1]
    world = obj.matrix_world @ stroke['location']
    moved = view3d_utils.region_2d_to_location_3d(region, rv3d, last[:2], world)
    return obj.matrix_world.inverted() @ moved


def _below_is_sculpt_step():
    rows = _undo.blender_steps()
    if not rows:
        return None
    active = next((row for row in rows if row[3]), None)
    return active is not None and active[1] == 'Sculpt'


def _anchor(stroke, dab):
    """A step for the stroke to rewind onto that is cheap to rewind onto.

    Each chunk takes the stroke's last step back before replaying it. When the
    step under the stroke is a memfile step — the stroke is the first after
    entering Sculpt Mode, or after any other change — that Undo reads the
    scene back from memory: 5 to 6 ms a chunk on the dinosaur file where a
    Sculpt step took 0.3 to 3 (measured in desktop 5.2.1), and the Python
    objects from before it are gone. So the stroke's first dab is first made
    at zero strength, which pushes a Sculpt step, and the stroke rewinds onto
    that. It is one of the stroke's own steps, so the stroke's Undo takes it
    back too.

    Zero strength is not enough by itself: Blender's auto-smooth runs at the
    brush's own Auto-Smooth factor whatever the strength. Measured in desktop
    5.2.1 over every Essentials brush on a sphere: with only the strength at
    zero, the Density brush (Auto-Smooth 0.1) moved 10 vertices by up to 0.003;
    with Auto-Smooth at zero too, no brush moved a vertex or changed a mask,
    face set or colour value. (The Mask, Face Set and paint brushes make their
    layer on the first dab, at its default, as their first real dab would.)

    Under dynamic topology a dab remeshes at any strength, so the anchor's dab
    is made with the detail method at Manual, under which a stroke changes no
    topology (Blender remeshes only from Detail Flood Fill then). It matters
    more there than anywhere: a memfile step comes back without the dynamic
    topology mesh, so a rewind onto one turned dynamic topology off in the
    middle of the stroke and the rest replayed without it — after a relaunch
    (the history's first step is Global Undo) or a labelled change in Sculpt
    Mode (round 3's review; scratchpad vr/p6c_dyn.py: on after chunk 0, off
    after chunk 1's 2.66 ms rewind).

    Not for the cloth brushes, whose simulation moves at any strength.
    Returns whether the stroke has its anchor (False: it goes on without).
    """
    brush = _brush()
    obj = bpy.data.objects[stroke['object']]
    if (brush.sculpt_brush_type == 'CLOTH'
            or getattr(brush, 'deform_target', 'GEOMETRY') == 'CLOTH_SIM'
            or _below_is_sculpt_step() is not False):
        return False
    owner = _strength_owner()
    saved, smooth = owner.strength, brush.auto_smooth_factor
    settings = bpy.context.scene.tool_settings.sculpt
    dyntopo = obj.use_dynamic_topology_sculpting
    detail = settings.detail_type_method
    owner.strength = 0.0
    brush.auto_smooth_factor = 0.0
    if dyntopo:
        settings.detail_type_method = 'MANUAL'
    try:
        pushed = _run(stroke, _stroke_elements([dab], stroke['location']), stroke['location'] is None)
    finally:
        owner.strength = saved
        brush.auto_smooth_factor = smooth
        if dyntopo:
            settings.detail_type_method = detail
    if not pushed:
        # The dab missed the surface: tried again with the next chunk's.
        return None
    if dyntopo and stroke['fresh'] and stroke['mark'] is not None:
        # This stroke started Blender's stack (the first after a relaunch), so
        # the anchor joins its base instead of the stroke: the stroke's Undo
        # stops on a Sculpt step and keeps dynamic topology, and its Redo has
        # it to replay onto. Counted into the stroke, the Undo went down to the
        # memfile step and both were lost (5,352 vertices and dynamic topology
        # off after the Undo, and again after the Redo, measured in 5.2.1). No
        # history step lies under the base for the step to throw off. Over a
        # labelled change it stays the stroke's own, or the next Undo, of that
        # change, would stop one step short.
        stroke['mark'] = _undo.mark()
    else:
        stroke['pushed'] += 1
    return True


def _gather(stroke, converted):
    """A deferred stroke's points, spaced as they come (see `begin`)."""
    if stroke['strategy'] == 'line':
        if converted:
            if stroke['first'] is None:
                stroke['first'] = converted[0]
            stroke['current'] = converted[-1]
        return
    new = _space(stroke, converted)
    stroke['dabs'].extend(new)
    stroke['total'] += len(new)


def _make_deferred(stroke):
    """A deferred stroke, made as one of Blender's strokes, as its streamed
    form would have ended up: the whole stroke, [first, last] for the anchored
    brushes, first to last for a Line."""
    obj = _check_between_chunks(stroke)
    _check_history(stroke)
    brush = _brush()
    kind = stroke['strategy']
    window, area, region = _knife.view3d(WHAT)
    space = area.spaces.active
    rv3d = space.region_3d
    with bpy.context.temp_override(window=window, area=area, region=region):
        aim(space, rv3d, region, stroke['camera'], stroke['view'])
        if kind == 'line':
            if stroke['first'] is None:
                return
            stroke['last'] = None
            dabs = _space(stroke, [stroke['first'], stroke['current']])
            stroke['total'] = len(dabs)
        else:
            dabs = list(stroke['dabs'])
        location = None
        if dabs and not _needs_location(brush):
            location = _start_location(stroke, obj, region, rv3d, dabs)
            if location is None:
                return
        if kind == 'anchored' and dabs:
            dabs = [dabs[0], dabs[-1]] if dabs[0] != dabs[-1] else dabs[:1]
        if not dabs:
            return
        ran = time.perf_counter()
        pushed = _run(stroke, _stroke_elements(dabs, location), location is None)
        stroke['timings'].append((len(dabs), round((time.perf_counter() - ran) * 1000, 2), 0.0))
    if pushed:
        stroke['pushed'] += 1
        stroke['chunks'] += 1
        _changes[0] += 1


def chunk(points):
    """Streams the stroke's next points to Blender and mirrors what it made.

    `points`: (x, y) or (x, y, pressure, seconds) in the app's 3D View
    points. Returns what happened, with the milliseconds it took."""
    stroke = _stroke
    if stroke is None:
        raise Refusal("There is no stroke to continue.")
    started = time.perf_counter()
    obj = _check_between_chunks(stroke)
    _check_history(stroke)
    brush = _brush()
    window, area, region = _knife.view3d(WHAT)
    space = area.spaces.active
    rv3d = space.region_3d
    mapped = stroke['mapped']
    converted = []
    for point in points:
        x, y = to_region(point, mapped)
        pressure = float(point[2]) if len(point) > 2 else 1.0
        when = float(point[3]) if len(point) > 3 else time.perf_counter()
        converted.append((x, y, pressure, when))
    kind = stroke['strategy']
    if stroke['deferred']:
        _gather(stroke, converted)
        result = dict(dabs=0, applied=False, strategy='deferred', replayed=0,
                      stroke_ms=round((time.perf_counter() - started) * 1000, 2), mirror_ms=0.0)
        stroke['timings'].append((0, result['stroke_ms'], 0.0))
        return result
    result = dict(dabs=0, applied=False, strategy=kind, replayed=0)
    with bpy.context.temp_override(window=window, area=area, region=region):
        aim(space, rv3d, region, stroke['camera'], stroke['view'])
        dabs = []
        if kind == 'line':
            if converted:
                if stroke['first'] is None:
                    stroke['first'] = converted[0]
                stroke['current'] = converted[-1]
                stroke['last'] = None
                dabs = _space(stroke, [stroke['first'], stroke['current']])
                stroke['total'] = len(dabs)
        else:
            new = _space(stroke, converted)
            stroke['total'] += len(new)
            growing = stroke['dabs'] if kind == 'anchored' else stroke['open']
            growing.extend(new)
            if new and stroke['location'] is None and not _needs_location(brush):
                stroke['location'] = _start_location(stroke, obj, region, rv3d, growing)
            if new and growing:
                dabs = growing if kind == 'replay' else [growing[0], growing[-1]]
                if len(dabs) == 2 and dabs[0] == dabs[1]:
                    dabs = dabs[:1]
        if dabs and stroke['anchor'] is None:
            # The chunk's last dab: the likeliest to be over the surface (a
            # stroke begun off the mesh has come onto it by now), and where a
            # zero-strength dab lands changes nothing.
            stroke['anchor'] = _anchor(stroke, dabs[-1])
        if dabs:
            rewound = False
            if stroke['rewindable']:
                undone = time.perf_counter()
                _undo_last()
                rewound = True
                stroke['rewind_ms'] = (time.perf_counter() - undone) * 1000
                result['undo_ms'] = round(stroke['rewind_ms'], 2)
                stroke['pushed'] -= 1
                stroke['rewindable'] = False
                # An Undo onto a memfile step reads the scene back, and the
                # Python objects from before it are gone.
                obj = bpy.data.objects[stroke['object']]
            location = stroke['location']
            ran = time.perf_counter()
            pushed = _run(stroke, _stroke_elements(dabs, location), location is None)
            ran = (time.perf_counter() - ran) * 1000
            result['run_ms'] = round(ran, 2)
            result['dabs'] = len(dabs)
            if pushed:
                stroke['pushed'] += 1
                stroke['rewindable'] = True
                result['applied'] = True
            elif rewound:
                # The replay made nothing, and the rewind had taken back what
                # the 3D View shows. Measured in desktop 5.2.1: a Grab begun
                # at the silhouette of a sphere under Subdivision pushed
                # nothing once dragged past about 270 px, so the next chunk's
                # rewind left the mesh as it was before the stroke while the
                # viewport still showed the last chunk — and the stroke, when
                # it ended, had moved nothing. The step taken back is put
                # back, and the stroke stays what was last shown.
                _redo_last()
                obj = bpy.data.objects[stroke['object']]
                stroke['pushed'] += 1
                stroke['rewindable'] = True
                result['kept'] = True
            # The next chunk would pay a rewind as dear as the last one and a
            # replay at least this long: over the budget, the stroke is kept as
            # it is and goes on as a new one from here.
            if kind == 'replay' and (len(dabs) >= MAX_OPEN_DABS
                                     or ran + stroke['rewind_ms'] > REPLAY_BUDGET_MS):
                if stroke['location'] is not None and brush.sculpt_brush_type == 'SNAKE_HOOK':
                    stroke['location'] = _carried_location(stroke, obj, region, rv3d)
                elif brush.sculpt_brush_type != 'ROTATE':
                    stroke['location'] = None if _needs_location(brush) else stroke['location']
                stroke['open'] = []
                stroke['rewindable'] = False
                stroke['segments'] += 1
                result['cut'] = True
    stroked = time.perf_counter()
    if result['applied']:
        stroke['chunks'] += 1
        _changes[0] += 1
        _mirror(obj, final=False)
    stroke['top'] = _undo.mark()
    finished = time.perf_counter()
    result['stroke_ms'] = round((stroked - started) * 1000, 2)
    result['mirror_ms'] = round((finished - stroked) * 1000, 2)
    stroke['timings'].append((result['dabs'], result['stroke_ms'], result['mirror_ms']))
    return result


def refresh_evaluated(obj):
    """Makes the evaluated mesh of an object in Sculpt Mode Blender's mesh
    again. Blender draws Sculpt Mode from its own structure and leaves the
    depsgraph's mesh stale: in the app a Redo of a stroke left the mirror
    showing the mesh from before it (0 of 1,986 vertices moved, where the
    stroke had moved 388). Flushed and tagged, the next evaluation is the
    mesh as it is. The mirroring pass calls this before it reads the scene."""
    if obj is None or getattr(obj, 'mode', '') != 'SCULPT' or obj.type != 'MESH':
        return
    if active_multires(obj) is not None:
        # Not a Multires level: re-evaluating it rebuilds the grids from the
        # displacement the mesh holds, which a stroke or a Redo has not been
        # flushed into yet. `multires_display` flushes first, and is what the
        # mirror reads for it.
        return
    if obj.use_dynamic_topology_sculpting:
        bpy.ops.ed.flush_edits()
    obj.data.update_tag()


def _flush(obj):
    """What the 3D View draws is the evaluated mesh, and a stroke leaves it
    stale: dynamic topology keeps its geometry in a BMesh until it is flushed
    to the mesh (`ed.flush_edits`, ED_editors_flush_edits_for_object). Then
    the mesh is tagged for the depsgraph to evaluate it again."""
    if obj.use_dynamic_topology_sculpting:
        bpy.ops.ed.flush_edits()
    obj.data.update_tag()


def multires_display(obj):
    """The mesh Blender's Sculpt Mode draws for an object sculpted on a
    Multires level, as (vertex positions, normals, triangles) arrays, or None
    for an object that is not.

    In Sculpt Mode Blender evaluates Multires into grids it draws itself, and
    the evaluated mesh a script can read is the base mesh: 1,106 vertices for
    a sphere whose level 1 has 4,514, and a stroke moved none of them
    (measured in desktop 5.2.1). So the level is flushed to the mesh
    (`ed.flush_edits`), and a Multires modifier at the sculpt level is
    evaluated on a copy of the mesh in a temporary object, in Object Mode,
    which gives the level as Blender draws it: the stroke's 157 vertices moved
    by up to 0.159, Undo back to within 1.3e-6, Redo exact. Copying the object
    instead crashed Blender: a copy keeps the Sculpt Mode flag and has no
    sculpt session. It costs about 150 ms on that level (75 to flush, 75 to
    evaluate), so a stroke on Multires is mirrored when it ends, not per chunk.
    """
    modifier = active_multires(obj)
    if modifier is None:
        return None
    if multires_base_refusal(obj) is not None:
        # Over MULTIRES_BASE_BUDGET the read costs seconds to tens of seconds
        # (26.8 s on a 49,922-vertex base), and the mirror asks for it after
        # every command. The app does not take such an object into Sculpt
        # Mode (`refuse_heavy_multires`) or sculpt it; one opened in Sculpt
        # Mode from a file shows its base mesh, and every sculpt action on it
        # says why in words.
        return None
    # Read again only when something could have changed it: nothing that
    # changes a sculpt goes without an undo step, so the step Blender's stack
    # is at, with the level and the mesh's size, says whether the arrays from
    # last time are still the level. A brush setting written in the header
    # runs a mirroring pass and pushes nothing: it reads the cache, where the
    # level cost 1.5 s to read (7,832 base vertices at level 1, desktop 5.2.1).
    # With the history's position and a count of this module's own changes:
    # a freed step's address can be handed to the next step pushed.
    key = _display_key(obj, modifier)
    active = key[1]
    cached = _display_cache.get(obj.name)
    if active is not None and cached is not None and cached[0] == key:
        return cached[1]
    bpy.ops.ed.flush_edits()
    mesh = obj.data.copy()
    temp = bpy.data.objects.new("_bk_multires_display", mesh)
    try:
        level = temp.modifiers.new("Multires", 'MULTIRES')
        level.levels = modifier.sculpt_levels
        bpy.context.scene.collection.objects.link(temp)
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = temp.evaluated_get(depsgraph)
        drawn = evaluated.to_mesh()
        try:
            drawn.calc_loop_triangles()
            count = len(drawn.vertices)
            co = array('f', [0.0]) * (3 * count)
            drawn.vertices.foreach_get('co', co)
            normals = array('f', [0.0]) * (3 * count)
            drawn.vertices.foreach_get('normal', normals)
            tris = array('I', [0]) * (3 * len(drawn.loop_triangles))
            drawn.loop_triangles.foreach_get('vertices', tris)
        finally:
            evaluated.to_mesh_clear()
    finally:
        bpy.data.objects.remove(temp)
        bpy.data.meshes.remove(mesh)
    _display_cache.clear()
    _display_cache[obj.name] = (key, (co, normals, tris))
    return co, normals, tris


def _display_key(obj, modifier):
    """What the cached level is keyed on (see multires_display)."""
    rows = _undo.blender_steps()
    active = next((row[0] for row in rows if row[3]), None) if rows else None
    return (obj.name, active, len(rows or ()), _undo._index, len(_undo._steps), _changes[0],
            modifier.sculpt_levels, len(obj.data.vertices), len(obj.data.polygons))


def history_recorded_only():
    """The history recorded the steps an action had already pushed, and
    pushed none on Blender's stack (`_blenderkit_undo.push` with
    `note_pushed`): nothing Blender holds changed, and the level read before
    is still the level. Its key moves with the history's position all the
    same, and the next read — a Grab's start on the level, the next mirroring
    pass — would read it again for nothing: measured in the app on a
    4,514-vertex base, the Grab after a stroke spent 2.7 s re-reading it."""
    for name, (key, arrays) in list(_display_cache.items()):
        obj = bpy.data.objects.get(name)
        modifier = active_multires(obj) if obj is not None else None
        if modifier is None:
            continue
        now = _display_key(obj, modifier)
        # Everything Blender holds the same; only the history's position moved.
        if now[:3] == key[:3] and now[5:] == key[5:]:
            _display_cache[name] = (now, arrays)
            tree = _tree_cache.get(name)
            if tree is not None and tree[0] == ('level', key):
                _tree_cache[name] = (('level', now), tree[1])


# The last Multires level read, by object: (key, arrays). See multires_display.
_display_cache = {}
# Strokes and operations made here, counted: part of the cache's key.
_changes = [0]


def _mirror(obj, final=True):
    """The sculpted object, and only it, back to the viewport: the same
    extraction as the mirroring pass, through the one-mesh entry point a frame
    change uses. The mask travels with it (`push_mask`). A Multires object is
    mirrored only when `final` (see `multires_display`)."""
    try:
        import _blenderkit
        import _blenderkit_anim
    except ImportError:
        # Outside the app (the Blender check) there is no viewport to push to.
        _flush(obj)
        return
    display = multires_display(obj) if final else None
    if display is not None:
        co, normals, tris = display
        _blenderkit.anim_mesh(obj.name, co.tobytes(), normals.tobytes(), tris.tobytes())
        push_mask(obj)
        return
    if active_multires(obj) is not None:
        return
    _flush(obj)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    _blenderkit_anim.push_mesh(obj, depsgraph)
    push_mask(obj, depsgraph)


def push_mask(obj, depsgraph=None):
    """Blender's sculpt mask for the viewport to darken, per evaluated vertex,
    when the viewport can take one (`_blenderkit.sync_mask`)."""
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_mask', None)
    if send is None:
        return
    if active_multires(obj) is not None:
        # On a Multires level the mask is in grid layers no script reads
        # (`state`), and the evaluated mesh here is the base: reading it only
        # re-evaluated the level, the dearest part of a stroke's mirror
        # (measured in the app on a 4,514-vertex base: 2.7 of its 5.4 s).
        send(obj.name, b'')
        return
    depsgraph = depsgraph or bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        values = _attribute_values(mesh, '.sculpt_mask', 'POINT') if mesh is not None else None
        if values is None or not any(values):
            send(obj.name, b'')
        else:
            send(obj.name, values.tobytes())
    finally:
        evaluated.to_mesh_clear()


def end():
    """Ends the stroke: the history records it as the steps it pushed.

    A deferred stroke (on a Multires level, see `begin`) is made here. When it
    cannot be — the object left Sculpt Mode, the history moved — nothing is
    made, and `refused` says why for the banner."""
    global _stroke
    stroke, _stroke = _stroke, None
    if stroke is None:
        return dict(pushed=0, counted=False, chunks=0, cuts=0, strategy='', dabs=0,
                    stroke_ms=[], mirror_ms=[])
    refused = None
    if stroke['deferred']:
        try:
            _make_deferred(stroke)
        except RuntimeError as error:
            refused = str(error)
    obj = bpy.data.objects.get(stroke['object'])
    if obj is not None and stroke['chunks'] and obj.mode == 'SCULPT' \
            and active_multires(obj) is not None:
        mirrored = time.perf_counter()
        _mirror(obj)
        if stroke['deferred'] and stroke['timings']:
            dabs, ran, _ = stroke['timings'][-1]
            stroke['timings'][-1] = (dabs, ran, round((time.perf_counter() - mirrored) * 1000, 2))
    if stroke['mark'] is None:
        # Blender's stack cannot be read here: the steps as they were made.
        counted, pushed = False, stroke['pushed']
    else:
        counted = True
        pushed = _undo.pushed_since(stroke['mark'])
        if pushed is None:
            # The stack is no longer above the mark: something took the
            # history back under the stroke (`_check_history`), and there is
            # nothing of it left to record. Otherwise the mark was dropped off
            # the bottom of the stack, and the steps are counted as made.
            pushed = 0 if stroke['moved'] else stroke['pushed']
            counted = False
    _undo.note_pushed(pushed)
    timings = stroke['timings']
    report = dict(pushed=pushed, counted=counted, chunks=stroke['chunks'],
                  cuts=stroke['segments'],
                  strategy='deferred' if stroke['deferred'] else stroke['strategy'],
                  dabs=stroke['total'],
                  stroke_ms=[t[1] for t in timings], mirror_ms=[t[2] for t in timings])
    if refused is not None:
        report['refused'] = refused
    return report


def cancel():
    """Forgets a stroke that failed part way, keeping what it did as a step."""
    return end()


# --------------------------------------------------------------------------
# One-shot operations, counted onto the history

class counted:
    """Counts the undo steps an operation pushes itself, for the history.

    `final=True`: the steps are the operation (a sculpt operator that pushes
    its own step when it is done), and the history pushes none of its own.
    `final=False`: the operation pushed something part way (a mode switch)
    and changed more after, so the history pushes its own step on top, and
    one Undo takes back both.
    """

    def __init__(self, final=True):
        self.final = final
        self.mark = None

    def __enter__(self):
        self.mark = _undo.mark()
        return self

    def __exit__(self, kind, error, traceback):
        _changes[0] += 1
        if kind is not None:
            return False
        pushed = _undo.pushed_since(self.mark) if self.mark is not None else None
        if pushed:
            if self.final:
                _undo.note_pushed(pushed)
            else:
                _undo.note_pushed(pushed, own=True)
        return False


def _view_override():
    window, area, region = _knife.view3d(WHAT)
    return bpy.context.temp_override(window=window, area=area, region=region)


def _require_sculpt_mode(what):
    if not _is_real_blender():
        raise Refusal(what + " runs in Blender, and the simulator's stand-in does not have it.")
    if not _knife.on_main_thread():
        raise Refusal(what + " works through Blender's 3D View, which exists on the main thread only.")
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH':
        raise Refusal(what + " works on a mesh. Select one first.")
    if obj.mode != 'SCULPT':
        raise Refusal(what + " works in Sculpt Mode.")
    if not obj.data.polygons:
        raise Refusal(what + ": " + obj.name + " has no faces.")
    _refuse_during_stroke(what)
    _require_multires_fits(obj)
    _knife.require_gpu_context(what)
    _require_undo_stack()
    return obj


def dyntopo(on):
    """Dynamic topology on or off (`sculpt.dynamic_topology_toggle`)."""
    obj = _require_sculpt_mode("Dynamic Topology")
    if bool(obj.use_dynamic_topology_sculpting) == bool(on):
        return bool(on)
    if on and any(m.type == 'MULTIRES' for m in obj.modifiers):
        raise Refusal("Dynamic Topology cannot run with a Multiresolution modifier. "
                      "Apply or remove it first.")
    with counted(), _view_override():
        result = bpy.ops.sculpt.dynamic_topology_toggle()
    if 'FINISHED' not in result:
        raise Refusal("Blender could not turn Dynamic Topology " + ("on." if on else "off."))
    _mirror(obj)
    return bool(obj.use_dynamic_topology_sculpting)


DETAIL_TYPES = ('RELATIVE', 'CONSTANT', 'BRUSH', 'MANUAL')


def set_detail(value):
    """The detail size of the Detailing method in use, as Blender's header
    shows it: pixels for Relative, a resolution for Constant and Manual, a
    percentage of the brush for Brush."""
    _refuse_during_stroke("Detail Size")
    sculpt = _sculpt_settings()
    method = sculpt.detail_type_method
    if method == 'RELATIVE':
        sculpt.detail_size = float(value)
        return sculpt.detail_size
    if method == 'BRUSH':
        sculpt.detail_percent = float(value)
        return sculpt.detail_percent
    sculpt.constant_detail_resolution = float(value)
    return sculpt.constant_detail_resolution


def set_voxel_size(value):
    obj = _require_sculpt_mode("Voxel Remesh")
    obj.data.remesh_voxel_size = float(value)
    return obj.data.remesh_voxel_size


def remesh_estimate(mesh, size):
    """(vertices Voxel Remesh would make at voxel `size`, the surface area it
    is reckoned from), both in the mesh's own units. See
    REMESH_VERTICES_PER_AREA."""
    areas = array('f', [0.0]) * len(mesh.polygons)
    mesh.polygons.foreach_get('area', areas)
    area = float(sum(areas))
    return REMESH_VERTICES_PER_AREA * area / (size * size), area


def voxel_remesh():
    """`object.voxel_remesh` at the mesh's voxel size, from Sculpt Mode.

    Refused before anything runs when its output would pass the vertex budget
    Multires keeps (`_blenderkit_multires.BUDGET`), or need more memory than
    this process has left: OpenVDB is asked for the whole surface at once, and
    a remesh too fine for the device ends the app. The estimate is the mesh's
    own surface area over the voxel size squared, both in the mesh's own
    units (see REMESH_VERTICES_PER_AREA): the guard this replaces counted
    world-space bounding-box cells and let through a model imported at scale
    0.01 at Blender's default 0.1 voxel (about 12.6 million vertices), and a
    2 m plane down to a 0.0001 voxel (about 800 million)."""
    obj = _require_sculpt_mode("Voxel Remesh")
    if obj.use_dynamic_topology_sculpting:
        raise Refusal("Voxel Remesh cannot run with Dynamic Topology on. Turn it off first.")
    if any(m.type == 'MULTIRES' for m in obj.modifiers):
        raise Refusal("Voxel Remesh cannot run with a Multiresolution modifier. "
                      "Apply or remove it first.")
    refuse_voxel_remesh(obj)
    with counted(), _view_override():
        result = bpy.ops.object.voxel_remesh()
    if 'FINISHED' not in result:
        raise Refusal("Blender could not remesh " + obj.name + ".")
    _mirror(obj)
    return len(obj.data.vertices)


def refuse_voxel_remesh(obj):
    """Raises, in words, when Voxel Remesh at `obj`'s voxel size would pass
    the vertex budget or the memory left (see `voxel_remesh`). Shared by the
    Sculpt header's Remesh and the operator search's `object.voxel_remesh`,
    which ran with no check at all: 1,043,336 vertices from a 2 m cube at a
    0.0048 voxel, past this estimate's 2,604,166 (round 3's review)."""
    if obj is None or obj.type != 'MESH':
        return
    size = obj.data.remesh_voxel_size
    if size <= 0:
        raise Refusal("Voxel Remesh needs a voxel size above zero.")
    import _blenderkit_multires
    budget = _blenderkit_multires.BUDGET
    count, area = remesh_estimate(obj.data, size)
    # The smallest voxel size the budget allows, in the same units.
    smallest = math.sqrt(REMESH_VERTICES_PER_AREA * area / budget) if area > 0 else 0.0
    units = _units_note(obj)
    if count > budget:
        raise Refusal("A voxel size of %g would remesh %s into about %s vertices, and this app "
                      "stops at %s so it does not run out of memory. Use %.4g or larger%s."
                      % (size, obj.name, format(int(count), ','), format(budget, ','),
                         smallest, units))
    free = _blenderkit_multires.available_memory()
    need = count * REMESH_PEAK_BYTES_PER_VERTEX
    if free is not None and need > free:
        raise Refusal("A voxel size of %g would remesh %s into about %s vertices, which needs "
                      "about %.1f GB of memory, and %.1f GB is free. Use a larger size%s."
                      % (size, obj.name, format(int(count), ','), need / 1e9, free / 1e9, units))


def _units_note(obj):
    """', in X's own units, ...' when the object's scale makes them differ
    from the scene's; '' otherwise."""
    scale = obj.matrix_world.to_scale()
    if all(abs(abs(s) - 1.0) < 1e-4 for s in scale):
        return ""
    return (" (in %s's own units, which its scale of %s makes differ from the scene's)"
            % (obj.name, ", ".join("%.4g" % s for s in scale)))


def multires_subdivide():
    """One more Multiresolution level, the modifier added first if there is
    none, as the Multires panel's Subdivide does. Run in Object Mode, where
    Blender's Multires operators are safe (see `Bpy.multires`), and back."""
    obj = _require_sculpt_mode("Multires Subdivide")
    if obj.use_dynamic_topology_sculpting:
        raise Refusal("Multiresolution cannot be added with Dynamic Topology on. "
                      "Turn it off first.")
    # What a Multires costs here is its base mesh (MULTIRES_BASE_BUDGET):
    # measured on the review's 99,840-triangle sphere, Subdivide to level 1
    # took 26.9 s and level 2 76 s, and every stroke after it 13 s a chunk.
    said = multires_base_refusal(obj, "Multires Subdivide")
    if said is not None:
        raise Refusal(said)
    # The Modifiers panel's budget: each press multiplies the mesh by four,
    # and a cube's tenth level is 6,291,458 vertices (_blenderkit_multires has
    # the measurements). Sculpt Mode without Dynamic Topology edits the mesh
    # in place, so its counts are the base mesh's here.
    import _blenderkit_multires
    existing = next((m for m in obj.modifiers if m.type == 'MULTIRES'), None)
    _blenderkit_multires.refuse_over_budget(
        obj, existing.total_levels if existing is not None else 0, "Multires Subdivide")
    with counted(final=False):
        bpy.ops.object.mode_set(mode='OBJECT')
        try:
            modifier = next((m for m in obj.modifiers if m.type == 'MULTIRES'), None)
            if modifier is None:
                modifier = obj.modifiers.new("Multires", 'MULTIRES')
            result = bpy.ops.object.multires_subdivide(modifier=modifier.name, mode='CATMULL_CLARK')
            if 'FINISHED' not in result:
                raise Refusal("Blender could not subdivide " + obj.name + ".")
        finally:
            bpy.ops.object.mode_set(mode='SCULPT')
    _mirror(obj)
    return modifier.total_levels


MASK_ACTIONS = ('CLEAR', 'INVERT', 'FILL')


def mask(action):
    """Mask ▸ Clear, Invert or Fill (`paint.mask_flood_fill`)."""
    obj = _require_sculpt_mode("Mask")
    if action not in MASK_ACTIONS:
        raise Refusal("Mask is CLEAR, INVERT or FILL, not " + repr(action) + ".")
    arguments = dict(mode='INVERT') if action == 'INVERT' else \
        dict(mode='VALUE', value=1.0 if action == 'FILL' else 0.0)
    with counted(), _view_override():
        result = bpy.ops.paint.mask_flood_fill(**arguments)
    if 'FINISHED' not in result:
        raise Refusal("Blender could not change the mask.")
    _mirror(obj)
    return state()['masked']


FACE_SET_INIT = ('LOOSE_PARTS', 'MATERIALS', 'NORMALS', 'UV_SEAMS', 'CREASES',
                 'SHARP_EDGES', 'FACE_SET_BOUNDARIES')


def face_sets_init(mode):
    """Face Sets ▸ Initialize (`sculpt.face_sets_init`)."""
    obj = _require_sculpt_mode("Face Sets")
    _require_face_sets(obj)
    if mode not in FACE_SET_INIT:
        raise Refusal("Face Sets are initialised by one of " + ", ".join(FACE_SET_INIT) + ".")
    with counted(), _view_override():
        result = bpy.ops.sculpt.face_sets_init(mode=mode)
    if 'FINISHED' not in result:
        raise Refusal("Blender could not make face sets.")
    _mirror(obj)
    return state()['face_sets']


def _require_face_sets(obj):
    """Blender's face set operators return CANCELLED under dynamic topology
    without a word (sculpt_face_set.cc: "Dyntopo not supported"): measured in
    desktop 5.2.1 with every vertex masked, Face Set from Masked and
    Initialize by Loose Parts both made nothing. Said here, in words, instead
    of a reason that is not the reason."""
    if obj.use_dynamic_topology_sculpting:
        raise Refusal("Blender's Face Sets do not work under Dynamic Topology. "
                      "Turn Dynamic Topology off first.")


def face_set_from_mask():
    """Face Sets ▸ Face Set from Masked (`sculpt.face_sets_create`)."""
    obj = _require_sculpt_mode("Face Sets")
    _require_face_sets(obj)
    with counted(), _view_override():
        result = bpy.ops.sculpt.face_sets_create(mode='MASKED')
    if 'FINISHED' not in result:
        raise Refusal("Blender made no face set: nothing is masked.")
    _mirror(obj)
    return state()['face_sets']
