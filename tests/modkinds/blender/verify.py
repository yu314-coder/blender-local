"""Round 4, group 8, run by the Blender it runs on: Blender's whole Add
Modifier menu, the eleven declared modifier rows (Curve, Wireframe, Skin,
Hook, Armature, Surface Deform, Mesh Deform, Data Transfer, Normal Edit, Mask,
Build) and their buttons, the vertex budget for what makes geometry, a text
object's Body Text and Data tab rows, and Add ▸ Image's reference and
background pictures.

scripts/run-modkinds-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup` twice: a window and a screen but no 3D View area in
the context, as for the bpy module on a device. The app's context is built the
way the app builds it: Blender's undo started through the app's own
`_blenderkit_undo.push`, `gpu.init()`, and the startup screen's 3D View
borrowed by `_blenderkit_context.temp_override_view3d` where the app borrows
it, all loaded from the source tree. Every string run is the one the Swift
sends (tests/modkinds/blender/main.swift).

Phase 1 holds the Swift's catalog to Blender's own menus drawn for each object
type, adds every row on every object type the app draws, measures the budget,
and writes Blender's record of each declared row. Phase 2 runs the edits the
Swift built from that record, each button, the text and image rows, and
writes what Blender reported for the Swift to replay.
"""
import bpy, bmesh, gpu, sys, types, json, math, pathlib, importlib.util, contextlib, io, os, time

sys.dont_write_bytecode = True
PHASE, CALLS, OUT, WORK = sys.argv[sys.argv.index("--") + 1:][:4]
ROOT = pathlib.Path(__file__).resolve().parents[3]
HISTORY = os.path.join(WORK, "Documents", ".blender-history")
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
        blocks[head[3:].strip()] = body


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps what a pass hands over."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.points = {}
        self.records = []

    def is_main_thread(self):
        return True

    def sync_points(self, name, record, positions, flags, lines, during_pass):
        self.points[name] = record

    def sync_record(self, kind, name, record):
        self.records.append((kind, name, record))

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *a, **k: None


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
context.install(bpy)
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools", "_blenderkit_points"):
    load(sibling)
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
multires = load("_blenderkit_multires")
modifiers = load("_blenderkit_modifiers")
text = load("_blenderkit_text")
images = load("_blenderkit_images")
# The vertex budget (loaded from beside _blenderkit_multires), and what its
# Remesh count reads: _blenderkit_sculpt's estimate, which imports Knife
# Project's module — on the app's path, loaded here as the app has them.
budget = sys.modules["_blenderkit_budget"]
load("_blenderkit_knife")
load("_blenderkit_sculpt")
gpu.init()
namespace = {"bpy": bpy}


def run(source):
    """A block of what the Swift sends, in the app's namespace: the error
    text or None."""
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(source, "<swift>", "exec"), namespace)
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return (type(error).__name__ + ": " + str(error)).strip()
    return None


def push(label):
    undo.push(HISTORY, label)


