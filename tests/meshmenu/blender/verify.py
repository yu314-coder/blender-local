"""The Mesh menu's round-4 rows held to Blender itself (desktop 5.2.1).

tests/meshmenu/blender/main.swift prints what the app sends: each row's first
press (`BpyBridge.performBody`), panel changes, Extrude to Cursor or Add's line
and Rip Vertices and Extend's, from a set of views. In a Blender with the app's
context — its undo stack (`_blenderkit_undo`), gpu.init(), its modules and
operator guards (`_blenderkit_context.install`) — this checks:

  * every row does exactly what Blender's own operator does on the same
    selection, called as Blender's menu row calls it: the same vertices,
    faces, selection and custom normals (the counts are printed);
  * every row refuses in words, changing nothing, where Blender would do
    nothing or fail with an enum error, and runs from Sculpt Mode;
  * Extrude to Cursor or Add (the app's port of the invoke) makes what
    Blender's own invoke makes with the pointer over the 3D cursor, and Rip
    Vertices and Extend what Blender's `rip_edge` invoke makes there. Neither
    invoke can run in a Blender with no window — there is no event — so the
    check runs them with a made event through `WM_operator_name_call`
    (ctypes, desktop only, inside an operator so nothing is registered and no
    redo panel is built); the negative controls flip the port's side test,
    its Rotate Source, and the ray's direction, and must disagree;
  * the reasons the menu gives hold: Rip and Poly Build change nothing under
    the borrowed 3D View, and Extrude to Cursor or Add's own operator answers
    PASS_THROUGH there.
"""
import bpy, bmesh, gpu, sys, os, json, ctypes, importlib.util, pathlib, types, math

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

from mathutils import Vector, Matrix
from bpy_extras import view3d_utils

sys.dont_write_bytecode = True
CALLS, WORK = sys.argv[-2], sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
fail = 0
passed = 0


def check(label, ok, detail=""):
    global fail, passed
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if ok:
        passed += 1
    else:
        fail += 1


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class _BK(types.ModuleType):
    """The app's C module, which a desktop Blender has not got."""
    def is_main_thread(self):
        return True

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules['_blenderkit'] = _BK('_blenderkit')
context = load("_blenderkit_context")
context.install(bpy)
undo = load("_blenderkit_undo")
for module in ("_blenderkit_multires", "_blenderkit_loopcut", "_blenderkit_knife"):
    load(module)
mm = load("_blenderkit_meshmenu")
gpu.init()
undo.push(os.path.join(WORK, "history"), "start")

blocks = {}
for b in open(CALLS).read().split("#--"):
    b = b.strip()
    if b:
        head, body = b.split("\n", 1)
        blocks[head[4:]] = body


# --------------------------------------------------------------------------
# Fixtures: one object, its mesh rebuilt for each case.

def obj():
    o = bpy.data.objects.get('Mesh')
    if o is None:
        o = bpy.data.objects.new('Mesh', bpy.data.meshes.new('Mesh'))
        bpy.context.collection.objects.link(o)
    for other in bpy.context.view_layer.objects:
        if other != o:
            other.select_set(False)
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    return o


def _canonical(bm, me):
    """`bm` into `me` with its faces in an order of their own: sorted by
    their vertices, the vertices as BMesh made them. Measured in desktop
    5.2.1, `bmesh.ops.create_uvsphere` gives the same vertices and faces in a
    different face order from one call to the next once other meshes have
    come and gone (11 orders in 40 calls with BMeshes made and freed between;
    one in 30 with nothing between), and the face order moves the corner normals
    an index-by-index read compares (26 of 60 identical builds differed,
    round 4's review), which face a tie picks (`edit`'s 'FACE0' on a grid),
    and what averaging operators sum first: Average ▸ Custom Normal on the
    sphere gave 4 results in 40 calls as `to_mesh` left it and 1 in 40 built
    this way. `from_pydata` makes the edges from the faces in their order."""
    bm.verts.index_update()
    verts = [tuple(v.co) for v in bm.verts]
    faces = sorted((tuple(v.index for v in f.verts) for f in bm.faces), key=lambda f: sorted(f))
    loose = sorted(tuple(sorted(v.index for v in e.verts)) for e in bm.edges if not e.link_faces)
    me.from_pydata(verts, loose, faces)


def build(kind, xform=None):
    o = obj()
    if o.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    o.matrix_world = xform or Matrix.Identity(4)
    for md in list(o.modifiers):
        o.modifiers.remove(md)
    # A new mesh each time: `to_mesh` into the old one kept what the last case
    # left on it (a custom normal layer from Point to Target… made the next
    # case's Average (Custom Normal) start from other normals, one run in
    # three).
    old = o.data
    o.data = bpy.data.meshes.new('Mesh')
    if old.users == 0:
        bpy.data.meshes.remove(old)
    bm = bmesh.new()
    if kind == 'cube':
        bmesh.ops.create_cube(bm, size=2.0)
    elif kind == 'grid':
        bmesh.ops.create_grid(bm, x_segments=4, y_segments=4, size=1.0)
    elif kind == 'grid7':
        bmesh.ops.create_grid(bm, x_segments=7, y_segments=7, size=1.0)
    elif kind in ('sphere', 'smoothsphere'):
        bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=6, radius=1.0)
    elif kind == 'twocubes':
        # A small cube through the face of a big one, the small one apart.
        bmesh.ops.create_cube(bm, size=2.0)
        small = bmesh.ops.create_cube(bm, size=1.0)
        bmesh.ops.translate(bm, vec=(0.9, 0.3, 0.4), verts=small['verts'])
    elif kind == 'weldgrid':
        # A 4 x 4 grid with a loose edge across one quad, corner to corner.
        bmesh.ops.create_grid(bm, x_segments=4, y_segments=4, size=1.0)
        bm.verts.ensure_lookup_table()
        a = next(v for v in bm.verts if (v.co - Vector((-0.5, -0.5, 0))).length < 1e-4)
        b = next(v for v in bm.verts if (v.co - Vector((0.0, 0.0, 0))).length < 1e-4)
        bm.edges.new((a, b))
    elif kind == 'asym':
        # A grid symmetric in X but for one vertex, 0.02 off its mirror.
        bmesh.ops.create_grid(bm, x_segments=4, y_segments=4, size=1.0)
        v = next(v for v in bm.verts if (v.co - Vector((0.5, 0.5, 0))).length < 1e-4)
        v.co.x += 0.02
        v.co.z += 0.01
    elif kind == 'halfgrid':
        # The +X half of a grid under a Mirror modifier with Clipping: Extrude
        # to Cursor or Add leaves the edges on the mirror plane out.
        bmesh.ops.create_grid(bm, x_segments=4, y_segments=4, size=1.0)
        for v in [v for v in bm.verts if v.co.x < -1e-4]:
            bm.verts.remove(v)
    _canonical(bm, o.data)
    bm.free()
    if kind == 'smoothsphere':
        # Every face smooth, for Shading ▸ Flat Faces to have something to do.
        for p in o.data.polygons:
            p.use_smooth = True
    o.data.update()
    if kind == 'halfgrid':
        md = o.modifiers.new("Mirror", 'MIRROR')
        md.use_clip = True
    return o


