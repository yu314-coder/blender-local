"""Part 12's sweep: what the state sweep (part 9, 9.13) never wrote (round 4's
fix round 2 review, October 21: "It never writes a pointer, a string,
a collection item, the Scene (frame), F-curve keys, drivers, node sockets,
mesh attributes, handler lists, or anything in Paint or Sculpt Mode").

Run from verify.py after bypass.py, in its globals. On fixtures whose counts
hang on them, bounded so that a bypass found stays in memory:

  * the settings of what the state sweep did not step — a constraint's target
    item, a Geometry Nodes group's node sockets, an F-curve's key, the
    scene's frame, a Grease Pencil modifier, a particle system's settings —
    each stepped up and down (`ladders`) and written bare;
  * every numeric setting's first step past the budget (by the budget's own
    count, `first_past_budget`) written again through each other way a value
    reaches Blender: a driver whose expression is that number, a driver
    reading a custom property written to it, a script's
    `depsgraph_update_post` handler, a key at the next frame and
    `frame_set`, and a registered operator's call;
  * every Object and Collection pointer of what is swept set to X, an object
    under an Array of 400,000 that no view layer holds, and to a collection
    that holds it;
  * a mesh's vertices moved and its attributes written in Object Mode, Weight
    Paint, Vertex Paint, Texture Paint and Sculpt Mode.

After each write and the mirror's pass, Blender's own count of every object
it evaluated — meshes, curves, texts and metaballs, a Grease Pencil's points
and a particle system's — may not be past the budget and more than before.
The control, with the gate off, has to find each kind.

Nothing here opens a window, a browser or another app.
"""
import bpy, bmesh, math, time
from bpy_extras import anim_utils

BUDGET_S = budget.BUDGET


def everyone2():
    """Every object Blender evaluated, by name: its mesh's vertices, its Grease
    Pencil's points and its particle systems' points (a hair strand's display
    points each) — whether or not a view layer holds it (a dependency)."""
    dg = bpy.context.evaluated_depsgraph_get()
    found = {}
    for obj in bpy.data.objects:
        ev = obj.evaluated_get(dg)
        if ev == obj:
            continue
        n = 0
        if obj.type in ('MESH', 'CURVE', 'SURFACE', 'FONT', 'META'):
            if obj.mode == 'EDIT' and obj.type in ('MESH', 'CURVE', 'SURFACE'):
                obj.update_from_editmode()
            mesh = ev.to_mesh()
            n = len(mesh.vertices) if mesh is not None else 0
            ev.to_mesh_clear()
        elif obj.type == 'GREASEPENCIL':
            for layer in ev.data.layers:
                frame = layer.current_frame()
                if frame is not None and frame.drawing is not None:
                    position = frame.drawing.attributes.get('position')
                    n += len(position.data) if position is not None else 0
        for system in getattr(ev, 'particle_systems', ()):
            per = 2 ** system.settings.display_step + 1 if system.settings.type == 'HAIR' else 1
            n += (len(system.particles) + len(system.child_particles)) * per
        found[obj.name] = n
    return found


