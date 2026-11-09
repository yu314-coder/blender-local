"""The Timeline's keys and markers, edited as Blender's Dope Sheet edits them.

Blender's own operators do the editing — `action.*`, `marker.*` and
`transform.transform` in its time modes — under the Timeline of the startup
screen, which the bpy module keeps as desktop Blender does. Measured in the
app's bpy (5.3) on this Mac, 2026-11-09: the Layout screen holds a Dope Sheet
in Timeline mode, and under it `action.select_all`, `action.delete`,
`marker.add` and `transform.transform` all poll True; desktop 5.2.1 run
headless the same (tests/timeline/blender/verify.py). Its filter is
Blender's: the Timeline's channels, Only Show Selected, hidden objects left
out, Grease Pencil layers too.

What Blender does by pointer position — a click on a column, a box drag, a
click on a marker — is done here by frame, over the channels the Timeline
lists (`timeline_channels`), with Blender's own rules (action_select.cc,
keyframes_edit.cc, anim_markers.cc): a click replaces the selection with the
column and clears the channels' selection, Shift toggles each key, a click on
nothing deselects, a box sets, extends or subtracts.

A selection runs without the mirroring pass (`BpyBridge.runWithoutMirror`), so
each one ends by telling the timeline what Blender now holds (`report`), and
says when it changed nothing (UNCHANGED), which then records no undo step.
An edit goes through the mirroring pass, which reports.

The same calls in the simulator's stand-in, which has no Timeline and no
operators, refuse in words.
"""

import bpy
import _blenderkit

import _blenderkit_anim as anim

# Printed by a selection that left everything as it was.
UNCHANGED = 'BK_KEYS_UNCHANGED'


def _is_main_thread():
    try:
        import _blenderkit_context
        return _blenderkit_context._is_main_thread()
    except (ImportError, AttributeError):
        import threading
        return threading.current_thread() is threading.main_thread()


def _real():
    try:
        return hasattr(bpy.ops.action.select_all, 'get_rna_type')
    except AttributeError:
        return False


class temp_override_timeline:
    """The startup screen's Timeline, for an operator whose poll asks for a
    Dope Sheet (`ED_operator_action_active`). A Timeline-mode area first, any
    Dope Sheet after. Refused in words off the main thread, the only one
    Blender gives a window and its areas out on, and where the screen has
    none to borrow."""

    def __init__(self, what):
        self.what = what
        self._override = None

    @staticmethod
    def find():
        found = None
        for window in bpy.context.window_manager.windows:
            screen = window.screen
            if screen is None:
                continue
            for area in screen.areas:
                if area.type != 'DOPESHEET_EDITOR':
                    continue
                region = next((r for r in area.regions if r.type == 'WINDOW'), None)
                if region is None:
                    continue
                if area.ui_type == 'TIMELINE':
                    return window, area, region
                found = found or (window, area, region)
        return found

    def __enter__(self):
        if not _real():
            raise RuntimeError(self.what + " needs Blender's Timeline, which the stand-in has not")
        if not _is_main_thread():
            raise RuntimeError(self.what + " works through Blender's Timeline, which exists on the "
                               "main thread only")
        found = self.find()
        if found is None:
            raise RuntimeError(self.what + " works through Blender's Timeline, and Blender's "
                               "screen has none to borrow")
        window, area, region = found
        self._override = bpy.context.temp_override(window=window, area=area, region=region)
        self._override.__enter__()
        return self

    def __exit__(self, *exc):
        if self._override is not None:
            return self._override.__exit__(*exc)
        return False


def _words(error):
    """An operator's failure as Blender says it: the poll's message without
    the call in front of it, a report without its "Error: "."""
    text = str(error).strip()
    if '.poll() ' in text:
        text = text.split('.poll() ', 1)[1]
    if text.startswith('Error: '):
        text = text[len('Error: '):]
    return text.strip()


def _op(what, call, refusal=None, **arguments):
    """One of Blender's operators under the Timeline. CANCELLED, which
    Blender answers silently, is refused in words when `refusal` says what
    went wrong, so no undo step is recorded for nothing."""
    with temp_override_timeline(what):
        try:
            result = call(**arguments)
        except RuntimeError as error:
            raise RuntimeError(_words(error)) from None
    if 'CANCELLED' in result and refusal:
        raise RuntimeError(refusal)
    return result


def report():
    """The timeline told what Blender holds now: the keys and the markers."""
    if hasattr(_blenderkit, 'anim_keys'):
        anim.report_keys()
        anim.report_markers()


