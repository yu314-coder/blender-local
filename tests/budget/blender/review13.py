"""Part 13 of the vertex budget's Blender check: the review of "frame changes
and a legal Boolean, priced in proportion to what changes" answered
(October 21, fix round 2).

Run from verify.py, in its globals (`check`, `clear`, `counts`, `activate`,
`gate_off`, `budget`, `gate`, `sync`). Every case is the review's own,
measured in desktop 5.2.1 with the app's context, and each check has a
control that builds what the review measured or puts the old behaviour back:

  13.1 a Boolean with faces in one plane: the light count is at least
       Blender's for Manifold, Exact and Fast, B turned 30° too, and the
       Data API row's Location is refused at a budget between the old light
       count and Blender's;
  13.2 a Boolean with Self Intersection: the same, Array Count 1 → 2;
  13.3 a collection's operand lowered through another: the light and exact
       counts are at least Blender's, and the row is refused;
  13.4 the frame plan follows what a frame_change_post handler adds, and
       what a refused script line leaves;
  13.5 drivers: the scene's frame, a value read through another path
       (`parent.location[0]`, `modifiers[0].count`), drivers that read
       each other;
  13.6 NLA strips and the active action blended over them, Time Stretching,
       keyed Geometry Nodes inputs and a node group's own keyed socket;
  13.7 a rig of 300 keyed bones under an Armature costs a frame nothing,
       and under a Remesh its channels are priced; a Count keyed to 0 is
       not priced on every frame; a post handler writing a place every frame
       does not make the plan again; real frames through `anim.frame_set`
       make the plan once.

Budgets are lowered (to 100,000 or between two counts) where a control
builds the count, so the controls stay small. Nothing here opens a window, a
browser or another app.
"""
import bpy, math, statistics, time

anim = sys.modules["_blenderkit_anim"]
sc = bpy.context.scene
# A frame's price with nothing priced in it, as 11.1 bounds it.
FRAME_BOUND_MS = 0.5


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


def reset_frame():
    with gate_off():
        sc.frame_set(1)
        bpy.context.view_layer.update()


def clear_all():
    clear()
    for collection in (bpy.data.actions, bpy.data.node_groups, bpy.data.armatures, bpy.data.collections):
        for block in list(collection):
            if block.users == 0 or collection is bpy.data.collections:
                try:
                    collection.remove(block)
                except (RuntimeError, ReferenceError):
                    pass
    sc.render.frame_map_old = 100
    sc.render.frame_map_new = 100
    reset_frame()