def sweep2_fixture():
    """A: one vertex under an Array fitted to 40, its offset O 1 m away, O
    under an Armature constraint whose target's bone is posed −0.99999 m at
    weight 0. FA: the same, its offset FO keyed 1 at frame 1 and 0.00001 at
    frame 2 (constant), so that frame 2 is 4,000,000. N: a Grid of 1 ×
    20,000 in a node group. GPG: a stroke of 20,000 points under a Grease
    Pencil Array of 1. H: a plane with 1,000 hair strands of 9 points. Q: a
    120 × 120 grid under a Bevel limited by Weight at 14 segments (every
    edge weighted, 3,335,306 in the app). B: a quad 1 m wide under an Array
    fitted to 3 by its size (4 µm wide, 3,000,000). X: a cube under an Array
    of 400,000, in no scene. CP: an empty whose custom property a driver
    reads. The meshes have faces because the paint and
    sculpt modes take only meshes that do."""
    clear()
    for collection in (bpy.data.actions, bpy.data.node_groups, bpy.data.grease_pencils, bpy.data.particles,
                       bpy.data.collections):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)
    with bare():
        bpy.context.scene.frame_set(1)
    objects = {}

    def vertex(name, location=(0, 0, 0)):
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata([(0.0, 0.0, 0.0)], [], [])
        obj = bpy.data.objects.new(name, mesh)
        obj.location = location
        bpy.context.scene.collection.objects.link(obj)
        return obj

    def fitted_to(obj, offset):
        m = obj.modifiers.new("Array", 'ARRAY')
        m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, offset
        m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
        return m

    a = vertex("A")
    o = bpy.data.objects.new("O", None)
    bpy.context.scene.collection.objects.link(o)
    o.location = (1.0, 0.0, 0.0)
    fitted_to(a, o)
    armature = bpy.data.armatures.new("Arm2")
    rig = bpy.data.objects.new("R2", armature)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode='EDIT')
    bone = armature.edit_bones.new("B")
    bone.head, bone.tail = (0.0, 0.0, 0.0), (0.0, 0.0, 1.0)
    bpy.ops.object.mode_set(mode='OBJECT')
    rig.pose.bones["B"].location = (-0.99999, 0.0, 0.0)
    constraint = o.constraints.new('ARMATURE')
    target = constraint.targets.new()
    target.target, target.subtarget, target.weight = rig, "B", 0.0
    objects.update(A=a, O=o, R2=rig)

    fa = vertex("FA", (0, 8, 0))
    fo = bpy.data.objects.new("FO", None)
    bpy.context.scene.collection.objects.link(fo)
    fo.location = (1.0, 8.0, 0.0)
    fitted_to(fa, fo)
    fo.keyframe_insert("location", index=0, frame=1)
    fo.location.x = 1e-5
    fo.keyframe_insert("location", index=0, frame=2)
    fo.location.x = 1.0
    # Constant between the keys: frame 1 holds 1 until frame 2.
    for curve in anim_utils.action_get_channelbag_for_slot(fo.animation_data.action,
                                                           fo.animation_data.action_slot).fcurves:
        for key in curve.keyframe_points:
            key.interpolation = 'CONSTANT'
    objects.update(FA=fa, FO=fo)

    bpy.ops.mesh.primitive_cube_add(location=(8, 0, 0))
    n = bpy.context.object
    n.name = "N"
    group = bpy.data.node_groups.new("SweepGrid", 'GeometryNodeTree')
    group.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    group.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    group.nodes.new('NodeGroupInput')
    out = group.nodes.new('NodeGroupOutput')
    grid = group.nodes.new('GeometryNodeMeshGrid')
    grid.name = "Grid"
    grid.inputs[2].default_value, grid.inputs[3].default_value = 1, 20_000
    group.links.new(grid.outputs[0], out.inputs[0])
    n.modifiers.new("GeometryNodes", 'NODES').node_group = group
    objects.update(N=n)

    gpd = bpy.data.grease_pencils.new("GPG")
    layer = gpd.layers.new("L")
    drawing = layer.frames.new(1).drawing
    drawing.add_strokes([20_000])
    gpg = bpy.data.objects.new("GPG", gpd)
    bpy.context.scene.collection.objects.link(gpg)
    gpg.modifiers.new("Array", 'GREASE_PENCIL_ARRAY').count = 1
    objects.update(GPG=gpg)

    bpy.ops.mesh.primitive_plane_add(location=(-8, 0, 0))
    h = bpy.context.object
    h.name = "H"
    settings = h.modifiers.new("Hair", 'PARTICLE_SYSTEM').particle_system.settings
    settings.type, settings.count, settings.display_step = 'HAIR', 1000, 3
    objects.update(H=h)

    bpy.ops.mesh.primitive_grid_add(x_subdivisions=119, y_subdivisions=119, location=(0, -8, 0))
    q = bpy.context.object
    q.name = "Q"
    q.data.attributes.new('bevel_weight_edge', 'FLOAT', 'EDGE')
    bevel = q.modifiers.new("Bevel", 'BEVEL')
    bevel.limit_method, bevel.segments, bevel.affect = 'WEIGHT', 14, 'EDGES'
    objects.update(Q=q)

    # A quad, so that the paint and sculpt modes take it.
    b_mesh = bpy.data.meshes.new("B")
    b_mesh.from_pydata([(0, 0, 0), (1, 0, 0), (1, 0.1, 0), (0, 0.1, 0)], [], [(0, 1, 2, 3)])
    b = bpy.data.objects.new("B", b_mesh)
    b.location = (0, 16, 0)
    bpy.context.scene.collection.objects.link(b)
    arr = b.modifiers.new("Array", 'ARRAY')
    arr.fit_type, arr.fit_length = 'FIT_LENGTH', 3.0
    objects.update(B=b)

    x_mesh = bpy.data.meshes.new("X")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=2.0)
    bm.to_mesh(x_mesh)
    bm.free()
    x = bpy.data.objects.new("X", x_mesh)
    x.modifiers.new("Array", 'ARRAY').count = 400_000
    held = bpy.data.collections.new("XC")
    held.objects.link(x)
    objects.update(X=x, XC=held)
    cp = bpy.data.objects.new("CP", None)
    bpy.context.scene.collection.objects.link(cp)
    objects.update(CP=cp)

    # Fix round 3 (October 29): what the interface reaches that this sweep
    # never wrote (docs/blender-local.md, "Found after fix round 2's
    # repairs"). TD: a cube under a Displace along its normals reading a Blend
    # texture at Contrast 0 (its value Brightness − 0.5 everywhere, measured:
    # not clamped), Midlevel 0.5 and Strength √3 × (2 − 0.0001) / 1.5, then an
    # Array fitted to 40 by its size: Brightness 0.25 shrinks it to 0.0001 m
    # (3,199,472).
    bpy.ops.mesh.primitive_cube_add(location=(16, 0, 0))
    td = bpy.context.object
    td.name = "TD"
    texture = bpy.data.textures.new("TDT", 'BLEND')
    texture.contrast = 0.0
    displace = td.modifiers.new("Displace", 'DISPLACE')
    displace.texture, displace.direction, displace.mid_level = texture, 'NORMAL', 0.5
    displace.strength = math.sqrt(3.0) * (2.0 - 1e-4) / 1.5
    td_array = td.modifiers.new("Array", 'ARRAY')
    td_array.fit_type, td_array.fit_length = 'FIT_LENGTH', 40.0
    objects.update(TD=td, TDT=texture)
    # GA: a vertex fitted to 40 by its offset GO, whose X is keyed 1 at frame 1
    # under a Generator of (0.00001, 0) at Influence 0: Influence 1 puts GO at
    # 0.00001 (4,000,001). Not the coefficients themselves: an array whose
    # length follows the Generator's order, which the ladders do not step.
    ga = vertex("GA", (0, 24, 0))
    go = bpy.data.objects.new("GO", None)
    bpy.context.scene.collection.objects.link(go)
    go.location = (1.0, 24.0, 0.0)
    fitted_to(ga, go)
    go.keyframe_insert("location", index=0, frame=1)
    curve = anim_utils.action_get_channelbag_for_slot(go.animation_data.action,
                                                      go.animation_data.action_slot).fcurves[0]
    generator = curve.modifiers.new('GENERATOR')
    generator.use_additive, generator.coefficients = False, (1e-5, 0.0)
    generator.use_influence, generator.influence = True, 0.0
    objects.update(GA=ga, GO=go)
    # NI: Points (10) -> Instance on Points of [Instance on Points (Points 10,
    # Grid 2 × 2)] -> Realize Instances, 400 vertices.
    bpy.ops.mesh.primitive_cube_add(location=(24, 0, 0))
    ni = bpy.context.object
    ni.name = "NI"
    nested = bpy.data.node_groups.new("SweepNested", 'GeometryNodeTree')
    nested.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    out = nested.nodes.new('NodeGroupOutput')
    outer, inner = nested.nodes.new('GeometryNodePoints'), nested.nodes.new('GeometryNodePoints')
    outer.name, inner.name = "Outer", "Inner"
    outer.inputs['Count'].default_value = inner.inputs['Count'].default_value = 10
    small = nested.nodes.new('GeometryNodeMeshGrid')
    small.inputs['Vertices X'].default_value = small.inputs['Vertices Y'].default_value = 2
    first, second = nested.nodes.new('GeometryNodeInstanceOnPoints'), nested.nodes.new('GeometryNodeInstanceOnPoints')
    real = nested.nodes.new('GeometryNodeRealizeInstances')
    nested.links.new(inner.outputs[0], first.inputs['Points'])
    nested.links.new(small.outputs[0], first.inputs['Instance'])
    nested.links.new(outer.outputs[0], second.inputs['Points'])
    nested.links.new(first.outputs[0], second.inputs['Instance'])
    nested.links.new(second.outputs[0], real.inputs[0])
    nested.links.new(real.outputs[0], out.inputs[0])
    ni.modifiers.new("GeometryNodes", 'NODES').node_group = nested
    objects.update(NI=ni)
    # CV: a Bézier curve at Resolution U 1,024 whose Geometry Nodes take it to
    # a mesh with a Curve Circle of Resolution 30 (30,750).
    bpy.ops.curve.primitive_bezier_curve_add(location=(32, 0, 0))
    cv = bpy.context.object
    cv.name = "CV"
    cv.data.resolution_u = 1024
    tube = bpy.data.node_groups.new("SweepTube", 'GeometryNodeTree')
    tube.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    tube.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    given, out = tube.nodes.new('NodeGroupInput'), tube.nodes.new('NodeGroupOutput')
    circle = tube.nodes.new('GeometryNodeCurvePrimitiveCircle')
    circle.name = "Circle"
    circle.inputs[0].default_value = 30
    to_mesh = tube.nodes.new('GeometryNodeCurveToMesh')
    tube.links.new(given.outputs[0], to_mesh.inputs['Curve'])
    tube.links.new(circle.outputs[0], to_mesh.inputs['Profile Curve'])
    tube.links.new(to_mesh.outputs[0], out.inputs[0])
    cv.modifiers.new("GeometryNodes", 'NODES').node_group = tube
    objects.update(CV=cv)

    # Fix round 3's review of the interface's gaps (October 29): what the
    # sweep could not step. TR: TD's cube and Displace again, its Blend
    # texture TRT read through a colour ramp whose two stops are grey 0.5,
    # Strength √3 × (1 − 0.00005) / 0.25: the first stop at grey 0 makes the
    # ramp 0.25 where the texture reads 0.5, and the cube 0.0001 m wide
    # (3,199,472). The gate left every `color` out (`_NEVER`).
    bpy.ops.mesh.primitive_cube_add(location=(40, 0, 0))
    tr = bpy.context.object
    tr.name = "TR"
    ramp_texture = bpy.data.textures.new("TRT", 'BLEND')
    ramp_texture.contrast = 0.0
    ramp_texture.use_color_ramp = True
    for stop in ramp_texture.color_ramp.elements:
        stop.color = (0.5, 0.5, 0.5, 1.0)
    displace = tr.modifiers.new("Displace", 'DISPLACE')
    displace.texture, displace.direction, displace.mid_level = ramp_texture, 'NORMAL', 0.5
    displace.strength = math.sqrt(3.0) * (1.0 - 5e-5) / 0.25
    tr_array = tr.modifiers.new("Array", 'ARRAY')
    tr_array.fit_type, tr_array.fit_length = 'FIT_LENGTH', 40.0
    objects.update(TR=tr, TRT=ramp_texture)
    # EA: a vertex under an Array whose Count a driver works out as
    # x × 40,000 + 2, x the X of EE's `matrix_world`; ES the same as x ×
    # 20,000, x DT's Dimensions X (a cube of 2: 40,000). What Blender derives
    # in its evaluation was read from the original, as it last evaluated it.
    def driven(name, location, target, path, expression):
        obj = vertex(name, location)
        m = obj.modifiers.new("Array", 'ARRAY')
        curve = m.driver_add("count")
        variable = curve.driver.variables.new()
        variable.name, variable.type = "x", 'SINGLE_PROP'
        variable.targets[0].id, variable.targets[0].data_path = target, path
        curve.driver.expression = expression
        return obj

    ee = bpy.data.objects.new("EE", None)
    bpy.context.scene.collection.objects.link(ee)
    ea = driven("EA", (0, 32, 0), ee, 'matrix_world[3][0]', "x*40000+2")
    bpy.ops.mesh.primitive_cube_add(location=(8, 32, 0))
    dt = bpy.context.object
    dt.name = "DT"
    es = driven("ES", (0, 40, 0), dt, 'dimensions[0]', "x*20000")
    objects.update(EE=ee, EA=ea, DT=dt, ES=es)
    # G2: Collection Info of CC -> Realize Instances, CC holding four empties
    # that instance DD, which holds DG, a 120 × 120 grid under an Array of 1:
    # its Count 48 makes DG 702,768 and G2 2,811,072. An empty that instances
    # a collection counted nothing, and DG's change reached no G2.
    dd = bpy.data.collections.new("DD")
    bpy.context.scene.collection.children.link(dd)
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=120, y_subdivisions=120, location=(0, 48, 0))
    dg = bpy.context.object
    dg.name = "DG"
    for holder in list(dg.users_collection):
        holder.objects.unlink(dg)
    dd.objects.link(dg)
    dg.modifiers.new("Array", 'ARRAY').count = 1
    cc = bpy.data.collections.new("CC")
    bpy.context.scene.collection.children.link(cc)
    for i in range(4):
        empty = bpy.data.objects.new("IE%d" % i, None)
        empty.instance_type, empty.instance_collection = 'COLLECTION', dd
        cc.objects.link(empty)
    bpy.ops.mesh.primitive_cube_add(location=(16, 48, 0))
    g2 = bpy.context.object
    g2.name = "G2"
    gather = bpy.data.node_groups.new("SweepGather", 'GeometryNodeTree')
    gather.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    out = gather.nodes.new('NodeGroupOutput')
    info, real = gather.nodes.new('GeometryNodeCollectionInfo'), gather.nodes.new('GeometryNodeRealizeInstances')
    info.inputs['Collection'].default_value = cc
    gather.links.new(info.outputs[0], real.inputs[0])
    gather.links.new(real.outputs[0], out.inputs[0])
    g2.modifiers.new("GeometryNodes", 'NODES').node_group = gather
    objects.update(DG=dg, G2=g2, DD=dd, CC=cc)
    bpy.context.view_layer.update()
    return objects


