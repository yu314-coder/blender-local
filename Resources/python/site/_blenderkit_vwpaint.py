"""Blender's own Weight Paint and Vertex Paint, stroked from the app's 3D View.

The app used to paint weights and colours into its own display cache, and
nothing ever reached Blender: the stroke was drawn, kept nowhere, and gone at
the next mirroring pass (round 3's review). Now both are Blender's modes, as
Sculpt Mode is (`_blenderkit_sculpt`): `object.mode_set` into them, Blender's
brushes from its Essentials library, and each stroke Blender's own
`paint.weight_paint` / `paint.vertex_paint`, streamed in chunks while the
finger moves, with the painted values mirrored back after every chunk — so the
3D View shows what Blender holds, and what is kept is what was shown.

Measured in desktop Blender 5.2.1 under `-b --factory-startup` with the app's
context (its undo stack, `gpu.init()`, the startup screen's 3D View borrowed
and aimed at the app's camera, `_blenderkit_sculpt.aim`), and held to it by
scripts/run-vwpaint-blender-check.sh:

  * Both operators run under the 3D View override and fail their poll without
    it ("context is incorrect"), so a script line without a view is refused
    by Blender itself, not crashed.

  * Called by `EXEC_DEFAULT` they take each stroke element's `location` as
    given, and paint nothing where it is not on the surface; with
    `override_location=True` they find it from the element's mouse position,
    as the modal stroke does. Every element is one dab, so spacing is done
    here (`_space`), as for sculpting.

  * One stroke cut into separate strokes is not the same stroke: without
    Accumulate a stroke never takes a vertex past the brush's strength, and
    three strokes of 8, 4 and 10 dabs left a weight of 0.484 where the same
    22 dabs as one stroke left 0.300 (strength 0.3). So each chunk undoes the
    stroke so far and replays it whole, which matched the one stroke exactly
    for every Essentials brush of both modes. A long stroke is never cut into
    strokes of its own for being long: cut at 64 dabs as a sculpt stroke is,
    216 dabs back and forth over a ball at strength 0.3 came out 0.456 apart
    in weight (0.345 in colour) from the same dabs as one stroke, the passes
    over each other adding up. Once a replay costs more than
    REPLAY_BUDGET_MS, the next waits until REPLAY_DUTY times that has passed
    (the view shows Blender's last replay meanwhile), and the stroke's end
    replays whatever came after it. Only at MAX_STROKE_DABS is a stroke
    kept and gone on with as a new one, cut there at once (`_next_replay`).

  * Each stroke pushes one Global Undo (memfile) step, named after the mode:
    "Weight Paint", "Vertex Paint" (`print_undo_steps`). Its rewind is a
    memfile undo, 2.5 to 5 ms on the dinosaur file, after which the Python
    objects from before it are gone: everything is fetched again. Entering
    and leaving the modes are steps named "Weight Paint Mode" and "Vertex
    Paint Mode".

  * Blender makes what a stroke needs on its first dab: a vertex group named
    "Group" when the mesh has none, a colour attribute "Attribute" (face
    corner, byte colour) when it has none. Their Undo takes them back too.

  * The brush's colour is scene linear (`Brush.color` and the unified
    colour are subtype COLOR in 5.2.1): the header's sRGB is converted on the
    way in and out (`_held_colour`, `shown_colour`), so sRGB 0.5 grey paints
    sRGB 0.502 (a byte), where written as it came it painted 0.737.

  * What it does not check, and is checked here: a locked active group
    (Blender answers FINISHED, warns "Active group is locked, aborting" and
    still pushes a step), a hidden object and a mesh with no faces (both
    FINISHED, a step each, nothing painted), and a stroke whose every dab is
    off the surface (FINISHED, and an empty step pushed).
"""

import math
import time
from array import array

import bpy

import _blenderkit_knife as _knife
import _blenderkit_sculpt as _sculpt
import _blenderkit_undo as _undo

MODES = ('WEIGHT_PAINT', 'VERTEX_PAINT')
# What Blender's mode menu and undo history call them.
MODE_NAMES = {'WEIGHT_PAINT': "Weight Paint", 'VERTEX_PAINT': "Vertex Paint"}
ESSENTIALS_FILES = {'WEIGHT_PAINT': 'essentials_brushes-mesh_weight.blend',
                    'VERTEX_PAINT': 'essentials_brushes-mesh_vertex.blend'}
# Blender 5.2.1's toolbar for both modes starts Brush, Blur, Average, Smear
# (VIEW3D_PT_tools_active, tests/names/reference/blender_toolbar.json); each
# tool takes a brush of its own type (measured: tool_set_by_id made Paint,
# Blur, Average and Smear the weight brush in turn, and activating the Blur
# asset set the tool to builtin_brush.blur).
TOOLS = {'BRUSH': 'builtin.brush', 'BLUR': 'builtin_brush.blur',
         'AVERAGE': 'builtin_brush.average', 'SMEAR': 'builtin_brush.smear'}
_TOOL_OF_TYPE = {'DRAW': 'BRUSH', 'BLUR': 'BLUR', 'AVERAGE': 'AVERAGE', 'SMEAR': 'SMEAR'}

