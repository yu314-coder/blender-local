"""Texture Paint's Python, run by a headless Blender the way an iPad runs it.

scripts/run-texpaint-blender-check.sh starts Blender with `-b --factory-startup`:
no user settings, and no 3D View area — `bpy.context.area` is None, as it is
for the bpy module on a device, which is why the brush itself runs in Swift.
Every call checked is what the Swift sends, printed by
tests/texpaint/blender/main.swift, and the module it calls is the one the app
ships, Resources/python/site/_blenderkit_texpaint.py.
"""
import bpy, contextlib, glob, io, mathutils, os, sys, time, types, pathlib, importlib.util, random
from array import array

CALLS, WORK = sys.argv[-2], sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


def run(name, namespace=None):
    """Runs one block as the app's interpreter would — in the namespace it
    shares with the blocks run before it — and returns what it printed."""
    namespace = {"bpy": bpy} if namespace is None else namespace
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        exec(compile(blocks[name], "<" + name + ">", "exec"), namespace)
    return [line for line in printed.getvalue().splitlines() if line]


def enter(name):
    """Entering, as BpyBridge.enterTexturePaint sends it: the block, then the
    query that reads back what it made, in one namespace."""
    namespace = {"bpy": bpy}
    run(name, namespace)
    return run("MADE", namespace)


class Bridge(types.ModuleType):
    """The app's `_blenderkit`, as much of it as a mirroring pass calls."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.pushed = {}

    def sync_begin(self):
        self.pushed = {}

    def sync_push(self, name, kind, matrix, verts, normals, tris, selected, active, rgba):
        self.pushed[name] = dict(verts=len(verts) // 12, tris=len(tris) // 12)

    def sync_end(self):
        pass

    def mode(self):
        return "TEXTURE_PAINT"

    def set_mode(self, mode):
        pass

    def sync_edit_selection(self, *args):
        pass

    def select_all(self, on=True):
        pass

    def select(self, name, on=True):
        pass

    def set_active(self, name):
        pass

    def material_set(self, *args):
        pass

    def set_timeline(self, *args):
        pass


class Native(types.ModuleType):
    """The app's `_blenderkit_paint`: records what the viewport is handed, and
    serves the stroke the Swift engine painted."""

    def __init__(self):
        super().__init__("_blenderkit_paint")
        self.surfaces = {}
        self.pending = None
        self.pushed = []
        self.images = {}
        self.stroke = {}
        self.written = []

    def surface_begin(self):
        self.pending = {}

    def surface_push(self, name, loops, uvs, materials, images, base, active):
        self.pending[name] = dict(loops=list(loops), uvs=list(uvs), materials=list(materials),
                                  images=images.split("\n"), base=list(base), active=active)

    def surface_end(self):
        self.surfaces, self.pending = self.pending, None

    def image_push(self, name, width, height, channels, is_float, pixels):
        self.pushed.append(name)
        self.images[name] = (width, height, channels, bool(is_float), len(pixels))

    def image_pixels(self, name):
        return self.stroke.get(name)

    def image_written(self, name):
        self.written.append(name)

    def shim_enter(self, *args):
        raise AssertionError("the simulator's path ran inside Blender")


bridge, native = Bridge(), Native()
sys.modules["_blenderkit"] = bridge
sys.modules["_blenderkit_paint"] = native


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


texpaint = load("_blenderkit_texpaint")
sync = load("_blenderkit_sync")


def uvs_of(obj):
    buffer = array('f', [0.0]) * (2 * len(obj.data.loops))
    obj.data.uv_layers.active.uv.foreach_get('vector', buffer)
    return buffer


def image_bytes(image):
    """Blender's pixels as bytes, bottom row first."""
    values = array('f', [0.0]) * len(image.pixels)
    image.pixels.foreach_get(values)
    return bytes(min(255, max(0, int(round(v * 255)))) for v in values)


print("headless, as on an iPad")
check("there is no 3D View area here, as there is none for bpy on a device",
      bpy.context.area is None, bpy.context.area)


print("\nthe brushes are Blender's essentials")
brush_root = glob.glob(os.path.join(os.path.dirname(bpy.app.binary_path), "..", "Resources", "*",
                                    "datafiles", "assets", "brushes"))[0]
