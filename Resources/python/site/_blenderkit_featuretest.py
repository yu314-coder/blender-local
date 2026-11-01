"""Test All Features: the user's scene saved before the run and put back after.

The features themselves are run from Swift, each through the call its button,
menu row or stroke makes (`FeatureTestRunner`), so that what is measured is
what a tap costs. What only Python can do is here: before the first feature,
the scene is saved the way the app writes its recovery file
(`_blenderkit_undo.autosave`, to the temporary folder; the app has written
`autosave.blend` itself a moment before, so a run that takes the app down
leaves the next launch the scene as it was), fingerprinted, and Blender's
startup file opened in its place, as File > New opens it; after the last, the
history is cut back to the run's own step, the saved scene opened again the
way the app opens its recovery file, and the two fingerprints compared.

This is the Self-Test's machinery (`_blenderkit_selftest`: `fingerprint`,
its scratch scene `_Run`), not a second copy of it. Loading a file ends
Blender's undo history, so Undo cannot go back past the run; the history is
left with the user's scene on top, never a feature's.

Each call prints one line, `[feature-test] ` and JSON, which the app reads
(`FeatureTest.answer`). Nothing here opens a window, a browser or another app.
"""
import json
import os

import bpy

import _blenderkit_selftest as _selftest

LABEL = "Test All Features"

# The run in progress: where the scene was saved, its fingerprint, the
# scratch scene's history, and the step the history stood at after it.
_state = None


def _undo():
    return _selftest._undo()


def _on_main_thread():
    return _selftest._on_main_thread()


def _say(**answer):
    print("[feature-test] " + json.dumps(answer), flush=True)
    return answer


def begin(saved, history_root):
    """Saves the user's scene to `saved`, fingerprints it and opens Blender's
    startup file. Refuses in one line, touching nothing, off the main thread
    or with painted pixels not yet saved in the scene."""
    global _state
    if not _on_main_thread():
        return _say(ok=False, why="it runs on the main thread only, where Blender's window is")
    dirty = [image.name for image in bpy.data.images if image.is_dirty]
    if dirty:
        return _say(ok=False, why="painted pixels of %s are not saved in the scene yet, and the test opens "
                    "the saved scene again; leave Texture Paint, or pack the image, first" % ", ".join(dirty))
    try:
        _undo().autosave(saved)
        before, objects, vertices = _selftest.fingerprint()
    except Exception as error:                     # noqa: BLE001 - said, and nothing is touched
        return _say(ok=False, why="your scene could not be saved first (%s: %s)" % (type(error).__name__, error))
    run = _selftest._Run(history_root or getattr(_undo(), '_root', None), LABEL)
    try:
        run.fresh()
    except Exception as error:                     # noqa: BLE001 - the scene is as it was
        return _say(ok=False, why="Blender's startup file did not open (%s: %s)" % (type(error).__name__, error))
    _state = dict(saved=saved, before=before, run=run, step=_undo().current_step())
    return _say(ok=True, objects=objects, vertices=vertices, blender=bpy.app.version_string,
                history=run.history)


def end():
    """Puts the user's scene back and says whether it came back exactly."""
    global _state
    state = _state
    if state is None:
        return _say(ok=False, restored=False, detail="no run to end")
    saved, run = state['saved'], state['run']
    # The run's own step on top, every feature's after it gone: the load
    # below then keeps none of their scenes (its load_pre handler saves the
    # step the history stands at only when no file holds it, and the run's
    # step has one).
    try:
        _undo().back_to(state['step'])
    except Exception as error:                     # noqa: BLE001 - said; the scene still comes back
        print("[Blender Local] Test All Features could not cut the history back: %s" % error)
    error = None
    for _ in range(3):
        try:
            run.restore(saved)
            error = None
            break
        except KeyboardInterrupt as interrupted:
            error = interrupted
        except Exception as failed:                # noqa: BLE001 - said, with where the scene is
            error = failed
            break
    if error is not None:
        _state = None
        return _say(ok=True, restored=False,
                    detail="could not be opened (%s: %s); it is saved in %s, and File ▸ Revert opens the app's "
                    "recovery file" % (type(error).__name__, error, saved), history=run.history)
    after, objects, vertices = _selftest.fingerprint()
    gone, new = _selftest._differences(state['before'], after)
    restored = not gone and not new
    detail = ("%s object%s, %s vertices, as before the test" % (
        _selftest._n(objects), "" if objects == 1 else "s", _selftest._n(vertices))
              if restored else "differs from before the test: was %s; now %s"
              % ("; ".join(gone[:3]) or "-", "; ".join(new[:3]) or "-"))
    try:
        run.push()
    except Exception as failed:                    # noqa: BLE001 - said: Undo may then reach a feature's scene
        restored = False
        detail += ("; but the undo history could not be put right (%s: %s), so Undo may reach a "
                   "feature's scene" % (type(failed).__name__, failed))
    for path in (saved, saved + '1'):
        if os.path.exists(path):
            os.remove(path)
    forget = getattr(_selftest._gate(), 'forget', None)
    if forget is not None:
        forget(saved)
    _state = None
    return _say(ok=True, restored=restored, detail=detail, history=run.history)
