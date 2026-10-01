"""The meshes the edit-mode checks drag, built the same way twice: once to
hand the Swift side (meshes.py), and again in verify.py to run what the Swift
sends. Both runs start from `--factory-startup`, so the same operators give
the same vertex order.

Each is transformed — moved, turned and scaled unevenly — because a preview
that worked in the mesh's own space rather than the world's is right only for
an object at rest with a uniform scale.
"""
import bpy

FIXTURES = ('grid', 'sphere', 'cube')


def build(name):
    """A fresh scene holding one mesh object called `name`, in object mode."""
    bpy.ops.wm.read_homefile(use_empty=True)
    return add(name)


def add(name):
    """The mesh object called `name`, added to the scene as it stands — for
    the snapping checks, which drag other objects onto it."""
    if name == 'grid':
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10, size=2)
    elif name == 'sphere':
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=1)
    elif name == 'cube':
        # Quads meeting at right angles: the case where the distance along
        # the surface and the distance through the air part company.
        bpy.ops.mesh.primitive_cube_add(size=2)
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.subdivide(number_cuts=3)
        bpy.ops.object.mode_set(mode='OBJECT')
    else:
        raise ValueError(name)
    obj = bpy.context.object
    obj.name = name
    obj.location = (0.5, -0.25, 0.3)
    obj.rotation_euler = (0.2, 0.0, 0.6)
    obj.scale = (1.5, 0.8, 1.0)
    bpy.context.view_layer.update()
    return obj


def select_vertices(obj, indices):
    """Edit mode on `obj` with exactly these vertices selected, in vertex
    select mode — what the app's selection push leaves Blender holding."""
    import bmesh
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = (True, False, False)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    for f in bm.faces:
        f.select = False
    for e in bm.edges:
        e.select = False
    for v in bm.verts:
        v.select = False
    for i in indices:
        bm.verts[i].select = True
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)