# A replay that costs up to this runs with every chunk, as a sculpt stroke's
# does (`_blenderkit_sculpt`); a dearer one waits until REPLAY_DUTY times its
# cost has passed since it ran, so a long stroke keeps the 3D View answering
# (at most a third of the time in Blender) and stays one stroke. The cost is
# the rewind, the replay and the mirror after it (`values`): round 4's review
# found the throttle counting the first two only, while the mirror of a
# 40,962-vertex colour layer took 95.7 ms a chunk.
REPLAY_BUDGET_MS = 25.0
REPLAY_DUTY = 2.0
# Past this many dabs the stroke so far is kept and the rest goes on as a new
# stroke: each replay rebuilds every dab, and this bounds what one costs.
MAX_STROKE_DABS = 2048

Refusal = RuntimeError


def _is_real_blender():
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _active():
    return bpy.context.view_layer.objects.active


def _mode():
    obj = _active()
    mode = getattr(obj, 'mode', 'OBJECT') if obj is not None else 'OBJECT'
    return mode if mode in MODES else None


def _paint(mode):
    """The mode's Paint settings, fetched afresh: a memfile undo replaces the
    ToolSettings struct, and a reference kept from before it reads freed
    memory (measured in desktop 5.2.1: a `tool_settings` held across an
    `ed.undo` in Weight Paint read its brush as None, then as garbage, and
    the next read segfaulted in `pyrna_prop_to_py`)."""
    ts = bpy.context.scene.tool_settings
    return ts.weight_paint if mode == 'WEIGHT_PAINT' else ts.vertex_paint


def _brush(mode):
    return _paint(mode).brush


def _owner(mode, what):
    """Where Blender reads `what` (size, strength, weight, color): the mode's
    unified settings while their Unified switch is on, the brush's own
    otherwise."""
    paint = _paint(mode)
    ups = paint.unified_paint_settings
    if getattr(ups, 'use_unified_' + what, False):
        return ups
    return paint.brush


def _brush_type(mode, brush):
    if brush is None:
        return None
    return getattr(brush, 'weight_brush_type' if mode == 'WEIGHT_PAINT' else 'vertex_brush_type', None)


def _refuse_during_stroke(what):
    """Each chunk rewinds the step on top of Blender's stack, so nothing else
    may push one while a stroke is open (as for sculpting)."""
    if _stroke is not None:
        raise Refusal(what + " waits until the paint stroke in progress has ended.")


def _require_mode(what):
    if not _is_real_blender():
        raise Refusal(what + " runs in Blender, and the simulator's stand-in does not have it.")
    mode = _mode()
    if mode is None:
        raise Refusal(what + " works in Weight Paint or Vertex Paint.")
    return mode


# --------------------------------------------------------------------------
# The brushes

_names = {}


def essentials_path(mode):
    """Blender's Essentials brushes for `mode`, or '' when this build has none."""
    import os
    try:
        folder = bpy.utils.system_resource('DATAFILES', path='assets/brushes')
    except Exception:                               # noqa: BLE001 - no library is the answer
        return ''
    path = os.path.join(folder, ESSENTIALS_FILES[mode]) if folder else ''
    return path if path and os.path.isfile(path) else ''


def brushes(mode=None):
    """The names of the Essentials brushes of `mode` (the active object's when
    None), sorted; [] without the library."""
    mode = mode or _mode()
    if mode not in MODES:
        return []
    if mode not in _names:
        path = essentials_path(mode)
        if not path:
            return []
        with bpy.data.libraries.load(path, assets_only=True) as (source, _):
            _names[mode] = sorted(source.brushes)
    return list(_names[mode])


def _view_override(what):
    window, area, region = _knife.view3d(what)
    return bpy.context.temp_override(window=window, area=area, region=region)


def activate(name):
    """Makes an Essentials brush the mode's brush, as the asset shelf does.
    Blender switches the tool to the brush's type (Blur to Blur, ...)."""
    mode = _require_mode("Picking a brush")
    if name not in brushes(mode):
        if not essentials_path(mode):
            raise Refusal("Blender's Essentials brushes for " + MODE_NAMES[mode] + " are not in this "
                          "build, so there is no " + name + " brush to pick.")
        raise Refusal("There is no Essentials " + MODE_NAMES[mode] + " brush called " + repr(name) + ".")
    _refuse_during_stroke("Picking a brush")
    if not _knife.on_main_thread():
        raise Refusal("Picking a brush works through Blender's 3D View, which exists on the main "
                      "thread only.")
    with _view_override(MODE_NAMES[mode]):
        # A file saved in this mode opens with no tool for it, and
        # asset_activate then segfaults (`_blenderkit_sculpt.ensure_view_tool`).
        _sculpt.ensure_view_tool("Picking a brush", mode)
        result = bpy.ops.brush.asset_activate(
            asset_library_type='ESSENTIALS',
            relative_asset_identifier='brushes/' + ESSENTIALS_FILES[mode] + '/Brush/' + name)
    brush = _brush(mode)
    if 'FINISHED' not in result or brush is None or brush.name != name:
        raise Refusal("Blender could not load the " + name + " brush.")
    return name


def set_tool(tool):
    """The toolbar's Brush, Blur, Average or Smear (`wm.tool_set_by_id`)."""
    mode = _require_mode("The tool")
    if tool not in TOOLS:
        raise Refusal("The paint tools here are " + ", ".join(t.title() for t in TOOLS) + ", not "
                      + repr(tool) + ".")
    _refuse_during_stroke("The tool")
    with _view_override(MODE_NAMES[mode]):
        bpy.ops.wm.tool_set_by_id(name=TOOLS[tool], space_type='VIEW_3D')
    return tool


