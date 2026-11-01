"""Loop Cut and the Knife, held to Blender itself: a headless Blender with the
app's context — its undo stack (`_blenderkit_undo`, the history's first push),
gpu.init(), the startup screen's 3D View borrowed as the app borrows it — and
the modules the app ships from Resources/python/site.

  * Blender's ring is the ring it cuts. For every edge of a cube, a grid, a UV
    sphere (its poles' triangle fans included), a cylinder with n-gon caps, a
    torus, an icosphere (all triangles), a strip of quads ending in a triangle
    and a pentagon with a hexagon between quads, and meshes with hidden faces,
    `_blenderkit_loopcut.ring` is held to the cut `loopcut_slide` makes with the
    call the app sends: one new vertex per cut on each ring edge, at i / (n + 1),
    and nowhere else. A walker that crosses even n-gons (Blender's own walker
    without the n-gon delimit) is the negative control: it must disagree on the
    hexagon. Each cut is written out for the Swift half (`main.swift preview`),
    which draws the preview from Blender's ring and holds it to the cut.
  * The edge index the app sends is Blender's: the mirror's edge list (the mesh
    after `update_from_editmode`) numbers edges as the edit mesh does, after
    deletes and adds have left holes in BMesh's pools.
  * The Swift-made Loop Cut and Slide: its cut, its re-run with three cuts and
    a slide (through the mesh backup and through Blender's undo), and what it
    refuses in words — a hidden edge (Blender would answer FINISHED and cut
    nothing), an edge that is not there, another object's index, the vertex
    budget, its undo argument (which crashes Blender in the borrowed view), and
    no 3D View.
  * The Swift-made Knife, perspective and orthographic, with Cut Through off
    and on: every new vertex where the planes the path and the eye make cross
    the mesh's edges (worked out here with mathutils, independently of the
    knife), on the faces the view sees only unless Cut Through; the select
    mode kept and the cut edges selected as Blender's Knife leaves them; no
    path object left behind; Blender's view, lens and clipping put back; a
    path that misses the mesh, or one behind the eye, refused in words.
  * Subdivide Edge-Ring, the Edge menu's row that used to be called Loop Cut:
    Blender's operator alone, refused in words when it would cut nothing.

    scripts/run-cuttools-blender-check.sh
"""
import bpy, bmesh, gpu, sys, os, json, types, tempfile, importlib.util, pathlib
from mathutils import Vector

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
CALLS, FIXTURES = sys.argv[-2], sys.argv[-1]
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
knife = load("_blenderkit_knife")
multires = load("_blenderkit_multires")
loopcut = load("_blenderkit_loopcut")
context.install(bpy)
gpu.init()
HISTORY = tempfile.mkdtemp(prefix="bk-cuttools-")
undo.push(HISTORY, "Original")

calls = {}
for block in open(CALLS).read().split("### ")[1:]:
    head, _, body = block.partition("\n")
    calls[head.strip()] = body.rstrip("\n")
MARKER = "424242"


def run(body, **names):
    scope = {"bpy": bpy}
    scope.update(names)
    exec(compile(body, "<app>", "exec"), scope)


def attempt(body):
    try:
        run(body)
        return None
    except Exception as error:
        return str(error).strip().replace("\n", " ")


def clear():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)


def mixed_mesh():
    """Quads in two rows; the lower row has a hexagon between two quads, a
    triangle at its left end and a pentagon at its right; a wire edge hangs
    off the top."""
    me = bpy.data.meshes.new("Mixed")
    bm = bmesh.new()
    bot = [bm.verts.new((x, 0, 0)) for x in range(6)]
    top = [bm.verts.new((x, 1, 0)) for x in range(6)]
    for i in range(5):
        if i != 2:
            bm.faces.new((bot[i], bot[i + 1], top[i + 1], top[i]))
    a = bm.verts.new((2.5, -0.4, 0)); b = bm.verts.new((2.5, 1.4, 0))
    bm.faces.new((bot[2], a, bot[3], top[3], b, top[2]))
    t = bm.verts.new((-1, 0.5, 0))
    bm.faces.new((t, bot[0], top[0]))
    p1 = bm.verts.new((6, -0.3, 0)); p2 = bm.verts.new((6.4, 0.5, 0)); p3 = bm.verts.new((6, 1.3, 0))
    bm.faces.new((bot[5], p1, p2, p3, top[5]))
    row = [bm.verts.new((x, 2, 0)) for x in range(6)]
    for i in range(5):
        bm.faces.new((top[i], top[i + 1], row[i + 1], row[i]))
    w = bm.verts.new((0, 3, 0))
    bm.edges.new((row[0], w))
    bm.to_mesh(me)
    bm.free()
    return me


def make(kind):
    clear()
    if kind == 'cube':
        bpy.ops.mesh.primitive_cube_add(size=2)
    elif kind == 'grid':
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=5, y_subdivisions=4, size=2)
    elif kind == 'uvsphere':
        bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6)
    elif kind == 'cylinder':
        bpy.ops.mesh.primitive_cylinder_add(vertices=8)
    elif kind == 'torus':
        bpy.ops.mesh.primitive_torus_add(major_segments=8, minor_segments=4)
    elif kind == 'icosphere':
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1)
    elif kind == 'mixed':
        obj = bpy.data.objects.new("Mixed", mixed_mesh())
        bpy.context.scene.collection.objects.link(obj)
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
    return bpy.context.view_layer.objects.active


def edit(obj, hide=(), mode='EDGE'):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    for element in list(bm.verts) + list(bm.edges) + list(bm.faces):
        element.select = False
    for i in hide:
        bm.faces[i].hide_set(True)
    bmesh.update_edit_mesh(obj.data)


def counts(obj):
    bm = bmesh.from_edit_mesh(obj.data)
    return len(bm.verts), len(bm.edges), len(bm.faces)


def positions(obj):
    return [tuple(v.co) for v in bmesh.from_edit_mesh(obj.data).verts]


