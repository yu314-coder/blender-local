"""Blender's Grease Pencil in the app: the drawings mirrored to the 3D View,
Draw Mode's strokes and Erase, the layers, and onion skinning.

Blender 5.x's Grease Pencil ("GPv3": object type GREASEPENCIL, data
`bpy.types.GreasePencil`) keeps a drawing per keyframe of each layer
(`layer.frames[i].drawing`), and a drawing is curves geometry: point
attributes `position`, `radius`, `opacity`, `vertex_color`, curve attributes
`cyclic`, `material_index`, `fill_id`, `fill_color`, and `curve_offsets`. Every
name below was read from desktop Blender 5.2.1 headless; what each measured
is held by scripts/run-gpencil-blender-check.sh.

  * The viewport draws the EVALUATED drawing of each layer at the current
    frame (`obj.evaluated_get(depsgraph).data.layers[i].current_frame()`),
    which carries the object's modifiers (an Offset of z 1 moved the Stroke's
    first point from -0.315 to 0.685); onion skins are the original drawings of
    the neighbouring keyframes.

  * A stroke is filled only when its `fill_id` is not 0 and its material's
    fill is visible: in 5.2.1 a square with fill_id 0 drew as a line, cyclic
    or not, and with fill_id 1 filled whether it was cyclic or not (rendered
    in Workbench). `show_stroke` and `show_fill` are deprecated and read False
    on every material; visibility is the colour's alpha
    (`is_stroke_visible`, `is_fill_visible`).

  * Blender's own Draw operator (`grease_pencil.brush_stroke`) has no exec:
    called with EXEC_DEFAULT under the borrowed 3D View it logs "Invalid
    operator call" and returns PASS_THROUGH, drawing nothing. So the app makes
    the stroke as the operator would and writes it here in one call
    (`draw_stroke`): the keyframe rule of `ensure_active_keyframe`, the active
    layer and material, positions the app projected onto the drawing plane,
    radius and opacity from the brush.

  * A drawing's attributes exist only once something set them: a Blank's
    drawing has no `radius`, and `vertex_color` / `fill_color` appear when the
    first value is written. Missing ones read as Blender's defaults (radius
    0.01, opacity 1, colours transparent). `add_strokes` gives new points 0 for
    every attribute that exists, so each is written.
"""

import json
import math
import sys
from array import array

import bpy

try:
    import _blenderkit
except ImportError:                                 # a desktop check loads this by path
    _blenderkit = None

WHAT = "Drawing"
# Blender's defaults for a point whose drawing has no such attribute
# (`CurvesGeometry::radius()` and GPv3's `opacities()`).
DEFAULT_RADIUS = 0.01
DEFAULT_OPACITY = 1.0
# The Essentials library's Grease Pencil Draw brushes (5.2.1:
# essentials_brushes-gp_draw.blend), by the tool that uses them
# (`gpencil_brush_type`).
ESSENTIALS_FILE = 'essentials_brushes-gp_draw.blend'
ASSET_PREFIX = 'brushes/' + ESSENTIALS_FILE + '/Brush/'

Refusal = RuntimeError


def _is_real_blender():
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


# --------------------------------------------------------------------------
# Reading a drawing

def _floats(attrs, name, count, width, default):
    """A point or curve attribute as one array of floats, `width` a value,
    or `default` repeated when the drawing has no such attribute."""
    attr = attrs.get(name)
    out = array('f', [0.0]) * (count * width)
    if attr is None or count == 0:
        if default and count:
            if width == 1:
                out = array('f', [default]) * count
            else:
                out = array('f', list(default)) * count
        return out, attr is not None
    key = 'value' if width == 1 else ('color' if attr.data_type in ('FLOAT_COLOR', 'BYTE_COLOR') else 'vector')
    attr.data.foreach_get(key, out)
    return out, True


def _ints(attrs, name, count, default=0):
    attr = attrs.get(name)
    out = array('i', [default]) * count
    if attr is None or count == 0:
        return out
    if attr.data_type == 'BOOLEAN':
        flags = array('b', [0]) * count
        attr.data.foreach_get('value', flags)
        return array('i', flags)
    if attr.data_type == 'INT8':
        small = array('b', [0]) * count
        attr.data.foreach_get('value', small)
        return array('i', small)
    attr.data.foreach_get('value', out)
    return out


def _finite(values):
    """Not-a-number and infinite positions as 0, as the mesh mirror draws
    them (`_blenderkit_sync._finite_or_zero`)."""
    if any(not math.isfinite(v) for v in values):
        for i, v in enumerate(values):
            if not math.isfinite(v):
                values[i] = 0.0
    return values