def _set(what, value, label):
    mode = _require_mode(label)
    _refuse_during_stroke(label)
    owner = _owner(mode, what)
    if owner is None:
        raise Refusal("There is no " + MODE_NAMES[mode] + " brush to set the " + label + " of.")
    if what == 'size':
        owner.size = int(round(value))
    elif what == 'color':
        owner.color = _held_colour(owner, value)
    else:
        setattr(owner, what, float(value))
    return getattr(owner, what)


def set_size(value):
    """Blender's Size (the header's own text for `size`): the brush's
    diameter in the region's pixels."""
    return _set('size', value, "Size")


def set_strength(value):
    return _set('strength', value, "Strength")


def set_weight(value):
    if _mode() != 'WEIGHT_PAINT':
        raise Refusal("Weight is Weight Paint's.")
    return _set('weight', min(max(float(value), 0.0), 1.0), "Weight")


def set_blend(identifier):
    """The brush's Blend (`Brush.blend`), which Blender's header shows for
    Vertex Paint and for Weight Paint's Draw brush."""
    mode = _require_mode("Blend")
    _refuse_during_stroke("Blend")
    brush = _brush(mode)
    if brush is None:
        raise Refusal("There is no " + MODE_NAMES[mode] + " brush to set the Blend of.")
    known = [item.identifier for item in brush.bl_rna.properties['blend'].enum_items]
    if identifier not in known:
        raise Refusal("Blend is one of " + ", ".join(known) + ", not " + repr(identifier) + ".")
    brush.blend = identifier
    return brush.blend


def _scene_linear(owner):
    """Whether Blender holds `owner`'s colour in scene-linear space. In
    desktop 5.2.1 `Brush.color`, `UnifiedPaintSettings.color` and their
    `secondary_color` are all subtype COLOR, which is scene linear; a
    COLOR_GAMMA one would hold sRGB as it is. Read from the running build
    rather than assumed, as the app's own bpy is 5.3."""
    try:
        return owner.bl_rna.properties['color'].subtype != 'COLOR_GAMMA'
    except (AttributeError, KeyError):
        return True


def _held_colour(owner, srgb):
    """What Blender is to hold for the sRGB colour `srgb` (the colour picker's,
    as Blender's own picker shows a colour): converted to scene linear by
    Blender's colour management where the property is scene linear. Written as
    it came, `set_color((0.5, 0.5, 0.5))` stored 0.5 and the stroke painted
    sRGB 0.737 (round 4's review, desktop 5.2.1, Paint Hard at strength 1),
    so the swatch showed a colour Blender did not hold and the paint came out
    lighter than the one picked."""
    rgb = tuple(min(max(float(c), 0.0), 1.0) for c in srgb)[:3]
    if not _scene_linear(owner):
        return rgb
    from mathutils import Color
    return tuple(Color(rgb).from_srgb_to_scene_linear())


def shown_colour(owner):
    """`owner`'s colour as Blender's colour picker shows it, in sRGB: what the
    header's swatch draws and what a stroke paints into a colour attribute
    (`color_srgb`)."""
    held = tuple(owner.color)
    if not _scene_linear(owner):
        return held
    from mathutils import Color
    return tuple(Color(held).from_scene_linear_to_srgb())


def set_color(rgb):
    """Vertex Paint's colour, given in sRGB as the colour picker gives it, and
    held as Blender holds it (`_held_colour`). Returns it in sRGB, read back."""
    if _mode() != 'VERTEX_PAINT':
        raise Refusal("Color is Vertex Paint's.")
    _set('color', rgb, "Color")
    return shown_colour(_owner('VERTEX_PAINT', 'color'))


def state():
    """What the paint header shows, as Blender holds it."""
    real = _is_real_blender()
    obj = _active()
    mode = _mode()
    report = dict(real=real, mode=mode, object=obj.name if obj is not None else None)
    if not real or mode is None:
        return report
    brush = _brush(mode)
    report.update(essentials=bool(essentials_path(mode)), brush=brush.name if brush is not None else None)
    try:
        _, _, region = _knife.view3d(MODE_NAMES[mode])
        report['region'] = [region.width, region.height]
    except RuntimeError:
        report['region'] = None
    if brush is not None:
        kind = _brush_type(mode, brush)
        report.update(brush_type=kind, tool=_TOOL_OF_TYPE.get(kind, 'BRUSH'),
                      stroke_method=brush.stroke_method, blend=brush.blend,
                      blends=[[item.identifier, item.name]
                              for item in brush.bl_rna.properties['blend'].enum_items],
                      size=_owner(mode, 'size').size,
                      strength=round(_owner(mode, 'strength').strength, 4))
        if mode == 'WEIGHT_PAINT':
            report['weight'] = round(_owner(mode, 'weight').weight, 4)
        else:
            owner = _owner(mode, 'color')
            # The swatch's sRGB, and what Blender's RNA holds (scene linear in
            # 5.2.1), so a check can hold one to the other.
            report['color'] = [round(c, 4) for c in shown_colour(owner)]
            report['color_held'] = [round(c, 4) for c in owner.color]
            report['color_space'] = 'SCENE_LINEAR' if _scene_linear(owner) else 'SRGB'
    if obj is not None and obj.type == 'MESH':
        if mode == 'WEIGHT_PAINT':
            group = obj.vertex_groups.active
            report.update(group=group.name if group is not None else None,
                          group_locked=bool(group.lock_weight) if group is not None else False,
                          groups=len(obj.vertex_groups))
        else:
            layer = obj.data.color_attributes.active_color
            report.update(color_attribute=layer.name if layer is not None else None)
    steps = _undo.blender_steps()
    report['undo_stack'] = len(steps) if steps is not None else None
    return report