def counts(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        return (len(mesh.vertices), len(mesh.edges), len(mesh.polygons), len(mesh.loops)) if mesh else (0, 0, 0, 0)
    finally:
        evaluated.to_mesh_clear()


def positions(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        return [tuple(round(c, 4) for c in v.co) for v in mesh.vertices]
    finally:
        evaluated.to_mesh_clear()


def x_range(obj):
    xs = [p[0] for p in positions(obj)]
    return (round(min(xs), 2), round(max(xs), 2)) if xs else None


def activate(obj):
    if obj is None:
        raise RuntimeError("the fixture made no object")
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj


def leave_edit():
    active = bpy.context.view_layer.objects.active
    if active is not None and active.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')


def home():
    leave_edit()
    bpy.ops.wm.read_homefile(load_ui=False)
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)


def fixture(kind):
    """One object of Blender type `kind`, active and selected."""
    home()
    if kind == 'MESH':
        bpy.ops.mesh.primitive_cube_add()
    elif kind == 'CURVE':
        bpy.ops.curve.primitive_bezier_curve_add()
    elif kind == 'FONT':
        bpy.ops.object.text_add()
    elif kind == 'SURFACE':
        bpy.ops.surface.primitive_nurbs_surface_sphere_add()
    elif kind == 'LATTICE':
        bpy.ops.object.add(type='LATTICE')
    elif kind == 'VOLUME':
        bpy.ops.object.volume_add()
    elif kind == 'GREASEPENCIL':
        bpy.ops.object.grease_pencil_add(type='EMPTY')
    elif kind == 'EMPTY':
        bpy.ops.object.empty_add()
    elif kind == 'CURVES':
        obj = bpy.data.objects.new('Curves', bpy.data.hair_curves.new('Curves'))
        bpy.context.scene.collection.objects.link(obj)
        bpy.context.view_layer.update()
        bpy.context.view_layer.objects.active = obj
    elif kind == 'POINTCLOUD':
        bpy.ops.object.pointcloud_random_add()
    elif kind == 'CAMERA':
        bpy.ops.object.camera_add()
    elif kind == 'LIGHT':
        bpy.ops.object.light_add()
    elif kind == 'ARMATURE':
        bpy.ops.object.armature_add()
    obj = bpy.context.view_layer.objects.active
    activate(obj)
    return obj


# --------------------------------------------------------------------------
# Blender's own Add Modifier menu, drawn with a layout that records rows.

class _Props:
    def __init__(self, rec):
        object.__setattr__(self, 'rec', rec)

    def __setattr__(self, k, v):
        self.rec[k] = v


class Layout:
    def __init__(self, rows, category):
        self.rows, self.category = rows, category
        self.operator_context = 'EXEC_REGION_WIN'

    def __getattr__(self, name):
        return lambda *a, **k: self

    def operator(self, idname, text=None, icon=None, **k):
        rec = dict(op=idname, text=text, category=self.category)
        self.rows.append(rec)
        return _Props(rec)

    def menu(self, name, **k):
        draw_menu(name, self.rows, getattr(bpy.types, name).bl_label)

    def menu_contents(self, name):
        pass  # asset catalogs: the device's Blender has no asset library

    def separator(self, **k):
        pass


def draw_menu(name, rows, category):
    cls = getattr(bpy.types, name)

    class Self:
        pass
    me = Self()
    me.layout = Layout(rows, category)
    me.bl_label = cls.bl_label
    for attr in ('operator_modifier_add', 'operator_modifier_add_asset'):
        if hasattr(cls, attr):
            setattr(me, attr, getattr(cls, attr))
    cls.draw(me, bpy.context)


def blender_rows(kind):
    obj = fixture(kind)
    check("the %s fixture is a %s" % (kind, kind), obj.type == kind, obj.type)
    rows = []
    draw_menu("OBJECT_MT_modifier_add", rows, "")
    out = []
    for r in rows:
        if r['op'] == 'object.modifier_add':
            out.append((r['category'], r['type'], r['text']))
        elif r['op'] == 'object.modifier_add_node_group':
            out.append((r['category'], r['relative_asset_identifier'].rsplit('/', 1)[-1], r['text']))
    return out


def phase1():
    print("Add Modifier against Blender's own menus")
    for kind in ("MESH", "CURVE", "FONT", "SURFACE", "LATTICE", "VOLUME", "GREASEPENCIL", "EMPTY", "CURVES",
                 "POINTCLOUD", "CAMERA", "LIGHT", "ARMATURE"):
        swift = [tuple(line.split("\t")[:3]) for line in blocks["CATALOG " + kind].splitlines() if line]
        theirs = blender_rows(kind)
        check("%s: every row of Blender's Add Modifier, in its order and words (%d)" % (kind, len(theirs)),
              swift == theirs, "\n    swift   %s\n    blender %s" % (swift, theirs))
        if kind == "MESH":
            check("control: one row left out does not match", swift[:-1] != theirs and swift[1:] != theirs)

    print("\nevery row added, on every object type the app draws")
    for kind in ("MESH", "CURVE", "FONT", "SURFACE", "LATTICE"):
        added = refused = 0
        for name, source in blocks.items():
            if not name.startswith("ADD %s " % kind):
                continue
            row = name.split(" ", 2)[2]
            fixture(kind)
            push("fixture")
            # The first push probes Blender's undo, which reloads the scene.
            obj = bpy.context.view_layer.objects.active
            before = len(obj.modifiers)
            error = run(source)
            if row in modifiers.ESSENTIALS_ASSETS:
                check("%s ▸ %s: the Essentials row says why it adds nothing" % (kind, row),
                      error is not None and ("Essentials" in error or "had not finished loading" in error)
                      and len(obj.modifiers) == before, error)
                refused += 1
                continue
            ok = error is None and len(obj.modifiers) == before + 1 and obj.modifiers[-1].type == row \
                if row != 'MULTIRES' else error is None and any(m.type == row for m in obj.modifiers)
            check("%s ▸ %s added" % (kind, row), ok, error)
            if ok:
                added += 1
                try:
                    sync.sync()
                    record = sync._modifier_record(obj)
                    check("%s ▸ %s: the pass reads it" % (kind, row), ("kind=" + row) in record, record)
                except Exception as error:         # noqa: BLE001
                    check("%s ▸ %s: the pass reads it" % (kind, row), False, error)
        print("    %s: %d added, %d Essentials rows refused" % (kind, added, refused))

    print("\nthe vertex budget for what makes geometry")
    def grid(n):
        fixture('MESH')
        bpy.ops.object.delete()
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n)
        return bpy.context.object

    def exact(label, obj):
        check(label + ": counted %d, Blender evaluates %d" % (multires.stack_vertices(obj), counts(obj)[0]),
              multires.stack_vertices(obj) == counts(obj)[0])

    for prim in ('cube', 'sphere', 'grid', 'monkey'):
        fixture('MESH')
        bpy.ops.object.delete()
        {'cube': bpy.ops.mesh.primitive_cube_add, 'sphere': bpy.ops.mesh.primitive_uv_sphere_add,
         'grid': lambda: bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10),
         'monkey': bpy.ops.mesh.primitive_monkey_add}[prim]()
        obj = bpy.context.object
        m = obj.modifiers.new('W', 'WIREFRAME')
        m.use_boundary = True
        exact("Wireframe on a %s with Boundary" % prim, obj)
        m.use_replace = False
        exact("and Replace Original off", obj)
        obj.modifiers.remove(m)
        m = obj.modifiers.new('S', 'SKIN')
        check("Skin on a %s: the estimate %d bounds Blender's %d" % (prim, multires.stack_vertices(obj), counts(obj)[0]),
              multires.stack_vertices(obj) >= counts(obj)[0])
        obj.modifiers.remove(m)
    fixture('MESH')
    cube = bpy.context.object
    m = cube.modifiers.new('S', 'SCREW')
    exact("Screw on a cube, a full turn", cube)
    m.angle = math.pi
    m.steps = 8
    exact("half a turn in 8 steps", cube)
    m.angle = 2 * math.pi
    m.iterations = 2
    exact("two iterations", cube)
    cube.modifiers.remove(m)
    m = cube.modifiers.new('O', 'OCEAN')
    m.viewport_resolution = 4
    m.repeat_x, m.repeat_y = 2, 3
    exact("Ocean at resolution 4, repeat 2 x 3", cube)
    real_ocean = budget._GROWTH['OCEAN']
    budget._GROWTH['OCEAN'] = budget._keep
    check("control: counting the Ocean as the mesh it replaces is wrong",
          multires.stack_vertices(cube) != counts(cube)[0])
    budget._GROWTH['OCEAN'] = real_ocean

    def attempt(fn):
        try:
            fn()
            return "ran"
        except RuntimeError as error:
            return str(error)

    obj = grid(30)
    said = attempt(lambda: multires.check_add('SKIN', obj))
    check("Skin on a 30 x 30 grid's 900 loops is refused for its time", "900 closed loops" in said, said)
    fixture('MESH')
    bpy.ops.object.delete()
    me = bpy.data.meshes.new('chain')
    chain = bpy.data.objects.new('chain', me)
    bpy.context.collection.objects.link(chain)
    me.from_pydata([(i * 0.1, 0, 0) for i in range(20000)], [(i, i + 1) for i in range(19999)], [])
    activate(chain)
    check("and on a chain of 20,000 edges, added", attempt(lambda: multires.check_add('SKIN', chain)) == "ran")
    obj = grid(700)
    said = attempt(lambda: multires.check_add('WIREFRAME', obj))
    check("Wireframe on a 700 x 700 grid (2(V+E) past 2,500,000) is refused", "2,500,000" in said, said)
    check("a Subdivision Surface on it passes alone (1,962,801)", attempt(lambda: multires.check_add('SUBSURF', obj)) == "ran")
    obj.modifiers.new('Subdivision', 'SUBSURF')
    check("and after one already in the stack is refused: the stack is counted",
          "2,500,000" in attempt(lambda: multires.check_add('SUBSURF', obj)))
    obj = grid(10)
    check("Wireframe on a 10 x 10 grid passes", attempt(lambda: multires.check_add('WIREFRAME', obj)) == "ran")
    m = obj.modifiers.new('Ocean', 'OCEAN')
    check("Ocean Resolution 40 ((1600+1)² vertices) is refused",
          "2,500,000" in attempt(lambda: multires.check_setting('Ocean', 'viewport_resolution', 40, obj)))
    check("30 passes", attempt(lambda: multires.check_setting('Ocean', 'viewport_resolution', 30, obj)) == "ran")
    obj.modifiers.remove(m)
    obj = grid(100)
    m = obj.modifiers.new('Screw', 'SCREW')
    check("Screw Steps 512 on a 100 x 100 grid is refused",
          "2,500,000" in attempt(lambda: multires.check_setting('Screw', 'steps', 512, obj)))
    check("200 passes", attempt(lambda: multires.check_setting('Screw', 'steps', 200, obj)) == "ran")
    obj.modifiers.remove(m)
    obj = grid(700)
    m = obj.modifiers.new('Wireframe', 'WIREFRAME')
    m.show_viewport = False
    activate(obj)
    error = run(blocks["WIRE KEEP"])
    check("Wireframe's Replace Original off is priced with the row's own line", error and "Replace Original" in error, error)
    fixture('MESH')
    bpy.ops.object.delete()
    bpy.ops.mesh.primitive_uv_sphere_add()
    sphere = bpy.context.object
    s = sphere.modifiers.new('Subdivision', 'SUBSURF')
    s.levels = 7
    s.show_viewport = False
    error = run(blocks["SHOW Subdivision"])
    check("showing a hidden Subdivision at level 7 on a sphere is refused with the row's own line",
          error and "Showing Subdivision" in error and not s.show_viewport, error)
    s.levels = 1
    error = run(blocks["SHOW Subdivision"])
    check("at level 1 it is shown", error is None and s.show_viewport, error)

    print("\nBlender's record of each declared row")
    cube = declared_fixture()
    records = {m.type: sync._modifier_entry(cube, m, True) for m in cube.modifiers}
    records["objects"] = {"CURVE object": "Circle", "HOOK object": "Empty.001", "ARMATURE object": "Armature.001",
                          "SURFACE_DEFORM target": "Plane.001", "MESH_DEFORM object": "Cage.001",
                          "DATA_TRANSFER object": "Source.001", "NORMAL_EDIT target": "Empty",
                          "MASK armature": "Armature"}
    for name, source in blocks.items():
        if name.startswith("FIELDS "):
            kind = name.split(" ")[1]
            lines = source.splitlines()
            m = cube.modifiers[lines[0]]
            check("%s: Blender names a new one %s, and its type %s" % (kind, lines[0], lines[1]),
                  m.type == kind and m.bl_rna.properties['type'].enum_items[kind].name == lines[1])
            for line in lines[2:]:
                key, label, tag, choices, panel = (line.split("\t") + [""] * 5)[:5]
                prop = m.bl_rna.properties.get(key)
                if tag == "readonly" and prop is None:
                    continue  # derived (the Hook's vertex count)
                check("%s %s (%s) is a property Blender has" % (kind, key, label), prop is not None)
                if prop is None:
                    continue
                if tag in ("choice", "flags"):
                    theirs = [(i.identifier, i.name) for i in prop.enum_items]
                    ours = [tuple(c.split("=", 1)) for c in choices.split(",") if c]
                    check("%s %s: Blender's items and names" % (kind, key), ours == theirs, (ours, theirs))
                    check("%s %s: a set exactly when Blender's is" % (kind, key), (tag == "flags") == prop.is_enum_flag)
                expected = {"number": "FLOAT", "integer": "INT", "toggle": "BOOLEAN", "vector3": "FLOAT",
                            "object": "POINTER", "choice": "ENUM", "flags": "ENUM", "readonly": prop.type}[tag]
                check("%s %s: a %s, as Blender's" % (kind, key, tag), prop.type == expected, prop.type)
                if tag == "readonly":
                    check("%s %s: read-only in Blender too" % (kind, key), prop.is_readonly)
    json.dump(records, open(OUT, "w"))