def sweep2_structs(objects):
    o = objects['O']
    bag = anim_utils.action_get_channelbag_for_slot(objects['FO'].animation_data.action,
                                                    objects['FO'].animation_data.action_slot)
    out = [("O's Armature target", o.constraints[0].targets[0]),
           ("FO's key", bag.fcurves[0].keyframe_points[0]),
           ("the scene", bpy.context.scene),
           ("GPG's Grease Pencil Array", objects['GPG'].modifiers[0]),
           ("H's hair", objects['H'].particle_systems[0].settings)]
    grid = objects['N'].modifiers[0].node_group.nodes["Grid"]
    for socket in grid.inputs:
        out.append(("N's Grid %s" % socket.name, socket))
    # Fix round 3: the scene's Time Stretching, a legacy texture, an F-curve
    # modifier, nested instances realized and a curve object's own curves.
    go_bag = anim_utils.action_get_channelbag_for_slot(objects['GO'].animation_data.action,
                                                       objects['GO'].animation_data.action_slot)
    out += [("the scene's render", bpy.context.scene.render),
            ("TD's texture", objects['TDT']),
            ("GO's Generator", go_bag.fcurves[0].modifiers[0]),
            ("NI's Outer Points", objects['NI'].modifiers[0].node_group.nodes["Outer"].inputs['Count']),
            ("CV's Circle", objects['CV'].modifiers[0].node_group.nodes["Circle"].inputs[0])]
    # Fix round 3's review of the interface's gaps: a colour ramp's stop, the
    # place and size a Single Property driver reads through `matrix_world` and
    # Dimensions, and a grid inside a collection that empties instance.
    out += [("TR's colour ramp stop", objects['TRT'].color_ramp.elements[0]),
            ("EE's place", objects['EE']),
            ("DT's size", objects['DT']),
            ("DG's Array", objects['DG'].modifiers[0])]
    return out