# --------------------------------------------------------------------------
# Modes

def enter(mode):
    """Into Weight Paint or Vertex Paint (`object.mode_set`), refused in words
    for what Blender would let in and not paint: anything but a mesh, a mesh
    with no faces, a hidden one."""
    if mode not in MODES:
        raise Refusal("The paint modes here are Weight Paint and Vertex Paint, not " + repr(mode) + ".")
    _refuse_during_stroke(MODE_NAMES[mode])
    obj = _active()
    if obj is None:
        raise Refusal(MODE_NAMES[mode] + " needs an object. Select a mesh first.")
    if obj.type != 'MESH':
        raise Refusal(MODE_NAMES[mode] + " works on meshes, and " + obj.name + " is not one.")
    if not obj.data.polygons:
        raise Refusal(obj.name + " has no faces to paint.")
    if not obj.visible_get():
        raise Refusal(obj.name + " is hidden. Show it to paint it.")
    if obj.mode == 'EDIT':
        bpy.ops.object.mode_set(mode='OBJECT')
    result = bpy.ops.object.mode_set(mode=mode)
    obj = _active()
    if 'FINISHED' not in result or obj is None or obj.mode != mode:
        raise Refusal("Blender would not take " + obj.name + " into " + MODE_NAMES[mode] + ".")
    push(obj)
    return mode


def leave():
    """Back to Object Mode from either paint mode."""
    _refuse_during_stroke("Object Mode")
    if _mode() is not None:
        bpy.ops.object.mode_set(mode='OBJECT')
    return 'OBJECT'


# --------------------------------------------------------------------------
# What the viewport draws

def _numpy():
    """numpy, which Blender's own Python ships (the app's bpy bundles it), or
    None where it is missing (the simulator's stand-in)."""
    try:
        import numpy
    except ImportError:
        return None
    return numpy


def values(obj, mode=None, depsgraph=None):
    """What the 3D View draws of `obj` in `mode`, per vertex of the evaluated
    mesh the mirror draws: the active group's weights (0 where a vertex is not
    in it) as float32, or the active colour attribute in sRGB as four float32
    each (a face-corner attribute averaged over each vertex's corners: a
    brush paints all a vertex's corners alike, measured 0 of 2,048 vertices
    with differing corners after a stroke). None when there is nothing to
    draw; b'' for an object with no group or no colour layer yet.

    Read from the evaluated mesh, so through its modifiers: a Subdivision
    carries the weights to its new vertices (8,066 read in 3.3 ms on a
    1,986-vertex sphere at level 1).

    It runs after every chunk of a stroke that changed something and in every
    mirroring pass, on the main thread. The corner average was a Python loop
    over every corner: round 4's review measured 6.4 ms at 2,562 vertices,
    23.7 at 10,242 and 95.7 at 40,962 (245,760 corners) in desktop 5.2.1. It
    is numpy's `bincount` now where numpy is there (`_numpy`). Blender has no
    bulk read of a vertex group's weights (no `foreach_get`, and the groups
    are not among a mesh's attributes in 5.2.1), so weights stay a loop: 18.8
    ms at 40,962 vertices by the review's measurement, 14.4 in the vwpaint
    check, where the corner average takes a few ms (that check prints both)."""
    mode = mode or getattr(obj, 'mode', None)
    if obj is None or obj.type != 'MESH' or mode not in MODES:
        return None
    depsgraph = depsgraph or bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        if mesh is None:
            return None
        count = len(mesh.vertices)
        if mode == 'WEIGHT_PAINT':
            group = obj.vertex_groups.active
            if group is None:
                return b''
            index = group.index
            weights = array('f', [0.0]) * count
            for vertex in mesh.vertices:
                for element in vertex.groups:
                    if element.group == index:
                        weights[vertex.index] = element.weight
                        break
            return weights.tobytes()
        layer = mesh.color_attributes.active_color
        if layer is None:
            name = obj.data.color_attributes.active_color_name
            layer = mesh.color_attributes.get(name) if name else None
        if layer is None:
            return b''
        if layer.domain not in ('POINT', 'CORNER'):
            return b''
        np = _numpy()
        if np is not None:
            return _colours_numpy(np, mesh, layer, count)
        colours = array('f', [0.0]) * (4 * len(layer.data))
        layer.data.foreach_get('color_srgb', colours)
        if layer.domain == 'POINT':
            return colours.tobytes() if len(layer.data) == count else b''
        corners = array('i', [0]) * len(mesh.loops)
        mesh.loops.foreach_get('vertex_index', corners)
        sums = array('f', [0.0]) * (4 * count)
        seen = array('i', [0]) * count
        for corner, v in enumerate(corners):
            base, source = 4 * v, 4 * corner
            sums[base] += colours[source]
            sums[base + 1] += colours[source + 1]
            sums[base + 2] += colours[source + 2]
            sums[base + 3] += colours[source + 3]
            seen[v] += 1
        for v in range(count):
            n = seen[v]
            base = 4 * v
            if n:
                for k in range(4):
                    sums[base + k] /= n
            else:
                sums[base:base + 4] = array('f', [1.0, 1.0, 1.0, 1.0])
        return sums.tobytes()
    finally:
        evaluated.to_mesh_clear()


