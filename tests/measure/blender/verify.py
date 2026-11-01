"""The Cursor tool, the ruler and Edit Mode's measurements held to Blender
itself (desktop 5.2.1, with the app's context: its undo history through
`_blenderkit_undo`, gpu.init(), its modules and operator guards).

    verify.py measure <scenes.json>
        Blender's own `view3d.cursor3d` invoke — run with a made event through
        `WM_operator_name_call_with_properties` inside an operator, as the
        meshmenu check runs `dupli_extrude_cursor` — at pixels of a set of
        fixtures and views, for each Surface Project and Orientation and the
        cursor's rotation modes; the fixtures' evaluated meshes and the view,
        for the Swift (tests/measure/blender/main.swift); and the edit meshes
        the ruler and the overlays are measured on.

    verify.py apply <scenes.json> <calls.txt>
        The app's calls (`_blenderkit_cursor.place` with the hits the Swift
        worked out on the mirror) run on the same fixtures and held to
        Blender's result; that no undo step is pushed and Blender's undo keeps
        the cursor; the drag's `transform.translate`; the unit strings the
        Swift made against Blender's own `BKE_unit_value_as_string(_scaled)`;
        the ruler's snapped points against Blender's evaluated geometry; the
        overlays' numbers against bmesh's own and the strings against
        Blender's C. Each with a negative control.
"""
import bpy, bmesh, gpu, sys, os, json, ctypes, importlib.util, pathlib, types, math

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

from mathutils import Vector, Matrix, Quaternion, Euler

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
argv = sys.argv[sys.argv.index("--") + 1:]
PHASE = argv[0]
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
load("_blenderkit_orient")
cursor_mod = load("_blenderkit_cursor")
measure_mod = load("_blenderkit_measure")
gpu.init()
WORK = os.environ.get("BK_WORK", "/tmp")
undo.push(os.path.join(WORK, "history"), "start")


# --------------------------------------------------------------------------
# Blender's own invoke with a made event

lib = ctypes.CDLL(None)
_call = getattr(lib, "_ZN7blender37WM_operator_name_call_with_propertiesEPNS_8bContextEPKcNS_2wm"
                     "13OpCallContextEPNS_10IDPropertyEPKNS_7wmEventE")
_call.restype = ctypes.c_int
_call.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int8, ctypes.c_void_p, ctypes.c_void_p]
INVOKED = {}


class BK_OT_invoke_at(bpy.types.Operator):
    """Runs Blender's own invoke of `opname` with the pointer at window pixel
    (x, y) — a wmEvent made here (5.2.1's layout: xy at byte 20) — and the
    properties as an IDProperty group. Inside this operator Blender's
    `op_undo_depth` is raised, so the invoked one is neither registered nor
    given a redo panel (the `ED_area_type_hud_ensure` crash class)."""
    bl_idname = "bk.invoke_at"
    bl_label = "Invoke at"
    bl_options = {'INTERNAL'}
    opname: bpy.props.StringProperty()
    x: bpy.props.IntProperty()
    y: bpy.props.IntProperty()
    props: bpy.props.StringProperty()

    def execute(self, context):
        event = (ctypes.c_ubyte * 1024)()
        ctypes.c_int32.from_buffer(event, 20).value = self.x
        ctypes.c_int32.from_buffer(event, 24).value = self.y
        holder = context.scene
        holder["_bk_props"] = json.loads(self.props)
        group = holder["_bk_props"]
        # BPy_IDProperty: PyObject_HEAD (16 bytes), owner_id, then prop.
        prop = ctypes.c_void_p.from_address(id(group) + 24).value
        INVOKED['ret'] = _call(context.as_pointer(), self.opname.encode(), 1, prop, ctypes.addressof(event))
        del holder["_bk_props"]
        return {'FINISHED'}


bpy.utils.register_class(BK_OT_invoke_at)
ORIENT_VALUE = {"NONE": 0, "VIEW": 1, "XFORM": 2, "GEOM": 3}


# --------------------------------------------------------------------------
# Fixtures

def clear():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)


def mesh_object(name, make, matrix):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    make(bm)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    o.matrix_world = matrix
    return o


def cube(bm):
    bmesh.ops.create_cube(bm, size=2.0)


def sphere(bm):
    bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=8, radius=1.0)


def grid(bm):
    bmesh.ops.create_grid(bm, x_segments=6, y_segments=6, size=1.5)


def build(kind):
    """The fixture `kind`, with its active object, mode and selection."""
    clear()
    R = Matrix.Rotation
    if kind == 'turned':
        a = mesh_object('Cube', cube, Matrix.Translation((0.2, 0.1, 0.3)) @ R(0.5, 4, 'Z') @ R(0.2, 4, 'Y')
                        @ R(0.3, 4, 'X'))
        b = mesh_object('Sphere', sphere, Matrix.Translation((2.6, 1.0, 0.4)))
        active = a
    elif kind == 'mirrored':
        # A negative scale: the face normal Blender reports is the object's
        # normal carried by the inverse transpose, not the world cross product.
        a = mesh_object('Cube', cube, Matrix.Translation((0.0, 0.3, 0.2)) @ R(0.4, 4, 'Z')
                        @ Matrix.Diagonal((-1.0, 1.5, 0.8, 1.0)))
        active = a
    elif kind == 'wire':
        # The sphere in front is drawn as wire: Blender's snap ray passes
        # through it to the cube behind.
        a = mesh_object('Cube', cube, Matrix.Translation((0.0, 0.0, 0.0)))
        b = mesh_object('Sphere', sphere, Matrix.Translation((0.3, -1.6, 0.2)) @ Matrix.Diagonal((0.7, 0.7, 0.7, 1)))
        b.display_type = 'WIRE'
        active = a
    elif kind == 'subsurf':
        # Edit Mode under a Subdivision Surface: the drawn surface is the
        # final mesh, which Blender's cursor meets.
        a = mesh_object('Cube', cube, R(0.3, 4, 'Z'))
        md = a.modifiers.new('Subdivision', 'SUBSURF')
        md.levels = 2
        active = a
    elif kind == 'edit_hidden':
        a = mesh_object('Grid', grid, R(0.6, 4, 'X'))
        active = a
    else:
        raise ValueError(kind)
    bpy.context.view_layer.update()
    for o in bpy.context.scene.objects:
        o.select_set(o == active)
    bpy.context.view_layer.objects.active = active
    if kind in ('subsurf', 'edit_hidden'):
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='DESELECT')
        bm = bmesh.from_edit_mesh(active.data)
        bm.faces.ensure_lookup_table()
        if kind == 'edit_hidden':
            # Six faces hidden, one face selected.
            for f in bm.faces[10:16]:
                f.hide_set(True)
            bm.faces[20].select_set(True)
        else:
            bm.faces[1].select_set(True)
        bmesh.update_edit_mesh(active.data)
    bpy.context.view_layer.update()
    return active


FIXTURES = ['turned', 'mirrored', 'wire', 'subsurf', 'edit_hidden']


def aim(view):
    """The borrowed 3D View, looking as `view` says: the meshmenu check's way."""
    rv3d = bpy.context.area.spaces.active.region_3d
    forward = Vector(view['forward']).normalized()
    z = -forward
    up = Vector(view['up'])
    y = (up - z * up.dot(z)).normalized()
    rv3d.view_perspective = 'ORTHO' if view['ortho'] else 'PERSP'
    rv3d.view_rotation = Matrix((y.cross(z), y, z)).transposed().to_quaternion()
    rv3d.view_distance = view.get('distance', 10.0)
    rv3d.view_location = Vector(view['eye']) + forward * rv3d.view_distance
    if view.get('axis'):
        rv3d.is_orthographic_side_view = True
    rv3d.update()
    return rv3d


VIEWS = [
    dict(name='persp', eye=(4.5, -8.0, 4.0), forward=(-4.5, 8.0, -4.0), up=(0, 0, 1), ortho=False),
    dict(name='close', eye=(1.5, -3.6, 2.4), forward=(-1.6, 3.4, -2.6), up=(0, 0, 1), ortho=False),
    dict(name='ortho', eye=(-6.0, -7.0, 5.0), forward=(6.0, 7.0, -5.0), up=(0, 0, 1), ortho=True),
    dict(name='front', eye=(0.0, -10.0, 0.0), forward=(0.0, 1.0, 0.0), up=(0, 0, 1), ortho=True, axis=True),
]


def view_record(rv3d, region):
    vi = rv3d.view_matrix.inverted()
    return dict(persmat=[list(r) for r in rv3d.perspective_matrix], size=[region.width, region.height],
                eye=list(vi.translation), x=list(vi.col[0].xyz), y=list(vi.col[1].xyz), z=list(vi.col[2].xyz),
                ortho=not rv3d.is_perspective, center=list(rv3d.view_location),
                axis=bool(rv3d.is_orthographic_side_view), rotation=list(rv3d.view_rotation))


def scene_meshes():
    """Every object as the mirror sends it: the evaluated mesh, its loop
    triangles (hidden faces left out in Edit Mode, as `_unhidden_triangles`
    leaves them), its matrix and display type."""
    out = []
    dg = bpy.context.evaluated_depsgraph_get()
    for o in bpy.context.view_layer.objects:
        if o.type != 'MESH' or not o.visible_get():
            continue
        editing = o.mode == 'EDIT'
        if editing:
            o.update_from_editmode()
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        hidden = [p.hide for p in me.polygons] if editing else None
        kept = [t for t in me.loop_triangles if not (hidden and hidden[t.polygon_index])]
        tris = [list(t.vertices) for t in kept]
        # The face corner behind each triangle corner, which the mirror sends
        # with the UV map (`_push_uvs`) and GeometrySnap tells a quad's
        # diagonal by (`UVUnwrap.diagonals`).
        loops = [list(t.loops) for t in kept]
        # The mirror's mesh is not the edit mesh: a modifier rebuilt it
        # (`editRegionRefusal` on device; here, by its counts).
        rebuilt = editing and len(me.vertices) != len(bmesh.from_edit_mesh(o.data).verts)
        # The mirror's `|subdivlast` (`_blenderkit_sync._kind`): in Edit Mode
        # under a last Subdivision Surface, Blender's snap meets the mesh
        # before it, and the app refuses Geometry there.
        subdivlast = editing and cursor_mod.subdivides_last(o) is not None
        out.append(dict(name=o.name, matrix=[list(r) for r in o.matrix_world],
                        vertices=[list(v.co) for v in me.vertices], triangles=tris, loops=loops,
                        display=o.display_type, rebuilt=rebuilt, subdivlast=subdivlast))
        ev.to_mesh_clear()
    return out


