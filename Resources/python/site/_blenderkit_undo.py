"""Undo and redo with the real Blender module.

Every undoable action used to save the whole scene as a .blend and every undo
loaded one back. This keeps steps in Blender's own undo system instead — the
memfile undo that shares unchanged data between steps, and edit-mesh undo in
edit mode — which is what Blender's Edit > Undo uses, and costs a fraction of a
millisecond to push and a few to step.

The bpy module runs headless, and Blender switches undo off there: nothing
creates the undo stack at startup, and the undo operators want a window and a
screen in the context. `ed.undo_push()` creates the stack in background mode
(ed_undo.cc), and `_context` supplies a window and screen. Whether that is
enough on this build is not assumed: `probe` pushes, undoes and redoes a
throw-away datablock before the first step, and when that fails anywhere the
history falls back to .blend checkpoints, as before. A later failure falls back
the same way, keeping the scene as it is and giving up only the steps that
cannot be reached without Blender's stack.

A step is reachable in one of two ways: through Blender's stack, while that
stack still holds it (its `segment` is the live one), or through its `file`.
Loading a file frees Blender's stack, so a load — File > New, Open, a script's
`read_factory_settings` — ends the segment. The scene being replaced is saved
first, by a load_pre handler, so the step before the load can still be
returned to.

What memfile undo does not restore is put right here too: an image's pixels
live in a buffer cache that survives an undo, so an image painted since the
step being returned to is reloaded from its packed data.
"""
import contextlib
import os
import sys
import time
import uuid

import bpy

# Blender's own default for Preferences > Editing > Undo Steps.
STEPS = 32
# Blender's undo memory limit, in megabytes. Zero is Blender's default and
# means no limit; on a tablet sharing memory with a 400 MB Blender there is one.
MEMORY_MB = 512
# The fallback's budget for checkpoint files on disk.
FILE_BYTES = 512 * 1024 * 1024

_started = time.time()
_root = None
# 'blender' or 'checkpoint'; None until the probe has run.
_mode = None
_why = ''
_forced = False

_steps = []
_index = -1
# The Blender undo stack the live steps are in; 0 when there is none.
_segment = 0
_segments = 0
# File loads the load_post handler has counted, and the count when the live
# segment began. A difference means a load freed Blender's stack.
_loads = 0
_segment_loads = 0
# The scene a load replaced, written by the load_pre handler.
_capture = None
# Nonzero while this module loads a file itself.
_loading = 0
# Set by `rewind`: the step on top was undone to be replaced.
_rewound = False

# For each image: the stroke last written into it, as a serial, and the
# stroke whose pixels its buffer holds now.
_written = {}
_buffers = {}
_serial = 0

_timing = {}


# --------------------------------------------------------------------------
# Context

def _context():
    """Refuse, rather than fake, a context the undo operators would reject.

    `ED_OT_undo_push` polls `ED_operator_screenactive` — a window and a screen
    in the context — and undo and redo add that the stack exists. In the bpy
    module on an iPad the main thread's context has both, and the script
    thread's has neither (measured on the arm64 module, 5.2.1). A
    `temp_override(window=…, screen=…)` there does not put them in, and on
    leaving it writes the window it found — none — back into the context the
    main thread shares: the next main-thread call then had no screen members
    at all, not even `objects_in_mode`. So nothing here overrides the context;
    off the main thread the call fails and the history uses a checkpoint.
    Never pass None for a window either: Blender 5.2.1 crashes in
    `temp_override` given one.
    """
    context = bpy.context
    if context.window is None or context.screen is None:
        raise RuntimeError("this thread's context has no window and screen for "
                           "Blender's undo operators")
    return contextlib.nullcontext()


def _operator(name, **arguments):
    with _context():
        result = getattr(bpy.ops.ed, name)(**arguments)
    if 'FINISHED' not in result:
        raise RuntimeError('bpy.ops.ed.' + name + ' returned ' + repr(result))


def _poll(name):
    try:
        with _context():
            return getattr(bpy.ops.ed, name).poll()
    except RuntimeError:
        return False


# --------------------------------------------------------------------------
# Setup

