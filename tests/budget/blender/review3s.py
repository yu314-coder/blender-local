"""Part 12t: the review of "the budget gaps a script reaches, and the gate's
own holes" answered (fix round 3, October 29). Each finding as the review
measured it, refused (or held at the mirror's pass) at a budget lowered to
100,000, beside a control that puts the gap back and has to let it through.

Run from verify.py at its end (it loads files, which replaces the scene the
other parts hold), or alone with `BUDGET_PARTS=12t`, in its globals
(`check`, `gate`, `budget`, `sync`, `undo`, `blocks`, `WORK`).

  t.1  a script's handler with no code of its own (a functools.partial, an
       instance with __call__, a method of one, an instance handing out a
       borrowed __code__) that takes out its checkpoint
  t.2  a handler taken as the gate's own through a module a script makes
       or a real module's globals
  t.3  Blender's and the app's own handlers still need no checkpoint
  t.4  what no price stood before, held at the mirror's pass: both lists
       cleared before Python's base-type entry, the lists put back after,
       a view layer never evaluated, sys.monitoring switched off from inside
       the handler, a load_post handler that takes out its checkpoint
  t.5  a handler that is also a bpy.props getter a driver reads: no
       checkpoint inside Blender's evaluation
  t.6  the app's own loads of files a script wrote: an undo step's file, the
       history's checkpoint, File ▸ New's startup file and a changed
       recovery file, as the Swift sends them

Nothing here opens a window, a browser or another app.
"""
import bpy, bmesh, functools, os, sys, types

# The modules themselves: run at the end of the whole check, some names of
# verify.py's globals are other parts' own by then (`undo` was a function).
gate = sys.modules["_blenderkit_gate"]
budget = sys.modules["_blenderkit_budget"]
sync = sys.modules["_blenderkit_sync"]
undo_t = sys.modules["_blenderkit_undo"]
SITE_T = os.path.dirname(gate.__file__)


class put_t:
    def __init__(self, module, name, value):
        self.module, self.name, self.value = module, name, value

    def __enter__(self):
        self.kept = getattr(self.module, self.name)
        setattr(self.module, self.name, self.value)

    def __exit__(self, *exc):
        setattr(self.module, self.name, self.kept)


