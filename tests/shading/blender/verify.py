"""The normals the 3D View shades a mesh with, the Python half, run by the
Blender it describes (desktop 5.2.1).

scripts/run-shading-blender-check.sh starts desktop Blender with a home of its
own. The app's own `_blenderkit_sync.sync()` and `_blenderkit_anim.push_mesh`
run from the source tree against a `_blenderkit` that records each call, and
the calls go to tests/shading/blender/main.swift, which installs them through
the Swift the device runs and holds what the 3D View draws at every triangle
corner to `truth()`: Blender's corner normals, the normals its Solid view
draws, read here beside each pass.

The scene is round 4's review of the Mesh menu: the six Normals rows whose
whole effect is Blender's custom normals (each run by the row's own first
press, `BpyBridge.performBody`, printed by main.swift), and the shading the
3D View never showed either — a primitive's flat faces, Shade Smooth, Shade
Smooth by Angle — in Object and Edit Mode, with a hidden face, and through a
frame change's `push_mesh` (a sculpt stroke's chunk takes it too).
"""
import bpy, bmesh, gpu, sys, os, types, json, base64, math, pathlib, importlib.util

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

sys.dont_write_bytecode = True
CALLS, RECORDS = sys.argv[sys.argv.index("--") + 1:][:2]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


def b64(data):
    return base64.b64encode(bytes(data)).decode()


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps the calls the 3D View's
    meshes are made from, and answers the rest with nothing."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.calls = []

    def is_main_thread(self):
        return True

    def sync_begin(self):
        self.calls = []

    def sync_push(self, name, kind, matrix, positions, normals, triangles, selected, active, rgba):
        self.calls.append(dict(call="push", name=name, kind=kind, matrix=b64(matrix), positions=b64(positions),
                               normals=b64(normals), triangles=b64(triangles)))

    def sync_edges(self, name, edges):
        self.calls.append(dict(call="edges", name=name, edges=b64(edges)))

    def sync_shading(self, name, domain, loops, normals):
        self.calls.append(dict(call="shading", name=name, domain=domain, loops=b64(loops), normals=b64(normals)))

    def anim_mesh(self, name, positions, normals, triangles, edges=None):
        self.calls.append(dict(call="frame_mesh", name=name, positions=b64(positions), normals=b64(normals),
                               triangles=b64(triangles)))
        return 1

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


bridge = Bridge()
sys.modules["_blenderkit"] = bridge
# The app's other modules, which sync imports as it needs them; at the end of
# the path, so Blender's own bpy and mathutils stay the ones imported.
sys.path.append(str(SITE))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
context.install(bpy)
load("_blenderkit_texpaint")
anim = load("_blenderkit_anim")
load("_blenderkit_tools")
load("_blenderkit_meshmenu")
sync = load("_blenderkit_sync")
gpu.init()


def run(block):
    exec(compile(blocks[block], "<" + block + ">", "exec"), {"bpy": bpy})


def flat_sphere(name, location):
    """The meshmenu check's sphere, 12 x 6 and flat (a BMesh's faces are not
    smooth), its faces in an order that does not depend on memory
    (`bmesh.ops.create_uvsphere`'s does: tests/meshmenu/blender/verify.py)."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=6, radius=1.0)
    bm.verts.index_update()
    verts = [tuple(v.co) for v in bm.verts]
    faces = sorted((tuple(v.index for v in f.verts) for f in bm.faces), key=lambda f: sorted(f))
    bm.free()
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    return obj


def activate(obj):
    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)


def row(obj, block, select):
    """A Normals row's first press on `obj`, in Edit Mode with `select`
    selected ('ALL', or 'TOP' for the face highest up), then Object Mode."""
    activate(obj)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = (select == 'ALL', False, select == 'TOP')
    bm = bmesh.from_edit_mesh(obj.data)
    for seq in (bm.verts, bm.edges, bm.faces):
        for e in seq:
            e.select = select == 'ALL'
    if select == 'TOP':
        max(bm.faces, key=lambda f: (round(f.calc_center_median().z, 4), -f.index)).select_set(True)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)
    try:
        run(block)
        error = None
    except Exception as e:                       # noqa: BLE001 - the words are the point
        error = str(e)
    check(f"{obj.name}: the row's first press ran", error is None, error)
    bpy.ops.object.mode_set(mode='OBJECT')


def truth(names=None):
    """Blender's corner normals for every mesh (or those `names`), per triangle corner in the
    order its loop triangles come, hidden faces left out while editing as the
    mirror leaves them out — what its Solid view draws."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    out = {}
    for obj in bpy.context.scene.objects:
        if obj.type != 'MESH' or (names is not None and obj.name not in names):
            continue
        if obj.mode == 'EDIT':
            obj.update_from_editmode()
        evaluated = obj.evaluated_get(depsgraph)
        me = evaluated.to_mesh()
        me.calc_loop_triangles()
        editing = obj.mode == 'EDIT'
        corners = []
        for t in me.loop_triangles:
            if editing and me.polygons[t.polygon_index].hide:
                continue
            for loop in t.loops:
                corners.extend(me.corner_normals[loop].vector)
        out[obj.name] = dict(domain=me.normals_domain, corners=corners)
        evaluated.to_mesh_clear()
    return out


passes = []


def mirror(label, names=None):
    sync.sync()
    passes.append(dict(label=label, calls=list(bridge.calls), blender=truth(names)))