def configure(root, force_checkpoints=False):
    """Where checkpoint files go, and whether Blender's undo may be used."""
    global _root, _forced
    _forced = bool(force_checkpoints)
    if _root != root:
        _root = root
        os.makedirs(root, exist_ok=True)
        # Checkpoints from an earlier run of the app: nothing refers to them.
        for name in os.listdir(root):
            path = os.path.join(root, name)
            if name.endswith('.blend') and os.path.getmtime(path) < _started:
                try:
                    os.remove(path)
                except OSError:
                    pass
    _install_handlers()


def _install_handlers():
    handlers = bpy.app.handlers
    for collection, function in ((handlers.load_pre, _bk_undo_load_pre),
                                 (handlers.load_post, _bk_undo_load_post)):
        # By name, so a second copy of this module — a test loads its own —
        # replaces the first rather than running beside it.
        for existing in list(collection):
            if getattr(existing, '__name__', '') == function.__name__:
                collection.remove(existing)
        collection.append(function)


@bpy.app.handlers.persistent
def _bk_undo_load_pre(*_):
    """Save the scene a load is about to replace, when only Blender's stack
    holds the step it is at."""
    global _capture
    if _loading or _mode != 'blender' or not (0 <= _index < len(_steps)):
        return
    here = _steps[_index]
    if here['file'] or not _segment or here['segment'] != _segment:
        return
    try:
        _capture = _save()
    except Exception as error:
        _capture = None
        print(f"[Blender Local] Undo could not keep the scene a load replaced: {error}")


@bpy.app.handlers.persistent
def _bk_undo_load_post(*_):
    global _loads
    _loads += 1


def _live_depth():
    """How many of Blender's undo steps the live segment's steps span."""
    return sum(step['depth'] for step in _steps if _live(step))


def _prefs(extra=0):
    """Blender's undo limits, with room for the steps the history holds.

    `undo_steps` counts Blender's steps, and one step of the history can be
    many of Blender's: a sculpt stroke is one per chunk streamed to Blender
    (`_blenderkit_sculpt`). Blender drops its oldest steps past the limit when
    a step is pushed (measured in 5.2.1: 40 one-chunk strokes under the
    default 32 left 34 steps), and a history step whose first chunks were
    dropped could only be half undone. So the limit is Blender's default, or
    what the live steps and `extra` more need, whichever is larger.
    """
    edit = bpy.context.preferences.edit
    wanted = max(STEPS, _live_depth() + extra + 2)
    if edit.undo_steps < wanted or (edit.undo_steps > wanted and extra == 0):
        edit.undo_steps = wanted
    if edit.undo_memory_limit != MEMORY_MB:
        edit.undo_memory_limit = MEMORY_MB


def reserve(extra):
    """Room on Blender's stack for `extra` more steps before the next push:
    what a stroke streamed in chunks asks for before each chunk."""
    _prefs(extra)


# --------------------------------------------------------------------------
# Blender's own stack, read
#
# Some actions push steps of their own: every chunk of a sculpt stroke is a
# brush_stroke that pushes one, and the sculpt operators the header runs
# (`dynamic_topology_toggle`, `mask_flood_fill`, ...) push one without being
# asked (measured in 5.2.1 with WindowManager.print_undo_steps). A history
# step for such an action has to be exactly as many of Blender's deep, or an
# Undo stops part way through it. Blender offers no count to Python; the one
# thing that shows the stack is `print_undo_steps`, which writes it with
# printf, so it is read from file descriptor 1 around the call.

# The steps an action just pushed, for the next `push` to take:
# (count, the address of Blender's active step once they were pushed).
_noted = None


def blender_steps():
    """Blender's undo stack as a list of (address, type, name, active, skip),
    oldest first; [] when Blender has no stack yet; None when it cannot be
    read here (no ctypes, or not the real Blender)."""
    import tempfile
    wm = getattr(bpy.context, 'window_manager', None)
    if wm is None or not hasattr(wm, 'print_undo_steps'):
        return None
    try:
        import ctypes
        flush = ctypes.CDLL(None).fflush
    except (ImportError, OSError, AttributeError):
        return None
    handle, path = tempfile.mkstemp(prefix='bk-undo-steps-')
    saved = os.dup(1)
    try:
        flush(None)
        os.dup2(handle, 1)
        try:
            wm.print_undo_steps()
            flush(None)
        finally:
            os.dup2(saved, 1)
    finally:
        os.close(saved)
        os.close(handle)
    try:
        with open(path, errors='replace') as f:
            text = f.read()
    finally:
        os.remove(path)
    if 'No undo steps recorded yet' in text:
        return []
    rows = None
    for line in text.splitlines():
        if line.startswith('Undo ') and ' Steps ' in line:
            rows = []
            continue
        if rows is None or len(line) < 8 or line[0] != '[' or line[5] != ']':
            continue
        try:
            address = line[line.index('{') + 1:line.index('}')]
            kind = line.split("type='", 1)[1].split("'", 1)[0]
            name = line.split("name='", 1)[1].rsplit("'", 1)[0]
        except (ValueError, IndexError):
            continue
        rows.append((address, kind, name, line[1] == '*', line[4] == 'S'))
    return rows


