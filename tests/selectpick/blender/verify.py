"""Blender's pick selections and the Select menu's new rows, held to Blender
5.2.1 itself, in the app's context: its undo stack (`_blenderkit_undo`, the
history's first push), gpu.init(), the startup screen's 3D View borrowed as
the app borrows it, and the modules the app ships from Resources/python/site.

scripts/run-selectpick-blender-check.sh runs this twice around the Swift:

  measure  over a grid seen from the top, a cube, a UV sphere (poles) and an
           8-sided cylinder (n-gon caps), each in vertex, edge and face mode:
           Blender's OWN pick at each visible element — the element
           `view3d.select(location=...)` takes there with X-Ray on, the only
           way Blender picks without a window (its GPU pick reads nothing
           headless) — and what Blender's Alt+click, Ctrl+Alt+click,
           Ctrl+click and L do from that element: the exec the invoke calls,
           with the active vertex or face the invoke works out from the same
           pixel (`loop_active`, edbm_select_loop_or_ring_invoke_impl read
           line for line). Loops and rings are sampled at each edge's middle
           and off it (a quarter along, 3 px aside), where neither the nearer
           end nor the nearer face is a tie. The invoke itself cannot run
           here: it reads the mouse from the window's event state, which
           Blender makes only for a GHOST window (wm_window.cc), and
           `Window.event_simulate` under `-b --enable-event-simulate`
           segfaulted in Window_event_simulate_call (measured, exit 139).
           Also Blender's own Ctrl+L on a grid with a seam, in each select
           mode, and its Box Select over what is selected. Written out with
           the mesh and the view for the Swift.

  apply    what the Swift made of the same pixels — MeshPicker's pick, the
           index Blender names it by, the active element, the selection
           order pushed before a path, the call — run, and held to Blender's
           own result element for element, the active element included.
           Then the refusals, the Select menu's Next Active, Previous Active,
           Side of Active and Select Grouped (Blender's operator cannot run
           without an interface, so its exec's port is held to what the
           exec does, type by type), the selection order's round trip through
           the mirror, the undo-in-an-area guard (True, 1, 2, -1, and an
           operator looked up outside the override), Select Linked ▸ Linked
           per select mode, Box Select's Set over the selection, the aimed
           view's failure path, and the negative controls: the multi-select
           the task first proposed (Face mode disagrees), a path pushed
           without the order (refused), an active vertex chosen from the far
           end of the edge (disagrees), the edge's first end or lower face
           always (caught off the middle), the Linked row's old Seam, the
           region rule that read the elements alone.

Nothing here opens a browser, a file browser or another program, and the
shell script gives this Blender a HOME and BLENDER_USER_RESOURCES of its own.
"""
import bpy, bmesh, gpu, sys, os, json, math, types, tempfile, importlib.util, pathlib
from mathutils import Vector, Euler, Quaternion
from mathutils.bvhtree import BVHTree
from bpy_extras.view3d_utils import location_3d_to_region_2d

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources/python/site"
sys.dont_write_bytecode = True
argv = sys.argv[sys.argv.index("--") + 1:]
PHASE = argv[0]
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


class _App(types.ModuleType):
    def is_main_thread(self):
        return True

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules['_blenderkit'] = _App('_blenderkit')
sys.path.insert(0, str(SITE))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
for name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(name)
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
load("_blenderkit_knife")
select = load("_blenderkit_select")
context.install(bpy)
gpu.init()
undo.push(tempfile.mkdtemp(prefix="bk-selectpick-"), "Original")


def view3d():
    for w in bpy.context.window_manager.windows:
        for a in w.screen.areas:
            if a.type == 'VIEW_3D':
                for r in a.regions:
                    if r.type == 'WINDOW':
                        return w, a, r
    raise RuntimeError("no 3D View in the startup screen")


WINDOW, AREA, REGION = view3d()
RV3D = AREA.spaces.active.region_3d


def clear_scene():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)


LIBRARY = None   # the measured meshes, written by measure and appended by apply


def make(kind):
    clear_scene()
    if LIBRARY is not None and os.path.exists(LIBRARY):
        # The mesh exactly as measured, element order and all: a UV sphere
        # added again in another Blender numbered its faces differently
        # (measured while writing this check), so apply appends the measured
        # one instead of adding a new primitive.
        with bpy.data.libraries.load(LIBRARY) as (source, target):
            target.meshes = ["Probe-" + kind]
        mesh = target.meshes[0]
        obj = bpy.data.objects.new("Probe-" + kind, mesh)
        bpy.context.scene.collection.objects.link(obj)
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        return obj
    if kind == 'grid':
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=6, y_subdivisions=6, size=6)
    elif kind == 'cube':
        bpy.ops.mesh.primitive_cube_add(size=2)
    elif kind == 'sphere':
        bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, radius=1.5)
    elif kind == 'cylinder':
        bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=1, depth=2)
    bpy.context.object.data.name = "Probe-" + kind
    return bpy.context.object


VIEWS = {
    'grid': dict(rotation=Quaternion((1, 0, 0, 0)), distance=8, perspective='ORTHO'),
    'cube': dict(rotation=Euler((math.radians(62), 0, math.radians(38)), 'XYZ').to_quaternion(),
                 distance=8, perspective='PERSP'),
    'sphere': dict(rotation=Euler((math.radians(70), 0, math.radians(-25)), 'XYZ').to_quaternion(),
                   distance=7, perspective='PERSP'),
    'cylinder': dict(rotation=Euler((math.radians(55), 0, math.radians(20)), 'XYZ').to_quaternion(),
                     distance=7, perspective='PERSP'),
}
KINDS = ('grid', 'cube', 'sphere', 'cylinder')


def aim(kind):
    v = VIEWS[kind]
    with bpy.context.temp_override(window=WINDOW, area=AREA, region=REGION):
        RV3D.view_rotation = v['rotation']
        RV3D.view_location = Vector((0, 0, 0))
        RV3D.view_distance = v['distance']
        RV3D.view_perspective = v['perspective']
        RV3D.update()


def in_view():
    return bpy.context.temp_override(window=WINDOW, area=AREA, region=REGION)