def cube(name="Cube", location=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    return obj


def mesh_max():
    with gate_off():
        return max([counts(o)[0] for o in sc.objects if o.type == 'MESH'] or [0])


class off:
    """A function of the budget put back to `value` for a control."""

    def __init__(self, name, value):
        self.name, self.value = name, value

    def __enter__(self):
        self.kept = getattr(budget, self.name)
        setattr(budget, self.name, self.value)

    def __exit__(self, *exc):
        setattr(budget, self.name, self.kept)


def light_walk(target, owner, key, value):
    s = budget.Prices()
    try:
        s.change(owner, key, value)
        return budget._walk(target, s, refine='light').final.v
    finally:
        s.close()


def made_by_blender(target, owner, key, value):
    old = getattr(owner, key)
    old = tuple(old) if hasattr(old, '__len__') else old
    with gate_off():
        setattr(owner, key, value)
        bpy.context.view_layer.update()
        made = counts(target)[0]
        setattr(owner, key, old)
        bpy.context.view_layer.update()
    return made


def crossings_only(x, operands):
    """The light count as the reviewed change made it: the crossing pairs of
    the mesh with each operand, taken as sure (the control)."""
    s = x.s
    given = x.measures()
    here = budget._Surface(given, budget._matrix(x.walk.obj, s))
    total = 0
    for other in operands:
        stack = budget._stack(other, s)
        theirs = budget._evaluate(other, s, stack, len(stack), False)
        if theirs.counts.f:
            total += budget._pair_crossings(here, budget._Surface(theirs, budget._matrix(other, s)))
    return total, True


print("\n13. the review of frame changes and Boolean pricing answered")

# 13.1 faces in one plane
def grid(name, n, location):
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.01
    return obj


def coplanar(n, solver, turned=False):
    clear_all()
    h = 1.0 / n          # half a cell
    a = grid("A", n, (0, 0, 0))
    b = grid("B", n, (h, 0, 0.3))
    if turned:
        b.rotation_euler.z = math.radians(30)
    m = a.modifiers.new("Boolean", 'BOOLEAN')
    m.operation = 'UNION'
    m.solver = solver
    m.object = b
    bpy.context.view_layer.update()
    light = light_walk(a, b, 'location', (h, 0, 0.0))
    made = made_by_blender(a, b, 'location', (h, 0, 0.0))
    with off('_crossings', crossings_only):
        old = light_walk(a, b, 'location', (h, 0, 0.0))
    label = "%s%s, N = %d" % (solver.title(), ", B turned 30°" if turned else "", n)
    check("13.1 faces in one plane (%s): the light count is at least Blender's (%s against %s)"
          % (label, format(light, ','), format(made, ',')), light >= made, (light, made))
    if made > old:
        with lowered_to((old + made) // 2):
            said = said_of(lambda: budget.price(b, 'location', (h, 0, 0.0)))
            with off('_crossings', crossings_only):
                control = said_of(lambda: budget.price(b, 'location', (h, 0, 0.0)))
        check("and the Data API row's Location is refused at %s, between the crossing pairs' %s and Blender's"
              % (format((old + made) // 2, ','), format(old, ',')), said is not None and "would give A" in said,
              said)
        check("control: with the crossing pairs alone taken as sure, as the review measured, it passes",
              control is None, control)
    return a, b


for solver in ('MANIFOLD', 'EXACT', 'FLOAT'):
    coplanar(40, solver)
coplanar(40, 'MANIFOLD', turned=True)
coplanar(40, 'EXACT', turned=True)
a, b = coplanar(150, 'MANIFOLD')
with lowered_to(150_478):
    said = said_of(lambda: budget.price(b, 'location', (1.0 / 150, 0, 0.0)))
    with off('_crossings', crossings_only):
        control = said_of(lambda: budget.price(b, 'location', (1.0 / 150, 0, 0.0)))
check("the review's own case, N = 150 Manifold at a budget of 150,478, is refused", said is not None, said)
check("control: with the crossing pairs alone, it passed (the review: Blender then held 208,628)",
      control is None, control)
h = 1.0 / 150
with lowered_to(int(made_by_blender(a, b, 'location', (h, 0, 0.0)) * 1.6)):
    said = said_of(lambda: budget.price(b, 'location', (h, 0, 0.0)))
check("and with the budget at 1.6× Blender's count it passes (the count is made exact)", said is None, said)
# Faces in one plane that face a way no axis does: two grids standing (turned
# 90° about X) and turned 30° about Z, B half a cell along A's plane. Their
# normals go to the world through each object's matrix (`_Surface.planes`).
clear_all()
n = 40
a = grid("A", n, (0, 0, 0))
b = grid("B", n, (0, 0, 0))
for o in (a, b):
    o.rotation_euler = (math.radians(90), 0, math.radians(30))
along = (math.cos(math.radians(30)) / n, math.sin(math.radians(30)) / n, 0.0)
m = a.modifiers.new("Boolean", 'BOOLEAN')
m.operation = 'UNION'
m.solver = 'MANIFOLD'
m.object = b
# Off A's plane along its normal, then moved onto it by the change.
b.location = (along[0] - 0.3 * math.sin(math.radians(30)), along[1] + 0.3 * math.cos(math.radians(30)), 0.0)
bpy.context.view_layer.update()
light = light_walk(a, b, 'location', along)
made = made_by_blender(a, b, 'location', along)
check("13.1 faces in one plane facing no axis (two grids standing and turned 30°, Manifold): the light count is "
      "at least Blender's (%s against %s)" % (format(light, ','), format(made, ',')), light >= made, (light, made))
# A legal Boolean whose faces do not share a plane is still taken from its
# light count (11.5 holds its time): no fin is built there.
clear_all()
a = grid("A", 40, (0, 0, 0))
b = grid("B", 40, (0.3, 0.2, 0.05))
m = a.modifiers.new("Boolean", 'BOOLEAN')
m.solver = 'MANIFOLD'
m.object = b
bpy.context.view_layer.update()
s = budget.Prices()
try:
    s.change(b, 'location', (0.31, 0.2, 0.05))
    w = budget._walk(a, s, refine='light')
    sure = not w.unsure
finally:
    s.close()
check("a Boolean of grids that cross, no face in another's plane: its light count is sure", sure)


# 13.2 Self Intersection
def comb_mesh(name, plates=10, n=10, gap=0.2):
    verts, faces = [], []
    for i in range(plates):
        x = (i - (plates - 1) / 2) * gap
        base = len(verts)
        for p in range(n):
            for q in range(n):
                verts.append((x, -1 + 2 * p / (n - 1), -1 + 2 * q / (n - 1)))
        for p in range(n - 1):
            for q in range(n - 1):
                v = base + p * n + q
                faces.append((v, v + n, v + n + 1, v + 1))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    return mesh


def comb(name, location=(0, 0, 0), rotation=(0, 0, 0)):
    obj = bpy.data.objects.new(name, comb_mesh(name))
    sc.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = rotation
    obj.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.02
    return obj


clear_all()
c = comb("Comb")
turn = bpy.data.objects.new("Turn", None)
sc.collection.objects.link(turn)
turn.rotation_euler.z = math.radians(90)
arr = c.modifiers.new("Array", 'ARRAY')
arr.count = 1
arr.use_relative_offset = False
arr.use_object_offset = True
arr.offset_object = turn
far = cube("Far", (20, 0, 0))
m = c.modifiers.new("Boolean", 'BOOLEAN')
m.operation = 'UNION'
m.solver = 'EXACT'
m.use_self = True
m.object = far
bpy.context.view_layer.update()
light = light_walk(c, arr, 'count', 2)
made = made_by_blender(c, arr, 'count', 2)
with off('_crossings', crossings_only):
    old = light_walk(c, arr, 'count', 2)
check("13.2 Self Intersection, a comb's Array turned 90°, Count 1 → 2: the light count is at least Blender's "
      "(%s against %s)" % (format(light, ','), format(made, ',')), light >= made, (light, made))
with lowered_to((old + made) // 2):
    said = said_of(lambda: budget.price(arr, 'count', 2))
    with off('_crossings', crossings_only):
        control = said_of(lambda: budget.price(arr, 'count', 2))
check("and Count 2 is refused at a budget of %s (Blender %s)" % (format((old + made) // 2, ','), format(made, ',')),
      said is not None, said)
check("control: with the crossing pairs alone (%s) it passed" % format(old, ','), control is None, control)


# 13.3 a collection's operand moved
def collection_case(solver):
    clear_all()
    b1 = comb("B1")
    b2 = comb("B2", location=(0, 0, 3), rotation=(0, 0, math.radians(90)))
    col = bpy.data.collections.new("Operands")
    sc.collection.children.link(col)
    for o in (b1, b2):
        sc.collection.objects.unlink(o)
        col.objects.link(o)
    a = cube("A", (20, 0, 0))
    m = a.modifiers.new("Boolean", 'BOOLEAN')
    m.operation = 'UNION'
    m.solver = solver
    m.operand_type = 'COLLECTION'
    m.collection = col
    bpy.context.view_layer.update()
    held = blender_count(a)
    light = light_walk(a, b2, 'location', (0, 0, 0))
    s = budget.Prices()
    try:
        s.change(b2, 'location', (0, 0, 0))
        exact = budget._walk(a, s, refine=True).final.v
    finally:
        s.close()
    made = made_by_blender(a, b2, 'location', (0, 0, 0))
    check("13.3 %s, B2 lowered through B1 in the Boolean's collection: the light count (%s) and the exact walk "
          "(%s) are at least Blender's %s" % (solver.title(), format(light, ','), format(exact, ','),
                                              format(made, ',')),
          light >= made and exact >= made, (light, exact, made))
    with lowered_to((held + made) // 2):
        budget_now = budget.BUDGET
        said = said_of(lambda: budget.price(b2, 'location', (0, 0, 0)))
        with off('_collection_stand_in', lambda *args: None), off('_crossings', crossings_only):
            control = said_of(lambda: budget.price(b2, 'location', (0, 0, 0)))
    check("and the Data API row's Location is refused at a budget of %s" % format(budget_now, ','),
          said is not None, said)
    check("control: with the operands evaluated where they were and crossed only with A, it passed",
          control is None, control)


collection_case('EXACT')
collection_case('MANIFOLD')


# 13.4 the plan follows the scene
with lowered_to(100_000):
    def keyed_target():
        clear_all()
        obj = cube()
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
        return obj, target

    def post_handler_case():
        obj, target = keyed_target()

        def handler(scene, *_):
            if not obj.modifiers:
                m = obj.modifiers.new("Array", 'ARRAY')
                m.use_relative_offset = False
                m.use_object_offset = True
                m.offset_object = target
                m.fit_type = 'FIT_LENGTH'
                m.fit_length = 2.0

        bpy.app.handlers.frame_change_post.append(handler)
        try:
            anim.frame_set(3)
        finally:
            bpy.app.handlers.frame_change_post.remove(handler)
        sync.sync()
        return said_of(lambda: anim.frame_set(30))

    said = post_handler_case()
    check("13.4 an Array reading the keyed empty, added by a frame_change_post handler during frame 3: frame 30 "
          "is refused (the frame stays %d)" % sc.frame_current,
          said is not None and "Frame 30" in said and sc.frame_current == 3, said)
    with off('note_pending', lambda found: None):
        said = post_handler_case()
    check("control: with the plan not hearing what the gate found, frame 30 passes and Blender makes %s"
          % format(mesh_max(), ','), said is None and mesh_max() > budget.BUDGET, said)

    def refused_line_case():
        clear_all()
        a = cube("A")
        a.modifiers.new("Array", 'ARRAY').count = 2
        b = cube("B", (5, 0, 0))
        b.modifiers.new("Array", 'ARRAY').count = 2
        reset_frame()
        sync.sync()
        anim.frame_set(2)
        plan = budget.frame_plan()
        m = a.modifiers["Array"]
        m.count = 2
        m.keyframe_insert("count", frame=1)
        m.keyframe_insert("count", frame=20)
        m.count = 20000
        m.keyframe_insert("count", frame=40)
        m.count = 2
        b.modifiers["Array"].count = 1_000_000
        said = said_of(lambda: sync.sync())
        return said, budget._plan is plan

    said, kept = refused_line_case()
    check("a script line keying A's Count and setting B's past the budget is refused at the mirror's pass, and "
          "the plan is made again", said is not None and not kept, (said, kept))
    with off('note_pending', lambda found: None):
        said, kept = refused_line_case()
    check("control: with the plan not hearing what the gate found, it is kept (the review: nothing was left "
          "pending)", said is not None and kept, (said, kept))
    reset_frame()


# 13.5 drivers
def keyed_case(build, frame, label):
    clear_all()
    obj = build()
    reset_frame()
    sync.sync()
    said = said_of(lambda: anim.frame_set(frame))
    check("%s: frame %d is refused before Blender evaluates it (the frame stays %d)" % (label, frame, sc.frame_current),
          said is not None and "Frame %d" % frame in said and sc.frame_current == 1, said)
    with gate_off():
        sc.frame_set(frame)
        control = max(counts(o)[0] for o in sc.objects if o.type == 'MESH')
    check("control: Blender's own frame %d makes %s" % (frame, format(control, ',')), control > budget.BUDGET,
          control)
    reset_frame()
    return obj


def frame_driver(context):
    def build():
        obj = cube()
        curve = obj.modifiers.new("Array", 'ARRAY').driver_add("count")
        curve.driver.type = 'SCRIPTED'
        var = curve.driver.variables.new()
        var.name = 'f'
        if context:
            var.type = 'CONTEXT_PROP'
            var.targets[0].context_property = 'ACTIVE_SCENE'
        else:
            var.type = 'SINGLE_PROP'
            var.targets[0].id_type = 'SCENE'
            var.targets[0].id = sc
        var.targets[0].data_path = 'frame_current'
        curve.driver.expression = 'f * 2000'
        return obj
    return build


def through_parent():
    obj = cube()
    parent = bpy.data.objects.new("Parent", None)
    sc.collection.objects.link(parent)
    obj.parent = parent
    parent.keyframe_insert("location", index=0, frame=1)
    parent.location.x = 20000
    parent.keyframe_insert("location", index=0, frame=10)
    parent.location.x = 0
    curve = obj.modifiers.new("Array", 'ARRAY').driver_add("count")
    curve.driver.type = 'SUM'
    var = curve.driver.variables.new()
    var.targets[0].id = obj
    var.targets[0].data_path = 'parent.location[0]'
    return obj


def through_index():
    obj = cube()
    first = obj.modifiers.new("Array", 'ARRAY')
    first.count = 1
    first.keyframe_insert("count", frame=1)
    first.count = 32
    first.keyframe_insert("count", frame=10)
    first.count = 1
    curve = obj.modifiers.new("Array.001", 'ARRAY').driver_add("count")
    curve.driver.type = 'SCRIPTED'
    var = curve.driver.variables.new()
    var.name = 'n'
    var.targets[0].id = obj
    var.targets[0].data_path = 'modifiers[0].count'
    curve.driver.expression = 'n * 20'
    return obj


def reads_a_failing_driver():
    """A Count driver that reads a custom property whose own driver divides
    by zero at frame 10: the plan cannot work that one out there, nor the
    Count's, which Blender still evaluates."""
    obj = cube()
    obj["a"] = 0.0
    inner = obj.driver_add('["a"]')
    inner.driver.type = 'SCRIPTED'
    inner.driver.expression = '1 / (frame - 10)'
    curve = obj.modifiers.new("Array", 'ARRAY').driver_add("count")
    curve.driver.type = 'SCRIPTED'
    var = curve.driver.variables.new()
    var.name = 'a'
    var.targets[0].id = obj
    var.targets[0].data_path = '["a"]'
    curve.driver.expression = 'a * 0 + (frame >= 10) * 20000'
    return obj


def driven_shape_key():
    """A shape key's Value driven by an empty's keyed X, under an Array
    fitted to 2 m: the plan's blocks hold a Key, and a driver reads through
    `_target_key`'s cache (a name a Key once shadowed in the plan)."""
    obj = cube()
    obj.shape_key_add(name="Basis")
    thin = obj.shape_key_add(name="Thin")
    for point in thin.data:
        point.co.x *= 0.00005
    arr = obj.modifiers.new("Array", 'ARRAY')
    arr.fit_type = 'FIT_LENGTH'
    arr.fit_length = 2.0
    source = bpy.data.objects.new("Source", None)
    sc.collection.objects.link(source)
    source.keyframe_insert("location", index=0, frame=1)
    source.location.x = 1.0
    source.keyframe_insert("location", index=0, frame=10)
    source.location.x = 0.0
    curve = thin.driver_add("value")
    curve.driver.type = 'SUM'
    var = curve.driver.variables.new()
    var.targets[0].id = source
    var.targets[0].data_path = 'location[0]'
    return obj


def cycle():
    obj = cube()
    obj["n"] = 2.0
    curve = obj.modifiers.new("Array", 'ARRAY').driver_add("count")
    curve.driver.type = 'SCRIPTED'
    var = curve.driver.variables.new()
    var.name = 'n'
    var.targets[0].id = obj
    var.targets[0].data_path = '["n"]'
    curve.driver.expression = 'n * 2 + frame * 0'
    back = obj.driver_add('["n"]')
    back.driver.type = 'SCRIPTED'
    var = back.driver.variables.new()
    var.name = 'c'
    var.targets[0].id = obj
    var.targets[0].data_path = 'modifiers["Array"].count'
    back.driver.expression = 'c + frame * 0'
    return obj


with lowered_to(100_000):
    keyed_case(frame_driver(False), 10, "13.5 a Count driver of f × 2000, f the scene's frame_current")
    with off('_frame_value', lambda *args: None):
        clear_all()
        frame_driver(False)()
        reset_frame()
        sync.sync()
        said = said_of(lambda: anim.frame_set(10))
    check("control: with f read as the frame Blender is leaving, frame 10 passed and Blender made %s"
          % format(mesh_max(), ','), said is None and mesh_max() > budget.BUDGET, said)
    keyed_case(frame_driver(True), 10, "the same through a Context Property")
    keyed_case(through_parent, 10, "a Count driver reading parent.location[0], the parent's X keyed to 20,000")
    keyed_case(through_index, 10, "a Count driver of 20 × modifiers[0].count, that Count keyed to 32")
    keyed_case(reads_a_failing_driver, 10, "a Count driver reading a driver that divides by zero at frame 10")
    keyed_case(driven_shape_key, 10, "a shape key's Value driven by an empty's keyed X, under an Array fitted to 2 m")
    with off('_target_key', lambda idblock, path, index=None, keys=None: (budget._pointer(idblock), path,
                                                                          0 if index is None else index)):
        clear_all()
        through_parent()
        reset_frame()
        sync.sync()
        said = said_of(lambda: anim.frame_set(10))
    check("control: with a variable keyed by its own path, frame 10 passed and Blender made %s"
          % format(mesh_max(), ','), said is None and mesh_max() > budget.BUDGET, said)
    clear_all()
    cycle()
    reset_frame()
    sync.sync()
    plan = budget.frame_plan()
    said = said_of(lambda: anim.frame_set(2))
    check("13.5 Count = n × 2 + frame × 0 and n = Count + frame × 0: frame 2 is refused in words (%s)"
          % (said or "")[:90], said is not None and "reads a driver that reads it back" in said, said)
    check("and the plan lists them as cycles, not as drivers it works out",
          len(plan.cycles) == 2 and not plan.drivers, (plan.cycles, plan.drivers))
    reached = []
    with gate_off():
        for f in range(2, 40):
            sc.frame_set(f)
            reached.append(max(counts(o)[0] for o in sc.objects if o.type == 'MESH'))
            if reached[-1] > budget.BUDGET:
                break
    check("control: Blender's own frames double the Count each frame, past the budget at frame %d (%s)"
          % (len(reached) + 1, format(reached[-1], ',')), reached[-1] > budget.BUDGET, reached)
    reset_frame()


# 13.6 NLA, Time Stretching, Geometry Nodes
def nla_strip():
    obj = cube()
    arr = obj.modifiers.new("Array", 'ARRAY')
    arr.count = 2
    arr.keyframe_insert("count", frame=1)
    arr.count = 20000
    arr.keyframe_insert("count", frame=10)
    arr.count = 2
    ad = obj.animation_data
    ad.nla_tracks.new().strips.new("Strip", 1, ad.action)
    ad.action = None
    return obj


def nla_added():
    obj = cube()
    arr = obj.modifiers.new("Array", 'ARRAY')
    arr.count = 7000
    arr.keyframe_insert("count", frame=1)
    ad = obj.animation_data
    ad.nla_tracks.new().strips.new("Strip", 1, ad.action)
    ad.action = None
    arr.count = 0
    arr.keyframe_insert("count", frame=1)
    arr.count = 7000
    arr.keyframe_insert("count", frame=10)
    ad.action_blend_type = 'ADD'
    return obj


def stretched():
    obj = cube()
    arr = obj.modifiers.new("Array", 'ARRAY')
    arr.count = 2
    arr.keyframe_insert("count", frame=1)
    arr.count = 20000
    arr.keyframe_insert("count", frame=500)
    arr.count = 2
    sc.render.frame_map_old = 100
    sc.render.frame_map_new = 1
    return obj


def grid_group(exposed):
    tree = bpy.data.node_groups.new("Grid Group", 'GeometryNodeTree')
    tree.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    tree.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    if exposed:
        tree.interface.new_socket("Size", in_out='INPUT', socket_type='NodeSocketInt')
    group_in = tree.nodes.new('NodeGroupInput')
    group_out = tree.nodes.new('NodeGroupOutput')
    grid_node = tree.nodes.new('GeometryNodeMeshGrid')
    grid_node.name = "Grid"
    tree.links.new(grid_node.outputs['Mesh'], group_out.inputs[0])
    if exposed:
        tree.links.new(group_in.outputs['Size'], grid_node.inputs['Vertices X'])
        tree.links.new(group_in.outputs['Size'], grid_node.inputs['Vertices Y'])
    return tree


def nodes_input():
    obj = cube()
    tree = grid_group(True)
    m = obj.modifiers.new("GeometryNodes", 'NODES')
    m.node_group = tree
    x = getattr(m.properties.inputs, tree.interface.items_tree["Size"].identifier)
    x.value = 2
    x.keyframe_insert("value", frame=1)
    x.value = 1000
    x.keyframe_insert("value", frame=10)
    x.value = 2
    return obj


def nodes_socket():
    obj = cube()
    tree = grid_group(False)
    obj.modifiers.new("GeometryNodes", 'NODES').node_group = tree
    for socket in (tree.nodes["Grid"].inputs['Vertices X'], tree.nodes["Grid"].inputs['Vertices Y']):
        socket.default_value = 2
        socket.keyframe_insert("default_value", frame=1)
        socket.default_value = 1000
        socket.keyframe_insert("default_value", frame=10)
        socket.default_value = 2
    return obj


with lowered_to(100_000):
    keyed_case(nla_strip, 10, "13.6 a Count keyed 2 → 20,000 pushed into an NLA strip")
    keyed_case(nla_added, 10, "the active action blended Add over a strip, 7,000 + 0 → 7,000 + 7,000")
    keyed_case(stretched, 5, "Time Stretching, Map Old 100 and Map New 1, a Count keyed 20,000 at 500")
    with off('_when', lambda scene, t: (t, t, None)):
        clear_all()
        stretched()
        reset_frame()
        sync.sync()
        said = said_of(lambda: anim.frame_set(5))
    check("control: with the frame's own keys priced, frame 5 passed and Blender made %s" % format(mesh_max(), ','),
          said is None and mesh_max() > budget.BUDGET, said)
    clear_all()
    keyed_case(nodes_input, 10, "a Geometry Nodes Grid's size keyed 2 → 1,000 on the modifier's input")
    keyed_case(nodes_socket, 10, "a Grid node's Vertices X and Y keyed 2 → 1,000 in its group")
    with off('_modifier_trees', lambda obj: []):
        clear_all()
        nodes_socket()
        reset_frame()
        sync.sync()
        said = said_of(lambda: anim.frame_set(10))
    check("control: with node groups left out of the plan, frame 10 passed and Blender made %s"
          % format(mesh_max(), ','), said is None and mesh_max() > budget.BUDGET, said)
    clear_all()


# 13.7 what a frame costs
def rig(bones, remesh=False):
    clear_all()
    data = bpy.data.armatures.new("Rig")
    arm = bpy.data.objects.new("Rig", data)
    sc.collection.objects.link(arm)
    activate(arm)
    bpy.ops.object.mode_set(mode='EDIT')
    for i in range(bones):
        bone = data.edit_bones.new("B%03d" % i)
        bone.head = (i * 0.01, 0, 0)
        bone.tail = (i * 0.01, 0, 0.1)
    bpy.ops.object.mode_set(mode='OBJECT')
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
        for f, v in ((1, 0.0), (10, 0.5)):
            pb.location = (v, 0, 0)
            pb.rotation_quaternion = (1, v, 0, 0)
            pb.scale = (1 + v, 1, 1)
            pb.keyframe_insert("location", frame=f)
            pb.keyframe_insert("rotation_quaternion", frame=f)
            pb.keyframe_insert("scale", frame=f)
    obj = cube()
    obj.modifiers.new("Armature", 'ARMATURE').object = arm
    if remesh:
        obj.modifiers.new("Remesh", 'REMESH').voxel_size = 0.25
    reset_frame()
    sync.sync()
    anim.frame_set(2)
    return arm, obj


def frame_costs(frames):
    costs = []
    for f in frames:
        t = time.perf_counter()
        budget.price_frame(f)
        costs.append((time.perf_counter() - t) * 1000)
        with gate_off():
            sc.frame_set(f)
    return costs


rig(300)
plan = budget.frame_plan()
cost = statistics.median(frame_costs(range(2, 34)))
check("13.7 a cube under an Armature of 300 keyed bones (3,000 F-curves): the plan leaves the bones out (%d "
      "evaluated, %d left out) and a frame's price is under %.1f ms (%.3f ms)"
      % (sum(len(e) for _, e in plan.curves), plan.left_out, FRAME_BOUND_MS, cost),
      cost < FRAME_BOUND_MS and not plan.live, (cost, plan.left_out))
with off('_reaches_shapes', lambda block: True):
    budget.drop_plan()
    priced = statistics.median(frame_costs(range(2, 18)))
    with off('_frame_changes', lambda t: (budget._animated_all(t), None)):
        every = statistics.median(frame_costs(range(2, 18)))
check("control: with the bones' channels priced, the review's 14.6 ms or so (%.2f ms; every F-curve, as "
      "before the plan, %.2f ms)" % (priced, every), priced > FRAME_BOUND_MS, priced)
arm, obj = rig(300, remesh=True)
plan = budget.frame_plan()
check("under a Remesh, whose count follows where the vertices are, the plan prices the bones' channels (%d)"
      % sum(len(e) for _, e in plan.curves), sum(len(e) for _, e in plan.curves) == 3000, plan.left_out)


def look_costs(plan):
    costs = []
    for f in range(2, 18):
        t = time.perf_counter()
        plan.changes(float(f), sc)
        costs.append((time.perf_counter() - t) * 1000)
    return statistics.median(costs)


found_where = look_costs(plan)
slots = [(e, e.slot) for _, entries in plan.curves for e in entries]
for e, _ in slots:
    e.slot = -1
searched = look_costs(plan)
for e, slot in slots:
    e.slot = slot
check("and a frame looks at each F-curve where the plan found it (%.2f ms for the 3,000), where searching the "
      "bag for each, as the review measured, takes %.2f ms" % (found_where, searched), found_where < 0.8 * searched,
      (found_where, searched))

clear_all()
bpy.ops.mesh.primitive_grid_add(x_subdivisions=200, y_subdivisions=200, size=2)
a = bpy.context.object
a.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.1
bpy.ops.mesh.primitive_grid_add(x_subdivisions=200, y_subdivisions=200, size=2, location=(0.3, 0.2, 0.05))
b = bpy.context.object
b.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.1
m = a.modifiers.new("Boolean", 'BOOLEAN')
m.solver = 'MANIFOLD'
m.object = b
arr = a.modifiers.new("Array", 'ARRAY')
arr.count = 1
arr.keyframe_insert("count", frame=1)
from bpy_extras import anim_utils
bag = anim_utils.action_get_channelbag_for_slot(a.animation_data.action, a.animation_data.action_slot)
bag.fcurves[0].keyframe_points[0].co.y = 0
bag.fcurves[0].keyframe_points.insert(10, 0)
reset_frame()
sync.sync()
anim.frame_set(2)


class judged:
    def __enter__(self):
        self.n = 0
        self.real = budget._judge_changes

        def counting(*args, **kwargs):
            self.n += 1
            return self.real(*args, **kwargs)

        budget._judge_changes = counting
        return self

    def __exit__(self, *exc):
        budget._judge_changes = self.real


with judged() as j:
    frame_costs(range(3, 11))
check("an Array's Count keyed to 0 after a 200 × 200 Boolean (Blender holds 1): %d of 8 frames priced" % j.n,
      j.n == 0 and arr.count == 1, j.n)
with off('_within', lambda e, number: number), judged() as j:
    budget.drop_plan()
    frame_costs(range(3, 11))
check("control: compared unclamped, %d of 8 frames are priced (the review: 8, about 125 ms each)" % j.n, j.n > 0, j.n)

clear_all()
keyed = []
for i in range(3000):
    e = bpy.data.objects.new("Keyed.%04d" % i, None)
    sc.collection.objects.link(e)
    e.location = (i % 60, i // 60, 0)
    e.keyframe_insert("location", frame=1)
    e.location.z = 5
    e.keyframe_insert("location", frame=10)
    keyed.append(e)
mover = cube("Mover", (0, -10, 0))
reset_frame()
sync.sync()
anim.frame_set(2)
builds = {'n': 0}
real_build = budget._plan_build


def counting_build(scene):
    builds['n'] += 1
    return real_build(scene)


def writes(scene, *_):
    mover.location.x = scene.frame_current * 0.01


budget._plan_build = counting_build
bpy.app.handlers.frame_change_post.append(writes)
try:
    costs = []
    for f in range(3, 35):
        t = time.perf_counter()
        anim.frame_set(f)
        costs.append((time.perf_counter() - t) * 1000)
    with_handler = builds['n']
finally:
    bpy.app.handlers.frame_change_post.remove(writes)
check("with 3,000 keyed empties and a frame_change_post handler writing a cube's place on every frame, 32 real "
      "frames through anim.frame_set make the plan %d times" % with_handler, with_handler == 0, with_handler)
builds['n'] = 0
with off('_plan_neutral', lambda found: False):
    bpy.app.handlers.frame_change_post.append(writes)
    try:
        for f in range(3, 11):
            anim.frame_set(f)
    finally:
        bpy.app.handlers.frame_change_post.remove(writes)
check("control: with every change the gate finds making the plan again, it is made on each frame (%d of 8)"
      % builds['n'], builds['n'] >= 7, builds['n'])
budget._plan_build = real_build
clear_all()
