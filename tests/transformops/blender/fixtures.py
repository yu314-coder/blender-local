"""The scenes the transformops check drags in: built the same way when they
are written out for the Swift (stage 1) and when the Swift's calls are run on
them (stage 3), so the preview and Blender work on one and the same scene."""
import bpy, bmesh
from mathutils import Quaternion

FIXTURES = ['obj_euler', 'obj_child', 'obj_quat', 'obj_pair', 'edit_cube', 'edit_grid',
            'edit_monkey', 'edit_sphere', 'edit_active',
            # Round 4's review of group 5: a locked Euler (Gimbal's X and Z
            # antiparallel, so its matrix has no inverse), a sheared object's
            # Local, and Active Element's Normal where the active face's
            # normal is not the selection's.
            'obj_gimbal', 'edit_gimbal', 'edit_sheared', 'edit_active_pair']


def _clear():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for collection in (bpy.data.meshes, bpy.data.curves, bpy.data.lattices):
        for d in list(collection):
            if d.users == 0:
                collection.remove(d)
    scene = bpy.context.scene
    scene.cursor.location = (0.4, -0.3, 0.2)
    scene.cursor.rotation_mode = 'XYZ'
    scene.cursor.rotation_euler = (0.2, 0.9, -0.4)
    scene.transform_orientation_slots[0].type = 'GLOBAL'
    scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
    scene.tool_settings.use_proportional_edit = False
    scene.tool_settings.use_proportional_edit_objects = False
    scene.tool_settings.use_mesh_automerge = False
    scene.tool_settings.use_snap = False


def _add(op, name, location, rotation, scale, **kw):
    op(**kw)
    obj = bpy.context.active_object
    obj.name = name
    obj.location = location
    obj.rotation_euler = rotation
    obj.scale = scale
    return obj


def _select(objects, active):
    for o in bpy.context.view_layer.objects:
        o.select_set(o in objects)
    bpy.context.view_layer.objects.active = active
    bpy.context.view_layer.update()


def _edit(obj, select, mode, history=()):
    _select([obj], obj)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table(); bm.edges.ensure_lookup_table(); bm.faces.ensure_lookup_table()
    for e in list(bm.verts) + list(bm.edges) + list(bm.faces):
        e.select = False
    bm.select_history.clear()
    seq = {'VERT': bm.verts, 'EDGE': bm.edges, 'FACE': bm.faces}[mode]
    for i in select:
        seq[i].select_set(True)
    bm.select_flush_mode()
    for i in history:
        bm.select_history.add(seq[i])
    if mode == 'FACE' and history:
        bm.faces.active = seq[history[-1]]
    bmesh.update_edit_mesh(obj.data)


def build(name):
    """The fixture, in its mode, with its selection. Returns the object the
    gizmo acts on (the active one)."""
    _clear()
    ops = bpy.ops.mesh
    if name == 'obj_euler':
        o = _add(ops.primitive_cube_add, 'Cube', (2, 0, 1), (0.4, 0.5, -0.6), (1, 1.5, 0.75))
        _select([o], o)
        return o
    if name in ('obj_child', 'obj_quat'):
        bpy.ops.object.empty_add()
        holder = bpy.context.active_object
        holder.name = 'Holder'
        holder.location = (1, 2, 0)
        holder.rotation_euler = (0.3, -0.2, 0.9)
        # Uniform: a selected child of a non-uniformly scaled, turned parent is
        # sheared, which no location, rotation and scale the preview poses can
        # draw (orient.py holds that case's matrices).
        holder.scale = (1.2, 1.2, 1.2) if name == 'obj_quat' else (1.5, 1.5, 1.5)
        o = _add(ops.primitive_cube_add, 'Cube', (0.5, 0.5, 1), (0.4, 0.5, -0.6), (1, 1, 1))
        o.parent = holder
        if name == 'obj_quat':
            o.rotation_mode = 'QUATERNION'
            o.rotation_quaternion = Quaternion((0.3, 0.2, 0.5), 0.9)
        _select([o], o)
        return o
    if name == 'obj_pair':
        a = _add(ops.primitive_cube_add, 'A', (2, 0, 0), (0, 0, 0.785398), (1, 1, 1))
        b = _add(ops.primitive_cube_add, 'B', (-2, 1, 0), (0.2, 0, 0.523599), (1, 1, 1))
        _select([a, b], a)
        return a
    if name == 'edit_cube':
        o = _add(ops.primitive_cube_add, 'Cube', (0.5, -1, 0.3), (0.5236, 0.2, 0.1), (1, 2, 0.5))
        _edit(o, [0], 'FACE')
        return o
    if name == 'edit_active':
        o = _add(ops.primitive_cube_add, 'Cube', (0.5, -1, 0.3), (0.5236, 0.2, 0.1), (1, 2, 0.5))
        bpy.context.scene.tool_settings.transform_pivot_point = 'ACTIVE_ELEMENT'
        _edit(o, [0, 2, 4], 'FACE', history=[0, 4])
        return o
    if name == 'edit_grid':
        o = _add(ops.primitive_grid_add, 'Grid', (0, 0, 0), (0.3, 0.0, 0.7), (1.5, 1, 1),
                 x_subdivisions=4, y_subdivisions=4)
        bm = bmesh.new()
        bm.from_mesh(o.data)
        boundary = [e.index for e in bm.edges if e.is_boundary][2]
        bm.free()
        _edit(o, [boundary], 'EDGE')
        return o
    if name == 'edit_monkey':
        o = _add(ops.primitive_monkey_add, 'Suzanne', (0, 0, 0.5), (0.3, 0.2, -0.5), (1.2, 0.8, 1))
        _edit(o, [10, 11, 40, 41, 120, 121, 300], 'FACE')
        return o
    if name == 'edit_sphere':
        o = _add(ops.primitive_uv_sphere_add, 'Sphere', (0, 0, 0), (0.2, 0.4, 0.1), (1, 1, 1),
                 segments=16, ring_count=8)
        _edit(o, [40], 'VERT')
        return o
    if name in ('obj_gimbal', 'edit_gimbal'):
        # Euler XYZ with Y at 90°: the textbook gimbal lock.
        o = _add(ops.primitive_cube_add, 'Cube', (1, 0.5, 0.25), (0.3, 1.5707963267948966, 0.2), (1, 1.25, 0.8))
        if name == 'obj_gimbal':
            _select([o], o)
        else:
            _edit(o, [2], 'FACE')
        return o
    if name == 'edit_sheared':
        # A child of a non-uniformly scaled, turned parent: its Local axes are
        # not at right angles, and Blender inverts them for a scale.
        bpy.ops.object.empty_add()
        holder = bpy.context.active_object
        holder.name = 'Holder'
        holder.location = (0.5, 0, 0)
        holder.rotation_euler = (0, 0, 0.6)
        holder.scale = (2, 1, 1)
        o = _add(ops.primitive_cube_add, 'Cube', (0.25, 0.5, 0.5), (0.3, 0.2, 0.5), (1, 1, 1))
        o.parent = holder
        _edit(o, [1], 'FACE')
        return o
    if name == 'edit_active_pair':
        # Two faces whose normals do not cancel, the second active: Active
        # Element's Normal is that face's alone, the selection's is between.
        o = _add(ops.primitive_cube_add, 'Cube', (0.5, -1, 0.3), (0.5236, 0.2, 0.1), (1, 2, 0.5))
        bpy.context.scene.tool_settings.transform_pivot_point = 'ACTIVE_ELEMENT'
        _edit(o, [1, 5], 'FACE', history=[1, 5])
        return o
    raise KeyError(name)