def to_edit(obj, mode):
    if obj.mode != 'EDIT':
        bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    for seq in (bm.faces, bm.edges, bm.verts):
        for e in seq:
            e.select = False
    bm.select_history.clear()
    bm.faces.active = None
    bmesh.update_edit_mesh(obj.data)


def state(obj):
    """What Blender holds: selected vertices, edges (by their ends), faces,
    and the active element as (kind, index)."""
    bm = bmesh.from_edit_mesh(obj.data)
    for seq in (bm.verts, bm.edges, bm.faces):
        seq.index_update()
    active = bm.select_history.active
    kind = None
    if active is not None:
        kind = [isinstance(active, t) for t in (bmesh.types.BMVert, bmesh.types.BMEdge, bmesh.types.BMFace)].index(True)
    return dict(v=sorted(x.index for x in bm.verts if x.select),
                e=sorted(sorted([x.verts[0].index, x.verts[1].index]) for x in bm.edges if x.select),
                f=sorted(x.index for x in bm.faces if x.select),
                active=None if active is None else [kind, active.index])


def summary(s):
    return "%dv/%de/%df" % (len(s['v']), len(s['e']), len(s['f']))


MODE_KIND = {'VERT': 0, 'EDGE': 1, 'FACE': 2}


# ---------------------------------------------------------------- measure

def blender_pick(obj, mode, px):
    """The element Blender's click takes at `px` in `mode` (X-Ray on): its
    (kind, index), or None."""
    to_edit(obj, mode)
    with in_view():
        bpy.ops.view3d.select(location=(int(px[0]), int(px[1])))
    s = state(obj)
    bm = bmesh.from_edit_mesh(obj.data)
    if mode == 'VERT':
        return [0, s['v'][0]] if len(s['v']) == 1 else None
    if mode == 'EDGE':
        sel = [e.index for e in bm.edges if e.select]
        return [1, sel[0]] if len(sel) == 1 else None
    return [2, s['f'][0]] if len(s['f']) == 1 else None


def project(obj, co):
    p = location_3d_to_region_2d(REGION, RV3D, obj.matrix_world @ co)
    return None if p is None else (p.x, p.y)


def loop_active(obj, edge_index, mode, px):
    """The element Blender's Alt+click makes active, as its invoke works it
    out (editmesh_select.cc): the nearer end in Vertex mode (the second on a
    tie), the face of the edge whose median centre is nearer in Face mode."""
    bm = bmesh.from_edit_mesh(obj.data)
    bm.edges.ensure_lookup_table()
    e = bm.edges[edge_index]
    m = Vector(px)
    if mode == 'VERT':
        d = []
        for v in e.verts:
            p = project(obj, v.co)
            d.append((Vector(p) - m).length_squared if p else float('inf'))
        return ('vert_index', e.verts[0].index if d[0] < d[1] else e.verts[1].index)
    if mode == 'FACE':
        best = None
        near = []
        for f in e.link_faces:
            p = project(obj, f.calc_center_median())
            if p is None:
                continue
            dist = (Vector(p) - m).length_squared
            near.append((dist, f.index))
            if best is None or dist < best[1]:
                best = (f.index, dist)
        if best is None:
            return None
        # A pointer exactly between two faces' middles (a grid from the top,
        # tapped on an edge): which is nearer is float rounding, not anything
        # a tap means, and either is Blender's answer.
        tie = [i for d, i in near if abs(math.sqrt(d) - math.sqrt(best[1])) < 0.01]
        return ('face_index', best[0], tie if len(tie) > 1 else None)
    return None


def any_index(obj, element):
    bm = bmesh.from_edit_mesh(obj.data)
    kind, index = element
    return index + (0, len(bm.verts), len(bm.verts) + len(bm.edges))[kind]


def visible(obj, tree, eye, ortho_dir, co):
    """Whether `co` (local, the object is at the origin) is what the eye
    sees first along its line of sight."""
    target = obj.matrix_world @ co
    if ortho_dir is not None:
        origin = target - ortho_dir * 100
        direction = ortho_dir
    else:
        origin = eye
        direction = (target - eye).normalized()
    hit = tree.ray_cast(origin, direction)
    if hit[0] is None:
        return True
    return hit[3] >= (target - origin).length - 1e-3


def seam_grid():
    """A 4 x 4 grid of faces (5 x 5 vertices, 1 apart, centred), with a seam
    down its middle: every edge on x = 0. Built the same way in both phases."""
    clear_scene()
    me = bpy.data.meshes.new("SeamGrid")
    bm = bmesh.new()
    rows = [[bm.verts.new((x - 2, y - 2, 0)) for x in range(5)] for y in range(5)]
    for y in range(4):
        for x in range(4):
            bm.faces.new((rows[y][x], rows[y][x + 1], rows[y + 1][x + 1], rows[y + 1][x]))
    for e in bm.edges:
        if all(abs(v.co.x) < 1e-6 for v in e.verts):
            e.seam = True
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new("SeamGrid", me)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    return obj


def seed_left(obj, mode):
    """In `mode`, the element at the grid's bottom-left corner selected, left
    of the seam: a vertex, an edge, a face."""
    to_edit(obj, mode)
    bm = bmesh.from_edit_mesh(obj.data)
    corner = lambda co: co.x + 2 * co.y
    if mode == 'VERT':
        min(bm.verts, key=lambda v: corner(v.co)).select_set(True)
    elif mode == 'EDGE':
        min(bm.edges, key=lambda e: corner(e.verts[0].co + e.verts[1].co)).select_set(True)
    else:
        min(bm.faces, key=lambda f: corner(f.calc_center_median())).select_set(True)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)


def selected_vertices(obj):
    return sum(v.select for v in bmesh.from_edit_mesh(obj.data).verts)


