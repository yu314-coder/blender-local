"""The UV Editor's Python half, run by the Blender it runs on.

scripts/run-uv-blender-check.sh starts desktop Blender with
`-b --factory-startup`. Every row of the UV menu is run as the Swift sends it
(`Bpy.uv`), through the app's own `_blenderkit_uv`, from object mode and from
Edit Mode. Then the app's own `_blenderkit_sync.sync()` pushes scenes with UV
maps and seams against a `_blenderkit` that records every call, for
tests/uv/blender/main.swift to replay through the Swift the device runs.
"""
import bpy, bmesh, sys, types, json, base64, pathlib, importlib.util
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


rows = []
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        name, _, label = head[4:].strip().partition("|")
        rows.append((name, label, body))


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
                               triangles=b64(triangles)))

    def sync_uvs(self, name, map_name, loops, uvs, seams):
        self.calls.append(dict(call="uvs", name=name, map=map_name, loops=b64(loops),
                               uvs=b64(uvs), seams=b64(seams)))

    def sync_uv_layout(self, name, map_name, positions, triangles, loops, uvs, seams):
        self.calls.append(dict(call="layout", name=name, map=map_name, positions=b64(positions),
                               triangles=b64(triangles), loops=b64(loops), uvs=b64(uvs),
                               seams=b64(seams)))

    def sync_edges(self, name, edges):
        pass

    def sync_modifiers(self, name, record):
        pass

    def sync_display(self, name, type, data_name, record):
        pass

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


for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
uvmenu = load("_blenderkit_uv")
sync = load("_blenderkit_sync")


def uvs_of(obj):
    me = obj.data
    values = array('f', [0.0]) * (2 * len(me.loops))
    me.uv_layers.active.uv.foreach_get('vector', values)
    return values


def seams_of(obj):
    flags = array('b', [0]) * len(obj.data.edges)
    obj.data.edges.foreach_get('use_seam', flags)
    return sum(flags)


def stored_selection(obj):
    return [list(f) for f in uvmenu._selection(obj.data)]


def loops_of_faces(obj, selected):
    """The loops of the faces whose stored `select` is `selected`."""
    out = []
    for poly in obj.data.polygons:
        if bool(poly.select) == selected:
            out.extend(range(poly.loop_start, poly.loop_start + poly.loop_total))
    return out


def moved(before, after, loops):
    return sum(1 for l in loops
               if abs(before[2 * l] - after[2 * l]) > 1e-6 or abs(before[2 * l + 1] - after[2 * l + 1]) > 1e-6)


def sphere(partial=True, seams=False):
    """A UV sphere, smart-projected and then squeezed into a corner so that
    every row has something to change, with every third face selected.

    `seams` marks Smart UV Project's island borders as seams, which is what
    an unwrap opens a closed surface along. Without them Blender solves no
    island (`Unwrap failed to solve 1 of 1`), and this check once counted the
    failed island's repack into the square as an unwrap."""
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_uv_sphere_add()
    obj = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project()
    if seams:
        bpy.ops.uv.seams_from_islands()
    bpy.ops.object.mode_set(mode='OBJECT')
    values = uvs_of(obj)
    obj.data.uv_layers.active.uv.foreach_set('vector', array('f', [v * 0.4 + 0.05 for v in values]))
    if partial:
        me = obj.data
        for v in me.vertices:
            v.select = False
        for e in me.edges:
            e.select = False
        for p in me.polygons:
            p.select = p.index % 3 == 0
            if p.select:
                for vi in p.vertices:
                    me.vertices[vi].select = True
        for e in me.edges:
            e.select = me.vertices[e.vertices[0]].select and me.vertices[e.vertices[1]].select
    return obj


def run(body):
    exec(compile(body, "<uv menu>", "exec"), {"bpy": bpy})


def said(body):
    """Runs a row, and returns (error or None, what it wrote to stdout) —
    where Blender's operator warnings go when Python calls an operator."""
    import io, contextlib
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            run(body)
        return None, out.getvalue()
    except Exception as e:
        return str(e).strip().splitlines()[-1], out.getvalue()


def unwrap_row(name):
    return name.startswith("unwrap")