CURSORS = [
    dict(name='euler', location=(0.5, -0.5, 2.0), mode='XYZ', rotation=(0.1, 0.2, 0.3)),
    dict(name='quat', location=(-0.4, 0.3, 1.1), mode='QUATERNION', rotation=(0.9, 0.1, -0.3, 0.2)),
    dict(name='axisangle', location=(0.2, 0.4, -0.6), mode='AXIS_ANGLE', rotation=(0.7, 0.2, 0.9, -0.1)),
    dict(name='zyx', location=(0.0, 0.0, 0.0), mode='ZYX', rotation=(-0.4, 0.6, 1.1)),
]


def set_cursor(c, behind=None):
    cur = bpy.context.scene.cursor
    cur.rotation_mode = c['mode']
    if c['mode'] == 'QUATERNION':
        cur.rotation_quaternion = c['rotation']
    elif c['mode'] == 'AXIS_ANGLE':
        cur.rotation_axis_angle = c['rotation']
    else:
        cur.rotation_euler = c['rotation']
    cur.location = behind if behind is not None else c['location']


def cursor_state():
    cur = bpy.context.scene.cursor
    return dict(location=list(cur.location), euler=list(cur.rotation_euler),
                quat=list(cur.rotation_quaternion), axis_angle=list(cur.rotation_axis_angle),
                mode=cur.rotation_mode)


SETTINGS = [(d, o) for d in (False, True) for o in ('NONE', 'VIEW', 'XFORM', 'GEOM')]

# A Blender with no window draws a 3D View's depth buffer for the first
# Surface Project click and never again: `ED_view3d_depth_override` sets
# V3D_RUNTIME_DEPTHBUF_OVERRIDDEN and returns early while it is set, and only
# the region's own draw (view3d_main_region_draw, which never runs headless)
# clears it. Measured: after a sphere in front of the cube was turned from
# Wire to Solid, the next click still landed on the cube. So the measure
# phase finds that flag in the View3D — the one int of its memory the first
# depth draw changes, from v to v | 2 — and clears it before every click.
DEPTH_FLAG = {}


def fresh_depth(space, invoke):
    """Runs `invoke` (a Surface Project click) with the depth buffer redrawn."""
    addr = space.as_pointer()
    if 'offset' not in DEPTH_FLAG:
        before = bytes((ctypes.c_ubyte * 8192).from_address(addr))
        invoke()
        after = bytes((ctypes.c_ubyte * 8192).from_address(addr))
        changed = [(o, int.from_bytes(before[o:o + 4], 'little'), int.from_bytes(after[o:o + 4], 'little'))
                   for o in range(0, 8188, 4) if before[o:o + 4] != after[o:o + 4]]
        flags = [o for o, a, b in changed if a & 2 == 0 and b == a | 2]
        if len(changed) != 1 or len(flags) != 1:
            raise RuntimeError("the View3D's depth flag was not found: %r" % changed)
        DEPTH_FLAG['offset'] = flags[0]
        return
    flag = ctypes.c_int32.from_address(addr + DEPTH_FLAG['offset'])
    flag.value = flag.value & ~2
    invoke()
ORIENTATION_SLOTS = {'turned': 'LOCAL', 'mirrored': 'GLOBAL', 'wire': 'VIEW', 'subsurf': 'NORMAL',
                     'edit_hidden': 'NORMAL'}


def pixels(region, rv3d, objects):
    """Pixels to measure at: over each object's middle and around it, near
    its silhouette, and in empty space."""
    from bpy_extras import view3d_utils
    out = set()
    for o in objects:
        c = o.matrix_world.translation
        m = view3d_utils.location_3d_to_region_2d(region, rv3d, c)
        if m is None:
            continue
        for dx, dy in ((0, 0), (17, 9), (-23, 14), (31, -26), (-48, -35), (64, 3), (5, 71)):
            x, y = int(m.x) + dx, int(m.y) + dy
            if 0 <= x < region.width and 0 <= y < region.height:
                out.add((x, y))
    out.add((40, 40))
    out.add((region.width - 60, region.height - 50))
    return sorted(out)


# --------------------------------------------------------------------------
# Edit Mode's overlays

UNIT_CASES = [
    dict(system='METRIC', system_rotation='DEGREES', scale_length=1.0, length_unit='METERS', use_separate=False),
    dict(system='METRIC', system_rotation='RADIANS', scale_length=0.01, length_unit='CENTIMETERS',
         use_separate=False),
    dict(system='METRIC', system_rotation='DEGREES', scale_length=1.0, length_unit='ADAPTIVE', use_separate=True),
    dict(system='IMPERIAL', system_rotation='DEGREES', scale_length=1.0, length_unit='FEET', use_separate=True),
    dict(system='NONE', system_rotation='DEGREES', scale_length=1.0, length_unit='ADAPTIVE', use_separate=False),
]


def set_units(case):
    u = bpy.context.scene.unit_settings
    u.system = case['system']
    u.system_rotation = case['system_rotation']
    u.scale_length = case['scale_length']
    if case['system'] != 'NONE':
        u.length_unit = case['length_unit']
    u.use_separate = case['use_separate']


def overlay_fixture(kind):
    """An object in Edit Mode with a selection to measure."""
    clear()
    if kind == 'cube':
        # Scaled unevenly and turned, so Global and Local differ.
        o = mesh_object('Cube', cube, Matrix.Translation((0.5, 0.2, 0.1)) @ Matrix.Rotation(0.4, 4, 'Z')
                        @ Matrix.Diagonal((1.0, 2.0, 0.5, 1.0)))
        sel = 'faces:0,1,3'
    elif kind == 'warped':
        # A grid with its corners lifted: non-planar quads, whose area Blender
        # sums over the tessellation and `BMFace.calc_area` does not.
        def warped(bm):
            bmesh.ops.create_grid(bm, x_segments=4, y_segments=4, size=1.0)
            for v in bm.verts:
                v.co.z = 0.3 * v.co.x * v.co.y + 0.2 * v.co.x * v.co.x
        o = mesh_object('Warped', warped, Matrix.Rotation(0.3, 4, 'X'))
        sel = 'all'
    else:
        def ngon(bm):
            verts = [bm.verts.new((math.cos(a) * r, math.sin(a) * r, 0.1 * math.sin(3 * a)))
                     for a, r in ((i * math.tau / 7, 1.0 + 0.3 * (i % 2)) for i in range(7))]
            bm.faces.new(verts)
            bmesh.ops.extrude_face_region(bm, geom=list(bm.faces))
        o = mesh_object('Ngon', ngon, Matrix.Translation((0, 0, 0.4)) @ Matrix.Diagonal((1.5, 1.0, 1.0, 1.0)))
        sel = 'all'
    bpy.context.view_layer.update()
    for x in bpy.context.scene.objects:
        x.select_set(x == o)
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='DESELECT')
    bm = bmesh.from_edit_mesh(o.data)
    bm.faces.ensure_lookup_table()
    if sel == 'all':
        for f in bm.faces:
            f.select_set(True)
    else:
        for i in sel.split(':')[1].split(','):
            bm.faces[int(i)].select_set(True)
    bm.select_flush(True)
    bmesh.update_edit_mesh(o.data)
    return o


OVERLAY_FIXTURES = ['cube', 'warped', 'ngon']


def measure_overlays():
    out = []
    for kind in OVERLAY_FIXTURES:
        for use_global in (False, True):
            overlay_fixture(kind)
            out.append(dict(fixture=kind, use_global=use_global,
                            record=measure_mod.edit_overlay(stats=True, edge_length=True, edge_angle=True,
                                                            face_area=True, face_angle=True,
                                                            use_global=use_global)))
    bpy.ops.object.mode_set(mode='OBJECT')
    return dict(cases=out, units=UNIT_CASES)


def measure(path):
    scenes = []
    for kind in FIXTURES:
        for view in VIEWS:
            active = build(kind)
            bpy.context.scene.transform_orientation_slots[0].type = ORIENTATION_SLOTS[kind]
            with context.temp_override_view3d("check"):
                region = bpy.context.region
                rv3d = aim(view)
                vrec = view_record(rv3d, region)
                objects = [o for o in bpy.context.view_layer.objects if o.visible_get()]
                pts = pixels(region, rv3d, objects)
                samples = []
                for (x, y) in pts:
                    for ci, c in enumerate(CURSORS):
                        # One cursor per pixel, in turn, and the euler one
                        # behind the view at the first pixel (the flip).
                        if (x + y + ci) % 2:
                            continue
                        for use_depth, orient in SETTINGS:
                            for behind in ([None, list(Vector(vrec['eye']) - Vector(vrec['z']) * -3.0)]
                                           if (ci == 0 and not vrec['ortho']) else [None]):
                                set_cursor(c, behind)

                                def invoke():
                                    bpy.ops.bk.invoke_at('EXEC_DEFAULT', opname="VIEW3D_OT_cursor3d",
                                                         x=region.x + x, y=region.y + y,
                                                         props=json.dumps({"use_depth": use_depth,
                                                                           "orientation": ORIENT_VALUE[orient]}))
                                if use_depth:
                                    fresh_depth(bpy.context.area.spaces.active, invoke)
                                else:
                                    invoke()
                                samples.append(dict(px=[x, y], cursor=ci, behind=behind, use_depth=use_depth,
                                                    orientation=orient, ret=INVOKED.get('ret'),
                                                    blender=cursor_state()))
            scenes.append(dict(fixture=kind, view=view['name'], view_in=view, region=vrec,
                               meshes=scene_meshes(), samples=samples))
    with open(path, 'w') as f:
        json.dump(dict(scenes=scenes, cursors=CURSORS, overlays=measure_overlays()), f)
    total = sum(len(s['samples']) for s in scenes)
    print("  measured %d invokes of Blender's own Cursor tool over %d fixtures and views" % (total, len(scenes)))
    check("Blender's own cursor3d answered FINISHED | PASS_THROUGH (12) every time",
          all(s['ret'] == 12 for sc in scenes for s in sc['samples']),
          {s['ret'] for sc in scenes for s in sc['samples']})