loaded = {}
for line in blocks["BRUSHES"].splitlines():
    name, kind, strength, spacing, preset, p_size, p_strength, blend = line.split("|")
    filename = "essentials_brushes-mesh_texture.blend"
    with bpy.data.libraries.load(os.path.join(brush_root, filename), assets_only=True) as (src, dst):
        dst.brushes = [name]
    brush = loaded[name] = dst.brushes[0]
    blender_kind = brush.image_brush_type
    check(f"{name} is a Texture Paint brush", brush.use_paint_image, brush.use_paint_image)
    got = (blender_kind, round(brush.strength, 4), float(brush.spacing), brush.curve_distance_falloff_preset,
           brush.use_pressure_size, brush.use_pressure_strength, brush.blend)
    want = (kind, round(float(strength), 4), float(spacing), preset, p_size == "1", p_strength == "1", blend)
    check(f"{name}: type, strength, spacing, falloff preset, pressure and blend", got == want, (got, want))

for line in blocks["FALLOFF"].splitlines():
    name, values = line.split("|")
    swift = [float(v) for v in values.split()]
    brush = loaded[name]
    if brush.curve_distance_falloff_preset == 'CUSTOM':
        curve = brush.curve_distance_falloff
        curve.initialize()
        blender = [min(1.0, max(0.0, curve.evaluate(curve.curves[0], i / 64))) if i < 64 else 0.0
                   for i in range(65)]
    else:
        blender = [(3 * p * p - 2 * p * p * p) if i < 64 else 0.0 for i, p in ((i, 1 - i / 64) for i in range(65))]
    worst = max(abs(a - b) for a, b in zip(swift, blender))
    check(f"{name}: the falloff at 65 distances is Blender's {brush.curve_distance_falloff_preset}",
          len(swift) == 65 and worst < 1e-4, worst)

size, r, g, b = (float(v) for v in blocks["UNIFIED"].split())
ups = bpy.context.scene.tool_settings.image_paint.unified_paint_settings
check("the brush size is Blender's unified size, a diameter", ups.use_unified_size and ups.size == size
      and bpy.types.UnifiedPaintSettings.bl_rna.properties['size'].description == "Diameter of the brush",
      (ups.size, size))
check("the colour is Blender's unified colour, black", ups.use_unified_color and tuple(ups.color) == (r, g, b),
      tuple(ups.color))
occlude, cull, normal, angle, bleed = blocks["OPTIONS"].split()
settings = bpy.context.scene.tool_settings.image_paint
check("occlusion, culling, normal falloff and its angle, and seam bleed are Blender's defaults",
      (settings.use_occlude, settings.use_backface_culling, settings.use_normal_falloff,
       settings.normal_angle, settings.seam_bleed)
      == (occlude == "1", cull == "1", normal == "1", round(float(angle)), int(bleed)))
slot_name, uv_name, stroke_name = blocks["UNDO_NAMES"].splitlines()
check("undo steps carry Blender's operator names, and entering that makes nothing makes none",
      slot_name == bpy.ops.paint.add_texture_paint_slot.get_rna_type().name
      and uv_name == bpy.ops.paint.add_simple_uvs.get_rna_type().name and stroke_name == "Texture Paint"
      and blocks["UNDO_NONE"] == "none",
      (slot_name, uv_name, stroke_name, blocks["UNDO_NONE"]))


print("\nentering Texture Paint on Blender's cube")
bpy.ops.wm.read_homefile(use_factory_startup=True)
cube = bpy.data.objects["Cube"]
bpy.context.view_layer.objects.active = cube
had = [u.name for u in cube.data.uv_layers]
made = enter("ENTER_CUBE")
check("it has a UV map and a material, so only a paint slot is made", made == ["Add Paint Slot"], made)
material = cube.active_material
node = material.node_tree.nodes.active
check("the slot is an Image Texture node, made active", node.type == 'TEX_IMAGE', node.type)
check("wired into the Principled BSDF's Base Color",
      any(link.from_node == node and link.to_socket.name == 'Base Color' for link in material.node_tree.links))