def declared_fixture():
    """A cube with every declared row added through the Swift's own add
    line, a group "Top" on its upper half, and an object for each pointer —
    two of each, so an edit can pick the other."""
    home()
    for i, (name, maker) in enumerate((("BézierCurve", lambda: bpy.ops.curve.primitive_bezier_curve_add()),
                                       ("Circle", lambda: bpy.ops.curve.primitive_bezier_circle_add()),
                                       ("Empty", lambda: bpy.ops.object.empty_add(location=(2, 0, 0))),
                                       ("Empty.001", lambda: bpy.ops.object.empty_add(location=(0, 2, 0))),
                                       ("Armature", lambda: bpy.ops.object.armature_add(location=(0, 0, -1))),
                                       ("Armature.001", lambda: bpy.ops.object.armature_add(location=(0, 0, 1))),
                                       ("Plane", lambda: bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, -1.5))),
                                       ("Plane.001", lambda: bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, 1.5))),
                                       ("Cage", lambda: bpy.ops.mesh.primitive_cube_add(size=4)),
                                       ("Cage.001", lambda: bpy.ops.mesh.primitive_cube_add(size=5)),
                                       ("Source", lambda: bpy.ops.mesh.primitive_cube_add()),
                                       ("Source.001", lambda: bpy.ops.mesh.primitive_cube_add()))):
        maker()
        bpy.context.object.name = name
    for name in ("Source", "Source.001"):
        source = bpy.data.objects[name]
        g = source.vertex_groups.new(name="Top")
        g.add([v.index for v in source.data.vertices if v.co.z > 0], 1.0, 'REPLACE')
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    cube.name = "Cube"
    g = cube.vertex_groups.new(name="Top")
    g.add([v.index for v in cube.data.vertices if v.co.z > 0], 1.0, 'REPLACE')
    activate(cube)
    push("fixture")
    cube = bpy.data.objects["Cube"]
    for kind in ("CURVE", "WIREFRAME", "SKIN", "HOOK", "ARMATURE", "SURFACE_DEFORM", "MESH_DEFORM",
                 "DATA_TRANSFER", "NORMAL_EDIT", "MASK", "BUILD"):
        error = run(blocks["ADD MESH " + kind])
        check("Add Modifier ▸ %s on the fixture" % kind, error is None, error)
    pointers = {"Curve": ("object", "BézierCurve"), "Hook": ("object", "Empty"),
                "SurfaceDeform": ("target", "Plane"), "MeshDeform": ("object", "Cage"),
                "DataTransfer": ("object", "Source"), "Mask": ("vertex_group", "Top")}
    for name, (key, value) in pointers.items():
        setattr(cube.modifiers[name], key, bpy.data.objects[value] if key != "vertex_group" else value)
    # Everything shown off, so the cube stays light while the edits run.
    for m in cube.modifiers:
        m.show_viewport = m.type in ('CURVE', 'HOOK')
    return cube


# --------------------------------------------------------------------------

def phase2():
    print("each declared row's edits, as the Swift built them from Blender's record")
    cube = declared_fixture()
    replay = dict(edits=[])
    for name, source in blocks.items():
        if not name.startswith("EDIT "):
            continue
        head, expected = name.split("\t")
        _, kind, key = head.split(" ")
        modifier = next(m for m in cube.modifiers if m.type == kind)
        error = run(source)
        value = getattr(modifier, key)
        if hasattr(value, 'name'):
            held = value.name
        elif value is None:
            held = ""
        elif isinstance(value, bool):
            held = "1" if value else "0"
        elif isinstance(value, (set, frozenset)):
            held = ",".join(sorted(value))
        elif isinstance(value, (int, float)):
            held = repr(float(value))
        elif isinstance(value, str):
            held = value
        else:
            held = ",".join(repr(float(c)) for c in value)
        same = held == expected
        if not same:
            try:
                if "," in expected:
                    same = all(abs(float(a) - float(b)) < 1e-4 for a, b in zip(held.split(","), expected.split(",")))
                else:
                    same = abs(float(held) - float(expected)) < 1e-4
            except ValueError:
                same = set(held.split(",")) - {""} == set(expected.split(",")) - {""}
        check("%s %s = %s reaches Blender" % (kind, key, expected), error is None and same, (error, held))
        replay["edits"].append(dict(type=kind, key=key, expected=held, record=sync._modifier_record(cube)))

    print("\nCurve: the object and the axis, measured")
    cube = declared_fixture()
    curve = cube.modifiers["Curve"]
    curve.object = None
    for m in cube.modifiers:
        m.show_viewport = m.name == "Curve"
    error = run("bpy.context.object.modifiers[\"Curve\"].object = bpy.data.objects[\"BézierCurve\"]")
    check("the cube's X range [-1, 1] bends to [-2.47, 0.15] along the Bézier", x_range(cube) == (-2.47, 0.15),
          x_range(cube))
    for v in cube.data.vertices:
        v.co.x *= 1.5
        v.co.z *= 0.25
    cube.data.update()
    shapes = {}
    for axis in ("POS_X", "POS_Y", "NEG_X"):
        curve.deform_axis = axis
        shapes[axis] = positions(cube)
    check("on a box, Deform Axis X, Y and -X bend it three ways",
          shapes["POS_X"] != shapes["POS_Y"] and shapes["POS_X"] != shapes["NEG_X"])

    print("\nData Transfer's Mix Mode: the Swift's list is Blender's")
    for line in blocks["MIXRULES"].splitlines():
        toggle, key, types, allowed = (line.split("\t") + [""] * 4)[:4]
        home()
        bpy.ops.mesh.primitive_cube_add()
        m = bpy.context.object.modifiers.new("DataTransfer", 'DATA_TRANSFER')
        setattr(m, toggle, True)
        setattr(m, key, set(t for t in types.split(",") if t))
        taken = []
        for mode in ('REPLACE', 'ABOVE_THRESHOLD', 'BELOW_THRESHOLD', 'MIX', 'ADD', 'SUB', 'MUL'):
            try:
                m.mix_mode = mode
                taken.append(mode)
            except TypeError:
                pass
        check("with %s: Blender takes %s" % (types or "nothing", ",".join(taken)), ",".join(taken) == allowed, allowed)

    print("\nthe Vertex Group field changes what each does")
    vertex_group_effects()

    print("\nthe buttons")
    buttons()

    print("\nthe text")
    replay.update(text_rows())

    print("\nthe pictures")
    replay["images"] = image_rows()

    print("\nround 4's review of this group: the text's price")
    replay.update(text_price())
    print("\nthe budget on a text, a curve and a surface")
    curve_budget()
    print("\nScrew, Ocean, Skin, a move, Edge Split")
    stack_prices()
    print("\nwhat Blender is handed for a picture")
    pictures()
    json.dump(replay, open(OUT, "w"))