# --------------------------------------------------------------------------

def blocks(path):
    out = {}
    for b in open(path).read().split("#--"):
        b = b.strip()
        if b:
            head, _, body = b.partition("\n")
            out[head.strip()] = body
    return out


def same_rotation(a, b, mode, eps):
    """The cursor's rotation as stored, compared in the stored form — an
    axis and angle as the rotation they make: at an angle of nought float
    noise in a cross product's sign gives 2π for 0 (`angle_signed_on_axis_v3v3_v3`
    on an axis view), the same rotation, which Blender's own tool would show
    either way."""
    if mode == 'QUATERNION':
        return max(abs(p - q) for p, q in zip(a['quat'], b['quat'])) <= eps
    if mode == 'AXIS_ANGLE':
        qa = Quaternion(Vector(a['axis_angle'][1:]).normalized(), a['axis_angle'][0])
        qb = Quaternion(Vector(b['axis_angle'][1:]).normalized(), b['axis_angle'][0])
        return min(max(abs(p - q) for p, q in zip(qa, qb)), max(abs(p + q) for p, q in zip(qa, qb))) <= eps
    return max(abs(p - q) for p, q in zip(a['euler'], b['euler'])) <= eps


MISSES = []
wire_edges = [0]
vertex_ties = [0]


def through_vertex(call, meshes):
    """Whether the surface the app's call carries lies within a pixel of a
    vertex of the fixture's evaluated meshes."""
    if "surface=((" not in call:
        return False
    at = call.split("surface=((", 1)[1].split(")", 1)[0]
    return near_vertex([float(v) for v in at.split(",")], meshes)


def near_vertex(p, meshes, within=0.015):
    """Whether `p` is within a pixel (9 mm across the orthographic views
    here) of a vertex of `meshes`."""
    if p is None:
        return False
    p = Vector(p)
    for m in meshes:
        mw = Matrix(m['matrix'])
        for v in m['vertices']:
            if (mw @ Vector(v) - p).length < within:
                return True
    return False


def on_wire_edge(p, within=4e-3):
    """Whether `p` lies on an edge of an object displayed as wire."""
    p = Vector(p)
    for o in bpy.context.scene.objects:
        if o.type != 'MESH' or o.display_type != 'WIRE':
            continue
        mw = o.matrix_world
        for e in o.data.edges:
            a, b = mw @ o.data.vertices[e.vertices[0]].co, mw @ o.data.vertices[e.vertices[1]].co
            ab = b - a
            t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared)) if ab.length_squared else 0.0
            if (a + ab * t - p).length < within:
                return True
    return False


def apply_cursor(scenes, calls, cursors):
    print("\nThe Cursor tool: the app's call against Blender's own invoke")
    worst_plane = worst_depth = worst_geom = worst_rot = 0.0
    cases = mismatched = 0
    by_setting = {}
    controls = {'no_inverse_transpose': [0, 0], 'no_roll': [0, 0], 'no_flip': [0, 0]}
    for si, sc in enumerate(scenes):
        build(sc['fixture'])
        bpy.context.scene.transform_orientation_slots[0].type = ORIENTATION_SLOTS[sc['fixture']]
        with context.temp_override_view3d("check"):
            aim(sc['view_in'])
            for k, s in enumerate(sc['samples']):
                key = "cursor.%d.%d" % (si, k)
                if key not in calls:
                    continue
                c = cursors[s['cursor']]
                b = s['blender']
                set_cursor(c, s['behind'])
                cursor_mod.set_settings(use_depth=s['use_depth'], orientation=s['orientation'])
                steps = undo.state()['steps']
                try:
                    exec(calls[key], {'bpy': bpy})
                    error = None
                except Exception as e:  # noqa: BLE001
                    error = "%s: %s" % (type(e).__name__, e)
                app = cursor_state()
                cases += 1
                d = (Vector(app['location']) - Vector(b['location'])).length
                rot_ok = same_rotation(app, b, b['mode'], 2e-4)
                if b['mode'] == 'AXIS_ANGLE':
                    qa = Quaternion(Vector(app['axis_angle'][1:]).normalized(), app['axis_angle'][0])
                    qb = Quaternion(Vector(b['axis_angle'][1:]).normalized(), b['axis_angle'][0])
                    rot_err = min(max(abs(p - q) for p, q in zip(qa, qb)), max(abs(p + q) for p, q in zip(qa, qb)))
                else:
                    form = 'quat' if b['mode'] == 'QUATERNION' else 'euler'
                    rot_err = max(abs(p - q) for p, q in zip(app[form], b[form]))
                # Surface Project reads Blender's depth buffer, a float the
                # GPU rasterised; the rest is arithmetic on the same numbers.
                hit_depth = s['use_depth'] and ("depth=None" not in calls[key]
                                                 or ("surface=None" not in calls[key] and s['orientation'] == 'GEOM'))
                # The rest is the same arithmetic in float on the same numbers,
                # 10 m from the eye: 1e-5 of that.
                # Blender's own direction is float noise itself: its
                # `ED_view3d_win_to_vector` unprojects a point 1.3 cm from the
                # eye and subtracts the eye (both ~8 m from the origin), which
                # leaves the line ~6e-5 rad off — 0.6 mm at 10 m. So a point is
                # held to 1e-4 of its distance from the eye.
                reach = max(1.0, (Vector(b['location']) - Vector(sc['region']['eye'])).length)
                tolerance = 2e-3 if hit_depth else 1e-4 * reach
                twin = next((t['blender']['location'] for t in sc['samples']
                             if t['px'] == s['px'] and t['use_depth'] and t['orientation'] == 'GEOM'), None)
                if not (error is None and d <= tolerance and rot_ok) and s['orientation'] == 'GEOM' and \
                        (through_vertex(calls[key], sc['meshes']) or near_vertex(twin, sc['meshes'])):
                    # The pointer's ray passes through a vertex: where its
                    # triangles meet, the app's test counts a hit and Blender's
                    # BVH ray-triangle test none (or the other way round).
                    vertex_ties[0] += 1
                    continue
                if not (error is None and d <= tolerance) and sc['fixture'] == 'wire' and hit_depth \
                        and s['orientation'] != 'GEOM' and on_wire_edge(b['location']):
                    # Blender's depth buffer holds a wire object's drawn edges
                    # (the overlay's wireframe; its prepass draws only solid
                    # objects' surfaces), which the mirror has no pixels of.
                    wire_edges[0] += 1
                    continue
                ok = error is None and d <= tolerance and rot_ok and undo.state()['steps'] == steps
                bucket = by_setting.setdefault((s['use_depth'], s['orientation']), [0, 0])
                bucket[0] += 1
                if ok:
                    bucket[1] += 1
                    if s['use_depth'] and s['orientation'] == 'GEOM' and "surface=None" not in calls[key]:
                        worst_geom = max(worst_geom, d)
                    elif hit_depth:
                        worst_depth = max(worst_depth, d)
                    else:
                        worst_plane = max(worst_plane, d)
                    worst_rot = max(worst_rot, rot_err)
                else:
                    mismatched += 1
                    MISSES.append((sc['fixture'], sc['view'], tuple(s['px']), s['use_depth'], s['orientation'],
                                   round(d, 6), rot_ok, error, 'behind' if s['behind'] else c['name']))
                    if mismatched <= 4:
                        check("%s %s px %s cursor %s depth=%s %s" % (sc['fixture'], sc['view'], s['px'], c['name'],
                                                                     s['use_depth'], s['orientation']), False,
                              dict(error=error, distance=d, app=app, blender=b,
                                   steps=(steps, undo.state()['steps'])))
                # Negative controls. On the Geometry cases with a surface: the
                # world cross product's normal (no inverse transpose, which a
                # mirrored object turns round) and the X roll matched to the
                # wrong axis; where the cursor is behind the view, the flip left
                # out. Each must disagree with Blender somewhere.
                geometry = s['orientation'] == 'GEOM' and "surface=None" not in calls[key]
                variants = []
                if key + " WORLDNORMAL" in calls:
                    variants.append(('no_inverse_transpose', calls[key + " WORLDNORMAL"]))
                if geometry:
                    variants.append(('no_roll', calls[key]))
                if s['behind'] is not None:
                    variants.append(('no_flip', calls[key]))
                for name, body in variants:
                    set_cursor(c, s['behind'])
                    original = cursor_mod._axis_dominant_ortho_single
                    original_behind = cursor_mod._View.behind
                    if name == 'no_roll':
                        cursor_mod._axis_dominant_ortho_single = lambda v: (original(v) + 1) % 3
                    if name == 'no_flip':
                        cursor_mod._View.behind = lambda self, co: False
                    try:
                        exec(body, {'bpy': bpy})
                        control = cursor_state()
                        differs = ((Vector(control['location']) - Vector(b['location'])).length > tolerance
                                   or not same_rotation(control, b, b['mode'], 2e-4))
                    except Exception:  # noqa: BLE001
                        differs = False
                    finally:
                        cursor_mod._axis_dominant_ortho_single = original
                        cursor_mod._View.behind = original_behind
                    controls[name][0] += 1
                    controls[name][1] += differs
    print("  on a wire object's drawn edge, which the mirror does not draw: %d; the ray through a vertex, "
          "where the two ray-triangle tests settle a tie differently: %d" % (wire_edges[0], vertex_ties[0]))
    print("  %d cases; worst distance %.2e m in the view's plane, %.2e m from the depth buffer, "
          "%.2e m on a face Geometry snapped to; worst rotation %.2e" % (cases, worst_plane, worst_depth,
                                                                         worst_geom, worst_rot))
    for key in sorted(by_setting):
        total, good = by_setting[key]
        print("    Surface Project %-5s Orientation %-5s %d of %d" % (key[0], key[1], good, total))
    if MISSES:
        from collections import Counter
        print("    mismatches by fixture, view, Surface Project, Orientation:",
              dict(Counter((m[0], m[1], m[3], m[4]) for m in MISSES).most_common(12)))
        print("    distances:", sorted({m[5] for m in MISSES})[:10], "...", sorted({m[5] for m in MISSES})[-5:])
        print("    rotation wrong in", sum(1 for m in MISSES if not m[6]))
        shown = 0
        for m in MISSES:
            if m[0] == 'subsurf' and m[4] == 'GEOM' and shown < 3:
                print("      subsurf", m)
                shown += 1
        for m in sorted(MISSES, key=lambda m: -m[5])[:6]:
            print("      worst", m)
        for m in MISSES:
            if not m[6]:
                print("      rot", m)
        print("    far misses:", Counter((m[0], m[1], m[3], m[4], m[8]) for m in MISSES if m[5] > 0.01).most_common(12))
        print("    near misses:", Counter((m[0], m[1], m[3], m[4], m[8]) for m in MISSES if m[5] <= 0.01).most_common(12))
    check("every call the app made put the cursor where Blender's own Cursor tool did (%d cases)" % cases,
          mismatched == 0 and cases > 1000, "%d mismatched" % mismatched)
    for name, (n, differ) in controls.items():
        check("negative control %s: %d of %d disagree with Blender" % (name, differ, n), n > 0 and differ > 0,
              (n, differ))


