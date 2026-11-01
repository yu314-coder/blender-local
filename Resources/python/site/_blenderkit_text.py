"""A text object's settings for the Data tab, and its body, written the way
Blender's own data holds them (round 4, group 8).

Blender types a text object's body in Edit Mode, in its 3D View. That edit
cannot be shown back here: measured in desktop 5.2.1 with the app's context,
`font.text_insert` works headless (in the window and screen, and under the
borrowed 3D View), but while Blender is in Edit Mode both `data.body` and the
evaluated object's `data.body` return the text from before Edit Mode
whatever was typed — the edit buffer is not in RNA (rna_curve.cc's body
setter says "TODO: how to handle editmode?") — and a body set during Edit
Mode is overwritten by the buffer on leaving ("SetInEdit" read back, "New"
after Object Mode). A field showing what was typed would show text Blender
cannot be asked for, and an Undo inside Edit Mode would leave it wrong.

So the body is written in Object Mode, to `data.body`, as the Every Property
browser writes it (measured: "Logo" set there, the evaluated mesh rebuilt),
and read back with every pass. Undo restores it (measured: "Text" after one
Undo, the new body after Redo).

Every setting that adds geometry is priced first (`vertices`), from what
Blender would lay out, before Blender builds it. Measured in desktop 5.2.1
with the default font, a text's vertices are its letters' outline points
times a number its Extrude, Bevel and Fill Mode decide:

  * Outline points. Blender lays each letter out as Bézier segments; a
    segment between two Vector handles is one point at any resolution, and
    every other one is Resolution Preview U points. So "I" is 4 points at
    Resolution U 1, 12 and 64, "O" 8, 96 and 512, "@" 26, 244 and 1,284, and
    "abcdefghij" 137, 1,050 and 5,366 — each exactly the segments of the
    text's own layout (`Object.to_curve`, which builds no mesh) counted this
    way, but for "@" and "U" at Resolution U 1 alone, where the fill adds 2
    where the coarse outline crosses itself (all of ASCII checked at 1, 2, 3
    and 6). Round 4's review found the estimate this replaces, which scaled
    the vertices the text has now by its number of letters, beaten by
    changing which letters were typed: 1,000 "O" after one "I" at Resolution
    U 64 and Bevel Resolution 32 priced at 276,000, against about 35 million.
  * Per point: 1 flat; with Extrude 2 (Fill Mode None), 3 (Front or Back)
    or 4 (Both); with a Bevel Depth — a negative one exactly as a positive
    one, which that estimate priced as flat — Bevel Resolution b gives
    2b + 4, b + 3 and 2b + 5 without Extrude and 4b + 6, b + 4 and 2b + 6
    with it, the same for every letter. A Bevel of type Profile or Object
    makes other numbers, so this one is not worked out here: Blender builds
    one letter at Resolution U 1 with the same settings, and its count is
    divided by its outline (measured equal to Blender's own evaluation for
    Round, Profile with a custom profile, and an Object bevel).
  * What the fill adds. A filled face — the flat text, or each of Extrude's
    and Bevel's caps — gets a vertex wherever an outline crosses itself,
    which Geometry ▸ Offset makes happen, and Resolution U 1 or 2 now and
    then: 'abcdefghij' at 12 gained 9 vertices at Offset 0.01 and 112 at 5;
    '*' at Resolution U 3 and Offset 10 is 238 against its outline's 66, and
    at 1024 it gained 604 on 18,444. Size, Shear, the spacings, the
    alignments and Offset X and Y add nothing (all measured). So with an
    Offset, each letter of the body is built once, flat, at the new
    settings, and what its fill added is counted for each time it occurs and
    each cap (`_fill_extra`). At
    Resolution U 64 and Bevel Resolution 32 with Extrude, 1,000
    "abcdefghij" characters are 37,562,000 vertices, which Blender built in
    5.6 s.

What Blender builds them on is made and removed inside the price: a copy of
the text's data with the change made, and an object for it outside the
scene, which Blender lays out (`to_curve`) or builds (`to_mesh`). Only an
Object bevel needs the scene: built outside it, Blender leaves the bevel
object out (4 vertices where it evaluates 192). Measured: laying out 8,000
"O" took 0.03 s and 7 MB.

A text with modifiers is priced through its whole stack as well
(`_blenderkit_budget`, from what Blender makes of the text
with the change: built only once the text alone is known to be within the
budget, so never more than the budget's worth).
"""