def vertex_group_effects():
    cases = {
        'CURVE': lambda c, m: setattr(m, 'object', bpy.data.objects['BézierCurve']),
        'WIREFRAME': lambda c, m: setattr(m, 'thickness_vertex_group', 0.5),
        'HOOK': lambda c, m: (setattr(m, 'object', bpy.data.objects['Empty'])),
        'ARMATURE': lambda c, m: setattr(m, 'object', bpy.data.objects['Armature']),
        'NORMAL_EDIT': lambda c, m: None,
        'MASK': lambda c, m: None,
        'DATA_TRANSFER': lambda c, m: (setattr(m, 'object', bpy.data.objects['Source']),
                                       setattr(m, 'use_loop_data', True),
                                       setattr(m, 'data_types_loops', {'CUSTOM_NORMAL'})),
        'SURFACE_DEFORM': None, 'MESH_DEFORM': None,
    }
    for kind, prepare in cases.items():
        home()
        for maker in (lambda: bpy.ops.curve.primitive_bezier_curve_add(), lambda: bpy.ops.object.empty_add(location=(2, 0, 0)),
                      lambda: bpy.ops.object.armature_add(location=(0, 0, -1)),
                      lambda: bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, -1.5)),
                      lambda: bpy.ops.mesh.primitive_cube_add(size=4), lambda: bpy.ops.mesh.primitive_cube_add()):
            maker()
        bpy.data.objects['Cube.001'].name = 'Source'
        bpy.data.objects['Cube'].name = 'Cage'
        source = bpy.data.objects['Source']
        for p in source.data.polygons:
            p.use_smooth = True
        bpy.ops.mesh.primitive_uv_sphere_add()
        obj = bpy.context.object
        g = obj.vertex_groups.new(name="Left")
        g.add([v.index for v in obj.data.vertices if v.co.x < 0], 1.0, 'REPLACE')
        activate(obj)
        m = obj.modifiers.new(kind.title(), kind)
        if kind == 'HOOK':
            # Every vertex assigned, so the group alone limits what moves.
            obj.data.vertices.foreach_set('select', [True] * len(obj.data.vertices))
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
            m.object = bpy.data.objects['Empty']
            bpy.ops.object.hook_assign(modifier=m.name)
            bpy.ops.object.mode_set(mode='OBJECT')
            bpy.data.objects['Empty'].location = (3, 0, 1)
        if kind == 'ARMATURE':
            arm = bpy.data.objects['Armature']
            arm.pose.bones[0].rotation_mode = 'XYZ'
            arm.pose.bones[0].rotation_euler = (0.6, 0, 0)
            m.use_bone_envelopes = True
            arm.data.bones[0].envelope_distance = 5
        if kind == 'SURFACE_DEFORM':
            m.target = bpy.data.objects['Plane']
            bpy.ops.object.surfacedeform_bind(modifier=m.name)
            bpy.context.view_layer.update()
            bpy.data.objects['Plane'].data.vertices[0].co.z -= 2
            bpy.data.objects['Plane'].data.update()
        if kind == 'MESH_DEFORM':
            m.object = bpy.data.objects['Cage']
            m.precision = 3
            bpy.ops.object.meshdeform_bind(modifier=m.name)
            bpy.context.view_layer.update()
            for v in bpy.data.objects['Cage'].data.vertices:
                v.co.z += 1 if v.co.z > 0 else 0
            bpy.data.objects['Cage'].data.update()
        if prepare is not None:
            prepare(obj, m)

        def look():
            if kind in ('NORMAL_EDIT', 'DATA_TRANSFER'):
                depsgraph = bpy.context.evaluated_depsgraph_get()
                evaluated = obj.evaluated_get(depsgraph)
                mesh = evaluated.to_mesh()
                try:
                    return [tuple(round(c, 3) for c in n.vector) for n in mesh.corner_normals]
                finally:
                    evaluated.to_mesh_clear()
            return (counts(obj), positions(obj))
        without = look()
        error = run("bpy.context.object.modifiers[%r].vertex_group = 'Left'" % m.name)
        with_group = look()
        run("bpy.context.object.modifiers[%r].invert_vertex_group = True" % m.name)
        inverted = look()
        check("%s: the group changes what it makes, and Invert changes it again" % kind,
              error is None and with_group != without and inverted != with_group, error)


def attempt(source):
    error = run(source)
    return "ran" if error is None else error


def op(name):
    return blocks["OP " + name].split("\n", 1)[1]


def buttons():
    cube = declared_fixture()
    for m in cube.modifiers:
        m.show_viewport = m.type in ('HOOK',)
    said = attempt(op("hook_assign"))
    check("Hook Assign in Object Mode is refused in words", "works in Edit Mode" in said, said)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.object.mode_set(mode='OBJECT')
    for v in cube.data.vertices:
        v.select = v.co.x > 0
    bpy.ops.object.mode_set(mode='EDIT')
    check("Assign in Edit Mode takes the four selected", attempt(op("hook_assign")) == "ran"
          and len(cube.modifiers["Hook"].vertex_indices) == 4, list(cube.modifiers["Hook"].vertex_indices))
    for name in ("hook_reset", "hook_recenter", "hook_select"):
        check("Hook %s in Edit Mode runs" % name, attempt(op(name)) == "ran")
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.data.objects["Empty"].location = (4, 0, 0)
    check("the hooked vertices follow the Empty", x_range(cube)[1] > 1.5, x_range(cube))

    deform = cube.modifiers["SurfaceDeform"]
    deform.target = bpy.data.objects["Plane"]
    said = attempt(op("bind_surface"))
    check("Bind on a modifier hidden in the viewport is refused: Blender binds when it evaluates",
          "Show in Viewport" in said and not deform.is_bound, said)
    deform.show_viewport = True
    cube.modifiers["MeshDeform"].show_viewport = True
    deform.target = None
    said = attempt(op("bind_surface"))
    check("Surface Deform Bind with no Target is refused", "has none" in said and not deform.is_bound, said)
    deform.target = bpy.data.objects["Plane"]
    check("Bind binds", attempt(op("bind_surface")) == "ran" and deform.is_bound)
    check("and again unbinds", attempt(op("bind_surface")) == "ran" and not deform.is_bound)
    bpy.ops.object.mode_set(mode='EDIT')
    check("from Edit Mode it binds too, in Object Mode, and comes back",
          attempt(op("bind_surface")) == "ran" and deform.is_bound and cube.mode == 'EDIT')
    bpy.ops.object.mode_set(mode='OBJECT')

    mesh_deform = cube.modifiers["MeshDeform"]
    mesh_deform.precision = 2
    start = time.time()
    check("Mesh Deform Bind at Precision 2 binds", attempt(op("bind_mesh")) == "ran" and mesh_deform.is_bound)
    print("    (%.2f s)" % (time.time() - start))
    attempt(op("bind_mesh"))
    mesh_deform.precision = 6
    said = attempt(op("bind_mesh"))
    check("at Precision 6 it is refused before Blender runs, which would not finish",
          "Precision 6" in said and not mesh_deform.is_bound, said)
    # Control: with the cap lifted the module calls Blender's operator, which
    # a proxy records instead of running.
    called = []
    real = modifiers.bpy

    class Ops:
        def __getattr__(self, name):
            if name == 'meshdeform_bind':
                return lambda **k: called.append(k) or {'FINISHED'}
            return getattr(real.ops.object, name)

    class Proxy:
        ops = types.SimpleNamespace(object=Ops())

        def __getattr__(self, name):
            return getattr(real, name)
    modifiers.bpy = Proxy()
    modifiers.MESH_DEFORM_MAX_PRECISION = 10
    try:
        attempt(op("bind_mesh"))
    finally:
        modifiers.bpy = real
        modifiers.MESH_DEFORM_MAX_PRECISION = 5
    check("control: without the cap the operator would have run", called == [{'modifier': 'MeshDeform'}], called)

    transfer = cube.modifiers["DataTransfer"]
    transfer.use_vert_data = True
    transfer.data_types_verts = {'VGROUP_WEIGHTS'}
    cube.vertex_groups.clear()
    check("Generate Data Layers makes the Source's group on the cube",
          attempt(op("generate")) == "ran" and [g.name for g in cube.vertex_groups] == ["Top"],
          [g.name for g in cube.vertex_groups])
    transfer.object = None
    check("and with no Source is refused", "no Source" in attempt(op("generate")))

    said = attempt(op("skin_root"))
    check("Skin's Mark Root in Object Mode is refused in words", "works in Edit Mode" in said, said)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    for name in ("skin_root", "skin_loose_mark", "skin_loose_clear", "skin_equalize"):
        check("Skin %s in Edit Mode runs" % name, attempt(op(name)) == "ran")
    bpy.ops.object.mode_set(mode='OBJECT')
    before = len(bpy.data.armatures)
    check("Create Armature makes one", attempt(op("skin_armature")) == "ran" and len(bpy.data.armatures) == before + 1)