def edit(select, mode='VERT'):
    """Edit Mode with `select` selected (in this select mode), Blender's
    selection order following the order the elements are named in."""
    o = obj()
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = (mode == 'VERT', mode == 'EDGE', mode == 'FACE')
    bm = bmesh.from_edit_mesh(o.data)
    for seq in (bm.verts, bm.edges, bm.faces):
        seq.ensure_lookup_table()
        for e in seq:
            e.select = False
    bm.select_history.clear()
    top = max(bm.faces, key=lambda f: (round(f.calc_center_median().z, 4), -f.index)) if bm.faces else None

    def pick(e):
        e.select_set(True)
        bm.select_history.add(e)
    if select == 'ALL':
        for seq in (bm.verts, bm.edges, bm.faces):
            for e in seq:
                e.select = True
    elif select == 'FACE0':
        pick(top)
    elif select == 'EDGE0':
        pick(top.edges[0])
    elif select == 'VERT0':
        pick(top.verts[0])
    elif select == 'VERT_DIAG':
        pick(top.verts[0]); pick(top.verts[2])
    elif select == 'VERT_PAIR':
        pick(top.verts[0]); pick(top.verts[1])
    elif select == 'VERT3':
        for v in top.verts[:3]:
            pick(v)
    elif select == 'VERT_FAR':
        # Two corners no edge joins: one of the top face's and the one
        # farthest from it.
        pick(top.verts[0])
        pick(max(bm.verts, key=lambda v: (v.co - top.verts[0].co).length))
    elif select == 'VERT3_UNORDERED':
        # Three corners selected with no selection order, as a box select
        # leaves them.
        for v in top.verts[:3]:
            v.select_set(True)
    elif select == 'LOOP':
        ys = sorted({round(v.co.y, 4) for v in bm.verts})
        mid = ys[len(ys) // 2]
        for e in bm.edges:
            if all(abs(v.co.y - mid) < 1e-4 for v in e.verts):
                e.select_set(True)
    elif select == 'INNER_EDGE':
        # An edge of a grid with a face on each side.
        e = next(e for e in bm.edges if len(e.link_faces) == 2)
        pick(e)
    elif select == 'SMALL':
        # The small cube of `twocubes`: every corner half a metre from its
        # middle (0.9, 0.3, 0.4) along each axis.
        for f in bm.faces:
            if all(abs(abs(v.co[i] - (0.9, 0.3, 0.4)[i]) - 0.5) < 1e-4 for v in f.verts for i in range(3)):
                f.select_set(True)
    elif select == 'LOOSE':
        e = next(e for e in bm.edges if not e.link_faces)
        pick(e)
    elif select == 'PLANE_EDGES':
        # Every edge of the half grid: the ones on x = 0 are excluded.
        for e in bm.edges:
            e.select_set(True)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(o.data)
    return o


def state(o=None):
    o = o or obj()
    bm = bmesh.from_edit_mesh(o.data) if o.mode == 'EDIT' else None
    if bm is None:
        bm = bmesh.new(); bm.from_mesh(o.data)
    for seq in (bm.verts, bm.edges, bm.faces):
        seq.index_update()
    co = [tuple(v.co) for v in bm.verts]
    faces = sorted(tuple(v.index for v in f.verts) for f in bm.faces)
    edges = sorted(tuple(sorted(v.index for v in e.verts)) for e in bm.edges)
    # Edges and faces by their vertices, not by their index: an operator may
    # number them in another order from one run to the next, as
    # `create_uvsphere` does (see `_canonical`), and the selection is the same.
    sel = ([v.select for v in bm.verts],
           sorted(tuple(sorted(v.index for v in e.verts)) for e in bm.edges if e.select),
           sorted(tuple(sorted(v.index for v in f.verts)) for f in bm.faces if f.select))
    # Custom normals, as Blender shades and exports them: each corner by its
    # face's vertices and its own vertex, for the same reason.
    o.update_from_editmode()
    me = o.data
    normals = sorted((tuple(sorted(p.vertices)), me.loops[i].vertex_index,
                      tuple(round(c, 4) for c in me.corner_normals[i].vector))
                     for p in me.polygons for i in p.loop_indices)
    return dict(co=co, faces=faces, edges=edges, sel=sel, normals=normals, mode=o.mode)


def counts(s):
    return "%d/%d/%d" % (len(s['co']), len(s['edges']), len(s['faces']))


def same(a, b, eps=1e-5, normals=True):
    if len(a['co']) != len(b['co']) or a['faces'] != b['faces'] or a['edges'] != b['edges']:
        return "topology: %s vs %s" % (counts(a), counts(b))
    worst = max([(Vector(p) - Vector(q)).length for p, q in zip(a['co'], b['co'])] or [0.0])
    if worst > eps:
        return "positions %.2e apart" % worst
    if a['sel'] != b['sel']:
        return "selection differs"
    # The normals rows' custom normals. Not for the pointer rows: Rip makes
    # a vertex on top of another, and the corner normals of the faces with a
    # zero-length edge came out differently from one run to the next in
    # Blender's own result (each case passed alone).
    if normals and (len(a['normals']) != len(b['normals']) or any(
            p[:2] != q[:2] or (Vector(p[2]) - Vector(q[2])).length > 2e-3
            for p, q in zip(a['normals'], b['normals']))):
        return "custom normals differ"
    return None


last_error = [None]


def perform(body):
    """What the bridge sends for a first press; the error's words, or None.
    The error itself is kept in `last_error` for `in_words`."""
    last_error[0] = None
    try:
        exec(compile(body, "<perform>", "exec"), {"bpy": bpy})
        return None
    except Exception as error:                     # noqa: BLE001 - the words are the point
        last_error[0] = error
        return str(error)


def in_words(error):
    """Whether a refusal is a sentence of the app's, as the banner should
    show: a RuntimeError the app raised, and not Python's own (an IndexError's
    "list index out of range") nor Blender's ("Error: …", an enum's TypeError)."""
    return error is None or (type(error) is RuntimeError and not str(error).startswith("Error:"))


# --------------------------------------------------------------------------
print("\nThe fixtures are the same from build to build")


def _churn(i):
    # Meshes made and freed between builds, as the cases below make them.
    junk = bmesh.new()
    bmesh.ops.create_cube(junk, size=0.5 + (i % 7) / 7)
    bmesh.ops.subdivide_edges(junk, edges=junk.edges[:], cuts=1 + i % 4)
    if i % 2:
        _kept.append(junk)
    else:
        junk.free()


def _read(me):
    return (tuple(tuple(p.vertices) for p in me.polygons), tuple(tuple(e.vertices) for e in me.edges),
            tuple(tuple(round(c, 5) for c in n.vector) for n in me.corner_normals))


_kept = []
for kind in ('sphere', 'cube', 'grid', 'twocubes', 'weldgrid', 'halfgrid'):
    seen_builds = set()
    for i in range(20):
        _churn(i)
        seen_builds.add(_read(build(kind).data))
    check(f"{kind}: one order of faces, edges and corner normals in 20 builds", len(seen_builds) == 1,
          len(seen_builds))
# The control: the sphere as `to_mesh` leaves it, under the same churn.
raw = set()
for i in range(20):
    _churn(i)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=6, radius=1.0)
    me = bpy.data.meshes.new("raw")
    bm.to_mesh(me)
    bm.free()
    raw.add(_read(me))
    bpy.data.meshes.remove(me)