def colour_ladders(prop, now):
    """A colour (four floats) stepped as greys, down to black and up to
    white, alpha kept: `ladders` steps arrays of two and three only."""
    alpha = float(now[3]) if len(now) == 4 else 1.0
    down = [(g, g, g, alpha) for g in (0.4, 0.3, 0.2, 0.1, 0.05, 0.0)]
    up = [(g, g, g, alpha) for g in (0.6, 0.8, 1.0)]
    return [down, up]


# Of these, only what is named: the scene's frame (the rest of the scene is
# the interface's, and its render settings a render's).
SWEEP2_ONLY = {"the scene": {'frame_current'}, "the scene's render": {'frame_map_old', 'frame_map_new'},
               "TR's colour ramp stop": {'color'}, "EE's place": {'location'}, "DT's size": {'scale'},
               "DG's Array": {'count'}}
SWEEP2_SKIP = globals().get('STATE_SKIP', SKIP) | {'co_ui', 'handle_left_type', 'handle_right_type', 'select_control_point',
                            'select_left_handle', 'select_right_handle', 'type', 'easing', 'back', 'period',
                            'amplitude', 'interpolation', 'seed', 'random_offset', 'random_rotation',
                            'random_scale', 'hide_value', 'enabled', 'show_expanded', 'display_shape',
                            'link_limit', 'is_inactive'}


