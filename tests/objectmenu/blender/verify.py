"""Show/Hide, Separate, Shade Auto Smooth, QuadriFlow and Add ▸ Curve and Text,
run by the Blender they run on.

scripts/run-objectmenu-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: no user settings and no 3D View area in the context,
as for the bpy module on a device. Every string run here is the one the Swift
sends, printed by tests/objectmenu/blender/main.swift. After each, the app's
own `_blenderkit_sync.sync()` runs from the source tree against a `_blenderkit`
that records what it is handed, and the Swift replays that.
"""
import bpy, bmesh, sys, types, json, math, base64, pathlib, importlib.util
from array import array

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

    def sync_edit_selection(self, name, bits, vsel, tpoly, psel, ends, esel, vhide=b'', vco=b''):
        self.calls.append(dict(call="edit", name=name, bits=bits, vsel=b64(vsel), tpoly=b64(tpoly),
                               psel=b64(psel), ends=b64(ends), esel=b64(esel), vhide=b64(vhide)))

    def sync_local(self, name, values):
        pass

    def sync_end(self):
        pass

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


# What the app has on its path: the context helpers the menu rows import, and
# the siblings `sync()` reports through.
context = load("_blenderkit_context")
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
sync = load("_blenderkit_sync")


def run(block, subject=None):
    """Runs what the Swift sends; the error's text, or None."""
    source = blocks[block].replace("@SUBJECT@", subject or "")
    try:
        exec(compile(source, "<" + block + ">", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return str(error).strip()
    return None


def namespace(block):
    """Runs what the Swift sends and returns what it left behind, with what
    it printed: `_bk_adjustable` is how `perform` learns whether the redo
    panel can open."""
    import contextlib, io
    ns, out = {"bpy": bpy}, io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(blocks[block], "<" + block + ">", "exec"), ns)
    return ns, out.getvalue().strip()


def ran(label, block, subject=None):
    error = run(block, subject)
    check(label, error is None, error)


def refused(label, block, words):
    error = run(block)
    check(label, error is not None and words in error, error)


def truth():
    """What Blender has, object by object."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    out = {}
    for obj in bpy.context.scene.objects:
        drawn, hidden, disabled = sync.visibility(obj)
        entry = dict(type=obj.type, drawn=drawn, hidden=hidden, disabled=disabled,
                     selected=obj.select_get(), vertices=0, edges=0, triangles=0,
                     modifiers=[m.name for m in obj.modifiers],
                     dimensions=list(obj.dimensions))
        if drawn and obj.type in {"MESH", "CURVE", "FONT"}:
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            if mesh is not None:
                mesh.calc_loop_triangles()
                entry.update(vertices=len(mesh.vertices), edges=len(mesh.edges),
                             triangles=len(mesh.loop_triangles))
                evaluated.to_mesh_clear()
        out[obj.name] = entry
    return out


passes = []


def mirror(name, **extra):
    sync.sync()
    passes.append(dict(name=name, calls=list(bridge.calls), blender=truth(), **extra))


def fresh():
    bpy.ops.wm.read_homefile(use_empty=True)


def only(*objects):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    if objects:
        bpy.context.view_layer.objects.active = objects[0]


def cube(name, x):
    bpy.ops.mesh.primitive_cube_add(location=(x, 0, 0))
    bpy.context.object.name = name
    return bpy.context.object


print("Object ▸ Show/Hide, in object mode")
fresh()
a, b, c = cube("A", 0), cube("B", 3), cube("C", 6)
only(a)
check("(the operators poll False without a 3D View: this is what the override is for)",
      not bpy.ops.object.hide_view_set.poll() and not bpy.ops.object.hide_view_clear.poll())
ran("Hide Selected runs", "OBJECT_HIDESELECTED")
check("A is hidden in the view layer and deselected; B and C are not",
      a.hide_get() and not a.select_get() and not b.hide_get() and not c.hide_get(),
      [(o.name, o.hide_get(), o.select_get()) for o in (a, b, c)])
check("with the view layer's flag, not Disable in Viewports", not a.hide_viewport)
check("A stays the active object, as Blender leaves it",
      bpy.context.view_layer.objects.active == a)
mirror("hide selected")
ran("Show Hidden Objects runs", "OBJECT_REVEAL")
check("A is back and selected, as Blender's Show Hidden selects what it shows",
      not a.hide_get() and a.select_get())
only()
refused("Hide Selected with nothing selected says so", "OBJECT_HIDESELECTED", "select an object")
only(b)
ran("Hide Unselected runs", "OBJECT_HIDEUNSELECTED")
check("A and C are hidden, B is not and is still selected",
      a.hide_get() and c.hide_get() and not b.hide_get() and b.select_get())
mirror("hide unselected")
ran("Show Hidden Objects runs again", "OBJECT_REVEAL")
only(a, b, c)
refused("Hide Unselected with everything selected says so", "OBJECT_HIDEUNSELECTED", "every object")
refused("Show Hidden Objects with nothing hidden says so", "OBJECT_REVEAL", "nothing is hidden")

print("\nThe Outliner's eye, and Show in Viewports")
only(a)
ran("the eye hides A", "EYE_HIDE_A")
check("with the flag H sets", a.hide_get() and not a.hide_viewport)
ran("and shows it again", "EYE_SHOW_A")
check("which brings it back", not a.hide_get() and a.visible_get())
ran("Show in Viewports off for C", "DISABLE_C")
check("C is disabled, and its eye is open", c.hide_viewport and not c.hide_get() and not c.visible_get())
mirror("disabled")
refused("Show Hidden Objects does not bring a disabled object back, and says where it comes back from",
        "OBJECT_REVEAL", "Outliner")
check("(C is still off)", c.hide_viewport)
ran("Show in Viewports on for C", "ENABLE_C")
check("C is drawn again", c.visible_get())

print("\nH, Shift+H and Show in Viewports, pass after pass, as the device mirrors them")
fresh()
a, b, c = cube("A", 0), cube("B", 3), cube("C", 6)
a.modifiers.new("Subdivision", 'SUBSURF').levels = 1
only(a)
mirror("chain drawn")
ran("H hides A", "OBJECT_HIDESELECTED")
evaluated = a.evaluated_get(bpy.context.evaluated_depsgraph_get())
count = len(evaluated.to_mesh().vertices)
evaluated.to_mesh_clear()
check("(Blender still evaluates A while it is hidden: 26 vertices under its Subdivision)",
      evaluated.is_evaluated and count == 26, count)
mirror("chain A hidden")
ran("Alt+H shows it", "OBJECT_REVEAL")
mirror("chain A shown")
only(b)
ran("Shift+H hides the other two", "OBJECT_HIDEUNSELECTED")
mirror("chain others hidden")
ran("Alt+H shows them", "OBJECT_REVEAL")
ran("Show in Viewports off for C", "DISABLE_C")
mirror("chain C disabled")
ran("and on", "ENABLE_C")
mirror("chain C enabled")

print("\nThe undo steps, named as Blender names them")
names = dict(line.split("\t", 1) for line in blocks["UNDO_NAMES"].splitlines())
rna = {
    "Hide Objects": bpy.ops.object.hide_view_set, "Show Hidden Objects": bpy.ops.object.hide_view_clear,
    "Hide Selected": bpy.ops.mesh.hide, "Reveal Hidden": bpy.ops.mesh.reveal,
    "Separate": bpy.ops.mesh.separate,
}
for label, op in rna.items():
    check("%r is %s's name" % (label, op.idname_py()), op.get_rna_type().name == label,
          op.get_rna_type().name)
check("and each is the step the Swift pushes", all(label == step for label, step in names.items()), names)

print("\nMesh ▸ Show/Hide, while editing")
fresh()
bpy.ops.mesh.primitive_grid_add(x_subdivisions=4, y_subdivisions=4, size=2)
grid = bpy.context.object
grid.name = "Grid"
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_mode(type='FACE')
bpy.ops.mesh.select_all(action='DESELECT')
refused("Hide Selected with nothing selected says so", "MESH_HIDESELECTED", "select what to hide")
bm = bmesh.from_edit_mesh(grid.data)
bm.faces.ensure_lookup_table()
bm.faces[0].select_set(True)
bm.faces[5].select_set(True)
bmesh.update_edit_mesh(grid.data)
ran("Hide Selected runs", "MESH_HIDESELECTED")
check("(still in edit mode)", grid.mode == 'EDIT')
grid.update_from_editmode()
hidden_faces = [p.index for p in grid.data.polygons if p.hide]
hidden_verts = [v.index for v in grid.data.vertices if v.hide]
check("the two faces are hidden, and only they", hidden_faces == [0, 5], hidden_faces)
check("(the corner vertex only face 0 used is hidden with it)", len(hidden_verts) == 1, hidden_verts)
mirror("mesh hide", shownTriangles=2 * (len(grid.data.polygons) - len(hidden_faces)),
       hiddenVertices=hidden_verts)
bpy.ops.mesh.select_all(action='SELECT')
refused("Hide Unselected with everything selected says so", "MESH_HIDEUNSELECTED", "every element")
ran("Reveal Hidden runs", "MESH_REVEAL")
grid.update_from_editmode()
check("every face is back", not any(p.hide for p in grid.data.polygons))
mirror("mesh reveal", shownTriangles=2 * len(grid.data.polygons), hiddenVertices=[])
bpy.ops.mesh.select_all(action='SELECT')
ran("Hide Selected with everything selected runs", "MESH_HIDESELECTED")
mirror("mesh hide all", shownTriangles=0, hiddenVertices=list(range(len(grid.data.vertices))))
bpy.ops.mesh.reveal()
bpy.ops.object.mode_set(mode='OBJECT')

print("\nA wire in edit mode, every vertex of it hidden")
fresh()
ran("the app's Add ▸ Circle runs", "ADD_MESH_CIRCLE")
wire = bpy.context.object
check("a mesh of 32 vertices and 32 edges and no face",
      (wire.name, len(wire.data.vertices), len(wire.data.edges), len(wire.data.polygons)) == ("Circle", 32, 32, 0),
      (wire.name, len(wire.data.vertices), len(wire.data.edges), len(wire.data.polygons)))
bpy.ops.object.mode_set(mode='EDIT')
mirror("wire editing")
bpy.ops.mesh.select_all(action='SELECT')
ran("Hide Selected with the whole wire selected runs", "MESH_HIDESELECTED")
wire.update_from_editmode()
check("every vertex and edge is hidden", all(v.hide for v in wire.data.vertices)
      and all(e.hide for e in wire.data.edges))
mirror("wire all hidden", shownTriangles=0, hiddenVertices=list(range(len(wire.data.vertices))))
bpy.ops.mesh.reveal()
bpy.ops.object.mode_set(mode='OBJECT')

print("\nMesh ▸ Separate")
fresh()
bpy.ops.mesh.primitive_cube_add()
box = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_mode(type='FACE')
bpy.ops.mesh.select_all(action='DESELECT')
check("with nothing selected, Selection raises Blender's own words",
      run("SEPARATE_SELECTED") == "Error: Nothing selected", run("SEPARATE_SELECTED"))
refused("By Loose Parts on a cube in one piece says why", "SEPARATE_LOOSE", "all one piece")
refused("By Material with no materials says why", "SEPARATE_MATERIAL", "same material")
bm = bmesh.from_edit_mesh(box.data)
bm.faces.ensure_lookup_table()
bm.faces[0].select_set(True)
bmesh.update_edit_mesh(box.data)
ran("Selection runs", "SEPARATE_SELECTED")
part = bpy.data.objects.get("Cube.001")
check("the face is an object of its own, selected, in object mode",
      part is not None and len(part.data.vertices) == 4 and part.select_get() and part.mode == 'OBJECT',
      part and (len(part.data.vertices), part.select_get(), part.mode))
check("and the cube stays active, in edit mode",
      bpy.context.view_layer.objects.active == box and box.mode == 'EDIT')
mirror("separate")
bpy.ops.object.mode_set(mode='OBJECT')
fresh()
x, y = cube("X", 0), cube("Y", 3)
only(x, y)
bpy.ops.object.join()
joined = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
ran("By Loose Parts runs", "SEPARATE_LOOSE")
bpy.ops.object.mode_set(mode='OBJECT')
check("two cubes joined come apart into two objects", len(bpy.context.scene.objects) == 2,
      [o.name for o in bpy.context.scene.objects])
fresh()
bpy.ops.mesh.primitive_cube_add()
painted = bpy.context.object
for name in ("Red", "Blue"):
    painted.data.materials.append(bpy.data.materials.new(name))
for polygon in painted.data.polygons:
    polygon.material_index = polygon.index % 2
bpy.ops.object.mode_set(mode='EDIT')
ran("By Material runs", "SEPARATE_MATERIAL")
bpy.ops.object.mode_set(mode='OBJECT')
check("a cube of two materials comes apart into two objects of three faces",
      sorted(len(o.data.polygons) for o in bpy.context.scene.objects) == [3, 3],
      [len(o.data.polygons) for o in bpy.context.scene.objects])


def modifier_angle(obj):
    return sync.node_input(obj.modifiers["Smooth by Angle"], "Angle")


print("\nShade Auto Smooth")
fresh()
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
ran("it runs", "AUTO_SMOOTH")
m = sphere.modifiers.get("Smooth by Angle")
check("it adds one Geometry Nodes modifier, Smooth by Angle",
      [x.type for x in sphere.modifiers] == ["NODES"] and m is not None
      and m.node_group.name == "Smooth by Angle", [(x.name, x.type) for x in sphere.modifiers])
check("at Blender's 30 degrees, read through the mirror's helper",
      abs(modifier_angle(sphere) - math.radians(30)) < 1e-5, modifier_angle(sphere))
check("every face smooth", all(p.use_smooth for p in sphere.data.polygons))
mirror("auto smooth")
ran("the redo panel's re-run at 60 degrees runs", "AUTO_SMOOTH_RERUN", sphere.name)
check("which sets the angle on the one modifier rather than adding a second",
      len(sphere.modifiers) == 1 and abs(modifier_angle(sphere) - math.radians(60)) < 1e-5,
      (len(sphere.modifiers), math.degrees(modifier_angle(sphere))))
ran("and without the backup, as with Blender's undo, it runs too", "AUTO_SMOOTH_BY_UNDO")
bpy.ops.object.camera_add()
refused("on a camera it says it needs a mesh", "AUTO_SMOOTH", "works on meshes")
try:
    with context.needs_essentials("Shade Auto Smooth", "Try the other one."):
        raise RuntimeError('Error: No asset found at path ""\n')
    words = None
except RuntimeError as error:
    words = str(error)
check("without the Essentials library the failure is named, with what to do instead",
      words is not None and "Essentials asset library" in words and "Try the other one." in words, words)
try:
    with context.needs_essentials("Shade Auto Smooth", "Try the other one."):
        raise RuntimeError("something else")
    words = None
except RuntimeError as error:
    words = str(error)
check("any other failure passes through as it was", words == "something else", words)

print("\nShade Smooth by Angle")
fresh()
bpy.ops.mesh.primitive_cube_add()
box = bpy.context.object
ran("it runs", "SMOOTH_BY_ANGLE")
check("a cube's faces are smooth and its twelve edges, at 90 degrees, sharp",
      all(p.use_smooth for p in box.data.polygons) and sum(e.use_edge_sharp for e in box.data.edges) == 12,
      sum(e.use_edge_sharp for e in box.data.edges))
check("with no modifier", len(box.modifiers) == 0)

print("\nShade Smooth by Angle and Auto Smooth, with no mesh selected")
fresh()
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
sphere.select_set(False)          # what H leaves: the active mesh, deselected
check("(Blender's own answers: Smooth by Angle CANCELLED, Auto Smooth FINISHED having done nothing)",
      bpy.ops.object.shade_smooth_by_angle() == {'CANCELLED'}
      and bpy.ops.object.shade_auto_smooth() == {'FINISHED'} and len(sphere.modifiers) == 0)
refused("Smooth by Angle says no mesh is selected", "SMOOTH_BY_ANGLE", "none is selected")
refused("Auto Smooth says so before it runs", "AUTO_SMOOTH", "none is selected")
check("and neither changed the sphere", len(sphere.modifiers) == 0
      and not any(p.use_smooth for p in sphere.data.polygons)
      and not any(e.use_edge_sharp for e in sphere.data.edges))
bpy.ops.object.camera_add()
bpy.context.view_layer.objects.active = sphere
refused("Auto Smooth with only a camera selected says so too", "AUTO_SMOOTH", "none is selected")
only(sphere)
ran("with the sphere selected again, Auto Smooth runs", "AUTO_SMOOTH")

print("\nShade Smooth by Angle's redo panel, where a mesh backup keeps the history")
fresh()
bpy.ops.mesh.primitive_uv_sphere_add()
first = bpy.context.object
bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
second = bpy.context.object
only(first)
ns, _ = namespace("SMOOTH_BY_ANGLE")
check("one mesh selected: its backup is the whole of what changed, so the panel opens",
      ns.get("_bk_adjustable") is True)
only(first, second)
ns, _ = namespace("SMOOTH_BY_ANGLE")
check("two selected: only the active one could be put back, so the panel does not open",
      ns.get("_bk_adjustable") is False)
check("while the operator itself ran on both",
      all(all(p.use_smooth for p in o.data.polygons) for o in (first, second)))
ns, _ = namespace("SMOOTH_BY_ANGLE_BY_UNDO")
check("with Blender's undo keeping the history, which puts back both, it opens",
      ns.get("_bk_adjustable") is True)

print("\nWhether the Essentials library is there, as the 3D View asks before offering Auto Smooth")
_, said = namespace("ESSENTIALS_PROBE")
check("desktop Blender has it, so the row is offered", said == "True", said)

print("\nQuadriFlow Remesh")
fresh()
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
ran("it runs, from edit mode", "QUADRIFLOW")
check("and puts edit mode back", sphere.mode == 'EDIT')
bpy.ops.object.mode_set(mode='OBJECT')
faces = len(sphere.data.polygons)
check("every face is a quad", all(len(p.vertices) == 4 for p in sphere.data.polygons))
check("about the 1000 asked for", 800 <= faces <= 1300, faces)
ran("the redo panel's re-run at 2000 runs", "QUADRIFLOW_RERUN", sphere.name)
again = len(sphere.data.polygons)
check("about 2000 quads, remeshed from the sphere rather than from the last remesh",
      1600 <= again <= 2600 and all(len(p.vertices) == 4 for p in sphere.data.polygons), again)
bpy.ops.object.text_add()
refused("on a text object it says it needs a mesh", "QUADRIFLOW", "works on meshes")

print("\nQuadriFlow Remesh on what Blender will not remesh")
fresh()
ran("the app's Add ▸ Circle runs", "ADD_MESH_CIRCLE")
wire = bpy.context.object
check("(Blender's own answer to the wire: CANCELLED, raising nothing)",
      bpy.ops.object.quadriflow_remesh(mode='FACES', target_faces=1000) == {'CANCELLED'})
refused("on the wire it says why instead", "QUADRIFLOW", "manifold")
check("and the circle is as it was: 32 vertices, 32 edges, in object mode",
      (len(wire.data.vertices), len(wire.data.edges), wire.mode) == (32, 32, 'OBJECT'),
      (len(wire.data.vertices), len(wire.data.edges), wire.mode))
bpy.ops.mesh.primitive_cube_add(location=(3, 0, 0))
box = bpy.context.object
flip = bmesh.new()
flip.from_mesh(box.data)
flip.faces.ensure_lookup_table()
flip.faces[0].normal_flip()
flip.to_mesh(box.data)
flip.free()
bpy.ops.object.mode_set(mode='EDIT')
refused("on a cube with one face flipped, run from edit mode, it says why", "QUADRIFLOW", "manifold")
check("and puts edit mode back", box.mode == 'EDIT', box.mode)
bpy.ops.object.mode_set(mode='OBJECT')
check("with the cube's 6 faces untouched", len(box.data.polygons) == 6, len(box.data.polygons))
bpy.ops.mesh.primitive_grid_add(location=(6, 0, 0))
ran("an open grid, whose boundary Blender accepts, is remeshed", "QUADRIFLOW")

print("\nAdd ▸ Curve and Text")
fresh()
bpy.ops.mesh.primitive_plane_add(size=6)
plane = bpy.context.object
ran("Add Text runs", "ADD_TEXT")
text = bpy.context.object
check("a FONT called Text at the 3D cursor", text.type == 'FONT' and text.name == "Text"
      and tuple(round(c, 4) for c in text.location) == (1, 2, 3), (text.type, text.name, tuple(text.location)))
width = text.dimensions.x
ran("its re-run at radius 2 runs", "ADD_TEXT_RERUN", "Text")
text = bpy.data.objects.get("Text")
check("the one text is replaced, twice the size, with no orphaned data left",
      text is not None and len([o for o in bpy.data.objects if o.type == 'FONT']) == 1
      and abs(text.dimensions.x - 2 * width) < 1e-3 and not [d for d in bpy.data.curves if d.users == 0],
      (text and text.dimensions.x, width, [d.name for d in bpy.data.curves if d.users == 0]))
ran("Add Bézier runs", "ADD_BEZIER")
curve = bpy.context.object
check("a CURVE called BézierCurve", curve.type == 'CURVE' and curve.name == "BézierCurve", curve.name)
ran("Add Circle runs", "ADD_CIRCLE")
circle = bpy.context.object
check("a CURVE called BézierCircle", circle.type == 'CURVE' and circle.name == "BézierCircle", circle.name)
size = circle.dimensions.x
ran("its re-run at radius 0.5 runs", "ADD_CIRCLE_RERUN", "BézierCircle")
circle = bpy.data.objects.get("BézierCircle")
check("half the size, and no orphaned curve", circle is not None and abs(circle.dimensions.x - size / 2) < 1e-3
      and not [d for d in bpy.data.curves if d.users == 0], circle and circle.dimensions.x)
mirror("adds")

json.dump(passes, open(RECORDS, "w"))
print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