check(f"  the control: `bmesh.ops.create_uvsphere` into `to_mesh` gave {len(raw)} orders in 20", len(raw) > 1)
for junk in _kept:
    junk.free()

# --------------------------------------------------------------------------
print("\nEach row does what Blender's own operator does, called as Blender's menu calls it")

ops = bpy.ops.mesh
# The 3D cursor of the first pointer main.swift makes the rows from: Point to
# Target…'s Target starts there.
CURSOR = Vector((2.0, -1.0, 2.5))
# (block, fixture, selection, select mode, Blender's own call)
SAME = [
    ("mergeAtCenter", 'cube', 'FACE0', 'FACE', lambda: ops.merge(type='CENTER')),
    ("mergeAtCursor", 'cube', 'FACE0', 'FACE', lambda: ops.merge(type='CURSOR')),
    ("mergeAtCursor", 'cube', 'VERT0', 'VERT', lambda: ops.merge(type='CURSOR')),
    ("mergeCollapse", 'cube', 'EDGE0', 'EDGE', lambda: ops.merge(type='COLLAPSE')),
    ("mergeAtFirst", 'cube', 'VERT_DIAG', 'VERT', lambda: ops.merge(type='FIRST')),
    ("mergeAtLast", 'cube', 'VERT_DIAG', 'VERT', lambda: ops.merge(type='LAST')),
    ("mergeAtCenter.last", 'cube', 'VERT_DIAG', 'VERT', lambda: ops.merge(type='LAST')),
    ("deleteVertices", 'cube', 'VERT0', 'VERT', lambda: ops.delete(type='VERT')),
    ("deleteEdges", 'cube', 'EDGE0', 'EDGE', lambda: ops.delete(type='EDGE')),
    ("deleteFaces", 'cube', 'FACE0', 'FACE', lambda: ops.delete(type='FACE')),
    ("deleteEdgesFaces", 'cube', 'FACE0', 'FACE', lambda: ops.delete(type='EDGE_FACE')),
    ("deleteOnlyFaces", 'cube', 'FACE0', 'FACE', lambda: ops.delete(type='ONLY_FACE')),
    ("collapseEdgesFaces", 'cube', 'EDGE0', 'EDGE', lambda: ops.edge_collapse()),
    ("collapseEdgesFaces", 'grid7', 'LOOP', 'EDGE', lambda: ops.edge_collapse()),
    ("deleteEdgeLoops", 'grid7', 'LOOP', 'EDGE', lambda: ops.delete_edgeloop()),
    ("deleteEdgeLoops.nosplit", 'cube', 'EDGE0', 'EDGE', lambda: ops.delete_edgeloop(use_face_split=False)),
    ("connectVertexPairs", 'cube', 'VERT_DIAG', 'VERT', lambda: ops.vert_connect()),
    ("smoothLaplacian", 'sphere', 'ALL', 'VERT', lambda: ops.vertices_smooth_laplacian()),
    ("smoothLaplacian.five", 'sphere', 'ALL', 'VERT',
     lambda: ops.vertices_smooth_laplacian(repeat=5, lambda_factor=2.0)),
    ("rotateEdgeCW", 'grid', 'INNER_EDGE', 'EDGE', lambda: ops.edge_rotate(use_ccw=False)),
    ("rotateEdgeCCW", 'grid', 'INNER_EDGE', 'EDGE', lambda: ops.edge_rotate(use_ccw=True)),
    ("intersectKnife", 'twocubes', 'SMALL', 'FACE', lambda: ops.intersect()),
    ("intersectKnife.self", 'twocubes', 'ALL', 'FACE', lambda: ops.intersect(mode='SELECT')),
    ("intersectBoolean", 'twocubes', 'SMALL', 'FACE', lambda: ops.intersect_boolean()),
    ("intersectBoolean.union", 'twocubes', 'SMALL', 'FACE', lambda: ops.intersect_boolean(operation='UNION')),
    # Self Intersection cuts the selection with itself: a whole selection is
    # not refused there.
    ("intersectBoolean.self", 'twocubes', 'ALL', 'FACE', lambda: ops.intersect_boolean(use_self=True)),
    ("intersectBoolean.float", 'twocubes', 'SMALL', 'FACE',
     lambda: ops.intersect_boolean(solver='FLOAT', threshold=0.0005)),
    ("weldEdgesIntoFaces", 'weldgrid', 'ALL', 'VERT', lambda: ops.face_split_by_edges()),
    ("convexHull", 'twocubes', 'ALL', 'VERT', lambda: ops.convex_hull()),
    ("convexHull", 'cube', 'VERT3', 'VERT', lambda: ops.convex_hull()),
    ("symmetrySnap", 'asym', 'ALL', 'VERT', lambda: ops.symmetry_snap()),
    ("recalculateNormals", 'cube', 'ALL', 'FACE', lambda: ops.normals_make_consistent(inside=False), True),
    ("recalculateInside", 'cube', 'ALL', 'FACE', lambda: ops.normals_make_consistent(inside=True)),
    ("setNormalsFromFaces", 'sphere', 'FACE0', 'FACE', lambda: ops.set_normals_from_faces()),
    ("pointNormals", 'sphere', 'ALL', 'VERT', lambda: ops.point_normals(target_location=CURSOR)),
    ("pointNormals.spherize", 'sphere', 'ALL', 'VERT',
     lambda: ops.point_normals(target_location=CURSOR, spherize=True, spherize_strength=0.5)),
    ("averageCustomNormal", 'sphere', 'ALL', 'VERT', lambda: ops.average_normals(average_type='CUSTOM_NORMAL')),
    ("averageFaceArea", 'sphere', 'ALL', 'VERT', lambda: ops.average_normals(average_type='FACE_AREA')),
    ("averageFaceArea.weight", 'sphere', 'ALL', 'VERT',
     lambda: ops.average_normals(average_type='FACE_AREA', weight=90)),
    ("averageCornerAngle", 'sphere', 'ALL', 'VERT', lambda: ops.average_normals(average_type='CORNER_ANGLE')),
    ("smoothNormals", 'sphere', 'ALL', 'VERT', lambda: ops.smooth_normals()),
    # Mesh ▸ Shading: every face smooth on a flat sphere, every face flat on
    # a smooth one. One face smooth among flat ones changes nothing Blender
    # draws: the edges between them stay sharp.
    ("shadeSmoothFaces", 'sphere', 'ALL', 'FACE', lambda: ops.faces_shade_smooth()),
    ("shadeFlatFaces", 'smoothsphere', 'ALL', 'FACE', lambda: ops.faces_shade_flat()),
    ("extrudeManifold", 'cube', 'FACE0', 'FACE',
     lambda: ops.extrude_manifold(MESH_OT_extrude_region={"use_dissolve_ortho_edges": True},
                                  TRANSFORM_OT_translate={"value": (0, 0, 0.2), "orient_type": 'NORMAL',
                                                          "constraint_axis": (False, False, True)})),
    ("extrudeManifold.in", 'cube', 'FACE0', 'FACE',
     lambda: ops.extrude_manifold(MESH_OT_extrude_region={"use_dissolve_ortho_edges": True},
                                  TRANSFORM_OT_translate={"value": (0, 0, -0.5), "orient_type": 'NORMAL',
                                                          "constraint_axis": (False, False, True)})),
    # Not faces only: an edge, as Blender's own call takes it.
    ("extrudeManifold", 'cube', 'EDGE0', 'EDGE',
     lambda: ops.extrude_manifold(MESH_OT_extrude_region={"use_dissolve_ortho_edges": True},
                                  TRANSFORM_OT_translate={"value": (0, 0, 0.2), "orient_type": 'NORMAL',
                                                          "constraint_axis": (False, False, True)})),
    ("extrudeManifold", 'grid', 'FACE0', 'FACE',
     lambda: ops.extrude_manifold(MESH_OT_extrude_region={"use_dissolve_ortho_edges": True},
                                  TRANSFORM_OT_translate={"value": (0, 0, 0.2), "orient_type": 'NORMAL',
                                                          "constraint_axis": (False, False, True)})),
]
NORMALS_ROWS = {"setNormalsFromFaces", "pointNormals", "averageCustomNormal", "averageFaceArea",
                "averageCornerAngle", "smoothNormals"}