def apply_undo():
    print("\nNo undo step, and Blender's undo keeps the cursor")
    build('turned')
    s = undo.state()['steps']
    with context.temp_override_view3d("check"):
        aim(VIEWS[0])
    view = VIEWS[0]
    cursor_mod.set_settings(use_depth=False, orientation='VIEW')
    cursor_mod.place(eye=view['eye'], forward=view['forward'], up=view['up'], ortho=False,
                     point=(0.4, -0.2, 0.5), center=(0, 0, 0))
    check("place() pushed no undo step", undo.state()['steps'] == s, (s, undo.state()['steps']))
    placed = Vector(bpy.context.scene.cursor.location)
    undo.push(os.path.join(WORK, "history"), "Move")
    bpy.data.objects['Cube'].location.x += 1.0
    undo.push(os.path.join(WORK, "history"), "Move")
    bpy.context.scene.cursor.location = (3.0, 2.0, 1.0)
    undo.step(-1)
    check("an Undo of a later change leaves the cursor where it is (scene_undo_preserve)",
          (Vector(bpy.context.scene.cursor.location) - Vector((3, 2, 1))).length < 1e-6,
          tuple(bpy.context.scene.cursor.location))
    # The drag's call: Blender's own operator moves the cursor alone.
    bpy.context.scene.cursor.location = placed
    cube_before = bpy.data.objects['Cube'].matrix_world.copy()


# --------------------------------------------------------------------------
# Blender's own unit strings

_scaled = getattr(lib, "_ZN7blender31BKE_unit_value_as_string_scaledEPcidiiRKNS_12UnitSettingsEbb")
_plain = getattr(lib, "_ZN7blender24BKE_unit_value_as_stringEPcidiiRKNS_12UnitSettingsEbb")
for _f in (_scaled, _plain):
    _f.restype = ctypes.c_size_t
    _f.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_double, ctypes.c_int, ctypes.c_int,
                   ctypes.c_void_p, ctypes.c_bool, ctypes.c_bool]
UNIT_TYPES = {'LENGTH': 1, 'AREA': 2, 'ROTATION': 5}


def blender_unit(value, prec, kind, scaled=True):
    """Blender's own `BKE_unit_value_as_string(_scaled)` with the scene's
    units, pad off and the suffix on, as the ruler and the overlays call it."""
    buf = ctypes.create_string_buffer(256)
    (_scaled if scaled else _plain)(buf, 256, float(value), prec, UNIT_TYPES[kind],
                                    bpy.context.scene.unit_settings.as_pointer(), False, True)
    return buf.value.decode('utf-8')


def set_unit_line(system, rotation, scale, length, split):
    u = bpy.context.scene.unit_settings
    u.system = system
    u.system_rotation = rotation
    u.scale_length = float(scale)
    if system != 'NONE':
        u.length_unit = length
    u.use_separate = split == '1'


def apply_units(calls):
    print("\nThe unit strings against Blender's own BKE_unit_value_as_string(_scaled)")
    lines = [l.split("\t") for l in calls["units"].splitlines()]
    bad = []
    for si, system, rotation, scale, length, split, kind, prec, scaled, value, text in lines:
        set_unit_line(system, rotation, scale, length, split)
        want = blender_unit(float(value), int(prec), kind, scaled == '1')
        if want != text:
            bad.append((system, length, split, kind, prec, value, text, want))
    check("%d strings, every one Blender's (%d settings, lengths, areas, angles, precisions 2, 3 and 6)"
          % (len(lines), len({l[0] for l in lines})), not bad and len(lines) > 1000, bad[:6])
    # Negative control: the same strings with the Length unit left out (the
    # adaptive variant `bpy.utils.units.to_string` makes) disagree.
    differ = 0
    for si, system, rotation, scale, length, split, kind, prec, scaled, value, text in lines:
        if system == 'METRIC' and length == 'METERS' and kind == 'LENGTH' and scaled == '1':
            differ += bpy.utils.units.to_string('METRIC', 'LENGTH', float(value), precision=int(prec)) != text
    check("negative control: Python's to_string, which has no Length unit, disagrees on %d" % differ, differ > 0)


# --------------------------------------------------------------------------
# The ruler

def v(text):
    return Vector([float(x) for x in text.split(",")])


def _c_angle(x, y):
    nx = x.normalized() if x.length > 0 else x
    ny = y.normalized() if y.length > 0 else y
    if nx.dot(ny) >= 0:
        return 2 * math.asin(min(1.0, (nx - ny).length / 2))
    return math.pi - 2 * math.asin(min(1.0, (nx + ny).length / 2))


def on_line(p, origin, direction, rv3d):
    """Whether `p` is on the line of sight through `origin` along
    `direction`, to 1e-4 of its distance (Blender's own line is that much
    float noise, `ED_view3d_win_to_vector`)."""
    d = p - origin
    if not rv3d.is_perspective:
        off = (d - direction * d.dot(direction)).length
        return off < 1e-4 * max(1.0, abs(d.dot(direction)))
    return (d - direction * d.dot(direction)).length < 1e-4 * max(1.0, d.length)