def grown_from(before):
    try:
        after = everyone2()
    except (RuntimeError, ReferenceError):
        return []
    return [(n, c) for n, c in after.items() if c > BUDGET_S and c > before.get(n, 0)]


def first_past_budget(struct, ident, ladder):
    """The first step of `ladder` the budget's own count says is past the
    budget (`_blenderkit_budget.counted`, the direct write's), or None: the
    value the other ways are tried with, so that a bypass they find costs
    one step past the budget, not the ladder's farthest (a hair Count of
    65,536,000 would be 590,000,000 points)."""
    for value in ladder:
        try:
            counts = budget.counted(struct, ident, value)
        except Exception:                                    # noqa: BLE001 - past what can be counted
            return value
        if any(c > BUDGET_S for c in counts.values()):
            return value
    return None


def via_paths(struct, ident, value, gated):
    """`struct.ident = value` written each other way a value reaches Blender;
    the growth each way found: [(way, grown)]."""
    found = []
    try:
        block = struct.id_data
        path = struct.path_from_id(ident)
    except (ValueError, AttributeError, TypeError):
        return found
    now = getattr(struct, ident)
    now = tuple(now) if hasattr(now, '__len__') and not isinstance(now, str) else now
    scalar = not isinstance(value, (tuple, list, set, str)) and not isinstance(value, bool)

    def put_back():
        try:
            setattr(struct, ident, now)
        except (TypeError, ValueError, AttributeError, RuntimeError):
            pass

    # A driver whose expression is the number.
    if scalar and hasattr(block, 'driver_add'):
        before = everyone2()
        try:
            curve = block.driver_add(path)
            curve.driver.expression = repr(float(value))
        except (TypeError, ValueError, RuntimeError, AttributeError):
            curve = None
        if curve is not None:
            if gated:
                mirror_pass()
            grown = grown_from(before)
            if grown:
                found.append(("a driver", grown))
            try:
                block.driver_remove(path)
            except (TypeError, RuntimeError):
                pass
            put_back()
            (mirror_pass() if gated else bpy.context.view_layer.update())

    # A driver reading a custom property, the property written as a script
    # line does (`CP["v"] = …` tags nothing), then a tag.
    holder = bpy.data.objects.get("CP")
    if scalar and hasattr(block, 'driver_add') and holder is not None:
        before = everyone2()
        try:
            holder["v"] = float(now)
            curve = block.driver_add(path)
            var = curve.driver.variables.new()
            var.type, var.name = 'SINGLE_PROP', "v"
            var.targets[0].id = holder
            var.targets[0].data_path = '["v"]'
            curve.driver.expression = "v"
        except (TypeError, ValueError, RuntimeError, AttributeError):
            curve = None
        if curve is not None:
            holder.update_tag()
            (mirror_pass() if gated else bpy.context.view_layer.update())
            before = everyone2()
            holder["v"] = float(value)
            holder.update_tag()
            if gated:
                mirror_pass()
            else:
                bpy.context.view_layer.update()
            grown = grown_from(before)
            if grown:
                found.append(("a custom property a driver reads", grown))
            try:
                block.driver_remove(path)
            except (TypeError, RuntimeError):
                pass
            holder["v"] = float(now)
            put_back()
            (mirror_pass() if gated else bpy.context.view_layer.update())

    # A script's depsgraph_update_post handler.
    def writes(scene=None, depsgraph=None):
        try:
            if getattr(struct, ident) != value:
                setattr(struct, ident, value)
        except (TypeError, ValueError, AttributeError, RuntimeError, ReferenceError):
            pass

    before = everyone2()
    bpy.app.handlers.depsgraph_update_post.append(writes)
    try:
        bpy.context.scene.cursor.location.x += 0.0          # nothing; the next tag is the mirror's
        block.update_tag() if hasattr(block, 'update_tag') else None
        if gated:
            mirror_pass()
        else:
            bpy.context.view_layer.update()
        grown = grown_from(before)
    finally:
        if writes in bpy.app.handlers.depsgraph_update_post:
            bpy.app.handlers.depsgraph_update_post.remove(writes)
    if grown:
        found.append(("a depsgraph_update_post handler", grown))
    put_back()
    (mirror_pass() if gated else bpy.context.view_layer.update())

    # A key at the next frame, then frame_set.
    if scalar and hasattr(struct, 'keyframe_insert'):
        before = everyone2()
        scene = bpy.context.scene
        keyed = False
        try:
            struct.keyframe_insert(ident, frame=1)
            setattr(struct, ident, value)
            struct.keyframe_insert(ident, frame=2)
            put_back()
            keyed = True
        except (TypeError, ValueError, RuntimeError, AttributeError):
            pass
        if keyed:
            try:
                scene.frame_set(2)
            except RuntimeError:
                pass
            if gated:
                mirror_pass()
            grown = grown_from(before)
            if grown:
                found.append(("a key and frame_set", grown))
            with bare():
                scene.frame_set(1)
            try:
                struct.keyframe_delete(ident, frame=1)
                struct.keyframe_delete(ident, frame=2)
            except (TypeError, RuntimeError):
                pass
            put_back()
            (mirror_pass() if gated else bpy.context.view_layer.update())

    # A registered operator's call.
    class BK_OT_sweep_write(bpy.types.Operator):
        bl_idname = "bk_test.sweep_write"
        bl_label = "Sweep Write"

        def execute(self, context):
            setattr(struct, ident, value)
            return {'FINISHED'}

    bpy.utils.register_class(BK_OT_sweep_write)
    before = everyone2()
    try:
        bpy.ops.bk_test.sweep_write()
    except (RuntimeError, TypeError, ValueError):
        pass
    if gated:
        mirror_pass()
    grown = grown_from(before)
    if grown:
        found.append(("a registered operator", grown))
    bpy.utils.unregister_class(BK_OT_sweep_write)
    put_back()
    (mirror_pass() if gated else bpy.context.view_layer.update())
    return found