def _colours_numpy(np, mesh, layer, count):
    """`values` for a colour layer, with numpy: the same sRGB per vertex, a
    corner layer averaged per vertex (white where a vertex has no corner)."""
    colours = np.empty(4 * len(layer.data), dtype=np.float32)
    layer.data.foreach_get('color_srgb', colours)
    if layer.domain == 'POINT':
        return colours.tobytes() if len(layer.data) == count else b''
    corners = np.empty(len(mesh.loops), dtype=np.int32)
    # Each corner's vertex, read through the mesh's own `.corner_vert`
    # attribute where it has one: 0.01 ms for 245,760 corners in desktop
    # 5.2.1, where `loops.foreach_get('vertex_index')` took 9.3 ms.
    corner_vert = mesh.attributes.get('.corner_vert')
    if (corner_vert is not None and corner_vert.domain == 'CORNER' and corner_vert.data_type == 'INT'
            and len(corner_vert.data) == len(corners)):
        corner_vert.data.foreach_get('value', corners)
    else:
        mesh.loops.foreach_get('vertex_index', corners)
    seen = np.bincount(corners, minlength=count)[:count]
    # One bincount over every channel of every corner (index 4 * vertex +
    # channel): 4.0 ms for 245,760 corners in desktop 5.2.1, 5.7 as four.
    channels = (corners[:, None] * 4 + np.arange(4, dtype=np.int32)).ravel()
    sums = np.bincount(channels, weights=colours, minlength=4 * count)[:4 * count].reshape(count, 4)
    with np.errstate(invalid='ignore', divide='ignore'):
        out = (sums / seen[:, None]).astype(np.float32)
    out[seen == 0] = 1.0
    return out.tobytes()


def push(obj, depsgraph=None):
    """Hands the viewport `obj`'s painted values (`_blenderkit.sync_paint`).
    The mirroring pass calls this for the active object in a paint mode, and
    every chunk of a stroke does."""
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_paint', None)
    if send is None or obj is None:
        return
    mode = getattr(obj, 'mode', None)
    data = values(obj, mode, depsgraph)
    if data is None:
        return
    send(obj.name, 'WEIGHT' if mode == 'WEIGHT_PAINT' else 'COLOR', data)


# --------------------------------------------------------------------------
# The stroke

_stroke = None


def _require(name):
    """The object a stroke on `name` would paint, everything a stroke needs
    checked, or a Refusal that says what is missing."""
    if not _is_real_blender():
        raise Refusal("Blender's paint brushes run in Blender, and the simulator's stand-in "
                      "for Blender does not have them.")
    mode = _mode()
    what = MODE_NAMES.get(mode, "Painting")
    if not _knife.on_main_thread():
        raise Refusal(what + " aims Blender's 3D View, which exists on the main thread only.")
    obj = _active()
    if obj is None:
        raise Refusal("Painting needs an object. Select a mesh first.")
    if obj.name != name:
        raise Refusal("Painting works on the active object, and " + name + " is not it.")
    if obj.type != 'MESH':
        raise Refusal("Painting works on meshes, and " + obj.name + " is not one.")
    if mode is None:
        raise Refusal(obj.name + " is not in Weight Paint or Vertex Paint.")
    if not obj.visible_get():
        raise Refusal(obj.name + " is hidden. Show it to paint it.")
    if not obj.data.polygons:
        raise Refusal(obj.name + " has no faces to paint.")
    brush = _brush(mode)
    if brush is None:
        raise Refusal("There is no " + what + " brush: Blender's Essentials brushes are not in this "
                      "build." if not essentials_path(mode) else
                      "There is no " + what + " brush. Pick one in the Brush menu.")
    if brush.stroke_method == 'CURVE':
        raise Refusal("The " + brush.name + " brush draws along a paint curve, which Blender edits "
                      "in a modal tool this app cannot run. Pick a Space or Dots stroke.")
    if mode == 'WEIGHT_PAINT':
        group = obj.vertex_groups.active
        if group is not None and group.lock_weight:
            # Blender's own words for it ("Active group is locked, aborting"),
            # which its exec path warns and then pushes a step anyway.
            raise Refusal("The active vertex group, " + group.name + ", is locked. Unlock it to "
                          "paint its weights.")
    _knife.require_gpu_context(what)
    _require_undo_stack(what)
    return obj, mode


def _require_undo_stack(what):
    """Blender's undo stack, which every chunk rewinds: made if there is none
    (`ed.undo_push`, which needs the main thread's window)."""
    steps = _undo.blender_steps()
    if steps:
        return
    context = bpy.context
    if context.window is None or context.screen is None:
        raise Refusal(what + " needs Blender's undo, which this thread has no window for.")
    if steps is None and bpy.ops.ed.undo.poll():
        return
    result = bpy.ops.ed.undo_push(message=what)
    if 'FINISHED' not in result:
        raise Refusal("Blender's undo could not be started, and a stroke needs it.")


