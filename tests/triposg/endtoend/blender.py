"""The Blender steps of tests/triposg/endtoend, with the app's module:
    blender -b --factory-startup --python blender.py -- prepare <folder>
    blender -b --factory-startup --python blender.py -- finish <folder> <name> <renders dir>
`finish` also saves <folder>/model.blend and renders the model from the front,
the side and the back in Material Preview's texture colours."""
import bpy, importlib.util, json, math, os, pathlib, sys
from mathutils import Vector
args = sys.argv[sys.argv.index("--") + 1:]
ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("_blenderkit_image3d", ROOT / "Resources/python/site/_blenderkit_image3d.py")
image3d = importlib.util.module_from_spec(spec); spec.loader.exec_module(image3d)
if args[0] == "prepare":
    for o in list(bpy.data.objects): bpy.data.objects.remove(o)
    print("[e2e] prepare", image3d.prepare_full(args[1], 50000))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(args[1], "prepared.blend"))
else:
    folder, name, renders = args[1], args[2], args[3]
    bpy.ops.wm.open_mainfile(filepath=os.path.join(folder, "prepared.blend"))
    result = json.loads(image3d.finish_full(folder, os.path.join(folder, "texture.png"), name))
    print("[e2e] finish", result)
    obj = bpy.data.objects[result["object"]]
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'; scene.display.shading.color_type = 'TEXTURE'
    scene.render.resolution_x = scene.render.resolution_y = 360
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); scene.collection.objects.link(cam); scene.camera = cam
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 2.3
    os.makedirs(renders, exist_ok=True)
    # Blender's front view looks along +Y: the model's front should face it.
    for i, (label, direction) in enumerate((("front", (0, -1, 0.15)), ("side", (1, 0, 0.15)), ("back", (0, 1, 0.15)), ("three-quarter", (-0.7, -0.7, 0.3)))):
        cam.location = Vector(direction).normalized() * 6
        cam.rotation_euler = (-cam.location).to_track_quat('-Z', 'Y').to_euler()
        scene.render.filepath = os.path.join(renders, f"{name}-{i}-{label}.png")
        bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(folder, "model.blend"))
    print("[e2e] dimensions", tuple(round(v, 3) for v in obj.dimensions), "packed", obj.active_material.node_tree.nodes.active.image.packed_file is not None)