image = node.image
first = array('f', [0.0]) * len(image.pixels)
image.pixels.foreach_get(first)
check("its image is Add Paint Slot's: <material> Base Color, 1024², bytes, the base colour",
      image.name == "Material Base Color" and tuple(image.size) == (1024, 1024) and not image.is_float
      and abs(first[0] - 0.8) < 1e-3, (image.name, tuple(image.size), image.is_float, first[0]))
check("the UV map is left as it was", [u.name for u in cube.data.uv_layers] == had)
check("Blender is left in object mode", cube.mode == 'OBJECT', cube.mode)
check("the image found is the one Blender's own slot cache names",
      texpaint.canvas_node(material).image == material.texture_paint_images[material.paint_active_slot])
check("entering again makes nothing", enter("ENTER_CUBE") == [])


print("\nentering Texture Paint on a mesh with no UVs and no material")


def bare(name):
    bpy.ops.mesh.primitive_monkey_add(location=(4, 0, 0))
    obj = bpy.context.object
    obj.name = name
    obj.data.name = name
    while obj.data.uv_layers:
        obj.data.uv_layers.remove(obj.data.uv_layers[0])
    obj.data.materials.clear()
    return obj


reference = bare("Reference")
bpy.ops.object.mode_set(mode='TEXTURE_PAINT')
bpy.ops.paint.add_simple_uvs()
bpy.ops.object.mode_set(mode='OBJECT')
wanted = uvs_of(reference)
obj = bare("Bare")
made = enter("ENTER_BARE")
check("a UV map and then a slot are made", made == ["Add Simple UVs", "Add Paint Slot"], made)
check("the UV map is what Blender's Add Simple UVs makes, to the float",
      len(obj.data.uv_layers) == 1 and uvs_of(obj) == wanted)
check("a material was made to hold the slot", obj.active_material is not None and obj.active_material.node_tree)
canvas = texpaint.canvas_node(obj.active_material)
check("its image is named after the object, as Add Paint Slot names one when there was no material",
      canvas is not None and canvas.image.name == "Bare Base Color", canvas and canvas.image.name)
check("Blender is back in object mode, and still adds objects",
      obj.mode == 'OBJECT' and 'FINISHED' in bpy.ops.mesh.primitive_cube_add(location=(0, 6, 0)))


print("\nthe image Blender would paint, without its slot cache")
path = os.path.join(WORK, "slots.blend")
bpy.ops.wm.save_as_mainfile(filepath=path, copy=True, check_existing=False)
bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
cube = bpy.data.objects["Cube"]
material = cube.active_material
tree = material.node_tree
check("after a load, Blender's slot cache is empty — so it cannot be what finds the image",
      len(material.texture_paint_images) == 0)
check("the image is still found", texpaint.canvas_node(material).image.name == "Material Base Color")
bpy.context.view_layer.objects.active = cube


def blender_canvas():
    """What Blender itself would paint: entering its paint mode refreshes the slots."""
    bpy.ops.object.mode_set(mode='TEXTURE_PAINT')
    name = material.texture_paint_images[material.paint_active_slot].name
    bpy.ops.object.mode_set(mode='OBJECT')
    return name


tree.nodes.active = next(n for n in tree.nodes if n.type == 'BSDF_PRINCIPLED')
check("with the BSDF made active since, it is still the image Blender paints",
      texpaint.canvas_node(material).image.name == blender_canvas() == "Material Base Color")
second = tree.nodes.new('ShaderNodeTexImage')
second.image = bpy.data.images.new("Second", 8, 8)
tree.nodes.active = second
check("making another image node active makes that the canvas, for Blender and here",
      texpaint.canvas_node(material).image.name == blender_canvas() == "Second")
tree.nodes.active = next(n for n in tree.nodes if n.type == 'TEX_IMAGE' and n.image.name == "Material Base Color")
settings = bpy.context.scene.tool_settings.image_paint
settings.mode = 'IMAGE'
settings.canvas = bpy.data.images["Second"]
check("in Single Image mode the canvas image is painted on every slot",
      [i.name for i, _, _ in texpaint.slots(cube)] == ["Second"])
settings.mode = 'MATERIAL'
check("in Material mode each slot's canvas, and whether it feeds Base Color",
      [(i.name, linked) for i, _, linked in texpaint.slots(cube)] == [("Material Base Color", True)])