def _operator(mode):
    return bpy.ops.paint.weight_paint if mode == 'WEIGHT_PAINT' else bpy.ops.paint.vertex_paint


def _ensure_brush_tool(mode, window, area, region):
    """The 3D View's brush tool, which the paint operators poll for: a file
    saved in a paint mode opens with no tool running in the borrowed area,
    as one saved in Sculpt Mode does (`_blenderkit_sculpt._ensure_brush_tool`)."""
    with bpy.context.temp_override(window=window, area=area, region=region):
        if _operator(mode).poll():
            return
        bpy.ops.wm.tool_set_by_id(name='builtin.brush', space_type='VIEW_3D')


def begin(name, camera, view, mode='NORMAL'):
    """Starts a stroke on `name` with the app's camera and 3D View size, as
    `_blenderkit_sculpt.begin` takes them. `mode`: NORMAL or INVERT (Blender's
    Ctrl). Returns the same shape as a sculpt stroke's begin."""
    global _stroke
    if mode not in ('NORMAL', 'INVERT'):
        raise Refusal("A paint stroke is NORMAL or INVERT, not " + repr(mode) + ".")
    # A stroke whose end never came: what it made stays as it is, and this
    # one counts from its mark, so one Undo takes both back.
    orphan = _stroke['mark'] if _stroke is not None else None
    _stroke = None
    obj, paint_mode = _require(name)
    brush = _brush(paint_mode)
    window, area, region = _knife.view3d(MODE_NAMES[paint_mode])
    space = area.spaces.active
    _ensure_brush_tool(paint_mode, window, area, region)
    with bpy.context.temp_override(window=window, area=area, region=region):
        mapped = _sculpt.aim(space, space.region_3d, region, camera, view)
        if not _operator(paint_mode).poll():
            raise Refusal("Blender's " + MODE_NAMES[paint_mode] + " brush cannot run on " + obj.name
                          + " here.")
    method = brush.stroke_method
    # A Line is spaced as a Space stroke is: Blender's line end adds a dab at
    # the start and spaces the rest to the end (`paint_stroke_line_end` calls
    # `paint_space_stroke`; RNA, 5.2.1: "Draw a line with dabs separated
    # according to spacing"). It used to send the two ends alone.
    spaced = method in ('SPACE', 'LINE')
    _stroke = dict(object=obj.name, mode=paint_mode, stroke_mode=mode, camera=dict(camera),
                   view=tuple(view), brush=brush.name, mapped=mapped, spaced=spaced,
                   strategy='line' if method == 'LINE' else 'replay',
                   last=None, open=[], first=None, current=None, rewindable=False,
                   waiting=False, replay_ms=0.0, replayed_at=0.0,
                   loads=getattr(_undo, '_loads', 0),
                   mark=orphan if orphan is not None else _undo.mark(), top=_undo.mark(),
                   pushed=0, chunks=0, total=0, segments=0, rewind_ms=0.0, timings=[], moved=False)
    return dict(strategy=_stroke['strategy'], brush=brush.name, scale=mapped[0],
                region=[mapped[1], mapped[2]])


def _elements(stroke, dabs):
    names = ('name', 'location', 'mouse', 'mouse_event', 'pressure', 'size', 'time', 'is_start',
             'x_tilt', 'y_tilt')
    known = {p.identifier for p in bpy.types.OperatorStrokeElement.bl_rna.properties}
    size = float(_owner(stroke['mode'], 'size').size)
    elements = []
    for i, (x, y, pressure, when) in enumerate(dabs):
        element = dict(name='', location=(0.0, 0.0, 0.0), mouse=(x, y), mouse_event=(x, y),
                       pressure=pressure, size=size, time=when, is_start=i == 0, x_tilt=0.0,
                       y_tilt=0.0)
        elements.append({k: v for k, v in element.items() if k in names and k in known})
    return elements


def _space(stroke, points):
    """The dabs Blender's modal stroke would add for `points`, continuing the
    stroke so far: spaced by the brush radius times its spacing over 50 for a
    Space or Line stroke (paint_space_stroke), one per point otherwise (Dots,
    Airbrush, whose timer adds a dab where the pen rests)."""
    dabs = []
    brush = _brush(stroke['mode'])
    radius = max(1.0, _owner(stroke['mode'], 'size').size / 2.0)
    for point in points:
        last = stroke['last']
        if last is None:
            dabs.append(point)
            stroke['last'] = point
            continue
        if not stroke['spaced']:
            if (point[0], point[1]) != (last[0], last[1]) or brush.stroke_method == 'AIRBRUSH':
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
            spacing = brush.spacing
            if getattr(brush, 'use_pressure_spacing', False):
                spacing = spacing * (1.5 - pressure)
            step = max(1.0, radius * spacing / 50.0)
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


def _on_surface(obj, region, rv3d, dabs):
    """Whether any of `dabs` is over the surface Blender paints: a stroke whose
    every dab is off it paints nothing, and Blender pushes an empty step for
    it all the same (measured), where its modal stroke never starts."""
    from bpy_extras import view3d_utils
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    inverse = obj.matrix_world.inverted()
    for dab in dabs:
        origin = view3d_utils.region_2d_to_origin_3d(region, rv3d, dab[:2])
        direction = view3d_utils.region_2d_to_vector_3d(region, rv3d, dab[:2])
        hit = evaluated.ray_cast(inverse @ origin, (inverse.to_3x3() @ direction).normalized())[0]
        if hit:
            return True
    return False