print("Every row of the UV menu, from object mode: the whole mesh, the selection put back")
for name, label, body in rows:
    obj = sphere(seams=unwrap_row(name))
    before_uv, before_sel = uvs_of(obj), stored_selection(obj)
    unselected = loops_of_faces(obj, False)
    error, output = said(body)
    if unwrap_row(name):
        check(f"{label}: Blender solved every island (no 'Unwrap failed' warning)",
              "Unwrap failed" not in output, output.strip())
    after_uv = uvs_of(obj)
    if name == "seamsFromIslands":
        effect, what = seams_of(obj), "seams marked"
    else:
        effect, what = moved(before_uv, after_uv, unselected), "UVs of unselected faces moved"
    check(f"{label}: runs, back in object mode, {what}: {effect}",
          error is None and obj.mode == 'OBJECT' and effect > 0, error or obj.mode)
    check(f"{label}: and Edit Mode's stored selection is as it was",
          stored_selection(obj) == before_sel)

print("\nFrom Edit Mode: the selected faces, as in Blender")
for name, label, body in rows:
    obj = sphere(partial=False, seams=unwrap_row(name))
    before_uv = uvs_of(obj)
    # Selected in Edit Mode, in face select mode: a face stored as selected in
    # object mode brings its vertices, and entering Edit Mode would select
    # every face those vertices close.
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = (False, False, True)
    bm = bmesh.from_edit_mesh(obj.data)
    for f in bm.faces:
        f.select_set(False)
    # Follow Active Quads walks from the active quad through selected quads
    # joined to it, so its selection is a band of them around the equator; a
    # scatter of lone faces would leave it (correctly) nothing to follow.
    band = name == "followActiveQuads"
    for f in bm.faces:
        if (abs(f.calc_center_median().z) < 0.2 and len(f.verts) == 4) if band else f.index % 3 == 0:
            f.select_set(True)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)
    chosen = {f.index for f in bm.faces if f.select}
    selected = [l for p in obj.data.polygons if p.index in chosen
                for l in range(p.loop_start, p.loop_start + p.loop_total)]
    unselected = [l for p in obj.data.polygons if p.index not in chosen
                  for l in range(p.loop_start, p.loop_start + p.loop_total)]
    try:
        run(body)
        error = None
    except Exception as e:
        error = str(e).strip().splitlines()[-1]
    still_editing = obj.mode == 'EDIT'
    bpy.ops.object.mode_set(mode='OBJECT')
    after_uv = uvs_of(obj)
    if name == "seamsFromIslands":
        check(f"{label}: runs in Edit Mode and marks seams", error is None and still_editing
              and seams_of(obj) > 0, error)
        continue
    check(f"{label}: runs, still in Edit Mode, moves {moved(before_uv, after_uv, selected)} selected "
          f"corners and none of the {len(unselected)} others",
          error is None and still_editing and moved(before_uv, after_uv, selected) > 0
          and moved(before_uv, after_uv, unselected) == 0,
          error or moved(before_uv, after_uv, unselected))

print("\nAn unwrap that solves no island is refused, and the UVs stay as they were")
# Round 2's review: on the default cube and a UV sphere with no seams all three
# methods answer FINISHED with "Unwrap failed to solve 1 of 1 island(s)", and
# leave the old map repacked (a sphere's scaled by 0.9998).
for shape in ("cube", "sphere"):
    for start in ("OBJECT", "EDIT"):
        for name, label, body in rows:
            if not unwrap_row(name):
                continue
            bpy.ops.wm.read_homefile(use_empty=True)
            if shape == "cube":
                bpy.ops.mesh.primitive_cube_add()
            else:
                bpy.ops.mesh.primitive_uv_sphere_add()
            obj = bpy.context.object
            if start == "EDIT":
                bpy.ops.object.mode_set(mode='EDIT')
                bpy.ops.mesh.select_all(action='SELECT')
            bpy.ops.object.mode_set(mode='OBJECT')
            before_uv = uvs_of(obj)
            bpy.ops.object.mode_set(mode=start)
            error, output = said(body)
            mode_after = obj.mode
            bpy.ops.object.mode_set(mode='OBJECT')
            unchanged = moved(before_uv, uvs_of(obj), range(len(obj.data.loops))) == 0
            check(f"{label} on a seamless {shape} from {start}: refused in words, UVs untouched, "
                  f"back in {start}",
                  error is not None and "could not unwrap" in error and unchanged and mode_after == start,
                  (error, unchanged, mode_after))
            check(f"  and Blender's own warning still reaches the console",
                  "Unwrap failed to solve" in output, output.strip())