# Every row's custom normals are held to Blender's. Average ▸ Custom Normal's
# were not, after a finding that its result was not reproducible in 5.2.1; it
# was this check's fixture, whose face order changed from build to build
# (`_canonical`), and with that fixed Blender agrees with itself, which the
# double run below holds for each normals row.
unsteady = []
seen = set()
for name, kind, sel, mode, own, *empty in SAME:
    seen.add(name.split(".")[0])
    bpy.context.scene.cursor.location = CURSOR
    build(kind); edit(sel, mode)
    before = state()
    own()
    blender = state()
    bpy.ops.object.mode_set(mode='OBJECT')
    if name.split(".")[0] in NORMALS_ROWS:
        # Blender's own, a second time, on a fresh fixture: the comparison
        # below means something only if Blender agrees with itself.
        build(kind); edit(sel, mode)
        own()
        steady = same(blender, state())
        bpy.ops.object.mode_set(mode='OBJECT')
        if steady is not None:
            unsteady.append(name)
        check(f"{name}: Blender's own, run twice, agrees with itself", steady is None, steady)
    build(kind); edit(sel, mode)
    error = perform(blocks["row.%s PERFORM" % name])
    app = state()
    bpy.ops.object.mode_set(mode='OBJECT')
    diff = same(blender, app) if error is None else "refused: " + error
    changed = same(before, blender) is not None
    check(f"{name} on {kind}/{sel}: {counts(before)} -> {counts(app)}, as Blender's", diff is None and
          app['mode'] == 'EDIT', diff)
    if not empty:
        check(f"  and Blender's own changed something there (the case is not empty)", changed)