def text_rows():
    out = {}
    home()
    bpy.ops.object.text_add()
    obj = bpy.context.object
    obj.name = "Text"
    activate(obj)
    push("Add Text")
    obj = bpy.data.objects["Text"]
    error = run(blocks["TEXT BODY"])
    check("the Body Text field's line sets data.body", error is None
          and obj.data.body == 'Hello;=|%\nWorld é "quoted"', (error, obj.data.body))
    push("Body Text")
    obj = bpy.data.objects["Text"]
    check("and the drawn text is rebuilt", counts(obj)[0] > 177, counts(obj))
    bpy.ops.ed.undo()
    check("Undo puts the body back", bpy.data.objects["Text"].data.body == "Text", bpy.data.objects["Text"].data.body)
    bpy.ops.ed.redo()
    obj = bpy.data.objects["Text"]
    check("Redo the new one", obj.data.body.startswith("Hello"))
    said = attempt(blocks["TEXT LONG"])
    check("9,000 characters, past Blender's 8,192, are refused", "8192" in said and obj.data.body.startswith("Hello"), said)
    for name, source in blocks.items():
        if not name.startswith("TEXT SET "):
            continue
        _, _, key, value = name.split(" ")
        error = run(source)
        held = getattr(obj.data, key)
        same = held == value if isinstance(held, str) else abs(float(held) - float(value)) < 1e-4
        check("Data tab %s = %s reaches Blender" % (key, value), error is None and same, (error, held))
    body = "abcdefghij" * 100
    obj.data.body = body
    obj.data.extrude, obj.data.bevel_depth, obj.data.bevel_resolution, obj.data.resolution_u = 0.1, 0.02, 4, 12
    # The rows above left Fill Mode Front and Offset 0.01; the review's case
    # is the default fill, and the Offset's extra vertices are measured below.
    obj.data.fill_mode, obj.data.offset = 'BOTH', 0.0
    drawn = counts(obj)[0]
    priced = text.vertices(obj, resolution_u=64)
    said = attempt(blocks["TEXT HUGE"])
    check("Resolution Preview U 64 on 1,000 bevelled characters (%s now, %s priced, as Blender's 5,366 × 100 × 14)"
          " is refused" % (format(drawn, ','), format(priced, ',')),
          priced == 5366 * 100 * 14 and format(priced, ',') in said and obj.data.resolution_u == 12, said)
    check("control: 1,000 flat characters at 12 pass", text.vertices(obj, extrude=0.0, bevel_depth=0.0) < 2_500_000)
    for case in (dict(extrude=0.0, bevel_depth=0.0, bevel_resolution=4, resolution_u=12),
                 dict(extrude=0.1, bevel_depth=0.0, bevel_resolution=4, resolution_u=12),
                 dict(extrude=0.1, bevel_depth=0.02, bevel_resolution=4, resolution_u=6)):
        obj.data.body = "abcdefghij" * 10
        for k, v in case.items():
            setattr(obj.data, k, v)
        for offset in (0.0, 0.01):
            obj.data.offset = offset
            obj.data.body = "abcdefghij" * 10
            guess = text.vertices(obj, body="abcdefghij" * 30)
            obj.data.body = "abcdefghij" * 30
            then = counts(obj)[0]
            if offset == 0:
                check("the price of three times the text (%s) is Blender's %s" % (guess, then), guess == then)
            else:
                check("with Offset 0.01, whose fill adds where outlines cross, never below Blender's %s and "
                      "within 1%% (%s)" % (then, guess), then <= guess <= then * 1.01)
        obj.data.offset = 0.0
    obj.data.extrude, obj.data.bevel_depth, obj.data.resolution_u = 0.0, 0.0, 12
    obj.data.body = "Hello;=|%\nWorld"
    error = run(blocks["TEXT EDITMODE"])
    check("Edit Mode on a text says where its text is typed, and Blender stays in Object Mode",
          error is not None and "Body Text" in error and obj.mode == 'OBJECT', error)
    bpy.ops.object.mode_set(mode='EDIT')
    said = attempt(blocks["TEXT BODY"])
    check("a body written while a script has it in Blender's Edit Mode is refused", "Edit Mode" in said, said)
    bpy.ops.object.mode_set(mode='OBJECT')
    bridge.points.clear()
    sync.sync()
    out["text"] = bridge.points.get("Text", "")
    check("the pass hands the Data tab the text's record", "body=" in out["text"], out["text"][:80])
    out["text_held"] = dict(body=obj.data.body, **{k: (getattr(obj.data, k) if isinstance(getattr(obj.data, k), str)
                                                       else repr(float(getattr(obj.data, k)))) for k in text.FIELDS})
    return out


def image_rows():
    out = {}
    home()
    bpy.ops.mesh.primitive_cube_add()
    activate(bpy.context.object)
    image = bpy.data.images.new("src", 64, 32, alpha=True)
    image.pixels = [c for y in range(32) for x in range(64)
                    for c in ((1, 0, 0, 1) if x < 32 else (0, 0, 1, 1 if y < 30 else 0))]
    picture = os.path.join(WORK, "ref;1.png")
    image.filepath_raw = picture
    image.file_format = 'PNG'
    image.save()
    bpy.data.images.remove(image)
    check("control: the Operator Search's context refuses Blender's operator, as measured",
          "context" in attempt("__import__('_blenderkit_sync').run_operator('object.empty_image_add', "
                               "{'filepath': %r, 'relative_path': False})" % picture))
    for name in ("IMAGE REF", "IMAGE BG ORTHO", "IMAGE BG PERSP"):
        error = run(blocks[name].replace("{PATH}", picture))
        obj = bpy.context.view_layer.objects.active
        check(name + ": an image empty with the picture, Size 5", error is None and obj.type == 'EMPTY'
              and obj.empty_display_type == 'IMAGE' and obj.data is not None and tuple(obj.data.size) == (64, 32)
              and abs(obj.empty_display_size - 5) < 1e-6, error)
        check(name + ": packed into the .blend", obj.data.packed_file is not None)
        push(name)
        obj = bpy.context.view_layer.objects.active
        if name == "IMAGE REF":
            check("Reference: at the cursor, facing the view, Depth Default and both sides",
                  tuple(round(c, 4) for c in obj.location) == (1, 2, 3) and round(obj.rotation_euler.x, 4) == 0.5
                  and obj.empty_image_depth == 'DEFAULT' and obj.empty_image_side == 'DOUBLE_SIDED')
            obj.name = "Reference"
        elif name == "IMAGE BG ORTHO":
            check("Background from an orthographic view: Back, Front side, hidden in perspective",
                  obj.empty_image_depth == 'BACK' and obj.empty_image_side == 'FRONT'
                  and not obj.show_empty_image_perspective and obj.show_empty_image_orthographic)
            obj.name = "Background"
        else:
            check("from a perspective view, shown in both", obj.show_empty_image_perspective)
            obj.name = "Background.persp"
    os.remove(picture)
    path = images.image_file(bpy.data.objects["Reference"].data)
    check("with its file gone, the picture comes from the packed bytes", os.path.isfile(path) and path != picture
          and open(path, 'rb').read(8) == b'\x89PNG\r\n\x1a\n', path)
    said = attempt(blocks["IMAGE REF"].replace("{PATH}", picture))
    check("a file that is not there is refused in words", "is not there" in said, said)
    bpy.ops.object.select_all(action='DESELECT')
    cube = bpy.data.objects["Cube"]
    activate(cube)
    bpy.ops.object.mode_set(mode='EDIT')
    picture2 = os.path.join(WORK, "again.png")
    open(picture2, 'wb').write(open(path, 'rb').read())
    said = attempt(blocks["IMAGE REF"].replace("{PATH}", picture2))
    check("Add ▸ Image in Edit Mode is refused, as Blender's operator", "Object Mode" in said, said)
    bpy.ops.object.mode_set(mode='OBJECT')
    reference = bpy.data.objects["Reference"]
    activate(reference)
    for name, source in blocks.items():
        if not name.startswith("EMPTY SET "):
            continue
        key = name.split(" ", 2)[2]
        error = run(source.replace("{NAME}", "Reference"))
        check("Empty panel %s reaches Blender" % key, error is None, error)
    check("each as Blender holds it", reference.empty_image_depth == 'FRONT' and reference.empty_image_side == 'BACK'
          and not reference.show_empty_image_orthographic and not reference.show_empty_image_perspective
          and reference.show_empty_image_only_axis_aligned and reference.use_empty_image_alpha
          and abs(reference.color[3] - 0.4) < 1e-6 and tuple(round(c, 4) for c in reference.empty_image_offset) == (-0.25, 0))
    error = run(blocks["EMPTY SIZE"].replace("{NAME}", "Reference"))
    check("and its Size", error is None and abs(reference.empty_display_size - 2.5) < 1e-6, error)
    said = attempt(blocks["EMPTY SET empty_image_depth"].replace("{NAME}", "Reference").replace("'FRONT'", "'SIDEWAYS'"))
    check("control: a Depth Blender does not have is refused", "takes" in said, said)
    for name in ("Reference", "Background", "Background.persp"):
        obj = bpy.data.objects[name]
        _, record = sync._display_record(obj)
        out[name] = dict(record=record, depth=obj.empty_image_depth, side=obj.empty_image_side,
                         ortho="1" if obj.show_empty_image_orthographic else "0",
                         persp="1" if obj.show_empty_image_perspective else "0",
                         axis="1" if obj.show_empty_image_only_axis_aligned else "0",
                         alpha="1" if obj.use_empty_image_alpha else "0", opacity=repr(float(obj.color[3])))
    bpy.ops.ed.undo()
    check("Undo takes the last step back", True)
    return out