# A mesh with no map: the refused unwrap made one (measured), which "left as
# they were" has to take away again; and the rows that work on a map say so.
for start in ("OBJECT", "EDIT"):
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add()
    obj = bpy.context.object
    obj.data.uv_layers.remove(obj.data.uv_layers[0])
    if start == "EDIT":
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
    error, _ = said(next(b for n, _, b in rows if n == "unwrapConformal"))
    bpy.ops.object.mode_set(mode='OBJECT')
    check(f"Unwrap on a mesh with no map from {start}: refused, and no map left behind",
          error is not None and "could not unwrap" in error and len(obj.data.uv_layers) == 0,
          (error, len(obj.data.uv_layers)))
    for name in ("packIslands", "averageIslandsScale", "seamsFromIslands", "followActiveQuads"):
        if start == "EDIT":
            bpy.ops.object.mode_set(mode='EDIT')
        error, _ = said(next(b for n, _, b in rows if n == name))
        bpy.ops.object.mode_set(mode='OBJECT')
        check(f"  {name} from {start} says there is no UV map, not that the context is incorrect",
              error is not None and "no UV map" in error, error)

# What the refusal stands in for: the bare operator on the same cube.
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add()
obj = bpy.context.object
before_uv = uvs_of(obj)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
import io, contextlib
raw = io.StringIO()
with contextlib.redirect_stdout(raw):
    result = bpy.ops.uv.unwrap(method='CONFORMAL')
bpy.ops.object.mode_set(mode='OBJECT')
check("the bare operator on that cube answers FINISHED with only a warning (negative control)",
      result == {'FINISHED'} and "Unwrap failed to solve 1 of 1" in raw.getvalue(), (result, raw.getvalue()))

print("\nWhat is refused in words, where Blender does nothing")
obj = sphere(partial=False)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='DESELECT')
for name, label, body in rows:
    try:
        run(body)
        error = None
    except RuntimeError as e:
        error = str(e)
    check(f"{label}: nothing selected in Edit Mode says so",
          error is not None and "no faces are selected" in error, error)
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.camera_add()
try:
    run(rows[0][2])
    error = None
except RuntimeError as e:
    error = str(e)
check("a camera is not unwrapped", error is not None and "not a mesh" in error, error)

print("\nFollow Active Quads with no face clicked")
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_grid_add(x_subdivisions=4, y_subdivisions=4)
obj = bpy.context.object
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
check("Blender has no active face after a Select All",
      bmesh.from_edit_mesh(obj.data).faces.active is None)
try:
    bpy.ops.uv.follow_active_quads()
    raw = "FINISHED"
except RuntimeError as e:
    raw = str(e).strip().splitlines()[-1]
check("so the bare operator refuses", "No active face" in raw, raw)
body = next(b for n, _, b in rows if n == "followActiveQuads")
try:
    run(body)
    error = None
except Exception as e:
    error = str(e)
check("the menu's row runs, following the lowest-numbered selected quad",
      error is None and bmesh.from_edit_mesh(obj.data).faces.active.index == 0, error)
bpy.ops.object.mode_set(mode='OBJECT')


# --------------------------------------------------------------------------
# The mirror

def corners_of(me, editing):
    """(map name, the UV of every drawn triangle corner, polygon sides, seam
    sides) of one mesh."""
    me.calc_loop_triangles()
    hidden = [p.hide and editing for p in me.polygons]
    layer = me.uv_layers.active
    corners = array('f')
    for tri in me.loop_triangles:
        if hidden[tri.polygon_index] or layer is None:
            continue
        for loop in tri.loops:
            corners.extend(layer.uv[loop].vector)
    edges = sides = 0
    for poly in me.polygons:
        if not hidden[poly.index]:
            edges += poly.loop_total
            sides += sum(1 for l in range(poly.loop_start, poly.loop_start + poly.loop_total)
                         if me.edges[me.loops[l].edge_index].use_seam)
    return (layer.name if layer is not None else ""), corners, edges, sides


def editor_map(obj):
    """The map Blender's UV Editor draws: the object's own mesh, before its
    modifiers — in Edit Mode the edited BMesh, read through a scratch mesh."""
    if obj.mode == 'EDIT':
        scratch = bpy.data.meshes.new("_truth")
        bmesh.from_edit_mesh(obj.data).to_mesh(scratch)
        try:
            return corners_of(scratch, True)
        finally:
            bpy.data.meshes.remove(scratch)
    return corners_of(obj.data, False)


