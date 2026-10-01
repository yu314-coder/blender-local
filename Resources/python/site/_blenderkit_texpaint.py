"""Texture Paint's side of bpy.

Blender's texture painter projects the brush through a 3D View region, and the
bpy module on an iPad has no region, so the brush runs in the app
(TexturePaintStroke.swift). This module does what only Blender can:

- `enter`   gives an object a UV map and an image to paint, the way Blender's
            texture paint offers to when either is missing;
- `report`  hands the viewport, after each mirroring pass, the UVs and images
            every textured object is painted through — and the pixels of any
            image that changed since it last did;
- `write`   puts a finished stroke into Blender's image and packs it, so the
            .blend, and every undo checkpoint and autosave made from it, keeps
            the paint.

In the simulator `bpy` is the app's shim, which has no images or node trees;
`enter` asks the app to do the same there instead.
"""
import sys
from array import array

import bpy

try:
    import _blenderkit_paint as _native
except ImportError:
    # Only desktop Blender running tests/texpaint/blender lacks it, and the
    # check puts its own stand-in in sys.modules first.
    _native = None


def _is_real_blender():
    """Blender's operators carry their RNA; the shim's are plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


# --------------------------------------------------------------------------
# The image Blender would paint

def _image_nodes(tree):
    """Image Texture nodes holding an image, in the order Blender numbers
    paint slots: node order, going into node groups
    (`ntree_foreach_texnode_recursive`)."""
    found = []
    for node in tree.nodes:
        if node.type == 'TEX_IMAGE' and node.image is not None:
            found.append(node)
        elif node.type == 'GROUP' and node.node_tree is not None:
            found.extend(_image_nodes(node.node_tree))
    return found


def canvas_node(material):
    """The Image Texture node Blender paints for `material`, or None.

    Blender paints the node flagged as the active paint canvas. Python cannot
    see that flag, but the node editor sets it together with the active node
    whenever an image node is made active, so the active node is it when it is
    an image node. When something else was made active since, Blender's own
    `paint_active_slot` still names the slot, and that is what it paints.
    `texture_paint_images` cannot be used instead: it is a runtime cache that
    is empty again after every file load, so after every undo.
    """
    tree = getattr(material, 'node_tree', None)
    if tree is None:
        return None
    nodes = _image_nodes(tree)
    if not nodes:
        return None
    active = tree.nodes.active
    for node in nodes:
        if node == active:
            return node
    return nodes[min(max(material.paint_active_slot, 0), len(nodes) - 1)]


def _uv_map_node(node):
    """Blender's `nodetree_uv_node_recursive`: from an image node up its first
    linked input, and on up from whatever feeds that, until a UV Map node. A
    node with no linked input ends the search, and the image reads the active
    UV map."""
    for socket in node.inputs:
        if socket.is_linked:
            source = socket.links[0].from_node
            if source.type == 'UVMAP':
                return source
            return _uv_map_node(source)
    return None


def slots(obj):
    """Per material slot: (image, UV map name or None, whether the image feeds
    the Principled BSDF's Base Color). A mesh with no materials has one slot.

    In Single Image mode Blender paints `image_paint.canvas` on every face.
    """
    settings = bpy.context.scene.tool_settings.image_paint
    count = max(1, len(obj.material_slots))
    if settings.mode == 'IMAGE':
        return [(settings.canvas, None, False)] * count
    out = []
    for index in range(count):
        material = obj.material_slots[index].material if index < len(obj.material_slots) else None
        node = canvas_node(material) if material is not None else None
        if node is None:
            out.append((None, None, False))
            continue
        uv_node = _uv_map_node(node)
        uv_map = uv_node.uv_map if uv_node is not None and uv_node.uv_map else None
        colour = node.outputs.get('Color')
        linked = colour is not None and any(
            link.to_node.type == 'BSDF_PRINCIPLED' and link.to_socket.name == 'Base Color'
            for link in colour.links)
        out.append((node.image, uv_map, linked))
    return out


# --------------------------------------------------------------------------
# Entering Texture Paint

def enter(name, width=1024, height=1024):
    """Make `name` paintable, and return the names of the operators that ran.

    Blender's texture paint mode checks for these on entry
    (`ED_paint_proj_mesh_data_check`) and offers a button for each missing one.
    Here the button is pressed: an object with no UV map gets Add Simple UVs,
    and one whose materials have no image gets Add Paint Slot, with the
    settings that operator's own dialog opens with.
    """
    if not _is_real_blender():
        made = _native.shim_enter(name, int(width), int(height)) if _native else ''
        return [line for line in made.split('\n') if line]

    obj = bpy.data.objects[name]
    if obj.type != 'MESH':
        raise RuntimeError("Texture Paint: " + name + " is not a mesh")
    layer = bpy.context.view_layer
    if layer.objects.active != obj:
        layer.objects.active = obj
    if obj.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')

    made = []
    if not obj.data.uv_layers:
        _add_uvs(obj)
        made.append('Add Simple UVs')
    if not any(image is not None for image, _, _ in slots(obj)):
        _add_slot(obj, width, height)
        made.append('Add Paint Slot')
    return made


def _add_uvs(obj):
    """Blender's Add Simple UVs: a cube projection, packed.

    It only runs in Texture Paint mode (`add_simple_uvs_poll`), so Blender goes
    there for the one operator and comes straight back — the app's painting
    keeps Blender in object mode. Smart UV Project, which works from edit
    mode, is the fallback should that visit ever fail.
    """
    try:
        bpy.ops.object.mode_set(mode='TEXTURE_PAINT')
        try:
            result = bpy.ops.paint.add_simple_uvs()
        finally:
            bpy.ops.object.mode_set(mode='OBJECT')
        if 'FINISHED' in result and obj.data.uv_layers:
            return
    except RuntimeError:
        if obj.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.mode_set(mode='EDIT')
    try:
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.uv.smart_project()
    finally:
        bpy.ops.object.mode_set(mode='OBJECT')


def _add_slot(obj, width, height):
    """Blender's Add Paint Slot, with what its dialog would have filled in
    (`texture_paint_add_texture_paint_slot_invoke`): named "<material> Base
    Color" — the object's name when there is no material — and filled with
    the Principled BSDF's Base Color. Blender makes the material, the Image
    Texture node, its link to Base Color and the image itself.
    """
    material = obj.active_material
    colour = (0.8, 0.8, 0.8, 1.0)
    tree = getattr(material, 'node_tree', None)
    if tree is not None:
        bsdf = next((node for node in tree.nodes if node.type == 'BSDF_PRINCIPLED'), None)
        if bsdf is not None:
            value = bsdf.inputs['Base Color'].default_value
            colour = (value[0], value[1], value[2], 1.0)
    base = material.name if material is not None else obj.name
    result = bpy.ops.paint.add_texture_paint_slot(
        type='BASE_COLOR', slot_type='IMAGE', name=base + " Base Color", color=colour,
        width=int(width), height=int(height), alpha=True, generated_type='BLANK', float=False)
    if 'FINISHED' not in result:
        raise RuntimeError("Texture Paint: Blender could not add a paint slot to " + obj.name)


# --------------------------------------------------------------------------
# The viewport's copy

# For each image the viewport has, what it looked like when its pixels were
# read. `session_uid` changes when a file loads, which is every undo and redo.
_signatures = {}


def _signature(image):
    packed = image.packed_file
    return (image.session_uid, tuple(image.size), image.channels, image.is_float,
            image.source, image.filepath_raw, packed.size if packed is not None else -1,
            tuple(image.generated_color), image.generated_type,
            image.generated_width, image.generated_height)


def _push_pixels(image):
    """Hand the viewport an image's pixels, when they are not the ones it has.

    Reading a 1024² image is sixteen megabytes of floats, so it happens only
    when something changed: a load, a new image, or pixels someone wrote and
    has not packed — `is_dirty`. A stroke packs as it is kept, so painting
    itself never causes a read back.
    """
    signature = _signature(image)
    if not image.is_dirty and _signatures.get(image.name) == signature:
        return False
    width, height = image.size
    if width == 0 or height == 0:
        return False
    pixels = array('f', [0.0]) * (width * height * image.channels)
    image.pixels.foreach_get(pixels)
    _native.image_push(image.name, width, height, image.channels, image.is_float, pixels)
    _signatures[image.name] = signature
    return True


def _layer_uvs(mesh, layer):
    values = array('f', [0.0]) * (2 * len(mesh.loops))
    layer.uv.foreach_get('vector', values)
    return values


def _corner_uvs(mesh, per_slot, loops, materials):
    """The loops behind the triangle corners, and the UVs to read them from.

    Blender paints each face through its slot's UV map — the one a UV Map node
    upstream of the slot's image names — and through the active UV map where
    there is none (`project_paint_prepare_all_faces`). When every slot reads
    the same map its UVs go over as they are, a pair per loop. When slots read
    different maps, each corner's UV is picked out here and sent a pair per
    corner, which is slower but the uncommon case.
    """
    active = mesh.uv_layers.active
    if active is None:
        return loops, array('f')
    layers = []
    for _, uv_map, _ in per_slot:
        layer = mesh.uv_layers.get(uv_map) if uv_map else None
        layers.append(layer if layer is not None else active)
    names = {layer.name for layer in layers}
    if len(names) == 1:
        return loops, _layer_uvs(mesh, layers[0])
    tables = {name: _layer_uvs(mesh, mesh.uv_layers[name]) for name in names}
    by_slot = [tables[layer.name] for layer in layers]
    fallback = tables.get(active.name) or _layer_uvs(mesh, active)
    corners = array('f', [0.0]) * (6 * len(materials))
    last = len(by_slot) - 1
    for t, slot in enumerate(materials):
        source = by_slot[slot] if 0 <= slot <= last else fallback
        for k in range(3 * t, 3 * t + 3):
            loop = loops[k]
            corners[2 * k] = source[2 * loop]
            corners[2 * k + 1] = source[2 * loop + 1]
    return array('I', range(3 * len(materials))), corners


def report(shown):
    """After a mirroring pass: every textured object's UVs and slots.

    `shown` is what the pass drew — name to (vertices, triangles) — because the
    UVs have to belong to those very triangles. The evaluated mesh is read, as
    the mirror reads it and as Blender's painter paints it: its loop triangles
    are the viewport's triangles, in the same order.
    """
    if _native is None or not _is_real_blender():
        return
    depsgraph = bpy.context.evaluated_depsgraph_get()
    pushed = set()
    _native.surface_begin()
    try:
        for name, counts in shown.items():
            obj = bpy.data.objects.get(name)
            # A wire mesh reaches the mirror too, and has no surface to paint.
            if obj is None or obj.type != 'MESH' or not counts[1]:
                continue
            per_slot = slots(obj)
            if not any(image is not None for image, _, _ in per_slot):
                continue
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            if mesh is None:
                continue
            try:
                mesh.calc_loop_triangles()
                triangles = len(mesh.loop_triangles)
                if (len(mesh.vertices), triangles) != tuple(counts):
                    continue
                loops = array('I', [0]) * (3 * triangles)
                mesh.loop_triangles.foreach_get('loops', loops)
                materials = array('i', [0]) * triangles
                mesh.loop_triangles.foreach_get('material_index', materials)
                corners, uvs = _corner_uvs(mesh, per_slot, loops, materials)
                active = min(max(obj.active_material_index, 0), len(per_slot) - 1)
                _native.surface_push(
                    name, corners, uvs, materials,
                    '\n'.join(image.name if image is not None else '' for image, _, _ in per_slot),
                    bytes(1 if linked else 0 for _, _, linked in per_slot), active)
            finally:
                evaluated.to_mesh_clear()
            for image, _, _ in per_slot:
                if image is not None and image.name not in pushed:
                    pushed.add(image.name)
                    _push_pixels(image)
    finally:
        _native.surface_end()


# --------------------------------------------------------------------------
# Keeping a stroke

def write(names):
    """Put the viewport's pixels for each named image into Blender, and pack.

    `foreach_set` takes the floats straight from the app's buffer, `update`
    tells Blender its display copy is stale, and `pack` embeds the image in the
    .blend: a generated or painted image that is not packed is not saved at
    all, and the undo checkpoint written next would come back without the
    stroke. Packing also clears `is_dirty`, which is what keeps the next
    mirroring pass from reading the image straight back.
    """
    if _native is None or not _is_real_blender():
        return 0
    written = 0
    for name in names:
        image = bpy.data.images.get(name)
        if image is None:
            raise RuntimeError("Texture Paint: there is no image named " + name)
        raw = _native.image_pixels(name)
        if raw is None:
            continue
        if len(raw) != 4 * len(image.pixels):
            raise RuntimeError("Texture Paint: " + name + " changed size in Blender during the stroke")
        image.pixels.foreach_set(memoryview(raw).cast('f'))
        image.update()
        image.pack()
        _native.image_written(name)
        _signatures[name] = _signature(image)
        _undo_painted(name)
        written += 1
    return written


def _undo_painted(name):
    """Tell the undo history this image's pixels changed.

    Blender's memfile undo restores the packed data but not the image's pixel
    buffer, so without this an undo left the stroke on screen and in `pixels`.
    The history reloads, on undo and redo, the images whose buffers hold a
    different stroke from the step it restores (_blenderkit_undo)."""
    undo = sys.modules.get('_blenderkit_undo')
    if undo is None:
        try:
            import _blenderkit_undo as undo
        except ImportError:
            return
    undo.painted(name)