def _check_between_chunks(stroke):
    if not _knife.on_main_thread():
        raise Refusal("Painting aims Blender's 3D View, which exists on the main thread only.")
    obj = _active()
    if obj is None or obj.name != stroke['object'] or obj.mode != stroke['mode']:
        raise Refusal("The stroke's object left " + MODE_NAMES[stroke['mode']] + " part way through.")
    brush = _brush(stroke['mode'])
    if brush is None or brush.name != stroke['brush']:
        raise Refusal("The brush changed part way through the stroke.")
    if getattr(_undo, '_loads', 0) != stroke['loads']:
        raise Refusal("A file was loaded part way through the stroke.")
    top = stroke.get('top')
    now = _undo.mark()
    if top is not None and now is not None and now != top:
        stroke['moved'] = True
        stroke['rewindable'] = False
        raise Refusal("Blender's undo history moved part way through the stroke, so the stroke "
                      "ends here rather than take back a step that is not its own.")
    return obj


def _run(stroke, dabs):
    """One paint stroke, and whether it pushed Blender's undo step."""
    _undo.reserve(stroke['pushed'] + 2)
    before = _undo.mark()
    result = _operator(stroke['mode'])('EXEC_DEFAULT', True, stroke=_elements(stroke, dabs),
                                       mode=stroke['stroke_mode'], override_location=True)
    if 'FINISHED' not in result:
        return False
    if before is None:
        return True
    return _undo.mark() != before


def chunk(points):
    """Streams the stroke's next points to Blender and mirrors what it made.
    `points`: (x, y) or (x, y, pressure, seconds) in the app's 3D View
    points."""
    stroke = _stroke
    if stroke is None:
        raise Refusal("There is no stroke to continue.")
    started = time.perf_counter()
    obj = _check_between_chunks(stroke)
    window, area, region = _knife.view3d(MODE_NAMES[stroke['mode']])
    space = area.spaces.active
    rv3d = space.region_3d
    converted = []
    for point in points:
        x, y = _sculpt.to_region(point, stroke['mapped'])
        pressure = float(point[2]) if len(point) > 2 else 1.0
        when = float(point[3]) if len(point) > 3 else time.perf_counter()
        converted.append((x, y, pressure, when))
    result = dict(dabs=0, applied=False, strategy=stroke['strategy'], replayed=0)
    with bpy.context.temp_override(window=window, area=area, region=region):
        _sculpt.aim(space, rv3d, region, stroke['camera'], stroke['view'])
        if stroke['strategy'] == 'line':
            dabs = []
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
            stroke['open'].extend(new)
            if new:
                stroke['waiting'] = True
            dabs = _next_replay(stroke)
            if stroke['waiting'] and not dabs:
                # Not yet: the 3D View goes on showing Blender's last replay.
                result['held'] = True
        _replay(stroke, obj, region, rv3d, dabs, result)
    stroked = time.perf_counter()
    if result['applied']:
        stroke['chunks'] += 1
        # A memfile rewind replaced the Python objects of before it.
        push(bpy.data.objects[stroke['object']])
    stroke['top'] = _undo.mark()
    finished = time.perf_counter()
    if result['applied']:
        # The mirror is part of what a replay costs the main thread (`_due`).
        stroke['replay_ms'] += (finished - stroked) * 1000
        stroke['replayed_at'] = finished
    result['stroke_ms'] = round((stroked - started) * 1000, 2)
    result['mirror_ms'] = round((finished - stroked) * 1000, 2)
    stroke['timings'].append((result['dabs'], result['stroke_ms'], result['mirror_ms']))
    return result


def _next_replay(stroke):
    """The dabs to replay now, or [] to wait: the stroke so far when it is
    due (`_due`), and at once once it reaches MAX_STROKE_DABS, cut there. The
    throttle let the stroke grow past the cap while it waited, and the next
    replay took all of it: round 4's review found no check reaching the cap,
    and one that did (2,468 dabs at size 10) replayed all 2,468 as one stroke
    at its end, the cap counted as a cut that cut nothing."""
    if not stroke['waiting'] or not stroke['open']:
        return []
    if len(stroke['open']) >= MAX_STROKE_DABS:
        return stroke['open'][:MAX_STROKE_DABS]
    return list(stroke['open']) if _due(stroke) else []


def _due(stroke):
    """Whether the stroke so far is to be replayed now: always while a replay
    (its rewind, run and mirror) costs up to REPLAY_BUDGET_MS, else once
    REPLAY_DUTY times its cost has passed since the last one ended."""
    cost = stroke['replay_ms']
    if not stroke['rewindable'] or cost <= REPLAY_BUDGET_MS:
        return True
    return (time.perf_counter() - stroke['replayed_at']) * 1000.0 >= REPLAY_DUTY * cost