print(f"Blender's own custom normals differed between two runs for: {', '.join(unsteady) or 'none'}")

# Two facts each measured once by hand, held here: Extrude Manifold at +0.2 on
# a cube's top face leaves 8/12/6 with the top 0.2 higher (its new sides
# dissolve into the old ones); Rotate Edge CW and CCW differ.
build('cube'); edit('FACE0', 'FACE')
perform(blocks["row.extrudeManifold PERFORM"])
s = state()
check("Extrude Manifold +0.2 on a cube's top face: 8/12/6, the top at z = 1.2",
      counts(s) == "8/12/6" and abs(max(c[2] for c in s['co']) - 1.2) < 1e-5, (counts(s), max(c[2] for c in s['co'])))
bpy.ops.object.mode_set(mode='OBJECT')
results = []
for name in ("rotateEdgeCW", "rotateEdgeCCW"):
    build('grid'); edit('INNER_EDGE', 'EDGE')
    perform(blocks["row.%s PERFORM" % name])
    results.append(state()['edges'])
    bpy.ops.object.mode_set(mode='OBJECT')
check("Rotate Edge CW and CCW turn the edge different ways", results[0] != results[1])

# --------------------------------------------------------------------------
print("\nRefused in words, the mesh as it was, where Blender would do nothing or fail")

REFUSE = [
    ("mergeAtCenter", 'cube', 'NONE', 'VERT', "select some first"),
    ("mergeCollapse", 'cube', 'VERT0', 'VERT', "one vertex is selected"),
    ("mergeAtFirst", 'cube', 'FACE0', 'FACE', "Vertex select mode"),
    ("mergeAtLast", 'cube', 'ALL', 'VERT', "no order"),
    # Three vertices without an order, as a box select or Select All leaves
    # them: At First raised Python's IndexError here (round 4's review).
    ("mergeAtFirst", 'cube', 'ALL', 'VERT', "no order"),
    ("mergeAtFirst", 'cube', 'VERT3_UNORDERED', 'VERT', "no order"),
    ("deleteVertices", 'cube', 'NONE', 'VERT', "select a vertex first"),
    ("deleteEdges", 'cube', 'VERT0', 'VERT', "select an edge first"),
    ("deleteFaces", 'cube', 'EDGE0', 'EDGE', "select a face first"),
    ("deleteEdgesFaces", 'cube', 'VERT_DIAG', 'VERT', "select an edge first"),
    ("deleteOnlyFaces", 'cube', 'EDGE0', 'EDGE', "select a face first"),
    ("collapseEdgesFaces", 'cube', 'VERT_DIAG', 'VERT', "select an edge first"),
    ("deleteEdgeLoops", 'cube', 'NONE', 'VERT', "select a loop of edges"),
    ("connectVertexPairs", 'cube', 'VERT0', 'VERT', "select two or more"),
    ("connectVertexPairs", 'cube', 'VERT_PAIR', 'VERT', "found no such pair"),
    ("ripVerticesExtend", 'cube', 'NONE', 'VERT', "select a vertex first"),
    ("ripVerticesExtend", 'cube', 'ALL', 'VERT', "could extend none"),
    ("smoothLaplacian", 'cube', 'NONE', 'VERT', "select some first"),
    ("intersectKnife", 'cube', 'EDGE0', 'EDGE', "select faces first"),
    ("intersectBoolean", 'cube', 'NONE', 'VERT', "select the faces to cut with first"),
    ("weldEdgesIntoFaces", 'cube', 'ALL', 'VERT', "none of the selected edges is loose"),
    ("weldEdgesIntoFaces", 'weldgrid', 'LOOSE', 'EDGE', "select the faces and the edges"),
    ("convexHull", 'cube', 'VERT_DIAG', 'VERT', "select at least three"),
    ("symmetrySnap", 'cube', 'NONE', 'VERT', "select some first"),
    ("setNormalsFromFaces", 'cube', 'EDGE0', 'EDGE', "select a face first"),
    ("pointNormals", 'cube', 'NONE', 'VERT', "select some first"),
    ("averageFaceArea", 'cube', 'NONE', 'VERT', "select some first"),
    ("smoothNormals", 'cube', 'NONE', 'VERT', "select some first"),
    ("extrudeManifold", 'cube', 'NONE', 'VERT', "select some first"),
    # FINISHED with nothing changed in Blender (measured in 5.2.1, the rows'
    # calls): said in words now (`LastOperator.Mesh.unchanged`, `edit_state`).
    ("mergeCollapse", 'cube', 'VERT_FAR', 'VERT', "none of these are joined"),
    ("smoothLaplacian", 'cube', 'VERT0', 'VERT', "moved no vertex"),
    # Every face selected, nothing unselected to cut: Knife changes nothing and
    # Boolean empties the mesh (8/12/6 -> 0/0/0) in Blender.
    ("intersectKnife", 'cube', 'ALL', 'FACE', "every face is selected"),
    ("intersectBoolean", 'cube', 'ALL', 'FACE', "every face is selected"),
]
for name, kind, sel, mode, words in REFUSE:
    seen.add(name)
    build(kind); edit(sel, mode)
    before = state()
    error = perform(blocks["row.%s PERFORM" % name])
    after = state()
    bpy.ops.object.mode_set(mode='OBJECT')
    check(f"{name} on {kind}/{sel}: {error!r}", error is not None and words in error and in_words(last_error[0])
          and same(before, after) is None and after['mode'] == 'EDIT', (error, same(before, after), after['mode']))