def relations():
    """A scene of 28 objects tied together each way Blender ties one object's
    transform or geometry to another's, for the snap targets a move leaves out:

      * P ← C ← G by parenting, VP to a vertex of X;
      * B's Boolean, L's Cast, V's UV Project read X; F copies X's location;
      * K has a Shrinkwrap constraint on P, W a Displace reading P's space;
      * A's Array offsets by O, H hooks to O, D's Z is driven by O's X;
      * S shrinkwraps onto G; M2 mirrors across U; N's Geometry Nodes take G
        as an input and U in an Object Info node;
      * Cur bevels with Bev, CM's Curve modifier and Tx's text follow Cur;
      * E instances the collection holding I1; AC's Armature constraint
        targets Arm;
      * T's material reads U's space, which moves nothing of T's.
    """
    bpy.ops.wm.read_homefile(use_empty=True)

    def cube(name, place):
        bpy.ops.mesh.primitive_cube_add(size=1, location=place)
        obj = bpy.context.object
        obj.name = name
        return obj

    P = cube("P", (0, 0, 0)); C = cube("C", (3, 0, 0)); G = cube("G", (5, 0, 0))
    C.parent = P
    G.parent = C
    X = cube("X", (0, 5, 0)); B = cube("B", (0, 6, 0))
    B.modifiers.new("Bool", 'BOOLEAN').object = X
    F = cube("F", (0, -5, 0)); F.constraints.new('COPY_LOCATION').target = X
    K = cube("K", (0, -7, 0)); K.constraints.new('SHRINKWRAP').target = P
    O = cube("O", (8, 0, 0)); A = cube("A", (8, 3, 0))
    array = A.modifiers.new("Arr", 'ARRAY')
    array.use_object_offset = True
    array.offset_object = O
    D = cube("D", (-5, 0, 0))
    curve = D.driver_add("location", 2)
    variable = curve.driver.variables.new()
    variable.type = 'TRANSFORMS'
    variable.targets[0].id = O
    variable.targets[0].transform_type = 'LOC_X'
    curve.driver.expression = variable.name
    U = cube("U", (-8, 0, 0)); T = cube("T", (-8, 4, 0))
    material = bpy.data.materials.new("m")
    material.use_nodes = True
    material.node_tree.nodes.new('ShaderNodeTexCoord').object = U
    T.data.materials.append(material)
    M2 = cube("M2", (12, 0, 0)); M2.modifiers.new("Mir", 'MIRROR').mirror_object = U
    W = cube("W", (12, 4, 0))
    displace = W.modifiers.new("Disp", 'DISPLACE')
    displace.texture_coords = 'OBJECT'
    displace.texture_coords_object = P
    displace.texture = bpy.data.textures.new("t", 'CLOUDS')
    H = cube("H", (12, 8, 0)); H.modifiers.new("Hook", 'HOOK').object = O
    L = cube("L", (15, 0, 0)); L.modifiers.new("Cast", 'CAST').object = X
    S = cube("S", (15, 4, 0)); S.modifiers.new("Sw", 'SHRINKWRAP').target = G
    V = cube("V", (15, 8, 0)); V.modifiers.new("UVP", 'UV_PROJECT').projectors[0].object = X
    N = cube("N", (18, 0, 0))
    nodes = N.modifiers.new("GN", 'NODES')
    group = bpy.data.node_groups.new("g", 'GeometryNodeTree')
    group.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    group.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    group.interface.new_socket("Obj", in_out='INPUT', socket_type='NodeSocketObject')
    group_in = group.nodes.new('NodeGroupInput')
    group_out = group.nodes.new('NodeGroupOutput')
    info = group.nodes.new('GeometryNodeObjectInfo')
    info.inputs['Object'].default_value = U
    info.transform_space = 'RELATIVE'
    join = group.nodes.new('GeometryNodeJoinGeometry')
    group.links.new(group_in.outputs[0], join.inputs[0])
    group.links.new(info.outputs['Geometry'], join.inputs[0])
    group.links.new(join.outputs[0], group_out.inputs[0])
    nodes.node_group = group
    identifier = next(i.identifier for i in group.interface.items_tree if i.name == 'Obj')
    getattr(nodes.properties.inputs, identifier).value = G
    bpy.ops.curve.primitive_bezier_circle_add(location=(20, 0, 0))
    bevel = bpy.context.object
    bevel.name = "Bev"
    bpy.ops.curve.primitive_bezier_curve_add(location=(22, 0, 0))
    bent = bpy.context.object
    bent.name = "Cur"
    bent.data.bevel_mode = 'OBJECT'
    bent.data.bevel_object = bevel
    held = bpy.data.collections.new("Inst")
    bpy.context.scene.collection.children.link(held)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(25, 0, 0))
    inside = bpy.context.object
    inside.name = "I1"
    for owner in inside.users_collection:
        owner.objects.unlink(inside)
    held.objects.link(inside)
    instancer = bpy.data.objects.new("E", None)
    bpy.context.scene.collection.objects.link(instancer)
    instancer.instance_type = 'COLLECTION'
    instancer.instance_collection = held
    instancer.location = (25, 5, 0)
    CM = cube("CM", (28, 0, 0)); CM.modifiers.new("Crv", 'CURVE').object = bent
    bpy.ops.object.text_add(location=(30, 0, 0))
    text = bpy.context.object
    text.name = "Tx"
    text.data.follow_curve = bent
    VP = cube("VP", (32, 0, 0))
    VP.parent = X
    VP.parent_type = 'VERTEX'
    VP.parent_vertices[0] = 0
    bpy.ops.object.armature_add(location=(34, 0, 0))
    bpy.context.object.name = "Arm"
    AC = cube("AC", (34, 3, 0))
    AC.constraints.new('ARMATURE').targets.new().target = bpy.data.objects["Arm"]
    bpy.context.view_layer.update()
    return list(bpy.data.objects)


def moved_with(obj):
    """What Blender's depsgraph updates when `obj` moves: the names
    `depsgraph_update_post` reports with a transform or geometry update."""
    seen = set()

    def note(scene, depsgraph):
        seen.update(u.id.original.name for u in depsgraph.updates
                    if isinstance(u.id, bpy.types.Object)
                    and (u.is_updated_transform or u.is_updated_geometry))

    bpy.app.handlers.depsgraph_update_post.append(note)
    try:
        obj.location.x += 0.5
        bpy.context.view_layer.update()
    finally:
        bpy.app.handlers.depsgraph_update_post.remove(note)
        obj.location.x -= 0.5
        bpy.context.view_layer.update()
    return seen