def mirror_t():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def line_t(source):
    try:
        exec(compile(source, "<line>", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the refusal is the finding
        return str(error)
    return mirror_t()


def held_t(obj, layer=None):
    layer = layer or bpy.context.view_layer
    dg = layer.depsgraph
    if dg is None:
        return None
    try:
        ev = obj.evaluated_get(dg)
    except (ReferenceError, RuntimeError):
        return None
    if ev == obj:
        return None
    me = ev.to_mesh()
    try:
        return len(me.vertices) if me is not None else 0
    finally:
        ev.to_mesh_clear()


def reset_t():
    for s in list(bpy.data.scenes):
        if s != bpy.context.scene and len(bpy.data.scenes) > 1:
            bpy.data.scenes.remove(s)
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    for m in list(bpy.data.meshes):
        if m.users == 0:
            bpy.data.meshes.remove(m)
    mirror_t()


def cube_t(name="A", count=2, scene=None):
    me = bpy.data.meshes.new(name + "Mesh")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    (scene or bpy.context.scene).collection.objects.link(o)
    o.modifiers.new("Array", 'ARRAY').count = count
    return o


def refused_t(said, number=None):
    return said is not None and "and this app stops at" in said and (number is None or format(number, ',') in said)


def held_said_t(said):
    return said is not None and "with nothing priced first" in said


def handler_case_t(handler, lst='depsgraph_update_post'):
    reset_t()
    a = cube_t()
    mirror_t()
    items = getattr(bpy.app.handlers, lst)
    items.append(handler)
    try:
        said = line_t("bpy.data.objects['A'].location.x = 1.0")
        built = held_t(a)
    finally:
        while handler in items:
            items.remove(handler)
        gate.tidy_handlers()
    return said, built


def unhook_t(me_of):
    """The body every handler below runs: its checkpoint taken out of the
    list, then Count 20,000 (160,000 vertices at the budget of 100,000)."""
    items = bpy.app.handlers.depsgraph_update_post
    try:
        i = items.index(me_of())
    except ValueError:
        i = -1
    if 0 <= i < len(items) - 1:
        items.remove(items[i + 1])
    bpy.data.objects['A'].modifiers[0].count = 20000


class Unwrapped_t(gate._Guarded):
    """The control's wrapper: calls what it wraps and nothing after, and is
    taken as the gate's own (no checkpoint after it either) — the gap as on
    the reviewed tree, where such a callable kept only the list's
    checkpoint, which it took out."""
    __slots__ = ()

    def __call__(self, *a, **k):
        return object.__getattribute__(self, '_function')(*a, **k)


def old_handler_code_t(function):
    """`_handler_code` as on the reviewed tree: the attribute read."""
    code = getattr(function, '__code__', None)
    if code is None:
        code = getattr(getattr(function, '__func__', None), '__code__', None)
    return code if type(code).__name__ == 'code' else None


def old_own_by_file_t(function):
    """`_own_by_file` as on the reviewed tree: the module Python names,
    its `__file__` and the function's globals."""
    scripts = os.path.realpath(bpy.utils.system_resource('SCRIPTS')) + os.sep
    plain = function if getattr(function, '__code__', None) is not None else getattr(function, '__func__', None)
    code = getattr(plain, '__code__', None)
    filename = getattr(code, 'co_filename', '') or ''
    if not filename:
        return False
    module = sys.modules.get(getattr(plain, '__module__', None) or '')
    if module is None or getattr(module, '__dict__', None) is not getattr(plain, '__globals__', None):
        return False
    module_file = getattr(module, '__file__', None) or ''
    if not module_file or os.path.realpath(module_file) != os.path.realpath(filename):
        return False
    if os.path.realpath(filename).startswith(scripts):
        return True
    return (os.path.basename(filename).startswith('_blenderkit_')
            and os.path.dirname(os.path.abspath(filename)) == SITE_T)


def old_own_t(function):
    return gate._gate_own(function) or type(function) is gate._Guarded or old_own_by_file_t(function)


print("\n12t. the review of 'the budget gaps a script reaches, and the gate's own holes', answered")
kept_budget_t = budget.BUDGET
budget.BUDGET = 100_000
try:
    # -- t.1 callables with no code of their own ---------------------------------------
    def partial_t():
        box = {}

        def inner(scene, *rest):
            unhook_t(lambda: box['h'])
        box['h'] = functools.partial(inner)
        return box['h']

    class CallableT:
        def __call__(self, scene, *rest):
            unhook_t(lambda: self)

    class BorrowedCodeT:
        __code__ = (lambda *a: None).__code__

        def __call__(self, scene, *rest):
            unhook_t(lambda: self)

    class MethodFunctionT:
        def __call__(self, owner, scene, *rest):
            unhook_t(lambda: owner.bound)

    def method_t():
        owner = types.SimpleNamespace()
        owner.bound = types.MethodType(MethodFunctionT(), owner)
        return owner.bound

    for label, make in (("a functools.partial", partial_t), ("an instance with __call__", CallableT),
                        ("a method whose function is such an instance", method_t)):
        said, built = handler_case_t(make())
        check("12t.1 %s in depsgraph_update_post that takes out its checkpoint and sets Count 20,000: refused at "
              "160,000, Blender at %s" % (label, built), refused_t(said, 160_000) and built == 16, (said, built))
        with put_t(gate, '_Guarded', Unwrapped_t), put_t(gate, 'hold_unseen', lambda: False):
            control, built = handler_case_t(make())
        check("control: with nothing around it, as on the reviewed tree (and nothing held at the mirror's pass), "
              "Blender built %s" % format(built or 0, ','),
              control is None and built == 160_000, (control, built))
    # The wrapper is still the script's callable to its list operations.
    p = functools.partial(print)
    post = bpy.app.handlers.depsgraph_update_post
    post.append(p)
    gate.install()
    wrapped = [h for h in post if type(h) is gate._Guarded]
    found = p in post
    post.remove(p)
    gate.tidy_handlers()
    check("12t.1 the wrapper stands where the partial was, and `in` and `remove` still find the partial "
          "(wrapped: %d, found: %s, left: %s)" % (len(wrapped), found, p in post),
          len(wrapped) == 1 and found and p not in post and not any(type(h) is gate._Guarded for h in post))

    said, built = handler_case_t(BorrowedCodeT())
    check("12t.1 an instance handing out another function's __code__, that takes out its checkpoint: refused at "
          "160,000, Blender at %s" % built, refused_t(said, 160_000) and built == 16, (said, built))
    with put_t(gate, '_handler_code', old_handler_code_t), put_t(gate, 'hold_unseen', lambda: False):
        control, built = handler_case_t(BorrowedCodeT())
    check("control: with the code read from the attribute, as on the reviewed tree (the borrowed code watched), "
          "Blender built %s" % format(built or 0, ','), control is None and built == 160_000, (control, built))

    # -- t.2 a handler taken as the gate's own ------------------------------------------
    def count_source_t(name):
        return ("def %s(scene, *rest):\n"
                "    import bpy\n"
                "    bpy.data.objects['A'].modifiers[0].count = 20000\n" % name)

    def fake_module_t(name, path):
        module = types.ModuleType(name)
        module.__file__ = path
        sys.modules[name] = module
        exec(compile(count_source_t("h"), path, 'exec'), module.__dict__)
        return module.h

    def real_globals_t():
        tools = sys.modules['_blenderkit_tools']
        exec(compile(count_source_t("_zz_review_handler"), tools.__file__, 'exec'), tools.__dict__)
        return tools._zz_review_handler

    scripts_t = bpy.utils.system_resource('SCRIPTS')
    for label, make in (
            ("a module the script makes beside the app's (`_blenderkit_zz_fake`, its file never written)",
             lambda: fake_module_t('_blenderkit_zz_fake', os.path.join(SITE_T, '_blenderkit_zz_fake.py'))),
            ("a function compiled into `_blenderkit_tools`' own globals", real_globals_t),
            ("a module the script makes under Blender's scripts folder",
             lambda: fake_module_t('zz_review_fake', os.path.join(scripts_t, 'zz_review_fake.py')))):
        said, built = handler_case_t(make())
        check("12t.2 a depsgraph_update_post handler from %s, setting Count 20,000: refused at 160,000, Blender at %s"
              % (label, built), refused_t(said, 160_000) and built == 16, (said, built))
        with put_t(gate, '_own', old_own_t), put_t(gate, 'hold_unseen', lambda: False):
            control, built = handler_case_t(make())
        check("control: with a module's handlers known by its file and globals, as on the reviewed tree, "
              "Blender built %s" % format(built or 0, ','), control is None and built == 160_000, (control, built))
    for name in ('_blenderkit_zz_fake', 'zz_review_fake'):
        sys.modules.pop(name, None)
    sys.modules['_blenderkit_tools'].__dict__.pop('_zz_review_handler', None)

    # -- t.3 Blender's and the app's own need no checkpoint -------------------------------
    gate.install()
    bare = []
    for name in ('load_post', 'version_update', 'depsgraph_update_post', 'undo_post', 'redo_post'):
        items = getattr(bpy.app.handlers, name)
        for i, item in enumerate(items):
            if not gate._gate_own(item) and gate._own(item) and i + 1 < len(items) and \
                    items[i + 1] in (gate._checkpoint, gate._load_checkpoint):
                bare.append((name, getattr(item, '__name__', repr(item))))
    trusted = [getattr(f, '__name__', '?') for f in bpy.app.handlers.load_post if gate._own(f)]
    check("12t.3 Blender's and the app's own handlers are known by identity and have no checkpoint after them "
          "(load_post: %s)" % ", ".join(trusted),
          not bare and '_on_blendfile_load_post' in trusted and '_bk_undo_load_post' in trusted, bare)

    # -- t.4 held at the mirror's pass -----------------------------------------------------
    clear_both = ("pre = bpy.app.handlers.depsgraph_update_pre; post = bpy.app.handlers.depsgraph_update_post\n"
                  "kept = (list(pre), list(post))\npre.clear(); post.clear()\n"
                  "bpy.data.objects['A'].modifiers[0].count = 20000\n"
                  "bpy.types.bpy_struct.__getattribute__(bpy.context.view_layer, 'update')()\n")

    def cleared_t(source):
        reset_t()
        a = cube_t()
        mirror_t()
        said = line_t(source)
        built = held_t(a)
        moved = line_t("bpy.data.objects['A'].location.x = 2.0")
        gate.install()
        return said, built, moved, held_t(a)

    said, built, moved, after = cleared_t(clear_both)
    check("12t.4 a line that clears depsgraph_update_pre AND _post, sets Count 20,000 and calls Python's base "
          "type's `update`: Blender builds it once, the mirror's pass holds it (the Array hidden, Blender at %s), "
          "said in words; a later move passes at %s" % (built, after),
          held_said_t(said) and "A (160,000)" in said and built == 8 and moved is None and after == 8,
          (said, built, moved, after))
    with put_t(gate, 'hold_unseen', lambda: False):
        control, built, moved, after = cleared_t(clear_both)
    check("control: with nothing held at the mirror's pass, as on the reviewed tree, Blender holds %s and the "
          "later move passes at %s" % (format(built or 0, ','), format(after or 0, ',')),
          control is None and built == 160_000 and moved is None and after == 160_000, (control, built, after))
    said, built, moved, after = cleared_t(clear_both + "pre.extend(kept[0]); post.extend(kept[1])\n")
    check("12t.4 …and with both lists put back by the line itself, leaving no trace: held all the same, "
          "Blender at %s" % built, held_said_t(said) and built == 8, (said, built))

    reset_t()
    s2 = bpy.data.scenes.new("S2")
    x = cube_t("X", 20000, s2)
    mirror_t()
    said = line_t("bpy.types.bpy_struct.__getattribute__(bpy.data.scenes['S2'].view_layers[0], 'update')()\n")
    built = held_t(x, s2.view_layers[0])
    check("12t.4 the same entry on a view layer never evaluated (S2, X under an Array of 20,000): held at the "
          "mirror's pass and that layer evaluated again, Blender's S2 at %s" % built,
          held_said_t(said) and built == 8, (said, built))
    reset_t()
    s2 = bpy.data.scenes.new("S2")
    x = cube_t("X", 20000, s2)
    mirror_t()
    with put_t(gate, 'hold_unseen', lambda: False):
        control = line_t("bpy.types.bpy_struct.__getattribute__(bpy.data.scenes['S2'].view_layers[0], 'update')()\n")
        built = held_t(x, s2.view_layers[0])
    check("control: with nothing held, S2's X stays at %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))

    def monitoring_off_t():
        def handler(scene, *rest):
            m = sys.monitoring
            for tool in range(6):
                if m.get_tool(tool) == 'Blender Local budget checkpoint':
                    m.set_local_events(tool, handler.__code__, 0)
            unhook_t(lambda: handler)
        return handler

    said, built = handler_case_t(monitoring_off_t())
    check("12t.4 a handler that switches sys.monitoring off for its own code, takes out its checkpoint and sets "
          "Count 20,000: held at the mirror's pass, Blender at %s (Python's own hooks are past the gate)" % built,
          held_said_t(said) and built == 8, (said, built))
    with put_t(gate, 'hold_unseen', lambda: False):
        control, built = handler_case_t(monitoring_off_t())
    check("control: with nothing held, as on the reviewed tree, Blender built %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))

    def load_post_t():
        reset_t()
        cube_t()
        mirror_t()
        path = os.path.join(WORK, "light_12t.blend")
        bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)

        @bpy.app.handlers.persistent
        def unhooking(*args):
            items = bpy.app.handlers.load_post
            i = items.index(unhooking)
            if i + 1 < len(items):
                items.remove(items[i + 1])
            obj = bpy.data.objects.get('A')
            if obj is not None:
                obj.modifiers[0].count = 20000
        bpy.app.handlers.load_post.append(unhooking)
        try:
            said = line_t("bpy.ops.wm.open_mainfile(filepath=%r, load_ui=False)" % path)
        finally:
            while unhooking in bpy.app.handlers.load_post:
                bpy.app.handlers.load_post.remove(unhooking)
            gate.tidy_handlers()
        return said, held_t(bpy.data.objects['A'])

    said, built = load_post_t()
    check("12t.4 a load_post handler that takes out its checkpoint and sets Count 20,000 as a script's load "
          "opens a file: held at the mirror's pass, Blender at %s" % built, held_said_t(said) and built == 8,
          (said, built))
    with put_t(gate, 'hold_unseen', lambda: False):
        control, built = load_post_t()
    check("control: with nothing held, Blender built %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))

    # -- t.5 a handler that is also a getter a driver reads ---------------------------------
    def getter_case_t(owner_type, gap):
        reset_t()
        a = cube_t("A")
        e = bpy.data.objects.new("E", None)
        bpy.context.scene.collection.objects.link(e)
        state = {'dispatching': False, 'inside': 0}

        def g(owner):
            return 2

        def mark_on(scene, *rest):
            state['dispatching'] = True

        def mark_off(scene, *rest):
            state['dispatching'] = False
        real_checkpoint = gate._checkpoint

        def spy(*args, **keywords):
            f = sys._getframe(1)
            for _ in range(4):
                if f is None:
                    break
                if f.f_code is g.__code__ and not state['dispatching']:
                    state['inside'] += 1
                    break
                f = f.f_back
            return real_checkpoint(*args, **keywords)
        setattr(owner_type, 'bk_review_probe', bpy.props.IntProperty(get=g))
        curve = a.modifiers[0].driver_add("count")
        var = curve.driver.variables.new()
        curve.driver.type = 'SUM'
        var.type = 'SINGLE_PROP'
        if owner_type is bpy.types.Scene:
            var.targets[0].id_type = 'SCENE'
            var.targets[0].id = bpy.context.scene
        else:
            var.targets[0].id = e
        var.targets[0].data_path = 'bk_review_probe'
        post = bpy.app.handlers.depsgraph_update_post
        for h in (mark_on, g, mark_off):
            post.append(h)
        try:
            with put_t(gate, '_checkpoint', spy), gap:
                for _ in range(3):
                    mirror_t()
                    e.location.x += 0.1
                    bpy.context.view_layer.update()
                mirror_t()
        finally:
            for h in (mark_on, g, mark_off):
                while h in post:
                    post.remove(h)
            gate.tidy_handlers()
            delattr(owner_type, 'bk_review_probe')
        return state['inside']

    inside = getter_case_t(bpy.types.Object, put_t(gate, '_MAIN_THREAD', gate._MAIN_THREAD))
    check("12t.5 a handler that is also an Object property's getter a driver reads: the gate's checkpoint ran "
          "%d times inside Blender's evaluation" % inside, inside == 0, inside)
    with put_t(gate, '_as_handler', lambda arguments, single=False: (None, None)):
        control = getter_case_t(bpy.types.Object, put_t(gate, '_off_dispatch', lambda frame: False))
    check("control: with every return taken as a handler's, as on the reviewed tree, it ran %d times there"
          % control, control > 0, control)

    # -- t.6 the app's own loads of files a script wrote ------------------------------------
    heavy_source = ("import os, bmesh\n"
                    "s = bpy.data.scenes.new('S9')\n"
                    "me = bpy.data.meshes.new('XM')\n"
                    "bm = bmesh.new(); bmesh.ops.create_cube(bm, size=1.0); bm.to_mesh(me); bm.free()\n"
                    "x = bpy.data.objects.new('X', me)\n"
                    "s.collection.objects.link(x)\n"
                    "x.modifiers.new('Array', 'ARRAY').count = 20000\n"
                    "bpy.data.libraries.write(%r, {s}, fake_user=True)\n"
                    "bpy.data.scenes.remove(s)\n")

    def x_held_t():
        for s in bpy.data.scenes:
            for o in s.objects:
                if o.name.startswith('X'):
                    return held_t(o, s.view_layers[0])
        return None

    def undo_file_t():
        """An undo step's file the app wrote, then written over by a script
        line, then opened as the history opens it (`_blenderkit_undo._load`,
        what `step` calls on a 'file' route)."""
        reset_t()
        cube_t("A")
        mirror_t()
        path = undo_t._save()
        heavy = os.path.join(WORK, "heavy_12t.blend")
        said = line_t((heavy_source % heavy) + "open(%r, 'wb').write(open(%r, 'rb').read())\n" % (path, heavy))
        try:
            undo_t._load(path)
            said = mirror_t()
        except RuntimeError as error:
            said = "RAISED " + str(error)
        return said, x_held_t()

    said, built = undo_file_t()
    check("12t.6 an undo step's file written over by a script line, then opened by the history: refused at "
          "160,000 in the mirror's words, X at %s" % built,
          refused_t(said, 160_000) and "which changed after this app wrote it" in said and built == 8, (said, built))
    with put_t(gate, 'vouched', lambda path: True):
        control, built = undo_file_t()
    check("control: with every file the history opens taken as the app wrote it, as on the reviewed tree, "
          "Blender built X at %s" % format(built or 0, ','), control is None and built == 160_000, (control, built))
    reset_t()
    cube_t("A", 3)
    mirror_t()
    path = undo_t._save()
    undo_t._load(path)
    said = mirror_t()
    a_again = bpy.data.objects.get('A')
    check("12t.6 …and the app's own file, as it wrote it, opens as saved (Blender at %s, said: %s)"
          % (held_t(a_again) if a_again else None, said), said is None and a_again is not None and held_t(a_again) == 24,
          said)

    def history_t():
        reset_t()
        cube_t("A")
        mirror_t()
        root = os.path.join(WORK, "Documents", ".history-12t")
        sync.checkpoint(root, "one")
        bpy.data.objects['A'].location.x = 0.5
        mirror_t()
        sync.checkpoint(root, "two")
        heavy = os.path.join(WORK, "heavy_12t_history.blend")
        line_t((heavy_source % heavy) + "import os\nfor f in os.listdir(%r):\n"
               "    if f.endswith('.blend'):\n"
               "        open(os.path.join(%r, f), 'wb').write(open(%r, 'rb').read())\n" % (root, root, heavy))
        try:
            sync.history_step(-1)
            said = mirror_t()
        except RuntimeError as error:
            said = "RAISED " + str(error)
        return said, x_held_t()

    said, built = history_t()
    check("12t.6 the history's checkpoints written over by a script line, then a step back: refused at 160,000, "
          "X at %s" % built, refused_t(said, 160_000) and built == 8, (said, built))
    with put_t(gate, 'vouched', lambda path: True):
        control, built = history_t()
    check("control: as on the reviewed tree, Blender built X at %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))

    def swift_load_t(name, path):
        reset_t()
        source = blocks[name].replace("@PATH@", repr(path))
        try:
            exec(compile(source, "<swift %s>" % name, "exec"), {"bpy": bpy})
            said = mirror_t()
        except RuntimeError as error:
            said = "RAISED " + str(error)
        return said, x_held_t()

    heavy = os.path.join(WORK, "heavy_12t_swift.blend")
    exec(compile(heavy_source % heavy, "<heavy>", "exec"), {"bpy": bpy})
    for name, words in (("LOAD NEW FROM", "File ▸ New's startup file"),
                        ("LOAD RECOVERY CHANGED", "The recovery file, which changed after this app wrote it")):
        said, built = swift_load_t(name, heavy)
        check("12t.6 %s, as the Swift sends it, on a heavy file a script wrote: refused at 160,000 in the "
              "mirror's words, X at %s" % (words, built),
              refused_t(said, 160_000) and words in said and built == 8, (said, built))
    said, built = swift_load_t("LOAD OPEN", heavy)
    check("control: the Open sheet's own load of the same file is Blender's to evaluate as saved, X at %s"
          % format(built or 0, ','), said is None and built == 160_000, (said, built))
    reset_t()
    try:
        exec(compile(blocks["LOAD NEW"], "<swift LOAD NEW>", "exec"), {"bpy": bpy})
        said = mirror_t()
    except RuntimeError as error:
        said = "RAISED " + str(error)
    check("12t.6 File ▸ New as the Swift sends it, on Blender's own startup file: passes (%s)" % said, said is None,
          said)
finally:
    budget.BUDGET = kept_budget_t
