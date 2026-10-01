"""Image to 3D Model: Blender's half.

Two modes, each a folder the app writes and a picture beside it.

Relief (`build`): the app shapes the subject's outline with the picture's depth
(ImageToModel.swift) and writes positions, face sizes, corner indices and UVs
as little-endian arrays, with meta.json. `build` makes the object:
- the mesh, with a UV map and smooth shading;
- a material whose Base Color is an Image Texture of the picture, the node
  made active, which is the layout Texture Paint and the viewport's
  `_blenderkit_texpaint.report` read the texture through;
- the picture packed into the .blend, so undo, autosave and saving keep it
  after the app deletes the folder.

Full 3D (`prepare_full`, then `finish_full`): the app runs TripoSG and writes
the extracted surface. `prepare_full` decimates it and unwraps it with Smart UV
Project, keeping the mesh aside, and writes each triangle's corners and UVs
back; the app bakes a texture for that layout; `finish_full` turns the mesh so
the model's front faces Blender's front view, sizes it, and makes the object
as `build` does.

Either way the object is made active and the only one selected, at the 3D
cursor, in object mode.
"""
import json
import math
import os
import sys
from array import array

import bpy


def _is_real_blender():
    """Blender's operators carry their RNA; the shim's are plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _read(folder, name, typecode, count):
    values = array(typecode)
    path = os.path.join(folder, name)
    with open(path, 'rb') as f:
        values.fromfile(f, count)
    if sys.byteorder != 'little':
        values.byteswap()
    return values



# The mesh prepare_full keeps for finish_full, by this name, with a fake user.
PENDING = "_bk_image3d_pending"


def _leave_edit_modes():
    active = bpy.context.view_layer.objects.active
    if active is not None and active.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')


def prepare_full(folder, faces=50000):
    """Decimate and unwrap the surface in `folder`; writes the unwrapped
    triangles back and returns a JSON line with the counts and timings."""
    import time
    if not _is_real_blender():
        raise RuntimeError("Image to 3D Model needs Blender's own module; the simulator "
                           "runs a stand-in with no meshes or images to build it with")
    started = time.time()
    with open(os.path.join(folder, 'meta.json')) as f:
        meta = json.load(f)
    vertices, triangles = meta['vertices'], meta['triangles']
    if vertices == 0 or triangles == 0:
        raise RuntimeError('TripoSG found no shape in the picture')
    positions = _read(folder, 'positions.bin', 'f', vertices * 3)
    corners = _read(folder, 'triangles.bin', 'i', triangles * 3)

    _leave_edit_modes()
    stale = bpy.data.meshes.get(PENDING)
    if stale is not None:
        bpy.data.meshes.remove(stale)
    mesh = bpy.data.meshes.new(PENDING)
    mesh.vertices.add(vertices)
    mesh.vertices.foreach_set('co', positions)
    mesh.loops.add(triangles * 3)
    mesh.loops.foreach_set('vertex_index', corners)
    mesh.polygons.add(triangles)
    mesh.polygons.foreach_set('loop_start', array('i', range(0, triangles * 3, 3)))
    mesh.update(calc_edges=True)
    mesh.validate(verbose=False)

    # Decimating and unwrapping are operators on an object in the view layer.
    layer = bpy.context.view_layer
    previous_active = layer.objects.active
    previous_selection = [o for o in layer.objects if o.select_get()]
    obj = bpy.data.objects.new(PENDING, mesh)
    bpy.context.scene.collection.objects.link(obj)
    try:
        for o in previous_selection:
            o.select_set(False)
        obj.select_set(True)
        layer.objects.active = obj
        if triangles > faces:
            modifier = obj.modifiers.new('Decimate', 'DECIMATE')
            modifier.ratio = faces / triangles
            bpy.ops.object.modifier_apply(modifier=modifier.name)
        decimated = time.time()
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.003, area_weight=0.0)
        bpy.ops.object.mode_set(mode='OBJECT')
        unwrapped = time.time()
    finally:
        bpy.data.objects.remove(obj)
        for o in previous_selection:
            if o.name in layer.objects:
                o.select_set(True)
        layer.objects.active = previous_active
    mesh.use_fake_user = True

    mesh.calc_loop_triangles()
    count = len(mesh.loop_triangles)
    loops = array('i', [0]) * (count * 3)
    mesh.loop_triangles.foreach_get('loops', loops)
    loop_vertex = array('i', [0]) * len(mesh.loops)
    mesh.loops.foreach_get('vertex_index', loop_vertex)
    co = array('f', [0.0]) * (len(mesh.vertices) * 3)
    mesh.vertices.foreach_get('co', co)
    uv = array('f', [0.0]) * (len(mesh.loops) * 2)
    mesh.uv_layers.active.data.foreach_get('uv', uv)
    out_positions = array('f', [0.0]) * (count * 9)
    out_uvs = array('f', [0.0]) * (count * 6)
    for k in range(count * 3):
        loop = loops[k]
        v = loop_vertex[loop]
        out_positions[k * 3] = co[v * 3]
        out_positions[k * 3 + 1] = co[v * 3 + 1]
        out_positions[k * 3 + 2] = co[v * 3 + 2]
        out_uvs[k * 2] = uv[loop * 2]
        out_uvs[k * 2 + 1] = uv[loop * 2 + 1]
    for name, values in (('unwrapped_positions.bin', out_positions), ('unwrapped_uvs.bin', out_uvs)):
        if sys.byteorder != 'little':
            values.byteswap()
        with open(os.path.join(folder, name), 'wb') as f:
            values.tofile(f)
    return json.dumps({'triangles': count, 'vertices': len(mesh.vertices),
                       'decimate_s': round(decimated - started, 3), 'unwrap_s': round(unwrapped - decimated, 3)})


def finish_full(folder, texture, name, location=(0.0, 0.0, 0.0), size=2.0):
    """The object from prepare_full's mesh and the baked texture."""
    from mathutils import Matrix, Vector
    mesh = bpy.data.meshes.get(PENDING)
    if mesh is None:
        raise RuntimeError('there is no prepared model to finish')
    _leave_edit_modes()
    mesh.use_fake_user = False
    mesh.name = name
    # TripoSG's frame has Y up and the model's front at +Z; Blender's front
    # view looks along +Y, so Y turns to Z and the front to -Y. Then the
    # model is centred on its bounds and its longest side made `size`.
    turn = Matrix.Rotation(math.pi / 2, 4, 'X')
    mesh.transform(turn)
    co = [v.co for v in mesh.vertices]
    lo = Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co)))
    hi = Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co)))
    extent = max(hi - lo)
    scale = size / extent if extent > 0 else 1.0
    mesh.transform(Matrix.Diagonal((scale, scale, scale, 1.0)) @ Matrix.Translation(-(lo + hi) / 2))
    mesh.shade_smooth()
    return _finish_object(mesh, texture, name, location)