def mark():
    """The address of Blender's active undo step, or None when it cannot be
    read: what `pushed_since` counts from."""
    rows = blender_steps()
    if not rows:
        return None
    return next((row[0] for row in rows if row[3]), None)


def pushed_since(address):
    """How many undoable steps Blender pushed after the step at `address`, up
    to its active step — the number of `ed.undo` calls that take it back
    there. A step Blender marks as skipped is crossed by the undo before it,
    so it is not counted. None when that cannot be told."""
    rows = blender_steps()
    if not rows or address is None:
        return None
    addresses = [row[0] for row in rows]
    if address not in addresses:
        return None
    start = addresses.index(address)
    active = next((i for i, row in enumerate(rows) if row[3]), None)
    if active is None or active < start:
        return None
    return sum(1 for row in rows[start + 1:active + 1] if not row[4])


def note_pushed(count, own=False):
    """The action that just ran pushed `count` of Blender's undo steps itself.

    The next `push` records a step that deep, so one Undo takes back the whole
    action. With `own` it also pushes its own step on top, for an action that
    changed more after the steps it pushed (one that left and re-entered a
    mode part way); without, the pushed steps are the action and it pushes
    none. Taken only if nothing has been pushed since (the active step is
    still the one the action left).
    """
    global _noted
    _noted = (int(count), mark(), bool(own)) if count and count > 0 else None


def _take_noted():
    """(steps the action pushed, whether the history pushes its own too)."""
    global _noted
    noted, _noted = _noted, None
    if noted is None:
        return 0, True
    count, after, own = noted
    if after is not None and mark() != after:
        return 0, True
    return count, own


def probe():
    """Find out whether Blender's undo works here, and settle the mode.

    A throw-away Text datablock is pushed, undone, redone and undone again —
    the stack is left where it started, and the Text gone. Deferred while any
    object is in a mode other than object mode: a push there is an edit-mode
    step, which does not carry a Text, and the probe would fail for the wrong
    reason. Returns the mode, or None when deferred.
    """
    global _mode, _why, _segment
    if _mode is not None:
        return _mode
    if _forced:
        _mode, _why = 'checkpoint', 'checkpoints were asked for'
        return _mode
    if any(getattr(obj, 'mode', 'OBJECT') != 'OBJECT' for obj in bpy.data.objects):
        return None
    started = time.perf_counter()
    name = None
    try:
        _prefs()
        _operator('undo_push', message='Original')
        text = bpy.data.texts.new('_bk_undo_probe')
        name = text.name
        del text
        _operator('undo_push', message='Undo probe')
        pushed = time.perf_counter()
        _operator('undo')
        undone = name not in bpy.data.texts
        _operator('redo')
        redone = name in bpy.data.texts
        _operator('undo')
        if not (undone and redone and name not in bpy.data.texts):
            raise RuntimeError('undo ran but did not restore the scene '
                               f'(undone {undone}, redone {redone})')
        _mode = 'blender'
        _why = ('push %.1f ms, undo and redo %.1f ms' %
                ((pushed - started) * 1000, (time.perf_counter() - pushed) * 1000 / 3))
    except Exception as error:
        _mode, _why = 'checkpoint', f'{type(error).__name__}: {error}'
        leftover = bpy.data.texts.get(name) if name else None
        if leftover is not None:
            bpy.data.texts.remove(leftover)
    # The probe's steps are not the history's: the first real step starts a
    # segment of its own.
    _segment = 0
    return _mode