def _replay(stroke, obj, region, rv3d, dabs, result):
    """Takes back the stroke's last step and makes `dabs` as one of Blender's
    strokes, under the 3D View override the caller holds."""
    if dabs and not stroke['rewindable'] and not _on_surface(obj, region, rv3d, dabs):
        # Nothing under any dab yet: no step for nothing, tried again with
        # the next chunk's. A whole MAX_STROKE_DABS of them paints nothing
        # and is let go, rather than ray cast again with every chunk.
        if stroke['strategy'] == 'replay' and len(dabs) >= MAX_STROKE_DABS:
            stroke['open'] = stroke['open'][len(dabs):]
            stroke['waiting'] = bool(stroke['open'])
        dabs = []
    if not dabs:
        return
    rewound = False
    stroke['rewind_ms'] = 0.0
    if stroke['rewindable']:
        undone = time.perf_counter()
        if 'FINISHED' not in bpy.ops.ed.undo():
            raise Refusal("Blender's undo could not take the stroke back to replace it.")
        rewound = True
        stroke['rewind_ms'] = (time.perf_counter() - undone) * 1000
        result['undo_ms'] = round(stroke['rewind_ms'], 2)
        stroke['pushed'] -= 1
        stroke['rewindable'] = False
    ran = time.perf_counter()
    pushed = _run(stroke, dabs)
    ran = (time.perf_counter() - ran) * 1000
    result['run_ms'] = round(ran, 2)
    result['dabs'] = len(dabs)
    if pushed:
        stroke['pushed'] += 1
        stroke['rewindable'] = True
        result['applied'] = True
    elif rewound:
        # The replay pushed nothing, and the rewind took back what the 3D
        # View shows: put back, so Blender holds it again.
        if 'FINISHED' not in bpy.ops.ed.redo():
            raise Refusal("Blender's undo could not put the stroke's last step back.")
        stroke['pushed'] += 1
        stroke['rewindable'] = True
        result['kept'] = True
    if pushed or rewound:
        stroke['waiting'] = False
        stroke['replay_ms'] = ran + stroke['rewind_ms']
        stroke['replayed_at'] = time.perf_counter()
    if stroke['strategy'] == 'replay' and len(dabs) >= MAX_STROKE_DABS:
        # Kept as it is, and what came after the cap goes on as a new stroke
        # of Blender's, waiting for its first replay.
        rest = stroke['open'][len(dabs):]
        stroke['open'] = rest
        stroke['rewindable'] = False
        stroke['waiting'] = bool(rest)
        stroke['segments'] += 1
        result['cut'] = True


def _flush(stroke):
    """At the stroke's end, the dabs that came after its last replay, which
    the throttle held back (`_due`), replayed with the rest: the stroke kept
    is all of it, as one of Blender's strokes. None, or why it could not."""
    if stroke['strategy'] != 'replay' or not stroke['waiting'] or not stroke['open']:
        return None
    started = time.perf_counter()
    try:
        obj = _check_between_chunks(stroke)
        window, area, region = _knife.view3d(MODE_NAMES[stroke['mode']])
        space = area.spaces.active
        result = dict(dabs=0, applied=False)
        flushed = 0
        with bpy.context.temp_override(window=window, area=area, region=region):
            _sculpt.aim(space, space.region_3d, region, stroke['camera'], stroke['view'])
            # At most MAX_STROKE_DABS a replay, as while the finger moved.
            while stroke['waiting'] and stroke['open']:
                left = len(stroke['open'])
                result['dabs'] = 0
                _replay(stroke, obj, region, space.region_3d, stroke['open'][:MAX_STROKE_DABS], result)
                flushed += result['dabs']
                result.pop('cut', None)
                if len(stroke['open']) >= left:
                    break   # replayed whole, or nothing under it yet
    except Refusal as error:
        return str(error)
    stroked = time.perf_counter()
    if result['applied']:
        stroke['chunks'] += 1
        push(bpy.data.objects[stroke['object']])
    stroke['top'] = _undo.mark()
    stroke['timings'].append((result['dabs'], round((stroked - started) * 1000, 2),
                              round((time.perf_counter() - stroked) * 1000, 2)))
    stroke['flushed'] = flushed
    return None


def end(flush=True):
    """Ends the stroke: what the throttle held back is replayed with the rest
    (`_flush`), and the history records it as the steps it pushed, under
    Blender's own name for them ("Weight Paint", "Vertex Paint")."""
    global _stroke
    refused = _flush(_stroke) if flush and _stroke is not None else None
    stroke, _stroke = _stroke, None
    if stroke is None:
        return dict(pushed=0, counted=False, chunks=0, cuts=0, strategy='', dabs=0,
                    stroke_ms=[], mirror_ms=[])
    if stroke['mark'] is None:
        counted, pushed = False, stroke['pushed']
    else:
        counted = True
        pushed = _undo.pushed_since(stroke['mark'])
        if pushed is None:
            pushed = 0 if stroke['moved'] else stroke['pushed']
            counted = False
    _undo.note_pushed(pushed)
    timings = stroke['timings']
    report = dict(pushed=pushed, counted=counted, chunks=stroke['chunks'], cuts=stroke['segments'],
                  strategy=stroke['strategy'], dabs=stroke['total'],
                  stroke_ms=[t[1] for t in timings], mirror_ms=[t[2] for t in timings],
                  flushed=stroke.get('flushed', 0))
    if refused is not None:
        report['refused'] = refused
    if pushed:
        rows = _undo.blender_steps() or []
        active = next((row for row in rows if row[3]), None)
        if active is not None and active[2]:
            report['step'] = active[2]
    return report


def cancel():
    """Ends a stroke that failed part way, keeping what Blender holds of it
    (what the 3D View shows) and replaying nothing more."""
    return end(flush=False)