def drawing_arrays(drawing):
    """(header, [buffers]) for one drawing, in the order Swift reads them
    (`GreasePencilWire`): positions (3 floats a point), radii, opacities,
    vertex colours (4 a point, when present), curve offsets (strokes + 1
    ints), cyclic, material index, fill id, hide stroke (an int a stroke),
    fill colours (4 floats a stroke, when present)."""
    attrs = drawing.attributes
    position = attrs.get('position')
    n = len(position.data) if position is not None else 0
    strokes = len(drawing.strokes)
    pos = array('f', [0.0]) * (3 * n)
    if n:
        position.data.foreach_get('vector', pos)
        _finite(pos)
    radius, _ = _floats(attrs, 'radius', n, 1, DEFAULT_RADIUS)
    opacity, _ = _floats(attrs, 'opacity', n, 1, DEFAULT_OPACITY)
    vcol, has_vcol = _floats(attrs, 'vertex_color', n, 4, None)
    offsets = array('i', [0]) * (strokes + 1)
    if strokes:
        drawing.curve_offsets.foreach_get('value', offsets)
    cyclic = _ints(attrs, 'cyclic', strokes)
    material = _ints(attrs, 'material_index', strokes)
    fill_id = _ints(attrs, 'fill_id', strokes)
    # 5.2's `hide_stroke`: the stroke's line is not drawn, its fill is — the
    # Monkey's face is a fill whose outline is hidden (measured: its Fills
    # layer's three filled strokes all have it).
    hidden = _ints(attrs, 'hide_stroke', strokes)
    fcol, has_fcol = _floats(attrs, 'fill_color', strokes, 4, None)
    buffers = [pos, radius, opacity]
    if has_vcol:
        buffers.append(vcol)
    buffers += [offsets, cyclic, material, fill_id, hidden]
    if has_fcol:
        buffers.append(fcol)
    header = {'points': n, 'strokes': strokes, 'vcol': has_vcol, 'fcol': has_fcol}
    return header, buffers


# --------------------------------------------------------------------------
# What each layer shows, and its onion skins

def _keyframes(layer):
    """Every keyframe of a layer: [frame, type, selected], by frame."""
    out = []
    for frame in layer.frames:
        out.append([int(frame.frame_number), str(frame.keyframe_type), bool(frame.select)])
    out.sort(key=lambda f: f[0])
    return out


def frame_in_effect(layer, current):
    """The start of the keyframe whose drawing a layer shows at `current`,
    or None before its first (`Layer::start_frame_at`)."""
    try:
        frame = layer.get_frame_at(int(current))
    except (AttributeError, RuntimeError, TypeError):
        frame = None
    return int(frame.frame_number) if frame is not None else None


def onion_frames(gp, layer, current, playing=False):
    """[(frame number, onion id)] of the keyframes a layer ghosts at
    `current`: negative ids before, positive after, by how far away — as
    GPv3 picks them (`get_visible_frames_for_layer`): Frames counts frame
    numbers from the current frame, Keyframes counts keyframes from the one in
    effect, Selected takes the selected keyframes; Filter by Type keeps one
    type; Show Start Frame adds the first keyframe after the last one."""
    if playing or not getattr(layer, 'use_onion_skinning', False):
        return []
    keys = _keyframes(layer)
    if not keys:
        return []
    mode = gp.onion_mode
    before = int(gp.ghost_before_range)
    after = int(gp.ghost_after_range)
    wanted = gp.onion_keyframe_type
    start = frame_in_effect(layer, current)
    numbers = [k[0] for k in keys]
    index = numbers.index(start) if start in numbers else -1
    out = []
    for i, (number, kind, selected) in enumerate(keys):
        if number == start:
            continue
        if wanted != 'ALL' and kind != wanted:
            continue
        if mode == 'ABSOLUTE':
            delta = number - int(current)
            if (delta < 0 and delta >= -before) or (0 < delta <= after):
                out.append((number, delta))
        elif mode == 'RELATIVE':
            # Before the first keyframe nothing is in effect: what follows
            # counts from where it would be.
            delta = i - index if index >= 0 else i + 1
            if (delta < 0 and delta >= -before) or (0 < delta <= after):
                out.append((number, delta))
        elif selected:
            out.append((number, i - index if index >= 0 else i + 1))
    if getattr(gp, 'use_onion_loop', False) and keys and start == numbers[-1] and len(numbers) > 1:
        first = numbers[0]
        if all(f != first for f, _ in out):
            out.append((first, 1))
    return out


def _onion_record(gp):
    return {'mode': gp.onion_mode, 'factor': float(gp.onion_factor), 'filter': gp.onion_keyframe_type,
            'before': int(gp.ghost_before_range), 'after': int(gp.ghost_after_range),
            'custom': bool(gp.use_ghost_custom_colors), 'before_color': [float(c) for c in gp.before_color],
            'after_color': [float(c) for c in gp.after_color], 'fade': bool(gp.use_onion_fade),
            'loop': bool(gp.use_onion_loop)}


def _material_record(slot):
    material = getattr(slot, 'material', None)
    style = getattr(material, 'grease_pencil', None) if material is not None else None
    if style is None:
        return None
    stroke = [float(c) for c in style.color]
    fill = [float(c) for c in style.fill_color]
    return {'name': material.name, 'stroke': stroke, 'fill': fill,
            'show_stroke': bool(getattr(style, 'is_stroke_visible', stroke[3] > 0)),
            'show_fill': bool(getattr(style, 'is_fill_visible', fill[3] > 0)),
            'hide': bool(style.hide), 'lock': bool(style.lock)}


def _matrix(layer):
    """The layer's own transform (Layer ▸ Transform), or None for none."""
    try:
        m = layer.matrix_local
    except AttributeError:
        return None
    values = [float(c) for row in m for c in row]
    identity = [1.0 if r == c else 0.0 for r in range(4) for c in range(4)]
    return None if values == identity else values


