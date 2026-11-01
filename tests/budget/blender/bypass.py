"""Part 12 of the vertex budget's Blender check: the bypasses round 4's fix
round 2 review measured past the gate (October 21), each refused before
Blender builds it, with its control.

Run from verify.py, in its globals (`check`, `counts`, `clear`, `run`,
`gate_off`, `budget`, `sync`, `gate`, `context`). Every case is the review's
own, through the path it named — a script line, the Data API row
(`_blenderkit_sync.set_property`), the Operator Search
(`_blenderkit_sync.run_operator`), the app's timeline
(`_blenderkit_anim.frame_set`), the Item tab (`_blenderkit_item.set_data`) —
followed by the mirror's pass the app runs after every command. Each checks
that the change is refused in words and that Blender's own evaluated count
stays what it was; its control does the same with the gate off and has to
build the review's count, so the case is a real one.

Nothing here opens a window, a browser or another app.
"""
import bpy, bmesh, math, os, sys, time

anim_module = sys.modules.get("_blenderkit_anim") or load("_blenderkit_anim")
item_module = sys.modules.get("_blenderkit_item") or load("_blenderkit_item")
loopcut_module = sys.modules.get("_blenderkit_loopcut") or load("_blenderkit_loopcut")


def said_of(fn):
    try:
        fn()
    except RuntimeError as error:
        return str(error)
    return None


def mirror_pass():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def held(obj):
    """What Blender holds for `obj` now, without evaluating anything."""
    dg = bpy.context.view_layer.depsgraph
    evaluated = obj.evaluated_get(dg)
    if evaluated == obj:
        return None
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


class bare:
    """The gate off, as it was before it existed (the controls), and what
    was written inside evaluated before it is back on."""

    def __enter__(self):
        gate._busy += 1

    def __exit__(self, *exc):
        try:
            bpy.context.view_layer.update()
        finally:
            gate._busy -= 1


def own_handlers_only():
    """A script's handlers taken out of the four lists again."""
    for name in ('depsgraph_update_pre', 'depsgraph_update_post', 'frame_change_pre', 'frame_change_post'):
        items = getattr(bpy.app.handlers, name)
        items[:] = [f for f in items if getattr(f, '_blenderkit_gate', False)
                    or getattr(getattr(f, '__code__', None), 'co_filename', '').endswith('.py')
                    and os.path.basename(f.__code__.co_filename).startswith('_blenderkit_')]
    gate.install()


# An earlier part leaves the 3D cursor elsewhere (Extrude to Cursor), and
# the fixtures here add their cubes at it: run after parts 1 to 11, A sat
# away from its offset O and its controls made 72 vertices, not 3,200,008.
bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
bpy.context.scene.cursor.rotation_euler = (0.0, 0.0, 0.0)


def cube_array(count=2, name="A"):
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = name
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = count
    bpy.context.view_layer.update()
    return a, m


def fitted_offset(length=40.0):
    """A cube under an Array fitted to `length` whose offset is the empty O."""
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    bpy.ops.object.empty_add(location=(1.0, 0.0, 0.0))
    o = bpy.context.object
    o.name = "O"
    m = a.modifiers.new("Array", 'ARRAY')
    m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, o
    m.fit_type, m.fit_length = 'FIT_LENGTH', length
    bpy.context.view_layer.update()
    return a, o


def keyed():
    """A cube whose Array Count is keyed 2 at frame 1 and 400,000 at 10."""
    a, m = cube_array()
    scene = bpy.context.scene
    with bare():
        scene.frame_set(1)
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.count = 400_000
    m.keyframe_insert("count", frame=10)
    m.count = 2
    with bare():
        scene.frame_set(1)
    return a, m


def unlinked_x():
    """An object never linked to a scene, under an Array of 400,000."""
    mesh = bpy.data.meshes.new("X")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=2.0)
    bm.to_mesh(mesh)
    bm.free()
    x = bpy.data.objects.new("X", mesh)
    x.modifiers.new("Array", 'ARRAY').count = 400_000
    return x


def x_count(x):
    dg = bpy.context.view_layer.depsgraph
    evaluated = x.evaluated_get(dg)
    return len(evaluated.data.vertices) if evaluated != x else 0


def refused(said, number=None):
    return said is not None and ("2,500,000" in said or "would take Blender" in said or
                                 "only Blender" in said) and (number is None or format(number, ',') in said)


print("\n12. the bypasses round 4's fix round 2 review measured past the gate")

# -- 12.1 handlers ------------------------------------------------------------


def writes_count(scene=None, depsgraph=None):
    m = bpy.data.objects["A"].modifiers["Array"]
    if m.count != 400_000:
        m.count = 400_000