def truth():
    """What Blender holds, for each mesh the pass drew: the UV of every drawn
    triangle corner, the seams by vertex pair, and its polygon edge count —
    of the evaluated mesh, which the viewport draws and textures — and the
    same of the map Blender's UV Editor draws (`editor…`)."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    out = {}
    for obj in bpy.context.scene.objects:
        if obj.type != 'MESH':
            continue
        editing = obj.mode == 'EDIT'
        if editing:
            obj.update_from_editmode()
        editor = editor_map(obj)
        evaluated = obj.evaluated_get(depsgraph)
        me = evaluated.to_mesh()
        me.calc_loop_triangles()
        hidden = [p.hide and editing for p in me.polygons]
        layer = me.uv_layers.active
        corners = array('f')
        edges = 0
        for tri in me.loop_triangles:
            if hidden[tri.polygon_index]:
                continue
            for loop in tri.loops:
                if layer is not None:
                    corners.extend(layer.uv[loop].vector)
        sides = 0
        for poly in me.polygons:
            if not hidden[poly.index]:
                edges += poly.loop_total
                sides += sum(1 for l in range(poly.loop_start, poly.loop_start + poly.loop_total)
                             if me.edges[me.loops[l].edge_index].use_seam)
        seams = [list(e.vertices) for e in me.edges if e.use_seam and not (editing and e.hide)]
        out[obj.name] = dict(map=layer.name if layer is not None else "", corners=b64(corners),
                             seams=seams, polygonEdges=edges, seamSides=sides,
                             editorMap=editor[0], editorCorners=b64(editor[1]),
                             editorPolygonEdges=editor[2], editorSeamSides=editor[3])
        evaluated.to_mesh_clear()
    return out


passes = []


def mirror(label):
    sync.sync()
    passes.append(dict(label=label, calls=list(bridge.calls), blender=truth()))


def row(name):
    return next(b for n, _, b in rows if n == name)


print("\nThe mirror: a scene with maps, seams, a modifier and faces hidden in Edit Mode")
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_uv_sphere_add(location=(0, 0, 0))
bpy.context.object.name = "Sphere"
run(row("smartProject"))
bpy.ops.mesh.primitive_cube_add(location=(3, 0, 0))
cube = bpy.context.object
cube.name = "Cube"
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(cube.data)
for element in list(bm.verts) + list(bm.edges) + list(bm.faces):
    element.select = False
bm.edges.ensure_lookup_table()
bm.edges[0].select = True
bm.edges[5].select = True
bmesh.update_edit_mesh(cube.data)
bpy.context.tool_settings.mesh_select_mode = (False, True, False)
bpy.ops.mesh.mark_seam(clear=False)
bpy.ops.object.mode_set(mode='OBJECT')
cube.modifiers.new("Subdivision", 'SUBSURF').levels = 1
check("the cube has 2 seams, 4 through its Subdivision",
      seams_of(cube) == 2, seams_of(cube))
# A Mirror with Mirror U adds a flipped copy of every island to the evaluated
# map; Blender's UV Editor still draws the plane's own one island.
bpy.ops.mesh.primitive_plane_add(location=(-3, 0, 0))
plane = bpy.context.object
plane.name = "Mirrored"
plane.modifiers.new("Mirror", 'MIRROR').use_mirror_u = True
bare = bpy.data.meshes.new("Bare")
bare.from_pydata([(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)], [], [(0, 1, 2, 3)])
bpy.context.collection.objects.link(bpy.data.objects.new("Bare", bare))
bpy.ops.mesh.primitive_grid_add(x_subdivisions=4, y_subdivisions=4, location=(0, 4, 0))
grid = bpy.context.object
grid.name = "Grid"
# In Edit Mode the map before the modifiers is the edited BMesh's, with the
# hidden faces left out as they are from what is drawn.
grid.modifiers.new("Subdivision", 'SUBSURF').levels = 1
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(grid.data)
bm.faces.ensure_lookup_table()
for f in bm.faces:
    f.select_set(False)
for i in (0, 1, 5):
    bm.faces[i].hide_set(True)
bmesh.update_edit_mesh(grid.data)
mirror("first pass: a smart-projected sphere, a seamed cube under a Subdivision, a mesh with no "
       "map, a grid with faces hidden in Edit Mode")
mirror("nothing changed: the same scene again")
bpy.ops.object.mode_set(mode='OBJECT')
bpy.context.view_layer.objects.active = bpy.data.objects["Sphere"]
run(row("unwrapConformal"))
# Removed the way the UV Maps panel's minus button does it. Measured in 5.2.1:
# `mesh.uv_layers.remove()` from a script leaves an already-evaluated
# depsgraph stale — the evaluated mesh kept its UVMap until `mesh.update()` —
# and the mirror shows the evaluated mesh, as Blender's renderers use it.
bpy.context.view_layer.objects.active = cube
bpy.ops.mesh.uv_texture_remove()
check("the cube's only UV map is gone", len(cube.data.uv_layers) == 0)
mirror("after Unwrap Conformal on the sphere and the cube's map removed")

json.dump(passes, open(RECORDS, "w"))
print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