def record(obj, depsgraph=None, playing=False, hidden=False):
    """(record, buffers): the JSON record Swift reads (`GreasePencilWire`)
    and the drawings' buffers in its blocks' order."""
    gp = obj.data
    scene = bpy.context.scene
    current = scene.frame_current
    evaluated_gp = None
    if depsgraph is not None:
        try:
            evaluated_gp = obj.evaluated_get(depsgraph).data
        except (AttributeError, RuntimeError, ReferenceError):
            evaluated_gp = None
    active = gp.layers.active
    layers = []
    blocks = []
    buffers = []
    active_index = -1
    for i, layer in enumerate(gp.layers):
        if active is not None and layer == active:
            active_index = i
        start = frame_in_effect(layer, current)
        layers.append({'name': layer.name, 'hide': bool(layer.hide), 'lock': bool(layer.lock),
                       'opacity': float(layer.opacity),
                       'tint': [float(c) for c in layer.tint_color] + [float(layer.tint_factor)],
                       'onion': bool(layer.use_onion_skinning), 'matrix': _matrix(layer),
                       'frames': _keyframes(layer), 'frame': start,
                       'blend': str(layer.blend_mode), 'lights': bool(layer.use_lights)})
        if layer.hide or hidden:
            continue
        drawing = None
        if evaluated_gp is not None:
            evaluated = evaluated_gp.layers.get(layer.name)
            frame = evaluated.current_frame() if evaluated is not None else None
            drawing = frame.drawing if frame is not None else None
        if drawing is None and start is not None:
            frame = layer.current_frame()
            drawing = frame.drawing if frame is not None else None
        if drawing is not None:
            header, arrays = drawing_arrays(drawing)
            if header['points']:
                header['layer'] = i
                header['onion'] = 0
                blocks.append(header)
                buffers += arrays
        ghosts = onion_frames(gp, layer, current, playing)
        # `layer.frames` is keyed by index, not frame number: `frames.get(5)`
        # raises (measured in 5.2.1), so the frames are found by number here.
        by_number = {f.frame_number: f for f in layer.frames} if ghosts else {}
        for number, onion in ghosts:
            frame = by_number.get(number)
            if frame is None or frame.drawing is None:
                continue
            header, arrays = drawing_arrays(frame.drawing)
            if header['points']:
                header['layer'] = i
                header['onion'] = onion
                header['frame'] = number
                blocks.append(header)
                buffers += arrays
    materials = [_material_record(slot) for slot in obj.material_slots]
    out = {'layers': layers, 'active_layer': active_index, 'materials': materials,
           'active_material': int(obj.active_material_index),
           'depth_order': str(gp.stroke_depth_order), 'in_front': bool(obj.show_in_front),
           'onion': _onion_record(gp), 'blocks': blocks, 'frame': int(current)}
    return json.dumps(out, separators=(',', ':')), buffers


def signature(obj, playing=False):
    """What decides which drawings an object shows at the current frame: each
    layer's keyframe in effect and its onion frames. A frame change pushes an
    object again only when this changed."""
    gp = obj.data
    current = bpy.context.scene.frame_current
    out = []
    for layer in gp.layers:
        out.append((frame_in_effect(layer, current), tuple(onion_frames(gp, layer, current, playing))))
    return tuple(out)


_pushed = {}


def push(obj, depsgraph=None, playing=False, hidden=False):
    """Hands Swift one Grease Pencil object's drawings (`sync_gpencil`). In a
    mirroring pass onto the object the pass just pushed; outside one (a frame
    change) onto the one on screen. `hidden`: the layers alone, for an object
    the viewport does not draw."""
    sender = getattr(_blenderkit, 'sync_gpencil', None) if _blenderkit is not None else None
    if sender is None or getattr(obj, 'type', '') != 'GREASEPENCIL':
        return False
    text, buffers = record(obj, depsgraph, playing, hidden)
    blob = b''.join(b.tobytes() for b in buffers)
    sender(obj.name, text, blob)
    _pushed[obj.name] = signature(obj, playing)
    return True


def push_frame(scene, depsgraph=None, playing=False):
    """After a frame change: every drawn Grease Pencil object whose drawings in
    effect changed. Returns how many were pushed."""
    count = 0
    for obj in scene.objects:
        if getattr(obj, 'type', '') != 'GREASEPENCIL':
            continue
        try:
            drawn = obj.visible_get() and not obj.hide_viewport
        except (AttributeError, RuntimeError):
            drawn = False
        if not drawn:
            continue
        sig = signature(obj, playing)
        if _pushed.get(obj.name) == sig and not _animated(obj):
            continue
        if depsgraph is None:
            depsgraph = bpy.context.evaluated_depsgraph_get()
        try:
            if push(obj, depsgraph, playing):
                count += 1
        except ValueError:
            # Not on screen yet: the next whole pass brings it in.
            pass
    return count


def _animated(obj):
    """Whether something besides the keyframes changes the drawing over time:
    a modifier (Noise, Time Offset, Build can animate) or keyed data."""
    if len(getattr(obj, 'modifiers', ())):
        return True
    animation = getattr(obj.data, 'animation_data', None)
    return animation is not None and animation.action is not None


# --------------------------------------------------------------------------
# Draw Mode