# What the refusals stand in for, measured: Blender's own calls there.
for label, sel, mode, own in (("Merge ▸ Collapse on two unjoined corners", 'VERT_FAR', 'VERT',
                               lambda: ops.merge(type='COLLAPSE')),
                              ("Smooth Vertices (Laplacian) on one corner", 'VERT0', 'VERT',
                               lambda: ops.vertices_smooth_laplacian()),
                              ("Intersect (Knife) on a whole cube", 'ALL', 'FACE', lambda: ops.intersect()),
                              ("Intersect (Boolean) on a whole cube", 'ALL', 'FACE', lambda: ops.intersect_boolean())):
    build('cube'); edit(sel, mode)
    before = state()
    result = sorted(own())
    after = state()
    bpy.ops.object.mode_set(mode='OBJECT')
    check(f"  Blender's own {label}: {result}, {counts(before)} -> {counts(after)}",
          result == ['FINISHED'] and (same(before, after) is None or counts(after) == "0/0/0"))

# The negative control for `edit_state`: with the counts alone, Merge ▸ At
# Cursor on one vertex — moved to the cursor, no vertex added or removed —
# would be refused as having changed nothing.
lc = sys.modules["_blenderkit_loopcut"]
_edit_state = lc.edit_state
lc.edit_state = lc.edit_counts
try:
    bpy.context.scene.cursor.location = CURSOR
    build('cube'); edit('VERT0', 'VERT')
    error = perform(blocks["row.mergeAtCursor PERFORM"])
    bpy.ops.object.mode_set(mode='OBJECT')
finally:
    lc.edit_state = _edit_state
check(f"  the negative control: compared by counts alone, At Cursor on one vertex is refused ({error!r})",
      error is not None and "changed nothing" in error, error)

# The negative control: without the check, Merge's At First fails in Blender's
# own words, which name an enum and no selection.
build('cube'); edit('FACE0', 'FACE')
try:
    ops.merge(type='FIRST')
    bare = None
except Exception as error:
    bare = str(error)
bpy.ops.object.mode_set(mode='OBJECT')
check("the negative control: Blender's own At First there says only 'enum not found'",
      bare is not None and "not found in" in bare, bare)

print("\nRun from Sculpt Mode, as the bridge's mode bracket allows")
for name in sorted(n for n in seen if "row.%s PERFORM" % n in blocks):
    build('cube'); edit('ALL', 'VERT')
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.mode_set(mode='SCULPT')
    error = perform(blocks["row.%s PERFORM" % name])
    mode = obj().mode
    if mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    check(f"{name}: no crash, back in Sculpt Mode, any refusal in the app's words ({error!r})",
          mode == 'SCULPT' and in_words(last_error[0]), (mode, type(last_error[0]).__name__))

# The negative control: Merge's check as it was, `history[0]` unguarded,
# fails that loop's words from Sculpt Mode (a whole cube, no order).
_fixed_check_merge = mm.check_merge


def _old_check_merge(type):
    if type == 'FIRST':
        obj = mm._edited("Merge")
        list(bmesh.from_edit_mesh(obj.data).select_history)[0]
    return _fixed_check_merge(type)


mm.check_merge = _old_check_merge
try:
    build('cube'); edit('ALL', 'VERT')
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.mode_set(mode='SCULPT')
    error = perform(blocks["row.mergeAtFirst PERFORM"])
    if obj().mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
finally:
    mm.check_merge = _fixed_check_merge
check(f"  the negative control: Merge's old check there says {error!r}, which is not in the app's words",
      not in_words(last_error[0]) and isinstance(last_error[0], IndexError), type(last_error[0]).__name__)

# --------------------------------------------------------------------------
print("\nExtrude to Cursor or Add and Rip Vertices and Extend, held to Blender's own invokes")

lib = ctypes.CDLL(None)
try:
    _call = getattr(lib, "_ZN7blender37WM_operator_name_call_with_propertiesEPNS_8bContextEPKcNS_2wm"
                         "13OpCallContextEPNS_10IDPropertyEPKNS_7wmEventE")
    _call.restype = ctypes.c_int
    _call.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int8, ctypes.c_void_p, ctypes.c_void_p]
except AttributeError as error:
    _call = None
    check("Blender's WM_operator_name_call_with_properties is reachable", False, error)
INVOKED = {}