import math
from collections import Counter

import bpy

# Settings the Data tab shows, by Blender's property names
# (properties_data_curve.py: Shape, Geometry, Bevel, Transform, Alignment,
# Spacing).
FIELDS = ('size', 'shear', 'extrude', 'offset', 'bevel_depth', 'bevel_resolution', 'resolution_u',
          'fill_mode', 'align_x', 'align_y', 'space_character', 'space_word', 'space_line',
          'offset_x', 'offset_y')
# What is priced: every setting, through the budget's one entry point
# (`_blenderkit_budget.price`), which lays the change over the text's data and
# counts it again — the letters' outlines here, then the whole stack. Round 4's
# review found the list this replaces (Resolution U, Bevel Resolution, Extrude,
# Bevel Depth, Fill Mode) leaving out Offset (50 '*' at Resolution U 3 went from
# 3,300 to 11,900 vertices at Offset 10) and Size, which grows what a Remesh
# makes of the text (Size 1, 4 and 16: 510, 3,302 and 31,810 vertices, all
# counted 860).
# Blender's RNA length limit for `body` (`length_max`, measured 8192).
BODY_LIMIT = 8192
_PROBE = "Blender Local price"
# The most different letters `_fill_extra` builds one by one; past it (a
# body in a script with thousands of signs), the most measured per letter
# stands in: three times its outline at Resolution U 1, and 604 at 1024.
_EXTRA_LETTERS = 128
_EXTRA_PER_LETTER = 604
_EXTRA_PER_POINT = 3

_ESCAPES = (('%', '%25'), (';', '%3B'), ('=', '%3D'), ('\n', '%0A'), ('|', '%7C'))


def _escape(text):
    for raw, escaped in _ESCAPES:
        text = text.replace(raw, escaped)
    return text


def _value(value):
    if isinstance(value, bool):
        return '1' if value else '0'
    if isinstance(value, (int, float)):
        return repr(float(value))
    return str(value)


def record(obj):
    """`key=value;…` for the Data tab, the body percent-escaped. An empty
    body ends the record with `body=`, which is an empty body, not none
    (`ObjectDataSettings.parse`)."""
    data = obj.data
    values = [(key, getattr(data, key)) for key in FIELDS]
    values.append(('chars', len(data.body)))
    text = ';'.join(k + '=' + _value(v) for k, v in values)
    text += ';font=' + _escape(data.font.name if data.font is not None else '')
    return text + ';body=' + _escape(data.body)


def push(obj, during_pass=True):
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_points', None)
    if send is None or obj.type != 'FONT':
        return
    send(obj.name, record(obj), b'', b'', b'', 1 if during_pass else 0)


def _segments(curve):
    """(curved, straight): the segments of `curve`'s splines that Blender
    makes Resolution U points of, and the ones it makes one point of — a
    Bézier segment between two Vector handles, the end of an open spline,
    and each point of a poly spline (the `bezier_points` count in Blender's
    curve evaluation)."""
    curved = straight = 0
    for spline in curve.splines:
        if spline.type != 'BEZIER':
            straight += len(spline.points)
            continue
        points = spline.bezier_points
        n = len(points)
        spans = n if spline.use_cyclic_u else n - 1
        for i in range(spans):
            a, b = points[i], points[(i + 1) % n]
            if a.handle_right_type == 'VECTOR' and b.handle_left_type == 'VECTOR':
                straight += 1
            else:
                curved += 1
        if not spline.use_cyclic_u:
            straight += 1
    return curved, straight


