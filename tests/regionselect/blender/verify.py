"""Box, Circle and Lasso select, and the Select menu, against Blender 5.2.1.

scripts/run-regionselect-blender-check.sh runs this twice around the Swift:

  measure  Blender's own view3d.select_box / select_circle / select_lasso, with
           the 3D View's X-Ray on, over a grid, a cube and a UV sphere, in
           vertex, edge and face mode: what each selected, the view it
           selected in and the mesh, written to a JSON file for the Swift to
           run RegionSelect over the same regions and compare.

  apply    the Python the app sends: the selection the Swift pass made, pushed
           as Bpy.pushEditSelection pushes it, and read back from Blender; and
           every row of the Select menu (SelectMenu.swift), on a 7 x 7 grid and
           on a small scene of objects, with the counts round 2's review
           measured.

X-Ray is on for the measuring because without it these operators select
nothing without a window — they read the GPU selection buffer (measured: 0 of a
10 x 10 grid) — which is exactly why the app's pass is its own. The context is
the one the app gives Blender: an undo stack (ed.undo_push under
temp_override(window, screen)), gpu.init() before any view update (without it
rv3d.update() crashes in GPU_matrix_ortho_set, measured while writing this),
and temp_override(window, area, region) onto the startup screen's 3D View.

Nothing here opens a browser, a file browser or another program, and the
Blender it runs in is given a HOME and BLENDER_USER_RESOURCES of its own by the
shell script, so the Mac's own Blender settings are never touched.
"""
import bpy, bmesh, gpu, json, sys, math
from mathutils import Vector, Quaternion, Euler

argv = sys.argv[sys.argv.index("--") + 1:]
PHASE, PATH = argv[0], argv[1]
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    sys.stdout.flush()
    if not ok:
        fail += 1


def view3d():
    for w in bpy.context.window_manager.windows:
        for a in w.screen.areas:
            if a.type == 'VIEW_3D':
                for r in a.regions:
                    if r.type == 'WINDOW':
                        return w, a, r
    raise RuntimeError("no 3D View in the startup screen")


WINDOW, AREA, REGION = view3d()
with bpy.context.temp_override(window=WINDOW, screen=WINDOW.screen):
    bpy.ops.ed.undo_push(message="region select check")
gpu.init()
RV3D = AREA.spaces.active.region_3d


def clear_scene():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)


def make(kind):
    clear_scene()
    if kind == 'grid':
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=6, y_subdivisions=6, size=6)
    elif kind == 'cube':
        bpy.ops.mesh.primitive_cube_add(size=2)
    elif kind == 'sphere':
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=1.5)
    return bpy.context.object


# The views: the grid from the top in orthographic, the others from above and
# to the side in perspective, as the 3D View opens.
VIEWS = {
    'grid': dict(rotation=Quaternion((1, 0, 0, 0)), distance=8, perspective='ORTHO'),
    'cube': dict(rotation=Euler((math.radians(62), 0, math.radians(38)), 'XYZ').to_quaternion(),
                 distance=8, perspective='PERSP'),
    'sphere': dict(rotation=Euler((math.radians(70), 0, math.radians(-25)), 'XYZ').to_quaternion(),
                   distance=7, perspective='PERSP'),
}


def aim(kind):
    v = VIEWS[kind]
    with bpy.context.temp_override(window=WINDOW, area=AREA, region=REGION):
        RV3D.view_rotation = v['rotation']
        RV3D.view_location = Vector((0, 0, 0))
        RV3D.view_distance = v['distance']
        RV3D.view_perspective = v['perspective']
        RV3D.update()


def regions():
    """Region-relative gestures, in Blender's region pixels (y up)."""
    W, H = REGION.width, REGION.height
    cx, cy = W // 2, H // 2
    return [
        ('box', dict(xmin=cx - 90, xmax=cx + 70, ymin=cy - 60, ymax=cy + 100)),
        ('box', dict(xmin=cx + 5, xmax=cx + 25, ymin=cy - 200, ymax=cy + 200)),   # a thin slice
        ('circle', dict(x=cx + 10, y=cy - 15, radius=70)),
        ('circle', dict(x=cx - 60, y=cy + 40, radius=23)),
        ('lasso', dict(path=[(cx - 150, cy - 120), (cx + 130, cy - 90), (cx + 20, cy + 140)])),
        # A C: its notch is outside.
        ('lasso', dict(path=[(cx - 160, cy - 160), (cx + 160, cy - 160), (cx + 160, cy - 60),
                             (cx - 40, cy - 60), (cx - 40, cy + 60), (cx + 160, cy + 60),
                             (cx + 160, cy + 160), (cx - 160, cy + 160)])),
    ]