print("\nthe mirror hands the viewport UVs, slots and pixels")
bpy.ops.wm.read_homefile(use_factory_startup=True)
cube = bpy.data.objects["Cube"]
bpy.context.view_layer.objects.active = cube
enter("ENTER_CUBE")
bpy.ops.mesh.primitive_cube_add(location=(0, 4, 0))
native.pushed.clear()
sync.sync()
surface = native.surfaces.get("Cube")
check("the textured cube is reported", surface is not None, list(native.surfaces))
check("an object with nothing to paint is not", "Cube.001" not in native.surfaces, list(native.surfaces))
me = cube.data
me.calc_loop_triangles()
triangles = len(me.loop_triangles)
check("a loop for each corner of the triangles the viewport draws",
      surface is not None and len(surface["loops"]) == 3 * triangles == 3 * bridge.pushed["Cube"]["tris"])
uv = me.uv_layers.active.uv
check("each corner carries the UV Blender stores on its loop",
      all(abs(surface["uvs"][2 * l] - uv[l].vector[0]) < 1e-6 and abs(surface["uvs"][2 * l + 1] - uv[l].vector[1]) < 1e-6
          for l in surface["loops"]))
check("and is the corner of the vertex the viewport draws there",
      [me.loops[l].vertex_index for l in surface["loops"]] == [v for t in me.loop_triangles for v in t.vertices])
check("the slot's image, which feeds Base Color", surface["images"] == ["Material Base Color"] and surface["base"] == [1])
check("its pixels are handed over, once", native.pushed == ["Material Base Color"], native.pushed)
check("at Blender's size and layout",
      native.images["Material Base Color"] == (1024, 1024, 4, False, 1024 * 1024 * 4), native.images["Material Base Color"])
native.pushed.clear()
sync.sync()
check("the next pass does not read them again", native.pushed == [], native.pushed)
image = bpy.data.images["Material Base Color"]
values = array('f', [0.0]) * len(image.pixels)
image.pixels.foreach_get(values)
values[0] = 1.0
image.pixels.foreach_set(values)
native.pushed.clear()
sync.sync()
check("pixels a script changed are read again", native.pushed == ["Material Base Color"], native.pushed)
cube.modifiers.new("Subdivision", 'SUBSURF')
sync.sync()
check("through a modifier, the UVs belong to the evaluated triangles the viewport draws",
      len(native.surfaces["Cube"]["loops"]) == 3 * bridge.pushed["Cube"]["tris"] > 3 * triangles,
      (len(native.surfaces["Cube"]["loops"]), bridge.pushed["Cube"]))
cube.modifiers.clear()


print("\neach material slot paints through its own UV map")
bpy.ops.wm.read_homefile(use_factory_startup=True)
cube = bpy.data.objects["Cube"]
bpy.context.view_layer.objects.active = cube
enter("ENTER_CUBE")
me = cube.data
me.uv_layers.new(name="Second")
# Adding a layer moves the others, so both are looked up afresh.
main_map, second_map = me.uv_layers["UVMap"], me.uv_layers["Second"]
me.uv_layers.active = main_map
layout = array('f', [0.0]) * (2 * len(me.loops))
main_map.uv.foreach_get('vector', layout)
second_map.uv.foreach_set('vector', array('f', (0.5 * v + 0.25 for v in layout)))
other = bpy.data.materials.new("Second")
if other.node_tree is None:
    other.use_nodes = True
other_tree = other.node_tree
image_node = other_tree.nodes.new('ShaderNodeTexImage')
image_node.image = bpy.data.images.new("Second Image", 16, 16)
uv_node = other_tree.nodes.new('ShaderNodeUVMap')
uv_node.uv_map = "Second"
mapping = other_tree.nodes.new('ShaderNodeMapping')
other_tree.links.new(uv_node.outputs['UV'], mapping.inputs['Vector'])
other_tree.links.new(mapping.outputs['Vector'], image_node.inputs['Vector'])
other_tree.nodes.active = image_node
me.materials.append(other)
for polygon in me.polygons:
    polygon.material_index = 1 if polygon.index >= 3 else 0
bpy.ops.object.mode_set(mode='TEXTURE_PAINT')
blender_maps = [slot.material.texture_paint_slots[slot.material.paint_active_slot].uv_layer
                for slot in cube.material_slots]