# --------------------------------------------------------------------------
# Files

def _save():
    target = os.path.join(_root, str(uuid.uuid4()) + '.blend')
    result = bpy.ops.wm.save_as_mainfile(filepath=target, copy=True, compress=False,
                                         check_existing=False)
    if 'FINISHED' not in result or not os.path.isfile(target):
        raise RuntimeError('Blender could not write the undo checkpoint')
    return target


def _load(path):
    global _loading, _segment, _segment_loads
    _loading += 1
    try:
        result = bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    finally:
        _loading -= 1
    if 'FINISHED' not in result:
        raise RuntimeError('Blender could not restore the checkpoint')
    _segment = 0
    _segment_loads = _loads


def _forget_files(removed):
    kept = {step['file'] for step in _steps if step['file']}
    for step in removed:
        path = step['file']
        if path and path not in kept and path != _capture and os.path.isfile(path):
            os.remove(path)


def autosave(path):
    """Write the scene the app recovers from on launch. Written beside and
    moved over the old one, so a kill mid-write keeps the last good file."""
    started = time.perf_counter()
    partial = path + '.partial'
    result = bpy.ops.wm.save_as_mainfile(filepath=partial, copy=True, compress=False,
                                         check_existing=False)
    if 'FINISHED' not in result or not os.path.isfile(partial):
        raise RuntimeError('Blender could not write the autosave')
    os.replace(partial, path)
    return round((time.perf_counter() - started) * 1000, 2)


# --------------------------------------------------------------------------
# The history

def _live(step):
    return bool(_segment) and step['segment'] == _segment


def _route(target):
    """How the step at `target`, beside the current one, is reached: 'blender',
    'file' or None."""
    if not (0 <= _index < len(_steps)) or not (0 <= target < len(_steps)):
        return None
    here, there = _steps[_index], _steps[target]
    if _mode == 'blender' and _live(here) and _live(there):
        # Blender drops its oldest steps past its own limits, and says so only
        # through the poll.
        if _poll('undo' if target < _index else 'redo'):
            return 'blender'
    return 'file' if there['file'] else None


def _trim():
    """Drop the steps that can no longer be reached from the current one."""
    global _index
    removed = []
    right = _index + 1
    while right < len(_steps):
        step, before = _steps[right], _steps[right - 1]
        if not (step['file'] or (_live(step) and _live(before))):
            break
        right += 1
    removed += _steps[right:]
    del _steps[right:]
    left = _index - 1
    while left >= 0:
        step, after = _steps[left], _steps[left + 1]
        if not (step['file'] or (_live(step) and _live(after))):
            break
        left -= 1
    if left >= 0:
        removed += _steps[:left + 1]
        del _steps[:left + 1]
        _index -= left + 1
    _forget_files(removed)


def _notice_loads():
    """A load since the last look: Blender's stack is gone. The step the scene
    was at keeps the file the load_pre handler wrote, if it wrote one."""
    global _segment, _capture
    if _loads == _segment_loads:
        return
    _segment = 0
    if _capture and 0 <= _index < len(_steps) and not _steps[_index]['file']:
        _steps[_index]['file'] = _capture
        _capture = None
    _trim()


def _failover(error):
    """Blender's undo failed after the probe said it worked: checkpoints from
    here on. The scene is left as it is, and the step it is at is written to a
    file, so the steps recorded after this can come back to it."""
    global _mode, _why, _segment
    _mode, _why = 'checkpoint', f'fell back after {type(error).__name__}: {error}'
    _segment = 0
    print(f"[Blender Local] Undo falls back to checkpoints: {error}")
    if 0 <= _index < len(_steps) and not _steps[_index]['file']:
        try:
            _steps[_index]['file'] = _save()
        except Exception as save_error:
            print(f"[Blender Local] Undo could not keep the current step: {save_error}")
    _trim()