def sweep2(gated=True, only=None, paths=True):
    """The sweep (see the module's note); returns [(where, setting, value or
    way, grown)] and the number of steps."""
    found, steps = [], 0
    objects = sweep2_fixture()
    for label, struct in sweep2_structs(objects):
        wanted = SWEEP2_ONLY.get(label)
        for prop in struct.bl_rna.properties:
            ident = prop.identifier
            if wanted is not None and ident not in wanted:
                continue
            # What a fixture names (SWEEP2_ONLY) is stepped even where the
            # state sweep skips it everywhere else: a colour ramp stop's
            # `color` (fix round 3), which STATE_SKIP leaves out for objects.
            if prop.is_readonly or ((ident in SWEEP2_SKIP or ident.startswith('show_')) and wanted is None):
                continue
            if only is not None and (label, ident) not in only:
                continue
            if prop.type not in ('BOOLEAN', 'INT', 'FLOAT', 'ENUM'):
                continue
            try:
                now = getattr(struct, ident)
            except AttributeError:
                continue
            now = tuple(now) if hasattr(now, '__len__') and not isinstance(now, str) else now
            colour = (prop.type == 'FLOAT' and getattr(prop, 'is_array', False) and prop.array_length == 4
                      and prop.subtype in ('COLOR', 'COLOR_GAMMA'))
            for ladder in (colour_ladders(prop, now) if colour else ladders(prop, now)):
                for value in ladder:
                    before = everyone2()
                    steps += 1
                    try:
                        setattr(struct, ident, value)
                    except (TypeError, ValueError, AttributeError, RuntimeError):
                        continue
                    if gated:
                        mirror_pass()
                    grown = grown_from(before)
                    if grown:
                        found.append((label, ident, value, grown))
                    try:
                        setattr(struct, ident, now)
                    except (TypeError, ValueError, AttributeError, RuntimeError):
                        pass
                    (mirror_pass() if gated else bpy.context.view_layer.update())
                    if grown:
                        break
                if paths and ladder and prop.type in ('INT', 'FLOAT') and not getattr(prop, 'is_array', False):
                    trigger = first_past_budget(struct, ident, ladder)
                    if trigger is not None:
                        for way, grown in via_paths(struct, ident, trigger, gated):
                            found.append((label, ident, way, grown))
                        steps += 5
    # Pointers: every Object and Collection pointer of the modifiers and
    # constraints swept here, to X and to the collection that holds it.
    for obj in [objects[k] for k in ('A', 'O', 'N', 'Q', 'B', 'H')]:
        for struct in list(obj.modifiers) + list(obj.constraints):
            for prop in struct.bl_rna.properties:
                if prop.type != 'POINTER' or prop.is_readonly:
                    continue
                kind = getattr(prop.fixed_type, 'identifier', '')
                if kind not in ('Object', 'Collection'):
                    continue
                label = "%s's %s" % (obj.name, struct.name)
                if only is not None and (label, prop.identifier) not in only:
                    continue
                now = getattr(struct, prop.identifier)
                before = everyone2()
                steps += 1
                try:
                    setattr(struct, prop.identifier, objects['X'] if kind == 'Object' else objects['XC'])
                except (TypeError, ValueError, AttributeError, RuntimeError):
                    continue
                if gated:
                    mirror_pass()
                grown = grown_from(before)
                if grown:
                    found.append((label, prop.identifier, "X", grown))
                try:
                    setattr(struct, prop.identifier, now)
                except (TypeError, ValueError, AttributeError, RuntimeError):
                    pass
                (mirror_pass() if gated else bpy.context.view_layer.update())
    # A mesh's vertices and attributes in each mode.
    for mode in ('OBJECT', 'WEIGHT_PAINT', 'VERTEX_PAINT', 'TEXTURE_PAINT', 'SCULPT'):
        for label, obj, write in (
                ("B's vertex, x 1 → 4e-6", objects['B'],
                 lambda o: [setattr(o.data.vertices[i].co, 'x', 4e-6) for i in (1, 2)]),
                ("Q's Bevel Weights 0 → 1", objects['Q'],
                 lambda o: o.data.attributes['bevel_weight_edge'].data.foreach_set(
                     'value', [1.0] * len(o.data.edges)))):
            if only is not None and (label, mode) not in only:
                continue
            for other in bpy.context.view_layer.objects:
                other.select_set(other == obj)
            bpy.context.view_layer.objects.active = obj
            if mode != 'OBJECT':
                try:
                    bpy.ops.object.mode_set(mode=mode)
                except RuntimeError:
                    continue
            before = everyone2()
            steps += 1
            saved = [tuple(v.co) for v in obj.data.vertices]
            weights = [d.value for d in obj.data.attributes['bevel_weight_edge'].data] \
                if 'bevel_weight_edge' in obj.data.attributes else None
            write(obj)
            obj.data.update()
            if gated:
                mirror_pass()
            grown = grown_from(before)
            if grown:
                found.append((label, mode, "written", grown))
            for v, co in zip(obj.data.vertices, saved):
                v.co = co
            if weights is not None:
                obj.data.attributes['bevel_weight_edge'].data.foreach_set('value', weights)
            obj.data.update()
            (mirror_pass() if gated else bpy.context.view_layer.update())
            if mode != 'OBJECT':
                bpy.ops.object.mode_set(mode='OBJECT')
    return found, steps