bpy.ops.object.mode_set(mode='OBJECT')
ours = [uv_map or '' for _, uv_map, _ in texpaint.slots(cube)]
check("each slot's UV map is the one Blender's own paint slots name, found through a Mapping node",
      ours == blender_maps == ['', 'Second'], (ours, blender_maps))
sync.sync()
surface = native.surfaces["Cube"]
me.calc_loop_triangles()
tables = {}
for layer in (me.uv_layers["UVMap"], me.uv_layers["Second"]):
    values = array('f', [0.0]) * (2 * len(me.loops))
    layer.uv.foreach_get('vector', values)
    tables[layer.name] = values
wanted = []
for triangle in me.loop_triangles:
    source = tables["Second" if triangle.material_index == 1 else "UVMap"]
    for loop in triangle.loops:
        wanted += [source[2 * loop], source[2 * loop + 1]]
got = []
for corner in surface["loops"]:
    got += [surface["uvs"][2 * corner], surface["uvs"][2 * corner + 1]]
check("the two maps really differ, so the next check could fail",
      max(abs(a - b) for a, b in zip(tables["UVMap"], tables["Second"])) > 0.1)
check("a triangle's corners carry the UVs of its own slot's map",
      len(got) == len(wanted) == 72 and max(abs(a - b) for a, b in zip(got, wanted)) < 1e-6, len(got))
check("with both slots' images, and each triangle's slot",
      surface["images"] == ["Material Base Color", "Second Image"]
      and surface["materials"] == [t.material_index for t in me.loop_triangles], surface["images"])


print("\na stroke is kept: written, packed, one undo step")
bpy.ops.wm.read_homefile(use_factory_startup=True)
bpy.ops.mesh.primitive_plane_add(size=2, location=(0, 0, 3))
canvas = bpy.context.object
canvas.name = "Canvas"
made = enter("ENTER_CANVAS")
image = texpaint.canvas_node(canvas.active_material).image
check("a 64² image to paint on the plane", tuple(image.size) == (64, 64) and made == ["Add Paint Slot"]
      and image.name == "Canvas Base Color", (tuple(image.size), made, image.name))
root = os.path.join(WORK, "history", ".blender-history")
before = image_bytes(image)
sync.checkpoint(root, "Original")
native.stroke["Canvas Base Color"] = bytes.fromhex(blocks["STROKE_FLOATS"])
run("WRITE_CANVAS")
painted_top_down = bytes.fromhex(blocks["STROKE_BYTES"])
painted = b"".join(painted_top_down[(63 - y) * 256:(64 - y) * 256] for y in range(64))
check("Blender's image holds the stroke the engine painted, to the byte", image_bytes(image) == painted)
check("and the stroke changed something", painted != before)
check("the image is packed into the .blend, and not left dirty",
      image.packed_file is not None and not image.is_dirty, (image.packed_file, image.is_dirty))
check("the viewport is told Blender has it", native.written == ["Canvas Base Color"], native.written)
native.pushed.clear()
sync.sync()
check("so the next mirroring pass does not read the image back", "Canvas Base Color" not in native.pushed,
      native.pushed)
state = sync.checkpoint(root, "Texture Paint")
check("the stroke is one undo step", state == {'undo': True, 'redo': False}, state)
sync.history_step(-1)
check("undo restores the pixels from before the stroke", image_bytes(bpy.data.images["Canvas Base Color"]) == before)
native.pushed.clear()
sync.sync()
check("and the viewport is handed those again", "Canvas Base Color" in native.pushed, native.pushed)
sync.history_step(1)
check("redo brings the stroke back", image_bytes(bpy.data.images["Canvas Base Color"]) == painted)

image = bpy.data.images["Canvas Base Color"]
values = array('f', [0.0]) * len(image.pixels)
image.pixels.foreach_get(values)
for i in range(0, len(values), 4):
    values[i] = 0.0
image.pixels.foreach_set(values)
image.update()
sync.checkpoint(root, "Not packed")
sync.history_step(-1)
sync.history_step(1)
check("for contrast: pixels written without packing again come back as the last packed stroke",
      image_bytes(bpy.data.images["Canvas Base Color"]) == painted)