def text_object(body):
    home()
    bpy.ops.object.text_add()
    name = bpy.context.object.name
    push("Add Text")
    obj = bpy.data.objects[name]
    obj.name = "Text"
    activate(obj)
    obj.data.body = body
    return obj


def text_price():
    out = {}
    obj = text_object("I")
    d = obj.data
    d.resolution_u, d.bevel_depth, d.bevel_resolution = 64, 0.02, 32
    check("the review's start: 'I' at Resolution U 64 and Bevel Resolution 32 is %d vertices" % counts(obj)[0],
          counts(obj)[0] == 276 and text.vertices(obj) == 276, (counts(obj)[0], text.vertices(obj)))
    said = attempt(blocks["TEXT O1000"])
    check("and the Body Text field's 1,000 'O' is refused at Blender's own count, 512 × 69 × 1,000",
          "35,328,000" in said and d.body == "I", said)
    error = run(blocks["TEXT O10"])
    check("ten 'O' pass and Blender makes what was priced (%d)" % counts(obj)[0],
          error is None and d.body == "O" * 10 and counts(obj)[0] == 353280, (error, counts(obj)[0]))
    # Exact, letter by letter and setting by setting, against what Blender
    # builds: the old estimate scaled what the text made now.
    worst = []
    cases = [dict(), dict(extrude=0.1), dict(bevel_depth=0.02, bevel_resolution=8), dict(bevel_depth=-0.02, bevel_resolution=8),
             dict(extrude=0.1, bevel_depth=0.01, bevel_resolution=3, fill_mode='FRONT'), dict(fill_mode='NONE', extrude=0.2),
             dict(fill_mode='BACK', bevel_depth=0.03, bevel_resolution=2), dict(bevel_mode='PROFILE', bevel_depth=0.02, bevel_resolution=5, fill_mode='NONE')]
    for body in ("I", "O", "@", "abcdefghij", "Hello, World!"):
        for res in (12, 64):
            for case in cases:
                for k, v in dict(extrude=0.0, bevel_depth=0.0, bevel_resolution=4, fill_mode='BOTH', bevel_mode='ROUND').items():
                    setattr(d, k, v)
                d.body, d.resolution_u = "x", 3
                guess = text.vertices(obj, body=body, resolution_u=res, **case)
                for k, v in case.items():
                    setattr(d, k, v)
                d.body, d.resolution_u = body, res
                real = counts(obj)[0]
                if guess != real:
                    worst.append((body, res, case, guess, real))
    check("the price is Blender's count for 5 bodies × 2 resolutions × 8 Extrude, Bevel and Fill settings, "
          "priced from another text", not worst, worst[:3])
    # Geometry ▸ Offset: the fill gets a vertex where an outline crosses
    # itself, which the outline alone does not count.
    under, over = [], 0.0
    for body in ("*", "@", "abcdefghij", "W&%"):
        for offset in (0.02, -0.5, 10.0):
            for res in (1, 3, 12):
                for case in (dict(), dict(extrude=0.1), dict(bevel_depth=0.02, bevel_resolution=2)):
                    for k, v in dict(extrude=0.0, bevel_depth=0.0, bevel_resolution=4, fill_mode='BOTH').items():
                        setattr(d, k, v)
                    for k, v in case.items():
                        setattr(d, k, v)
                    d.body, d.offset, d.resolution_u = body, offset, res
                    real, guess = counts(obj)[0], text.vertices(obj)
                    if guess < real:
                        under.append((body, offset, res, case, guess, real))
                    over = max(over, (guess - real) / real)
    check("with an Offset the price is never below Blender's count (108 cases, at most %.1f%% over)" % (100 * over),
          not under and over < 0.02, under[:3])
    d.offset = 0.0
    real = text._fill_extra
    text._fill_extra = lambda data: 0
    d.body, d.offset, d.resolution_u = "*", 10.0, 3
    try:
        missed = text.vertices(obj) < counts(obj)[0]
    finally:
        text._fill_extra = real
        d.offset = 0.0
    check("control: without what the fill adds, '*' at Offset 10 is priced below Blender's count", missed)
    # A bevel object: Blender leaves it out of a build outside the scene.
    bpy.ops.curve.primitive_bezier_circle_add()
    circle = bpy.context.object
    activate(obj)
    for k, v in dict(extrude=0.0, bevel_depth=0.0, bevel_resolution=4, fill_mode='BOTH', bevel_mode='OBJECT', resolution_u=12).items():
        setattr(d, k, v)
    d.bevel_object = circle
    d.body = "Hi"
    check("with a Bevel Object too (%d)" % counts(obj)[0], text.vertices(obj) == counts(obj)[0], text.vertices(obj))
    d.bevel_object = None
    d.bevel_mode = 'ROUND'
    circle_data = circle.data
    bpy.data.objects.remove(circle)
    bpy.data.curves.remove(circle_data)
    check("and nothing it made is left behind", sorted(o.name for o in bpy.data.objects) == ["Text"]
          and sorted(c.name for c in bpy.data.curves) == ["Text"], [o.name for o in bpy.data.objects])
    # A negative Bevel Depth bevels as a positive one.
    d.body, d.resolution_u, d.bevel_resolution = "abcdefghij" * 100, 12, 32
    flat = counts(obj)[0]
    said = attempt(blocks["TEXT NEGBEVEL"])
    check("Bevel Depth -0.02 on 1,000 flat characters (%s) is refused as 2 × 32 + 5 times that" % format(flat, ','),
          format(flat * 69, ',') in said and d.bevel_depth == 0, said)
    d.body = "abcdefghij"
    error = run(blocks["TEXT NEGBEVEL"])
    check("control: on ten it passes, and Blender makes 69 times the flat count, as for +0.02",
          error is None and counts(obj)[0] == 1050 * 69, (error, counts(obj)[0]))
    d.bevel_depth = 0
    # Fill Mode.
    d.body, d.resolution_u, d.extrude, d.fill_mode = "abcdefghij" * 120, 64, 0.1, 'NONE'
    said = attempt(blocks["TEXT FILL BOTH"])
    check("Fill Mode None to Both with Extrude doubles the vertices, 1,287,840 to 2,575,680, and is refused",
          "2,575,680" in said and d.fill_mode == 'NONE', said)
    d.body = "abcdefghij"
    check("control: on ten characters it passes", run(blocks["TEXT FILL BOTH"]) is None and d.fill_mode == 'BOTH')
    d.extrude, d.resolution_u = 0.0, 12
    # The Data API row reaches the text's data too.
    d.body, d.bevel_resolution = "O" * 100, 4
    said = attempt("__import__('_blenderkit_sync').set_property('bpy.data.curves[\"Text\"]', 'resolution_u', 1024)")
    check("the Data API row's Resolution U 1024 on 100 'O' (819,200 flat) passes", said == "ran"
          and counts(obj)[0] == 819200, said)
    said = attempt("__import__('_blenderkit_sync').set_property('bpy.data.curves[\"Text\"]', 'bevel_depth', 0.01)")
    check("(Bevel Depth 0.01 at Bevel Resolution 4: 13 times, refused)", "10,649,600" in said and d.bevel_depth == 0, said)
    d.resolution_u = 12
    # A cleared body.
    error = run(blocks["TEXT CLEAR"])
    bridge.points.clear()
    sync.sync()
    out["text_cleared"] = bridge.points.get("Text", "")
    check("the Body Text field clears the body, and the pass still hands the Data tab its record",
          error is None and d.body == "" and out["text_cleared"].endswith("body="), (error, out["text_cleared"][-40:]))
    return out