def _object(name):
    obj = bpy.data.objects.get(name)
    if obj is None or obj.type != 'GREASEPENCIL':
        raise Refusal("There is no Grease Pencil object called " + repr(name) + ".")
    return obj


def _active_layer(obj):
    """The layer a stroke goes on, refused as Blender refuses it."""
    layer = obj.data.layers.active
    if layer is None:
        raise Refusal("No active Grease Pencil layer")
    if layer.lock or layer.hide:
        raise Refusal("Active layer is locked or hidden")
    return layer


def ensure_active_keyframe(obj, layer, scene=None):
    """The drawing a stroke drawn now goes into, made as Blender's
    `ensure_active_keyframe` makes it: with Auto Keying on, or no keyframe at
    or before the current frame, a keyframe at the current frame — a copy of
    the one in effect when Additive Drawing is on, blank otherwise; with Auto
    Keying off, the keyframe in effect. Returns (drawing, inserted)."""
    scene = scene or bpy.context.scene
    current = int(scene.frame_current)
    tools = scene.tool_settings
    start = frame_in_effect(layer, current)
    inserted = False
    if tools.use_keyframe_insert_auto or start is None:
        if start is None or start != current:
            if start is not None and tools.use_gpencil_draw_additive:
                layer.frames.copy(start, current)
            else:
                layer.frames.new(current)
            inserted = True
    frame = layer.get_frame_at(current)
    if frame is None or frame.drawing is None:
        raise Refusal("No Grease Pencil frame to draw on")
    return frame.drawing, inserted


def _set_floats(attrs, name, values, domain, kind):
    attr = attrs.get(name)
    if attr is None:
        attr = attrs.new(name, kind, domain)
    return attr


def draw_stroke(name, data, count, material=None, cyclic=False):
    """Writes one stroke the app drew (Draw Mode's Draw tool) into the active
    layer's drawing at the current frame, as one call.

    `data` holds `count` points, 5 floats each, in the LAYER's space: x, y,
    z, radius, opacity — the positions already on Blender's drawing plane
    (GreasePencilStroke.swift). The material is the object's active slot
    unless given. Returns a dict of what was made, for the checks."""
    obj = _object(name)
    if obj.mode != 'PAINT_GREASE_PENCIL':
        raise Refusal("Strokes are drawn in Draw Mode.")
    layer = _active_layer(obj)
    values = array('f')
    values.frombytes(data) if isinstance(data, (bytes, bytearray)) else values.extend(data)
    if count <= 0 or len(values) != 5 * count:
        raise Refusal("A stroke needs at least one point.")
    _finite(values)
    drawing, inserted = ensure_active_keyframe(obj, layer)
    first = len(drawing.strokes)
    first_point = len(drawing.attributes['position'].data) if drawing.attributes.get('position') else 0
    drawing.add_strokes([count])
    attrs = drawing.attributes
    total = len(attrs['position'].data)
    # Written whole, with the new stroke's points at the end.
    position = array('f', [0.0]) * (3 * total)
    attrs['position'].data.foreach_get('vector', position)
    for i in range(count):
        position[3 * (first_point + i):3 * (first_point + i) + 3] = values[5 * i:5 * i + 3]
    attrs['position'].data.foreach_set('vector', position)
    for column, attr_name, default in ((3, 'radius', DEFAULT_RADIUS), (4, 'opacity', DEFAULT_OPACITY)):
        attr = attrs.get(attr_name)
        if attr is None:
            # Made with Blender's default for the points already there.
            attr = attrs.new(attr_name, 'FLOAT', 'POINT')
            existing = array('f', [default]) * total
        else:
            existing = array('f', [0.0]) * total
            attr.data.foreach_get('value', existing)
        for i in range(count):
            existing[first_point + i] = values[5 * i + column]
        attr.data.foreach_set('value', existing)
    # A poly line, as the Pencil's Curve Type (`curve_type` POLY) makes it: a
    # drawing with no `curve_type` yet reads every curve as Catmull-Rom, which
    # Blender would draw smoothed between the points rather than through them.
    drawing.set_types(type='POLY', indices=[first])
    stroke = drawing.strokes[first]
    index = obj.active_material_index if material is None else int(material)
    stroke.material_index = max(0, min(index, max(len(obj.material_slots) - 1, 0)))
    stroke.cyclic = bool(cyclic)
    drawing.tag_positions_changed()
    return {'layer': layer.name, 'frame': int(bpy.context.scene.frame_current), 'inserted': inserted,
            'stroke': first, 'points': count, 'material': stroke.material_index}


# --------------------------------------------------------------------------
# Erase

ERASER_MODES = ('SOFT', 'HARD', 'STROKE')


def _screen(matrix, positions, view):
    """Each point's place in the 3D View (top-left origin, in its points)
    through a row-major 4x4 `matrix` taking `positions` (n x 3) to clip space,
    and whether it is in front of the eye. numpy arrays."""
    import numpy as np
    m = np.asarray(matrix, dtype=np.float64).reshape(4, 4)
    homogeneous = np.hstack([positions.astype(np.float64), np.ones((len(positions), 1))])
    clip = homogeneous @ m.T
    w = clip[:, 3]
    front = w > 1e-6
    safe = np.where(front, w, 1.0)
    x = (clip[:, 0] / safe * 0.5 + 0.5) * view[0]
    y = (0.5 - clip[:, 1] / safe * 0.5) * view[1]
    return np.stack([x, y], axis=1), front