def _layout(data):
    """(curved, straight) of the text `data` holds, as Blender lays it out:
    `Object.to_curve` on an object of its own outside the scene, which lays
    the letters out and builds no mesh."""
    probe = bpy.data.objects.new(_PROBE, data)
    try:
        curve = probe.to_curve(bpy.context.view_layer.depsgraph)
        try:
            return _segments(curve) if curve is not None else (0, 0)
        finally:
            probe.to_curve_clear()
    finally:
        bpy.data.objects.remove(probe)


def _per_point(data):
    """The vertices Blender makes per outline point of `data`'s text with its
    Extrude, Bevel and Fill Mode: one letter built at Resolution U 1, its
    count divided by its outline. "I" when the font has one, else the first
    of the body's letters it has; 0 when it has none of them."""
    body, resolution, offset = data.body, data.resolution_u, data.offset
    letters = ['I'] + list(dict.fromkeys(c for c in body if not c.isspace()))[:32]
    try:
        # No Offset here: what it adds is the fill's, counted apart.
        data.offset = 0.0
        for letter in letters:
            data.body = letter
            data.resolution_u = 1
            curved, straight = _layout(data)
            if curved + straight:
                return _budget().curve_counts(data)[0] / float(curved + straight)
        return 0.0
    finally:
        data.body, data.resolution_u, data.offset = body, resolution, offset


def _caps(data):
    """The filled faces of `data`'s text: one for a flat text with a fill,
    else one per side Fill Mode fills."""
    if data.fill_mode == 'NONE':
        return 0
    flat = data.extrude == 0 and data.bevel_depth == 0 and not (
        data.bevel_mode == 'OBJECT' and data.bevel_object is not None)
    if flat:
        return 1
    return 2 if data.fill_mode == 'BOTH' else 1


def _fill_extra(data):
    """The vertices Blender's fill adds to one cap of `data`'s text where its
    outlines cross themselves (see above): each different letter built
    flat at the same Resolution U and Offset, its count less its outline,
    times how often it occurs. None to add with no Offset at Resolution U 3
    or more, where none was measured."""
    resolution = max(1, int(data.resolution_u))
    if data.offset == 0 and resolution > 2:
        return 0
    letters = Counter(c for c in data.body if not c.isspace())
    if not letters:
        return 0
    if len(letters) > _EXTRA_LETTERS:
        curved, straight = _layout(data)
        return _EXTRA_PER_POINT * (curved * resolution + straight) + _EXTRA_PER_LETTER * sum(letters.values())
    if data.dimensions != '2D':
        # A text set to 3D through the Data API row is not filled.
        return 0
    saved = (data.body, data.extrude, data.bevel_depth, data.bevel_mode, data.fill_mode)
    try:
        data.extrude, data.bevel_depth, data.bevel_mode, data.fill_mode = 0.0, 0.0, 'ROUND', 'BOTH'
        extra = 0
        for letter, times in letters.items():
            data.body = letter
            curved, straight = _layout(data)
            outline = curved * resolution + straight
            if outline:
                extra += times * max(0, _budget().curve_counts(data)[0] - outline)
        return extra
    finally:
        data.body, data.extrude, data.bevel_depth, data.bevel_mode, data.fill_mode = saved


def _changed(obj, changes):
    """A copy of `obj`'s text data with `changes` made (Blender's property
    names, and `body`), which the caller removes."""
    data = obj.data.copy()
    try:
        for key, value in changes.items():
            if key == 'render_resolution_u':
                # What a render builds: its own resolution, or the viewport's
                # when it is 0.
                if int(value) > 0:
                    data.resolution_u = int(value)
                continue
            setattr(data, key, value)
    except Exception:
        bpy.data.curves.remove(data)
        raise
    return data


def _vertices(data):
    curved, straight = _layout(data)
    points = curved * max(1, int(data.resolution_u)) + straight
    if not points:
        return 0
    count = int(math.ceil(points * _per_point(data)))
    caps = _caps(data)
    return count + caps * _fill_extra(data) if caps else count


def vertices(obj, **changes):
    """The vertices Blender would make of the text `obj`, modifiers aside,
    with `changes` made, worked out without building them (see above)."""
    data = _changed(obj, changes)
    try:
        return _vertices(data)
    finally:
        bpy.data.curves.remove(data)


