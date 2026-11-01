"""Part 12s: fix round 3's script-only cases (October 29) — the budget gaps
reachable from a script line and the gate's own holes, as "Found after fix
round 2's repairs, still open (October 22)" lists them in
docs/blender-local.md, each refused before Blender builds it, beside a
control that puts that gap back and has to let it through.

Run from verify.py after part 12 (or alone, `BUDGET_PARTS=12s`), in its
globals (`check`, `counts`, `clear`, `gate_off`, `budget`, `sync`, `gate`,
`context`, `load`, `WORK`). Each case is a script line followed by the
mirror's pass (`_blenderkit_sync.sync`), as the app runs a script, or the
app's timeline (`_blenderkit_anim.frame_set`); Blender's own count is read
after, without evaluating anything (`held_s3`). The budget is lowered to
100,000 so every bypass costs little.

  s.1  a mesh grown by a script, and a metaball refused for its time, stay
       out of the scene
  s.2  a Background Scene and a Rigid Body World's collection
  s.3  hair curves, new and grown
  s.4  a custom-property array longer than 64 read by a driver
  s.5  a script's handlers: one marked as the gate's, one that takes out
       the checkpoint after it, and the frame plan after such a handler
  s.6  a frame's probe builds no other object's growth
  s.7  drivers that read each other under a keyed parent, a keyed
       rotation, and through a Distance only Blender works out
  s.8  a render of another scene, a bake, an export at render settings
  s.9  an image's pixels a Displace reads
  s.10 Grease Pencil Line Art
  s.11 a file a script writes and loads
  s.12 ordinary edits of the same kinds still pass

Nothing here opens a window, a browser or another app.
"""
import bpy, bmesh, math, os, sys, time

anim_s3 = sys.modules.get("_blenderkit_anim") or load("_blenderkit_anim")
SC_S3 = bpy.context.scene


class put_s3:
    """`module.name` set to `value` for a control (the gap put back)."""

    def __init__(self, module, name, value):
        self.module, self.name, self.value = module, name, value

    def __enter__(self):
        self.kept = getattr(self.module, self.name)
        setattr(self.module, self.name, self.value)

    def __exit__(self, *exc):
        setattr(self.module, self.name, self.kept)


class nohold_s3:
    """A control's gap, with nothing held at the mirror's pass after either
    (`_blenderkit_gate.hold_unseen`, the review of this part's work): what
    the gap lets through is then Blender's to keep, as on 6d31b90."""

    def __enter__(self):
        self.kept = gate.hold_unseen
        gate.hold_unseen = lambda: False

    def __exit__(self, *exc):
        gate.hold_unseen = self.kept


class bare_s3:
    def __enter__(self):
        gate._busy += 1

    def __exit__(self, *exc):
        try:
            bpy.context.view_layer.update()
        finally:
            gate._busy -= 1


def said_s3(fn):
    try:
        fn()
    except RuntimeError as error:
        return str(error)
    return None