started = time.time()
found, steps = sweep2()
print("        %d steps in %.0f s" % (steps, time.time() - started))
for f in found[:20]:
    print("        bypass: %s %s %r → %s" % (f[0], f[1], f[2], f[3]))
check("12.17 the sweep of what the state sweep never wrote — a constraint's target, node sockets, a key, the frame, "
      "a Grease Pencil modifier, hair, each numeric setting through a driver, a custom property a driver reads, a "
      "handler, a key and frame_set and an operator, every pointer to an object no view layer holds, vertices and attributes in every mode: Blender is "
      "never past the budget unpriced (%d steps)" % steps, not found, found[:5])
CONTROL_ONLY = {("O's Armature target", 'weight'), ("FO's key", 'co'), ("the scene", 'frame_current'),
                ("GPG's Grease Pencil Array", 'count'), ("H's hair", 'count'), ("N's Grid Vertices X", 'default_value'),
                ("A's Array", 'start_cap'), ("B's vertex, x 1 → 4e-6", 'WEIGHT_PAINT'),
                ("B's vertex, x 1 → 4e-6", 'SCULPT'), ("Q's Bevel Weights 0 → 1", 'OBJECT')}
# Fix round 3's, which `interface3.py` also sweeps with each gap put back.
CONTROL_ROUND3 = {("the scene's render", 'frame_map_old'), ("TD's texture", 'intensity'),
                  ("GO's Generator", 'influence'), ("NI's Outer Points", 'default_value'),
                  ("CV's Circle", 'default_value')}
CONTROL_ONLY |= CONTROL_ROUND3
# The review of that work's: `interface4.py` sweeps them with each fix taken out.
CONTROL_ROUND3B = {("TR's colour ramp stop", 'color'), ("EE's place", 'location'), ("DT's size", 'scale'),
                   ("DG's Array", 'count')}
CONTROL_ONLY |= CONTROL_ROUND3B
with gate_off():
    control, _ = sweep2(gated=False, only=CONTROL_ONLY)
kinds = sorted({(f[0], f[1] if not isinstance(f[2], str) or f[2] in ('X', 'written') else f[2]) for f in control})
ways = sorted({f[2] for f in control if isinstance(f[2], str) and f[2] not in ('X', 'written')})
settings = {(f[0], f[1]) for f in control if not (isinstance(f[2], str) and f[2] not in ('X', 'written'))}
check("control: with the gate off, the same sweep finds %d of those %d settings and %d of the 5 other ways growing "
      "Blender past the budget" % (len(settings), len(CONTROL_ONLY), len(ways)),
      settings == CONTROL_ONLY and len(ways) >= 5, (kinds, ways, sorted(CONTROL_ONLY - settings)))
clear()
