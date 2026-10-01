"""The mirror's Python half, run by the Blender it runs on.

scripts/run-mirror-blender-check.sh starts desktop Blender with
`-b --factory-startup`. The app's own `_blenderkit_sync.sync()` is run from the
source tree against a `_blenderkit` that records every call instead of drawing,
and the calls are written out for tests/mirror/blender/main.swift to replay
through the Swift the device runs.

The objects are the ones the mirror used to drop: every MESH with no
triangles went, so the app's own Add ▸ Circle (fill type Nothing) never reached
the viewport, the Outliner or Knife Project's list of cutters.
"""
import bpy, sys, types, json, base64, pathlib, importlib.util

sys.dont_write_bytecode = True
CALLS, RECORDS = sys.argv[sys.argv.index("--") + 1:][:2]
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


def b64(data):
    return base64.b64encode(bytes(data)).decode()


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps every call a pass makes."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.calls = []

    def sync_begin(self):
        self.calls = []

    def sync_push(self, name, kind, matrix, positions, normals, triangles, selected, active, rgba):
        self.calls.append(dict(call="push", name=name, kind=kind, matrix=b64(matrix),
                               positions=b64(positions), normals=b64(normals),
                               triangles=b64(triangles), selected=selected, active=active))

    def sync_edges(self, name, edges):
        self.calls.append(dict(call="edges", name=name, edges=b64(edges)))

    def sync_modifiers(self, name, record):
        self.calls.append(dict(call="modifiers", name=name, record=record))

    def sync_display(self, name, type, data_name, record):
        self.calls.append(dict(call="display", name=name, type=type, dataName=data_name, record=record))

    def sync_local(self, name, values):
        pass

    def sync_end(self):
        pass

    # A frame change, from `_blenderkit_anim.push_frame`: outside any pass.
    def anim_frame(self, frame, subframe, names, matrices):
        self.calls.append(dict(call="frame", name="", frame=frame))
        return 0

    def anim_mesh(self, name, positions, normals, triangles, edges=None):
        call = dict(call="frame_mesh", name=name, positions=b64(positions), normals=b64(normals),
                    triangles=b64(triangles))
        if edges is not None:
            call["edges"] = b64(edges)
        self.calls.append(call)
        return 1

    def material_set(self, *args):
        pass


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


load("_blenderkit_texpaint")
anim = load("_blenderkit_anim")
load("_blenderkit_tools")
sync = load("_blenderkit_sync")


def run(block):
    exec(compile(blocks[block], "<" + block + ">", "exec"), {"bpy": bpy})
    return bpy.context.object


def mesh_object(name, verts, edges=(), faces=()):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, edges, faces)
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    return obj