def measure_linked_rows():
    """Blender's own Ctrl+L — `mesh.select_linked` with no properties, its
    keymap item and its Select ▸ Select Linked ▸ Linked row — on the seam
    grid from the corner, in each select mode. Measured before anything in
    this Blender sets a Delimit: the exec remembers the last one it was
    given, per kind of select mode (`select_linked_delimit_default_from_op`),
    and these are its first-press defaults."""
    obj = seam_grid()
    bpy.ops.object.mode_set(mode='EDIT')
    out = {}
    for mode in ('VERT', 'EDGE', 'FACE'):
        seed_left(obj, mode)
        result = bpy.ops.mesh.select_linked()
        out[mode] = dict(result=sorted(result), vertices=selected_vertices(obj))
    bpy.ops.object.mode_set(mode='OBJECT')
    print("  measured Blender's Ctrl+L on the seam grid: " + ", ".join(
        f"{m} {out[m]['vertices']}" for m in out), flush=True)
    return out


def measure_region_sets(obj):
    """Blender's own Box Select (X-Ray on) over the grid's centre vertex,
    from four starts: that vertex selected and active, selected with no
    order, nothing selected over an empty patch (a face's middle), and Extend
    over the selected, active vertex — what it returns and what it leaves,
    the selection order included."""
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    centre = min(range(len(bm.verts)), key=lambda i: bm.verts[i].co.length)
    p = project(obj, bm.verts[centre].co)
    x, y = round(p[0]), round(p[1])
    on = dict(xmin=x - 5, xmax=x + 5, ymin=y - 5, ymax=y + 5)
    q = project(obj, bm.verts[centre].co + Vector((0.5, 0.5, 0)))
    off = dict(xmin=round(q[0]) - 5, xmax=round(q[0]) + 5, ymin=round(q[1]) - 5, ymax=round(q[1]) + 5)
    out = []
    for name, op_mode, seed, ordered, rect in (('set same, ordered', 'SET', [centre], True, on),
                                               ('set same, no order', 'SET', [centre], False, on),
                                               ('set nothing over nothing', 'SET', [], False, off),
                                               ('extend same, ordered', 'ADD', [centre], True, on)):
        to_edit(obj, 'VERT')
        bm = bmesh.from_edit_mesh(obj.data)
        bm.verts.ensure_lookup_table()
        for i in seed:
            bm.verts[i].select_set(True)
            if ordered:
                bm.select_history.add(bm.verts[i])
        bmesh.update_edit_mesh(obj.data)
        with in_view():
            result = bpy.ops.view3d.select_box(mode=op_mode, wait_for_input=False, **rect)
        out.append(dict(name=name, mode=op_mode, seed=seed, ordered=ordered, rect=rect,
                        result=sorted(result), after=state(obj)))
    print("  measured Blender's Box Select over the selected vertex: " + "; ".join(
        f"{c['name']} {c['result']} order {len(seed_history(c))} -> {0 if c['after']['active'] is None else 1}"
        for c in out), flush=True)
    return out


def seed_history(case):
    return case['seed'] if case['ordered'] else []


