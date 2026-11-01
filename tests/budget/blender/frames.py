"""Part 11 of the vertex budget's Blender check: frame changes and a legal
Boolean, priced in proportion to what changes (October 21, fix round 2).

Run from verify.py, in its globals (`check`, `clear`, `counts`, `activate`,
`gate_off`, `budget`, `gate`, `sync`). Round 4's first fix round priced every
frame of the app's timeline from every F-curve in the scene (53–54 ms a
frame with 3,000 keyed empties, which nothing counted reads), and refined a
legal Boolean's count through nine evaluations of its stacks (Add Modifier ▸
Weld: 11.0–12.3 s against Blender's 0.68). Here:

  11.1 the frame's price on 3,000 keyed empties stays under FRAME_BOUND_MS,
       with the plan made once; the control, every F-curve priced as before,
       is over it;
  11.2 a frame that does change a priced input is still priced, and refused
       past the budget, before Blender evaluates it — an Array's Count, a
       Subdivision's Levels, a shape key's Value, a driver of a Count, an
       offset object's place and its parent's — each with the bare frame as
       its control, among the 3,000 empties for the first;
  11.3 the plan follows the scene: a modifier added after it is made, by a
       script line or by a frame handler, is priced on the next frame (the
       control: the plan kept as it was);
  11.4 the mesh reads the price makes through attributes are Blender's own
       numbers, element for element;
  11.5 a legal Boolean of two 400 × 400 grids under a Solidify is priced in
       at most PRICE_FACTOR times Blender's own evaluation of the change, from
       at most two of Blender's evaluations, and the light count it passes
       at is at least Blender's.

Budgets are lowered (to 100,000) where a control builds the count, so the
controls stay small. Nothing here opens a window, a browser or another app.
"""
import bpy, math, statistics, time

anim = sys.modules["_blenderkit_anim"]
sc = bpy.context.scene
# The frame's price on 3,000 keyed empties, in ms. Measured with the plan in
# desktop 5.2.1: 0.0039 to 0.0044 ms a frame at a load average of 545 (a
# look at the depsgraph's waiting list and at the plan), against 49.6 to
# 51.8 ms for every F-curve priced. Reading a single attribute of each of
# 3,000 objects takes more than a millisecond (4 attributes each: 3.9 ms at
# a load average of 160), so any return to per-object work fails this.
FRAME_BOUND_MS = 0.5
# A legal Boolean's price against Blender's own evaluation of the same change.
PRICE_FACTOR = 3.0
# A frame that changes one keyed Count among 3,000 keyed empties: the price
# judges the one object, 0.10 ms measured. Walking every object in the file
# for what it reaches (`affected`) took 8.15 ms there: the bound is 20 times
# the first and fails a return to the walk.
CHANGED_BOUND_MS = 2.0


class lowered_to:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        self.kept = budget.BUDGET
        budget.BUDGET = self.value

    def __exit__(self, *exc):
        budget.BUDGET = self.kept


def said_of(fn):
    try:
        fn()
    except RuntimeError as error:
        return str(error)
    return None


def blender_count(obj):
    with gate_off():
        return counts(obj)[0]