def _ops(module):
    return getattr(bpy.ops, module)


# ---------------------------------------------------------------------------
# The Timeline's channels
# ---------------------------------------------------------------------------

def timeline_objects(scene=None, view_layer=None):
    """The objects whose keys the Timeline lists: the view layer's, visible
    (`_blenderkit_anim.in_timeline`), and selected while Only Show Selected
    is on (`scene.show_keys_from_selected_only`, ADS_FILTER_ONLYSEL)."""
    scene = scene or bpy.context.scene
    view_layer = view_layer or bpy.context.view_layer
    only = scene.show_keys_from_selected_only
    for obj in view_layer.objects:
        if obj is None or not anim.in_timeline(obj):
            continue
        if only and not obj.select_get():
            continue
        yield obj


def timeline_channels(scene=None):
    """Every channel the Timeline's summary is made of: the scene's own (its
    world and compositor), then each listed object's — the object, its data,
    shape keys and materials — each once."""
    scene = scene or bpy.context.scene
    ids, known = [], set()

    def add(idblock):
        key = idblock.as_pointer()
        if key not in known:
            known.add(key)
            ids.append(idblock)

    for idblock in anim.scene_ids(scene):
        add(idblock)
    for obj in timeline_objects(scene):
        for idblock in anim.animated_ids(obj):
            add(idblock)
    out, seen = [], set()
    for idblock in ids:
        for channel in anim.channels_of(idblock):
            if channel.key not in seen:
                seen.add(channel.key)
                out.append(channel)
    return out


def _apply(channels, wanted, before, clear_channels=False):
    changed = False
    for channel, new, old in zip(channels, wanted, before):
        if clear_channels:
            channel.deselect_channel()
        if new != old:
            channel.select(new)
            changed = True
    return changed


def _finish(changed):
    report()
    if not changed:
        print(UNCHANGED)


# ---------------------------------------------------------------------------
# Selecting keys
# ---------------------------------------------------------------------------

def click_select(frame, extend=False, deselect_all=True):
    """A click on the summary at `frame` (`action.clickselect`): the column's
    keys replace the selection, and the channels are deselected
    (`mouse_action_keys`); with `extend` (Shift) each key there is toggled
    (`select_bezier_invert`); on nothing, with `deselect_all`, everything is
    deselected. A key is in the column within Blender's threshold."""
    channels = timeline_channels()
    before = [channel.selection() for channel in channels]
    hits = [[abs(f - frame) <= anim.THRESHOLD for f in channel.frames()] for channel in channels]
    found = any(any(row) for row in hits)
    wanted = [list(row) for row in before]
    clear = False
    if (not extend and found) or (not found and deselect_all):
        wanted = [[False] * len(row) for row in before]
        clear = True
    if found:
        for row, hit in zip(wanted, hits):
            for i, h in enumerate(hit):
                if h:
                    row[i] = (not row[i]) if extend else True
    _finish(_apply(channels, wanted, before, clear_channels=clear))


def box_select(first, last, mode='SET'):
    """A box over the summary from `first` to `last` (`action.select_box`):
    SET deselects everything first, ADD extends (Shift), SUB subtracts
    (Ctrl). A key is inside when its frame is (BEZT_OK_FRAMERANGE)."""
    lo, hi = min(first, last), max(first, last)
    channels = timeline_channels()
    before = [channel.selection() for channel in channels]
    wanted = []
    for channel, old in zip(channels, before):
        inside = [lo <= f <= hi for f in channel.frames()]
        if mode == 'SUB':
            wanted.append([o and not i for o, i in zip(old, inside)])
        elif mode == 'ADD':
            wanted.append([o or i for o, i in zip(old, inside)])
        else:
            wanted.append(inside)
    _finish(_apply(channels, wanted, before))


def _selection_signature():
    return [channel.selection() for channel in timeline_channels()]


def _select_op(what, operator, **arguments):
    if not _real():
        raise RuntimeError(what + " needs Blender's Timeline, which the stand-in has not")
    before = _selection_signature()
    _op(what, getattr(bpy.ops.action, operator), **arguments)
    _finish(_selection_signature() != before)


def select_all(action):
    """Select ▸ All, None, Invert (A, Alt+A, Ctrl+I): `action.select_all`."""
    _select_op('Select All', 'select_all', action=action)