def curve_budget():
    obj = text_object("Hello")
    for i in range(3):
        error = run(blocks["ADD FONT ARRAY"])
        check("Add Modifier ▸ Array (Legacy) on the text, #%d" % (i + 1), error is None, error)
    for m in obj.modifiers:
        m.count = 2
    for name in ("Array", "Array.001"):
        error = run(blocks["ARRAY64 " + name])
        check("%s's Count 64 passes" % name, error is None and obj.modifiers[name].count == 64, error)
    check("and the count is Blender's (%s)" % format(counts(obj)[0], ','),
          multires.stack_vertices(obj) == counts(obj)[0] == 215 * 64 * 64 * 2)
    said = attempt(blocks["ARRAY64 Array.002"])
    check("the third Array's Count 64 on a text (215 × 64³ vertices) is refused with the row's own line",
          "56,360,960" in said and obj.modifiers["Array.002"].count == 2, said)
    # The object types the budget counts are its own (_blenderkit_budget).
    # (and what it judges, COUNTED_TYPES, which adds volumes to them since
    # round 4's fix-round review).
    real, counted = budget.GEOMETRY_TYPES, budget.COUNTED_TYPES
    budget.GEOMETRY_TYPES = budget.COUNTED_TYPES = ('MESH',)
    try:
        passed = multires.check_setting("Array.002", "count", 64, obj) is None
    finally:
        budget.GEOMETRY_TYPES, budget.COUNTED_TYPES = real, counted
    check("control: priced as the review found it, meshes only, it went through", passed)
    obj.modifiers.clear()
    home()
    bpy.ops.curve.primitive_bezier_curve_add()
    curve = bpy.context.object
    curve.name = "Curve"
    curve.data.bevel_depth, curve.data.resolution_u, curve.data.bevel_resolution = 0.1, 64, 16
    activate(curve)
    error = run(blocks["ADD CURVE SUBSURF"])
    check("Subdivision Surface added to a bevelled curve", error is None, error)
    check("its count is Blender's (%s)" % format(counts(curve)[0], ','), multires.stack_vertices(curve) == counts(curve)[0])
    said = attempt(blocks["SUBSURF 1 TO 6"])
    check("Subdivision level 6 on the curve is refused with the row's own line", "2,500,000" in said
          and curve.modifiers["Subdivision"].levels == 1, said)
    home()
    bpy.ops.surface.primitive_nurbs_surface_sphere_add()
    surface = bpy.context.object
    activate(surface)
    error = run(blocks["ADD SURFACE ARRAY"])
    surface.modifiers[0].count = 3
    check("Array on a NURBS surface, counted as Blender evaluates it", error is None
          and multires.stack_vertices(surface) == counts(surface)[0], (error, counts(surface)))
    said = attempt("__import__('_blenderkit_sync').set_property('bpy.context.object.modifiers[\"Array\"]', 'count', 4000)")
    check("the Data API row's Count 4000 on it (640 × 4000) is refused", "2,560,000" in said, said)


def stack_prices():
    home()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=100, y_subdivisions=100)
    grid = bpy.context.object
    activate(grid)
    run(blocks["ADD MESH SCREW"])
    said = attempt(blocks["SCREW STEPS 512"])
    check("the Screw row's Steps 512 on a 100 x 100 grid is refused by the row's own line",
          "2,500,000" in said and grid.modifiers["Screw"].steps == 16, said)
    check("control: its Steps 200 passes and reaches Blender", run(blocks["SCREW STEPS 200"]) is None
          and grid.modifiers["Screw"].steps == 200 and grid.modifiers["Screw"].render_steps == 200)
    home()
    bpy.ops.mesh.primitive_uv_sphere_add()
    sphere = bpy.context.object
    activate(sphere)
    run(blocks["ADD MESH SCREW"])
    said = attempt("__import__('_blenderkit_sync').set_property('bpy.context.object.modifiers[\"Screw\"]', 'iterations', 10000)")
    check("Screw Iterations 10,000 through the Data API row is refused (77,120,482)",
          "77,120,482" in said and sphere.modifiers["Screw"].iterations == 1, said)
    sphere.modifiers["Screw"].iterations = 3
    check("and Iterations 3 is counted as Blender evaluates it", multires.stack_vertices(sphere) == counts(sphere)[0])
    home()
    bpy.ops.mesh.primitive_plane_add()
    plane = bpy.context.object
    activate(plane)
    run(blocks["ADD MESH OCEAN"])
    path = 'bpy.context.object.modifiers["Ocean"]'
    for key, value in (('geometry_mode', 'DISPLACE'), ('repeat_x', 200), ('repeat_y', 200)):
        check("Ocean %s %s passes: Displace builds nothing" % (key, value),
              attempt("__import__('_blenderkit_sync').set_property(%r, %r, %r)" % (path, key, value)) == "ran")
    said = attempt("__import__('_blenderkit_sync').set_property(%r, 'geometry_mode', 'GENERATE')" % path)
    check("then Geometry Generate at Repeat 200 x 200 is refused (96,059,601)", "96,059,601" in said
          and plane.modifiers["Ocean"].geometry_mode == 'DISPLACE', said)
    said = attempt("__import__('_blenderkit_sync').set_property(%r, 'viewport_resolution', 40)" % path)
    check("Displace at Resolution 40 is refused for its simulation (2,560,000 points)", "2,560,000" in said, said)
    check("39 is priced to pass", attempt(lambda_source("multires.check_setting('Ocean', 'viewport_resolution', 39)")) == "ran")
    said = attempt("__import__('_blenderkit_sync').set_property(%r, 'resolution', 100)" % path)
    check("a Render Resolution of 100 is refused as if rendered", "100,000,000" in said, said)
    home()
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    activate(cube)
    run(blocks["ADD MESH SUBSURF"])
    check("Skin added below a level 1 Subdivision (23 loops)", run(blocks["ADD MESH SKIN"]) is None
          and multires.skin_loops(cube) == (23, "Skin"))
    check("the Subdivision row's level 2 passes (95 loops)", run(blocks["SUBSURF 1 TO 2"]) is None
          and cube.modifiers["Subdivision"].levels == 2)
    cube.modifiers["Subdivision"].levels = 1
    said = attempt(blocks["SUBSURF 1 TO 4"])
    check("its level 4, which hands the Skin 1,535 loops, is refused with the row's own line",
          "1,535 closed loops" in said and cube.modifiers["Subdivision"].levels == 1, said)
    cube.modifiers.clear()
    run(blocks["ADD MESH SKIN"])
    run(blocks["ADD MESH SUBSURF"])
    cube.modifiers["Subdivision"].levels = 4
    start = time.time()
    said = attempt(blocks["MOVE UP Subdivision"])
    took = time.time() - start
    check("moving a level 4 Subdivision above the Skin is refused before Blender moves it (%.2f s; Blender's own "
          "move evaluated it for 44 s)" % took,
          "1,535 closed loops" in said and [m.name for m in cube.modifiers] == ["Skin", "Subdivision"] and took < 2, said)
    check("control: a move Blender cancels is left to Blender, priced or not",
          "Blender keeps" in attempt(bpy_move_first()))
    cube.modifiers["Subdivision"].levels = 1
    error = run(blocks["MOVE UP Subdivision"])
    check("control: at level 1 it moves", error is None and [m.name for m in cube.modifiers] == ["Subdivision", "Skin"], error)
    # Edge Split's price bounds Blender's count.
    over = []
    for maker in (bpy.ops.mesh.primitive_cube_add, lambda: bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1),
                  bpy.ops.mesh.primitive_uv_sphere_add, bpy.ops.mesh.primitive_monkey_add):
        home()
        maker()
        obj = bpy.context.object
        m = obj.modifiers.new("EdgeSplit", 'EDGE_SPLIT')
        for angle in (math.radians(30), 0.0):
            m.split_angle = angle
            if counts(obj)[0] > multires.stack_vertices(obj):
                over.append((obj.name, angle, counts(obj)[0], multires.stack_vertices(obj)))
        m.split_angle = 0.0
        if multires.stack_vertices(obj) != counts(obj)[0]:
            over.append((obj.name, "exact at 0", counts(obj)[0], multires.stack_vertices(obj)))
    check("Edge Split: counted at most what every corner split makes, and exactly that at 0°", not over, over)
    home()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=800, y_subdivisions=800)
    activate(bpy.context.object)
    said = attempt(blocks["ADD MESH EDGE_SPLIT"])
    check("Add Modifier ▸ Edge Split on an 800 x 800 grid (2,560,000 corners) is refused", "2,560,000" in said, said)


def bpy_move_first():
    """The Swift's Move Up for the stack's first modifier: past the top."""
    first = bpy.context.object.modifiers[0].name
    return blocks["MOVE UP Subdivision"].replace('"Subdivision"', repr(first).replace("'", '"'))


def lambda_source(expression):
    return "import _blenderkit_multires as multires\n" + expression


def blender_pixel(image, x, y):
    """The RGB, 0 to 255, Blender holds at (x, y) from the top left."""
    w, h = image.size
    pixels = image.pixels[:]
    k = ((h - 1 - y) * w + x) * 4
    return [round(c * 255) for c in pixels[k:k + 3]]


