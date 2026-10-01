"""Image to 3D Model, Blender's half, run by a headless Blender.

scripts/run-image3d-blender-check.sh builds tests/image3d/blender/main.swift,
which writes the model folders ImageToModel.swift makes and prints the Python
the app sends. This makes each folder's texture.png, runs that Python, and
checks what Blender ended up with: the mesh against the files, the UVs, the
material the viewport's texture mirroring reads, the packed picture surviving
the folder's removal and a save and reload, and which way the front faces.
"""
import bmesh, bpy, importlib.util, json, os, pathlib, shutil, sys
from array import array

CALLS, WORK = sys.argv[-2], sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = str(ROOT / "Resources/python/site")
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


# The app's modules, not the shim's bpy: append, so Blender's own bpy stays.
sys.path.append(SITE)
spec = importlib.util.spec_from_file_location("_blenderkit_image3d", os.path.join(SITE, "_blenderkit_image3d.py"))
image3d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image3d)
spec = importlib.util.spec_from_file_location("_blenderkit_texpaint", os.path.join(SITE, "_blenderkit_texpaint.py"))
texpaint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(texpaint)

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body

# Start from edit mode on the default cube: the build has to leave it.
bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]
bpy.ops.object.mode_set(mode='EDIT')

for label, (width, height) in (("OVAL", (256, 192)), ("WHOLE", (64, 128))):
    print(f"\n  {label}")
    folder = os.path.join(WORK, label)
    meta = json.load(open(os.path.join(folder, "meta.json")))
    picture = bpy.data.images.new("source_" + label, width, height)
    pixels = array('f', [0.0]) * (width * height * 4)
    for y in range(height):
        for x in range(width):
            k = (y * width + x) * 4
            pixels[k:k + 4] = array('f', [x / width, y / height, 0.25, 1.0])
    picture.pixels.foreach_set(pixels)
    picture.filepath_raw = os.path.join(folder, "texture.png")
    picture.file_format = 'PNG'
    picture.save()
    bpy.data.images.remove(picture)

    ns = {"bpy": bpy}
    import io, contextlib
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(blocks[label], "<call>", "exec"), ns)
        result = json.loads([l for l in printed.getvalue().splitlines() if l.startswith("{")][-1])
    except Exception as error:
        check(f"{label}: Blender runs the call", False, f"{type(error).__name__}: {error}")
        continue
    check(f"{label}: Blender runs the call", True)
    obj = bpy.data.objects.get(result["object"])
    check(f"{label}: the object it names exists", obj is not None, result)
    if obj is None:
        continue
    mesh = obj.data
    check(f"{label}: vertices and faces match the files",
          (len(mesh.vertices), len(mesh.polygons), len(mesh.loops)) == (meta["vertices"], meta["faces"], meta["loops"]),
          ((len(mesh.vertices), len(mesh.polygons), len(mesh.loops)), meta))
    check(f"{label}: it is active, the only one selected, in object mode",
          bpy.context.view_layer.objects.active == obj and bpy.context.selected_objects == [obj] and obj.mode == 'OBJECT',
          (bpy.context.view_layer.objects.active, bpy.context.selected_objects, obj.mode))
    check(f"{label}: Blender left the cube's edit mode", bpy.data.objects["Cube"].mode == 'OBJECT')
    uv = mesh.uv_layers.active
    got = array('f', [0.0]) * (len(mesh.loops) * 2)
    if uv is not None:
        uv.data.foreach_get("uv", got)
    want = array('f'); want.fromfile(open(os.path.join(folder, "uvs.bin"), "rb"), len(mesh.loops) * 2)
    check(f"{label}: every corner has the UV the app computed",
          uv is not None and max(abs(a - b) for a, b in zip(got, want)) < 1e-5)
    check(f"{label}: smooth shaded", all(p.use_smooth for p in mesh.polygons))
    check(f"{label}: Blender finds nothing to fix in the mesh", not mesh.validate(verbose=False))

    mat = mesh.materials[0] if mesh.materials else None
    check(f"{label}: one material", mat is not None and len(mesh.materials) == 1)
    slots = texpaint.slots(obj)
    image = slots[0][0] if slots else None
    check(f"{label}: the viewport's texture reader finds the picture, feeding Base Color",
          image is not None and slots[0][2], slots)
    check(f"{label}: the picture is packed", image is not None and image.packed_file is not None)
    check(f"{label}: the picture's pixels are the texture's",
          image is not None and tuple(image.size) == (width, height)
          and abs(image.pixels[(height // 2 * width + width // 2) * 4] - 0.5) < 0.02,
          image and (tuple(image.size), image.pixels[(height // 2 * width + width // 2) * 4]))
    check(f"{label}: at the location asked for",
          tuple(round(v, 4) for v in obj.location) == ((1.0, 2.0, 3.0) if label == "OVAL" else (0.0, 0.0, 0.0)),
          tuple(obj.location))

    bm = bmesh.new(); bm.from_mesh(mesh)
    edges = len(bm.edges)
    open_edges = sum(1 for e in bm.edges if len(e.link_faces) == 1)
    over = sum(1 for e in bm.edges if len(e.link_faces) > 2)
    front = [f for f in bm.faces if f.index < meta["front_faces"]]
    facing = sum(f.normal.y for f in front) / len(front)
    bm.free()
    check(f"{label}: no edge shared by three faces", over == 0, over)
    if label == "OVAL":
        check(f"{label}: closed but for a handful of edges", open_edges / edges < 0.02, f"{open_edges} of {edges}")
        check(f"{label}: the front faces Blender's front view, -Y", facing < -0.5, facing)
    else:
        check(f"{label}: a card the size of the picture: 1 x 2 m",
              abs(obj.dimensions.x - 1) < 0.05 and abs(obj.dimensions.z - 2) < 0.05, tuple(obj.dimensions))

    shutil.rmtree(folder)

print("\n  FULL")
import contextlib, io
folder = os.path.join(WORK, "FULL")
meta = json.load(open(os.path.join(folder, "meta.json")))
def call(label):
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        exec(compile(blocks[label], "<call>", "exec"), {"bpy": bpy})
    return json.loads([l for l in printed.getvalue().splitlines() if l.startswith("{")][-1])
bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]
bpy.ops.object.mode_set(mode='EDIT')
objects_before = set(bpy.data.objects.keys())
try:
    prepared = call("FULL_PREPARE")
    check("FULL: prepare runs", True)
except Exception as error:
    prepared = None
    check("FULL: prepare runs", False, f"{type(error).__name__}: {error}")
if prepared:
    check("FULL: decimated to at most the faces asked for", prepared["triangles"] <= 1500 and meta["triangles"] > 1500,
          (prepared, meta["triangles"]))
    check("FULL: no object is left behind by preparing", set(bpy.data.objects.keys()) == objects_before,
          set(bpy.data.objects.keys()) ^ objects_before)
    check("FULL: the pending mesh is kept for finishing", bpy.data.meshes.get(image3d.PENDING) is not None
          and bpy.data.meshes[image3d.PENDING].use_fake_user)
    positions = os.path.getsize(os.path.join(folder, "unwrapped_positions.bin")) // 36
    uvs = os.path.getsize(os.path.join(folder, "unwrapped_uvs.bin")) // 24
    check("FULL: a corner and a UV for every unwrapped triangle", positions == uvs == prepared["triangles"], (positions, uvs))
    uv = array('f'); uv.fromfile(open(os.path.join(folder, "unwrapped_uvs.bin"), "rb"), uvs * 6)
    check("FULL: the UVs are inside the unit square", min(uv) >= 0 and max(uv) <= 1, (min(uv), max(uv)))
    tex = bpy.data.images.new("baked", 64, 64); tex.pixels.foreach_set(array('f', [0.8, 0.2, 0.1, 1.0] * 4096))
    tex.filepath_raw = os.path.join(folder, "texture.png"); tex.file_format = 'PNG'; tex.save(); bpy.data.images.remove(tex)
    try:
        finished = call("FULL_FINISH")
        check("FULL: finish runs", True)
    except Exception as error:
        finished = None
        check("FULL: finish runs", False, f"{type(error).__name__}: {error}")
    if finished:
        obj = bpy.data.objects[finished["object"]]
        check("FULL: the pending mesh became the object's", bpy.data.meshes.get(image3d.PENDING) is None and obj.data.name == "Ball"
              and not obj.data.use_fake_user)
        check("FULL: its longest side is 2 m, centred on the cursor",
              abs(max(obj.dimensions) - 2) < 1e-3 and tuple(round(v, 3) for v in obj.location) == (0.0, 0.0, 1.0), (tuple(obj.dimensions), tuple(obj.location)))
        nearest = min(obj.data.vertices, key=lambda v: v.co.y)
        check("FULL: the model's front faces Blender's front view (-Y)",
              abs(nearest.co.x) < 0.2 and abs(nearest.co.z) < 0.2 and nearest.co.y < -0.9, tuple(nearest.co))
        slots = texpaint.slots(obj)
        check("FULL: the texture feeds Base Color, packed", slots and slots[0][0] is not None and slots[0][2]
              and slots[0][0].packed_file is not None, slots)
        check("FULL: it is active and selected, in object mode", bpy.context.view_layer.objects.active == obj
              and obj.select_get() and obj.mode == 'OBJECT')
        check("FULL: the normals point outward", sum((p.center.normalized() if p.center.length else p.center).dot(p.normal) for p in obj.data.polygons) > 0)
try:
    call("FULL_FINISH")
    check("FULL: finishing twice is refused in words", False, "no error")
except RuntimeError as error:
    check("FULL: finishing twice is refused in words", "no prepared model" in str(error), str(error))

print("\n  keeping it")
path = os.path.join(WORK, "kept.blend")
bpy.ops.wm.save_as_mainfile(filepath=path)
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.wm.open_mainfile(filepath=path)
obj = bpy.data.objects.get("Oval Photo")
image = texpaint.slots(obj)[0][0] if obj else None
check("after the folders are gone and the file is reopened, the picture is still there",
      image is not None and image.packed_file is not None and tuple(image.size) == (256, 192),
      image and (image.packed_file, tuple(image.size)))

bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]
print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