def mirror_s3():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def line_s3(source, ns=None):
    """A script line, then the mirror's pass the app runs after it."""
    try:
        exec(compile(source, "<line>", "exec"), ns if ns is not None else {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the refusal is the finding
        return str(error)
    return mirror_s3()


def held_s3(obj, layer=None):
    """What Blender holds for `obj` in `layer`'s depsgraph (the context's),
    evaluating nothing: None where it holds none."""
    layer = layer or bpy.context.view_layer
    dg = layer.depsgraph
    if dg is None:
        return None
    evaluated = obj.evaluated_get(dg)
    if evaluated == obj:
        return None
    if obj.type == 'CURVES':
        return len(evaluated.data.points)
    if obj.type == 'GREASEPENCIL':
        n = 0
        for layer_ in evaluated.data.layers:
            frame = layer_.current_frame()
            if frame is not None and frame.drawing is not None:
                n += len(frame.drawing.attributes['position'].data)
        return n
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


def refused_s3(said, number=None):
    return said is not None and ("and this app stops at" in said or "before its modifiers are counted" in said
                                 or "reads a driver that reads it back" in said or "polygonize" in said) and (
        number is None or format(number, ',') in said)


def reset_s3():
    for scene in list(bpy.data.scenes):
        if scene != SC_S3 and len(bpy.data.scenes) > 1:
            bpy.data.scenes.remove(scene)
    SC_S3.background_set = None
    if SC_S3.rigidbody_world is not None:
        with bare_s3():
            bpy.ops.rigidbody.world_remove()
    clear()
    for collection in (bpy.data.actions, bpy.data.node_groups, bpy.data.textures, bpy.data.collections,
                       bpy.data.curves, bpy.data.meshes, bpy.data.hair_curves, bpy.data.metaballs,
                       bpy.data.grease_pencils, bpy.data.images, bpy.data.materials, bpy.data.cameras):
        for block in list(collection):
            try:
                if block.users == 0 or collection is bpy.data.collections:
                    collection.remove(block)
            except (RuntimeError, ReferenceError):
                pass
    with bare_s3():
        SC_S3.frame_set(1)
    mirror_s3()


def cube_s3(name, scene=None, collection=None):
    me = bpy.data.meshes.new(name + "Mesh")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    (collection or (scene or SC_S3).collection).objects.link(obj)
    return obj


def array_s3(obj, count):
    m = obj.modifiers.new("Array", 'ARRAY')
    m.count = count
    return m


def mesh_peak_s3():
    best = 0
    dg = bpy.context.view_layer.depsgraph
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            ev = obj.evaluated_get(dg)
            if ev != obj:
                best = max(best, len(ev.data.vertices))
    return best


print("\n12s. fix round 3: the budget gaps reachable from a script, and the gate's own")
kept_budget_s3 = budget.BUDGET
budget.BUDGET = 100_000
try:
    # -- s.1 what a refusal leaves ---------------------------------------------------
    reset_s3()
    base = cube_s3("Base")
    mirror_s3()
    said = line_s3("me = bpy.data.objects['Base'].data\nme.vertices.add(160000)\nme.update()")
    check("12s.1 a script's `vertices.add(160000)` and `update()` on a cube is refused at 160,008, and the cube "
          "is taken out of the scene (in it: %s, Blender holds %s)" % (base.name in SC_S3.objects, held_s3(base)),
          refused_s3(said, 160_008) and "taken out of the scene" in said and base.name not in SC_S3.objects
          and held_s3(base) is None, said)
    reset_s3()
    base = cube_s3("Base")
    mirror_s3()
    with nohold_s3(), put_s3(budget, '_left_over', lambda strict, stand_over, now, label: []):
        control = line_s3("me = bpy.data.objects['Base'].data\nme.vertices.add(160000)\nme.update()")
        moved = line_s3("bpy.data.objects['Base'].location.x = 1.0")
    check("control: with what the refusal leaves not priced, as on 6d31b90, the cube stays and a later move "
          "passes, Blender at %s" % format(held_s3(base) or 0, ','),
          refused_s3(control) and moved is None and held_s3(base) == 160_008, (control, moved, held_s3(base)))

    # A metaball family refused for its time alone (the time's bound lowered
    # so a small family is past it): taken out too.
    reset_s3()
    mb = bpy.data.metaballs.new("MB")
    ball = bpy.data.objects.new("MB", mb)
    SC_S3.collection.objects.link(ball)
    mb.resolution = 0.2
    mb.elements.new().radius = 1.0
    mirror_s3()
    # 40 elements at Resolution 0.2: about 48,000 vertices by the count's
    # bound, under the budget, and 0.08 s by the time's, past its 0.05 s
    # margin over what Blender holds.
    grow_meta = ("mb = bpy.data.metaballs['MB']\nfor i in range(39):\n"
                 "    e = mb.elements.new(); e.co = (i * 0.5, 0, 0); e.radius = 1.0\n")
    with put_s3(budget, 'METABALL_SECONDS', 1e-4):
        said = line_s3(grow_meta)
    check("12s.1 a metaball family given elements by a script line, refused for its polygonizing time alone, "
          "is taken out of the scene (in it: %s)" % (ball.name in SC_S3.objects),
          said is not None and "polygonize" in said and ball.name not in SC_S3.objects, said)
    reset_s3()
    mb = bpy.data.metaballs.new("MB")
    ball = bpy.data.objects.new("MB", mb)
    SC_S3.collection.objects.link(ball)
    mb.resolution = 0.2
    mb.elements.new().radius = 1.0
    mirror_s3()
    with nohold_s3(), put_s3(budget, 'METABALL_SECONDS', 1e-4), \
            put_s3(budget, '_left_over', lambda strict, stand_over, now, label: []):
        control = line_s3(grow_meta)
    check("control: with what the refusal leaves not priced, the family stays in the scene",
          control is not None and "polygonize" in control and ball.name in SC_S3.objects, control)

    # -- s.2 a Background Scene and a Rigid Body World ------------------------------
    def background_case():
        reset_s3()
        s2 = bpy.data.scenes.new("S2")
        x = cube_s3("X", s2)
        array_s3(x, 20_000)
        mirror_s3()
        return x, line_s3("bpy.context.scene.background_set = bpy.data.scenes['S2']")

    x, said = background_case()
    check("12s.2 `scene.background_set = S2`, S2 holding X under an Array of 20,000, is refused at 160,000, the "
          "Background Scene put back (%s) and X not built (%s)" % (SC_S3.background_set, held_s3(x)),
          refused_s3(said, 160_000) and SC_S3.background_set is None and held_s3(x) is None, said)
    with nohold_s3(), put_s3(gate, '_diff_scene_pointer', lambda *a: None), put_s3(gate, '_scene_reads', lambda scene: []):
        x, control = background_case()
        built = held_s3(x)
    check("control: with the Scene's own pointers compared nowhere and what it reads looked for nowhere, as on "
          "6d31b90, the line passed and Blender built X at %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))

    def rigid_case():
        reset_s3()
        group = bpy.data.collections.new("C")
        x = cube_s3("X", collection=group)
        array_s3(x, 20_000)
        mirror_s3()
        return x, line_s3("bpy.ops.rigidbody.world_add()\nbpy.context.scene.rigidbody_world.collection = "
                          "bpy.data.collections['C']")

    x, said = rigid_case()
    check("12s.2 a Rigid Body World given collection C, C holding X under an Array of 20,000: refused at 160,000, "
          "the collection put back and X not built (%s)" % held_s3(x),
          refused_s3(said, 160_000) and SC_S3.rigidbody_world.collection is None and held_s3(x) is None, said)
    with nohold_s3(), put_s3(gate, '_diff_scene_pointer', lambda *a: None), put_s3(gate, '_scene_reads', lambda scene: []):
        x, control = rigid_case()
        built = held_s3(x)
    check("control: as on 6d31b90 Blender built X at %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))

    # -- s.3 hair curves ------------------------------------------------------------------
    hair_new = ("c = bpy.data.hair_curves.new('H')\nc.add_curves([1000] * 200)\n"
                "o = bpy.data.objects.new('H', c)\nbpy.context.scene.collection.objects.link(o)")
    reset_s3()
    said = line_s3(hair_new)
    hair = bpy.data.objects.get('H')
    check("12s.3 hair curves of 200,000 points made and linked by a script line are refused at 200,000 and taken "
          "out of the scene (Blender holds %s)" % held_s3(hair),
          refused_s3(said, 200_000) and hair.name not in SC_S3.objects and held_s3(hair) is None, said)
    reset_s3()
    with bare_s3():
        curves = bpy.data.hair_curves.new('H')
        curves.add_curves([10] * 4)
        hair = bpy.data.objects.new('H', curves)
        SC_S3.collection.objects.link(hair)
    mirror_s3()
    said = line_s3("bpy.data.hair_curves['H'].add_curves([1000] * 200)")
    check("…and `add_curves([1000] * 200)` on one in the scene is refused at 200,040, Blender at %s"
          % held_s3(hair), refused_s3(said, 200_040) and held_s3(hair) in (None, 40), said)
    reset_s3()
    with nohold_s3(), put_s3(budget, 'COUNTED_TYPES', tuple(t for t in budget.COUNTED_TYPES if t != 'CURVES')), \
            put_s3(gate, '_COLLECTIONS', {k: v for k, v in gate._COLLECTIONS.items() if k != 'Curves'}):
        control = line_s3(hair_new)
        hair = bpy.data.objects.get('H')
        built = held_s3(hair)
    check("control: with hair curves counted nowhere, as on 6d31b90, the line passed and Blender holds %s points"
          % format(built or 0, ','), control is None and built == 200_000, (control, built))

    # -- s.4 a long custom-property array a driver reads ---------------------------------
    def custom_case():
        reset_s3()
        a = cube_s3("A")
        m = array_s3(a, 2)
        e = bpy.data.objects.new("E", None)
        SC_S3.collection.objects.link(e)
        with bare_s3():
            e["arr"] = [2] * 70
            driver = m.driver_add("count").driver
            driver.type = 'SCRIPTED'
            var = driver.variables.new()
            var.name = "n"
            var.targets[0].id = e
            var.targets[0].data_path = '["arr"][0]'
            driver.expression = "n"
        mirror_s3()
        return a, line_s3("E = bpy.data.objects['E']\nE['arr'] = [20000] + [2] * 69\nE.update_tag()")

    a, said = custom_case()
    check("12s.4 a Count driven by E['arr'][0], a 70-element array: the script line writing 20,000 there is "
          "refused at 160,000, Blender at %s, the array put back (%s)" % (held_s3(a), bpy.data.objects['E']['arr'][0]),
          refused_s3(said, 160_000) and held_s3(a) == 16 and bpy.data.objects['E']['arr'][0] == 2
          and "70 values" in said, said)

    real_custom = gate._custom

    def skipping(struct):
        return {k: v for k, v in real_custom(struct).items() if not (isinstance(v, tuple) and len(v) > 64)}
    with nohold_s3(), put_s3(gate, '_custom', skipping):
        a, control = custom_case()
        built = held_s3(a)
    check("control: with arrays longer than 64 skipped, as on 6d31b90, the line passed and Blender built %s"
          % format(built or 0, ','), control is None and built == 160_000, (control, built))

    # -- s.5 a script's handlers ---------------------------------------------------------
    def handler_case(make):
        reset_s3()
        a = cube_s3("A")
        array_s3(a, 2)
        mirror_s3()
        handler = make()
        bpy.app.handlers.depsgraph_update_post.append(handler)
        try:
            said = line_s3("bpy.data.objects['A'].location.x = 1.0")
            built = held_s3(a)
        finally:
            while handler in bpy.app.handlers.depsgraph_update_post:
                bpy.app.handlers.depsgraph_update_post.remove(handler)
            gate.tidy_handlers()
        return said, built

    def marked():
        def handler(scene, *_):
            bpy.data.objects['A'].modifiers[0].count = 20000
        handler._blenderkit_gate = True
        return handler

    said, built = handler_case(marked)
    check("12s.5 a depsgraph_update_post handler given `_blenderkit_gate = True`, setting Count 20,000: refused "
          "at 160,000, Blender at %s" % built, refused_s3(said, 160_000) and built == 16, (said, built))
    def marked_again():
        # Its own code object: the control's handler is not one already
        # watched.
        def handler(scene, *_):
            bpy.data.objects['A'].modifiers[0].count = 20000 + 0
        handler._blenderkit_gate = True
        return handler
    with nohold_s3(), put_s3(gate, '_gate_own', lambda f: bool(getattr(f, '_blenderkit_gate', False))):
        control, built = handler_case(marked_again)
    check("control: with the gate's own known by that mark, as on 6d31b90, Blender built %s"
          % format(built or 0, ','), control is None and built == 160_000, (control, built))

    def unhooking():
        def handler(scene, *_):
            items = bpy.app.handlers.depsgraph_update_post
            i = items.index(handler)
            if i + 1 < len(items):
                items.remove(items[i + 1])
            bpy.data.objects['A'].modifiers[0].count = 20000
        return handler

    said, built = handler_case(unhooking)
    check("12s.5 a depsgraph_update_post handler that takes out the checkpoint after it, then sets Count 20,000: "
          "refused at 160,000, Blender at %s" % built, refused_s3(said, 160_000) and built == 16, (said, built))

    def unhooking_again():
        # Its own code object: the control's handler is not one already
        # watched.
        def handler(scene, *_):
            items = bpy.app.handlers.depsgraph_update_post
            i = items.index(handler)
            if i + 1 < len(items):
                items.remove(items[i + 1])
            bpy.data.objects['A'].modifiers[0].count = 20000 + 0
        return handler
    with nohold_s3(), put_s3(gate, '_monitor', lambda function: False):
        control, built = handler_case(unhooking_again)
    check("control: with no checkpoint at the handler's own return, as on 6d31b90, Blender built %s"
          % format(built or 0, ','), control is None and built == 160_000, (control, built))

    def plan_case(make):
        reset_s3()
        obj = cube_s3("Cube")
        target = bpy.data.objects.new("Target", None)
        SC_S3.collection.objects.link(target)
        target.location = (2.0, 0, 0)
        target.keyframe_insert("location", frame=1)
        target.keyframe_insert("location", frame=10)
        target.location = (0.0001, 0, 0)
        target.keyframe_insert("location", frame=30)
        target.location = (2.0, 0, 0)
        with bare_s3():
            SC_S3.frame_set(1)
        mirror_s3()
        anim_s3.frame_set(2)
        handler = make(obj, target)
        bpy.app.handlers.frame_change_post.append(handler)
        try:
            said_s3(lambda: anim_s3.frame_set(3))
        finally:
            while handler in bpy.app.handlers.frame_change_post:
                bpy.app.handlers.frame_change_post.remove(handler)
            gate.tidy_handlers()
        mirror_s3()
        said = said_s3(lambda: anim_s3.frame_set(30))
        return said, mesh_peak_s3()

    def adds_array(obj, target):
        def handler(scene, *_):
            items = bpy.app.handlers.frame_change_post
            i = items.index(handler)
            if i + 1 < len(items):
                items.remove(items[i + 1])
            if not obj.modifiers:
                m = obj.modifiers.new("Array", 'ARRAY')
                m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, target
                m.fit_type, m.fit_length = 'FIT_LENGTH', 2.0
        return handler

    said, built = plan_case(adds_array)
    check("12s.5 a frame_change_post handler that takes out its checkpoint and adds an Array reading a keyed empty "
          "at frame 3: frame 30 is refused (Blender at %s)" % built,
          said is not None and "Frame 30" in said and built <= 16, (said, built))

    def adds_array_again(obj, target):
        def handler(scene, *_):
            items = bpy.app.handlers.frame_change_post
            i = items.index(handler)
            if i + 1 < len(items):
                items.remove(items[i + 1])
            if not obj.modifiers:
                m = obj.modifiers.new("Array", 'ARRAY')
                m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, target
                m.fit_type, m.fit_length = 'FIT_LENGTH', 2.0 + 0.0
        return handler
    with nohold_s3(), put_s3(gate, '_monitor', lambda function: False):
        control, built = plan_case(adds_array_again)
    check("control: with no checkpoint at the handler's own return, frame 30 passed and Blender built %s"
          % format(built, ','), control is None and built == 160_008, (control, built))

    # The gate's own handler taken out of depsgraph_update_pre. Through the
    # entries a script is handed, it is put back first and the change priced;
    # through the base type's own `__getattribute__`, Blender builds it once
    # (still open) and the gate holds it right after (`_unpriced`).
    def cleared_case(entry):
        reset_s3()
        a = cube_s3("A")
        array_s3(a, 2)
        mirror_s3()
        said = line_s3("bpy.app.handlers.depsgraph_update_pre.clear()\n"
                       "bpy.data.objects['A'].modifiers[0].count = 20000\n" + entry)
        built = held_s3(a)
        gate.install()
        return said, built

    said, built = cleared_case("bpy.context.view_layer.update()\n")
    check("12s.5 a script line that clears depsgraph_update_pre, sets Count 20,000 and calls "
          "`view_layer.update()`: refused at 160,000 (the entry puts the gate's handler back), Blender at %s"
          % built, refused_s3(said, 160_000) and built == 16, (said, built))
    raw = "bpy.types.bpy_struct.__getattribute__(bpy.context.view_layer, 'update')()\n"
    said, built = cleared_case(raw)
    check("12s.5 the same through `bpy.types.bpy_struct.__getattribute__(view_layer, 'update')()`: Blender "
          "builds it once with no price before (still open), and the gate's post handler holds it at once: "
          "the Array hidden, Blender at %s, said in words" % built,
          said is not None and "taken out of depsgraph_update_pre" in said and built == 8, (said, built))
    with nohold_s3(), put_s3(gate, '_unpriced', lambda depsgraph: gate.install()):
        control, built = cleared_case(raw)
    check("control: with nothing looking after such an evaluation, as on 6d31b90, Blender holds %s"
          % format(built or 0, ','), control is None and built == 160_000, (control, built))

    # -- s.6 a frame's probe builds no other object's growth -----------------------------
    peak_s3 = [0]

    def watch_s3(scene, depsgraph=None, *_):
        dg = depsgraph or bpy.context.view_layer.depsgraph
        for obj in bpy.data.objects:
            if obj.type == 'MESH' and obj.name == 'X':
                ev = obj.evaluated_get(dg)
                if ev != obj:
                    peak_s3[0] = max(peak_s3[0], len(ev.data.vertices))
    # The gate's own, so the price's `_Busy` keeps it in its lists: it reads
    # what the probe's own evaluation builds.
    gate._OWN_FUNCTIONS = gate._OWN_FUNCTIONS + (watch_s3,)

    def probe_case(kind):
        reset_s3()
        bpy.ops.mesh.primitive_cube_add()
        x = bpy.context.object
        x.name = "X"
        m = x.modifiers.new("Array", 'ARRAY')
        m.count = 2
        m.keyframe_insert("count", frame=1)
        m.count = 20_000
        m.keyframe_insert("count", frame=10)
        with bare_s3():
            m.count = 2
        bpy.ops.mesh.primitive_cube_add(location=(5, 0, 0))
        y = bpy.context.object
        y.name = "Y"
        my = y.modifiers.new("Array", 'ARRAY')
        my.count = 2
        if kind == 'nla':
            my.keyframe_insert("count", frame=1)
            my.count = 3
            my.keyframe_insert("count", frame=10)
            ad = y.animation_data
            ad.nla_tracks.new().strips.new("s", 1, ad.action)
            ad.action = None
        else:
            curve = my.driver_add("count")
            curve.driver.type = 'SCRIPTED'
            var = curve.driver.variables.new()
            var.name = 'f'
            var.targets[0].id_type = 'SCENE'
            var.targets[0].id = SC_S3
            var.targets[0].data_path = 'frame_current'
            curve.driver.expression = '2 + 1/(10 - f)'
        with bare_s3():
            SC_S3.frame_set(1)
        mirror_s3()
        peak_s3[0] = 0
        bpy.app.handlers.depsgraph_update_post.append(watch_s3)
        bpy.app.handlers.frame_change_post.append(watch_s3)
        try:
            said = said_s3(lambda: anim_s3.frame_set(10))
        finally:
            for items in (bpy.app.handlers.depsgraph_update_post, bpy.app.handlers.frame_change_post):
                while watch_s3 in items:
                    items.remove(watch_s3)
        return said, peak_s3[0]

    for kind, words in (('nla', "an NLA strip"), ('driver', "a driver dividing by zero at frame 10")):
        said, peak = probe_case(kind)
        check("12s.6 X's Count keyed 2 → 20,000 and Y with %s: frame 10 is refused at 160,000 and the probe's own "
              "evaluation built X at most at %s" % (words, format(peak, ',')),
              refused_s3(said, 160_000) and peak <= 16, (said, peak))
    real_probe = budget.probe_values
    with nohold_s3(), put_s3(budget, 'probe_values', lambda t, wanted, extra=(): real_probe(t, wanted)):
        control, peak = probe_case('nla')
    check("control: with the probe hiding only what the probed blocks reach, as on 6d31b90, frame 10 was refused "
          "after the probe had built X at %s" % format(peak, ','), refused_s3(control) and peak == 160_000,
          (control, peak))

    # -- s.7 drivers that read each other ------------------------------------------------
    def cycle_case(kind):
        reset_s3()
        obj = cube_s3("Cube")
        obj["n"] = 2.0
        e = bpy.data.objects.new("E", None)
        SC_S3.collection.objects.link(e)
        if kind == 'parent':
            p = bpy.data.objects.new("P", None)
            SC_S3.collection.objects.link(p)
            e.parent = p
            p.location.x = 0.0
            p.keyframe_insert("location", frame=1)
            p.location.x = 1.0
            p.keyframe_insert("location", frame=40)
        else:
            e.rotation_euler.z = 0.0
            e.keyframe_insert("rotation_euler", frame=1)
            e.rotation_euler.z = 1.0
            e.keyframe_insert("rotation_euler", frame=40)
        curve = obj.modifiers.new("Array", 'ARRAY').driver_add("count")
        curve.driver.type = 'SCRIPTED'
        var = curve.driver.variables.new()
        var.name = 'n'
        var.targets[0].id = obj
        var.targets[0].data_path = '["n"]'
        var = curve.driver.variables.new()
        var.name = 'x'
        if kind == 'parent':
            var.type = 'TRANSFORMS'
            var.targets[0].id = e
            var.targets[0].transform_type = 'LOC_X'
            var.targets[0].transform_space = 'TRANSFORM_SPACE'
        elif kind == 'rotation':
            var.targets[0].id = e
            var.targets[0].data_path = 'location[0]'
        else:
            var.type = 'LOC_DIFF'
            var.targets[0].id = e
            var.targets[1].id = obj
        curve.driver.expression = 'n * 2 + x * 0'
        back = obj.driver_add('["n"]')
        back.driver.type = 'SCRIPTED'
        v = back.driver.variables.new()
        v.name = 'c'
        v.targets[0].id = obj
        v.targets[0].data_path = 'modifiers["Array"].count'
        back.driver.expression = 'c'
        with bare_s3():
            SC_S3.frame_set(1)
        mirror_s3()
        reached = []
        for f in range(2, 20):
            said = said_s3(lambda: anim_s3.frame_set(f))
            reached.append(mesh_peak_s3())
            if said is not None or reached[-1] > budget.BUDGET:
                return said, reached
        return None, reached

    for kind, words in (('parent', "a Transform Channel X of an empty whose parent is keyed"),
                        ('rotation', "an empty's X location, its rotation keyed"),
                        ('distance', "a Distance, which only Blender works out, to an empty whose rotation is keyed")):
        said, reached = cycle_case(kind)
        check("12s.7 Count = n × 2 + x × 0 and n = Count, x %s: frame 2 is refused in words, Blender at %s"
              % (words, format(reached[-1], ',')),
              said is not None and "reads a driver that reads it back" in said and len(reached) == 1
              and reached[-1] <= 32, (said, reached))
    with nohold_s3(), put_s3(budget, '_in_time', lambda block, seen: False):
        control, reached = cycle_case('parent')
    check("control: with a cycle refused only where it reads the frame or a keyed value, as on 6d31b90, the "
          "frames passed and Blender reached %s" % format(reached[-1], ','),
          control is None and reached[-1] > budget.BUDGET, (control, reached))
    real_cyclic = budget._cyclic
    with nohold_s3(), put_s3(budget, '_cyclic', lambda every, reads: real_cyclic(
            {k: v for k, v in every.items() if budget._driver_computable(v[0], v[1])}, reads)):
        control, reached = cycle_case('distance')
    check("control: with cycles looked for among the drivers worked out ahead only, the Distance's cycle passed "
          "and Blender reached %s" % format(reached[-1], ','),
          control is None and reached[-1] > budget.BUDGET, (control, reached))

    # -- s.8 renders, bakes and exports at render settings -------------------------------
    def render_fixture(scene):
        x = cube_s3("X", scene)
        x.data.uv_layers.new()       # a bake needs one
        array_s3(x, 2)
        sub = x.modifiers.new("Subdivision", 'SUBSURF')
        sub.levels, sub.render_levels = 0, 7
        scene.render.engine = 'CYCLES'
        scene.cycles.samples = 1
        scene.render.resolution_x = scene.render.resolution_y = 16
        cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
        scene.collection.objects.link(cam)
        scene.camera = cam
        return x

    reset_s3()
    render_fixture(bpy.data.scenes.new("S2"))
    mirror_s3()
    said = line_s3("bpy.ops.render.render(scene='S2')")
    check("12s.8 `render.render(scene='S2')`, S2's X at 196,612 vertices by its Render levels: refused in words",
          refused_s3(said, 196_612), said)
    real_render = budget.price_render
    with nohold_s3(), put_s3(budget, 'price_render', lambda scene=None, doing="Rendering": real_render(None, doing)):
        control = line_s3("bpy.ops.render.render(scene='S2')")
    check("control: with the render priced on the context's scene whatever the call names, as on 6d31b90, it "
          "rendered (%s)" % control, control is None, control)

    reset_s3()
    x = render_fixture(SC_S3)
    material = bpy.data.materials.new("M")
    image = bpy.data.images.new("Baked", 16, 16)
    tree = getattr(material, 'node_tree', None)
    if tree is None:
        material.use_nodes = True
        tree = material.node_tree
    node = tree.nodes.new('ShaderNodeTexImage')
    node.image = image
    tree.nodes.active = node
    x.data.materials.append(material)
    with bare_s3():
        for other in bpy.context.view_layer.objects:
            other.select_set(other == x)
        bpy.context.view_layer.objects.active = x
    mirror_s3()
    said = line_s3("bpy.ops.object.bake(type='NORMAL')")
    check("12s.8 `object.bake(type='NORMAL')` of X at 196,612 vertices by its Render levels: refused in words",
          said is not None and "Baking would give X 196,612" in said, said)
    path = os.path.join(WORK, "export-s3.obj")
    said = line_s3("bpy.ops.wm.obj_export(filepath=%r, export_eval_mode='DAG_EVAL_RENDER')" % path)
    check("…and `wm.obj_export(export_eval_mode='DAG_EVAL_RENDER')`, refused in words, nothing written (%s)"
          % os.path.exists(path), said is not None and "Exporting would give X 196,612" in said
          and not os.path.exists(path), said)
    with bare_s3():
        for other in bpy.context.view_layer.objects:
            other.select_set(other == x)
        bpy.context.view_layer.objects.active = x
    with nohold_s3(), put_s3(budget, '_RENDER_EVALUATIONS', {}):
        control = line_s3("bpy.ops.object.bake(type='NORMAL')")
    check("control: with a bake priced nowhere, as on 6d31b90, it baked (%s)" % control, control is None, control)

    # -- s.9 an image a Displace reads ------------------------------------------------
    def image_case(change):
        reset_s3()
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=4)
        s = bpy.context.object
        s.name = "S"
        image = bpy.data.images.new("I", 64, 64)
        image.pixels = [0.5] * (64 * 64 * 4)
        texture = bpy.data.textures.new("T", 'IMAGE')
        texture.image = image
        d = s.modifiers.new("Displace", 'DISPLACE')
        d.texture, d.strength, d.texture_coords = texture, 1.0, 'LOCAL'
        r = s.modifiers.new("Remesh", 'REMESH')
        r.mode, r.voxel_size = 'VOXEL', 0.02
        mirror_s3()
        import random
        random.seed(1)
        pixels = [0.0] * (64 * 64 * 4)
        for i in range(0, len(pixels), 4):
            v = random.random() * 3.0 if change else 0.5 + random.random() * 0.02
            pixels[i] = pixels[i + 1] = pixels[i + 2] = v
            pixels[i + 3] = 1.0
        bpy.app.driver_namespace['bk_s3_pixels'] = pixels
        said = line_s3("bpy.data.images['I'].pixels = bpy.app.driver_namespace['bk_s3_pixels']")
        # The next evaluation of the sphere's geometry, whatever asks for it.
        tagged = line_s3("bpy.data.objects['S'].data.update()")
        return said, tagged, held_s3(s)

    said, tagged, built = image_case(True)
    check("12s.9 a script line writing noise up to 3 into the pixels of the image a Displace reads (a Remesh "
          "after it): refused in words, and the sphere's next evaluation builds %s" % format(built, ','),
          refused_s3(said) and "The image I" in said and built <= budget.BUDGET, (said, tagged, built))
    with nohold_s3(), put_s3(gate, '_image_structs', lambda layer, out: None):
        control, tagged, built = image_case(True)
    check("control: with images looked for nowhere, as on 6d31b90, the line passed and the next evaluation "
          "built %s" % format(built, ','), control is None and tagged is None and built > budget.BUDGET,
          (control, tagged, built))

    # -- s.10 Grease Pencil Line Art --------------------------------------------------
    def lineart_case(count):
        reset_s3()
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=5)
        ico = bpy.context.object
        ico.name = "Ico"
        cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
        SC_S3.collection.objects.link(cam)
        SC_S3.camera = cam
        cam.location, cam.rotation_euler = (0, -6, 0), (math.pi / 2, 0, 0)
        with bare_s3():
            bpy.ops.object.grease_pencil_add(type='LINEART_OBJECT')
        gp = bpy.context.object
        gp.name = "LineArt"
        for m in gp.modifiers:
            if m.type == 'LINEART':
                m.source_type, m.source_object = 'OBJECT', ico
                m.use_crease, m.crease_threshold = True, math.pi
        mirror_s3()
        drawn = held_s3(gp)
        said = line_s3("m = bpy.data.objects['LineArt'].modifiers.new('Array', 'GREASE_PENCIL_ARRAY')\n"
                       "m.count = %d" % count)
        return drawn, said, held_s3(gp)

    drawn, said, built = lineart_case(40)
    check("12s.10 Line Art of %s points (an icosphere of 7,680 edges, Crease 180°), then a Grease Pencil Array of "
          "40 from a script line: refused in words, Blender at %s" % (format(drawn, ','), format(built, ',')),
          refused_s3(said) and built == drawn, (said, drawn, built))
    with nohold_s3(), put_s3(budget, '_GROWTH', dict(budget._GROWTH, LINEART=budget._keep)):
        drawn, control, built = lineart_case(40)
    check("control: with Line Art counted as keeping what it is given, as on 6d31b90, the line passed and "
          "Blender built %s points" % format(built, ','), control is None and built > budget.BUDGET,
          (control, built))
    drawn, said, built = lineart_case(2)
    check("an Array of 2 passes (Blender at %s, counted at most %s)" % (format(built, ','), "51,200"),
          said is None and built == 2 * drawn, (said, built))

    # -- s.11 a file a script writes and loads -----------------------------------------
    crafted = os.path.join(WORK, "crafted-s3.blend")
    session_file = os.path.join(WORK, "session-s3.blend")

    def back_to_session():
        """The file each load case started from, opened again as the app
        opens a file, so what follows runs in a scene of its own again."""
        global SC_S3
        with gate.opening():
            bpy.ops.wm.open_mainfile(filepath=session_file, load_ui=False)
        SC_S3 = bpy.context.scene
        gate.take_refusals()

    def load_case(own=False):
        reset_s3()
        cube_s3("Here")
        mirror_s3()
        if os.path.exists(crafted):
            os.remove(crafted)
        source = ("import bmesh\nme = bpy.data.meshes.new('XM')\nbm = bmesh.new()\n"
                  "bmesh.ops.create_cube(bm, size=1)\nbm.to_mesh(me)\nbm.free()\n"
                  "x = bpy.data.objects.new('X', me)\nx.modifiers.new('Array', 'ARRAY').count = 20000\n"
                  "s = bpy.data.scenes.new('Crafted')\ns.collection.objects.link(x)\n"
                  "bpy.data.libraries.write(%r, {s, x, me})\n" % crafted)
        if own:
            source += ("import _blenderkit_gate\nwith _blenderkit_gate.opening():\n"
                       "    bpy.ops.wm.open_mainfile(filepath=%r, load_ui=False)\n" % crafted)
        else:
            source += "bpy.ops.wm.open_mainfile(filepath=%r, load_ui=False)\n" % crafted
        bpy.ops.wm.save_as_mainfile(filepath=session_file, copy=True)
        said = line_s3(source)
        x = bpy.data.objects.get('X')
        built = held_s3(x) if x is not None else None
        back_to_session()
        return said, built

    said, built = load_case()
    check("12s.11 a script line writing a scene with X under an Array of 20,000 (`bpy.data.libraries.write`) and "
          "opening it: refused at the line at 160,000, X's Array held, Blender at %s" % built,
          refused_s3(said, 160_000) and built == 8, (said, built))
    with nohold_s3(), put_s3(gate, '_price_script_load', lambda layer: None):
        control, built = load_case()
    check("control: with a script's load priced nowhere, as on 6d31b90, Blender built %s" % format(built or 0, ','),
          control is None and built == 160_000, (control, built))
    said, built = load_case(own=True)
    check("the app's own load of a file (the Open sheet, `_blenderkit_gate.opening`) is Blender's to evaluate "
          "as saved: not priced (Blender at %s)" % format(built or 0, ','), said is None and built == 160_000,
          (said, built))
    reset_s3()
    os.remove(crafted)

    # -- s.12 ordinary edits pass ------------------------------------------------------
    reset_s3()
    s2 = bpy.data.scenes.new("S2")
    x = cube_s3("X", s2)
    array_s3(x, 20)
    mirror_s3()
    said = line_s3("bpy.context.scene.background_set = bpy.data.scenes['S2']")
    check("12s.12 a Background Scene of 160 vertices passes, Blender at %s" % held_s3(x),
          said is None and held_s3(x) == 160, said)
    reset_s3()
    said = line_s3("c = bpy.data.hair_curves.new('H')\nc.add_curves([10] * 100)\n"
                   "bpy.context.scene.collection.objects.link(bpy.data.objects.new('H', c))")
    check("hair curves of 1,000 points pass, Blender at %s" % held_s3(bpy.data.objects['H']),
          said is None and held_s3(bpy.data.objects['H']) == 1000, said)
    said, tagged, built = image_case(False)
    check("a small image change passes (Blender at %s)" % format(built, ','),
          said is None and tagged is None and built <= budget.BUDGET, (said, tagged, built))

    def small(scene, *_):
        bpy.data.objects['A'].modifiers[0].count = 3

    def small_case():
        return small
    said, built = handler_case(small_case)
    check("a handler setting Count 3 passes, Blender at %s" % built, said is None and built == 24, (said, built))
    reset_s3()
    s2 = bpy.data.scenes.new("S2")
    x = cube_s3("X", s2)
    array_s3(x, 2)
    s2.render.engine = 'CYCLES'
    s2.cycles.samples = 1
    s2.render.resolution_x = s2.render.resolution_y = 16
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    s2.collection.objects.link(cam)
    s2.camera = cam
    said = line_s3("bpy.ops.render.render(scene='S2')")
    check("a render of a light scene S2 passes (%s)" % said, said is None, said)
finally:
    budget.BUDGET = kept_budget_s3
    reset_s3()