def base_counts(obj):
    """(vertices, edges, faces, corners) of what `obj`'s modifiers are given
    (`_blenderkit_budget.base_counts`)."""
    return _budget().base_counts(obj)


def _budget():
    import sys
    module = sys.modules.get('_blenderkit_budget')
    if module is None:
        import importlib.util
        import os
        spec = importlib.util.spec_from_file_location(
            '_blenderkit_budget', os.path.join(os.path.dirname(__file__), '_blenderkit_budget.py'))
        module = importlib.util.module_from_spec(spec)
        sys.modules['_blenderkit_budget'] = module
        spec.loader.exec_module(module)
    return module


def _text(name):
    obj = bpy.data.objects.get(name)
    if obj is None or obj.type != 'FONT':
        raise RuntimeError("%r is not a text object." % (name,))
    if obj.mode == 'EDIT':
        raise RuntimeError(
            "%s is in Blender's Edit Mode, which keeps its own copy of the text and writes it "
            "back on leaving, over this. Leave Edit Mode first." % obj.name)
    return obj


def _instead(obj):
    if any(m.show_viewport for m in obj.modifiers):
        return "Use less text, lower the resolutions or what its modifiers make."
    return "Use less text or lower the resolutions."


def _price(obj, what, **changes):
    """Refuses, in words, `changes` to the text `obj` whose vertices — the
    text's, then its whole stack's — would pass the budget or the memory
    left: the budget's one price (`_blenderkit_budget.price_all`)."""
    _budget().price_all([(obj.data, key, value) for key, value in changes.items()], what, _instead(obj))


def set_body(name, body):
    obj = _text(name)
    body = str(body)
    if len(body.encode('utf-8')) > BODY_LIMIT:
        raise RuntimeError("Blender holds at most %d bytes of text in a text object's body, and "
                           "this is %d." % (BODY_LIMIT, len(body.encode('utf-8'))))
    if body == obj.data.body:
        return body
    _price(obj, "That text", body=body)
    obj.data.body = body
    return obj.data.body


# What each priced setting is called in a refusal: the Data tab's words.
# The curve Data tab's rows share them (_blenderkit_budget._label).
_LABELS = {'resolution_u': 'Resolution Preview U %d', 'bevel_resolution': 'Bevel Resolution %d',
           'extrude': 'Extrude %g', 'bevel_depth': 'Bevel Depth %g', 'fill_mode': 'Fill Mode %s',
           'render_resolution_u': 'Render U %d', 'bevel_mode': 'Bevel %s', 'body': 'That text',
           'bevel_object': 'That Bevel Object', 'size': 'Size %g', 'offset': 'Offset %g',
           'shear': 'Shear %g', 'space_character': 'Character Spacing %g',
           'space_word': 'Word Spacing %g', 'space_line': 'Line Spacing %g',
           'offset_x': 'Offset X %g', 'offset_y': 'Offset Y %g', 'align_x': 'Horizontal %s',
           'align_y': 'Vertical %s', 'resolution_v': 'Resolution Preview V %d',
           'render_resolution_v': 'Render V %d'}


def _label(key, value):
    label = _LABELS[key]
    if '%' not in label:
        return label
    if isinstance(value, str):
        value = value.replace('_', ' ').title()
    try:
        return label % value
    except TypeError:
        return label.split(' %')[0] + ' ' + str(value)


def set_setting(name, key, value):
    obj = _text(name)
    if key not in FIELDS:
        raise RuntimeError("The Data tab has no text setting %r" % (key,))
    # Every row, not a list of them: Size and Offset were off the list.
    _price(obj, _label(key, value) if key in _LABELS else None, **{key: value})
    setattr(obj.data, key, value)
    return getattr(obj.data, key)


def price_data(curve, key, value):
    """The Data API row's price for setting `key` of the text data `curve`
    to `value`: the budget's (`_blenderkit_budget.price`), which
    `_blenderkit_sync.set_property` calls for any struct now."""
    _budget().price(curve, key, value)