def apply_ruler(scenes, calls):
    from bpy_extras import view3d_utils
    from mathutils.geometry import intersect_line_plane
    print("\nThe ruler's points against Blender's evaluated geometry")
    lines = [l.split("\t") for l in calls["ruler"].splitlines()]
    counts, bad = {}, []
    by_scene = {}
    for line in lines:
        by_scene.setdefault(int(line[0]), []).append(line)
    for si, rows in by_scene.items():
        sc = scenes[si]
        build(sc['fixture'])
        dg = bpy.context.evaluated_depsgraph_get()
        verts, edges, centres = [], [], []
        for m in sc['meshes']:
            o = bpy.data.objects[m['name']]
            ev = o.evaluated_get(dg)
            me = ev.to_mesh()
            mw = o.matrix_world
            vs = [mw @ x.co for x in me.vertices]
            verts += vs
            edges += [(vs[e.vertices[0]], vs[e.vertices[1]]) for e in me.edges]
            # `face_center_calc`: the mean of the corners.
            centres += [sum((vs[i] for i in f.vertices), Vector()) / len(f.vertices) for f in me.polygons]
            ev.to_mesh_clear()
        with context.temp_override_view3d("check"):
            region = bpy.context.region
            rv3d = aim(sc['view_in'])
            for _, x, y, kind, point, depth, cursor in rows:
                p = v(point)
                counts[kind] = counts.get(kind, 0) + 1
                coord = (float(x), float(y))
                origin = view3d_utils.region_2d_to_origin_3d(region, rv3d, coord)
                direction = view3d_utils.region_2d_to_vector_3d(region, rv3d, coord)
                if kind == 'vertex':
                    ok = min((p - q).length for q in verts) < 1e-5
                elif kind == 'edgeMidpoint':
                    # A midpoint of one of Blender's edges, not of a diagonal
                    # the viewport's triangles add.
                    ok = min((p - (a + b) / 2).length for a, b in edges) < 1e-5
                elif kind == 'edge':
                    ok = min(((a + (b - a) * max(0.0, min(1.0, (p - a).dot(b - a) / max((b - a).length_squared, 1e-20))))
                              - p).length for a, b in edges) < 1e-5
                elif kind == 'face':
                    # On the pointer's line, where Blender's own snapping ray
                    # meets the surface (`scene.ray_cast` in Object Mode).
                    hit = bpy.context.scene.ray_cast(dg, origin - direction * 1000.0, direction)
                    ok = hit[0] and (Vector(hit[1]) - p).length < 1e-4 * max(1.0, (p - origin).length)
                elif kind == 'faceMidpoint':
                    ok = min((p - c).length for c in centres) < 1e-5
                elif kind == 'plane':
                    # Nothing in reach: the plane through the 3D cursor facing
                    # Z, where the pointer's line meets it — held as on that
                    # plane and on Blender's line of sight (to 1e-4 of the
                    # distance: near the horizon the meeting point runs far
                    # along the plane for a sliver of angle).
                    z = Vector(sc['region']['z'])
                    if not rv3d.is_perspective and abs(z.z) <= 1e-2:
                        # An orthographic view along the plane: the view's
                        # own plane through the cursor instead.
                        ok = on_line(p, origin, direction, rv3d) and abs((p - v(cursor)).dot(z)) < 1e-4
                    else:
                        ok = abs(p.z - v(cursor).z) < 1e-4 and on_line(p, origin, direction, rv3d)
                else:
                    # `ED_view3d_win_to_3d`: on Blender's line of sight, in the
                    # view's plane through the depth point.
                    z = Vector(sc['region']['z'])
                    reach = max(1.0, (p - origin).length)
                    ok = on_line(p, origin, direction, rv3d) and abs((p - v(depth)).dot(z)) < 1e-4 * reach
                if not ok:
                    near_edge = min(((a + (b - a) * max(0.0, min(1.0, (p - a).dot(b - a) / max((b - a).length_squared, 1e-20))))
                                     - p).length for a, b in edges)
                    hit = bpy.context.scene.ray_cast(dg, origin - direction * 1000.0, direction)
                    bad.append((sc['fixture'], sc['view'], x, y, kind, point, 'edge %.2e' % near_edge,
                                'ray ' + (str(tuple(round(c, 5) for c in hit[1])) if hit[0] else 'none'),
                                'vert %.2e' % min((p - q).length for q in verts)))
    check("%d ruler points where Blender's geometry and view put them (%s)" % (len(lines), counts),
          not bad and all(counts.get(k, 0) > 0 for k in ('vertex', 'edgeMidpoint', 'edge', 'face', 'plane', 'depth')),
          bad[:6])

    # The negative control: snapped without the face corners, so a quad's
    # diagonal counts as an edge; some of those points are on no edge of
    # Blender's.
    off = total = 0
    for line in calls.get("ruler_control", "").splitlines():
        si, x, y, kind, point = line.split("\t")
        sc = scenes[int(si)]
        build(sc['fixture'])
        dg = bpy.context.evaluated_depsgraph_get()
        p = v(point)
        best = 1e9
        for m in sc['meshes']:
            o = bpy.data.objects[m['name']]
            ev = o.evaluated_get(dg)
            me = ev.to_mesh()
            mw = o.matrix_world
            for e in me.edges:
                a, b = mw @ me.vertices[e.vertices[0]].co, mw @ me.vertices[e.vertices[1]].co
                t = max(0.0, min(1.0, (p - a).dot(b - a) / max((b - a).length_squared, 1e-20)))
                best = min(best, (a + (b - a) * t - p).length)
            ev.to_mesh_clear()
        total += 1
        off += best > 1e-5
    check("negative control: without the face corners %d of %d edge snaps land on a diagonal" % (off, total),
          off > 0, (off, total))

    print("\nThe ruler's text against Blender's C")
    texts = [l.split("\t") for l in calls["rulertext"].splitlines()]
    last_digit = [0]
    cases = json.load(open(argv[1]))['overlays']['units']
    bad = []
    for ui, angle, points, text in texts:
        line = [l for l in calls["units"].splitlines() if l.split("\t")[0] == ui][0].split("\t")
        set_unit_line(*line[1:6])
        a, b, c = (v(p) for p in points.split(";"))
        if angle == '1':
            # `angle_v3v3v3`, a zero vector normalized to zero as Blender's is.
            value = _c_angle(a - b, c - b)

            def fmt(x):
                return ("%.2f\u00b0" % math.degrees(x)) if line[1] == 'NONE' else blender_unit(x, 2, 'ROTATION', False)
        else:
            value = (a - c).length

            def fmt(x):
                return ("%.6f" % x) if line[1] == 'NONE' else blender_unit(x, 6, 'LENGTH', True)
        want = fmt(value)
        if want != text:
            # Six figures print the float's last bits: the length or angle a
            # float ulp either way (the order Blender's compiler sums a dot
            # product in) may round to the next digit.
            import numpy as np
            f = np.float32(value)
            near = {fmt(float(np.nextafter(f, np.float32(-1e30)))), fmt(float(np.nextafter(f, np.float32(1e30)))),
                    fmt(float(f))}
            if text in near:
                last_digit[0] += 1
            else:
                bad.append((line[1:6], angle, text, want))
    check("%d ruler texts, lengths and angles, each what Blender's ruler would print (%d a float ulp from "
          "the next figure)" % (len(texts), last_digit[0]), not bad and len(texts) > 100, bad[:6])


# --------------------------------------------------------------------------
# Edit Mode's overlays

def apply_overlays(data, calls):
    print("\nEdit Mode's measurements against bmesh's own, and their text against Blender's C")
    cases = data['overlays']['cases']
    units = [l.split("\t") for l in calls["units"].splitlines()]
    unit_by_index = {}
    for l in units:
        unit_by_index.setdefault(l[0], l[1:6])
    rows = [l.split("\t") for l in calls["overlay"].splitlines()]
    bad_values, bad_text, bad_stats = [], [], []
    checked = {'length': 0, 'edgeAngle': 0, 'area': 0, 'faceAngle': 0}
    differs_newell = differs_global = 0
    for ci, case in enumerate(cases):
        o = overlay_fixture(case['fixture'])
        bm = bmesh.from_edit_mesh(o.data)
        mw = o.matrix_world
        m3 = mw.to_3x3()
        g = case['use_global']
        rec = json.loads(case['record'])
        # Values, independently of the module: bmesh's own measures.
        lengths = [(m3 @ e.verts[0].co - m3 @ e.verts[1].co).length if g else e.calc_length()
                   for e in bm.edges if e.select]
        got = [r[6] for r in rec['lengths']]
        bad_values += [('length', ci)] if len(got) != len(lengths) or any(abs(p - q) > 1e-6 for p, q in zip(got, lengths)) else []
        if not g:
            angles = [e.calc_face_angle() for e in bm.edges if e.select and len(e.link_faces) == 2]
            got = [r[6] for r in rec['edge_angles']]
            bad_values += [('edgeAngle', ci)] if len(got) != len(angles) or any(abs(p - q) > 1e-5 for p, q in zip(got, angles)) else []
            corner = [l.calc_angle() for f in bm.faces if f.select for l in f.loops]
            got = [r[3] for r in rec['face_angles']]
            bad_values += [('faceAngle', ci)] if len(got) != len(corner) or any(abs(p - q) > 1e-5 for p, q in zip(got, corner)) else []
            # Face Area sums the tessellation's triangles; `calc_area` is
            # the polygon's own (Newell), which a warped quad does not share.
            tris = {}
            for t in bm.calc_loop_triangles():
                tris.setdefault(t[0].face.index, []).append(t)
            area = [sum((t[1].vert.co - t[0].vert.co).cross(t[2].vert.co - t[0].vert.co).length / 2
                        for t in tris[f.index]) for f in bm.faces if f.select]
            got = [r[3] for r in rec['areas']]
            bad_values += [('area', ci)] if len(got) != len(area) or any(abs(p - q) > 1e-6 for p, q in zip(got, area)) else []
            differs_newell += sum(1 for f, a in zip([f for f in bm.faces if f.select], got) if abs(f.calc_area() - a) > 1e-4)
        else:
            local = [e.calc_length() for e in bm.edges if e.select]
            differs_global += sum(1 for p, q in zip([r[6] for r in rec['lengths']], local) if abs(p - q) > 1e-4)
        st = rec['stats']
        want = [1, 1, sum(x.select for x in bm.verts), len(bm.verts), sum(x.select for x in bm.edges), len(bm.edges),
                sum(x.select for x in bm.faces), len(bm.faces), sum(len(f.verts) - 2 for f in bm.faces)]
        if st != want:
            bad_stats.append((ci, st, want))
        # The text the Swift drew for each label, against Blender's C.
        for r in rows:
            if int(r[0]) != ci or r[1] == '-':
                continue
            ui, kind, at, text = r[1], r[2], r[3], r[4]
            sysname, rot, scale, length, split = unit_by_index[ui]
            set_unit_line(sysname, rot, scale, length, split)
            checked[kind] += 1
        bpy.ops.object.mode_set(mode='OBJECT')
    # The strings: rebuild each from the record's value with Blender's C.
    for r in rows:
        if r[1] == '-':
            continue
        ci, ui, kind, at, text = int(r[0]), r[1], r[2], r[3], r[4]
        sysname, rot, scale, length, split = unit_by_index[ui]
        set_unit_line(sysname, rot, scale, length, split)
        u = bpy.context.scene.unit_settings
        rec = json.loads(cases[ci]['record'])
        key = {'length': 'lengths', 'edgeAngle': 'edge_angles', 'area': 'areas', 'faceAngle': 'face_angles'}[kind]
        p = v(at)
        values = []
        for row in rec[key]:
            pos = (Vector(row[:3]) + Vector(row[3:6])) / 2 if len(row) == 7 else Vector(row[:3])
            if (pos - p).length < 1e-5:
                values.append(row[-1])
        if not values:
            bad_text.append((ci, kind, at, text, 'no value there'))
            continue
        val = values[0]
        if kind in ('edgeAngle', 'faceAngle'):
            want = ("%.3fr" % val) if rot == 'RADIANS' else ("%.3f\u00b0" % math.degrees(val))
        elif sysname == 'NONE':
            # conv_float for the grid (1 here).
            want = "%.4g" % val
        else:
            want = blender_unit(val, 3, 'LENGTH' if kind == 'length' else 'AREA', True)
        if text not in [want] and not any(text == (("%.3fr" % x) if rot == 'RADIANS' else ("%.3f\u00b0" % math.degrees(x)))
                                          for x in values if kind in ('edgeAngle', 'faceAngle')) and \
                not any(text == blender_unit(x, 3, 'LENGTH' if kind == 'length' else 'AREA', True)
                        for x in values if sysname != 'NONE' and kind in ('length', 'area')) and \
                not any(text == "%.4g" % x for x in values if sysname == 'NONE'):
            bad_text.append((ci, kind, sysname, length, text, want))
    check("the overlays' numbers are bmesh's own: lengths, edge angles, corner angles, tessellated areas",
          not bad_values, bad_values)
    check("the statistics are the edit mesh's counts", not bad_stats, bad_stats)
    check("%d labels written as Blender writes them (%s)" % (sum(checked.values()), checked),
          not bad_text and all(checked.values()), bad_text[:6])
    check("negative control: BMFace.calc_area (no tessellation) differs on %d warped faces" % differs_newell,
          differs_newell > 0)
    check("negative control: Local lengths differ from Global on %d edges of the scaled cube" % differs_global,
          differs_global > 0)


