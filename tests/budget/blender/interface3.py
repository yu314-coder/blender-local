"""Part 12's fix round 3 cases (October 29): the budget gaps a user reaches
from the interface, as "Found after fix round 2's repairs, still open
(October 22)" lists them in docs/blender-local.md, each refused before
Blender builds it, beside a control that puts that gap back and has to let
it through (or take the old time).

Run from verify.py at the end of part 12 (or alone, `BUDGET_PARTS=12i`), in
its globals (`check`, `counts`, `clear`, `gate_off`, `budget`, `sync`,
`gate`, `context`, `load`). Each case goes through the path the interface
sends — the Data API row (`_blenderkit_sync.set_property`), a script line
followed by the mirror's pass (`_blenderkit_sync.sync`), the app's timeline
(`_blenderkit_anim.frame_set`), an Object Mode move as the gizmo commits it
with the Options popover's Affect Only set as `_blenderkit_tools.set_tools`
sets it — and reads Blender's own count after.

  i.1  Time Stretching (Map Old / Map New) as a new time for the frame
  i.2  an F-curve modifier on a keyed value
  i.3  Geometry Nodes: Realize Instances of nested instances, and a curve
       object's own curves given to Curve to Mesh
  i.4  Affect Only Parents and Affect Only Origins on a move
  i.5  Booleans: Fast's Overlap Threshold, Self Intersection after a
       modifier the walk cannot ask Blender through, and a collection's
       operands crossed in one BVH (with its timing)
  i.6  drivers reading what the Data API row sets
  i.7  legacy Texture data-blocks
  i.8  ordinary edits of the same kinds still pass

Nothing here opens a window, a browser or another app.
"""
import bpy, bmesh, math, os, sys, time
import numpy as np

anim_i3 = sys.modules.get("_blenderkit_anim") or load("_blenderkit_anim")
tools_i3 = sys.modules.get("_blenderkit_tools") or load("_blenderkit_tools")
counting_i3 = sys.modules.get("_blenderkit_nodecount") or load("_blenderkit_nodecount")
SC = bpy.context.scene


def said_i3(fn):
    try:
        fn()
    except RuntimeError as error:
        return str(error)
    return None