def push(root, label, replace=False, force_checkpoints=None):
    """Record the scene as it is now as the step called `label`.

    `replace` makes it take the place of the current step — adjusting the last
    operation. After `rewind` the current step was already undone, and the new
    one simply takes its place on Blender's stack. Without it Blender's stack
    cannot drop its top, so the step records that it is two of Blender's deep.

    `force_checkpoints` keeps the history in checkpoint files even where
    Blender's undo works; it only has an effect before the probe has run.
    """
    global _index, _segment, _segments, _segment_loads, _rewound
    started = time.perf_counter()
    configure(root, _forced if force_checkpoints is None else force_checkpoints)
    if _mode is None:
        probe()
    _notice_loads()
    rewound, _rewound = _rewound, False
    replacing = replace and not rewound and 0 <= _index < len(_steps)
    cut = _index if replacing else _index + 1
    replaced = _steps[_index] if replacing else None
    removed = _steps[cut:]
    del _steps[cut:]
    step = dict(label=label, segment=0, file=None, depth=1, paint=dict(_written))
    timing = {}
    # Blender's steps the action pushed itself (`note_pushed`): a stroke's
    # chunks, a sculpt operator's own step. They are the step; pushing one more
    # would make an Undo stop between them and the scene they left.
    pushed, own = _take_noted()
    if replacing:
        pushed, own = 0, True
    # Whether this push only recorded steps already on Blender's stack.
    recorded_only = False
    if _mode == 'blender':
        try:
            fresh = not _segment
            if fresh:
                _prefs()
                _segments += 1
                _segment, _segment_loads = _segments, _loads
                # A new segment starts from its own push, which the steps
                # before it reach through a file (below).
                pushed, own = 0, True
            began = time.perf_counter()
            if own or not pushed:
                _operator('undo_push', message=label)
                step['depth'] = pushed + 1
            else:
                step['depth'] = pushed
                recorded_only = True
            timing['blender'] = (time.perf_counter() - began) * 1000
            step['segment'] = _segment
            if replaced is not None and not fresh and _live(replaced):
                step['depth'] = replaced['depth'] + 1
            if fresh and _steps:
                # The steps before are reached through their files, so the way
                # back to this one is a file as well.
                began = time.perf_counter()
                step['file'] = _save()
                timing['file'] = (time.perf_counter() - began) * 1000
        except Exception as error:
            _failover(error)
            cut = min(cut, len(_steps))
    if _mode != 'blender':
        began = time.perf_counter()
        step['file'] = _save()
        timing['file'] = (time.perf_counter() - began) * 1000
        step['segment'] = 0
    _steps.append(step)
    # STEPS undos, as Blender's `undo_steps` counts them: that many steps and
    # the one they go back to.
    while len(_steps) > STEPS + 1 or (len(_steps) > 2 and _mode != 'blender' and
                                  sum(os.path.getsize(s['file']) for s in _steps if s['file']) > FILE_BYTES):
        removed.append(_steps.pop(0))
    _index = len(_steps) - 1
    _forget_files(removed)
    if recorded_only and step['file'] is None:
        # Nothing Blender holds changed: what was read from it is still good
        # (`_blenderkit_sculpt.history_recorded_only`).
        sculpting = sys.modules.get('_blenderkit_sculpt')
        if sculpting is not None and hasattr(sculpting, 'history_recorded_only'):
            sculpting.history_recorded_only()
    timing['total'] = (time.perf_counter() - started) * 1000
    _set_timing(timing)
    return state()


def step(direction):
    """Undo (-1) or redo (+1) one step."""
    global _index, _written, _noted
    # A sculpt stroke streamed in chunks rewinds the step on top of Blender's
    # stack before each chunk, taking it for its own (`_blenderkit_sculpt`).
    # Measured in desktop 5.2.1: an Undo between two chunks, then the next
    # chunk's rewind, took the history two steps back while it read one, and
    # the stroke moved nothing. The interface holds Undo during a stroke
    # (BpySession.sculptStrokeOpen); this holds the history to it as well.
    sculpting = sys.modules.get('_blenderkit_sculpt')
    if sculpting is not None and getattr(sculpting, '_stroke', None) is not None:
        raise RuntimeError("Undo and Redo wait until the sculpt stroke in progress has ended.")
    started = time.perf_counter()
    _noted = None
    _notice_loads()
    target = _index + direction
    route = _route(target)
    if route is None:
        # Nothing to step to, and nothing spent: the last call's costs are not
        # this one's.
        _set_timing({})
        return state()
    there = _steps[target]
    timing = {}
    images = _image_sources()
    began = time.perf_counter()
    if route == 'blender':
        depth = _steps[_index]['depth'] if direction < 0 else there['depth']
        name = 'undo' if direction < 0 else 'redo'
        try:
            for taken in range(depth):
                if taken and not _poll(name):
                    raise RuntimeError('Blender dropped a step the history still had')
                _operator(name)
        except Exception as error:
            if not there['file']:
                _failover(error)
                _index = min(_index, len(_steps) - 1)
                _set_timing(timing)
                return state()
            route = 'file'
    if route == 'file':
        _load(there['file'])
        if _mode == 'blender':
            _start_segment_at(there)
    timing[route] = (time.perf_counter() - began) * 1000
    _index = target
    _written = dict(there['paint'])
    began = time.perf_counter()
    reloaded = _restore_images(there, images, fresh=(route == 'file'))
    if reloaded:
        timing['images'] = (time.perf_counter() - began) * 1000
    _trim()
    timing['total'] = (time.perf_counter() - started) * 1000
    _set_timing(timing)
    return state()