def path_distance(points, path):
    """Each point's distance (n) to the polyline `path` (k x 2), numpy."""
    import numpy as np
    path = np.asarray(path, dtype=np.float64).reshape(-1, 2)
    if len(path) == 1:
        return np.linalg.norm(points - path[0], axis=1)
    a, b = path[:-1], path[1:]
    d = b - a
    length = np.maximum((d * d).sum(axis=1), 1e-12)
    best = np.full(len(points), np.inf)
    # In slices, so a long path over a large drawing stays a few MB.
    step = max(1, 2_000_000 // max(len(points), 1))
    for k in range(0, len(a), step):
        sa, sd, sl = a[k:k + step], d[k:k + step], length[k:k + step]
        rel = points[:, None, :] - sa[None, :, :]
        t = np.clip((rel * sd[None, :, :]).sum(axis=2) / sl[None, :], 0.0, 1.0)
        nearest = rel - t[:, :, None] * sd[None, :, :]
        best = np.minimum(best, np.sqrt((nearest * nearest).sum(axis=2)).min(axis=1))
    return best


def erase(name, matrix, view, path, radius, mode='SOFT', strength=1.0, active_layer_only=False):
    """Blender's Eraser over the drawings at the current frame: the points
    within `radius` points of the path the eraser took, seen through
    `matrix` (row-major world view-projection, 16 floats) in a view of
    `view` points. Stroke (STROKE) deletes every stroke it touches; Point
    (HARD) deletes the points, splitting a stroke where its middle went;
    Dissolve (SOFT) lowers their opacity by `strength` times the falloff and
    deletes what reaches 0. Locked and hidden layers are left alone, as
    Blender leaves them. Returns how many points were removed or changed."""
    import numpy as np
    from mathutils import Matrix
    obj = _object(name)
    if mode not in ERASER_MODES:
        raise Refusal("The Eraser's Mode is Dissolve, Point or Stroke.")
    if obj.mode != 'PAINT_GREASE_PENCIL':
        raise Refusal("Erasing is done in Draw Mode.")
    if len(path) < 2 or len(path) % 2:
        raise Refusal("The eraser needs a place on the view.")
    trail = np.asarray(path, dtype=np.float64).reshape(-1, 2)
    view_projection = Matrix([matrix[0:4], matrix[4:8], matrix[8:12], matrix[12:16]])
    current = bpy.context.scene.frame_current
    active = obj.data.layers.active
    changed = 0
    for layer in obj.data.layers:
        if layer.hide or layer.lock or (active_layer_only and layer != active):
            continue
        frame = layer.get_frame_at(current)
        if frame is None or frame.drawing is None:
            continue
        drawing = frame.drawing
        header, arrays = drawing_arrays(drawing)
        n = header['points']
        if not n:
            continue
        to_clip = view_projection @ obj.matrix_world @ layer.matrix_local
        positions = np.frombuffer(arrays[0].tobytes(), dtype=np.float32).reshape(-1, 3)
        screen, front = _screen([c for row in to_clip for c in row], positions, view)
        distance = path_distance(screen, trail)
        inside = front & (distance <= radius)
        offsets = arrays[3 + int(header['vcol'])]
        # A stroke whose points are further apart than the eraser is wide can
        # cross its path between two of them. Stroke deletes what it touches,
        # so the segments count too; Point and Dissolve need points there,
        # which are put on those segments first, a half radius apart, as
        # Blender's eraser cuts a segment where it crosses.
        crossed, cuts = _segments_crossed(screen, front, offsets, trail, radius)
        if mode == 'STROKE':
            inside = inside | crossed
        elif cuts:
            _insert_points(drawing, offsets, cuts)
            header, arrays = drawing_arrays(drawing)
            positions = np.frombuffer(arrays[0].tobytes(), dtype=np.float32).reshape(-1, 3)
            screen, front = _screen([c for row in to_clip for c in row], positions, view)
            distance = path_distance(screen, trail)
            inside = front & (distance <= radius)
            offsets = arrays[3 + int(header['vcol'])]
        if not inside.any():
            continue
        if mode == 'SOFT':
            # Blender's soft eraser: full at the centre, nothing at the rim.
            hit = np.where(inside, 1.0 - distance / max(radius, 1e-6), 0.0)
        else:
            hit = inside.astype(np.float64)
        changed += _apply_erase(drawing, offsets, hit.tolist(), mode, strength, arrays[2])
    return changed


def _segments_crossed(screen, front, offsets, trail, radius):
    """For each point, whether the segment from it to the next point of its
    stroke passes within `radius` of the path — the segment sampled at least
    every half radius, numpy — and, for the segments that do, the fractions
    of the way along them of those samples: (crossed, {point: [t, …]})."""
    import numpy as np
    n = len(screen)
    crossed = np.zeros(n, dtype=bool)
    cuts = {}
    if n < 2:
        return crossed, cuts
    last = np.zeros(n, dtype=bool)
    ends = np.asarray(offsets[1:], dtype=np.int64) - 1
    last[ends[ends >= 0]] = True
    a, b = screen[:-1], screen[1:]
    usable = ~last[:-1] & front[:-1] & front[1:]
    length = np.linalg.norm(b - a, axis=1)
    steps = np.where(usable, np.ceil(length / max(radius * 0.5, 0.5)).astype(np.int64), 0)
    long = np.nonzero(steps > 1)[0]
    for i in long[:20000]:
        t = np.linspace(0.0, 1.0, int(min(steps[i], 400)) + 1)[1:-1, None]
        samples = a[i] + (b[i] - a[i]) * t
        if (path_distance(samples, trail) <= radius).any():
            crossed[i] = True
            cuts[int(i)] = [float(v) for v in t[:, 0]]
    return crossed, cuts


def _apply_erase(drawing, offsets, hit, mode, strength, opacity):
    strokes = len(offsets) - 1
    if mode == 'STROKE':
        doomed = [s for s in range(strokes) if any(hit[offsets[s]:offsets[s + 1]])]
        if doomed:
            drawing.remove_strokes(indices=doomed)
        return sum(offsets[s + 1] - offsets[s] for s in doomed)
    keep = [True] * len(hit)
    changed = 0
    if mode == 'SOFT':
        new_opacity = array('f', opacity)
        for i, h in enumerate(hit):
            if h > 0:
                new_opacity[i] = max(0.0, opacity[i] - strength * h)
                changed += 1
                if new_opacity[i] <= 1e-3:
                    keep[i] = False
        attr = drawing.attributes.get('opacity') or drawing.attributes.new('opacity', 'FLOAT', 'POINT')
        attr.data.foreach_set('value', new_opacity)
    else:
        for i, h in enumerate(hit):
            if h > 0:
                keep[i] = False
                changed += 1
    if all(keep):
        return changed
    _remove_points(drawing, offsets, keep)
    return changed


def _remove_points(drawing, offsets, keep):
    """Deletes the points `keep` says to, splitting a stroke into the runs
    left (a cyclic one opened where it was cut), with every attribute of the
    points and the strokes carried over."""
    strokes = len(offsets) - 1
    runs = []          # (source stroke, [point indices])
    for s in range(strokes):
        start, end = offsets[s], offsets[s + 1]
        indices = list(range(start, end))
        if all(keep[i] for i in indices):
            runs.append((s, indices, None))
            continue
        cyclic = bool(drawing.strokes[s].cyclic)
        pieces = []
        current = []
        for i in indices:
            if keep[i]:
                current.append(i)
            elif current:
                pieces.append(current)
                current = []
        if current:
            pieces.append(current)
        if cyclic and len(pieces) > 1 and keep[start] and keep[end - 1]:
            # The run through the end joins the one from the start.
            pieces[0] = pieces[-1] + pieces[0]
            pieces.pop()
        for piece in pieces:
            runs.append((s, piece, False))
    _rebuild(drawing, runs)


def _rebuild(drawing, runs):
    """Makes the drawing's strokes `runs` — (source stroke, [point sources],
    cyclic or None to keep the source's) — every attribute carried over. A
    point source is a point's index, or (i, j, t): a new point t of the way
    from point i to point j, its float attributes interpolated, the rest
    point i's."""
    point_attrs = []
    curve_attrs = []
    for attr in drawing.attributes:
        if attr.name.startswith('.'):
            continue
        width = {'FLOAT_VECTOR': 3, 'FLOAT_COLOR': 4, 'BYTE_COLOR': 4, 'FLOAT2': 2, 'INT32_2D': 2,
                 'QUATERNION': 4, 'FLOAT4X4': 16}.get(attr.data_type, 1)
        key = {'FLOAT_VECTOR': 'vector', 'FLOAT_COLOR': 'color', 'BYTE_COLOR': 'color', 'FLOAT2': 'vector',
               'INT32_2D': 'value', 'QUATERNION': 'value', 'FLOAT4X4': 'value'}.get(attr.data_type, 'value')
        code = 'i' if attr.data_type in ('INT', 'INT8', 'BOOLEAN', 'INT32_2D') else 'f'
        size = len(attr.data)
        values = array(code, [0]) * (size * width)
        if attr.data_type in ('BOOLEAN', 'INT8'):
            raw = array('b', [0]) * size
            attr.data.foreach_get(key, raw)
            values = array('i', raw)
        else:
            attr.data.foreach_get(key, values)
        (point_attrs if attr.domain == 'POINT' else curve_attrs).append((attr.name, attr.data_type, attr.domain, width, key, values))
    sizes = [len(points) for _, points, _ in runs]
    drawing.remove_strokes()
    if not sizes:
        return
    drawing.add_strokes(sizes)
    total = sum(sizes)
    for name, data_type, domain, width, key, values in point_attrs:
        attr = drawing.attributes.get(name) or drawing.attributes.new(name, data_type, domain)
        out = array(values.typecode, [0]) * (total * width)
        floats = values.typecode == 'f'
        k = 0
        for _, points, _ in runs:
            for source in points:
                if isinstance(source, tuple):
                    i, j, t = source
                    if floats:
                        out[k * width:(k + 1) * width] = array('f', (
                            values[i * width + c] + (values[j * width + c] - values[i * width + c]) * t
                            for c in range(width)))
                    else:
                        out[k * width:(k + 1) * width] = values[i * width:(i + 1) * width]
                else:
                    out[k * width:(k + 1) * width] = values[source * width:(source + 1) * width]
                k += 1
        _set(attr, key, out, data_type)
    for name, data_type, domain, width, key, values in curve_attrs:
        attr = drawing.attributes.get(name) or drawing.attributes.new(name, data_type, domain)
        out = array(values.typecode, [0]) * (len(runs) * width)
        for r, (s, _, cyclic) in enumerate(runs):
            out[r * width:(r + 1) * width] = values[s * width:(s + 1) * width]
            if name == 'cyclic' and cyclic is False:
                out[r] = 0
        _set(attr, key, out, data_type)
    drawing.tag_positions_changed()


def _insert_points(drawing, offsets, inserts):
    """Adds points along segments: `inserts` maps a point's index to the
    fractions of the way to the next point of its stroke (the first, past
    the last of a cyclic one) to put one at, so an eraser has points where it
    crossed a long segment."""
    runs = []
    for s in range(len(offsets) - 1):
        start, end = offsets[s], offsets[s + 1]
        cyclic = bool(drawing.strokes[s].cyclic)
        points = []
        for i in range(start, end):
            points.append(i)
            j = i + 1 if i + 1 < end else (start if cyclic else None)
            if j is None:
                continue
            for t in inserts.get(i, ()):
                points.append((i, j, t))
        runs.append((s, points, None))
    _rebuild(drawing, runs)


def _set(attr, key, values, data_type):
    if data_type in ('BOOLEAN', 'INT8'):
        attr.data.foreach_set(key, array('b', (1 if v else 0 for v in values)) if data_type == 'BOOLEAN'
                              else array('b', values))
    else:
        attr.data.foreach_set(key, values)


# --------------------------------------------------------------------------
# Layers and materials

def layer_set_active(name, layer_name):
    obj = _object(name)
    layer = obj.data.layers.get(layer_name)
    if layer is None:
        raise Refusal("There is no layer called " + repr(layer_name) + ".")
    obj.data.layers.active = layer


def layer_set(name, layer_name, key, value):
    """One of a layer's settings, as the Layers panel's row writes it."""
    if key not in ('name', 'hide', 'lock', 'opacity', 'use_onion_skinning', 'use_lights', 'tint_factor'):
        raise Refusal("The app does not set a layer's " + key + ".")
    obj = _object(name)
    layer = obj.data.layers.get(layer_name)
    if layer is None:
        raise Refusal("There is no layer called " + repr(layer_name) + ".")
    setattr(layer, key, value)
    return getattr(layer, key)


def material_add(name, colour, fill=None):
    """A new Grease Pencil material with `colour` (RGBA, scene-linear) as its
    stroke colour, in a new slot made active: Blender's material slot + New,
    whose Grease Pencil data `bpy.data.materials.create_gpencil_data` makes.
    Its fill is the same colour, as Blender's new material's is."""
    obj = _object(name)
    material = bpy.data.materials.new("Material")
    bpy.data.materials.create_gpencil_data(material)
    rgba = [float(c) for c in colour] + [1.0] * (4 - len(colour))
    material.grease_pencil.color = rgba[:4]
    material.grease_pencil.fill_color = list(fill) if fill is not None else rgba[:4]
    obj.data.materials.append(material)
    obj.active_material_index = len(obj.material_slots) - 1
    return material.name


def material_set_colour(name, index, colour):
    obj = _object(name)
    slot = obj.material_slots[int(index)]
    if slot.material is None or slot.material.grease_pencil is None:
        raise Refusal("That slot has no Grease Pencil material.")
    slot.material.grease_pencil.color = [float(c) for c in colour][:4]


# --------------------------------------------------------------------------
# The brush

def _paint():
    return bpy.context.scene.tool_settings.gpencil_paint


def brushes():
    """The Essentials library's Grease Pencil Draw brushes, by name, [] where
    the build has none."""
    import os
    try:
        folder = bpy.utils.system_resource('DATAFILES', path='assets/brushes')
    except Exception:                               # noqa: BLE001 - no library is the answer
        return []
    path = os.path.join(folder, ESSENTIALS_FILE) if folder else ''
    if not path or not os.path.isfile(path):
        return []
    with bpy.data.libraries.load(path, assets_only=True) as (source, _):
        return sorted(source.brushes)


def _curve_samples(mapping, samples=17):
    """A pressure curve sampled at 0, 1/16 … 1, for the app's live preview."""
    try:
        curve = mapping.curves[0]
        return [float(mapping.evaluate(curve, i / (samples - 1))) for i in range(samples)]
    except (AttributeError, IndexError, RuntimeError):
        return [i / (samples - 1) for i in range(samples)]


def state():
    """What Draw Mode's header and the app's stroke need from Blender, as JSON."""
    tools = bpy.context.scene.tool_settings
    brush = _paint().brush if _paint() is not None else None
    out = {'placement': tools.gpencil_stroke_placement_view3d,
           'plane': tools.gpencil_sculpt.lock_axis,
           'auto_key': bool(tools.use_keyframe_insert_auto),
           'additive': bool(tools.use_gpencil_draw_additive),
           'cursor': [float(c) for c in bpy.context.scene.cursor.location],
           'cursor_rotation': [float(c) for row in bpy.context.scene.cursor.matrix.to_3x3() for c in row],
           'brush': None}
    if brush is not None:
        settings = brush.gpencil_settings
        out['brush'] = {
            'name': brush.name, 'type': getattr(brush, 'gpencil_brush_type', 'DRAW'),
            'size': int(brush.size), 'unprojected_size': float(brush.unprojected_size),
            'unit': str(brush.use_locked_size), 'strength': float(brush.strength),
            'use_pressure_size': bool(brush.use_pressure_size),
            'use_pressure_strength': bool(brush.use_pressure_strength),
            'size_curve': _curve_samples(settings.curve_sensitivity) if settings else None,
            'strength_curve': _curve_samples(settings.curve_strength) if settings else None,
            'active_smooth': float(settings.active_smooth_factor) if settings else 0.0,
            'simplify_px': float(settings.simplify_pixel_threshold) if settings else 0.0,
            'hardness': float(settings.hardness) if settings else 1.0,
            'eraser_mode': str(settings.eraser_mode) if settings else 'SOFT',
            'caps': str(settings.caps_type) if settings else 'ROUND',
        }
    return json.dumps(out)


def set_brush(key, value):
    """One of the active brush's settings (Size, Strength, their pressure
    toggles), as the header writes it."""
    brush = _paint().brush
    if brush is None:
        raise Refusal("Draw Mode has no brush.")
    if key not in ('size', 'unprojected_size', 'strength', 'use_pressure_size', 'use_pressure_strength'):
        raise Refusal("The app does not set a brush's " + key + ".")
    setattr(brush, key, value)
    return getattr(brush, key)


def activate(name):
    """Makes an Essentials Grease Pencil Draw brush the Draw Mode brush, as
    the asset shelf does (`brush.asset_activate`), under the borrowed 3D View
    with Draw Mode's tool (`_blenderkit_context.give_brush_tool`)."""
    if name not in brushes():
        raise Refusal("There is no Essentials Grease Pencil brush called " + repr(name) + ".")
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.mode != 'PAINT_GREASE_PENCIL':
        raise Refusal("Pick a Grease Pencil brush in Draw Mode.")
    knife = sys.modules.get('_blenderkit_knife')
    if knife is None:
        import _blenderkit_knife as knife
    context = sys.modules.get('_blenderkit_context')
    if context is None:
        import _blenderkit_context as context
    window, area, region = knife.view3d("Picking a brush")
    with bpy.context.temp_override(window=window, area=area, region=region):
        context.give_brush_tool("Picking a brush")
        result = bpy.ops.brush.asset_activate(asset_library_type='ESSENTIALS',
                                              relative_asset_identifier=ASSET_PREFIX + name)
    brush = _paint().brush
    if 'FINISHED' not in result or brush is None or brush.name != name:
        raise Refusal("Blender could not load the " + name + " brush.")
    return name


# --------------------------------------------------------------------------
# The Timeline: each layer's keyframes, one channel per layer

class LayerChannel:
    """A Grease Pencil layer's keyframes as one of the Timeline's channels
    (`_blenderkit_anim.register_channel_source`), as Blender's Dope Sheet
    lists a layer under its object: `frames()` the keyframes' frame numbers,
    `flags()` each one's selection and keyframe type, `select(mask)` and
    `deselect_channel()` Blender's own `frame.select` and `layer.select`.
    Blender's action and transform operators edit them as they edit F-Curve
    keys (the Timeline's G, S, X, Shift+D move `layer.frames`)."""
    __slots__ = ('layer',)

    def __init__(self, layer):
        self.layer = layer

    @property
    def key(self):
        return self.layer.as_pointer()

    def frames(self):
        return array('f', (float(f.frame_number) for f in self.layer.frames))

    def selection(self):
        return [bool(f.select) for f in self.layer.frames]

    def flags(self):
        anim = sys.modules.get('_blenderkit_anim')
        types = getattr(anim, 'KEY_TYPES', ('KEYFRAME',))
        out = []
        for f in self.layer.frames:
            kind = types.index(f.keyframe_type) if f.keyframe_type in types else 0
            out.append((1 if f.select else 0) | ((kind & 7) << 1))
        return out

    def select(self, mask):
        frames = list(self.layer.frames)
        if len(mask) != len(frames):
            return
        for frame, on in zip(frames, mask):
            frame.select = bool(on)

    def deselect_channel(self):
        self.layer.select = False


def timeline_channels(idblock):
    """The channels of a Grease Pencil data-block: a layer with keyframes
    each. Nothing for any other data-block."""
    if getattr(bpy.types, 'GreasePencil', None) is None or not isinstance(idblock, bpy.types.GreasePencil):
        return
    for layer in idblock.layers:
        if len(layer.frames):
            yield LayerChannel(layer)


def _register_timeline():
    """Plugs the layers into the Timeline (`_blenderkit_anim`), once, as
    this module is imported — by the mirror's first Grease Pencil object,
    before its pass reports the keys."""
    anim = sys.modules.get('_blenderkit_anim')
    if anim is None:
        try:
            import _blenderkit_anim as anim
        except ImportError:
            return
    register = getattr(anim, 'register_channel_source', None)
    if register is not None:
        register(timeline_channels)


_register_timeline()