class BK_OT_invoke_at(bpy.types.Operator):
    """Runs Blender's own invoke of `opname` with the pointer at window
    pixel (x, y): a wmEvent made here (5.2.1's layout: xy at byte 20; the
    region-relative mval is worked out from it by `wm_region_mouse_co`) and
    the properties as an IDProperty group. Inside this operator Blender's
    `op_undo_depth` is raised, so the invoked one is neither registered nor
    given a redo panel — the crash class of `ED_area_type_hud_ensure`."""
    bl_idname = "bk.invoke_at"
    bl_label = "Invoke at"
    bl_options = {'INTERNAL'}
    opname: bpy.props.StringProperty()
    x: bpy.props.IntProperty()
    y: bpy.props.IntProperty()
    rotate: bpy.props.BoolProperty(default=True)

    def execute(self, context):
        event = (ctypes.c_ubyte * 1024)()
        ctypes.c_int32.from_buffer(event, 20).value = self.x
        ctypes.c_int32.from_buffer(event, 24).value = self.y
        holder = context.scene
        holder["_bk_props"] = {"rotate_source": self.rotate} if self.opname.endswith("cursor") else {}
        group = holder["_bk_props"]
        # BPy_IDProperty: PyObject_HEAD (16 bytes), owner_id, then prop.
        prop = ctypes.c_void_p.from_address(id(group) + 24).value
        INVOKED['ret'] = _call(context.as_pointer(), self.opname.encode(), 1, prop, ctypes.addressof(event))
        del holder["_bk_props"]
        return {'FINISHED'}


bpy.utils.register_class(BK_OT_invoke_at)


def aim(view):
    """Blender's borrowed 3D View, looking as the app's pointer says."""
    rv3d = bpy.context.area.spaces.active.region_3d
    forward = Vector(view['forward']).normalized()
    z = -forward
    up = Vector(view['up'])
    y = (up - z * up.dot(z)).normalized()
    rv3d.view_perspective = 'ORTHO' if view['ortho'] else 'PERSP'
    rv3d.view_rotation = Matrix((y.cross(z), y, z)).transposed().to_quaternion()
    rv3d.view_distance = 10.0
    rv3d.view_location = Vector(view['eye']) + forward * 10.0
    rv3d.update()
    return rv3d


def pointer_at(view, cursor):
    """The window pixel over `cursor`, and the point Blender's own invoke puts
    under it at the cursor's depth: Extrude to Cursor or Add's vertex with
    nothing selected, which is on Blender's own ray through that pixel."""
    build('cube'); edit('NONE', 'VERT')
    bpy.context.scene.cursor.location = cursor
    with context.temp_override_view3d("check"):
        region = bpy.context.region
        rv3d = aim(view)
        m = view3d_utils.location_3d_to_region_2d(region, rv3d, cursor)
        x, y = region.x + int(round(m.x)), region.y + int(round(m.y))
        bpy.ops.bk.invoke_at('EXEC_DEFAULT', opname="MESH_OT_dupli_extrude_cursor", x=x, y=y)
        bm = bmesh.from_edit_mesh(obj().data)
        bm.verts.ensure_lookup_table()
        point = bm.verts[-1].co.copy()
    bpy.ops.object.mode_set(mode='OBJECT')
    return x, y, point


XFORM = Matrix.Translation((0.3, -0.2, 0.5)) @ Matrix.Rotation(0.4, 4, 'Z') @ Matrix.Diagonal((1.0, 1.5, 0.8, 1.0))
FIXTURES = [('cube', 'VERT0', 'VERT', None), ('cube', 'EDGE0', 'EDGE', None), ('cube', 'FACE0', 'FACE', None),
            ('cube', 'NONE', 'VERT', None), ('grid', 'LOOP', 'EDGE', None), ('cube', 'VERT_DIAG', 'VERT', None),
            ('cube', 'ALL', 'VERT', None), ('sphere', 'FACE0', 'FACE', None), ('cube', 'FACE0', 'FACE', XFORM),
            ('grid', 'LOOP', 'EDGE', XFORM), ('halfgrid', 'PLANE_EDGES', 'EDGE', None)]