for where in ("depsgraph_update_post", "depsgraph_update_pre"):
    a, m = cube_array()
    getattr(bpy.app.handlers, where).append(writes_count)
    a.location.x = 1.0
    said = mirror_pass()
    check("12.1 a script's %s handler writing Count 400,000 (appended after the gate's) is refused at "
          "3,200,000, Blender's count stays 16" % where, refused(said, 3_200_000) and counts(a)[0] == 16, said)
    check("and the handler is still in its list, found where the script put it",
          writes_count in getattr(bpy.app.handlers, where))
    own_handlers_only()
    with bare():
        getattr(bpy.app.handlers, where).append(writes_count)
        a.location.x = 2.0
    check("control: with the gate off, the handler builds %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_000)
    own_handlers_only()

a, m = cube_array()
bpy.app.handlers.frame_change_post.append(writes_count)
said = said_of(lambda: bpy.context.scene.frame_set(2)) or mirror_pass()
check("a frame_change_post handler writing Count 400,000, then frame_set(2): refused at 3,200,000, Blender "
      "stays at 16", refused(said, 3_200_000) and counts(a)[0] == 16, said)
own_handlers_only()
with bare():
    bpy.context.scene.frame_set(1)

a, o = fitted_offset()
bpy.app.handlers.depsgraph_update_pre.clear()
o.location.x = 0.0001
bpy.context.view_layer.update()
said = mirror_pass()
check("`depsgraph_update_pre.clear()`, then O to 0.0001 and view_layer.update(): refused at 3,200,008 "
      "(the gate's handlers are put back), Blender stays at 328",
      refused(said, 3_200_008) and counts(a)[0] == 328 and gate._handler in bpy.app.handlers.depsgraph_update_pre,
      said)
with bare():
    o.location.x = 0.0001
check("control: with the gate off, A makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_008)

# A script's persistent load_post handler, and a file saved in Sculpt Mode
# (Blender sets the modes up only after the load's handlers): what it writes
# is evaluated by the load operator's own update, which builds the new file's
# depsgraph fresh and runs no handler.
from bpy.app.handlers import persistent

clear()
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
sphere.name = "A"
sphere.modifiers.new("Array", 'ARRAY').count = 2
bpy.ops.object.mode_set(mode='SCULPT')
saved = os.path.join(WORK, "sculpted.blend")
bpy.ops.wm.save_as_mainfile(filepath=saved, copy=True)
bpy.ops.object.mode_set(mode='OBJECT')


@persistent
def load_writes(*_):
    obj = bpy.data.objects.get("A")
    if obj is not None:
        obj.modifiers["Array"].count = 10_000


bpy.app.handlers.load_post.append(load_writes)
said = said_of(lambda: bpy.ops.wm.open_mainfile(filepath=saved)) or mirror_pass()
sphere = bpy.data.objects["A"]
check("a persistent load_post handler writing Count 10,000 as a file saved in Sculpt Mode opens: refused at "
      "4,820,000, the Array hidden, Blender at %s" % format(held(sphere) or 0, ','),
      refused(said, 4_820_000) and not sphere.modifiers["Array"].show_viewport and held(sphere) == 482, said)
bpy.ops.object.mode_set(mode='OBJECT')
with bare():
    bpy.ops.wm.open_mainfile(filepath=saved)
check("control: with the gate off, the handler builds %s" % format(held(bpy.data.objects["A"]) or 0, ','),
      held(bpy.data.objects["A"]) == 4_820_000)
bpy.app.handlers.load_post.remove(load_writes)
if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
    bpy.ops.object.mode_set(mode='OBJECT')
own_handlers_only()

# -- 12.2 drivers -------------------------------------------------------------
a, m = cube_array()
curve = m.driver_add("count")
curve.driver.expression = "400000"
said = mirror_pass()
check("12.2 a driver of '400000' on Array Count added by a script line is refused at 3,200,000, Blender "
      "stays at 16, and the driver is muted", refused(said, 3_200_000) and counts(a)[0] == 16 and curve.mute, said)
curve.mute = False
with bare():
    curve.driver.expression = "400000.0"
check("control: with the gate off, the driver builds %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_000)
m.driver_remove("count")

# Drivers on edits (the still-open high item): an empty's X drives Count.
a, m = cube_array()
bpy.ops.object.empty_add()
e = bpy.context.object
e.name = "E"
curve = m.driver_add("count")
var = curve.driver.variables.new()
var.type, var.name = 'TRANSFORMS', "x"
var.targets[0].id = e
var.targets[0].transform_type = 'LOC_X'
var.targets[0].transform_space = 'TRANSFORM_SPACE'
curve.driver.expression = "max(2, x)"
bpy.context.view_layer.update()
e.location.x = 400_000
said = mirror_pass()
check("a driver reading an empty's X: the X written to 400,000 is refused at 3,200,000, and the X is put back",
      refused(said, 3_200_000) and counts(a)[0] == 16 and e.location.x == 0.0, said)
with bare():
    e.location.x = 400_000
check("control: with the gate off, the driver builds %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_000)

# A driver reading a custom property: `E["n"] = …` tags nothing, so Blender
# reads it at the next tag (found re-measuring the round: 3,200,000 unpriced
# after `E.update_tag()`, before custom properties were compared).
a, m = cube_array()
bpy.ops.object.empty_add()
e = bpy.context.object
e.name = "E"
e["n"] = 2
e.location.x = 0.0                      # a tag: Blender's copy of E holds n
curve = m.driver_add("count")
var = curve.driver.variables.new()
var.type, var.name = 'SINGLE_PROP', "n"
var.targets[0].id = e
var.targets[0].data_path = '["n"]'
curve.driver.expression = "n"
e.update_tag()
mirror_pass()
e["n"] = 400_000
e.update_tag()
said = mirror_pass()
check("a driver reading an empty's custom property: `E[\"n\"] = 400000` and a tag refused at 3,200,000, n put "
      "back to %s" % e["n"], refused(said, 3_200_000) and counts(a)[0] == 16 and e["n"] == 2, said)
# One the copy has never held (set with no tag since): no value to put back,
# so the driver reading it is muted and the value left as written.
e2 = bpy.data.objects.new("E2", None)
bpy.context.scene.collection.objects.link(e2)
mirror_pass()
e2["k"] = 2
var.targets[0].id, var.targets[0].data_path = e2, '["k"]'
mirror_pass()
e2["k"] = 400_000
e2.update_tag()
said = mirror_pass()
check("one set with no tag before (Blender's copy never held it): refused at 3,200,000, the driver muted, "
      "the value left as written", refused(said, 3_200_000) and counts(a)[0] < 3_200_000 and curve.mute
      and e2["k"] == 400_000, said)
curve.mute = False
var.targets[0].id, var.targets[0].data_path = e, '["n"]'
mirror_pass()
with bare():
    e["n"] = 400_000
    e.update_tag()
check("control: with the gate off, the custom property builds %s" % format(counts(a)[0], ','),
      counts(a)[0] == 3_200_000)

# -- 12.3 animation on every path ----------------------------------------------
a, m = keyed()
from bpy_extras import anim_utils
bag = anim_utils.action_get_channelbag_for_slot(a.animation_data.action, a.animation_data.action_slot)
bag.fcurves[0].keyframe_points[0].co.y = 400_000
said = mirror_pass()
check("12.3 a key written to 400,000 at the current frame by a script line is refused at 3,200,000, the key "
      "put back (%g)" % bag.fcurves[0].keyframe_points[0].co.y,
      refused(said, 3_200_000) and counts(a)[0] == 16 and bag.fcurves[0].keyframe_points[0].co.y == 2.0, said)
with bare():
    bag.fcurves[0].keyframe_points[0].co.y = 400_000
check("control: with the gate off, the key builds %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_000)

paths = (
    ("the Data API row's frame_current 10",
     lambda: sync.set_property('bpy.context.scene', 'frame_current', 10)),
    ("a script line's scene.frame_current = 10", lambda: setattr(bpy.context.scene, 'frame_current', 10)),
    ("the search's screen.frame_offset(delta=9)", lambda: sync.run_operator('screen.frame_offset', {'delta': 9})),
    ("the search's screen.frame_jump(end=True)", lambda: sync.run_operator('screen.frame_jump', {'end': True})),
    ("the search's screen.keyframe_jump(next=True)",
     lambda: sync.run_operator('screen.keyframe_jump', {'next': True})),
    ("a script's frame_set(10)", lambda: bpy.context.scene.frame_set(10)),
)
for words, step in paths:
    a, m = keyed()
    bpy.context.scene.frame_end = 10
    a.select_set(True)
    bpy.context.view_layer.objects.active = a
    said = said_of(step) or mirror_pass()
    check("%s, where the key is 400,000: refused at 3,200,000, the frame stays 1 and Blender at 16" % words,
          refused(said, 3_200_000) and counts(a)[0] == 16 and bpy.context.scene.frame_current == 1, said)
a, m = keyed()
with bare():
    bpy.context.scene.frame_set(10)
check("control: with the gate off, Blender's own frame 10 makes %s" % format(counts(a)[0], ','),
      counts(a)[0] == 3_200_000)
with bare():
    bpy.context.scene.frame_set(1)

for words, step in (("the app's timeline", lambda: anim_module.frame_set(10)),
                    ("a script's frame_set", lambda: bpy.context.scene.frame_set(10))):
    a, m = keyed()
    ad = a.animation_data
    action = ad.action
    ad.nla_tracks.new().strips.new("S", 1, action)
    ad.action = None
    m.count = 2
    with bare():
        bpy.context.scene.frame_set(1)
    said = said_of(step) or mirror_pass()
    check("%s's frame 10 with the key in an NLA strip and no active action: refused at 3,200,000, Blender at %s"
          % (words, format(counts(a)[0], ',')),
          refused(said, 3_200_000) and counts(a)[0] == 16 and bpy.context.scene.frame_current == 1, said)
said = said_of(lambda: anim_module.frame_set(3))
check("and frame 3 passes (%s; Blender's own NLA evaluation, read with the Array hidden)" % format(counts(a)[0], ','),
      said is None and bpy.context.scene.frame_current == 3 and 600_000 < counts(a)[0] < 2_500_000, said)
with bare():
    bpy.context.scene.frame_set(10)
check("control: with the gate off, the strip's frame 10 makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_000)
with bare():
    bpy.context.scene.frame_set(1)

# -- 12.4 Geometry Nodes ------------------------------------------------------


def grid_group(x, y, name="G"):
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    group = bpy.data.node_groups.new(name, 'GeometryNodeTree')
    group.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    group.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    group.nodes.new('NodeGroupInput')
    out = group.nodes.new('NodeGroupOutput')
    grid = group.nodes.new('GeometryNodeMeshGrid')
    grid.name = "Grid"
    grid.inputs[2].default_value, grid.inputs[3].default_value = x, y
    group.links.new(grid.outputs[0], out.inputs[0])
    m = a.modifiers.new("GeometryNodes", 'NODES')
    m.node_group = group
    return a, group, grid


a, group, grid = grid_group(1900, 1900)
said = mirror_pass()
check("12.4 a script line's node group with a Grid of 1,900 × 1,900 on a cube is refused at 3,610,000, "
      "Blender at %s" % format(counts(a)[0], ','), refused(said, 3_610_000) and counts(a)[0] == 8, said)
a, group, grid = grid_group(10, 10)
bpy.context.view_layer.update()
grid.inputs[2].default_value = grid.inputs[3].default_value = 1900
said = mirror_pass()
check("the Grid's Vertices X and Y raised from 10 to 1,900 by a script line: refused at 3,610,000, both put back, "
      "Blender at 100", refused(said, 3_610_000) and counts(a)[0] == 100 and grid.inputs[2].default_value == 10, said)
row = "bpy.data.node_groups[%r].nodes['Grid'].inputs[%d]"
first = said_of(lambda: sync.set_property(row % (group.name, 2), 'default_value', 1900))
second = said_of(lambda: sync.set_property(row % (group.name, 3), 'default_value', 1900))
check("the Data API row: X 1,900 passes (19,000), then Y 1,900 is refused at 3,610,000",
      first is None and refused(second, 3_610_000) and counts(a)[0] == 19_000, (first, second))
with bare():
    grid.inputs[3].default_value = 1900
check("control: with the gate off, the group builds %s" % format(counts(a)[0], ','), counts(a)[0] == 3_610_000)
clear()
bpy.ops.mesh.primitive_cube_add()
bpy.context.object.modifiers.new("GeometryNodes", 'NODES')
a, group, grid = grid_group(100, 100)
said = mirror_pass()
check("ordinary: Add Modifier ▸ Geometry Nodes (an empty group) and a Grid of 100 × 100 pass (%s)"
      % format(counts(a)[0], ','), said is None and counts(a)[0] == 10_000, said)

# -- 12.5 settings held in collection items ------------------------------------
a, o = fitted_offset()
armature = bpy.data.armatures.new("Arm")
rig = bpy.data.objects.new("Rig", armature)
bpy.context.scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='EDIT')
bone = armature.edit_bones.new("B")
bone.head, bone.tail = (0.0, 0.0, 0.0), (0.0, 0.0, 1.0)
bpy.ops.object.mode_set(mode='OBJECT')
constraint = o.constraints.new('ARMATURE')
target = constraint.targets.new()
target.target, target.subtarget, target.weight = rig, "B", 0.0
rig.pose.bones["B"].location = (-0.9999, 0.0, 0.0)
bpy.context.view_layer.update()
o.constraints[0].targets[0].weight = 1.0
said = mirror_pass()
check("12.5 O under an Armature constraint, its target's weight 0 → 1 by a script line: refused at 3,199,480, "
      "the weight put back", refused(said, 3_199_480) and counts(a)[0] == 328 and target.weight == 0.0, said)
said = said_of(lambda: sync.set_property("bpy.data.objects['O'].constraints[0].targets[0]", 'weight', 1.0))
check("the Data API row's weight 1: refused at 3,199,480", refused(said, 3_199_480) and counts(a)[0] == 328, said)
with bare():
    target.weight = 1.0
check("control: with the gate off, A makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_199_472)

# -- 12.6 mesh attributes -------------------------------------------------------


def beveled_grid():
    clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=119, y_subdivisions=119)
    g = bpy.context.object
    g.name = "G"
    m = g.modifiers.new("Bevel", 'BEVEL')
    m.limit_method, m.segments = 'WEIGHT', 14
    bpy.context.view_layer.update()
    return g


def weights(g):
    if g.mode == 'EDIT':
        g.update_from_editmode()
    a = g.data.attributes.get('bevel_weight_edge')
    if a is None:
        return 0.0
    copy = g.data.copy()
    try:
        values = [d.value for d in copy.attributes['bevel_weight_edge'].data]
    finally:
        bpy.data.meshes.remove(copy)
    return max(values) if values else 0.0


g = beveled_grid()
mesh = g.data
weight = mesh.attributes.new('bevel_weight_edge', 'FLOAT', 'EDGE')
bpy.context.view_layer.update()
weight.data.foreach_set('value', [1.0] * len(mesh.edges))
mesh.update()
said = mirror_pass()
check("12.6 a 120 × 120 grid under a Bevel limited by Weight at 14 segments: a script line's Bevel Weights in "
      "Object Mode refused, Blender at 14,400, the weights put back",
      refused(said) and counts(g)[0] == 14_400 and weights(g) == 0.0, said)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
said = said_of(lambda: item_module.set_data('bevel_weight_edge', 1.0))
check("the Sidebar Item tab's Edge Data ▸ Bevel Weight 1 in Edit Mode is refused, the weights put back",
      refused(said) and weights(g) == 0.0, said)
bpy.ops.mesh.select_mode(type='EDGE')
mesh.attributes.active = mesh.attributes['bevel_weight_edge']
said = said_of(lambda: bpy.ops.mesh.attribute_set(value_float=1.0))
check("`mesh.attribute_set(value_float=1.0)` in Edit Mode is refused, the weights put back",
      refused(said) and weights(g) == 0.0, said)
bpy.ops.object.mode_set(mode='OBJECT')
check("and Blender holds 14,400 after leaving Edit Mode", counts(g)[0] == 14_400)
with bare():
    weight = g.data.attributes['bevel_weight_edge']
    weight.data.foreach_set('value', [1.0] * len(g.data.edges))
    g.data.update()
check("control: with the gate off, the weights build %s" % format(counts(g)[0], ','), counts(g)[0] > 2_500_000)

# -- 12.7 Proportional Editing ----------------------------------------------------
a, o = fitted_offset()
bpy.ops.object.empty_add(location=(1.05, 0.0, 0.0))
e = bpy.context.object
e.name = "E"
for other in bpy.context.view_layer.objects:
    other.select_set(False)
e.select_set(True)
bpy.context.view_layer.objects.active = e
bpy.context.view_layer.update()
move = dict(value=(-0.9999, 0.0, 0.0), use_proportional_edit=True, proportional_edit_falloff='CONSTANT',
            proportional_size=1.0)
said = said_of(lambda: bpy.ops.transform.translate(**move))
check("12.7 an Object Mode Move of E with Proportional Editing that moves O (unselected) to 0.0001: refused "
      "at 3,199,472, O stays at 1", refused(said) and counts(a)[0] == 328 and abs(o.location.x - 1.0) < 1e-6, said)
with bare():
    bpy.ops.transform.translate(**move)
check("control: with the gate off, the move builds %s" % format(counts(a)[0], ','), counts(a)[0] > 2_500_000)

# -- 12.8 the paint modes and Sculpt Mode ------------------------------------------
for mode in ('WEIGHT_PAINT', 'VERTEX_PAINT', 'TEXTURE_PAINT', 'SCULPT'):
    a, m = cube_array()
    m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    bpy.context.view_layer.update()
    a.select_set(True)
    bpy.context.view_layer.objects.active = a
    bpy.ops.object.mode_set(mode=mode)
    for v in a.data.vertices:
        v.co.x *= 0.00005
    a.data.update()
    said = mirror_pass()
    check("12.8 in %s, a script line scaling the cube's x by 0.00005 under an Array fitted to 40: refused at "
          "3,200,008, Blender at 168" % mode, refused(said, 3_200_008) and counts(a)[0] == 168, said)
    with bare():
        for v in a.data.vertices:
            v.co.x *= 0.00005
        a.data.update()
    check("control: with the gate off, Blender makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_008)
    bpy.ops.object.mode_set(mode='OBJECT')

# -- 12.9 bulk writes inside an operator's call -------------------------------------


class BK_OT_thin(bpy.types.Operator):
    bl_idname = "bk_test.thin"
    bl_label = "Thin"

    def execute(self, context):
        mesh = bpy.data.objects["A"].data
        for v in mesh.vertices:
            v.co.x *= 0.00005
        mesh.update()
        return {'FINISHED'}


bpy.utils.register_class(BK_OT_thin)
a, m = cube_array()
m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
bpy.context.view_layer.update()
said = said_of(lambda: bpy.ops.bk_test.thin())
check("12.9 the same thinning as a registered Operator is refused at 3,200,008, Blender at 168",
      refused(said, 3_200_008) and counts(a)[0] == 168, said)
text = bpy.data.texts.new("thin.py")
text.write("import bpy\nm = bpy.data.objects['A'].data\nfor v in m.vertices:\n    v.co.x *= 0.00005\nm.update()\n")
said = None
with context.temp_override_view3d("test"):
    with bpy.context.temp_override(edit_text=text):
        said = said_of(lambda: bpy.ops.text.run_script())
said = said or mirror_pass()
check("as a Text run by `text.run_script`: refused at 3,200,008, Blender at 168",
      refused(said, 3_200_008) and counts(a)[0] == 168, said)
with bare():
    bpy.ops.bk_test.thin()
check("control: with the gate off, the operator builds %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_008)
bpy.utils.unregister_class(BK_OT_thin)
# The crash this skip was for: leaving Edit Mode, then the gate's read of the
# copy Blender evaluated there (`_edit_meshes_then`).
a, m = cube_array()
m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
bpy.context.view_layer.objects.active = a
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.transform.resize(value=(0.5, 1.0, 1.0))
bpy.ops.object.mode_set(mode='OBJECT')
check("leaving Edit Mode after a Resize, read by the gate in the update after: no crash, %s vertices"
      % format(counts(a)[0], ','), counts(a)[0] > 168)

# -- 12.10 other view layers and scenes ------------------------------------------------
clear()
s2 = bpy.data.scenes.new("S2")
x = unlinked_x()
s2.collection.objects.link(x)
with bpy.context.temp_override(scene=s2, view_layer=s2.view_layers[0]):
    dg = bpy.context.evaluated_depsgraph_get()
    made = len(x.evaluated_get(dg).data.vertices)
said = mirror_pass()
check("12.10 a new scene S2 with a cube under an Array of 400,000, evaluated through `temp_override(scene=S2, "
      "...)`: refused at 3,200,000, Blender built %s" % format(made, ','), refused(said, 3_200_000) and made == 8, said)
bpy.data.scenes.remove(s2)
clear()
scene = bpy.context.scene
hidden = bpy.data.collections.new("Hidden")
scene.collection.children.link(hidden)
x = unlinked_x()
hidden.objects.link(x)
bpy.context.view_layer.layer_collection.children["Hidden"].exclude = True
bpy.context.view_layer.update()
second = scene.view_layers.new("VL2")
with bpy.context.temp_override(view_layer=second):
    dg = bpy.context.evaluated_depsgraph_get()
    made = len(x.evaluated_get(dg).data.vertices)
said = mirror_pass()
check("a collection excluded from the view layer, evaluated through a second view layer: refused at 3,200,000, "
      "Blender built %s" % format(made, ','), refused(said, 3_200_000) and made == 8, said)
scene.view_layers.remove(second)
s3 = bpy.data.scenes.new("S3")
x = unlinked_x()
s3.collection.objects.link(x)
with bare():
    with bpy.context.temp_override(scene=s3, view_layer=s3.view_layers[0]):
        dg = bpy.context.evaluated_depsgraph_get()
        made = len(x.evaluated_get(dg).data.vertices)
check("control: with the gate off, the new scene builds %s" % format(made, ','), made == 3_200_000)
bpy.data.scenes.remove(s3)

# Another scene's frame_set: a script's, on a scene Blender has not
# evaluated (its depsgraph made as the frame change begins) and on one it has.


def keyed_in(scene, name):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=2.0)
    bm.to_mesh(mesh)
    bm.free()
    x = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(x)
    m = x.modifiers.new("Array", 'ARRAY')
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.count = 400_000
    m.keyframe_insert("count", frame=10)
    m.count = 2
    return x


def count_in(scene, obj):
    dg = scene.view_layers[0].depsgraph
    evaluated = obj.evaluated_get(dg) if dg is not None else obj
    return len(evaluated.data.vertices) if evaluated != obj else 0


clear()
s2 = bpy.data.scenes.new("S2")
x2 = keyed_in(s2, "X2")
said = said_of(lambda: s2.frame_set(10)) or mirror_pass()
check("another scene never evaluated, its Count keyed 400,000 at frame 10: its frame_set(10) refused at 3,200,000, "
      "Blender built %s" % format(count_in(s2, x2), ','), refused(said, 3_200_000) and count_in(s2, x2) <= 16, said)
s3 = bpy.data.scenes.new("S3")
x3 = keyed_in(s3, "X3")
with bare():
    s3.frame_set(1)
said = said_of(lambda: s3.frame_set(10)) or mirror_pass()
check("the same in a scene Blender has evaluated: refused, its frame stays %d and Blender at %s"
      % (s3.frame_current, format(count_in(s3, x3), ',')),
      refused(said, 3_200_000) and count_in(s3, x3) == 16 and s3.frame_current == 1, said)
with bare():
    s3.frame_set(10)
check("control: with the gate off, its frame 10 makes %s" % format(count_in(s3, x3), ','),
      count_in(s3, x3) == 3_200_000)
bpy.data.scenes.remove(s2)
bpy.data.scenes.remove(s3)

# -- 12.11 what Blender evaluates as a dependency ------------------------------------------
for words, attach in (
        ("instanced through an empty's Collection instance",
         lambda a, x: (lambda c: (c.objects.link(x), setattr(a, 'instance_type', 'COLLECTION'),
                                  setattr(a, 'instance_collection', c)))(bpy.data.collections.new("XC"))),
        ("as A's Shrinkwrap target", lambda a, x: setattr(a.modifiers.new("SW", 'SHRINKWRAP'), 'target', x)),
        ("as A's Data Transfer source", lambda a, x: setattr(a.modifiers.new("DT", 'DATA_TRANSFER'), 'object', x))):
    a, m = cube_array()
    if words.startswith("instanced"):
        bpy.ops.object.empty_add()
        a = bpy.context.object
    x = unlinked_x()
    attach(a, x)
    said = mirror_pass()
    check("12.11 X, never linked, under an Array of 400,000, %s: refused at 3,200,000, Blender built %s"
          % (words, format(x_count(x), ',')), refused(said, 3_200_000) and x_count(x) <= 8, said)
a, m = cube_array()
x = unlinked_x()
with bare():
    a.modifiers.new("SW", 'SHRINKWRAP').target = x
check("control: with the gate off, X as a Shrinkwrap target builds %s" % format(x_count(x), ','),
      x_count(x) == 3_200_000)

# -- 12.12 append and link ---------------------------------------------------------------
clear()
x = unlinked_x()
path = os.path.join(WORK, "appended.blend")
bpy.data.libraries.write(path, {x})
bpy.data.objects.remove(x)
said = said_of(lambda: bpy.ops.wm.append(directory=path + "/Object/", filename="X"))
x = bpy.data.objects.get("X")
check("12.12 `wm.append` of an object under an Array of 400,000 written by `bpy.data.libraries.write`: refused at "
      "3,200,000, Blender built %s" % format(x_count(x) if x else 0, ','),
      refused(said, 3_200_000) and (x is None or x_count(x) <= 8), said)
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)
with bare():
    bpy.ops.wm.append(directory=path + "/Object/", filename="X")
x = bpy.data.objects.get("X")
check("control: with the gate off, the append builds %s" % format(x_count(x) if x else 0, ','),
      x is not None and x_count(x) == 3_200_000)

# -- 12.13 a text's Edit Mode --------------------------------------------------------------
clear()
bpy.ops.object.text_add()
t = bpy.context.object
t.name = "T"
t.modifiers.new("Array", 'ARRAY').count = 12
bpy.context.view_layer.update()
bpy.ops.object.mode_set(mode='EDIT')
said = said_of(lambda: bpy.ops.font.text_insert(text='W' * 20000))
in_edit = held(t)
bpy.ops.object.mode_set(mode='OBJECT')
check("12.13 a text under an Array of 12 (2,124) in Edit Mode, `font.text_insert(text='W' * 20000)`: refused at "
      "3,122,124, Blender held %s in Edit Mode, the body back to %r" % (format(in_edit or 0, ','), t.data.body),
      refused(said, 3_122_124) and in_edit == 2_124 and t.data.body == "Text", said)
bpy.ops.object.mode_set(mode='EDIT')
said = said_of(lambda: bpy.ops.font.text_insert(text='AB'))
bpy.ops.font.move(type='LINE_BEGIN')
said = said or said_of(lambda: bpy.ops.font.text_insert(text='Z'))
bpy.ops.object.mode_set(mode='OBJECT')
check("ordinary: 'AB', then 'Z' at the line's start, pass where the cursor is (%r)" % t.data.body,
      said is None and t.data.body == "ZTextAB", said)
bpy.ops.object.mode_set(mode='EDIT')
with bare():
    bpy.ops.font.text_insert(text='W' * 20000)
check("control: with the gate off, Edit Mode builds %s" % format(held(t) or 0, ','), (held(t) or 0) > 3_000_000)
with bare():
    bpy.ops.object.mode_set(mode='OBJECT')

# -- 12.14 Grease Pencil ----------------------------------------------------------------------


def points_of(o):
    evaluated = o.evaluated_get(bpy.context.view_layer.depsgraph)
    n = 0
    for layer in evaluated.data.layers:
        frame = layer.current_frame()
        if frame is not None and frame.drawing is not None:
            position = frame.drawing.attributes.get('position')
            n += len(position.data) if position is not None else 0
    return n


clear()
bpy.ops.object.grease_pencil_add(type='MONKEY')
gp = bpy.context.object
gp.name = "GP"
bpy.context.view_layer.update()
gp.modifiers.new("Array", 'GREASE_PENCIL_ARRAY').count = 4111
said = mirror_pass()
check("12.14 the Monkey (1,216 points) under a Grease Pencil Array of 4,111: refused at 4,998,976, Blender at %s"
      % format(points_of(gp), ','), refused(said, 4_998_976) and points_of(gp) == 1_216, said)
subdivide = gp.modifiers.new("Subdivide", 'GREASE_PENCIL_SUBDIV')
subdivide.level = 2
gp.modifiers.remove(gp.modifiers["Array"])
said = mirror_pass()
check("ordinary: Subdivide Level 2 passes (%s points)" % format(points_of(gp), ','), said is None)
subdivide.level = 16
said = mirror_pass()
check("and Level 16 is refused, put back to 2", refused(said) and subdivide.level == 2, said)
with bare():
    gp.modifiers.remove(subdivide)
    gp.modifiers.new("Array", 'GREASE_PENCIL_ARRAY').count = 4111
check("control: with the gate off, the Array makes %s points" % format(points_of(gp), ','),
      points_of(gp) == 4_998_976)

# -- 12.15 hair -----------------------------------------------------------------------------------
clear()
bpy.ops.mesh.primitive_plane_add()
plane = bpy.context.object
settings = plane.modifiers.new("Hair", 'PARTICLE_SYSTEM').particle_system.settings
settings.type, settings.count, settings.display_step = 'HAIR', 10_000, 3
said = mirror_pass()
check("12.15 a plane with hair Count 10,000, Display Steps 3, passes (90,000 points)", said is None, said)
settings.child_type, settings.child_percent = 'INTERPOLATED', 100
said = mirror_pass()
check("Interpolated children at Display Amount 100 (1,000,000 strands): refused, put back to %s"
      % settings.child_type, refused(said) and settings.child_type == 'NONE', said)
with bare():
    settings.child_type, settings.child_percent = 'INTERPOLATED', 100
evaluated = plane.evaluated_get(bpy.context.evaluated_depsgraph_get())
strands = len(evaluated.particle_systems[0].child_particles)
check("control: with the gate off, Blender makes %s child strands" % format(strands, ','), strands == 1_000_000)
with bare():
    settings.child_type = 'NONE'

# -- 12.16 Loop Cut's time ----------------------------------------------------------------------------
clear()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
cut = dict(MESH_OT_loopcut={"number_cuts": 32000, "smoothness": 0, "falloff": 'INVERSE_SQUARE', "object_index": 0,
                            "edge_index": 0, "mesh_select_mode_init": (False, True, False)},
           TRANSFORM_OT_edge_slide={"value": 0})
started = time.perf_counter()
with context.temp_override_view3d("test"):
    said = said_of(lambda: bpy.ops.mesh.loopcut_slide(**cut))
took = time.perf_counter() - started
check("12.16 a script's `mesh.loopcut_slide` of 32,000 cuts on the cube (the review: 342 s) is refused for its "
      "time in %.3f s" % took, said is not None and "would take Blender" in said and took < 1.0, said)
said = said_of(lambda: loopcut_module.check(0, 32000))
check("and so is the app's Loop Cut", said is not None and "would take Blender" in said, said)
cut["MESH_OT_loopcut"]["number_cuts"] = 4000
started = time.perf_counter()
with bare():
    with context.temp_override_view3d("test"):
        loopcut_module_check = loopcut_module.check_call
        loopcut_module.check_call = lambda *a, **k: None
        try:
            bpy.ops.mesh.loopcut_slide(**cut)
        finally:
            loopcut_module.check_call = loopcut_module_check
took = time.perf_counter() - started
check("control: unpriced, 4,000 cuts (an eighth of them) already take %.2f s" % took, took > 0.3, took)
bpy.ops.object.mode_set(mode='OBJECT')
clear()
own_handlers_only()

# -- a put-back value that frees another change's struct ---------------------------------
# Found re-running part 2 on this round's tree: a Fluid domain's Combined
# Export, put back, made Blender remove and remake its secondary particle
# systems, and the gate then set the removed Foam system's `settings` again
# (Blender 5.2.1 crashed in `psys_changed_type`, exit 139, twice in a row).
bpy.ops.mesh.primitive_cube_add()
fluid = bpy.context.object
domain = fluid.modifiers.new("Fluid", 'FLUID')
domain.fluid_type = 'DOMAIN'
settings = domain.domain_settings
settings.domain_type = 'LIQUID'
settings.use_spray_particles = settings.use_foam_particles = settings.use_bubble_particles = True
settings.sndparticle_combined_export = 'OFF'
mirror_pass()
foam = fluid.particle_systems["Foam"]
change = gate.Change(foam, 'settings', foam.settings, foam.settings, 1)
with bare():
    settings.sndparticle_combined_export = 'SPRAY_FOAM'
check("a change on the Foam system, which Combined Export ▸ Spray + Foam removes: the gate finds it gone and "
      "writes nothing to it", not gate._live(change) and fluid.particle_systems.get("Foam") is None and
      said_of(lambda: gate._reapply([change])) is None)
said = None
for value in ('SPRAY_BUBBLES', 'OFF', 'SPRAY_BUBBLES', 'FOAM_BUBBLES', 'OFF', 'SPRAY_FOAM_BUBBLES', 'OFF'):
    settings.sndparticle_combined_export = value
    said = said or mirror_pass()
check("and the export stepped through its values with the mirror's pass after each: no crash, nothing refused, "
      "systems %s" % ", ".join(p.name for p in fluid.particle_systems), said is None, said)
clear()

# -- 12.17 the sweep of what the state sweep never wrote ------------------------------------
# (BK_SKIP_SWEEP2=1 leaves it out, for the controls that take one fix out at a time.)
if os.environ.get("BK_SKIP_SWEEP2") != "1":
    exec(compile(open(str(ROOT / "tests/budget/blender/sweep2.py")).read(), "sweep2.py", "exec"), globals())

# -- 12i fix round 3: the gaps a user reaches from the interface (October 29) -------
exec(compile(open(str(ROOT / "tests/budget/blender/interface3.py")).read(), "interface3.py", "exec"), globals())

# -- 12j the review of 12i's work, answered (October 29) ---------------------------
exec(compile(open(str(ROOT / "tests/budget/blender/interface4.py")).read(), "interface4.py", "exec"), globals())