def apply_tool_settings():
    """The Cursor's settings are written to the tool Blender keeps for the
    mode, made as Blender makes one: named after its default tool, kept by a
    save and a reload, and set again by Blender's own `wm.tool_set_by_id`. The
    control is the old way, `from_space_view3d_mode(create=True)`, which left
    a tool named '' (round 4's review). Run first: factory startup has no tool
    for Object or Edit Mode yet."""
    print("\nThe Cursor's settings live in a tool Blender would have made")
    clear()
    o = mesh_object('Cube', cube, Matrix())
    for x in bpy.context.scene.objects:
        x.select_set(x == o)
    bpy.context.view_layer.objects.active = o
    ws = bpy.context.workspace

    def tools():
        return {t.mode: t.idname for t in ws.tools if t.space_type == 'VIEW_3D'}

    before = tools()
    check("factory startup has no 3D View tool for Object or Edit Mode (the fixture)",
          'OBJECT' not in before and 'EDIT_MESH' not in before, before)
    held = {}
    for mode, key in (('OBJECT', 'OBJECT'), ('EDIT', 'EDIT_MESH')):
        bpy.ops.object.mode_set(mode=mode)
        held[key] = cursor_mod.set_settings(use_depth=False, orientation='GEOM')
    bpy.ops.object.mode_set(mode='OBJECT')
    after = tools()
    check("the Cursor bar's write made each mode's tool Box Select, Blender's default (`toolsystem_default_tool`)",
          after.get('OBJECT') == 'builtin.select_box' and after.get('EDIT_MESH') == 'builtin.select_box', after)
    check("…and holds the settings written", held == {'OBJECT': (False, 'GEOM'), 'EDIT_MESH': (False, 'GEOM')}, held)
    # Mended: a tool an earlier build left unnamed.
    lat = bpy.data.objects.new('Lattice', bpy.data.lattices.new('Lattice'))
    bpy.context.collection.objects.link(lat)
    for x in bpy.context.scene.objects:
        x.select_set(x == lat)
    bpy.context.view_layer.objects.active = lat
    bpy.ops.object.mode_set(mode='EDIT')
    broken = ws.tools.from_space_view3d_mode(bpy.context.mode, create=True)
    check("the old way, create=True, makes a tool named '' (the control)", broken is not None and broken.idname == '',
          broken and broken.idname)
    cursor_mod.set_settings(orientation='XFORM')
    mended = ws.tools.from_space_view3d_mode(bpy.context.mode, create=False)
    check("…which the bar's next write names Box Select", mended is not None and mended.idname == 'builtin.select_box',
          mended and mended.idname)
    bpy.ops.object.mode_set(mode='OBJECT')
    path = os.path.join(WORK, "tools.blend")
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=True)
    ws = bpy.context.workspace
    reloaded = tools()
    check("a save and a reload keep them", all(reloaded.get(k) == 'builtin.select_box'
                                                for k in ('OBJECT', 'EDIT_MESH', 'EDIT_LATTICE')), reloaded)
    again = bpy.ops.wm.tool_set_by_id(name=reloaded.get('OBJECT', ''), space_type='VIEW_3D')
    check("…and Blender's own tool_set_by_id takes the kept name (with '' it answered CANCELLED, "
          "\"Tool '' not found\")", again == {'FINISHED'}, again)
    # Edit Text: Blender's default there is Select Text.
    text = bpy.data.objects.new('Text', bpy.data.curves.new('Text', 'FONT'))
    bpy.context.collection.objects.link(text)
    for x in bpy.context.scene.objects:
        x.select_set(x == text)
    bpy.context.view_layer.objects.active = text
    bpy.ops.object.mode_set(mode='EDIT')
    try:
        cursor_mod.set_settings(orientation='VIEW')
        refused = None
    except RuntimeError as e:
        refused = str(e)
    check("in Edit Text, whose Select Text a Blender without a window cannot start, the write is refused in words "
          "and leaves no unnamed tool", refused is not None and 'EDIT_TEXT' not in tools(), (refused, tools()))
    bpy.ops.object.mode_set(mode='OBJECT')
    # A brush mode: refused in words, no brush tool started. Sculpt Mode is
    # entered with an undo stack, as the app always has one (the load above
    # freed Blender's).
    undo.push(os.path.join(WORK, "history"), "tools")
    for x in bpy.context.scene.objects:
        x.select_set(x.name == 'Cube')
    bpy.context.view_layer.objects.active = bpy.data.objects['Cube']
    bpy.ops.object.mode_set(mode='SCULPT')
    entered = tools().get('SCULPT')
    try:
        held = cursor_mod.set_settings(orientation='XFORM')
    except RuntimeError as e:
        held = str(e)
    check("in Sculpt Mode the write goes to the tool Blender made on entering it, its name left alone (%r)" % entered,
          entered == 'builtin.brush' and tools().get('SCULPT') == entered and held == (True, 'XFORM'),
          (entered, tools(), held))
    check("…and a brush mode's default is a brush, which the bar's write would not start (`default_tool`)",
          cursor_mod.default_tool('SCULPT') == 'builtin.brush' and cursor_mod.default_tool('PAINT_WEIGHT') ==
          'builtin.brush' and cursor_mod.default_tool('EDIT_MESH') == cursor_mod.DEFAULT_TOOL)
    bpy.ops.object.mode_set(mode='OBJECT')


# Blender's own Geometry click under each stack, against `subdivides_last`.
FINAL_STACKS = [
    ([], 'none'),
    (['MIRROR'], 'Mirror'),
    (['ARRAY'], 'Array'),
    (['SUBSURF'], 'Subdivision Surface'),
    (['MIRROR', 'SUBSURF'], 'Mirror, then Subdivision Surface'),
    (['SUBSURF', 'MIRROR'], 'Subdivision Surface, then Mirror'),
    (['SUBSURF', 'SIMPLE_DEFORM'], 'Subdivision Surface, then Simple Deform'),
    (['SUBSURF', 'BOOLEAN'], 'Subdivision Surface, then a Boolean with no object (off)'),
    (['SUBSURF:noedit'], 'Subdivision Surface not shown in Edit Mode'),
    (['SUBSURF:level0', 'MIRROR'], 'Subdivision Surface at level 0, then Mirror'),
]


def _final_fixture(stack):
    clear()
    me = bpy.data.meshes.new('C')
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=2.0)
    bmesh.ops.translate(bm, vec=(2, 0, 0), verts=bm.verts)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new('C', me)
    bpy.context.collection.objects.link(o)
    o.matrix_world = Matrix.Rotation(0.3, 4, 'Z') @ Matrix.Rotation(0.2, 4, 'X')
    for entry in stack:
        kind, _, how = entry.partition(':')
        md = o.modifiers.new(kind, kind)
        if kind == 'SUBSURF':
            md.levels = 0 if how == 'level0' else 1
            md.show_in_editmode = how != 'noedit'
        if kind == 'ARRAY':
            md.relative_offset_displace = (-2, 0, 0)
    for x in bpy.context.scene.objects:
        x.select_set(x == o)
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='DESELECT')
    return o


def _world_triangles(o, mesh):
    from mathutils.geometry import intersect_ray_tri
    mw = o.matrix_world
    mesh.calc_loop_triangles()
    i3 = mw.to_3x3().inverted().transposed()
    tris = []
    for t in mesh.loop_triangles:
        a, b, c = (mesh.vertices[i].co for i in t.vertices)
        tris.append((mw @ a, mw @ b, mw @ c, (i3 @ (b - a).cross(c - a).normalized()).normalized()))

    def cast(origin, d):
        best = None
        for a, b, c, n in tris:
            p = intersect_ray_tri(a, b, c, d, origin, True)
            if p is not None:
                t = (p - origin).dot(d)
                if t > 0 and (best is None or t < best[0]):
                    best = (t, n)
        return best
    return cast