def quarters(image):
    w, h = image.size
    return [blender_pixel(image, x, y) for x, y in ((w // 4, h // 4), (3 * w // 4, h // 4),
                                                       (w // 4, 3 * h // 4), (3 * w // 4, 3 * h // 4))]


def near(a, b, tolerance=48):
    return len(a) == len(b) and all(abs(int(x) - int(y)) <= tolerance for x, y in zip(a, b))


def allocated():
    """The bytes Blender's allocator holds now (`MEM_get_memory_in_use`, the
    total Blender's Memory Statistics prints): every buffer Blender makes, a
    decoded picture's pixels among them, counted exactly. Resident memory was
    measured here before, and it is not exact: the system compresses and pages
    out what it holds under load, and round 4's final review read the control
    below at +65 MB resident with three other jobs running and +144 MB alone.
    Measured in desktop 5.2.1: a 3,000 x 3,000 PNG decoded put 34.3 MiB on the
    allocator (8.37 to 42.72 MB, 3,000 x 3,000 x 4 bytes), whatever else ran."""
    import ctypes
    libc = ctypes.CDLL(None)
    # A pointer to the allocator's function (guarded or lock-free), not the
    # function itself.
    function = ctypes.c_void_p.in_dll(libc, 'MEM_get_memory_in_use').value
    return ctypes.CFUNCTYPE(ctypes.c_size_t)(function)()


def pictures():
    folder = os.path.join(WORK, "pictures")
    made = json.load(open(os.path.join(folder, "pictures.json")))
    red, blue, green, yellow = [255, 0, 0], [0, 0, 255], [0, 255, 0], [255, 255, 0]

    def load(name):
        return bpy.data.images.load(os.path.join(folder, name), check_existing=False)

    # First, before anything decodes a picture this big: the record reads
    # the size from the header and Blender decodes nothing.
    huge = os.path.join(folder, "huge6000.png")
    home()
    bpy.ops.object.empty_add(type='IMAGE')
    empty = bpy.context.object
    empty.data = bpy.data.images.load(huge, check_existing=False)
    before = allocated()
    values = dict(images.record_values(empty))
    aspect = sync._image_aspect(empty.data)
    after = allocated()
    check("an image empty's record of a 6,000 x 6,000 PNG has its picture and aspect, and Blender decoded nothing "
          "(%+.1f MB allocated)" % ((after - before) / 1e6), values["image_has_data"] and aspect == (1.0, 1.0)
          and not empty.data.has_data and after - before < 50_000_000,
          (values["image_has_data"], aspect, empty.data.has_data))
    size = tuple(empty.data.size)
    grown = allocated()
    # Its pixels are 6,000 x 6,000 x 4 bytes, 144 MB, on the allocator.
    check("control: asking Blender its size decodes it (%+.1f MB allocated)" % ((grown - after) / 1e6),
          size == (6000, 6000) and empty.data.has_data and grown - after >= 6000 * 6000 * 4,
          (size, empty.data.has_data, grown - after))

    home()
    bpy.ops.mesh.primitive_cube_add()
    activate(bpy.context.object)
    heic = load("photo.heic")
    check("control: Blender reads no HEIC (0 x 0), as measured", tuple(heic.size) == (0, 0), tuple(heic.size))
    said = attempt("import _blenderkit_images\n_blenderkit_images.add(%r, False, (0, 0, 0), (0, 0, 0), False)"
                   % os.path.join(folder, "photo.heic"))
    check("and a HEIC handed to Reference... is refused in words", "not a PNG or a JPEG" in said, said)
    prepared = load(made["photo.heic"]["prepared"])
    check("what the app makes of it Blender reads: 64 x 32, its quarters where they were",
          tuple(prepared.size) == (64, 32) and all(near(a, b) for a, b in zip(quarters(prepared), [red, blue, green, yellow])),
          (tuple(prepared.size), quarters(prepared)))
    turned = load("turned.jpg")
    check("control: Blender ignores the JPEG's EXIF orientation: 64 x 32, red top left, as stored",
          tuple(turned.size) == (64, 32) and near(quarters(turned)[0], red), (tuple(turned.size), quarters(turned)))
    prepared = load(made["turned.jpg"]["prepared"])
    check("what the app makes of it Blender reads the right way up: 32 x 64, green, red / yellow, blue",
          tuple(prepared.size) == (32, 64) and all(near(a, b) for a, b in zip(quarters(prepared), [green, red, yellow, blue])),
          (tuple(prepared.size), quarters(prepared)))
    view = made["turned.jpg"]
    check("and the viewport draws the file Blender reads: the prepared one 32 x 64, the raw one 64 x 32 as stored",
          view["viewport"] == [32, 64] and view["viewport_raw"] == [64, 32]
          and near(view["viewport_raw_quarters"][0], red) and near(view["viewport_quarters"][0], green), view)
    check("an sRGB PNG goes as it is", made["plain.png"]["same"] is True)
    p3 = load("p3.png")
    check("Blender takes a Display P3 file's numbers as they are (180, 120, 60), so the app converts it to sRGB",
          near(blender_pixel(p3, 4, 4), [180, 120, 60], 1) and made["p3.png"]["same"] is False, blender_pixel(p3, 4, 4))
    for name in ("plain.png", "progressive.jpg", "deep16.png", "turned.jpg", "huge6000.png"):
        path = os.path.join(folder, name)
        header = images.picture_size(path)
        image = load(name)
        check("%s: the header read gives Blender's own size, %s" % (name, tuple(image.size)),
              header is not None and (header[0], header[1]) == tuple(image.size), header)
    check("the progressive JPEG's frame is found past its 3,000-byte EXIF comment",
          images.picture_size(os.path.join(folder, "progressive.jpg"))[3] == 'JPEG')
    deep = images.picture_size(os.path.join(folder, "deep16.png"))
    check("a 16-bit PNG is read as 16 bits", deep[2] == 16, deep)
    said = attempt("import _blenderkit_images\n_blenderkit_images.refuse_picture(%r, 'Reference')" % huge)
    check("a 6,000 x 6,000 PNG (%d KB) is refused before Blender decodes it" % (os.path.getsize(huge) // 1000),
          "6000 × 6000" in said, said)
    said = attempt("import _blenderkit_images\n_blenderkit_images.refuse_picture(%r, 'Reference')"
                   % os.path.join(folder, "deep16-big.png"))
    check("and a 2,100 x 2,100 16-bit one, which decodes to floats (70 MB)", "at 16 bits" in said, said)
    check("control: the 40 x 20 16-bit one passes", attempt("import _blenderkit_images\n_blenderkit_images.refuse_picture(%r, 'R')"
                                                           % os.path.join(folder, "deep16.png")) == "ran")
    check("the app's 6,000 x 6,000 is 4,096 x 4,096", images.picture_size(os.path.join(folder, made["huge6000.png"]["prepared"]))[:2]
          == (4096, 4096))
    # Mesh Plane...
    home()
    bpy.ops.mesh.primitive_cube_add()
    activate(bpy.context.object)
    push("fixture")
    bpy.context.scene.cursor.location = (1, 2, 3)
    picture = os.path.join(folder, made["turned.jpg"]["prepared"])
    error = run(blocks["IMAGE PLANE"].replace("{PATH}", picture))
    plane = bpy.context.view_layer.objects.active
    nodes = plane.data.materials[0].node_tree.nodes if plane and plane.type == 'MESH' and plane.data.materials else []
    textures = [n for n in nodes if n.type == 'TEX_IMAGE']
    check("Mesh Plane... adds Blender's plane at the 3D cursor, 0.5 x 1 for a 32 x 64 picture, its picture packed",
          error is None and plane.type == 'MESH' and tuple(round(c, 3) for c in plane.dimensions) == (0.5, 1.0, 0.0)
          and tuple(round(c, 3) for c in plane.location) == (1, 2, 3) and textures and textures[0].image.packed_file is not None,
          (error, plane.name, tuple(plane.dimensions), tuple(plane.location)))
    push(images.PLANE_UNDO)
    bpy.ops.ed.undo()
    check("Undo takes it away", [o.type for o in bpy.data.objects] == ['MESH'] and len(bpy.data.objects) == 1,
          [o.name for o in bpy.data.objects])
    said = attempt(blocks["IMAGE PLANE"].replace("{PATH}", os.path.join(folder, "photo.heic")))
    check("and a HEIC is refused there too", "not a PNG or a JPEG" in said, said)


if PHASE == "1":
    phase1()
else:
    phase2()
print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