def fresh(obj, base, hide=()):
    if obj.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    old = obj.data
    obj.data = base.copy()
    bpy.data.meshes.remove(old)
    edit(obj, hide)


def perform_cut(edge, body_key="loopcut UNDOPERFORM"):
    body = calls[body_key].replace(MARKER, str(edge))
    return attempt(body)


# --------------------------------------------------------------------------
print("\nBlender's ring is the ring it cuts, on every edge")

fixtures = []
CASES = [('cube', (), 1), ('cube', (), 3), ('grid', (), 1), ('grid', (), 2), ('grid', (3, 7, 8, 12), 1),
         ('uvsphere', (), 1), ('uvsphere', (), 2), ('cylinder', (), 1), ('torus', (), 1), ('icosphere', (), 1),
         ('mixed', (), 1), ('mixed', (), 2), ('mixed', (2, 6), 1)]
for kind, hide, cuts in CASES:
    obj = make(kind)
    base = obj.data.copy()
    base.use_fake_user = True
    edit(obj, hide)
    edges = len(bmesh.from_edit_mesh(obj.data).edges)
    agree, refused, bad = 0, 0, []
    for e in range(edges):
        fresh(obj, base, hide)
        bm = bmesh.from_edit_mesh(obj.data)
        bm.edges.ensure_lookup_table()
        if bm.edges[e].hide:
            said = attempt(calls["loopcut UNDOPERFORM"].replace(MARKER, str(e)))
            if said and "hidden" in said and counts(obj)[0] == len(base.vertices):
                refused += 1
            else:
                bad.append((e, "hidden edge: " + str(said)))
            continue
        ring = loopcut.ring(e)
        before = positions(obj)
        want = set()
        bm.edges.ensure_lookup_table()
        for i in ring["edges"]:
            a, b = bm.edges[i].verts[0].co, bm.edges[i].verts[1].co
            for k in range(1, cuts + 1):
                want.add(tuple(round(c, 4) for c in a + (b - a) * (k / (cuts + 1))))
        body = calls["loopcut UNDOPERFORM"].replace(MARKER, str(e)).replace('"number_cuts": 1', '"number_cuts": %d' % cuts)
        body = body.replace("check(%s, 1, 0)" % e, "check(%s, %d, 0)" % (e, cuts))
        said = attempt(body)
        after_bm = bmesh.from_edit_mesh(obj.data)
        old = {tuple(round(c, 4) for c in p) for p in before}
        made = [tuple(v.co) for v in after_bm.verts if tuple(round(c, 4) for c in v.co) not in old]
        made_set = {tuple(round(c, 4) for c in p) for p in made}
        ok = said is None and made_set == want and len(made) == cuts * len(ring["edges"])
        if ok:
            agree += 1
        elif len(bad) < 3:
            bad.append((e, said, len(made), len(want)))
        fixtures.append(dict(mesh=kind + ("/hidden" if hide else ""), cuts=cuts, before=[list(p) for p in before],
                             ring=json.dumps(ring), new=[list(p) for p in made],
                             edges_after=[[list(e2.verts[0].co), list(e2.verts[1].co)] for e2 in after_bm.edges]))
    label = "%s%s, %d cut%s" % (kind, " with faces %s hidden" % list(hide) if hide else "", cuts, "s" if cuts > 1 else "")
    check("%s: %d of %d edges cut exactly the ring predicted%s" % (
        label, agree, edges - refused, ", %d hidden edges refused in words" % refused if refused else ""),
        agree == edges - refused and not bad, bad)
json.dump(fixtures, open(FIXTURES, "w"))

# The negative control: Blender's walker without the n-gon delimit (the
# undelimited branch of bmw_EdgeringWalker_step: "only n-gons with an even
# number of sides") goes across the hexagon, which the loop cut does not.
obj = make('mixed')
edit(obj)
bm = bmesh.from_edit_mesh(obj.data)
bm.edges.ensure_lookup_table()