def select_column(mode):
    """Select ▸ Columns on Selected Keys (K), Column on Current Frame (Ctrl+K),
    Columns on Selected Markers (Shift+K), Between Selected Markers (Alt+K)."""
    _select_op('Select All', 'select_column', mode=mode)


def select_leftright(mode, extend=False):
    """Select ▸ Before and After Current Frame ([ and ]), and Ctrl+click's
    side of the current frame."""
    _select_op('Select Left/Right', 'select_leftright', mode=mode, extend=bool(extend))


def select_linked():
    """Select ▸ Select Linked (L): every key of a channel with one selected."""
    _select_op('Select Linked', 'select_linked')


def select_more():
    _select_op('Select More', 'select_more')


def select_less():
    _select_op('Select Less', 'select_less')


# ---------------------------------------------------------------------------
# Editing keys — each through the mirroring pass, which reports
# ---------------------------------------------------------------------------

NOTHING_SELECTED = "No keyframes are selected"


class _snap_anim:
    """Snap for keys as `snap` says for one call, then as it was. Blender's
    transform snaps a value it is given by the scene's Snap even with
    `snap=False` (measured in 5.2.1: a move by 2.4 moved keys 2), so a drag
    with Ctrl held — Blender's Snap Invert — has Snap turned round for the
    call itself."""

    def __init__(self, snap):
        self.snap = snap
        self.was = None

    def __enter__(self):
        if self.snap is not None:
            tool = bpy.context.scene.tool_settings
            self.was = tool.use_snap_anim
            tool.use_snap_anim = bool(self.snap)
        return self

    def __exit__(self, *exc):
        if self.was is not None:
            bpy.context.scene.tool_settings.use_snap_anim = self.was
        return False


def move(delta, snap=None):
    """G and a drag of the selected keys: `transform.transform` in
    TIME_TRANSLATE by `delta` frames. Blender snaps it as the scene's Snap
    says (Frame by default: the move by whole frames; with Absolute Time Snap
    each key onto a whole frame) — the other way round with `snap` given —
    merges keys that land on others (Auto-Merge Keyframes) and puts the
    handles right."""
    with _snap_anim(snap):
        _op('Move', bpy.ops.transform.transform, refusal=NOTHING_SELECTED,
            mode='TIME_TRANSLATE', value=(float(delta), 0.0, 0.0, 0.0))


def scale(factor, snap=None):
    """S: TIME_SCALE about the current frame."""
    with _snap_anim(snap):
        _op('Scale', bpy.ops.transform.transform, refusal=NOTHING_SELECTED,
            mode='TIME_SCALE', value=(float(factor), 0.0, 0.0, 0.0))


def duplicate_move(delta, snap=None):
    """Shift+D: `action.duplicate_move`, Blender's macro — the copies made
    and selected, then moved by `delta`; at 0 (cancelled) they stay on the
    originals, which they then replace."""
    with _snap_anim(snap):
        _op('Duplicate', bpy.ops.action.duplicate_move, refusal=NOTHING_SELECTED,
            TRANSFORM_OT_transform={'mode': 'TIME_TRANSLATE', 'value': (float(delta), 0.0, 0.0, 0.0),
                                    'use_duplicated_keyframes': True, 'use_proportional_edit': False})


def delete():
    """Delete Keyframes (X's menu, Delete): `action.delete` without its
    confirmation, which the interface asks itself."""
    _op('Delete Keyframes', bpy.ops.action.delete, refusal=NOTHING_SELECTED, confirm=False)


def clean(channels=False):
    """Clean Keyframes, Clean Channels: `action.clean` at its threshold."""
    _op('Clean Keyframes', bpy.ops.action.clean, channels=bool(channels))


def copy():
    """Ctrl+C: `action.copy`, into Blender's own clipboard."""
    _op('Copy Keyframes', bpy.ops.action.copy)


def paste(offset='START', merge='MIX', flipped=False):
    """Ctrl+V and Shift+Ctrl+V: `action.paste` at its defaults — the first
    copied key on the current frame (Frame Start), mixed into what is there."""
    _op('Paste Keyframes', bpy.ops.action.paste, offset=offset, merge=merge, flipped=bool(flipped))


def snap(kind):
    """Shift+S and Key ▸ Snap: `action.snap`."""
    _op('Snap Keys', bpy.ops.action.snap, type=kind)


def mirror(kind):
    """Ctrl+M and Key ▸ Mirror: `action.mirror`."""
    _op('Mirror Keys', bpy.ops.action.mirror, type=kind)