def truth():
    """What Blender has, object by object: its type, and its evaluated mesh."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    out = {}
    for obj in bpy.context.scene.objects:
        entry = dict(type=obj.type, vertices=0, edges=0, triangles=0, evaluated=False)
        if obj.type in {"MESH", "CURVE", "FONT"} and obj.visible_get():
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            if mesh is not None:
                mesh.calc_loop_triangles()
                entry.update(vertices=len(mesh.vertices), edges=len(mesh.edges),
                             triangles=len(mesh.loop_triangles), evaluated=len(mesh.vertices) > 0)
                # Where each vertex is, for the small meshes: a Swift stack run
                # over Blender's evaluated mesh keeps the count of a Wave and
                # moves every vertex.
                if len(mesh.vertices) <= 5000:
                    entry["co"] = [c for v in mesh.vertices for c in v.co]
                evaluated.to_mesh_clear()
        out[obj.name] = entry
    return out


passes = []


def mirror():
    pushed = sync.sync()
    passes.append(dict(calls=list(bridge.calls), blender=truth()))
    return pushed


print("A scene whose only mesh is past the limit")
import io, contextlib
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_uv_sphere_add()
# The limit lowered, so a UV sphere (482 vertices) stands in for ten million.
limit, sync._MAX_VERTS = sync._MAX_VERTS, 400
log = io.StringIO()
with contextlib.redirect_stdout(log):
    alone = sync.sync()
sync._MAX_VERTS = limit
check("it is counted as reaching the viewport, as its bounds, and the log does not also say none did",
      alone == 1 and "drawn as its bounds" in log.getvalue()
      and "none reached the viewport" not in log.getvalue(), (alone, log.getvalue()))
bpy.ops.wm.read_homefile(use_empty=True)

print("\nThe scene the mirror used to drop half of")
bpy.ops.wm.read_homefile(use_empty=True)
plane = run("ADD_PLANE")
circle = run("ADD_CIRCLE")
check("the Add menu's circle is a wire in Blender: vertices and edges, no face",
      len(circle.data.vertices) == 32 and len(circle.data.edges) == 32 and len(circle.data.polygons) == 0,
      (len(circle.data.vertices), len(circle.data.edges), len(circle.data.polygons)))
bpy.ops.curve.primitive_bezier_circle_add(location=(3, 0, 0))
bpy.context.object.name = "BezierCircle"
mesh_object("Edges", [(0, 0, 0), (1, 0, 0), (1, 1, 0)], [(0, 1), (1, 2)])
mesh_object("Points", [(0, 0, 0), (1, 0, 0)])
mesh_object("EmptyMesh", [])
curve = bpy.data.curves.new("NoSplines", 'CURVE')
bpy.context.collection.objects.link(bpy.data.objects.new("NoSplines", curve))
bpy.ops.object.text_add(location=(0, 3, 0))
bpy.context.object.name = "EmptyText"
bpy.context.object.data.body = ""
bpy.ops.mesh.primitive_circle_add(location=(0, -3, 0))
bpy.context.object.name = "HiddenCircle"
bpy.context.object.hide_set(True)
bpy.ops.mesh.primitive_cube_add(location=(5, 0, 0))
bpy.context.object.name = "Screwed"
screw = bpy.context.object.modifiers.new("Screw", 'SCREW')
screw.steps = 16
# Past the limit: the limit lowered for the check, so a UV sphere (482
# vertices) stands in for ten million.
bpy.ops.mesh.primitive_uv_sphere_add(location=(0, 0, -5))
bpy.context.object.name = "Huge"
# A wire that will lose every edge and keep every vertex in the second pass.
bpy.ops.mesh.primitive_circle_add(location=(0, 6, 0))
bpy.context.object.name = "Stripped"
# Three a frame change deforms, as a Wave does on every frame (measured in
# 5.2.1: `is_updated_geometry` on each `frame_set`): a grid, a cube whose
# Screw the Swift also models, and a wire circle.
bpy.ops.mesh.primitive_grid_add(size=2, location=(-5, 0, 0))
bpy.context.object.name = "Waver"
bpy.context.object.modifiers.new("Wave", 'WAVE')
bpy.ops.mesh.primitive_cube_add(location=(-5, 5, 0))
bpy.context.object.name = "ScrewWave"
bpy.context.object.modifiers.new("Screw", 'SCREW').steps = 16
bpy.context.object.modifiers.new("Wave", 'WAVE')
bpy.ops.mesh.primitive_circle_add(location=(-5, -5, 0))
bpy.context.object.name = "WireWave"
bpy.context.object.modifiers.new("Wave", 'WAVE')
bpy.ops.object.camera_add(location=(0, -10, 0))
sync._MAX_VERTS = 400
bpy.ops.object.select_all(action='DESELECT')
plane.select_set(True)
bpy.context.view_layer.objects.active = plane

pushed = mirror()
names = {c["name"] for c in passes[0]["calls"] if c["call"] == "push"}
check("every object in the scene is pushed", names == set(o.name for o in bpy.context.scene.objects),
      sorted(set(o.name for o in bpy.context.scene.objects) - names))
edged = {c["name"] for c in passes[0]["calls"] if c["call"] == "edges"}
check("edges go with the ones that have no faces, and only those",
      edged == {"Circle", "BezierCircle", "Edges", "Huge", "Stripped", "WireWave", "Points"},
      sorted(edged))

print("\nA second pass: an edge moved, a modifier on an object already there, a circle filled")
# The same three vertices, one edge moved from 1-2 to 0-2: the vertices come
# back identical, so only the edges tell the two passes apart.
bpy.data.objects["Edges"].data = bpy.data.meshes.new("Edges2")
bpy.data.objects["Edges"].data.from_pydata([(0, 0, 0), (1, 0, 0), (1, 1, 0)], [(0, 1), (0, 2)], [])
bpy.data.objects["Plane"].modifiers.new("Screw", 'SCREW')
filled = bpy.data.objects["Circle"]
bpy.context.view_layer.objects.active = filled
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.fill()
bpy.ops.object.mode_set(mode='OBJECT')
stripped = bpy.data.objects["Stripped"]
before = [tuple(v.co) for v in stripped.data.vertices]
bpy.context.view_layer.objects.active = stripped
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.delete(type='EDGE_FACE')
bpy.ops.object.mode_set(mode='OBJECT')
check("Delete ▸ Only Edges & Faces leaves the circle's vertices where they were, and no edge",
      [tuple(v.co) for v in stripped.data.vertices] == before and len(stripped.data.edges) == 0,
      (len(stripped.data.vertices), len(stripped.data.edges)))
mirror()
stripped_edges = [c for c in passes[-1]["calls"] if c["call"] == "edges" and c["name"] == "Stripped"]
check("and the pass says so, with an empty edge list rather than none",
      len(stripped_edges) == 1 and stripped_edges[0]["edges"] == "", stripped_edges)

print("\nA frame change: what a Wave moved, faces or not")
scene = bpy.context.scene
bridge.calls = []
anim.frame_set(9)
passes.append(dict(calls=list(bridge.calls), blender=truth(), frame=True))
deformed = {c["name"] for c in bridge.calls if c["call"] == "frame_mesh"}
check("the frame hands over the three the Wave deforms, the wire among them",
      deformed == {"Waver", "ScrewWave", "WireWave"}, sorted(deformed))
wire = [c for c in bridge.calls if c["call"] == "frame_mesh" and c["name"] == "WireWave"]
check("the wire comes with its edges", bool(wire) and wire[0].get("edges"), wire)
still = [n for n in ("Waver", "ScrewWave", "WireWave")
         if passes[-1]["blender"][n]["co"] == passes[-2]["blender"][n]["co"]]
check("and the Wave really moved all three between the frames", not still, still)

json.dump(passes, open(RECORDS, "w"))
print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