def selected(obj, mode):
    bm = bmesh.from_edit_mesh(obj.data)
    if mode == 'VERT':
        return sorted(v.index for v in bm.verts if v.select)
    if mode == 'EDGE':
        return sorted(e.index for e in bm.edges if e.select)
    return sorted(f.index for f in bm.faces if f.select)


def gesture(kind, params):
    with bpy.context.temp_override(window=WINDOW, area=AREA, region=REGION):
        if kind == 'box':
            return bpy.ops.view3d.select_box(mode='SET', wait_for_input=False, **params)
        if kind == 'circle':
            return bpy.ops.view3d.select_circle(mode='SET', wait_for_input=False, **params)
        path = [{"name": "", "loc": p, "time": 0.0} for p in params['path']]
        return bpy.ops.view3d.select_lasso(path=path, mode='SET')


def measure():
    AREA.spaces.active.shading.show_xray = True
    out = {'scenes': []}
    for kind in ('grid', 'cube', 'sphere'):
        obj = make(kind)
        aim(kind)
        me = obj.data
        me.calc_loop_triangles()
        scene = {
            'name': kind,
            'size': [REGION.width, REGION.height],
            # Row by row, as mathutils holds it.
            'matrix': [list(row) for row in RV3D.perspective_matrix],
            'vertices': [list(v.co) for v in me.vertices],
            'triangles': [list(t.vertices) for t in me.loop_triangles],
            'triangle_polygons': [t.polygon_index for t in me.loop_triangles],
            'edges': [list(e.vertices) for e in me.edges],
            'polygons': len(me.polygons),
            'tests': [],
        }
        bpy.ops.object.mode_set(mode='EDIT')
        for mode in ('VERT', 'EDGE', 'FACE'):
            bpy.ops.mesh.select_mode(type=mode)
            for region_kind, params in regions():
                bpy.ops.mesh.select_all(action='DESELECT')
                result = gesture(region_kind, params)
                scene['tests'].append({'mode': mode, 'kind': region_kind, 'params': params,
                                       'result': sorted(result), 'selected': selected(obj, mode)})
        bpy.ops.object.mode_set(mode='OBJECT')
        out['scenes'].append(scene)
        print(f"  measured {kind}: {len(scene['tests'])} gestures, "
              f"{sum(len(t['selected']) for t in scene['tests'])} elements selected by Blender")
    AREA.spaces.active.shading.show_xray = False
    with open(PATH, 'w') as f:
        json.dump(out, f)


# ---------------------------------------------------------------- apply

def blocks(path):
    out = {}
    for chunk in open(path).read().split("#--"):
        chunk = chunk.strip()
        if chunk:
            head, _, body = chunk.partition("\n")
            out[head.strip()] = body
    return out