def frame_jump():
    """Ctrl+G, Key ▸ Jump to Selected: `action.frame_jump`, the current frame
    to the selected keys' average."""
    _op('Jump to Keyframes', bpy.ops.action.frame_jump)


def interpolation(kind):
    """T: `action.interpolation_type`."""
    _op('Set Keyframe Interpolation', bpy.ops.action.interpolation_type, type=kind)


def easing(kind):
    """Ctrl+E: `action.easing_type`."""
    _op('Set Keyframe Easing Type', bpy.ops.action.easing_type, type=kind)


def keyframe_type(kind):
    """R: `action.keyframe_type`."""
    _op('Set Keyframe Type', bpy.ops.action.keyframe_type, type=kind)


def handle_type(kind):
    """V: `action.handle_type`."""
    _op('Set Keyframe Handle Type', bpy.ops.action.handle_type, type=kind)


def insert(kind='ALL'):
    """I over the Timeline: `action.keyframe_insert` — a key on every listed
    channel (All Channels), or the selected ones'."""
    _op('Insert Keyframes', bpy.ops.action.keyframe_insert, type=kind)


def snap_state():
    """What a drag previews by: Snap, its element and Absolute Time Snap,
    and the scene's rate — one line, for the interface."""
    scene = bpy.context.scene
    tool = scene.tool_settings
    render = scene.render
    elements = tool.snap_anim_element
    element = elements if isinstance(elements, str) else ','.join(sorted(elements))
    print('BK_KEYS_SNAP %d %s %d %r' % (int(tool.use_snap_anim), element,
                                         int(getattr(tool, 'use_snap_time_absolute', False)),
                                         render.fps / render.fps_base))


# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------

LOCKED = "Markers are locked"


def _markers():
    return bpy.context.scene.timeline_markers


def _refuse_locked():
    if bpy.context.scene.tool_settings.lock_markers:
        raise RuntimeError(LOCKED)


def marker_select(index, extend=False):
    """A click on a marker (`marker.select`): it alone selected, or with
    Shift toggled; `index` is its place in the scene's list, -1 for a click
    on none of them, which deselects them all (deselect_all)."""
    markers = _markers()
    before = [m.select for m in markers]
    if 0 <= index < len(markers):
        if extend:
            markers[index].select = not markers[index].select
        else:
            for i, marker in enumerate(markers):
                marker.select = i == index
    elif not extend:
        for marker in markers:
            marker.select = False
    _finish([m.select for m in markers] != before)


def marker_select_all(action):
    before = [m.select for m in _markers()]
    _op('(De)select all Markers', bpy.ops.marker.select_all, action=action)
    _finish([m.select for m in _markers()] != before)


def marker_select_leftright(mode, extend=False):
    before = [m.select for m in _markers()]
    _op('Select Markers Before/After Current Frame', bpy.ops.marker.select_leftright,
        mode=mode, extend=bool(extend))
    _finish([m.select for m in _markers()] != before)


def marker_add():
    """M: `marker.add` on the current frame, the new marker alone selected.
    Nothing the 3D View draws changes, so the interface skips the mirroring
    pass and this reports the markers itself."""
    _op('Add Time Marker', bpy.ops.marker.add)
    report()


def marker_rename(name):
    """F2's Rename Marker: the first selected marker named (`marker.rename`,
    as TOPBAR_PT_name_marker picks it)."""
    _refuse_locked()
    if not any(m.select for m in _markers()):
        raise RuntimeError("No active marker")
    _op('Rename Marker', bpy.ops.marker.rename, name=name)
    report()


def marker_move(frames):
    """G over the markers and a drag of one: `marker.move` by whole frames."""
    _op('Move Time Marker', bpy.ops.marker.move, frames=int(frames))


def marker_duplicate(frames):
    """Shift+D over the markers: `marker.duplicate`, the copies moved."""
    _op('Duplicate Time Marker', bpy.ops.marker.duplicate, frames=int(frames))


def marker_delete():
    """Delete Marker (X over the markers, Delete): `marker.delete`."""
    _op('Delete Markers', bpy.ops.marker.delete, confirm=False)


def marker_camera_bind():
    """Ctrl+B: `marker.camera_bind`, the active camera bound to a marker on
    the current frame."""
    _op('Bind Camera to Markers', bpy.ops.marker.camera_bind)


def set_lock_markers(on):
    """Marker ▸ Lock Markers (`tool_settings.lock_markers`)."""
    bpy.context.scene.tool_settings.lock_markers = bool(on)
    report()