def even_ngon_ring(edge):
    out, seen, stack = [edge], {edge}, [edge]
    while stack:
        e = stack.pop()
        for l in e.link_loops:
            n = len(l.face.loops)
            if n % 2:
                continue
            opposite = l
            for _ in range(n // 2):
                opposite = opposite.link_loop_next
            if opposite.edge not in seen:
                seen.add(opposite.edge); out.append(opposite.edge); stack.append(opposite.edge)
    return sorted(x.index for x in out)


crossings = [e.index for e in bm.edges
             if sorted(loopcut.ring(e.index)["edges"]) != even_ngon_ring(e)]
check("the negative control: a ring walker that crosses even n-gons disagrees with Blender's cut on the hexagon "
      "(%d edges)" % len(crossings), len(crossings) > 0)

# --------------------------------------------------------------------------
print("\nThe index the app sends is the edit mesh's own")

obj = make('grid')
edit(obj, mode='FACE')
bm = bmesh.from_edit_mesh(obj.data)
bm.faces.ensure_lookup_table()
for f in list(bm.faces)[3:7]:
    f.select = True
bmesh.update_edit_mesh(obj.data)
bpy.ops.mesh.delete(type='FACE')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.extrude_region_move(TRANSFORM_OT_translate={"value": (0, 0, 0.3)})
bm = bmesh.from_edit_mesh(obj.data)
bm.edges.ensure_lookup_table()
obj.update_from_editmode()
mesh_ends = [tuple(e.vertices) for e in obj.data.edges]
bm_ends = [(e.verts[0].index, e.verts[1].index) for e in bm.edges]
check("after a delete and an extrude, the mirror's edge %d is the edit mesh's edge %d, for all %d"
      % (7, 7, len(bm_ends)), mesh_ends == bm_ends, (mesh_ends[:4], bm_ends[:4]))

# --------------------------------------------------------------------------
print("\nThe cut the app sends: Loop Cut and Slide")

obj = make('cube')
edit(obj)
said = perform_cut(4)
check("a cube's edge 4: 8/12/6 to 12/20/10, the new loop selected", said is None and counts(obj) == (12, 20, 10)
      and sum(v.select for v in bmesh.from_edit_mesh(obj.data).verts) == 4, (said, counts(obj)))
obj = make('cube')
edit(obj)
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.mode_set(mode='EDIT')
said = attempt(calls["loopcut PERFORM"].replace(MARKER, "4"))
check("with the mesh backup the checkpoint history needs, the same cut and an adjustable backup",
      said is None and counts(obj) == (12, 20, 10) and bpy.data.meshes.get("_bk_redo") is not None, said)
rerun = calls["loopcut RERUN3"].replace(MARKER, "4").replace("@SUBJECT@", obj.name)
said = attempt(rerun)
xs = sorted({round(v.co.x, 4) for v in bmesh.from_edit_mesh(obj.data).verts} - {-1.0, 1.0})
check("re-run from the backup with 3 cuts slid by 0.5: 20/36/18, the loops off the middle", said is None
      and counts(obj) == (20, 36, 18) and xs != [-0.5, 0.0, 0.5], (said, counts(obj), xs))

# Edge Slide's Clamp, Mirror Editing and Correct UVs, the rows Blender's panel
# shows, sent in the call the app makes, each measured changing the cut:
# Clamp off lets a Factor past 1 slide past the ring's end; Mirror Editing
# keeps a loop on the mesh's X mirror plane there; Correct UVs off leaves the
# cut corners' UVs where the cut put them.
DEFAULTS = {"use_clamp": "True", "correct_uv": "True", "mirror": "True", "value": "0"}


def cut_with(edit_slide, along=2, mesh_x=False):
    obj = make('cube')
    obj.data.use_mirror_x = mesh_x
    edit(obj)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.edges.ensure_lookup_table()
    edge = [e for e in bm.edges if abs((e.verts[0].co - e.verts[1].co)[along]) > 1][0].index
    body = calls["loopcut UNDOPERFORM"].replace(MARKER, str(edge))
    for key, value in edit_slide.items():
        body = body.replace('"%s": %s' % (key, DEFAULTS[key]), '"%s": %s' % (key, value))
    said = attempt(body)
    bm = bmesh.from_edit_mesh(obj.data)
    uv = bm.loops.layers.uv.active
    return said, sorted(tuple(round(c, 4) for c in v.co) for v in bm.verts if v.select), sorted(
        {(round(l[uv].uv.x, 4), round(l[uv].uv.y, 4)) for f in bm.faces for l in f.loops})


check("the call carries Clamp, Mirror Editing and Correct UVs, on as Blender's own Loop Cut records them",
      '"use_clamp": True, "mirror": True, "correct_uv": True' in calls["loopcut UNDOPERFORM"],
      calls["loopcut UNDOPERFORM"])
_, clamped, _ = cut_with({"value": "1.5"})
said, free, _ = cut_with({"value": "1.5", "use_clamp": "False"})
check("Clamp: Factor 1.5 stops the loop at the ring's end clamped (z %s) and slides past it unclamped (z %s)"
      % (sorted({p[2] for p in clamped}), sorted({p[2] for p in free})),
      said is None and {p[2] for p in clamped} == {-1.0} and {p[2] for p in free} == {-1.5}, (said, clamped, free))
_, mirrored, _ = cut_with({"value": "0.5"}, along=0, mesh_x=True)
said, unmirrored, _ = cut_with({"value": "0.5", "mirror": "False"}, along=0, mesh_x=True)
check("Mirror Editing, the mesh's X mirror on: a loop across X stays on the plane (x %s), off it slides (x %s)"
      % (sorted({p[0] for p in mirrored}), sorted({p[0] for p in unmirrored})),
      said is None and {p[0] for p in mirrored} == {0.0} and {p[0] for p in unmirrored} == {0.5},
      (said, mirrored, unmirrored))
_, plain, _ = cut_with({"value": "0.5"}, along=0)
check("and with the mesh's mirror off, Mirror Editing on mirrors nothing (x %s)" % sorted({p[0] for p in plain}),
      {p[0] for p in plain} == {0.5}, plain)
_, _, uv_on = cut_with({"value": "0.5"})
said, _, uv_off = cut_with({"value": "0.5", "correct_uv": "False"})
check("Correct UVs: on and off give the cut corners different UVs", said is None and uv_on != uv_off,
      (said, len(uv_on), len(uv_off)))

# Through Blender's undo, as `readjustThroughUndo` does: rewind the step, run
# the new arguments, record over it.
obj = make('cube')
edit(obj)
undo.push(HISTORY, "Fixture")
said = perform_cut(4)
undo.push(HISTORY, "Loop Cut and Slide")
first = counts(obj)
rewound = undo.rewind()
said3 = attempt(calls["loopcut UNDOPERFORM3"].replace(MARKER, "4"))
undo.push(HISTORY, "Loop Cut and Slide", replace=True)
obj = bpy.context.view_layer.objects.active
check("through Blender's undo: the cut, then the same edge re-run with 3 cuts, not on top of the first",
      said is None and first == (12, 20, 10) and rewound is not False and said3 is None
      and counts(obj) == (20, 36, 18), (said, first, rewound, said3, counts(obj)))
undo.step(-1)
obj = bpy.context.view_layer.objects.active
check("and one Undo goes back to the cube", obj.mode == 'EDIT' and counts(obj) == (8, 12, 6), counts(obj))

print("\nWhat it refuses, in words, before Blender runs")

obj = make('cube')
edit(obj)
bm = bmesh.from_edit_mesh(obj.data)
bm.edges.ensure_lookup_table()
for f in bm.edges[4].link_faces:
    f.hide_set(True)
bmesh.update_edit_mesh(obj.data)
with context.temp_override_view3d('Loop Cut'):
    raw = bpy.ops.mesh.loopcut_slide(MESH_OT_loopcut={"number_cuts": 1, "edge_index": 4, "object_index": 0},
                                     TRANSFORM_OT_edge_slide={"value": 0})
check("Blender itself answers FINISHED on a hidden edge and cuts nothing (why it is refused first)",
      raw == {'FINISHED'} and counts(obj) == (8, 12, 6), (raw, counts(obj)))
said = perform_cut(4)
check("a hidden edge", said is not None and "edge 4 is hidden" in said and counts(obj) == (8, 12, 6), said)
obj = make('cube')
edit(obj)
said = perform_cut(12)
check("an edge the mesh does not have", said is not None and "there is no edge 12" in said, said)
said = attempt(calls["loopcut OBJECT1"].replace(MARKER, "4"))
check("another object's index", said is not None and "not the first of the objects in Edit Mode" in said, said)
budget = multires.BUDGET
multires.BUDGET = 10
said = perform_cut(4)
multires.BUDGET = budget
check("past the vertex budget (lowered to 10 here), naming the count", said is not None and "would give Cube" in said
      and "stops at 10" in said and counts(obj) == (8, 12, 6), said)
obj.modifiers.new("Subdivision", 'SUBSURF').levels = 3
# Evaluated at the real budget before it is lowered: the vertex budget's gate
# prices a write when Blender next evaluates (_blenderkit_gate.py), and an add
# still waiting then would be priced, and refused, at 300.
bpy.context.view_layer.update()
multires.BUDGET = 300
said = perform_cut(4)
multires.BUDGET = budget
check("through the whole stack: a Subdivision at level 3 over the cut is priced too",
      said is not None and "would give Cube" in said, said)
obj.modifiers.clear()
said = attempt("import _blenderkit_loopcut\n_blenderkit_loopcut.check(4, 0)")
check("no cuts at all", said is not None and "at least one cut" in said, said)
said = attempt('bpy.ops.mesh.loopcut_slide(MESH_OT_loopcut={"number_cuts": 1, "edge_index": 4, "object_index": 0})')
check("no 3D View in the context: refused, not run (Blender segfaults there)",
      said is not None and "with no 3D View in the context Blender crashes" in said and counts(obj) == (8, 12, 6), said)
said = attempt("import _blenderkit_context\nwith _blenderkit_context.temp_override_view3d('Loop Cut'):\n"
               "    bpy.ops.mesh.loopcut_slide('EXEC_DEFAULT', True, MESH_OT_loopcut={\"number_cuts\": 1, "
               "\"edge_index\": 4, \"object_index\": 0})")
check("its undo argument in the borrowed view: refused (with it on Blender segfaults in ED_area_type_hud_ensure)",
      said is not None and "was not run with its undo on" in said and counts(obj) == (8, 12, 6), said)

# Blender reads any int there as the undo flag (`bpy_op_parse_args`: the first
# int, PyLong_Check, then PyObject_IsTrue), so `1` crashed as True did past a
# guard that refused True alone (round 4's review: loopcut_slide, loopcut and
# transform.translate given 1 under temp_override_view3d, exit 139). So does
# any registered operator in an area override, and an unregistered one that
# runs one (`object.mode_set` runs editmode_toggle).
VIEW = "import _blenderkit_context\nwith _blenderkit_context.temp_override_view3d('Loop Cut'):\n    "
for undo_arg in ("True", "1", "2", "-1"):
    for label, line in (
            ("loopcut_slide", "bpy.ops.mesh.loopcut_slide('EXEC_DEFAULT', %s, MESH_OT_loopcut={'number_cuts': 1, "
                              "'edge_index': 4, 'object_index': 0})"),
            ("loopcut", "bpy.ops.mesh.loopcut('EXEC_DEFAULT', %s, number_cuts=1, edge_index=4, object_index=0)"),
            ("subdivide", "bpy.ops.mesh.subdivide('EXEC_DEFAULT', %s, number_cuts=1)"),
            ("an undo argument alone", "bpy.ops.mesh.subdivide(%s, number_cuts=1)"),
            ("transform.translate", "bpy.ops.transform.translate('EXEC_DEFAULT', %s, value=(0, 0, 1))"),
            ("object.mode_set", "bpy.ops.object.mode_set('EXEC_DEFAULT', %s, mode='OBJECT')")):
        obj = make('cube')
        edit(obj)
        bpy.ops.mesh.select_all(action='SELECT')
        said = attempt(VIEW + line % undo_arg)
        check("%s with %s as its undo argument in the borrowed view: refused in words, nothing changed"
              % (label, undo_arg), said is not None and "was not run with its undo on" in said
              and obj.mode == 'EDIT' and counts(obj) == (8, 12, 6) and tuple(obj.location) == (0, 0, 0),
              (said, obj.mode, counts(obj)))
for undo_arg, want in (("0", (12, 20, 10)), ("False", (12, 20, 10))):
    obj = make('cube')
    edit(obj)
    said = attempt(VIEW + "bpy.ops.mesh.loopcut_slide('EXEC_DEFAULT', %s, MESH_OT_loopcut={'number_cuts': 1, "
                   "'edge_index': 4, 'object_index': 0})" % undo_arg)
    check("with %s, the undo off, Blender's own call runs: %s" % (undo_arg, counts(obj)),
          said is None and counts(obj) == want, said)
obj = make('cube')
edit(obj)
said = attempt("import _blenderkit_context\nop = bpy.ops.mesh.subdivide\n"
               "with _blenderkit_context.temp_override_view3d('Loop Cut'):\n"
               "    bpy.ops.mesh.select_all(action='SELECT')\n    op('EXEC_DEFAULT', 1, number_cuts=1)")
check("an operator looked up before the override and called inside it with 1: refused too (it segfaulted)",
      said is not None and "was not run with its undo on" in said and counts(obj) == (8, 12, 6), said)
said = attempt("bpy.ops.mesh.select_all('EXEC_DEFAULT', 1, action='SELECT')")
check("with no area in the context the undo argument is Blender's: it runs", said is None, said)
said = attempt(VIEW + "bpy.ops.mesh.select_all('EXEC_DEFAULT', 1, 2, action='SELECT')")
check("arguments Blender itself refuses are Blender's ValueError, not run",
      said is not None and "1-2 args" in said, said)
decide = context.undo_requested
check("the guard reads the undo flag as Blender does: True, 1, 2, -1 and a bare 1 on; 0, False, none and "
      "what Blender refuses off",
      all(decide(a) for a in (('EXEC_DEFAULT', True), ('EXEC_DEFAULT', 1), ('EXEC_DEFAULT', 2), ('EXEC_DEFAULT', -1), (1,)))
      and not any(decide(a) for a in ((), ('EXEC_DEFAULT',), ('EXEC_DEFAULT', 0), ('EXEC_DEFAULT', False),
                                      ('EXEC_DEFAULT', 1, 2), (1, 'EXEC_DEFAULT'), ('EXEC_DEFAULT', 1.0))))
# The negative control: the rule the guard had, `argument is True`, lets 1
# through — the call that segfaulted.
check("the negative control: the old rule (True alone) reads 1 as no undo",
      not any(argument is True for argument in ('EXEC_DEFAULT', 1)) and decide(('EXEC_DEFAULT', 1)))
check("the strokes the app runs with their undo on in the borrowed view are still let through "
      "(unregistered and BLOCKING: brush_stroke, vertex_paint, weight_paint)",
      all('REGISTER' not in getattr(bpy.ops.paint if m != 'sculpt' else bpy.ops.sculpt, n).bl_options
          and 'BLOCKING' in getattr(bpy.ops.paint if m != 'sculpt' else bpy.ops.sculpt, n).bl_options
          for m, n in (('sculpt', 'brush_stroke'), ('paint', 'vertex_paint'), ('paint', 'weight_paint'))))

# A hidden object is not one the borrowed view hands Loop Cut: Blender
# answers CANCELLED (measured), which read as "found no edge 4".
obj = make('cube')
edit(obj)
obj.hide_set(True)
said = perform_cut(4)
check("the edited object hidden: refused in words naming it, nothing cut",
      said is not None and "Cube is hidden" in said and counts(obj) == (8, 12, 6), said)
obj.hide_set(False)

# --------------------------------------------------------------------------
print("\nThe Knife the app sends")


def knife_expected(obj, path, eye, forward, ortho, through):
    """Each mesh edge crossing the plane of a path segment and the lines of
    sight through its ends, inside that wedge, on the faces the view faces
    unless `through` (exact for a convex mesh)."""
    bm = bmesh.from_edit_mesh(obj.data)
    mw = obj.matrix_world
    pts = []

    def seen(f):
        c = mw @ f.calc_center_median()
        n = (mw.to_3x3() @ f.normal).normalized()
        return n.dot(-forward) > 0 if ortho else n.dot(eye - c) > 0

    for e in bm.edges:
        if not through and not any(seen(f) for f in e.link_faces):
            continue
        a, b = mw @ e.verts[0].co, mw @ e.verts[1].co
        for p, q in zip(path, path[1:]):
            n = (q - p).cross(forward) if ortho else (p - eye).cross(q - eye)
            origin = p if ortho else eye
            d = n.dot(b - a)
            if abs(d) < 1e-12:
                continue
            t = n.dot(origin - a) / d
            if not 1e-6 < t < 1 - 1e-6:
                continue
            x = a + (b - a) * t
            if ortho:
                u = (q - p) - forward * (q - p).dot(forward)
                inside = 0 <= (x - p).dot(u) / u.length_squared <= 1
            else:
                inside = (p - eye).cross(x - eye).dot(n) >= 0 and (x - eye).cross(q - eye).dot(n) >= 0
            if inside:
                pts.append(x)
    # A point of the path on the mesh is a vertex of the cut, as a click on a
    # face is in Blender's Knife: where its line of sight meets the faces the
    # view sees, or every face with Cut Through.
    from mathutils.bvhtree import BVHTree
    tree = BVHTree.FromBMesh(bm)
    inverse = mw.inverted()
    for p in path:
        origin = (p - forward * 1e4) if ortho else eye
        direction = forward if ortho else (p - eye).normalized()
        o, d = inverse @ origin, (inverse.to_3x3() @ direction).normalized()
        while True:
            hit, _, face, distance = tree.ray_cast(o, d)
            if hit is None:
                break
            pts.append(mw @ hit)
            if not through:
                break
            o = hit + d * 1e-5
    return pts


def vec(text):
    return Vector(tuple(float(c) for c in text.split(",")))


w, area, region = knife.view3d()
space = area.spaces.active
rv3d = space.region_3d


def view_state():
    return (tuple(rv3d.view_location), tuple(rv3d.view_rotation), rv3d.view_distance, rv3d.view_perspective,
            space.lens, space.clip_start, space.clip_end)


for name in ("persp", "persp3", "ortho"):
    eye_s, fwd_s, ortho_s = calls["knife.%s EYE" % name].split(";")
    eye, forward, ortho = vec(eye_s), vec(fwd_s).normalized(), ortho_s == "true"
    path = [vec(p) for p in calls["knife.%s PATH" % name].split(";")]
    for through in (False, True):
        obj = make('cube')
        other = bpy.data.objects.new("Other", bpy.data.meshes.new("Other"))
        bpy.context.scene.collection.objects.link(other)
        other.select_set(True)
        bpy.context.view_layer.objects.active = obj
        edit(obj, mode='VERT')
        want = knife_expected(obj, path, eye, forward, ortho, through)
        before = [v.co.copy() for v in bmesh.from_edit_mesh(obj.data).verts]
        c0 = counts(obj)
        state = view_state()
        said = attempt(calls["knife.%s %s" % (name, "THROUGH" if through else "FRONT")])
        bm = bmesh.from_edit_mesh(obj.data)
        made = [v.co.copy() for v in bm.verts if min((v.co - b).length for b in before) > 1e-6]
        worst = max((min((m - x).length for x in want) for m in made), default=None) if want else None
        missed = max((min((x - m).length for m in made) for x in want), default=None) if made else None
        selected_edges = sum(e.select for e in bm.edges)
        label = "%s, %d points, Cut Through %s" % (name, len(path), "on" if through else "off")
        check("%s: %d new vertices where the path's planes cross %d edges, worst %.1e m"
              % (label, len(made), len(want), worst if worst is not None else -1),
              said is None and len(made) == len(want) > 0 and worst < 1e-4 and missed < 1e-4,
              (said, len(made), len(want), worst, missed))
        check("%s: faces split, Vertex select mode kept, the %d cut edges selected" % (label, selected_edges),
              counts(obj)[2] > c0[2] and tuple(bpy.context.scene.tool_settings.mesh_select_mode) == (True, False, False)
              and selected_edges >= len(path) - 1,
              (counts(obj), tuple(bpy.context.scene.tool_settings.mesh_select_mode), selected_edges))
        check("%s: no path object left, Blender's view, lens and clipping as they were, Other still selected" % label,
              knife.PATH_OBJECT not in bpy.data.objects and knife.PATH_OBJECT not in bpy.data.meshes
              and view_state() == state and other.select_get(),
              ([o.name for o in bpy.data.objects], view_state() == state, other.select_get()))
        if name == "persp" and not through:
            front = (len(made), counts(obj))
        if name == "persp" and through:
            check("persp: Cut Through cuts the face behind as well (%d vertices against %d)" % (len(made), front[0]),
                  len(made) > front[0], (len(made), front))

# Under a Subdivision Surface the viewport draws the subdivided mesh, but the
# path's lines of sight are the same, and Blender's Knife cuts the edit cage
# along them (its cage is the base mesh unless On Cage is on).
eye_s, fwd_s, _ = calls["knife.persp EYE"].split(";")
eye, forward = vec(eye_s), vec(fwd_s).normalized()
path = [vec(p) for p in calls["knife.persp PATH"].split(";")]
obj = make('cube')
obj.modifiers.new("Subdivision", 'SUBSURF')
edit(obj, mode='VERT')
want = knife_expected(obj, path, eye, forward, False, False)
before = [v.co.copy() for v in bmesh.from_edit_mesh(obj.data).verts]
said = attempt(calls["knife.persp FRONT"])
made = [v.co.copy() for v in bmesh.from_edit_mesh(obj.data).verts if min((v.co - b).length for b in before) > 1e-6]
worst = max((min((m - x).length for x in want) for m in made), default=1) if want else 1
check("under a Subdivision Surface the cage is cut along the same lines of sight: %d vertices, worst %.1e m"
      % (len(made), worst), said is None and len(made) == len(want) == 3 and worst < 1e-4, (said, len(made), worst))

# The comparison can fail: the same perspective cut against the crossings an
# orthographic projection along the view would make.
eye_s, fwd_s, _ = calls["knife.persp EYE"].split(";")
eye, forward = vec(eye_s), vec(fwd_s).normalized()
path = [vec(p) for p in calls["knife.persp PATH"].split(";")]
obj = make('cube')
edit(obj, mode='VERT')
wrong = knife_expected(obj, path, eye, forward, True, False)
before = [v.co.copy() for v in bmesh.from_edit_mesh(obj.data).verts]
attempt(calls["knife.persp FRONT"])
made = [v.co.copy() for v in bmesh.from_edit_mesh(obj.data).verts if min((v.co - b).length for b in before) > 1e-6]
off = max((min((m - x).length for x in wrong) for m in made), default=0) if wrong else 1
check("the negative control: held to an orthographic projection the perspective cut is %.3f m off" % off, off > 1e-2)

# Redo through Blender's undo: Cut Through turned on in the panel.
obj = make('cube')
edit(obj, mode='VERT')
undo.push(HISTORY, "Fixture")
attempt(calls["knife.persp FRONT"])
undo.push(HISTORY, "Knife Topology Tool")
front_counts = counts(obj)
undo.rewind()
said = attempt(calls["knife.persp ADJUSTED"])
undo.push(HISTORY, "Knife Topology Tool", replace=True)
obj = bpy.context.view_layer.objects.active
check("re-run through Blender's undo with Cut Through on: %s, then %s" % (front_counts, counts(obj)),
      said is None and front_counts == (11, 17, 8) and counts(obj) == (12, 20, 10), (said, front_counts, counts(obj)))

for name, words in (("miss", "does not cross Cube"), ("behind", "is behind the view")):
    obj = make('cube')
    edit(obj, mode='VERT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    for i in (0, 3):
        bm.verts[i].select = True
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)
    state = view_state()
    said = attempt(calls["knife.%s FRONT" % name])
    bm = bmesh.from_edit_mesh(obj.data)
    kept = [v.index for v in bm.verts if v.select]
    mode = tuple(bpy.context.scene.tool_settings.mesh_select_mode)
    check("%s: refused in words, nothing cut, no path object, the view as it was, Vertex select mode and the "
          "selected vertices %s kept" % (name, kept),
          said is not None and words in said and counts(obj) == (8, 12, 6)
          and knife.PATH_OBJECT not in bpy.data.objects and view_state() == state
          and mode == (True, False, False) and kept == [0, 3], (said, mode, kept))
said = attempt("import _blenderkit_knife\nwith _blenderkit_knife.drawing([(0, 0, 3)], (0, 0, 9), (0, 0, -1), (0, 1, 0)):\n"
               "    bpy.ops.mesh.knife_project()")
check("one point: refused in words", said is not None and "at least two" in said, said)
said = attempt("import _blenderkit_knife\nwith _blenderkit_knife.drawing([(0, 0, 3), (float('nan'), 0, 3)], (0, 0, 9), "
               "(0, 0, -1), (0, 1, 0)):\n    bpy.ops.mesh.knife_project()")
check("a point that is not a number: refused in words", said is not None and "not a number" in said, said)
obj = make('cube')
said = attempt(calls["knife.persp FRONT"])
check("from Object Mode the app's bracket cuts in Edit Mode and comes back out (%s)" % (obj.mode,),
      said is None and obj.mode == 'OBJECT' and len(obj.data.vertices) == 11, (said, obj.mode, len(obj.data.vertices)))

# --------------------------------------------------------------------------
print("\nThe Knife snaps as Blender's knife does")


def knife_case(name, mode='VERT', select=None):
    obj = make('cube')
    edit(obj, mode=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    if select == 'front':
        for f in bm.faces:
            if abs(f.calc_center_median().y + 1) < 1e-6:
                f.select = True
        bmesh.update_edit_mesh(obj.data)
    before = [v.co.copy() for v in bmesh.from_edit_mesh(obj.data).verts]
    said = attempt(calls["knife.%s FRONT" % name])
    bm = bmesh.from_edit_mesh(obj.data)
    made = sorted(tuple(round(c, 4) for c in v.co) for v in bm.verts if min((v.co - b).length for b in before) > 1e-6)
    faces = sorted(len(f.verts) for f in bm.faces)
    # Centres, not the faces: a BMFace outlives the BMesh it came from only as
    # a dead reference.
    selected = [f.calc_center_median().copy() for f in bm.faces if f.select]
    return obj, said, made, faces, selected


print("  the snaps: " + "; ".join("%s %s" % (n, calls["knife.%s SNAPS" % n]) for n in
                                  ("snap_edges", "snap_corners", "snap_close", "sight")))
obj, said, made, faces, _ = knife_case("snap_edges")
check("two taps 2 px inside a face's side edges land on them: the vertices on x = -1 and 1, the face split into "
      "two quads, its neighbours pentagons (%s, faces %s)" % (made, faces),
      said is None and counts(obj) == (10, 15, 7) and faces == [4, 4, 4, 4, 4, 5, 5]
      and [m[0] for m in made] == [-1.0, 1.0], (said, counts(obj), made, faces))
obj, said, made, faces, _ = knife_case("raw_edges")
check("the negative control: the same taps unsnapped cut a hexagon with slivers (faces %s), the vertices "
      "inside the face" % faces, said is None and faces == [4, 4, 4, 4, 4, 4, 6] and all(abs(m[0]) < 0.999 for m in made),
      (said, made, faces))
obj, said, made, faces, _ = knife_case("snap_corners")
check("two taps near opposite corners land on them: the face split corner to corner into two triangles, "
      "no new vertex (%s, faces %s)" % (counts(obj), faces),
      said is None and counts(obj) == (8, 13, 7) and faces == [3, 3, 4, 4, 4, 4, 4] and not made, (said, counts(obj), faces))
obj, said, made, faces, _ = knife_case("snap_close")
check("a fifth tap 3.6 pt from the first closes the path on it: 4 new vertices, none beside another (%s)"
      % (counts(obj),), said is None and len(made) == 4 and counts(obj) == (12, 18, 8), (said, made, counts(obj)))
obj, said, made, faces, _ = knife_case("raw_close")
check("the negative control: unsnapped, the fifth tap makes a fifth vertex beside the first (%d new)" % len(made),
      said is None and len(made) == 5, (said, made))
obj, said, made, faces, _ = knife_case("sight")
_, said_ref, made_ref, faces_ref, _ = knife_case("sight_ref")
check("p2 on p1's line of sight between p1 and p3: the cut p1 to p3 alone makes, vertex for vertex "
      "(%s, faces %s)" % (made, faces),
      said is None and said_ref is None and made == made_ref and faces == faces_ref and len(made) == 2,
      (said, made, made_ref, faces, faces_ref))
# Knife Project given the three points as they are: Python joins the two on
# one line of sight too (`_wire`), half a pixel of Blender's own view.
p1 = Vector((-0.5, -1, 0)); eye = Vector((0, -6, 0)); p2 = eye + (p1 - eye) * 1.8
for label, path, want in (("p1, p2, p3", [p1, p2, Vector((0.5, -1, 0))], (10, 15, 7)), ("p1, p2", [p1, p2], None)):
    obj = make('cube')
    edit(obj, mode='VERT')
    said = attempt("import _blenderkit_knife\nwith _blenderkit_knife.drawing(%r, eye=(0, -6, 0), forward=(0, 1, 0), "
                   "up=(0, 0, 1)):\n    bpy.ops.mesh.knife_project()" % ([tuple(p) for p in path],))
    if want:
        check("a script's %s on one line of sight: cut as p1 to p3 (%s)" % (label, counts(obj)),
              said is None and counts(obj) == want, said)
    else:
        check("a script's %s alone: refused in words, nothing cut" % label,
              said is not None and "one line of sight" in said and counts(obj) == (8, 12, 6), said)
obj, said, made, faces, selected = knife_case("snap_edges", mode='FACE', select='front')
check("Face select mode, the front face selected: both its halves still selected after the cut, as Blender's "
      "knife leaves them (%d faces)" % len(selected),
      said is None and len(selected) == 2 and all(abs(c.y + 1) < 1e-6 for c in selected),
      (said, len(selected)))
obj, said, made, faces, selected = knife_case("snap_edges", mode='FACE')
check("Face select mode, nothing selected: nothing selected after (Blender's knife selects no edge there)",
      said is None and not selected and not any(e.select for e in bmesh.from_edit_mesh(obj.data).edges), said)
bm = bmesh.from_edit_mesh(obj.data)
check("the knife's own layers are gone after the cut", not bm.edges.layers.int.keys() and not bm.faces.layers.int.keys(),
      (list(bm.edges.layers.int.keys()), list(bm.faces.layers.int.keys())))

# The selection the cut leaves, in each mode, with its order: what was
# selected and not cut stays, active included (`_select_like_the_knife`).
for mode, pick, want_kind in (('VERT', 'corner', 'BMVert'), ('EDGE', 'bottom', 'BMEdge'), ('FACE', 'top', 'BMFace')):
    obj = make('cube')
    edit(obj, mode=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    if pick == 'corner':
        element = next(v for v in bm.verts if (v.co - Vector((-1, 1, 1))).length < 1e-6)
    elif pick == 'bottom':
        element = next(e for e in bm.edges if ((e.verts[0].co + e.verts[1].co) / 2 - Vector((0, -1, -1))).length < 1e-6)
    else:
        element = next(f for f in bm.faces if abs(f.calc_center_median().z - 1) < 1e-6)
    element.select = True
    bm.select_history.add(element)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(obj.data)
    said = attempt(calls["knife.snap_edges FRONT"])
    bm = bmesh.from_edit_mesh(obj.data)
    active = type(bm.select_history.active).__name__ if bm.select_history.active else None
    still = (sum(v.select for v in bm.verts), sum(e.select for e in bm.edges), sum(f.select for f in bm.faces))
    want = {'VERT': (3, 1, 0), 'EDGE': (4, 2, 0), 'FACE': (4, 4, 1)}[mode]
    check("%s select mode, the %s selected and active: kept, active, and the cut's edges added outside Face mode "
          "(%s selected)" % (mode.title(), pick, still), said is None and active == want_kind and still == want,
          (said, active, still))

# The mesh backup a re-run starts from holds the active mesh alone, and Knife
# Project cuts every mesh in Edit Mode, so with another mesh in Edit Mode the
# cut is made and no re-run is offered (`actsOnSelection`).
for others, want in ((False, True), (True, False)):
    obj = make('cube')
    if others:
        bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 4, 0))
        bpy.context.view_layer.objects.active = obj
        for o in bpy.data.objects:
            o.select_set(True)
    edit(obj, mode='VERT')
    scope = {"bpy": bpy}
    try:
        exec(compile(calls["knife.persp PERFORM"], "<app>", "exec"), scope)
        said = None
    except Exception as error:
        said = str(error)
    check("the Knife with %s in Edit Mode: cut, and a re-run %s" % ("another mesh" if others else "its mesh alone",
                                                                    "offered" if want else "not offered"),
          said is None and scope.get("_bk_adjustable") is want and counts(obj) == (11, 17, 8),
          (said, scope.get("_bk_adjustable"), counts(obj), [o.name for o in bpy.context.objects_in_mode]))

# Under a modifier that rebuilds the mesh the viewport's elements are not
# Blender's, and the Knife asks Blender for its cage (`cage_json`), which is
# what Blender's knife snaps to there.
import io, contextlib as _contextlib
obj = make('cube')
obj.location = (0, 0, 2)
obj.modifiers.new("Subdivision", 'SUBSURF').levels = 2
edit(obj, hide=(0,))
out = io.StringIO()
with _contextlib.redirect_stdout(out):
    knife.cage_json()
cage = json.loads(out.getvalue())
corners = [tuple(cage["positions"][i:i + 3]) for i in range(0, len(cage["positions"]), 3)]
check("Blender's cage for the Knife under a Subdivision: the 8 corners in world space (z from 1 to 3), and the 5 "
      "faces that are not hidden", len(corners) == 8 and sorted({round(c[2], 4) for c in corners}) == [1.0, 3.0]
      and len(cage["faces"]) == 5 and all(len(f) == 4 for f in cage["faces"]), cage)
bpy.ops.object.mode_set(mode='OBJECT')
out = io.StringIO()
with _contextlib.redirect_stdout(out):
    knife.cage_json()
check("and out of Edit Mode, a refusal in its place", "refused" in json.loads(out.getvalue()), out.getvalue())

# --------------------------------------------------------------------------
print("\nSubdivide Edge-Ring, the row that was called Loop Cut")

check("the call is Blender's with Blender's defaults: 10 cuts, Blend Path, Smoothness 1, Profile Factor 0, "
      "Profile Shape Smooth",
      "subdivide_edgering(number_cuts=10, interpolation='PATH', smoothness=1, profile_shape_factor=0, "
      "profile_shape='SMOOTH')" in calls["edgering PERFORM"], calls["edgering PERFORM"])
rna = {p.identifier: p for p in bpy.ops.mesh.subdivide_edgering.get_rna_type().properties}
check("and those are the defaults Blender's own RNA holds",
      (rna['number_cuts'].default, rna['interpolation'].default, rna['smoothness'].default,
       rna['profile_shape_factor'].default, rna['profile_shape'].default) == (10, 'PATH', 1.0, 0.0, 'SMOOTH'))
for picks, want, words in (([4], (8, 12, 6), "select two or more"), (None, (28, 42, 16), None),
                           ([0, 1], (8, 12, 6), "found no quads")):
    obj = make('cube')
    edit(obj)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.edges.ensure_lookup_table()
    chosen = picks if picks is not None else loopcut.ring(4)["edges"][:2]
    for i in chosen:
        bm.edges[i].select = True
        for v in bm.edges[i].verts:
            v.select = True
    bmesh.update_edit_mesh(obj.data)
    said = attempt(calls["edgering PERFORM"])
    if words:
        check("%s selected: refused in words (%s), nothing cut" % (chosen, words),
              said is not None and words in said and counts(obj) == want, (said, counts(obj)))
    else:
        check("two edges of a ring %s: the quad between them cut ten times, 8/12/6 to %s" % (chosen, counts(obj)),
              said is None and counts(obj) == want, (said, counts(obj)))
obj = make('cube')
edit(obj)
bm = bmesh.from_edit_mesh(obj.data)
bm.edges.ensure_lookup_table()
for i in loopcut.ring(4)["edges"][:2]:
    bm.edges[i].select_set(True)
bmesh.update_edit_mesh(obj.data)
budget = multires.BUDGET
multires.BUDGET = 20
said = attempt(calls["edgering PERFORM"])
multires.BUDGET = budget
check("ten cuts priced against the vertex budget first (lowered to 20 here): refused in words, nothing cut",
      said is not None and "Subdivide Edge-Ring with 10 cuts" in said and counts(obj) == (8, 12, 6), said)

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