def run(source):
    """What the app's bridge.run does with it: exec, bpy in scope. The error
    raised, or None."""
    try:
        exec(compile(source, "<app>", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return str(error).strip()
    return None


def counts(obj):
    bm = bmesh.from_edit_mesh(obj.data)
    return (sum(v.select for v in bm.verts), sum(e.select for e in bm.edges), sum(f.select for f in bm.faces))


def only(obj, indices):
    bpy.ops.mesh.select_all(action='DESELECT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    for i in indices:
        bm.verts[i].select = True
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)


def apply():
    calls = blocks(PATH)

    print("\nthe selection the Swift pass made, pushed as the app pushes it")
    pushes = [name for name in calls if name.startswith("PUSH ")]
    for name in pushes:
        _, kind, mode, index = name.split(" ")
        obj = make(kind)
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_mode(type=mode)
        bpy.ops.mesh.select_all(action='DESELECT')
        body, _, want = calls[name].rpartition("\n# expect ")
        error = run(body)
        # Edges by their ends: the order Blender numbers a new primitive's
        # edges in is not fixed — a UV sphere added with an undo stack in
        # place numbers them differently from one added without (measured
        # while writing this) — and the app names edges by their ends too.
        if mode == 'EDGE':
            bm = bmesh.from_edit_mesh(obj.data)
            got = sorted(sorted((e.verts[0].index, e.verts[1].index)) for e in bm.edges if e.select)
            want = sorted(sorted(p) for p in json.loads(want))
        else:
            got = selected(obj, mode)
            want = sorted(json.loads(want))
        check(f"{kind}, {mode.lower()} mode, gesture {index}: Blender holds the {len(want)} elements "
              "the pass picked", error is None and got == want, (error, got, want))
        bpy.ops.object.mode_set(mode='OBJECT')
    check(f"({len(pushes)} pushes run)", len(pushes) > 0)

    print("\nthe Select menu while editing, on a 7 x 7 grid (49 vertices)")
    obj = make('grid')
    check("the grid has 49 vertices", len(obj.data.vertices) == 49, len(obj.data.vertices))
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type='VERT')
    centre = min(range(49), key=lambda i: obj.data.vertices[i].co.length)
    corner = min(range(49), key=lambda i: (obj.data.vertices[i].co.x + obj.data.vertices[i].co.y))
    far = [i for i in range(49) if abs(obj.data.vertices[i].co.x - obj.data.vertices[corner].co.x) < 1e-4
           and abs(obj.data.vertices[i].co.y - obj.data.vertices[corner].co.y - 4) < 1e-4][0]

    def row(name, seed, expect, label):
        if seed == 'all':
            bpy.ops.mesh.select_all(action='SELECT')
        else:
            only(obj, seed)
        before = counts(obj)[0]
        error = run(calls[name])
        after = counts(obj)[0]
        ok = error is None and (expect(after) if callable(expect) else after == expect)
        check(f"{label}: {before} -> {after} vertices", ok, (error, after))
        return after

    row("MESH more", [centre], 9, "More, from the centre")
    only(obj, [centre])
    run(calls["MESH more"])
    row("MESH less", [v.index for v in bmesh.from_edit_mesh(obj.data).verts if v.select], 1,
        "Less, from the nine More made: back to the centre")
    row("MESH linked", [centre], 49, "Linked, from one vertex")
    row("MESH nonManifold", [centre], 25, "Non Manifold: the 24 on the border, and the one kept (Extend)")
    row("MESH shortestPath", [corner, far], 5, "Shortest Path between two four apart")
    row("MESH checkerDeselect", 'all', lambda n: n in (24, 25), "Checker Deselect, from everything")
    row("MESH mirror", [corner], 1, "Select Mirror moves the selection to the mirrored corner")
    mirrored = [v.index for v in bmesh.from_edit_mesh(obj.data).verts if v.select]
    check("  ... which is the corner across X",
          mirrored and abs(obj.data.vertices[mirrored[0]].co.x + obj.data.vertices[corner].co.x) < 1e-4
          and abs(obj.data.vertices[mirrored[0]].co.y - obj.data.vertices[corner].co.y) < 1e-4, mirrored)
    row("MESH random", [], lambda n: 10 < n < 40, "Select Random, half by default")
    row("MESH loose", [centre], 0, "Loose Geometry: a grid has none, and Extend is off")
    row("MESH interiorFaces", [centre], 1, "Interior Faces: a grid has none")
    row("MESH facesBySides", [centre], 49, "Faces by Sides, four (all of them)")
    # Each of the next three seeded where it does something: these rows used
    # to accept any count from a single seeded vertex, so they could only
    # fail on an exception. Counts measured in 5.2.1.
    row("MESH polesByCount", [centre], 0,
        "Poles by Count on a grid: every inner vertex has 4 edges, the border is non-manifold")
    row("MESH linkedFlat", [centre], 1, "Linked Flat Faces from a vertex: no face to grow")
    block = [i for i in range(49) if abs(obj.data.vertices[i].co.x) <= 1.001
             and abs(obj.data.vertices[i].co.y) <= 1.001]
    ring = [i for i in block if i != centre]
    check("the 3 x 3 block round the centre, and its ring of 8", len(block) == 9 and len(ring) == 8,
          (len(block), len(ring)))
    row("MESH boundaryOfSelected", block, 8, "Boundary of Selected, from the 3 x 3 block: its ring of 8")
    row("MESH loopInnerRegion", ring, 9, "Loop Inner-Region, from that ring: the 9 inside it")
    row("MESH sharpEdges", [centre], 1, "Sharp Edges: a flat grid has none to add")
    only(obj, [centre])
    error = run(calls["MESH shortestPath"])
    check("Shortest Path with one selected says why, instead of a silent CANCELLED",
          error is not None and "select two" in error, error)
    error = run(calls["MESH ungrouped"])
    check("Ungrouped Vertices with no vertex group passes Blender's own words through",
          error is not None and "vertex groups" in error.lower(), error)
    # What MeshItem.isEnabled greys the row for.
    bpy.ops.mesh.select_mode(type='EDGE')
    error = run(calls["MESH ungrouped"])
    check("and in edge mode Blender's poll wants vertex mode, where the menu greys the row",
          error is not None and "vertex selection mode" in error.lower(), error)
    bpy.ops.mesh.select_mode(type='VERT')
    only(obj, [])
    error = run(calls["MESH boundaryLoops"])
    check("Boundary Loops with nothing selected passes Blender's words through",
          error is not None and "boundary" in error.lower(), error)

    print("\nSelect Similar, each type in its own mode")
    for name in sorted(n for n in calls if n.startswith("SIMILAR ")):
        _, mode, ident = name.split(" ")
        bpy.ops.mesh.select_mode(type=mode)
        bpy.ops.mesh.select_all(action='DESELECT')
        bm = bmesh.from_edit_mesh(obj.data)
        seq = {'VERT': bm.verts, 'EDGE': bm.edges, 'FACE': bm.faces}[mode]
        seq.ensure_lookup_table()
        seq[len(seq) // 2].select_set(True)
        bmesh.update_edit_mesh(obj.data)
        error = run(calls[name])
        check(f"{mode.lower()} mode, {ident}: runs", error is None, error)
    bpy.ops.mesh.select_mode(type='VERT')
    check("every type of every mode was run", len([n for n in calls if n.startswith("SIMILAR ")]) == 22)

    print("\nthe menu's names are Blender's operator names")
    for name in sorted(n for n in calls if n.startswith("NAME ")):
        _, call = name.split(" ", 1)
        want = calls[name].strip()
        module, op = call.split(".")[2:4]
        got = getattr(getattr(bpy.ops, module), op).get_rna_type().name
        check(f"{call}: '{want}'", got == want, got)
    bpy.ops.object.mode_set(mode='OBJECT')

    print("\nPoles by Count where there are poles: a cube's corners have 3 edges each")
    obj = make('cube')
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type='VERT')
    bpy.ops.mesh.select_all(action='DESELECT')
    error = run(calls["MESH polesByCount"])
    check(f"all 8 corners selected ({counts(obj)[0]})", error is None and counts(obj)[0] == 8, (error, counts(obj)))
    bpy.ops.object.mode_set(mode='OBJECT')

    # BKObject.editRegionRefusal: a Box, Circle or Lasso in Edit Mode is
    # refused on a mesh the viewport draws through a modifier that rebuilds
    # it, and the words say to hide the modifier in the viewport. Both halves
    # of that, as the mirror sees them: the evaluated mesh it draws against
    # the base mesh its report names (`_report_edit_selection`'s `_shown`).
    print("\na Box, Circle or Lasso in Edit Mode under a modifier that rebuilds the mesh")
    for kind, label in (('SUBSURF', 'Subdivision Surface'), ('MIRROR', 'Mirror')):
        obj = make('cube')
        mod = obj.modifiers.new("M", kind)
        bpy.ops.object.mode_set(mode='EDIT')

        def drawn():
            obj.update_from_editmode()
            ev = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
            me = ev.to_mesh()
            me.calc_loop_triangles()
            n = (len(me.vertices), len(me.loop_triangles))
            ev.to_mesh_clear()
            return n

        base = (len(obj.data.vertices), 12)
        shown = drawn()
        check(f"{label}: the viewport draws {shown} (vertices, triangles) over Blender's {base}, so the "
              "report cannot name them and the gesture refuses", shown != base, shown)
        mod.show_viewport = False
        hidden = drawn()
        check(f"  hidden in the viewport, as the refusal says: {hidden}, which lines up", hidden == base, hidden)
        bpy.ops.object.mode_set(mode='OBJECT')

    print("\nthe Select menu in Object Mode")
    clear_scene()
    bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
    body = bpy.context.object
    body.name = "Body"
    bpy.ops.mesh.primitive_cube_add(location=(3, 0, 0), size=1)
    bpy.context.object.name = "Wheel.L"
    bpy.ops.mesh.primitive_cube_add(location=(-3, 0, 0), size=1)
    bpy.context.object.name = "Wheel.R"
    for n in ("Wheel.L", "Wheel.R"):
        bpy.data.objects[n].parent = body
    bpy.ops.object.light_add(type='POINT', location=(0, 3, 0))
    bpy.ops.object.camera_add(location=(0, -8, 2))
    bpy.context.scene.camera = bpy.context.object

    def pick(*names):
        for o in bpy.context.view_layer.objects:
            o.select_set(o.name in names)
        bpy.context.view_layer.objects.active = bpy.data.objects[names[0]] if names else None

    def sel():
        return sorted(o.name for o in bpy.context.view_layer.objects if o.select_get())

    def orow(name, seed, want, label):
        pick(*seed)
        error = run(calls[name])
        got = sel()
        check(f"{label}: {list(seed)} -> {got}", error is None and got == want, (error, got))

    orow("OBJECT more", ["Body"], ["Body", "Wheel.L", "Wheel.R"], "More adds the children")
    orow("OBJECT child", ["Body"], ["Wheel.L", "Wheel.R"], "Child")
    orow("OBJECT parent", ["Wheel.L"], ["Body"], "Parent")
    orow("OBJECT extendChild", ["Body"], ["Body", "Wheel.L", "Wheel.R"], "Extend Child")
    orow("OBJECT mirror", ["Wheel.L"], ["Wheel.R"], "Select Mirror swaps .L for .R")
    orow("OBJECT activeCamera", [], ["Camera"], "Select Active Camera")
    orow("TYPE MESH", [], ["Body", "Wheel.L", "Wheel.R"], "Select All by Type, Mesh")
    orow("TYPE LIGHT", ["Body"], ["Point"], "Select All by Type, Light")
    orow("PATTERN", [], ["Wheel.L", "Wheel.R"], "Select Pattern Wheel*")
    pick("Wheel.L")
    error = run(calls["LINKED MATERIAL"])
    check("Select Linked by Material with no material says so, and changes nothing (Blender "
          "deselected everything before cancelling)",
          error is not None and "material" in error and sel() == ["Wheel.L"]
          and bpy.context.view_layer.objects.active.name == "Wheel.L", (error, sel()))
    orow("LINKED OBDATA", ["Wheel.L"], ["Wheel.L"], "Select Linked by Object Data")
    pick("Body")
    bpy.context.view_layer.objects.active = None
    error = run(calls["LINKED OBDATA"])
    check("Select Linked with nothing active is refused before Blender deselects anything",
          error is not None and "active" in error and sel() == ["Body"], (error, sel()))
    error = run(calls["OBJECT child"])
    check("so is Child, whose poll fails without an active object",
          error is not None and "Tap one first" in error and sel() == ["Body"], (error, sel()))
    pick("Wheel.L")
    error = run(calls["OBJECT child"])
    check("Child with no child to go to says so, and changes nothing",
          error is not None and "child" in error and sel() == ["Wheel.L"], (error, sel()))
    pick("Body", "Wheel.L", "Wheel.R")
    error = run(calls["OBJECT less"])
    check("Less with nothing to take off says so, and changes nothing",
          error is not None and sel() == ["Body", "Wheel.L", "Wheel.R"], (error, sel()))
    pick()
    error = run(calls["OBJECT random"])
    first = sel()
    check(f"Select Random from nothing runs: {first}", error is None and first, (error, first))
    error = run(calls["OBJECT random"])
    check("again, with the same seed, it picks the same and is refused in words rather than "
          "recording a step that changed nothing", error is not None and "changed nothing" in error
          and sel() == first, (error, sel()))
    pick("Body")
    # Blender's own answer first: a Python operator that finishes whatever
    # matched.
    result = bpy.ops.object.select_pattern(pattern="Nothing*", case_sensitive=False, extend=True)
    check(f"select_pattern matching nothing returns {sorted(result)}", result == {'FINISHED'}, result)
    pick("Body")
    error = run(calls["PATTERN NONE"])
    check("so Select Pattern matching nothing is refused by the app, selection unchanged",
          error is not None and "matches" in error and sel() == ["Body"], (error, sel()))

    print("\nwhat a region sends for objects, by each of the five operations")
    for name in sorted(n for n in calls if n.startswith("REGION ")):
        _, action, seed, want = name.split(" ")
        pick(*[s for s in seed.split(",") if s])
        error = run(calls[name])
        got = ",".join(sel())
        check(f"{action} over Body and Point, from [{seed}] -> [{got}]", error is None and got == want,
              (error, got, want))


if PHASE == 'measure':
    measure()
else:
    apply()
print(f"\n{fail} FAILED" if fail else "\nALL PASS")
sys.exit(1 if fail else 0)