def apply_final_geometry():
    """In Edit Mode Blender's Geometry orientation (and the cursor's drag)
    snaps to the final geometry, which is the mirror's mesh except under a
    Subdivision Surface evaluated last. Blender's own cursor3d, with a made
    event, at a grid of pixels under each stack: does it meet the mirror's
    mesh (the evaluated `to_mesh()`, as `_blenderkit_sync` sends it)? The app
    refuses (and leaves the object out of a drag's snap) exactly where
    `subdivides_last` names a modifier — which has to be where Blender did
    not. The control is the rule the app had, a mirror whose vertex count is
    not the edit mesh's."""
    from bpy_extras import view3d_utils
    print("\nGeometry in Edit Mode: Blender's own click against the mirror, for each stack")
    wrong_new = []
    wrong_old = []
    measured = {}
    for stack, label in FINAL_STACKS:
        o = _final_fixture(stack)
        last = cursor_mod.subdivides_last(o)
        with context.temp_override_view3d("check"):
            region = bpy.context.region
            rv3d = bpy.context.area.spaces.active.region_3d
            rv3d.view_perspective = 'PERSP'
            rv3d.view_rotation = Quaternion((0.82, 0.45, 0.17, 0.3)).normalized()
            rv3d.view_distance = 12
            rv3d.view_location = (0, 0, 0)
            rv3d.update()
            o.update_from_editmode()
            ev = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
            me = ev.to_mesh()
            mirror_cast = _world_triangles(o, me)
            rebuilt = len(me.vertices) != len(bmesh.from_edit_mesh(o.data).verts)
            ev.to_mesh_clear()
            agree = differ = 0
            for x in range(10, region.width, 37):
                for y in range(10, region.height, 31):
                    origin = view3d_utils.region_2d_to_origin_3d(region, rv3d, (x, y))
                    d = view3d_utils.region_2d_to_vector_3d(region, rv3d, (x, y)).normalized()
                    hit = mirror_cast(origin, d)
                    view_z = rv3d.view_rotation @ Vector((0, 0, 1))
                    bpy.context.scene.cursor.rotation_mode = 'QUATERNION'
                    bpy.context.scene.cursor.rotation_quaternion = (1, 0, 0, 0)
                    bpy.ops.bk.invoke_at('EXEC_DEFAULT', opname="VIEW3D_OT_cursor3d", x=region.x + x,
                                         y=region.y + y, props=json.dumps({"use_depth": False, "orientation": 3}))
                    z = Quaternion(bpy.context.scene.cursor.rotation_quaternion) @ Vector((0, 0, 1))
                    # What the mirror says Blender's click should give: the
                    # face's normal, or the view's own Z where it meets none.
                    want = hit[1] if hit is not None else view_z
                    if (z - want).length < 1e-3:
                        agree += 1
                    else:
                        differ += 1
        meets_mirror = differ == 0
        measured[label] = (agree, differ)
        if meets_mirror != (last is None):
            wrong_new.append((label, last, agree, differ))
        if meets_mirror != (not rebuilt):
            wrong_old.append(label)
        bpy.ops.object.mode_set(mode='OBJECT')
    check("Blender's click met the mirror's mesh under exactly the stacks `subdivides_last` passes (%s)" % measured,
          not wrong_new, wrong_new)
    check("negative control: the old rule (a rebuilt edit mesh) is wrong under %d stacks (%s)"
          % (len(wrong_old), ', '.join(wrong_old)), len(wrong_old) > 0)


def _swift_keeps(row, vp):
    """`EditMeasurements.clip` (an edge) or the overlay's window test (a
    face's label), in single precision as the Swift does it."""
    import numpy as np
    vp = np.asarray(vp, np.float32)
    if len(row) == 7:
        ca = vp @ np.array(row[0:3] + [1], np.float32)
        cb = vp @ np.array(row[3:6] + [1], np.float32)
        t0, t1 = np.float32(0), np.float32(1)
        for da, db in ((ca[3] + ca[0], cb[3] + cb[0]), (ca[3] - ca[0], cb[3] - cb[0]),
                       (ca[3] + ca[1], cb[3] + cb[1]), (ca[3] - ca[1], cb[3] - cb[1])):
            if da < 0 and db < 0:
                return False
            if da < 0:
                t0 = max(t0, da / (da - db))
            elif db < 0:
                t1 = min(t1, da / (da - db))
            if t0 > t1:
                return False
        return True
    c = vp @ np.array(row[:3] + [1], np.float32)
    return c[3] > 1e-5 and -c[3] <= c[0] <= c[3] and -c[3] <= c[1] <= c[3]


def _perspective(eye, target, fov=0.69, aspect=1.4, near=0.05, far=1000.0):
    """A world-to-clip matrix as the app's camera makes one (Metal's z)."""
    eye, target = Vector(eye), Vector(target)
    f = (target - eye).normalized()
    r = f.cross(Vector((0, 0, 1))).normalized()
    u = r.cross(f)
    view = Matrix(((r.x, r.y, r.z, -r.dot(eye)), (u.x, u.y, u.z, -u.dot(eye)),
                   (-f.x, -f.y, -f.z, f.dot(eye)), (0, 0, 0, 1)))
    t = 1 / math.tan(fov / 2)
    proj = Matrix(((t / aspect, 0, 0, 0), (0, t, 0, 0), (0, 0, far / (near - far), near * far / (near - far)),
                   (0, 0, -1, 0)))
    m = proj @ view
    return [m[i][j] for i in range(4) for j in range(4)]


def _grid_object(n, warp=True, shape_key=False):
    import random
    rnd = random.Random(4)
    clear()

    def make(bm):
        bmesh.ops.create_grid(bm, x_segments=n, y_segments=n, size=2.0)
        if warp:
            for v in bm.verts:
                v.co.z += rnd.uniform(-0.3, 0.3) + 0.3 * math.sin(v.co.x * 1.3)
    o = mesh_object('Grid', make, Matrix.Translation((0.3, -0.2, 0.1)) @ Matrix.Rotation(0.4, 4, 'Z')
                    @ Matrix.Diagonal((1.0, 1.7, 0.6, 1.0)))
    if shape_key:
        o.shape_key_add(name='Basis')
        k = o.shape_key_add(name='Key 1')
        for d in k.data:
            d.co = d.co + Vector((rnd.uniform(-.1, .1), rnd.uniform(-.1, .1), rnd.uniform(-.3, .3)))
        o.active_shape_key_index = 1
    for x in bpy.context.scene.objects:
        x.select_set(x == o)
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    return o


def apply_bounded_read():
    """Round 4's review measured the overlays' read unbounded: 90,000 faces,
    all selected, all four switches on, 2.4 s and 65 MB of JSON for the main
    thread to parse. It is Blender's own read while it stays within LABELS,
    and past that culled to the app's view and thinned, saying so."""
    import time
    import numpy as np
    print("\nEdit Mode's measurements: a bounded read")
    ALL = dict(edge_length=True, edge_angle=True, face_area=True, face_angle=True)
    # 1. Face Area's tessellation, face by face, against Blender's own.
    flipped = differs = 0
    for shape_key in (False, True):
        o = _grid_object(16, shape_key=shape_key)
        bm = bmesh.from_edit_mesh(o.data)
        whole = {}
        for tri in bm.calc_loop_triangles():
            whole.setdefault(tri[0].face.index, []).append(sum(((tri[1].vert.co - tri[0].vert.co).cross(
                tri[2].vert.co - tri[0].vert.co).length / 2,), 0.0))
        tess = measure_mod._Tessellation(o, bm)
        for i, f in enumerate(bm.faces):
            mine = sum((t[1].vert.co - t[0].vert.co).cross(t[2].vert.co - t[0].vert.co).length / 2 for t in tess.of(f, i))
            fixed = sum((t[1].vert.co - t[0].vert.co).cross(t[2].vert.co - t[0].vert.co).length / 2
                        for t in ((f.loops[0], f.loops[1], f.loops[2]), (f.loops[0], f.loops[2], f.loops[3])))
            flipped += abs(fixed - sum(whole[i])) > 1e-6
            differs += abs(mine - sum(whole[i])) > 1e-7
        bpy.ops.object.mode_set(mode='OBJECT')
    check("Face Area's per-face tessellation is BMesh's own on a warped grid, with and without a shape key "
          "(the control, every quad split 0-2, differs on %d faces)" % flipped, differs == 0 and flipped > 0,
          differs)
    # 2. The read past its budget writes the same rows as the whole read.
    same = True
    for shape_key in (False, True):
        for g in (False, True):
            o = _grid_object(20, shape_key=shape_key)
            whole = json.loads(measure_mod.edit_overlay(use_global=g, budget=10 ** 9, **ALL))
            out = {k: [] for k in measure_mod._KEYS}
            measure_mod._culled([o], (True, True, True, True), g, None, 10 ** 9, out)
            same &= all(out[k] == whole[k] for k in measure_mod._KEYS)
            bpy.ops.object.mode_set(mode='OBJECT')
    check("the culled read, with no view to cull to and nothing to thin, writes the whole read's rows exactly",
          same)
    # 3. Culled to a view: nothing the app would draw is left out.
    o = _grid_object(40)
    whole = json.loads(measure_mod.edit_overlay(budget=10 ** 9, **ALL))
    missing = drawn = 0
    widened_missing = 0
    for eye, target in (((1.0, -2.5, 1.6), (0.4, 0.3, 0.0)), ((-3, -3, 2), (-2.5, -2.5, 0)), ((6, -9, 7), (0, 0, 0))):
        view = _perspective(eye, target)
        vp = np.array(view, np.float32).reshape(4, 4)
        for widen in (measure_mod._WIDEN, -0.05):
            saved = measure_mod._WIDEN
            measure_mod._WIDEN = widen
            try:
                out = {k: [] for k in measure_mod._KEYS}
                measure_mod._culled([o], (True, True, True, True), False, view, 10 ** 9, out)
            finally:
                measure_mod._WIDEN = saved
            for k in measure_mod._KEYS:
                got = set(map(tuple, out[k]))
                want = [tuple(r) for r in whole[k] if _swift_keeps(list(r), vp)]
                lost = sum(1 for r in want if r not in got)
                if widen == measure_mod._WIDEN:
                    drawn += len(want)
                    missing += lost
                else:
                    widened_missing += lost
    check("culled to three views, every one of the %d labels the app draws is in the read" % drawn,
          missing == 0 and drawn > 1000, missing)
    check("negative control: the view's planes pulled in by 5%% lose %d of them" % widened_missing,
          widened_missing > 0)
    bpy.ops.object.mode_set(mode='OBJECT')
    # 4. The bound itself, against the read as it was (no budget).
    o = _grid_object(150, warp=False)
    view = _perspective((0, -6, 5), (0, 0, 0))
    t = time.perf_counter()
    text = measure_mod.edit_overlay(stats=True, view=view, **ALL)
    bounded = time.perf_counter() - t
    rec = json.loads(text)
    rows = sum(len(rec[k]) for k in measure_mod._KEYS)
    t = time.perf_counter()
    unbounded_text = measure_mod.edit_overlay(stats=True, budget=10 ** 9, **ALL)
    unbounded = time.perf_counter() - t
    unbounded_rows = sum(len(v) for k, v in json.loads(unbounded_text).items() if k in measure_mod._KEYS)
    print("  measured  22,500 faces, all selected, all four: %d labels, %.0f KB in %.0f ms; unbounded %d labels, "
          "%.1f MB in %.0f ms" % (rows, len(text) / 1e3, bounded * 1e3, unbounded_rows, len(unbounded_text) / 1e6,
                                  unbounded * 1e3))
    # Every n-th of each list, rounded up, and Face Angle every n-th face's
    # corners: at most LABELS, one more per list and a face's corners.
    check("past the budget the read hands over about LABELS (%d), says how many were in view and which it kept, "
          "and that the view decided" % rows, rows <= measure_mod.LABELS + 3 + 4
          and rec.get('thinned') and rec['thinned'][0] > measure_mod.LABELS and rec['thinned'][1] > 1
          and rec.get('culled') is True, (rows, rec.get('thinned'), rec.get('culled')))
    check("…where the unbounded read wrote every one (the control)", unbounded_rows > 100 * measure_mod.LABELS,
          unbounded_rows)
    check("…and the statistics are the whole mesh's either way", rec['stats'] == json.loads(unbounded_text)['stats'])
    bpy.ops.object.mode_set(mode='OBJECT')