def mirror_i3():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def line_i3(source):
    """A script line, then the mirror's pass the app runs after it."""
    try:
        exec(compile(source, "<line>", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the refusal is the finding
        return str(error)
    return mirror_i3()


def held_i3(obj):
    """What Blender holds for `obj` now, evaluating nothing."""
    dg = bpy.context.view_layer.depsgraph
    evaluated = obj.evaluated_get(dg)
    if evaluated == obj:
        return None
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


class bare_i3:
    """The gate off, as before it existed, and what was written inside
    evaluated before it is back on (the controls)."""

    def __enter__(self):
        gate._busy += 1

    def __exit__(self, *exc):
        try:
            bpy.context.view_layer.update()
        finally:
            gate._busy -= 1


class put:
    """`module.name` set to `value` for a control (today's gap put back)."""

    def __init__(self, module, name, value):
        self.module, self.name, self.value = module, name, value

    def __enter__(self):
        self.kept = getattr(self.module, self.name)
        setattr(self.module, self.name, self.value)
        # And nothing held at the mirror's pass after (`hold_unseen`, the
        # review of 12s's work): what the gap lets through is Blender's to
        # keep, as before that hold existed.
        self.kept_hold = gate.hold_unseen
        gate.hold_unseen = lambda: False

    def __exit__(self, *exc):
        gate.hold_unseen = self.kept_hold
        setattr(self.module, self.name, self.kept)


class budget_at:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        self.kept = budget.BUDGET
        budget.BUDGET = self.value

    def __exit__(self, *exc):
        budget.BUDGET = self.kept


def refused_i3(said, number=None):
    return said is not None and "and this app stops at" in said and (
        number is None or format(number, ',') in said)


def reset_i3():
    clear()
    for collection in (bpy.data.actions, bpy.data.node_groups, bpy.data.textures, bpy.data.collections,
                       bpy.data.curves, bpy.data.meshes):
        for block in list(collection):
            if block.users == 0 or collection is bpy.data.collections:
                try:
                    collection.remove(block)
                except (RuntimeError, ReferenceError):
                    pass
    with bare_i3():
        SC.render.frame_map_old = 100
        SC.render.frame_map_new = 100
        SC.frame_set(1)
    tools_i3.set_tools(skip_children=False, data_origin=False)
    SC.tool_settings.use_transform_pivot_point_align = False
    SC.cursor.location = (0.0, 0.0, 0.0)


def cube_i3(name="A", location=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    return obj


def keyed_i3():
    """A cube under an Array whose Count is keyed 2 at frame 1 and 400,000
    at frame 10, held between them."""
    reset_i3()
    a = cube_i3()
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.count = 400_000
    m.keyframe_insert("count", frame=10)
    with bare_i3():
        m.count = 2
    for layer in a.animation_data.action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    for key in curve.keyframe_points:
                        key.interpolation = 'CONSTANT'
    with bare_i3():
        SC.frame_set(1)
    return a, m


def select_only(obj):
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj


print("\n12i. fix round 3: the budget gaps a user reaches from the interface")

# -- i.1 Time Stretching ---------------------------------------------------------
a, m = keyed_i3()
said = line_i3("bpy.context.scene.render.frame_map_new = 10")
check("12i.1 Time Stretching: the script line `scene.render.frame_map_new = 10` at frame 1, a Count keyed 400,000 "
      "at frame 10, is refused at 3,200,000 and Blender stays at 16 (Map New back at %d)" % SC.render.frame_map_new,
      refused_i3(said, 3_200_000) and held_i3(a) == 16 and SC.render.frame_map_new == 100, (said, held_i3(a)))
said = said_i3(lambda: sync.set_property('bpy.context.scene.render', 'frame_map_new', 10))
check("and the Data API row's Frame Map New 10 is refused there, Blender at 16",
      refused_i3(said, 3_200_000) and held_i3(a) == 16 and SC.render.frame_map_new == 100, (said, held_i3(a)))
with bare_i3():
    SC.frame_set(2)
said = said_i3(lambda: sync.set_property('bpy.context.scene.render', 'frame_map_old', 900))
check("and at frame 2 the row's Frame Map Old 900 (time 18) is refused too, Blender at 16 and Map Old back at %d"
      % SC.render.frame_map_old, refused_i3(said, 3_200_000) and held_i3(a) == 16 and SC.render.frame_map_old == 100,
      (said, held_i3(a)))
with bare_i3():
    SC.frame_set(1)
with put(gate, '_TIME_STRETCH', ()), put(budget, '_price_stretch', lambda changes: None):
    control = line_i3("bpy.context.scene.render.frame_map_new = 10")
    built = held_i3(a)
check("control: with the Scene's Time Stretching compared nowhere, as on 6d31b90, the line passed and Blender "
      "built %s" % format(built or 0, ','), control is None and built == 3_200_000, (control, built))
reset_i3()

# -- i.2 an F-curve modifier ----------------------------------------------------
GENERATOR = """
curve = bpy.data.objects['A'].animation_data.action.layers[0].strips[0].channelbags[0].fcurves[0]
g = curve.modifiers.new('GENERATOR')
g.coefficients = (400000.0, 0.0)
"""


def diff_action_6d31b90(orig, copy, out, structs):
    """`_diff_action` as 6d31b90 had it: an F-curve's modifiers unread."""
    mine, theirs = gate._fcurves(orig), gate._fcurves(copy)
    if [k for k, _ in mine] != [k for k, _ in theirs]:
        structs.append(gate.Struct('keys', None, None, orig, "its F-curves"))
        return
    for (key, x), (_, y) in zip(mine, theirs):
        if len(x.keyframe_points) != len(y.keyframe_points):
            structs.append(gate.Struct('keys', None, None, orig, "its keys"))
            return
        gate._diff_struct(x, y, None, out, 0, structs)
        for attribute in ('co', 'handle_left', 'handle_right'):
            gate._diff_bulk(x, y, 'keyframe_points', attribute, 2, out, keys=True)


a, m = keyed_i3()
said = line_i3(GENERATOR)
curve = a.animation_data.action.layers[0].strips[0].channelbags[0].fcurves[0]
check("12i.2 a script line adding a Generator of (400,000, 0) to the keyed Count's F-curve is refused at "
      "3,200,000, the curve stays muted and Blender stays at 16 — and the next mirror's pass too",
      refused_i3(said, 3_200_000) and curve.mute and held_i3(a) == 16 and mirror_i3() is None
      and held_i3(a) == 16, (said, curve.mute, held_i3(a)))
a, m = keyed_i3()
with put(gate, '_diff_action', diff_action_6d31b90):
    control = line_i3(GENERATOR)
    built = held_i3(a)
curve = a.animation_data.action.layers[0].strips[0].channelbags[0].fcurves[0]
check("control: with the modifiers compared nowhere, as on 6d31b90, the refusal was said and Blender built %s anyway "
      "(the curve %s)" % (format(built or 0, ','), "muted" if curve.mute else "not muted"),
      built == 3_200_000 and not curve.mute, (control, built))
reset_i3()

# -- i.3 Geometry Nodes ---------------------------------------------------------
NESTED = """
bpy.ops.mesh.primitive_cube_add()
o = bpy.context.object
o.name = 'NR'
g = bpy.data.node_groups.new('Nested', 'GeometryNodeTree')
g.interface.new_socket('Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
out = g.nodes.new('NodeGroupOutput')
p1 = g.nodes.new('GeometryNodePoints'); p1.inputs['Count'].default_value = 100
p2 = g.nodes.new('GeometryNodePoints'); p2.inputs['Count'].default_value = 100
grid = g.nodes.new('GeometryNodeMeshGrid')
grid.inputs['Vertices X'].default_value = 20; grid.inputs['Vertices Y'].default_value = 20
i1 = g.nodes.new('GeometryNodeInstanceOnPoints'); i2 = g.nodes.new('GeometryNodeInstanceOnPoints')
r = g.nodes.new('GeometryNodeRealizeInstances')
g.links.new(p2.outputs[0], i1.inputs['Points']); g.links.new(grid.outputs[0], i1.inputs['Instance'])
g.links.new(p1.outputs[0], i2.inputs['Points']); g.links.new(i1.outputs[0], i2.inputs['Instance'])
g.links.new(i2.outputs[0], r.inputs[0]); g.links.new(r.outputs[0], out.inputs[0])
o.modifiers.new('GN', 'NODES').node_group = g
"""


def realized_6d31b90(self):
    held = self.held or counting_i3.Geo()
    n = self.instances
    return counting_i3.Geo(self.v + n * held.v, self.e + n * held.e, self.f + n * held.f, self.l + n * held.l,
                           self.points + n * held.points, n * held.instances, held.held)


reset_i3()
said = line_i3(NESTED)
nr = bpy.data.objects['NR']
check("12i.3 a script line's Points (100) -> Instance on Points of [Instance on Points (Points 100, Grid 20 × 20)] "
      "-> Realize Instances is refused at 4,000,000, and Blender holds %s" % format(held_i3(nr) or 0, ','),
      refused_i3(said, 4_000_000) and (held_i3(nr) or 0) <= 8, (said, held_i3(nr)))
reset_i3()
with put(counting_i3.Geo, 'realized', realized_6d31b90):
    control = line_i3(NESTED)
nr = bpy.data.objects['NR']
built = held_i3(nr)
check("control: realized one level, as on 6d31b90, the line passed and Blender built %s" % format(built or 0, ','),
      control is None and built == 4_000_000, (control, built))
reset_i3()

# Instances of instances: Blender runs a node on the geometry inside
# instances too (`GeometrySet::modify_geometry_sets`), Instance on Points
# among them — found by this round's own checking, not the re-check.
INSIDE = """
bpy.ops.mesh.primitive_cube_add()
o = bpy.context.object
o.name = 'NI'
g = bpy.data.node_groups.new('Inside', 'GeometryNodeTree')
g.interface.new_socket('Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
out = g.nodes.new('NodeGroupOutput')
p = g.nodes.new('GeometryNodePoints'); p.inputs['Count'].default_value = POINTS
grid = g.nodes.new('GeometryNodeMeshGrid')
grid.inputs['Vertices X'].default_value = SIDE; grid.inputs['Vertices Y'].default_value = SIDE
first = g.nodes.new('GeometryNodeInstanceOnPoints')
g.links.new(p.outputs[0], first.inputs['Points']); g.links.new(grid.outputs[0], first.inputs['Instance'])
last = first.outputs[0]
if THEN == 'cube':
    second = g.nodes.new('GeometryNodeInstanceOnPoints'); cube = g.nodes.new('GeometryNodeMeshCube')
    g.links.new(last, second.inputs['Points']); g.links.new(cube.outputs[0], second.inputs['Instance'])
    last = second.outputs[0]
else:
    sub = g.nodes.new('GeometryNodeSubdivideMesh'); sub.inputs['Level'].default_value = 1
    g.links.new(last, sub.inputs[0]); last = sub.outputs[0]
real = g.nodes.new('GeometryNodeRealizeInstances')
g.links.new(last, real.inputs[0]); g.links.new(real.outputs[0], out.inputs[0])
o.modifiers.new('GN', 'NODES').node_group = g
"""
for then, points, side, made in (('cube', 1000, 20, 3_200_000), ('subdivide', 100, 100, 3_960_100)):
    source = INSIDE.replace("POINTS", str(points)).replace("SIDE", str(side)).replace("THEN", repr(then))
    reset_i3()
    said = line_i3(source)
    ni = bpy.data.objects['NI']
    check("12i.3 Points (%d) -> Instance on Points (a Grid %d × %d) -> %s -> Realize Instances, from a script line, "
          "is refused, and Blender holds %s" % (points, side, side, "Instance on Points (a Cube)" if then == 'cube'
                                                else "Subdivide Mesh (1)", format(held_i3(ni) or 0, ',')),
          refused_i3(said) and (held_i3(ni) or 0) <= 8, (said, held_i3(ni)))
    reset_i3()
    with put(counting_i3._Group, '_each', lambda self, g, one: one(g)):
        control = line_i3(source)
    built = held_i3(bpy.data.objects['NI'])
    check("control: with the node run on the top geometry alone, as on 6d31b90, the line passed and Blender built %s"
          % format(built or 0, ','), control is None and built == made, (control, built))
reset_i3()

CURVE_TO_MESH = """
bpy.ops.curve.primitive_bezier_curve_add()
c = bpy.context.object
c.name = 'CV'
c.data.resolution_u = 1024
g = bpy.data.node_groups.new('G3', 'GeometryNodeTree')
g.interface.new_socket('Geometry', in_out='INPUT', socket_type='NodeSocketGeometry')
g.interface.new_socket('Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
gi = g.nodes.new('NodeGroupInput'); out = g.nodes.new('NodeGroupOutput')
circle = g.nodes.new('GeometryNodeCurvePrimitiveCircle'); circle.name = 'Circle'
circle.inputs[0].default_value = RESOLUTION
to_mesh = g.nodes.new('GeometryNodeCurveToMesh')
g.links.new(gi.outputs[0], to_mesh.inputs['Curve']); g.links.new(circle.outputs[0], to_mesh.inputs['Profile Curve'])
g.links.new(to_mesh.outputs[0], out.inputs[0])
c.modifiers.new('GN', 'NODES').node_group = g
"""
said = line_i3(CURVE_TO_MESH.replace("RESOLUTION", "3000"))
cv = bpy.data.objects['CV']
check("12i.3 a script line's Bézier curve at Resolution U 1,024 under Group Input -> Curve to Mesh (a Curve Circle of "
      "Resolution 3,000) is refused, and Blender holds %s" % format(held_i3(cv) or 0, ','),
      refused_i3(said) and (held_i3(cv) or 0) < 100_000, (said, held_i3(cv)))
reset_i3()
with bare_i3():
    exec(compile(CURVE_TO_MESH.replace("RESOLUTION", "30"), "<fixture>", "exec"), {"bpy": bpy})
cv = bpy.data.objects['CV']
row = "bpy.data.node_groups['G3'].nodes['Circle'].inputs[0]"
said = said_i3(lambda: sync.set_property(row, 'default_value', 3000))
check("and the Data API row's Circle Resolution 30 -> 3,000 is refused, Blender at %s" % format(held_i3(cv), ','),
      refused_i3(said) and held_i3(cv) == 30_750, (said, held_i3(cv)))
plain = counting_i3.Counter.count


def count_given_as_mesh(self, modifier, given):
    """As on 6d31b90: what a curve object gives its group, a mesh with no points."""
    return plain(self, modifier, counting_i3.Geo(given.v, given.e, given.f, given.l))


with put(counting_i3.Counter, 'count', count_given_as_mesh):
    control = said_i3(lambda: sync.set_property(row, 'default_value', 3000))
built = held_i3(cv)
check("control: with the curve given as a mesh, as on 6d31b90, the row passed and Blender built %s"
      % format(built or 0, ','), control is None and built == 3_075_000, (control, built))
reset_i3()

# -- i.4 Affect Only Parents and Affect Only Origins -----------------------------


def fitted_child():
    """A under an Array fitted to 40 whose offset is its own child O, 1 m away."""
    reset_i3()
    a = cube_i3()
    bpy.ops.object.empty_add(location=(1.0, 0.0, 0.0))
    o = bpy.context.object
    o.name = "O"
    m = a.modifiers.new("Array", 'ARRAY')
    m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, o
    m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    o.parent = a
    bpy.context.view_layer.update()
    select_only(a)
    return a, o


def thin_cube():
    """A cube 0.0001 m thick in its own Y under an Array fitted to 40 by its size."""
    reset_i3()
    c = cube_i3("T")
    for v in c.data.vertices:
        v.co.y *= 5e-5
    m = c.modifiers.new("Array", 'ARRAY')
    m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    bpy.context.view_layer.update()
    select_only(c)
    return c


a, o = fitted_child()
tools_i3.set_tools(skip_children=True)
said = said_i3(lambda: bpy.ops.transform.translate(value=(0.9999, 0.0, 0.0)))
check("12i.4 Affect Only Parents (the Options popover's switch): A moved 0.9999 with its child O, A's Array offset, "
      "left in place is refused at 3,199,480 and Blender stays at %s" % format(held_i3(a), ','),
      refused_i3(said) and held_i3(a) == 328, (said, held_i3(a)))
a, o = fitted_child()
tools_i3.set_tools(skip_children=True)
with put(gate, '_AFFECT_ONLY', ()), put(gate, '_move_scope', lambda path: None), \
        put(gate, '_object_mode', lambda: False):
    control = said_i3(lambda: bpy.ops.transform.translate(value=(0.9999, 0.0, 0.0)))
    built = held_i3(a)
check("control: with the move's update read for Edit Mode's points alone, as on 6d31b90, it passed and Blender "
      "built %s" % format(built or 0, ','), control is None and built == 3_199_472, (control, built))
a, o = fitted_child()
tools_i3.set_tools(skip_children=True)
with put(gate, '_AFFECT_ONLY', ()):
    alone = said_i3(lambda: bpy.ops.transform.translate(value=(0.9999, 0.0, 0.0)))
check("and with the Affect Only switches unread, the move's update read against what its price priced "
      "(`_move_scope`) refuses it alone too, Blender at %s" % format(held_i3(a), ','),
      refused_i3(alone) and held_i3(a) == 328, (alone, held_i3(a)))
c = thin_cube()
tools_i3.set_tools(data_origin=True)
said = said_i3(lambda: bpy.ops.transform.rotate(value=math.pi / 2, orient_axis='Z'))
check("12i.4 Affect Only Origins: a 90° Rotate of the thin cube (its data turned back) is refused at 3,197,216 and "
      "Blender stays at %s" % format(held_i3(c), ','), refused_i3(said) and held_i3(c) == 168, (said, held_i3(c)))
c = thin_cube()
tools_i3.set_tools(data_origin=True)
with put(gate, '_AFFECT_ONLY', ()), put(gate, '_move_scope', lambda path: None), \
        put(gate, '_object_mode', lambda: False):
    control = said_i3(lambda: bpy.ops.transform.rotate(value=math.pi / 2, orient_axis='Z'))
    built = held_i3(c)
check("control: as on 6d31b90 it passed and Blender built %s" % format(built or 0, ','),
      control is None and (built or 0) > 2_500_000, (control, built))
reset_i3()

# -- i.5 Booleans ----------------------------------------------------------------
N5 = 40
H5 = 1.0 / N5


def grid_i3(name, location, n=N5):
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.01
    return obj


def made_i3(target, owner, key, value):
    old = getattr(owner, key)
    old = tuple(old) if hasattr(old, '__len__') else old
    with bare_i3():
        setattr(owner, key, value)
    made = counts(target)[0]
    with bare_i3():
        setattr(owner, key, old)
    return made


def light_i3(target, owner, key, value):
    s = budget.Prices()
    try:
        s.change(owner, key, value)
        w = budget._walk(target, s, refine='light')
        return w.final.v, w.unsure
    finally:
        s.close()


def fast_tilted():
    reset_i3()
    # Made with the gate off: a Fast Boolean at 0.01 on these grids is
    # refused for Blender's own time when it is new (12j.6), and the cases
    # here are a change of where B is under it.
    with bare_i3():
        a = grid_i3("A", (0, 0, 0))
        b = grid_i3("B", (H5, H5, 0.3))
        b.rotation_euler.x = 0.002
        m = a.modifiers.new("Boolean", 'BOOLEAN')
        m.operation, m.solver, m.double_threshold, m.object = 'UNION', 'FLOAT', 0.01, b
    return a, b, m


a, b, m = fast_tilted()
light = light_i3(a, b, 'location', (H5, H5, 0.0))
made = made_i3(a, b, 'location', (H5, H5, 0.0))
check("12i.5 Fast at an Overlap Threshold of 0.01, B tilted 0.002 rad and lowered onto A's plane: the light count is "
      "not sure, and at least Blender's (%s against %s)" % (format(light[0], ','), format(made, ',')),
      light[1] and light[0] >= made, (light, made))
with budget_at(17_201):
    said = said_i3(lambda: budget.price(b, 'location', (H5, H5, 0.0)))
    with put(budget, '_near_faces', lambda *args: np.zeros(0, dtype=np.int64)):
        control = said_i3(lambda: budget.price(b, 'location', (H5, H5, 0.0)))
check("and the Data API row's Location is refused at a budget of 17,201", refused_i3(said), said)
check("control: with what lies within the threshold unlooked for, as on 6d31b90, it passed (the light count 7,774, "
      "taken as sure)", control is None, control)
with bare_i3():
    b.location = (H5, H5, 0.0)
    m.double_threshold = 1e-6
with budget_at(17_201):
    said = said_i3(lambda: sync.set_property("bpy.data.objects['A'].modifiers['Boolean']", 'double_threshold', 0.01))
# Refused for its count, or (since 12j.6) first for Blender's own Fast time.
check("and the row's Overlap Threshold 1e-6 -> 0.01 with B already on A's plane is refused, Blender at %s"
      % format(held_i3(a), ','), (refused_i3(said) or (said is not None and "Fast solver" in said))
      and held_i3(a) < 17_201, (said, held_i3(a)))


def self_after(kind):
    reset_i3()
    c = grid_i3("C", (0, 0, 0))
    arr = c.modifiers.new("Array", 'ARRAY')
    arr.count = 1
    arr.use_relative_offset, arr.use_constant_offset = False, True
    arr.constant_offset_displace = (H5, H5, 0.0)
    if kind == 'NODES':
        g = bpy.data.node_groups.new("Pass", 'GeometryNodeTree')
        g.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
        g.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
        gi, go = g.nodes.new("NodeGroupInput"), g.nodes.new("NodeGroupOutput")
        g.links.new(gi.outputs[0], go.inputs[0])
        c.modifiers.new("GN", 'NODES').node_group = g
    else:
        c.modifiers.new("MeshDeform", 'MESH_DEFORM')
    far = cube_i3("Far", (20, 0, 0))
    m = c.modifiers.new("Boolean", 'BOOLEAN')
    m.operation, m.solver, m.use_self, m.object = 'UNION', 'EXACT', True, far
    bpy.context.view_layer.update()
    return c, arr


for kind in ('NODES', 'MESH_DEFORM'):
    c, arr = self_after(kind)
    light = light_i3(c, arr, 'count', 2)
    made = made_i3(c, arr, 'count', 2)
    with budget_at(11_900):
        said = said_i3(lambda: budget.price(arr, 'count', 2))
        with put(budget, '_coplanar_self', lambda *args, **kw: (0, False)):
            control = said_i3(lambda: budget.price(arr, 'count', 2))
    check("12i.5 Self Intersection after a %s (the walk cannot ask Blender through it), the grid's Array offset half a "
          "cell, Count 1 -> 2: the count %s is at least Blender's %s, and the row is refused at 11,900"
          % ('Geometry Nodes modifier' if kind == 'NODES' else 'Mesh Deform', format(light[0], ','),
             format(made, ',')), light[0] >= made and refused_i3(said), (light, made, said))
    check("control: with a mesh's own faces in one plane uncounted, as on 6d31b90, it passed", control is None,
          control)


def crossings_pairwise(x, operands):
    """`_crossings` as 6d31b90 had it: a collection's operands crossed pair
    by pair (the timing control)."""
    s = x.s
    given = x.measures()
    surfaces = []
    if given.counts.f:
        surfaces.append(budget._Surface(given, budget._matrix(x.walk.obj, s)))
    first = len(surfaces)
    for other in operands:
        stack = budget._stack(other, s)
        theirs = budget._evaluate(other, s, stack, len(stack), False)
        if theirs.counts.f:
            surfaces.append(budget._Surface(theirs, budget._matrix(other, s)))
    if not surfaces:
        return 0, True
    tolerance = budget.COPLANAR_DISTANCE * (1.0 + max(surface.extent() for surface in surfaces))
    total, sure = 0, True
    pairs = [(surfaces[0], other) for other in surfaces[1:]] if first else []
    others = surfaces[first:]
    for i in range(len(others)):
        for j in range(i + 1, len(others)):
            pairs.append((others[i], others[j]))
    for p, q in pairs:
        total += budget._pair_crossings(p, q)
        flat, looked = budget._coplanar(p, q, tolerance)
        total += flat
        if looked and flat:
            sure = False
    return total, sure


def operands(k, solver):
    reset_i3()
    group = bpy.data.collections.new("Operands")
    SC.collection.children.link(group)
    side = int(math.ceil(math.sqrt(k)))
    made = []
    for i in range(k):
        mesh = bpy.data.meshes.new("u%d" % i)
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        bm.to_mesh(mesh)
        bm.free()
        o = bpy.data.objects.new("u%d" % i, mesh)
        group.objects.link(o)
        o.location = (2 * (i % side), 2 * (i // side), 0.0)
        made.append(o)
    a = cube_i3("A", (0, 0, 0.5))
    m = a.modifiers.new("Boolean", 'BOOLEAN')
    m.operation, m.solver, m.operand_type, m.collection = 'UNION', solver, 'COLLECTION', group
    bpy.context.view_layer.update()
    return a, made


def priced_in(obj, value):
    started = time.perf_counter()
    said = said_i3(lambda: budget.price(obj, 'location', value))
    return time.perf_counter() - started, said


for k, solver in ((400, 'MANIFOLD'), (400, 'EXACT')):
    a, made = operands(k, solver)
    moved = (made[1].location.x + 0.1, made[1].location.y, 0.0)
    started = time.perf_counter()
    with bare_i3():
        made[1].location = moved
    blender_s = time.perf_counter() - started
    with bare_i3():
        made[1].location.x -= 0.1
    seconds, said = priced_in(made[1], moved)
    with put(budget, '_crossings', crossings_pairwise):
        old_seconds, old_said = priced_in(made[1], moved)
    check("12i.5 a collection of %d unit cubes in one plane under A's Union (%s), one moved 0.1 through the row's "
          "price: %.2f s (Blender's own evaluation %.2f s), under 3 s and under a quarter of the pairs' time"
          % (k, solver.title(), seconds, blender_s), said is None and seconds < 3.0 and seconds < old_seconds / 4,
          (said, seconds))
    check("control: crossed pair by pair, as on 6d31b90, the same price took %.2f s" % old_seconds,
          old_said is None and old_seconds > 3.0, (old_said, old_seconds))
# The operands crossing each other are still counted: two combs' plates,
# one lowered through the other (part 13.3's case), now in one BVH.
reset_i3()
reset_i3()

# -- i.6 drivers reading what the Data API row sets --------------------------------
with budget_at(100_000):
    reset_i3()
    a = cube_i3()
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    curve = m.driver_add("count")
    var = curve.driver.variables.new()
    var.name = "x"
    var.targets[0].id_type, var.targets[0].id = 'OBJECT', a
    var.targets[0].data_path = 'modifiers["Array"].relative_offset_displace[1]'
    curve.driver.expression = "x*2000+1"
    bpy.context.view_layer.update()
    row = "bpy.data.objects['A'].modifiers['Array']"
    said = said_i3(lambda: sync.set_property(row, 'relative_offset_displace', (1.0, 10.0, 0.0)))
    check("12i.6 the Data API row's Relative Offset (1, 10, 0), read by the Array's own Count driver (x × 2,000 + 1), "
          "is refused at the row at 160,008 (budget 100,000), Blender at %s" % format(held_i3(a), ','),
          refused_i3(said, 160_008) and held_i3(a) == 8, (said, held_i3(a)))
    with put(budget, '_readers_of', lambda changes: ([], False)):
        control = said_i3(lambda: sync.set_property(row, 'relative_offset_displace', (1.0, 10.0, 0.0)))
        built = held_i3(a)
    check("control: with the drivers that read the row's value unread, as on 6d31b90, it passed and Blender built %s"
          % format(built or 0, ','), control is None and built == 160_008, (control, built))
    # An empty's Location read in World Space, which only Blender works out.
    reset_i3()
    a = cube_i3()
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    bpy.ops.object.empty_add(location=(0.0, 0.0, 0.0))
    e = bpy.context.object
    e.name = "E"
    curve = m.driver_add("count")
    var = curve.driver.variables.new()
    var.name, var.type = "x", 'TRANSFORMS'
    var.targets[0].id, var.targets[0].transform_type = e, 'LOC_X'
    curve.driver.expression = "x*2000+2"
    bpy.context.view_layer.update()
    said = said_i3(lambda: sync.set_property("bpy.data.objects['E']", 'location', (10.0, 0.0, 0.0)))
    check("and an empty's Location read by a Count driver in World Space (Blender's to work out) is refused at the "
          "row at 160,016, Blender at %s and E back at x = %g" % (format(held_i3(a), ','), e.location.x),
          refused_i3(said, 160_016) and held_i3(a) == 16 and e.location.x == 0.0, (said, held_i3(a)))
    # A Move of an empty a Count driver reads (found by this round's own
    # checking: the move's price laid a matrix, which no driver reads), and the
    # row's Location of a parent whose child a driver reads in World Space.
    def driven_by_empty(space, parented):
        reset_i3()
        a = cube_i3()
        m = a.modifiers.new("Array", 'ARRAY')
        m.count = 2
        bpy.ops.object.empty_add(location=(0.0, 0.0, 0.0))
        e = bpy.context.object
        e.name = "E"
        bpy.ops.object.empty_add(location=(0.0, 0.0, 0.0))
        p = bpy.context.object
        p.name = "P"
        if parented:
            e.parent = p
        curve = m.driver_add("count")
        var = curve.driver.variables.new()
        var.name, var.type = "x", 'TRANSFORMS'
        var.targets[0].id, var.targets[0].transform_type = e, 'LOC_X'
        var.targets[0].transform_space = space
        curve.driver.expression = "x*40000+2"
        bpy.context.view_layer.update()
        mover = p if parented else e
        select_only(mover)
        return a, mover

    for label, control in (("", False), ("control: ", True)):
        a, e = driven_by_empty('TRANSFORM_SPACE', False)
        if control:
            with put(budget, '_readers_of', lambda changes: ([], False)), \
                    put(budget, 'read_by_drivers', lambda blocks: False):
                said = said_i3(lambda: bpy.ops.transform.translate(value=(10.0, 0.0, 0.0)))
                built = held_i3(a)
            check("control: with the move's matrix laying nothing and its update not read for drivers, as on "
                  "6d31b90, it passed and Blender built %s" % format(built or 0, ','),
                  said is None and built == 3_200_016, (said, built))
        else:
            said = said_i3(lambda: bpy.ops.transform.translate(value=(10.0, 0.0, 0.0)))
            check("12i.6 a Move of 10 of an empty whose X a Count driver reads (x × 40,000 + 2) is refused at "
                  "3,200,016, Blender at %s and the empty back at x = %g" % (format(held_i3(a), ','), e.location.x),
                  refused_i3(said, 3_200_016) and held_i3(a) == 16 and e.location.x == 0.0, (said, held_i3(a)))
    for label, control in (("", False), ("control: ", True)):
        a, p = driven_by_empty('WORLD_SPACE', True)
        if control:
            with put(budget, '_readers_of', lambda changes: ([], False)):
                said = said_i3(lambda: sync.set_property("bpy.data.objects['P']", 'location', (10.0, 0.0, 0.0)))
                built = held_i3(a)
            check("control: with the drivers that read the row's value unread, the parent's row passed and Blender "
                  "built %s" % format(built or 0, ','), said is None and built == 3_200_016, (said, built))
        else:
            said = said_i3(lambda: sync.set_property("bpy.data.objects['P']", 'location', (10.0, 0.0, 0.0)))
            check("and the row's Location of P, whose child E a Count driver reads in World Space, is refused at "
                  "3,200,016, Blender at %s" % format(held_i3(a), ','),
                  refused_i3(said, 3_200_016) and held_i3(a) == 16 and p.location.x == 0.0, (said, held_i3(a)))
    # A Wave's Narrowness read by a shape key's Value under a fitted Array.
    reset_i3()
    s = cube_i3("S")
    s.shape_key_add(name="Basis")
    thin = s.shape_key_add(name="Thin")
    for point in thin.data:
        point.co.x *= 0.00005
    wave = s.modifiers.new("Wave", 'WAVE')
    wave.narrowness = 0.0
    arr = s.modifiers.new("Array", 'ARRAY')
    arr.fit_type, arr.fit_length = 'FIT_LENGTH', 2.0
    curve = thin.driver_add("value")
    var = curve.driver.variables.new()
    var.name = "w"
    var.targets[0].id_type, var.targets[0].id = 'OBJECT', s
    var.targets[0].data_path = 'modifiers["Wave"].narrowness'
    curve.driver.expression = "w"
    bpy.context.view_layer.update()
    before = held_i3(s)
    said = said_i3(lambda: sync.set_property("bpy.data.objects['S'].modifiers['Wave']", 'narrowness', 1.0))
    check("and a Wave's Narrowness 0 -> 1 read by a shape key's Value under an Array fitted to its size is refused at "
          "the row, Blender at %s" % format(held_i3(s), ','), refused_i3(said) and held_i3(s) == before,
          (said, held_i3(s)))
reset_i3()

# -- i.7 legacy textures -------------------------------------------------------------


def displaced():
    """A cube under a Displace (a Blend texture, Strength 20) and a Remesh at 0.5: 1,564 vertices."""
    reset_i3()
    d = cube_i3("D")
    texture = bpy.data.textures.new("T", 'BLEND')
    displace = d.modifiers.new("Displace", 'DISPLACE')
    displace.texture, displace.strength = texture, 20.0
    remesh = d.modifiers.new("Remesh", 'REMESH')
    remesh.mode, remesh.voxel_size = 'VOXEL', 0.5
    bpy.context.view_layer.update()
    return d, texture


def texture_unread():
    """The gap put back: no texture compared by the gate or read by the model."""
    kinds = {k: v for k, v in gate._COLLECTIONS.items() if v != 'textures'}
    return put(gate, '_COLLECTIONS', kinds), put(budget, '_textures_of', lambda obj: [])


with budget_at(20_000):
    d, texture = displaced()
    held_before = held_i3(d)
    said = said_i3(lambda: sync.set_property("bpy.data.textures['T']", 'intensity', 2.0))
    check("12i.7 the Data API row's Brightness 1 -> 2 of the Displace's Blend texture under a Remesh is refused at "
          "the row (budget 20,000), Blender at %s" % format(held_i3(d), ','),
          refused_i3(said) and held_i3(d) == held_before and texture.intensity == 1.0, (said, held_i3(d)))
    said = line_i3("bpy.data.textures['T'].intensity = 2.0")
    check("and the script line, priced at the mirror's pass, Brightness back at %g, Blender at %s"
          % (texture.intensity, format(held_i3(d), ',')),
          refused_i3(said) and held_i3(d) == held_before and texture.intensity == 1.0, (said, held_i3(d)))
    with bare_i3():
        SC.frame_set(1)
    texture.keyframe_insert('intensity', frame=1)
    texture.intensity = 2.0
    texture.keyframe_insert('intensity', frame=10)
    with bare_i3():
        texture.intensity = 1.0
        SC.frame_set(1)
    said = said_i3(lambda: anim_i3.frame_set(10))
    check("and the Brightness keyed 1 at frame 1 and 2 at frame 10: the app's timeline is refused at frame 10, "
          "Blender at %s on frame %d" % (format(held_i3(d), ','), SC.frame_current),
          said is not None and "Frame 10" in said and held_i3(d) == held_before and SC.frame_current == 1,
          (said, held_i3(d)))
    d, texture = displaced()
    first, second = texture_unread()
    with first, second:
        control = said_i3(lambda: sync.set_property("bpy.data.textures['T']", 'intensity', 2.0))
        built = held_i3(d)
    check("control: with textures compared and counted nowhere, as on 6d31b90, the row passed and Blender built %s"
          % format(built or 0, ','), control is None and (built or 0) > 20_000, (control, built))
reset_i3()

# -- i.8 ordinary edits of these kinds pass ------------------------------------------
d, texture = displaced()
said = said_i3(lambda: sync.set_property("bpy.data.textures['T']", 'intensity', 1.1))
check("12i.8 ordinary: the row's Brightness 1 -> 1.1 passes (Blender %s)" % format(held_i3(d), ','),
      said is None and abs(texture.intensity - 1.1) < 1e-6, said)
a, m = keyed_i3()
said = said_i3(lambda: sync.set_property('bpy.context.scene.render', 'frame_map_new', 50))
check("ordinary: the row's Frame Map New 50 (time 2, Count still 2) passes", said is None and held_i3(a) == 16, said)
a, o = fitted_child()
said = said_i3(lambda: bpy.ops.transform.translate(value=(0.5, 0.0, 0.0)))
check("ordinary: moving A with its child O following (no Affect Only) passes, Blender at %s" % format(held_i3(a), ','),
      said is None and held_i3(a) == 328, said)
a, o = fitted_child()
tools_i3.set_tools(skip_children=True)
said = said_i3(lambda: bpy.ops.transform.translate(value=(-0.5, 0.0, 0.0)))
check("ordinary: Affect Only Parents moving A 0.5 away from O (the offset 1.5 m) passes, Blender at %s"
      % format(held_i3(a), ','), said is None and held_i3(a) < 328, said)
reset_i3()
a = grid_i3("A", (0, 0, 0))
b = grid_i3("B", (0.3, 0.2, 0.05))
b.rotation_euler.x = 0.3
m = a.modifiers.new("Boolean", 'BOOLEAN')
m.operation, m.solver, m.double_threshold, m.object = 'UNION', 'FLOAT', 1e-6, b
bpy.context.view_layer.update()
light = light_i3(a, b, 'location', (0.31, 0.2, 0.05))
check("ordinary: a Fast Boolean at Blender's default Overlap Threshold of grids that cross keeps a sure light count "
      "(%s), as before" % format(light[0], ','), not light[1], light)
with bare_i3():
    m.double_threshold = 0.01
started = time.perf_counter()
said = said_i3(lambda: budget.price(b, 'location', (0.31, 0.2, 0.05)))
seconds = time.perf_counter() - started
# Since 12j.6 Blender is not asked through a Fast Boolean it takes longer
# than FAST_SECONDS on: the bound stands, as fast as the light walk.
check("ordinary: at an Overlap Threshold of 0.01 the same move passes (%.2f s)" % seconds, said is None, said)
with budget_at(100_000):
    reset_i3()
    a = cube_i3()
    m = a.modifiers.new("Array", 'ARRAY')
    curve = m.driver_add("count")
    var = curve.driver.variables.new()
    var.name = "x"
    var.targets[0].id_type, var.targets[0].id = 'OBJECT', a
    var.targets[0].data_path = 'modifiers["Array"].relative_offset_displace[1]'
    curve.driver.expression = "x*2+2"
    bpy.context.view_layer.update()
    said = said_i3(lambda: sync.set_property("bpy.data.objects['A'].modifiers['Array']", 'relative_offset_displace',
                                             (1.0, 10.0, 0.0)))
    check("ordinary: the row's Relative Offset read by a Count driver that stays small (x × 2 + 2 = 22) passes, "
          "Blender at %s" % format(held_i3(a), ','), said is None and held_i3(a) == 176, (said, held_i3(a)))
reset_i3()

# -- i.10 a price that fails refuses ------------------------------------------------
# Found by part 12.17's sweep in this round: a price that raised inside the gate
# wrote the change again, and where nothing can raise (a handler) Blender then
# evaluated it, under the words "so it was put back". A script's
# depsgraph_update_post handler writing Count 400,000, priced at the gate's
# checkpoint after it (part 12.1's case), with the price made to raise:
# refused in words, the Count put back, and the second pass Blender makes of
# what a post handler writes builds 16.


def raising(*args, **kwargs):
    raise ValueError("a price made to fail by the check")


real_judge = gate._judge


def judge_6d31b90(found, title=None):
    """The gate's judgement as 6d31b90 had it on a failing price: the
    change written again, and the error raised."""
    said = real_judge(found, title)
    if said and said.startswith("The vertex budget could not price"):
        gate._reapply(found.changes)
        raise RuntimeError(said)
    return said


def writes_400000(scene=None, depsgraph=None):
    m = bpy.data.objects["A"].modifiers["Array"]
    if m.count != 400_000:
        m.count = 400_000


for judge in (None, judge_6d31b90):
    reset_i3()
    a = cube_i3()
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    bpy.context.view_layer.update()
    bpy.app.handlers.depsgraph_update_post.append(writes_400000)
    try:
        with put(budget, 'price_state', raising), put(gate, '_judge', judge or real_judge):
            a.update_tag()
            said = mirror_i3()
            built = held_i3(a)
    finally:
        if writes_400000 in bpy.app.handlers.depsgraph_update_post:
            bpy.app.handlers.depsgraph_update_post.remove(writes_400000)
        gate.tidy_handlers()
    said = said or "; ".join(gate.take_refusals())
    if judge is None:
        check("12i.10 a depsgraph_update_post handler writing Count 400,000 whose price fails is refused in words, "
              "the Count put back, Blender at %s" % format(built or 0, ','),
              "could not price" in (said or "") and built == 16 and m.count == 2, (said, built, m.count))
    else:
        check("control: as on 6d31b90, the change written again and the error raised, Blender built %s"
              % format(built or 0, ','), built == 3_200_000, (said, built))
    with bare_i3():
        m.count = 2
reset_i3()

# -- i.9 the sweep's new fixtures with each gap put back ------------------------------
# Part 12.17's sweep (sweep2.py) steps five more fixtures since fix round 3: the
# scene's Time Stretching, a legacy texture, an F-curve modifier, nested
# instances realized and a curve object's curves given to Curve to Mesh. With the
# gate on it finds none of them (12.17's own check); here, with each of this
# round's fixes taken out at once — today's gaps put back — it has to find all
# five, so 12.17 can fail on them. Not run alone (`BUDGET_PARTS=12i`): the sweep
# is part 12's.
if 'sweep2' in globals() and 'CONTROL_ROUND3' in globals():
    kinds = {k: v for k, v in gate._COLLECTIONS.items() if v != 'textures'}
    with put(gate, '_COLLECTIONS', kinds), put(budget, '_textures_of', lambda obj: []), \
            put(gate, '_TIME_STRETCH', ()), put(budget, '_price_stretch', lambda changes: None), \
            put(gate, '_diff_action', diff_action_6d31b90), put(counting_i3.Geo, 'realized', realized_6d31b90), \
            put(counting_i3.Counter, 'count', count_given_as_mesh):
        gaps, _ = sweep2(gated=True, only=CONTROL_ROUND3, paths=False)
    found_settings = {(f[0], f[1]) for f in gaps}
    check("12i.9 control: the sweep's five fix round 3 fixtures, swept with the gate on and this round's fixes "
          "taken out, find %d of %d growing Blender past the budget" % (len(found_settings & CONTROL_ROUND3),
                                                                        len(CONTROL_ROUND3)),
          found_settings >= CONTROL_ROUND3, sorted(CONTROL_ROUND3 - found_settings))
    reset_i3()