def _start_segment_at(step_):
    """After a checkpoint load in Blender mode: a new stack, with this step as
    its base."""
    global _segment, _segments, _segment_loads
    try:
        _prefs()
        _segments += 1
        _segment, _segment_loads = _segments, _loads
        _operator('undo_push', message=step_['label'])
        step_['segment'], step_['depth'] = _segment, 1
    except Exception as error:
        _failover(error)


def rewind():
    """Undo the current step so that the next push replaces it: Blender's redo
    panel, which undoes an operator and runs it again with new arguments."""
    global _rewound
    before = _index
    step(-1)
    if _index == before:
        raise RuntimeError("There is no step before this one to adjust it from.")
    _rewound = True
    return state()


def cancel_rewind():
    """The operator could not run again: back to the step that was undone."""
    global _rewound
    if _rewound:
        _rewound = False
        step(1)
    return state()


def state():
    undo = _route(_index - 1) is not None
    redo = _route(_index + 1) is not None
    return dict(undo=undo, redo=redo,
                undo_label=_steps[_index]['label'] if undo else '',
                redo_label=_steps[_index + 1]['label'] if redo else '',
                mode=_mode or 'pending', why=_why, steps=len(_steps), index=_index,
                timing=_timing)


def _set_timing(timing):
    global _timing
    _timing = {key: round(value, 2) for key, value in timing.items()}


# --------------------------------------------------------------------------
# Images

def painted(name):
    """A Texture Paint stroke was written into `name` (_blenderkit_texpaint.write)."""
    global _serial
    _serial += 1
    _written[name] = _buffers[name] = _serial


def _image_source(image):
    """What an image's pixels are made from, as the .blend holds it. Nothing
    here reads the pixels: `size` would load them."""
    packed = image.packed_file
    return (image.source, image.filepath_raw, packed.size if packed is not None else -1,
            image.generated_type, image.generated_width, image.generated_height,
            tuple(image.generated_color), image.use_generated_float)


def _image_sources():
    sources = {}
    for image in bpy.data.images:
        if image.source in {'FILE', 'GENERATED', 'TILED'}:
            try:
                sources[image.name] = _image_source(image)
            except (AttributeError, ReferenceError):
                pass
    return sources


def _restore_images(there, before, fresh):
    """Reload the images whose buffers do not hold the pixels of the step now
    restored. Memfile undo keeps an image's buffer across the undo (the cache is
    preserved while the image data-block is read back), so a stroke painted since
    stays on screen and in `pixels` unless the image is reloaded from the data
    the step restored. A load starts every buffer afresh."""
    wanted = there['paint']
    if fresh:
        _buffers.clear()
        _buffers.update(wanted)
        return []
    texpaint = sys.modules.get('_blenderkit_texpaint')
    reloaded = []
    for image in bpy.data.images:
        name = image.name
        if image.source not in {'FILE', 'GENERATED', 'TILED'}:
            continue
        stale = (_buffers.get(name) != wanted.get(name)
                 or before.get(name) != _image_source(image)
                 or image.is_dirty)
        if not stale:
            continue
        image.reload()
        if wanted.get(name) is None:
            _buffers.pop(name, None)
        else:
            _buffers[name] = wanted[name]
        if texpaint is not None:
            getattr(texpaint, '_signatures', {}).pop(name, None)
        reloaded.append(name)
    return reloaded