def apply_global_overlays():
    """With the Sidebar's Global (V3D_GLOBAL_STATS), each value as
    `DRW_text_edit_mesh_measure_stats` works it (draw_manager_text.cc): edge
    angles between the faces' normals carried by the world-to-object matrix
    (`world_to_object().view<3, 3>() * no`), face angles and areas between
    corners carried by the object-to-world matrix — here in double precision
    with numpy, apart from the module's code. Local and Global differ on the
    scaled fixtures (the control)."""
    import numpy as np
    print("\nEdit Mode's measurements with Global, against Blender's formulas")
    bad = []
    local_differs = {'edge_angles': 0, 'areas': 0, 'face_angles': 0}
    for kind in OVERLAY_FIXTURES:
        o = overlay_fixture(kind)
        bm = bmesh.from_edit_mesh(o.data)
        m3 = np.array(o.matrix_world.to_3x3(), dtype=np.float64)
        w2o = np.linalg.inv(np.array(o.matrix_world, dtype=np.float64))[:3, :3]
        g = json.loads(measure_mod.edit_overlay(edge_angle=True, face_area=True, face_angle=True, use_global=True))
        local = json.loads(measure_mod.edit_overlay(edge_angle=True, face_area=True, face_angle=True))

        def unit(v):
            # `normalize_v3`: a zero vector stays zero (the fixtures' extruded
            # sides are faces of no area).
            n = np.linalg.norm(v)
            return v / n if n > 0 else v

        def angle(a, b):
            # `angle_v3v3` (math_vector.cc), in double.
            a, b = unit(a), unit(b)
            if float(np.dot(a, b)) >= 0:
                return 2 * math.asin(min(1.0, float(np.linalg.norm(a - b)) / 2))
            return math.pi - 2 * math.asin(min(1.0, float(np.linalg.norm(a + b)) / 2))
        want = []
        for e in bm.edges:
            if e.select and len(e.link_faces) == 2:
                la = e.link_loops[0]
                na = unit(w2o @ np.array(la.face.normal))
                nb = unit(w2o @ np.array(la.link_loop_radial_next.face.normal))
                want.append(angle(na, nb))
        got = [r[6] for r in g['edge_angles']]
        if len(got) != len(want) or any(abs(p - q) > 2e-5 for p, q in zip(got, want)):
            bad.append((kind, 'edge_angles'))
        tris = {}
        for t in bm.calc_loop_triangles():
            tris.setdefault(t[0].face.index, []).append(t)
        want = [sum(np.linalg.norm(np.cross(m3 @ np.array(t[1].vert.co) - m3 @ np.array(t[0].vert.co),
                                            m3 @ np.array(t[2].vert.co) - m3 @ np.array(t[0].vert.co))) / 2
                    for t in tris[f.index]) for f in bm.faces if f.select]
        got = [r[3] for r in g['areas']]
        if len(got) != len(want) or any(abs(p - q) > 1e-5 * max(1.0, q) for p, q in zip(got, want)):
            bad.append((kind, 'areas'))
        want = []
        for f in bm.faces:
            if f.select:
                for l in f.loops:
                    v = m3 @ np.array(l.vert.co)
                    want.append(angle(m3 @ np.array(l.link_loop_prev.vert.co) - v,
                                      m3 @ np.array(l.link_loop_next.vert.co) - v))
        got = [r[3] for r in g['face_angles']]
        if len(got) != len(want) or any(abs(p - q) > 2e-5 for p, q in zip(got, want)):
            bad.append((kind, 'face_angles'))
        for k in local_differs:
            local_differs[k] += sum(1 for a, b in zip(g[k], local[k]) if abs(a[-1] - b[-1]) > 1e-4)
        bpy.ops.object.mode_set(mode='OBJECT')
    check("Global edge angles, areas and face angles are Blender's formulas' (%s)" % ', '.join(OVERLAY_FIXTURES),
          not bad, bad)
    check("negative control: Local differs from Global on %s" % local_differs, all(local_differs.values()))


def apply_file_loads():
    """The file record counts the loads that put another file in front of the
    reader — read_homefile (File ▸ New), open_mainfile (Open) — and not the
    undo history's own checkpoint load, which the app's rulers outlive (they
    go when another file comes). The control is Blender's load count, which
    counts all three."""
    print("\nThe file record: another file in front of the reader")
    path = os.path.join(WORK, "loads.blend")
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    start, all_start = undo.file_loads(), undo._loads
    bpy.ops.wm.read_homefile(load_ui=False)
    after_new = undo.file_loads()
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    after_open = undo.file_loads()
    undo._load(path)
    after_checkpoint = undo.file_loads()
    check("File ▸ New and Open each count one, the history's checkpoint load none (%d, %d, %d after %d)"
          % (after_new, after_open, after_checkpoint, start),
          (after_new, after_open, after_checkpoint) == (start + 1, start + 2, start + 2))
    check("…the record says so", cursor_mod.file_record() == 'loads=%d' % after_checkpoint, cursor_mod.file_record())
    check("negative control: Blender's own load count took all three (%d)" % (undo._loads - all_start),
          undo._loads - all_start == 3)


def apply_checkpoint_undo():
    """The app's checkpoint history (where Blender's undo cannot be used) keeps
    the cursor across an Undo as Blender's own undo does; without
    `_keep_cursor`, the control, the load takes it back. Run last: a second
    copy of the history module, forced to checkpoints, beside the first."""
    print("\nThe checkpoint history keeps the cursor as Blender's undo does")
    spec = importlib.util.spec_from_file_location("_bk_undo_files", SITE / "_blenderkit_undo.py")
    files = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(files)
    root = os.path.join(WORK, "checkpoints")
    for keep in (True, False):
        build('turned')
        bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
        files.push(root, "start", force_checkpoints=True)
        bpy.context.scene.cursor.location = (1.0, 2.0, 3.0)
        bpy.data.objects['Cube'].location.x += 2.0
        files.push(root, "Move")
        bpy.context.scene.cursor.location = (7.0, 8.0, 9.0)
        original = files._keep_cursor
        if not keep:
            files._keep_cursor = lambda state: None
        try:
            files.step(-1)
        finally:
            files._keep_cursor = original
        at = tuple(round(v, 6) for v in bpy.context.scene.cursor.location)
        if keep:
            check("an Undo through a checkpoint (mode %s) leaves the cursor at (7, 8, 9) and the cube back" %
                  files.state()['mode'], at == (7.0, 8.0, 9.0)
                  and abs(bpy.data.objects['Cube'].location.x - 0.2) < 1e-6, (at, bpy.data.objects['Cube'].location.x))
        else:
            check("negative control: without keeping it the load takes the cursor back (%s)" % (at,),
                  at != (7.0, 8.0, 9.0))


def apply_drag(calls):
    print("\nThe Cursor's drag: Blender's own transform.translate moves the cursor alone")
    lines = calls["drag"].splitlines()
    for mode in ('OBJECT', 'EDIT'):
        build('turned')
        if mode == 'EDIT':
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
        for line, (start, end) in zip(lines, (((0.5, -0.5, 2), (1.25, 0.75, 1.5)), ((0, 0, 0), (-0.3, 2.0, 0.125)))):
            bpy.context.scene.cursor.location = start
            ob = bpy.data.objects['Cube']
            before = ob.matrix_world.copy()
            if mode == 'EDIT':
                co = [x.co.copy() for x in bmesh.from_edit_mesh(ob.data).verts]
            exec(line, {'bpy': bpy})
            moved = (Vector(bpy.context.scene.cursor.location) - Vector(end)).length
            same = ob.matrix_world == before and (mode == 'OBJECT' or all(
                (a - b.co).length == 0 for a, b in zip(co, bmesh.from_edit_mesh(ob.data).verts)))
            check("%s Mode: %s put the cursor at %s (%.1e m) and moved nothing else" % (mode.title(), line[:60], end,
                                                                                         moved), moved < 1e-6 and same)
        if mode == 'EDIT':
            bpy.ops.object.mode_set(mode='OBJECT')


def main():
    if PHASE == 'measure':
        measure(argv[1])
    elif PHASE == 'apply':
        data = json.load(open(argv[1]))
        calls = blocks(argv[2])
        apply_tool_settings()
        apply_cursor(data['scenes'], calls, data['cursors'])
        apply_undo()
        apply_drag(calls)
        apply_units(calls)
        apply_ruler(data['scenes'], calls)
        apply_overlays(data, calls)
        apply_global_overlays()
        apply_bounded_read()
        apply_final_geometry()
        apply_file_loads()
        apply_checkpoint_undo()
    print("\n%s: %d passed, %d failed" % ("ALL PASS" if fail == 0 else "FAILED", passed, fail))
    sys.exit(1 if fail else 0)


main()