def measure(path):
    AREA.spaces.active.shading.show_xray = True
    out = {'scenes': [], 'linked_rows': measure_linked_rows()}
    meshes = set()
    for kind in KINDS:
        obj = make(kind)
        aim(kind)
        me = obj.data
        me.calc_loop_triangles()
        view_inv = RV3D.view_matrix.inverted()
        eye = view_inv.translation.copy()
        ortho = RV3D.view_perspective == 'ORTHO'
        ortho_dir = (view_inv.to_3x3() @ Vector((0, 0, -1))).normalized() if ortho else None
        tree = BVHTree.FromPolygons([v.co for v in me.vertices], [list(p.vertices) for p in me.polygons])
        scene = {
            'name': kind,
            'size': [REGION.width, REGION.height],
            'matrix': [list(row) for row in RV3D.perspective_matrix],
            'eye': list(eye), 'ortho': ortho, 'direction': list(ortho_dir) if ortho else None,
            'vertices': [list(v.co) for v in me.vertices],
            'triangles': [list(t.vertices) for t in me.loop_triangles],
            'triangle_polygons': [t.polygon_index for t in me.loop_triangles],
            'edges': [list(e.vertices) for e in me.edges],
            'polygons': len(me.polygons),
            'samples': [],
        }
        bpy.ops.object.mode_set(mode='EDIT')
        if kind == 'grid':
            scene['region_sets'] = measure_region_sets(obj)
        bm = bmesh.from_edit_mesh(me)
        for seq in (bm.verts, bm.edges, bm.faces):
            seq.ensure_lookup_table()
        edge_px, quarter_px, vert_px, face_px = [], [], [], []
        for e in bm.edges:
            mid = (e.verts[0].co + e.verts[1].co) / 2
            p = project(obj, mid)
            if p and 2 < p[0] < REGION.width - 2 and 2 < p[1] < REGION.height - 2 \
                    and visible(obj, tree, eye, ortho_dir, mid):
                edge_px.append((e.index, (round(p[0]), round(p[1]))))
            # Off the middle (round 4's review): at an edge's middle the end
            # Vertex mode makes active is a tie that pixel rounding decides
            # (`length_1 < length_2`), and on the grid from the top both faces'
            # middles are equally near, so the active element was held to
            # Blender only at ties. A quarter of the way along — from the
            # first end on even edges, the second on odd ones — and 3 px to
            # one side of the edge, alternating, neither is a tie.
            a, b = e.verts
            t = 0.25 if e.index % 2 == 0 else 0.75
            co = a.co.lerp(b.co, t)
            pa, pb, pq = project(obj, a.co), project(obj, b.co), project(obj, co)
            if pa and pb and pq and visible(obj, tree, eye, ortho_dir, co):
                d = Vector(pb) - Vector(pa)
                if d.length > 1e-6:
                    side = 3 if (e.index // 2) % 2 == 0 else -3
                    n = Vector((-d.y, d.x)).normalized() * side
                    q = (round(pq[0] + n.x), round(pq[1] + n.y))
                    if 2 < q[0] < REGION.width - 2 and 2 < q[1] < REGION.height - 2:
                        quarter_px.append((e.index, q))
        for v in bm.verts:
            p = project(obj, v.co)
            if p and visible(obj, tree, eye, ortho_dir, v.co):
                vert_px.append((v.index, (round(p[0]), round(p[1]))))
        for f in bm.faces:
            c = f.calc_center_median()
            p = project(obj, c)
            if p and visible(obj, tree, eye, ortho_dir, c):
                face_px.append((f.index, (round(p[0]), round(p[1]))))
        sid = 0

        def add(sample):
            nonlocal sid
            sample['id'] = f"{kind}-{sid}"
            sid += 1
            scene['samples'].append(sample)

        # Loop Select and Edge Ring Select from every visible edge, at its
        # middle and off it, in each mode; a second Alt+click on the same
        # edge for the first few.
        aimed = [(e, p, 'middle') for e, p in edge_px] + [(e, p, 'off the middle') for e, p in quarter_px]
        for mode in ('VERT', 'EDGE', 'FACE'):
            for pick in ('loop', 'ring'):
                for k, (edge, px, where) in enumerate(aimed):
                    element = blender_pick(obj, 'EDGE', px)
                    sample = dict(mode=mode, pick=pick, px=list(px), sampled=[1, edge], blender=element,
                                  where=where)
                    if element is None:
                        add(sample)
                        continue
                    to_edit(obj, mode)
                    extra = {}
                    act = loop_active(obj, element[1], mode, px)
                    if act:
                        extra[act[0]] = act[1]
                        if len(act) > 2 and act[2]:
                            sample['tie'] = [[2, i] for i in act[2]]
                    op = bpy.ops.mesh.loop_select if pick == 'loop' else bpy.ops.mesh.edgering_select
                    with in_view():
                        op(object_index=0, edge_index=element[1], **extra)
                    sample['reference'] = state(obj)
                    if k < 4:
                        with in_view():
                            op(object_index=0, edge_index=element[1], **extra)
                        sample['again'] = state(obj)
                    add(sample)
        # Pick Shortest Path: from the first visible element (a click), to
        # each of up to 12 others.
        for mode, pxs in (('VERT', vert_px), ('EDGE', edge_px), ('FACE', face_px)):
            if len(pxs) < 2:
                continue
            source_px = pxs[0][1]
            source = blender_pick(obj, mode, source_px)
            for index, px in pxs[1:13]:
                element = blender_pick(obj, mode, px)
                sample = dict(mode=mode, pick='path', px=list(px), sampled=[MODE_KIND[mode], index],
                              blender=element, source=source, source_px=list(source_px))
                if element is not None and source is not None:
                    for fill in (False, True):
                        to_edit(obj, mode)
                        with in_view():
                            bpy.ops.view3d.select(location=source_px)
                            r = bpy.ops.mesh.shortest_path_pick(index=any_index(obj, element), use_fill=fill)
                        sample['fill' if fill else 'reference'] = state(obj)
                        sample['result_fill' if fill else 'result'] = sorted(r)
                add(sample)
        # Select Linked under the pointer, with L's default Delimit for the
        # mode (none in Vertex and Edge mode, Seam in Face mode).
        for mode, pxs in (('VERT', vert_px), ('EDGE', edge_px), ('FACE', face_px)):
            for index, px in pxs[:6]:
                element = blender_pick(obj, mode, px)
                sample = dict(mode=mode, pick='linked', px=list(px), sampled=[MODE_KIND[mode], index],
                              blender=element)
                if element is not None:
                    to_edit(obj, mode)
                    delimit = {'SEAM'} if mode == 'FACE' else set()
                    bpy.ops.mesh.select_linked_pick(object_index=0, index=any_index(obj, element),
                                                    delimit=delimit)
                    sample['reference'] = state(obj)
                add(sample)
        bpy.ops.object.mode_set(mode='OBJECT')
        meshes.add(obj.data)
        obj.data.use_fake_user = True
        out['scenes'].append(scene)
        print(f"  measured {kind}: {len(scene['samples'])} picks, "
              f"{sum(1 for s in scene['samples'] if s['blender'] == s['sampled'])} of them where Blender's "
              "own click takes the element aimed at", flush=True)
    AREA.spaces.active.shading.show_xray = False
    bpy.data.libraries.write(LIBRARY_PATH, meshes, fake_user=True)
    with open(path, 'w') as f:
        json.dump(out, f)


# ---------------------------------------------------------------- apply

def blocks(path):
    out = {}
    for chunk in open(path).read().split("#-- ")[1:]:
        head, _, body = chunk.partition("\n")
        out[head.strip()] = body.rstrip("\n")
    return out


def run(source):
    try:
        exec(compile(source, "<app>", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return str(error).strip().replace("\n", " ")
    return None


def apply(scenes_path, calls_path):
    scenes = {s['name']: s for s in json.load(open(scenes_path))['scenes']}
    calls = blocks(calls_path)

    print("\nthe app's picks against Blender's own, at the same pixels of the same views")
    wrong_rules = {}
    for kind in KINDS:
        scene = scenes[kind]
        obj = make(kind)
        aim(kind)
        me = obj.data
        same_mesh = ([list(v.co) for v in me.vertices] == scene['vertices']
                     and [list(e.vertices) for e in me.edges] == scene['edges'])
        check(f"{kind}: rebuilt with the same vertices and edges, in the same order", same_mesh)
        bpy.ops.object.mode_set(mode='EDIT')
        tally = {}
        for sample in scene['samples']:
            sid = sample['id']
            if 'reference' not in sample or sid not in calls:
                continue
            key = f"{sample['pick']} {sample['mode']}"
            if sample.get('where') == 'off the middle':
                key += " off the middle"
            to_edit(obj, sample['mode'])
            error = run(calls[sid])
            got = state(obj)

            def same(a, b):
                # Everything, the active element included — or, where the
                # pointer is exactly between two faces' middles, the active
                # face either of them.
                if 'tie' not in sample:
                    return a == b
                return ({k: v for k, v in a.items() if k != 'active'}
                        == {k: v for k, v in b.items() if k != 'active'}) and a['active'] in sample['tie']
            ok = error is None and same(got, sample['reference'])
            tally.setdefault(key, [0, 0])
            tally[key][0] += ok
            tally[key][1] += 1
            if not ok:
                check(f"{kind} {key} at {sample['px']}: the app's {summary(got)} = Blender's "
                      f"{summary(sample['reference'])}", False, (error, got, sample['reference']))
            if 'again' in sample and ok:
                error = run(calls[sid])
                got = state(obj)
                tally.setdefault(key + " (a second click)", [0, 0])
                tally[key + " (a second click)"][0] += error is None and same(got, sample['again'])
                tally[key + " (a second click)"][1] += 1
            if sample['pick'] == 'path' and 'fill' in sample and (sid + "+fill") in calls:
                to_edit(obj, sample['mode'])
                error = run(calls[sid + "+fill"])
                got = state(obj)
                tally.setdefault(key + " Fill Region", [0, 0])
                tally[key + " Fill Region"][0] += error is None and got == sample['fill']
                tally[key + " Fill Region"][1] += 1
        for key in sorted(tally):
            good, total = tally[key]
            check(f"{kind}, {key}: {good} of {total} the same as Blender's own pick, the active element "
                  "included", total > 0 and good == total, f"{good}/{total}")
        # Two wrong rules for the active element, run off the middle: the
        # edge's first end always (Vertex mode), the edge's lower-numbered
        # face always (Face mode). Each has to disagree with Blender's result
        # somewhere, or these samples could not tell the invoke's rule from
        # it — at the middles alone the first would pass wherever rounding
        # favoured the first end.
        for prefix, mode in (("NEGV1", 'VERT'), ("NEGLOW", 'FACE')):
            for sample in scene['samples']:
                name = f"{prefix} {sample['id']}"
                if name not in calls or 'reference' not in sample:
                    continue
                to_edit(obj, mode)
                error = run(calls[name])
                got = state(obj)
                wrong_rules.setdefault(prefix, [0, 0])
                wrong_rules[prefix][0] += error is not None or got['active'] != sample['reference']['active']
                wrong_rules[prefix][1] += 1
        bpy.ops.object.mode_set(mode='OBJECT')

    print("\nthe negative controls")
    for prefix, label in (("NEGV1", "the edge's first end made active in Vertex mode"),
                          ("NEGLOW", "the edge's lower-numbered face made active in Face mode")):
        caught, total = wrong_rules.get(prefix, (0, 0))
        check(f"{label}, off the middle: caught at {caught} of {total} pixels", total > 0 and caught > 0,
              (caught, total))
    # 1. The multi-select the task proposed: the picked edge pushed as the
    # selection, then Select Loops' Edge Loops. In Face mode Alt+click walks
    # a face loop, and this does not.
    obj = make('grid')
    aim('grid')
    bpy.ops.object.mode_set(mode='EDIT')
    agree = total = 0
    for sample in scenes['grid']['samples']:
        if sample['pick'] != 'loop' or sample['mode'] != 'FACE' or 'reference' not in sample:
            continue
        to_edit(obj, 'FACE')
        bm = bmesh.from_edit_mesh(obj.data)
        bm.edges.ensure_lookup_table()
        e = bm.edges[sample['blender'][1]]
        e.select_set(True)
        bm.select_history.add(e)
        bm.select_flush_mode()
        bmesh.update_edit_mesh(obj.data)
        bpy.ops.mesh.select_edge_loop_multi()
        total += 1
        agree += state(obj) == sample['reference']
    check(f"a pushed edge and Edge Loops in Face mode disagree with Blender's Alt+click: {agree} of "
          f"{total} agree", total > 0 and agree < total, (agree, total))
    # 2. The far end of the edge made active instead of the near one.
    disagree = total = 0
    for name in sorted(n for n in calls if n.startswith("NEG ")):
        sid = name.split(" ", 1)[1]
        sample = next(s for s in scenes['grid']['samples'] if s['id'] == sid)
        to_edit(obj, 'VERT')
        error = run(calls[name])
        total += 1
        disagree += state(obj)['active'] != sample['reference']['active']
    check(f"an active vertex from the far end of the edge is caught: {disagree} of {total} differ",
          total > 0 and disagree == total, (disagree, total))
    # 3. A path with the source pushed but no selection order: refused.
    to_edit(obj, 'VERT')
    error = run(calls["PATH NO ORDER"])
    check("Pick Shortest Path after a push with no selection order is refused in words",
          error is not None and "nothing is active" in error, error)
    bpy.ops.object.mode_set(mode='OBJECT')

    print("\nwhat the picks refuse, in words")
    obj = make('grid')
    bpy.ops.object.mode_set(mode='EDIT')
    to_edit(obj, 'EDGE')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.edges.ensure_lookup_table()
    bm.edges[3].hide = True
    bmesh.update_edit_mesh(obj.data)
    error = run(calls["LOOP HIDDEN 3"])
    check("Loop Select on a hidden edge (Blender's exec returns CANCELLED)", error is not None and "hidden" in error, error)
    bpy.ops.mesh.reveal()
    to_edit(obj, 'EDGE')
    error = run(calls["LOOP STALE"])
    check("a pick made on a mesh Blender no longer has", error is not None and "changed after" in error, error)
    error = run(calls["LOOP PAST"])
    check("an edge past the mesh", error is not None and "no edge" in error, error)
    to_edit(obj, 'VERT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    bm.verts[0].select_set(True)
    bm.select_history.add(bm.verts[0])
    bmesh.update_edit_mesh(obj.data)
    error = run(calls["PATH FACE FROM VERTEX"])
    check("Pick Shortest Path to a face from an active vertex", error is not None and "is a vertex" in error, error)
    error = run(calls["LOOP NO VIEW"])
    check("Loop Select with no 3D View fails Blender's poll in words, and does not crash",
          error is not None and "view3d" in error.lower(), error)
    # Blender reads the undo argument as any int (`bpy_op_parse_args`:
    # PyBool_Check || PyLong_Check, then PyObject_IsTrue), and round 4's
    # review measured `1` past a guard that refused True only: Loop Select
    # segfaulted in ED_area_type_hud_ensure. If any of these reached Blender
    # this Blender would crash here and the check would fail with it.
    for undo_flag in ("True", "1", "2", "-1"):
        with in_view():
            error = run(f"bpy.ops.mesh.loop_select('EXEC_DEFAULT', {undo_flag}, object_index=0, edge_index=3)")
        check(f"a script's Loop Select with its undo on ({undo_flag}) inside the borrowed view is refused, "
              "not crashed", error is not None and "undo on" in error, error)
    with in_view():
        error = run("bpy.ops.mesh.loop_select('EXEC_DEFAULT', 0, object_index=0, edge_index=3)")
    check("with the undo off (0) it is Blender's own call", error is None, error)
    with in_view():
        error = run("bpy.ops.mesh.select_next_item('EXEC_DEFAULT', True)")
    check("so is a Python operator's (Select Next Element)", error is not None and "undo on" in error, error)
    # Looked up before the override and called inside it, which a guard
    # made at lookup time did not see: round 4's review measured
    # `op = bpy.ops.mesh.select_all`, then `op('EXEC_DEFAULT', True, ...)`
    # inside the borrowed view, crashing in ED_area_type_hud_ensure.
    for undo_flag in ("True", "1"):
        error = run("op = bpy.ops.mesh.select_all\n"
                    "import _blenderkit_context\n"
                    "with _blenderkit_context.temp_override_view3d('Probe'):\n"
                    f"    op('EXEC_DEFAULT', {undo_flag}, action='SELECT')")
        check(f"an operator looked up outside the borrowed view and called inside it with {undo_flag} is "
              "refused", error is not None and "undo on" in error, error)
    error = run("bpy.ops.mesh.select_linked_pick('EXEC_DEFAULT', True, object_index=0, index=3)")
    check("with no area in the context Select Linked's undo is Blender's (it ran there)", error is None, error)
    bpy.ops.object.mode_set(mode='OBJECT')
    # A sculpt stroke is not registered and is BLOCKING, and keeps its undo:
    # inside an area override the guard lets only unregistered BLOCKING
    # operators keep it (`refuse_undo_in_area`; measured: brush_stroke
    # {'BLOCKING'}), which is how the app itself calls the strokes.
    options = bpy.ops.sculpt.brush_stroke.bl_options
    check("the guard leaves the strokes alone (brush_stroke: BLOCKING, not REGISTER)",
          'REGISTER' not in options and 'BLOCKING' in options, options)

    print("\nSelect ▸ Select Linked ▸ Linked (Ctrl+L): Blender's first-press Delimit, by the select mode")
    linked = json.load(open(scenes_path))['linked_rows']
    obj = seam_grid()
    bpy.ops.object.mode_set(mode='EDIT')
    for mode in ('VERT', 'EDGE', 'FACE'):
        seed_left(obj, mode)
        error = run(calls["LINKED ROW " + mode])
        got = selected_vertices(obj)
        want = linked[mode]['vertices']
        check(f"{mode}: the row selects {got} vertices, Blender's own Ctrl+L {want}",
              error is None and got == want, (error, got, want))
    delimit = bpy.ops.mesh.select_linked.get_rna_type().properties['delimit']
    want = [[i.identifier, i.name, delimit.name] for i in delimit.enum_items]
    got = json.loads(calls["LINKED PANEL"])
    check(f"its panel's toggles are Blender's items under Blender's heading: {[g[1] for g in got]}",
          delimit.is_enum_flag and got == want, (got, want))
    # The negative control: the row as it was, Seam in every mode.
    seed_left(obj, 'VERT')
    error = run("bpy.ops.mesh.select_linked(delimit={'SEAM'})")
    got = selected_vertices(obj)
    check(f"the row as it was (Seam in every mode) selects {got} in Vertex mode, not Blender's "
          f"{linked['VERT']['vertices']}", error is None and got != linked['VERT']['vertices'], (error, got))
    bpy.ops.object.mode_set(mode='OBJECT')

    print("\nBox Select over what is selected: the app pushes when Blender's own box finishes")
    obj = make('grid')
    aim('grid')
    bpy.ops.object.mode_set(mode='EDIT')
    old_wrong = []
    for case in scenes['grid']['region_sets']:
        # The negative control: the rule as it was pushed nothing whenever
        # the elements matched, which leaves the start as it was seeded.
        seeded_active = [0, case['seed'][-1]] if case['ordered'] and case['seed'] else None
        if calls["REGION " + case['name'] + " OLD"] == "False" and seeded_active != case['after']['active']:
            old_wrong.append(case['name'])
        to_edit(obj, 'VERT')
        bm = bmesh.from_edit_mesh(obj.data)
        bm.verts.ensure_lookup_table()
        for i in case['seed']:
            bm.verts[i].select_set(True)
            if case['ordered']:
                bm.select_history.add(bm.verts[i])
        bmesh.update_edit_mesh(obj.data)
        name = "REGION " + case['name']
        pushes = calls[name + " CHANGES"] == "True"
        blender_finished = 'FINISHED' in case['result']
        error = run(calls[name]) if pushes else None
        got = state(obj)
        check(f"{case['name']}: Blender {case['result']}, the app {'pushes' if pushes else 'pushes nothing'}; "
              f"after, active {got['active']} (Blender's {case['after']['active']})",
              error is None and pushes == blender_finished and got == case['after'],
              (error, pushes, case['result'], got, case['after']))
    check(f"the rule as it was (the elements alone) keeps an active element Blender's box drops: {old_wrong}",
          old_wrong == ['set same, ordered'], old_wrong)
    bpy.ops.object.mode_set(mode='OBJECT')

    print("\nSide of Active's aimed view is left when aiming fails")
    obj = make('grid')
    bpy.ops.object.mode_set(mode='EDIT')
    saved = RV3D.view_rotation.copy()
    real_aim = select.aimed_view._aim

    def failing(self, *a):
        # Turn the view, then fail, as anything after the override's entry
        # could (round 4's review: an exception there left the override
        # entered for the rest of the script; measured with an `up` of two
        # numbers, `bpy.context.area` still VIEW_3D after the failed `with`).
        self._region = AREA.spaces.active.region_3d
        self._rotation = self._region.view_rotation.copy()
        self._region.view_rotation = Quaternion((0.5, 0.5, 0.5, 0.5))
        raise ValueError("aiming failed")
    select.aimed_view._aim = failing
    try:
        with select.aimed_view('Side of Active', forward=(0.0, 0.0, -1.0), up=(0.0, 1.0, 0.0)):
            pass
        raised = None
    except ValueError as e:
        raised = str(e)
    finally:
        select.aimed_view._aim = real_aim
    check(f"the failure is raised ({raised}), the override is left (area {bpy.context.area}) and the view "
          "turned back", raised == "aiming failed" and bpy.context.area is None
          and (RV3D.view_rotation - saved).magnitude < 1e-6, (raised, bpy.context.area))
    error = run("import _blenderkit_select\n"
                "with _blenderkit_select.aimed_view('Side of Active', forward=(0.0, 0.0, -1.0), up=(0.0, 1.0)):\n"
                "    pass")
    check("a direction of two numbers is refused before the view is borrowed",
          error is not None and "three numbers" in error and bpy.context.area is None, (error, bpy.context.area))
    bpy.ops.object.mode_set(mode='OBJECT')

    print("\nthe selection order: pushed as a tap leaves it, read back as the mirror reads it")
    obj = make('grid')
    bpy.ops.object.mode_set(mode='EDIT')
    to_edit(obj, 'VERT')
    error = run(calls["PUSH ORDER"])
    bm = bmesh.from_edit_mesh(obj.data)
    want = json.loads(calls["PUSH ORDER WANT"])
    got = [[0 if isinstance(e, bmesh.types.BMVert) else 1 if isinstance(e, bmesh.types.BMEdge) else 2, e.index]
           for e in bm.select_history]
    check(f"the push leaves Blender's order {got}", error is None and got == want, (error, got, want))
    raw = select.history_bytes(bm)
    import array
    pairs = array.array('i')
    pairs.frombytes(raw)
    check(f"and the mirror reads it back the same: {list(pairs)}", list(pairs) == [x for p in want for x in p],
          list(pairs))
    error = run(calls["MENU nextActive"])
    s = state(obj)
    check(f"Next Active walks on from the two: {summary(s)}, active {s['active']}",
          error is None and len(s['v']) == 3 and s['active'] == [0, 2], (error, s))
    error = run(calls["MENU previousActive"])
    s = state(obj)
    check(f"Previous Active takes it back: {summary(s)}, active {s['active']}",
          error is None and len(s['v']) == 2 and s['active'] == [0, 1], (error, s))
    to_edit(obj, 'VERT')
    error = run(calls["MENU nextActive"])
    check("Next Active with no order says why instead of a silent FINISHED",
          error is not None and "two" in error, error)
    error = run(calls["MENU previousActive"])
    check("so does Previous Active", error is not None and "Tap an element" in error, error)
    centre = min(range(len(obj.data.vertices)), key=lambda i: obj.data.vertices[i].co.length)
    to_edit(obj, 'VERT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    bm.verts[centre].select_set(True)
    bm.select_history.add(bm.verts[centre])
    bmesh.update_edit_mesh(obj.data)
    error = run(calls["MENU sideOfActive"])
    s = state(obj)
    check(f"Side of Active from the centre, +X: {summary(s)} (the 4 columns at x >= 0)",
          error is None and len(s['v']) == 28, (error, summary(s)))
    to_edit(obj, 'VERT')
    error = run(calls["MENU sideOfActive"])
    check("Side of Active with no active vertex says why", error is not None and "active vertex" in error, error)
    # The View axis, aimed as the app looks: from the front (-Y), X of the
    # view is the world's X; from the right (+X), it is the world's Y.
    to_edit(obj, 'VERT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    corner = min(range(len(bm.verts)), key=lambda i: bm.verts[i].co.x + 2 * bm.verts[i].co.y)
    bm.verts[corner].select_set(True)
    bm.select_history.add(bm.verts[corner])
    bmesh.update_edit_mesh(obj.data)
    saved = RV3D.view_rotation.copy()
    error = run(calls["MENU sideOfActive VIEW right"])
    s = state(obj)
    check(f"Side of Active, Axis Mode View, the view looking from +X: {summary(s)} (all 49 above the "
          "bottom-left corner's row... every vertex with y >= its y)",
          error is None and len(s['v']) == 49, (error, summary(s)))
    check("and the borrowed view's rotation is put back", (RV3D.view_rotation - saved).magnitude < 1e-6)
    to_edit(obj, 'VERT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    mid = [i for i, v in enumerate(bm.verts) if abs(v.co.x) < 1e-4 and abs(v.co.y) < 1e-4][0]
    bm.verts[mid].select_set(True)
    bm.select_history.add(bm.verts[mid])
    bmesh.update_edit_mesh(obj.data)
    error = run(calls["MENU sideOfActive VIEW right"])
    s = state(obj)
    view_y = sorted({round(obj.data.vertices[i].co.y, 3) for i in s['v']})
    check(f"from the centre, looking from +X, the view's X is the world's Y: y in {view_y}",
          error is None and len(s['v']) == 28 and min(view_y) >= -1e-3, (error, view_y))
    to_edit(obj, 'VERT')
    error = run(calls["MENU byAttribute"])
    check("By Attribute with no active attribute passes Blender's poll words through",
          error is not None and "active attribute" in error, error)
    bpy.ops.object.mode_set(mode='OBJECT')

    print("\nSelect Grouped, its exec type by type (Blender's own operator fails its poll without an interface)")
    check("Blender's own select_grouped refuses to run here", not bpy.ops.object.select_grouped.poll())
    clear_scene()
    coll_a = bpy.data.collections.new("A")
    bpy.context.scene.collection.children.link(coll_a)
    def add_cube(name, loc, parent=None, coll=None, color=None, pass_index=0):
        bpy.ops.mesh.primitive_cube_add(location=loc, size=0.5)
        o = bpy.context.object
        o.name = name
        o.parent = parent
        if coll is not None:
            for c in list(o.users_collection):
                c.objects.unlink(o)
            coll.objects.link(o)
        if color:
            o.color = color
        o.pass_index = pass_index
        return o
    root = add_cube("Root", (0, 0, 0), color=(1, 0, 0, 1), pass_index=3)
    kid1 = add_cube("Kid1", (1, 0, 0), parent=root, color=(1, 0.004, 0, 1))
    kid2 = add_cube("Kid2", (2, 0, 0), parent=root, coll=coll_a, pass_index=3)
    grand = add_cube("Grand", (3, 0, 0), parent=kid1, coll=coll_a)
    loner = add_cube("Loner", (4, 0, 0), coll=coll_a, color=(1, 0.002, 0.003, 1))
    bpy.ops.object.light_add(type='POINT', location=(0, 3, 0))
    bpy.context.object.name = "Point"
    bpy.ops.object.light_add(type='SUN', location=(0, 4, 0))
    bpy.context.object.name = "Sun"
    bpy.ops.object.light_add(type='POINT', location=(0, 5, 0))
    bpy.context.object.name = "Point2"
    bpy.ops.object.empty_add(location=(5, 0, 0))
    hook_target = bpy.context.object
    hook_target.name = "HookTarget"
    hook = loner.modifiers.new("Hook", 'HOOK')
    hook.object = hook_target

    def pick(*names):
        for o in bpy.context.view_layer.objects:
            o.select_set(o.name in names)
        bpy.context.view_layer.objects.active = bpy.data.objects[names[0]] if names else None

    def sel():
        return sorted(o.name for o in bpy.context.view_layer.objects if o.select_get())

    cases = [
        ("CHILDREN_RECURSIVE", ["Root"], ["Grand", "Kid1", "Kid2"]),
        ("CHILDREN", ["Root"], ["Kid1", "Kid2"]),
        ("PARENT", ["Grand"], ["Kid1"]),
        ("SIBLINGS", ["Kid1"], ["Kid1", "Kid2"]),
        ("TYPE", ["Point"], ["Point", "Point2", "Sun"]),
        ("COLLECTION", ["Kid2"], ["Grand", "Kid2", "Loner"]),
        ("HOOK", ["Loner"], ["HookTarget"]),
        ("PASS", ["Root"], ["Kid2", "Root"]),
        ("COLOR", ["Root"], ["Kid1", "Loner", "Root"]),
        ("LIGHT_TYPE", ["Point"], ["Point", "Point2"]),
    ]
    for ident, seed, want in cases:
        pick(*seed)
        error = run(calls["GROUPED " + ident])
        got = sel()
        check(f"{ident}: from {seed} -> {got}", error is None and got == want, (error, got, want))
    pick("Grand")
    run(calls["GROUPED PARENT"])
    check("Parent makes the parent active, as select_grouped_parent does",
          bpy.context.view_layer.objects.active.name == "Kid1")
    pick("Root", "Sun")
    error = run(calls["GROUPED CHILDREN extend"])
    check(f"Extend keeps what was selected: {sel()}", error is None and sel() == ["Kid1", "Kid2", "Root", "Sun"],
          (error, sel()))
    pick("Loner")
    error = run(calls["GROUPED CHILDREN"])
    check("Children of an object with none: Blender's Deselect All still changed the selection, so "
          "it finishes (the exec's `changed`) with nothing selected", error is None and sel() == [],
          (error, sel()))
    pick("Loner")
    error = run(calls["GROUPED CHILDREN extend"])
    check("with Extend there is nothing to change: refused in words, selection unchanged",
          error is not None and "grouped" in error and sel() == ["Loner"], (error, sel()))
    pick("Root")
    error = run(calls["GROUPED LIGHT_TYPE"])
    check("Light Type from a mesh: Blender's words, before anything is deselected",
          error is not None and "must be a light" in error and sel() == ["Root"], (error, sel()))
    error = run(calls["GROUPED KEYINGSET"])
    check("Keying Set with none active: Blender's words", error is not None and "Keying Set" in error
          and sel() == ["Root"], (error, sel()))
    coll_b = bpy.data.collections.new("B")
    bpy.context.scene.collection.children.link(coll_b)
    coll_b.objects.link(kid2)
    pick("Kid2")
    error = run(calls["GROUPED COLLECTION"])
    check("Collection with the active object in two: refused naming them (Blender asks in a menu)",
          error is not None and "2 collections" in error and sel() == ["Kid2"], (error, sel()))
    pick()
    bpy.context.view_layer.objects.active = None
    error = run(calls["GROUPED TYPE"])
    check("with nothing active: refused before anything changes", error is not None and "active" in error, error)
    # The Keying Set type with one that has paths.
    ks = bpy.context.scene.keying_sets.new(idname="KS", name="KS")
    ks.paths.add(bpy.data.objects["Kid2"], "location")
    ks.paths.add(bpy.data.objects["Loner"], "location")
    bpy.context.scene.keying_sets.active = ks
    pick("Root")
    error = run(calls["GROUPED KEYINGSET"])
    check(f"Keying Set selects what its paths name: {sel()}", error is None and sel() == ["Kid2", "Loner"],
          (error, sel()))

    print("\nthe Object Mode rows with their redo panels still refuse as before")
    pick("Kid1")
    error = run(calls["OBJECT child"])
    check(f"Child through the redo panel's call: {sel()}", error is None and sel() == ["Grand"], (error, sel()))
    pick("Grand")
    error = run(calls["OBJECT child"])
    check("Child with no child says so, selection unchanged", error is not None and "child" in error
          and sel() == ["Grand"], (error, sel()))
    error = run(calls["OBJECT random"])
    first = sel()
    error2 = run(calls["OBJECT random"])
    check("Select Random twice with the same seed: the second refused", error is None and error2 is not None
          and "changed nothing" in error2 and sel() == first, (error, error2))


# The measured meshes, beside the measurements: measure writes them and
# apply appends them (`make`).
LIBRARY_PATH = os.path.join(os.path.dirname(os.path.abspath(argv[1])), "selectpick-meshes.blend")
if PHASE == 'measure':
    if os.path.exists(LIBRARY_PATH):
        os.remove(LIBRARY_PATH)
    measure(argv[1])
else:
    LIBRARY = LIBRARY_PATH
    apply(argv[1], argv[2])
print(f"\n{fail} FAILED" if fail else "\nALL PASS")
sys.exit(1 if fail else 0)