views = sorted({k.split()[0] for k in blocks if k.startswith("pointer.")}, key=lambda k: int(k.split(".")[1]))
worst = 0.0
cases = differ_side = differ_rot = differ_ray = rip_cases = mismatched = rip_mismatched = 0
rip_shapes = {}
original_side = mm._line_point_side_v2
for key in views:
    view = json.loads(blocks[key + " VIEW"])
    cursor = Vector(view['cursor'])
    x, y, point = pointer_at(view, cursor)
    for kind, sel, mode, xform in FIXTURES:
        for rotate in (True, False):
            build(kind, xform); edit(sel, mode)
            with context.temp_override_view3d("check"):
                aim(view)
                bpy.ops.bk.invoke_at('EXEC_DEFAULT', opname="MESH_OT_dupli_extrude_cursor", x=x, y=y, rotate=rotate)
            blender = state()
            bpy.ops.object.mode_set(mode='OBJECT')
            # The app's line, Blender's cursor where Blender's pointer is: on
            # its ray, at the cursor's depth (the empty selection's depth).
            build(kind, xform); edit(sel, mode)
            bpy.context.scene.cursor.location = point
            error = perform(blocks[key + (" EXTRUDE" if rotate else " NOROT")])
            app = state()
            bpy.ops.object.mode_set(mode='OBJECT')
            diff = same(blender, app, 1e-4, normals=False) if error is None else "refused: " + error
            cases += 1
            if diff is None:
                worst = max([worst] + [(Vector(p) - Vector(q)).length for p, q in zip(blender['co'], app['co'])])
            else:
                mismatched += 1
                check(f"Extrude to Cursor or Add, {key} {kind}/{sel}{' moved' if xform else ''} "
                      f"rotate={rotate}", False, diff)
            # Negative controls: the port with its side test turned round,
            # and with Rotate Source the other way, against the same Blender.
            if sel not in ('NONE', 'VERT0'):
                build(kind, xform); edit(sel, mode)
                bpy.context.scene.cursor.location = point
                mm._line_point_side_v2 = lambda a, b, p: -original_side(a, b, p)
                try:
                    perform(blocks[key + (" EXTRUDE" if rotate else " NOROT")])
                finally:
                    mm._line_point_side_v2 = original_side
                differ_side += same(blender, state(), 1e-4, normals=False) is not None
                bpy.ops.object.mode_set(mode='OBJECT')
                build(kind, xform); edit(sel, mode)
                bpy.context.scene.cursor.location = point
                perform(blocks[key + (" NOROT" if rotate else " EXTRUDE")])
                differ_rot += same(blender, state(), 1e-4, normals=False) is not None
                bpy.ops.object.mode_set(mode='OBJECT')
    # Rip Vertices and Extend: Blender's own `rip_edge` invoke at the pixel,
    # against the app's call with Blender's cursor on Blender's ray.
    for kind, sel, mode, xform in FIXTURES[:2] + [('grid', 'LOOP', 'EDGE', None), ('cube', 'VERT_DIAG', 'VERT', None),
                                                  ('sphere', 'VERT0', 'VERT', None), ('grid7', 'VERT0', 'VERT', XFORM)]:
        build(kind, xform); edit(sel, mode)
        with context.temp_override_view3d("check"):
            aim(view)
            bpy.ops.bk.invoke_at('EXEC_DEFAULT', opname="MESH_OT_rip_edge", x=x, y=y)
        blender = state()
        bpy.ops.object.mode_set(mode='OBJECT')
        build(kind, xform); edit(sel, mode)
        bpy.context.scene.cursor.location = point
        error = perform(blocks[key + " RIP"])
        app = state()
        bpy.ops.object.mode_set(mode='OBJECT')
        rip_cases += 1
        diff = same(blender, app, normals=False) if error is None else "refused: " + error
        if diff is not None:
            rip_mismatched += 1
            check(f"Rip Vertices and Extend, {key} {kind}/{sel}", False, diff)
        rip_shapes.setdefault((kind, sel), set()).add(str(app['edges']))
        # The negative control: the ray through the point mirrored through
        # the world's origin. (Turning the ray round is no control: `rip_edge`
        # reads only its line, `closest_to_line_v3`.)
        build(kind, xform); edit(sel, mode)
        bpy.context.scene.cursor.location = point
        original_ray = mm.pointer_ray
        mm.pointer_ray = lambda *a, **k: (tuple(-c for c in original_ray(*a, **k)[0]), original_ray(*a, **k)[1])
        try:
            perform(blocks[key + " RIP"])
        finally:
            mm.pointer_ray = original_ray
        differ_ray += same(blender, state(), normals=False) is not None
        bpy.ops.object.mode_set(mode='OBJECT')

check(f"Extrude to Cursor or Add: {cases} cases ({len(views)} views, {len(FIXTURES)} selections, Rotate Source "
      f"on and off) as Blender's own invoke made them, worst {worst:.1e} m",
      mismatched == 0 and cases > 0 and worst < 1e-4)
check(f"  the negative control: the side test turned round disagrees in {differ_side} of them", differ_side > 0)
check(f"  and Rotate Source the other way in {differ_rot}", differ_rot > 0)
check(f"Rip Vertices and Extend: {rip_cases} cases as Blender's own rip_edge invoke made them",
      rip_cases > 0 and rip_mismatched == 0)
check(f"  the pointer decides the edge: {sum(len(v) > 1 for v in rip_shapes.values())} selections ripped "
      f"differently from different views", any(len(v) > 1 for v in rip_shapes.values()))
check(f"  the negative control: the ray through the mirrored point disagrees in {differ_ray}", differ_ray > 0)

# An object scaled to nothing on an axis has no space of its own to work in:
# refused, the mesh as it was, rather than a vertex 2.17e8 m out (round 4's
# review measured the port's `inverted_safe` there against Blender's own).
build('cube', Matrix.Diagonal((1.0, 0.0, 1.0, 1.0))); edit('VERT0', 'VERT')
before = state()
error = perform(blocks["pointer.0 EXTRUDE"])
after = state()
bpy.ops.object.mode_set(mode='OBJECT')
check(f"Extrude to Cursor or Add on an object of scale 0 in Y is refused in words ({error!r})",
      error is not None and "scaled to nothing" in error and in_words(last_error[0])
      and same(before, after) is None, (error, same(before, after)))
build('cube', Matrix.Diagonal((1.0, 1e-6, 1.0, 1.0))); edit('VERT0', 'VERT')
error = perform(blocks["pointer.0 EXTRUDE"])
bpy.ops.object.mode_set(mode='OBJECT')
check(f"  and one of scale 1e-6 is not ({error!r})", error is None, error)

# --------------------------------------------------------------------------
print("\nThe rows the menu cannot run, and why")

# All nine `polybuild_*` the search lists (round 4's review measured the four
# this check had left out).
for path, kw in (("rip_move", {}), ("rip_move", {"MESH_OT_rip": {"use_fill": True}}), ("dupli_extrude_cursor", {}),
                 ("polybuild_face_at_cursor_move", {}), ("polybuild_extrude_at_cursor_move", {}),
                 ("polybuild_split_at_cursor_move", {}), ("polybuild_dissolve_at_cursor", {}),
                 ("polybuild_transform_at_cursor_move", {}), ("polybuild_delete_at_cursor", {}),
                 ("polybuild_face_at_cursor", {}), ("polybuild_split_at_cursor", {}),
                 ("polybuild_transform_at_cursor", {})):
    build('cube'); edit('VERT0', 'VERT')
    before = state()
    with context.temp_override_view3d("check"):
        try:
            result = sorted(getattr(ops, path)('EXEC_DEFAULT', **kw))
        except Exception as error:
            result = "error: " + str(error)
    after = state()
    bpy.ops.object.mode_set(mode='OBJECT')
    check(f"mesh.{path}{kw or ''} under the borrowed 3D View: {result}, nothing changed", same(before, after) is None)

print(f"\n{passed} passed")
print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