bpy.ops.wm.open_mainfile(filepath=os.path.join(WORK, "history", "autosave.blend"), load_ui=False)
check("the autosave carries the stroke", image_bytes(bpy.data.images["Canvas Base Color"]) == painted)


print("\na float image keeps what a byte cannot hold")
bpy.ops.wm.read_homefile(use_factory_startup=True)
bpy.ops.mesh.primitive_plane_add(location=(0, 0, 3))
bpy.context.object.name = "HDR"
bpy.ops.paint.add_texture_paint_slot(type='BASE_COLOR', slot_type='IMAGE', name="HDR Base Color",
                                     color=(0.8, 0.8, 0.8, 1), width=8, height=8, alpha=True,
                                     generated_type='BLANK', float=True)
# Opaque, as a Base Color texture is: Blender reads a packed EXR back as
# straight alpha and premultiplies it, so a translucent texel would not
# round-trip through its own packing either.
values = array('f', [0.5, 0.5, 0.5, 1.0]) * (8 * 8)
values[0] = 3.0
native.stroke["HDR Base Color"] = values.tobytes()
texpaint.write(["HDR Base Color"])
path = os.path.join(WORK, "hdr.blend")
bpy.ops.wm.save_as_mainfile(filepath=path, copy=True, check_existing=False)
bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
kept = array('f', [0.0]) * (8 * 8 * 4)
bpy.data.images["HDR Base Color"].pixels.foreach_get(kept)
check("packed, a value of 3.0 survives a save and a load", abs(kept[0] - 3.0) < 1e-4 and abs(kept[1] - 0.5) < 1e-4,
      list(kept[:4]))


def floats_of(image):
    values = array('f', [0.0]) * len(image.pixels)
    image.pixels.foreach_get(values)
    return values


print("\nthe brush size is Blender's: a diameter in region pixels")
size, measured, ppp = (float(v) for v in blocks["PIXELS"].split())
ups = bpy.context.scene.tool_settings.image_paint.unified_paint_settings
check("Blender's unified and brush sizes are PIXEL_DIAMETER",
      bpy.types.UnifiedPaintSettings.bl_rna.properties['size'].subtype == 'PIXEL_DIAMETER'
      and bpy.types.Brush.bl_rna.properties['size'].subtype == 'PIXEL_DIAMETER')
check("a Size %g brush painted on a %g× screen is %g pixels across (%.1f measured), not %g points"
      % (ups.size, ppp, ups.size, measured, ups.size),
      size == ups.size and abs(measured - ups.size) < 2, (size, measured, ups.size))


print("\na float image is painted in float and kept without a byte")
bpy.ops.wm.read_homefile(use_factory_startup=True)
bpy.ops.mesh.primitive_plane_add(size=2, location=(0, 0, 3))
bpy.context.object.name = "Float Canvas"
bpy.ops.paint.add_texture_paint_slot(type='BASE_COLOR', slot_type='IMAGE', name="Canvas Float",
                                     color=(0.8, 0.8, 0.8, 1), width=64, height=64, alpha=True,
                                     generated_type='BLANK', float=True)
image = bpy.data.images["Canvas Float"]
before = array('f')
before.frombytes(bytes.fromhex(blocks["FLOAT_BEFORE"]))
after = array('f')
after.frombytes(bytes.fromhex(blocks["FLOAT_AFTER"]))
check("Add Paint Slot with Float makes a float image of the engine's size",
      image.is_float and len(image.pixels) == len(before) == len(after), (image.is_float, len(image.pixels)))
image.pixels.foreach_set(before)
image.update()
image.pack()
root = os.path.join(WORK, "float-history", ".blender-history")
sync.checkpoint(root, "Original")
native.stroke["Canvas Float"] = after.tobytes()
native.written.clear()
texpaint.write(["Canvas Float"])
got = floats_of(image)
check("kept, Blender's float image holds the floats the engine painted, bit for bit",
      got.tobytes() == after.tobytes() and native.written == ["Canvas Float"])