def _finish_object(mesh, texture, name, location):
    image = bpy.data.images.load(texture, check_existing=False)
    image.name = name
    image.pack()

    material = bpy.data.materials.new(name)
    if material.node_tree is None:
        material.use_nodes = True
    tree = material.node_tree
    bsdf = next((n for n in tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if bsdf is None:
        bsdf = tree.nodes.new('ShaderNodeBsdfPrincipled')
        output = next((n for n in tree.nodes if n.type == 'OUTPUT_MATERIAL'), None)
        if output is not None:
            tree.links.new(bsdf.outputs['BSDF'], output.inputs['Surface'])
    node = tree.nodes.new('ShaderNodeTexImage')
    node.image = image
    node.location = (bsdf.location.x - 320, bsdf.location.y)
    tree.links.new(node.outputs['Color'], bsdf.inputs['Base Color'])
    tree.nodes.active = node
    # A photo is not a mirror: Blender's default roughness of 0.5 makes the
    # print look glossy.
    bsdf.inputs['Roughness'].default_value = 0.8
    mesh.materials.clear()
    mesh.materials.append(material)

    obj = bpy.data.objects.new(name, mesh)
    collection = bpy.context.collection or bpy.context.scene.collection
    collection.objects.link(obj)
    obj.location = tuple(location)
    layer = bpy.context.view_layer
    for other in layer.objects:
        if other.select_get():
            other.select_set(False)
    obj.select_set(True)
    layer.objects.active = obj

    return json.dumps({'object': obj.name, 'vertices': len(mesh.vertices),
                       'faces': len(mesh.polygons)})


def build(folder, texture, name, location=(0.0, 0.0, 0.0)):
    """Makes the object and returns a JSON line: its name, vertex and face counts."""
    if not _is_real_blender():
        raise RuntimeError("Image to 3D Model needs Blender's own module; the simulator "
                           "runs a stand-in with no meshes or images to build it with")
    with open(os.path.join(folder, 'meta.json')) as f:
        meta = json.load(f)
    vertices, faces, loops = meta['vertices'], meta['faces'], meta['loops']
    if vertices == 0 or faces == 0:
        raise RuntimeError('the picture gave no shape to build')

    positions = _read(folder, 'positions.bin', 'f', vertices * 3)
    sizes = _read(folder, 'sizes.bin', 'i', faces)
    indices = _read(folder, 'indices.bin', 'i', loops)
    uvs = _read(folder, 'uvs.bin', 'f', loops * 2)
    if sum(sizes) != loops or max(indices) >= vertices or min(indices) < 0:
        raise RuntimeError('the model files do not agree with each other')

    # Out of edit or paint modes first: a new object belongs in object mode,
    # and making it active while Blender edits another mesh would leave that
    # edit hanging.
    active = bpy.context.view_layer.objects.active
    if active is not None and active.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')

    mesh = bpy.data.meshes.new(name)
    mesh.vertices.add(vertices)
    mesh.vertices.foreach_set('co', positions)
    mesh.loops.add(loops)
    mesh.loops.foreach_set('vertex_index', indices)
    starts = array('i', [0]) * faces
    running = 0
    for k, size in enumerate(sizes):
        starts[k] = running
        running += size
    mesh.polygons.add(faces)
    mesh.polygons.foreach_set('loop_start', starts)
    mesh.update(calc_edges=True)
    mesh.validate(verbose=False)
    mesh.uv_layers.new(name='UVMap').data.foreach_set('uv', uvs)
    mesh.shade_smooth()

    return _finish_object(mesh, texture, name, location)