# --------------------------------------------------------------------------
bpy.ops.wm.read_homefile(use_empty=True)
bpy.context.scene.cursor.location = (2.0, -1.0, 2.5)

# What the 3D View never showed: a primitive's flat faces, Shade Smooth, and
# Shade Smooth by Angle's sharp edges.
bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
bpy.context.object.name = "Cube"
bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
bpy.context.object.name = "Smooth"
bpy.ops.object.shade_smooth()
bpy.ops.mesh.primitive_cylinder_add(location=(6, 0, 0))
bpy.context.object.name = "ByAngle"
bpy.ops.object.shade_smooth_by_angle(angle=math.radians(30))

# The six Normals rows, each by its own first press, on the meshmenu check's
# flat sphere — and Point to Target… on a smooth one, where Blender's vertex
# normals come out as the custom ones (measured: 5.2.1's `vertex_normals`
# after it equal the corner normals there).
rows = [("SetFromFaces", "row.setNormalsFromFaces", 'TOP'), ("PointToTarget", "row.pointNormals", 'ALL'),
        ("AverageCustom", "row.averageCustomNormal", 'ALL'), ("AverageFaceArea", "row.averageFaceArea", 'ALL'),
        ("AverageCornerAngle", "row.averageCornerAngle", 'ALL'), ("SmoothVectors", "row.smoothNormals", 'ALL')]
for k, (name, block, select) in enumerate(rows):
    # Smooth Vectors smooths custom normals: Point to Target… gives it some
    # that differ from vertex to vertex, its Target (the 3D cursor, 2, -1,
    # 2.5) put just inside this sphere.
    obj = flat_sphere(name, (2.0, -1.0, 2.2) if name == "SmoothVectors" else (3 * k, 4, 0))
    if name == "SmoothVectors":
        row(obj, "row.pointNormals", 'ALL')
# Each sphere as the row finds it, so main.swift can say what the row changed
# on screen beside what it changed in Blender.
mirror("the six rows' spheres before their rows", {name for name, _, _ in rows})
for name, block, select in rows:
    row(bpy.data.objects[name], block, select)
bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, location=(0, 8, 0))
smooth_target = bpy.context.object
smooth_target.name = "PointToTargetSmooth"
bpy.ops.object.shade_smooth()
row(smooth_target, "row.pointNormals", 'ALL')

# Edit Mode, the way the rows leave it: a cube with one face hidden and Set
# from Faces run on another; the pass leaves the hidden face out.
bpy.ops.mesh.primitive_cube_add(location=(3, 8, 0))
edited = bpy.context.object
edited.name = "Editing"
row(edited, "row.setNormalsFromFaces", 'TOP')
activate(edited)
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(edited.data)
for f in bm.faces:
    f.select = False
min(bm.faces, key=lambda f: f.calc_center_median().z).select_set(True)
bm.select_flush_mode()
bmesh.update_edit_mesh(edited.data)
bpy.ops.mesh.hide(unselected=False)
mirror("Object Mode's flat, smooth and by-angle meshes; the six rows; one mesh in Edit Mode with a face hidden")
counts = {c["name"]: c["domain"] for c in bridge.calls if c["call"] == "shading"}
check("every mesh's shading went with its push, by Blender's domain (0 POINT, 1 FACE, 2 CORNER): "
      + json.dumps(counts, sort_keys=True), counts.get("Cube") == 1 and counts.get("Smooth") == 0
      and counts.get("ByAngle") == 2 and all(counts.get(n) == 2 for n, _, _ in rows)
      and counts.get("Editing") == 2, counts)
bpy.ops.object.mode_set(mode='OBJECT')

# Shade Smooth and Shade Flat change no vertex: the fast path's meshes.
activate(bpy.data.objects["Cube"])
bpy.ops.object.shade_smooth()
activate(bpy.data.objects["Smooth"])
bpy.ops.object.shade_flat()
mirror("Shade Smooth on the cube, Shade Flat on the sphere", {"Cube", "Smooth"})
counts = {c["name"]: c["domain"] for c in bridge.calls if c["call"] == "shading"}
check("the cube is shaded by its vertex normals now (POINT) and the sphere by its faces (FACE)",
      counts.get("Cube") == 0 and counts.get("Smooth") == 1, counts)

# A frame change's push_mesh, which a sculpt stroke's chunk takes too: a
# flat cube's top raised, its sides tilting.
activate(bpy.data.objects["Smooth"])
bpy.ops.object.shade_flat()
bpy.ops.mesh.primitive_cube_add(location=(6, 8, 0))
deformed = bpy.context.object
deformed.name = "Deformed"
mirror("a flat cube before a frame change deforms it", {"Deformed"})
for v in deformed.data.vertices:
    if v.co.z > 0:
        v.co.x *= 0.5
        v.co.z += 0.5
deformed.data.update()
bridge.calls = []
anim.push_mesh(deformed, bpy.context.evaluated_depsgraph_get())
check("push_mesh sends the deformed mesh's faces' normals after it",
      [c["call"] for c in bridge.calls] == ["frame_mesh", "shading"] and bridge.calls[1]["domain"] == 1,
      [c["call"] for c in bridge.calls])
passes.append(dict(label="the frame change: the top raised and narrowed", calls=list(bridge.calls),
                   blender=truth({"Deformed"}), frame=True))

with open(RECORDS, "w") as f:
    json.dump(passes, f)
print(f"\n{len(passes)} passes written for the Swift to replay")
sys.exit(1 if fail else 0)