changed = [i for i in range(0, len(after), 4) if after[i:i + 4] != before[i:i + 4]]
check("the stroke changed texels", len(changed) > 100, len(changed))
hdr = (60 * 64 + 4) * 4
check("a texel the brush did not reach keeps its 3.0, which no byte holds", got[hdr] == 3.0 and hdr not in changed,
      got[hdr])
swatch = [float(v) for v in blocks["FLOAT_COLOUR"].split()]
linear = mathutils.Color(swatch).from_srgb_to_scene_linear()
full = [i for i in changed
        if abs(after[i + 3] - 1) < 1e-6 and max(abs(after[i + k] - linear[k]) for k in range(3)) < 1e-5]
check("where the brush reached full strength a texel is the swatch in Blender's scene-linear",
      len(full) > 20, (len(full), tuple(linear)))
grid = [mathutils.Color((b / 255,) * 3).from_srgb_to_scene_linear()[0] for b in range(256)]
off = sum(1 for i in changed if min(abs(after[i + 1] - g) for g in grid) > 1e-4)
check("and where it faded, values between any two an sRGB byte can hold", off > 20, off)
state = sync.checkpoint(root, "Texture Paint")
check("the float stroke is one undo step", state == {'undo': True, 'redo': False}, state)
sync.history_step(-1)
back = floats_of(bpy.data.images["Canvas Float"])
error = max(abs(a - b) for a, b in zip(back, before))
check("undo puts the floats from before the stroke back (largest difference %g)" % error, error < 1e-5, error)
sync.history_step(1)
forward = floats_of(bpy.data.images["Canvas Float"])
error = max(abs(a - b) for a, b in zip(forward, after))
check("redo brings the painted floats back (largest difference %g)" % error, error < 1e-5, error)


print("\nTexture Paint's tools are Blender's")
from bl_ui.space_toolsystem_toolbar import VIEW3D_PT_tools_active
from bl_ui.space_toolsystem_common import ToolDef
image_types = {item.identifier for item in bpy.types.Brush.bl_rna.properties['image_brush_type'].enum_items}
vertex_types = {item.identifier for item in bpy.types.Brush.bl_rna.properties['vertex_brush_type'].enum_items}
toolbar = [tool for tool in VIEW3D_PT_tools_active._tools['PAINT_TEXTURE'] if isinstance(tool, ToolDef)]
toolbar_types = {tool.brush_type or 'DRAW' for tool in toolbar if 'USE_BRUSHES' in (tool.options or ())}
ours = blocks["TEXTURE_TOOLS"].split()
check("every brush type Texture Paint paints with is an image_brush_type on Blender's Texture Paint toolbar",
      ours and all(kind in image_types and kind in toolbar_types for kind in ours),
      (ours, sorted(image_types), sorted(toolbar_types)))
check("Blender's Texture Paint has no Average: not an image_brush_type, not on its toolbar",
      'AVERAGE' not in image_types and 'AVERAGE' not in toolbar_types, sorted(toolbar_types))
live = [line.split("|") for line in blocks["TOOLBAR"].splitlines()]
check("every live tool that takes the view into Texture Paint paints with one of those types",
      live and all(kind in toolbar_types for _, on, kind in live if on == "1"), live)
check("Average is not among them; it takes the view to Vertex Paint, where Blender has an AVERAGE brush",
      not any(label == "Average" for label, _, _ in live) and blocks["AVERAGE_MODE"] == "VERTEX_PAINT"
      and 'AVERAGE' in vertex_types, (blocks["AVERAGE_MODE"], live))


print("\nhow long keeping a 1024² stroke takes")
bpy.ops.wm.read_homefile(use_factory_startup=True)
bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]
enter("ENTER_CUBE")
rng = random.Random(7)
values = array('f', [0.8, 0.8, 0.8, 1.0]) * (1024 * 1024)
for y in range(312, 712):
    row = y * 1024 * 4
    for x in range(312, 712):
        values[row + 4 * x] = rng.randrange(256) / 255
native.stroke["Material Base Color"] = values.tobytes()
times = []
for _ in range(3):
    started = time.time()
    texpaint.write(["Material Base Color"])
    times.append((time.time() - started) * 1000)
print("        foreach_set, update and pack: " + ", ".join("%.1f ms" % t for t in times))
check("a 1024² stroke is kept in well under a quarter of a second", min(times) < 250, times)

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