def keyed_empties(n):
    for i in range(n):
        e = bpy.data.objects.new("Keyed.%04d" % i, None)
        sc.collection.objects.link(e)
        e.location = (i % 60, i // 60, 0)
        e.keyframe_insert("location", frame=1)
        e.location.z = 5
        e.keyframe_insert("location", frame=10)


class counting_builds:
    def __enter__(self):
        self.n = 0
        self.real = budget._plan_build

        def build(scene):
            self.n += 1
            return self.real(scene)

        budget._plan_build = build
        return self

    def __exit__(self, *exc):
        budget._plan_build = self.real


def frame_costs(frames):
    costs = []
    for f in frames:
        t = time.perf_counter()
        budget.price_frame(f)
        costs.append((time.perf_counter() - t) * 1000)
    return costs


# Cubes are added at the origin, not at the 3D cursor: an earlier part leaves
# the cursor elsewhere (Extrude to Cursor), and an offset object's fixture
# reads where the cube is. Run after part 9, cubes at the cursor put the
# offset object 2 m and more away and made only 8 vertices.


def reset_frame():
    with gate_off():
        sc.frame_set(1)
        bpy.context.view_layer.update()


print("\n11. frame changes and a legal Boolean, priced in proportion to what changes")
clear()
reset_frame()
keyed_empties(3000)
reset_frame()
sync.sync()
anim.frame_set(2)
with counting_builds() as built:
    costs = frame_costs(list(range(2, 34)))
plan = budget.frame_plan()
median, worst = statistics.median(costs), max(costs)
print("        3,000 keyed empties: the frame's price %.4f ms (median of 32), %.4f at most; "
      "the plan evaluates %d F-curves and %d drivers, %d left out" % (
          median, worst, sum(len(e) for _, e in plan.curves), len(plan.drivers), plan.left_out))
check("11.1 with 3,000 keyed empties the frame's price is under %.1f ms (median %.4f ms)" % (FRAME_BOUND_MS, median),
      median < FRAME_BOUND_MS, costs)
check("and the plan is made once, not for each frame (%d made in 32 frames)" % built.n, built.n == 0, built.n)
check("and it evaluates nothing: no empty is read by anything counted", not plan.live,
      (plan.curves, plan.drivers))
real_changes = budget._frame_changes
budget._frame_changes = lambda t: (budget._animated_all(t), None)
try:
    control = statistics.median(frame_costs(list(range(2, 10))))
finally:
    budget._frame_changes = real_changes
check("control: with every F-curve priced, as round 4's fix round did, it is over the bound (%.1f ms)" % control,
      control >= FRAME_BOUND_MS, control)
t = time.perf_counter()
for f in range(2, 10):
    anim.frame_set(f)
whole = (time.perf_counter() - t) / 8 * 1000
with gate_off():
    t = time.perf_counter()
    for f in range(2, 10):
        sc.frame_set(f)
    bare = (time.perf_counter() - t) / 8 * 1000
print("        and a whole frame change through the app %.1f ms, of which Blender's frame_set %.1f ms" % (whole, bare))

# 11.2 among the empties, one cube whose Array's Count is keyed
with lowered_to(100_000):
    reset_frame()
    bpy.ops.mesh.primitive_cube_add(location=(0, -10, 0))
    a = bpy.context.object
    a.name = "Counted"
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.keyframe_insert("count", frame=10)
    m.count = 20_000
    m.keyframe_insert("count", frame=40)
    m.count = 2
    reset_frame()
    sync.sync()
    anim.frame_set(2)
    held = statistics.median(frame_costs(list(range(2, 10))))
    plan = budget.frame_plan()
    check("11.2 among the 3,000 empties, one keyed Count is all the plan evaluates (%s)"
          % [e.path for _, entries in plan.curves for e in entries],
          [e.path for _, entries in plan.curves for e in entries] == ['modifiers["Array"].count'], plan.curves)
    check("and frames where it holds its value are not priced (%.4f ms, under the bound)" % held,
          held < FRAME_BOUND_MS, held)
    changing = statistics.median(frame_costs(list(range(11, 19))))
    check("and frames where it changes are priced in under %.0f ms among the 3,000 objects (%.2f ms): only "
          "what the plan says it reaches is judged" % (CHANGED_BOUND_MS, changing), changing < CHANGED_BOUND_MS,
          changing)
    real_judge = budget._judge_changes

    def judged_everything(*args, **kwargs):
        kwargs['reached'] = None
        return real_judge(*args, **kwargs)

    budget._judge_changes = judged_everything
    try:
        walked = statistics.median(frame_costs(list(range(11, 19))))
    finally:
        budget._judge_changes = real_judge
    check("control: with every object in the file walked for what it reaches (`affected`), as a change "
          "elsewhere is, they take %.2f ms" % walked, walked > changing, (walked, changing))
    said = said_of(lambda: anim.frame_set(40))
    check("frame 40, where it is 20,000, is refused before Blender evaluates it (the frame stays %d)"
          % sc.frame_current, said is not None and "160,000" in said and sc.frame_current == 2, said)
    said = said_of(lambda: anim.frame_set(20))
    check("and frame 20 passes (%s)" % format(blender_count(a), ','), said is None and sc.frame_current == 20, said)
    with gate_off():
        sc.frame_set(40)
        control = counts(a)[0]
    check("control: Blender's own frame 40 makes %s" % format(control, ','), control == 160_000, control)
    reset_frame()

    def keyed_fixture(build, frame, label, words=None):
        clear()
        reset_frame()
        obj = build()
        reset_frame()
        sync.sync()
        said = said_of(lambda: anim.frame_set(frame))
        check("%s: frame %d is refused before Blender evaluates it (the frame stays %d)"
              % (label, frame, sc.frame_current),
              said is not None and "Frame %d" % frame in said and sc.frame_current == 1
              and (words is None or words in said), said)
        before = blender_count(obj)
        with gate_off():
            sc.frame_set(frame)
            control = counts(obj)[0]
        check("control: Blender's own frame %d makes %s (from %s)" % (frame, format(control, ','), format(before, ',')),
              control > budget.BUDGET, control)
        reset_frame()
        return obj

    def subdivision():
        bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
        obj = bpy.context.object
        sd = obj.modifiers.new("Subdivision", 'SUBSURF')
        sd.levels = 1
        sd.keyframe_insert("levels", frame=1)
        sd.levels = 8
        sd.keyframe_insert("levels", frame=20)
        sd.levels = 1
        return obj

    keyed_fixture(subdivision, 20, "a keyed Subdivision's Levels, 1 to 8")

    def shape_key():
        bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
        obj = bpy.context.object
        obj.shape_key_add(name="Basis")
        thin = obj.shape_key_add(name="Thin")
        for point in thin.data:
            point.co.x *= 0.00005
        arr = obj.modifiers.new("Array", 'ARRAY')
        arr.fit_type = 'FIT_LENGTH'
        arr.fit_length = 2.0
        thin.value = 0.0
        thin.keyframe_insert("value", frame=1)
        thin.value = 1.0
        thin.keyframe_insert("value", frame=10)
        thin.value = 0.0
        return obj

    keyed_fixture(shape_key, 10, "a shape key's Value keyed to 1 under an Array fitted to 2 m")

    def driven():
        bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
        obj = bpy.context.object
        arr = obj.modifiers.new("Array", 'ARRAY')
        source = bpy.data.objects.new("Source", None)
        sc.collection.objects.link(source)
        source["n"] = 2.0
        source.keyframe_insert('["n"]', frame=1)
        source["n"] = 20_000.0
        source.keyframe_insert('["n"]', frame=50)
        source["n"] = 2.0
        curve = arr.driver_add("count")
        curve.driver.type = 'SUM'
        var = curve.driver.variables.new()
        var.type = 'SINGLE_PROP'
        var.targets[0].id = source
        var.targets[0].data_path = '["n"]'
        return obj

    keyed_fixture(driven, 50, "an Array's Count driven by an empty's keyed property")
    plan = budget.frame_plan()
    check("and the plan holds the driver and the F-curve it reads",
          [x.path for _, x in plan.drivers] == ['modifiers["Array"].count']
          and [e.path for _, entries in plan.curves for e in entries] == ['["n"]'], (plan.drivers, plan.curves))

    def fitted_to_offset(parented=False):
        bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
        obj = bpy.context.object
        target = bpy.data.objects.new("Offset", None)
        sc.collection.objects.link(target)
        target.location = (2.0, 0, 0)
        arr = obj.modifiers.new("Array", 'ARRAY')
        arr.use_relative_offset = False
        arr.use_object_offset = True
        arr.offset_object = target
        arr.fit_type = 'FIT_LENGTH'
        arr.fit_length = 2.0
        keyed = target
        if parented:
            holder = bpy.data.objects.new("Holder", None)
            sc.collection.objects.link(holder)
            target.parent = holder
            keyed = holder
            keyed.location = (0, 0, 0)
            keyed.keyframe_insert("location", frame=1)
            keyed.location = (-1.9999, 0, 0)
            keyed.keyframe_insert("location", frame=30)
            keyed.location = (0, 0, 0)
        else:
            keyed.keyframe_insert("location", frame=1)
            keyed.location = (0.0001, 0, 0)
            keyed.keyframe_insert("location", frame=30)
            keyed.location = (2.0, 0, 0)
        return obj

    keyed_fixture(fitted_to_offset, 30, "an Array's offset object keyed to 0.0001 m away")
    keyed_fixture(lambda: fitted_to_offset(True), 30, "the parent of an Array's offset object, keyed")

    # 11.3 the plan follows the scene
    def follows(add, label):
        clear()
        reset_frame()
        bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
        obj = bpy.context.object
        target = bpy.data.objects.new("Target", None)
        sc.collection.objects.link(target)
        target.location = (2.0, 0, 0)
        target.keyframe_insert("location", frame=1)
        target.keyframe_insert("location", frame=10)
        target.location = (0.0001, 0, 0)
        target.keyframe_insert("location", frame=30)
        target.location = (2.0, 0, 0)
        reset_frame()
        sync.sync()
        anim.frame_set(2)
        made = budget.frame_plan()
        nothing = not made.live
        add(obj, target)
        said = said_of(lambda: anim.frame_set(30))
        return nothing, said

    def by_script(obj, target):
        arr = obj.modifiers.new("Array", 'ARRAY')
        arr.use_relative_offset = False
        arr.use_object_offset = True
        arr.offset_object = target
        arr.fit_type = 'FIT_LENGTH'
        arr.fit_length = 2.0
        sync.sync()

    nothing, said = follows(by_script, "script")
    check("11.3 a plan made while nothing read the keyed empty", nothing)
    check("and an Array that reads it, added by a script line after: the next frame is priced and refused",
          said is not None and "Frame 30" in said and sc.frame_current == 2, said)

    def in_handler(obj, target):
        def handler(scene, *_):
            if not obj.modifiers:
                by_script_bare(obj, target)

        bpy.app.handlers.frame_change_pre.append(handler)
        try:
            anim.frame_set(3)
        finally:
            bpy.app.handlers.frame_change_pre.remove(handler)

    def by_script_bare(obj, target):
        arr = obj.modifiers.new("Array", 'ARRAY')
        arr.use_relative_offset = False
        arr.use_object_offset = True
        arr.offset_object = target
        arr.fit_type = 'FIT_LENGTH'
        arr.fit_length = 2.0

    nothing, said = follows(in_handler, "handler")
    check("and one added by a frame handler during a frame: the frame after is priced and refused",
          nothing and said is not None and "Frame 30" in said and sc.frame_current == 3, said)
    real_pending = budget._pending
    real_note = budget.note_pending

    def stale_after_frames():
        # The control: the plan hears nothing of what is waiting after a frame
        # handler (`anim.frame_set`'s last handler) or at the frame's price,
        # nor of what the gate found (`note_pending`).
        budget._pending = lambda: False
        budget.note_pending = lambda found: None
        try:
            return follows(in_handler, "handler")
        finally:
            budget._pending = real_pending
            budget.note_pending = real_note

    nothing, said = stale_after_frames()
    check("control: with the plan kept as it was made, that frame passes (%s) and Blender makes %s"
          % (said, format(max(counts(o)[0] for o in sc.objects if o.type == 'MESH'), ',')),
          said is None and max(counts(o)[0] for o in sc.objects if o.type == 'MESH') > budget.BUDGET, said)
    reset_frame()

# 11.4 the attribute reads
clear()
import numpy as np


def slow_measures(mesh):
    n, f, c, e = len(mesh.vertices), len(mesh.polygons), len(mesh.loops), len(mesh.edges)
    co = np.empty(3 * n, np.float32)
    mesh.vertices.foreach_get('co', co)
    totals = np.empty(f, np.int32)
    mesh.polygons.foreach_get('loop_total', totals)
    normals = np.empty(3 * f, np.float32)
    mesh.polygons.foreach_get('normal', normals)
    corner_verts = np.empty(c, np.int32)
    mesh.loops.foreach_get('vertex_index', corner_verts)
    corner_edges = np.empty(c, np.int32)
    mesh.loops.foreach_get('edge_index', corner_edges)
    ends = np.empty(2 * e, np.int32)
    mesh.edges.foreach_get('vertices', ends)
    mesh.calc_loop_triangles()
    t = len(mesh.loop_triangles)
    areas = np.empty(t, np.float32)
    faces = np.empty(t, np.int32)
    mesh.loop_triangles.foreach_get('area', areas)
    mesh.loop_triangles.foreach_get('polygon_index', faces)
    return dict(co=co.reshape(-1, 3), totals=totals, normals=normals.reshape(-1, 3), corner_verts=corner_verts,
                corner_edges=corner_edges, ends=ends.reshape(-1, 2),
                areas=np.bincount(faces, weights=areas.astype(np.float64), minlength=f))


def measured(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        return budget.Measures(mesh), slow_measures(mesh)
    finally:
        evaluated.to_mesh_clear()


shapes = []
bpy.ops.mesh.primitive_grid_add(x_subdivisions=40, y_subdivisions=30)
shapes.append(bpy.context.object)
bpy.ops.mesh.primitive_monkey_add(location=(5, 0, 0))
shapes.append(bpy.context.object)
bpy.ops.mesh.primitive_circle_add(vertices=37, fill_type='NGON', location=(10, 0, 0))
shapes.append(bpy.context.object)
bpy.ops.mesh.primitive_cylinder_add(vertices=11, end_fill_type='TRIFAN', location=(15, 0, 0))
c = bpy.context.object
c.modifiers.new("Solidify", 'SOLIDIFY')
shapes.append(c)
bpy.ops.mesh.primitive_uv_sphere_add(location=(20, 0, 0))
s = bpy.context.object
s.modifiers.new("Triangulate", 'TRIANGULATE')
shapes.append(s)
same = []
for obj in shapes:
    fast, slow = measured(obj)
    for name in ('co', 'totals', 'normals', 'corner_verts', 'corner_edges', 'ends', 'areas'):
        a, b = getattr(fast, name), slow[name]
        # Blender's two face normals (`polygon_normals`, cached, and each
        # polygon's `normal`, worked out when read) differ in the last bits:
        # at most 4.5e-6 on the triangulated sphere, 1.7e-7 on the cylinder.
        tolerance = 1e-5 if name == 'normals' else 1e-7
        same.append((obj.name, name, a.shape == b.shape and bool(np.allclose(a, b, rtol=1e-6, atol=tolerance))))
check("11.4 the price's attribute reads are Blender's own numbers on a grid, Suzanne, a 37-gon, a solidified "
      "cylinder of triangle fans and a triangulated sphere (%d arrays)" % len(same),
      all(ok for _, _, ok in same), [x for x in same if not x[2]])
fast, slow = measured(shapes[1])
check("control: the comparison tells two reads apart (Suzanne's corners' edges against their vertices)",
      not np.allclose(fast.corner_edges, slow['corner_verts']))

# 11.5 a legal Boolean
clear()
reset_frame()


def grid400(name, location):
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=400, y_subdivisions=400, size=2, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.2
    return obj


a = grid400("A", (0, 0, 0))
b = grid400("B", (0.3, 0.2, 0.05))
boolean = a.modifiers.new("Boolean", 'BOOLEAN')
boolean.operation = 'UNION'
boolean.solver = 'MANIFOLD'
boolean.object = b
bpy.context.view_layer.update()
held = blender_count(a)


def blender_time(do, undo):
    best = None
    with gate_off():
        for _ in range(2):
            do()
            t = time.perf_counter()
            bpy.context.view_layer.update()
            took = time.perf_counter() - t
            undo()
            bpy.context.view_layer.update()
            best = took if best is None else min(best, took)
    return best


evaluations = {'n': 0}
real_once = budget._evaluate_once


def counting_once(*args, **kwargs):
    evaluations['n'] += 1
    return real_once(*args, **kwargs)


def price_time(fn):
    best = None
    for _ in range(2):
        evaluations['n'] = 0
        t = time.perf_counter()
        said = said_of(fn)
        took = time.perf_counter() - t
        if best is None or took < best[0]:
            best = (took, evaluations['n'], said)
    return best


def add_weld():
    a.modifiers.new("Weld", 'WELD')


def remove_weld():
    a.modifiers.remove(a.modifiers["Weld"])


cases = (
    ("Add Modifier ▸ Weld", lambda: budget.price_add('WELD', obj=a), add_weld, remove_weld),
    ("the Data API row's Location", lambda: budget.price(a, 'location', (0.01, 0, 0)),
     lambda: setattr(a, 'location', (0.01, 0, 0)), lambda: setattr(a, 'location', (0, 0, 0))),
    ("the Solidify row's Thickness", lambda: budget.price(a.modifiers['Solidify'], 'thickness', 0.21),
     lambda: setattr(a.modifiers['Solidify'], 'thickness', 0.21),
     lambda: setattr(a.modifiers['Solidify'], 'thickness', 0.2)),
    ("a gizmo Move's commit", lambda: budget.price_object_moves('transform.translate', {'value': (0.01, 0, 0)}),
     lambda: setattr(a, 'location', (0.01, 0, 0)), lambda: setattr(a, 'location', (0, 0, 0))),
)
activate(a)
budget._evaluate_once = counting_once
try:
    for label, price, do, undo in cases:
        own = blender_time(do, undo)
        took, asked, said = price_time(price)
        print("        %s: priced in %.2f s from %d of Blender's evaluations; Blender's own evaluation %.2f s"
              % (label, took, asked, own))
        check("11.5 %s on a legal Boolean (%s vertices) passes in at most %.0f× Blender's own evaluation "
              "(%.2f s against %.2f s), from at most 2 evaluations (%d)"
              % (label, format(held, ','), PRICE_FACTOR, took, own, asked),
              said is None and took <= PRICE_FACTOR * own + 0.1 and asked <= 2, (took, own, asked, said))
    s = budget.Prices()
    try:
        s.change(a, 'location', (0.01, 0, 0))
        light = budget._final(a, s, light=True).final.v
    finally:
        s.close()
    with gate_off():
        a.location = (0.01, 0, 0)
        moved = counts(a)[0]
        a.location = (0, 0, 0)
        bpy.context.view_layer.update()
    check("and the light count it passes at is at least Blender's (%s against %s)"
          % (format(light, ','), format(moved, ',')), light >= moved, (light, moved))
    # Where the light count is past the budget the count is made as before
    # this round: Blender is asked only inside the budget, so at a budget
    # between Blender's count and the bound, the bound stands, as it did.
    with lowered_to(int(held * 1.2)):
        said = said_of(lambda: budget.price(a, 'location', (0.01, 0, 0)))
        s = budget.Prices()
        try:
            s.change(a, 'location', (0.01, 0, 0))
            exact = budget._final(a, s).final.v
        finally:
            s.close()
        check("with the budget at %s, past the light count, the Location is judged on the exact walk's count "
              "(%s), as before this round" % (format(budget.BUDGET, ','), format(exact, ',')),
              said is not None and format(exact, ',') in said and light > budget.BUDGET, (said, exact, light))
    with lowered_to(int(light * 1.05)):
        said = said_of(lambda: budget.price(a, 'location', (0.01, 0, 0)))
        check("and with the budget at %s, above the light count, it passes" % format(budget.BUDGET, ','), said is None, said)
    said = said_of(lambda: budget.price_add('SUBSURF', obj=a, settings={'levels': 2}))
    check("and Add Modifier ▸ Subdivision Surface at level 2 on it is refused", said is not None, said)
    real_clean = budget._clean_through
    real_final = budget._final
    budget._clean_through = lambda *args: False
    budget._final = lambda obj, s, sculpt=None, light=False: real_final(obj, s, sculpt)
    try:
        evaluations['n'] = 0
        said_of(lambda: budget.price_add('WELD', obj=a))
        control = evaluations['n']
    finally:
        budget._clean_through = real_clean
        budget._final = real_final
    check("control: with every count made exact and the stack as Blender holds it not reused, Add Modifier ▸ "
          "Weld asks for %d evaluations" % control, control > 2, control)
finally:
    budget._evaluate_once = real_once
a.keyframe_insert("location", frame=1)
a.location.x = 0.05
a.keyframe_insert("location", frame=10)
a.location.x = 0.0
reset_frame()
sync.sync()
own = blender_time(lambda: setattr(a, 'location', (0.005, 0, 0)), lambda: setattr(a, 'location', (0, 0, 0)))
budget.price_frame(4)
t = time.perf_counter()
said = said_of(lambda: budget.price_frame(5))
took = time.perf_counter() - t
check("11.5 with A's Location keyed, a frame's price takes at most %.0f× Blender's own evaluation (%.2f s against %.2f s)"
      % (PRICE_FACTOR, took, own), said is None and took <= PRICE_FACTOR * own + 0.1, (took, own, said))
with counting_builds() as built:
    said_of(lambda: budget.price_frame(6))
    said_of(lambda: budget.price_frame(7))
check("and the copies that price evaluated leave nothing for the next frame to take as a change: the plan is "
      "not made again (%d times in 2 frames)" % built.n, built.n == 0, built.n)
clear()
reset_frame()
