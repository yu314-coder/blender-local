"""What Blender has freed, read by the gate: one case per Blender, run by
freed_drive.py under MallocScribble and MallocGuardEdges, several rounds
each (fix round 3, October 29).

    Blender -b --factory-startup --python freed.py -- WORK case=NAME [rounds=N]

Round 4's fix round 2 left a use-after-free in ordinary use: a 61 x 61 grid
under a one-node Geometry Nodes group, Edit Mode, Select All, Extrude, and
leaving Edit Mode exited 139 on the first leave under MallocScribble
(rna_AttributeGroup_iterator_begin <- Mesh_attributes_begin <- the gate's
`_diff_attributes` in depsgraph_update_pre). Blender's evaluated copy of a
mesh in Edit Mode points at the original's edit mesh
(deg_eval_copy_on_write.cc, `update_mesh_edit_mode_pointers`); leaving Edit
Mode frees that edit mesh's BMesh, and the copy keeps pointing at it until
the evaluation that follows depsgraph_update_pre. Each case here is a path
that reads an evaluated copy, or a data-block a copy points at, in that
window: other modifiers, other Edit Mode operators, Undo and Redo across the
leave, the sculpt and paint modes, curves, lattices, metaballs, text and
armatures, and data-blocks Blender's copies do not copy (images, fonts),
removed while a copy still points at them. A case passes when Blender
survives every round; it prints what the gate said and what Blender built,
and the cases that hold a price check it.

Desktop Blender with the app's context (its modules from BK_SITE, or the
source tree; `_blenderkit_context.install`, gpu.init(), the app's undo
push). Nothing here opens a window, a browser or another app.
"""
import bpy, gpu, sys, os, types, importlib.util, pathlib, threading

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = pathlib.Path(os.environ.get("BK_SITE") or ROOT / "Resources/python/site")
# As in the app, where the modules import one another by name.
sys.path.insert(0, str(SITE))
ARGS = sys.argv[sys.argv.index("--") + 1:]
WORK = ARGS[0]
OPTS = dict(a.split("=", 1) for a in ARGS[1:] if "=" in a)
CASE = OPTS.get("case", "gn_extrude")
ROUNDS = int(OPTS.get("rounds", "6"))
fail = 0

import webbrowser, subprocess


def _blocked(*a, **k):
    raise RuntimeError("blocked by the freed-memory check: no browser or subprocess")


webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


class _App(types.ModuleType):
    def is_main_thread(self):
        return threading.current_thread() is threading.main_thread()

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
context.install(bpy)
for name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools", "_blenderkit_points"):
    load(name)
budget = load("_blenderkit_budget")
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
gpu.init()
undo.push(os.path.join(WORK, ".blender-history"), "start")
gate = sys.modules["_blenderkit_gate"]


def mirror():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def said_by(call, *args, **keywords):
    try:
        call(*args, **keywords)
    except RuntimeError as error:
        return str(error)
    return None


def count(obj):
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


def note(text):
    print("  " + text, flush=True)


def clear():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)


def one_node_group(node='GeometryNodeSetPosition'):
    tree = bpy.data.node_groups.new("One", 'GeometryNodeTree')
    tree.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    tree.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    i = tree.nodes.new('NodeGroupInput')
    o = tree.nodes.new('NodeGroupOutput')
    s = tree.nodes.new(node)
    tree.links.new(i.outputs[0], s.inputs[0])
    tree.links.new(s.outputs[0], o.inputs[0])
    return tree


def grid(modifier='GN', n=60):
    clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2)
    g = bpy.context.object
    if modifier == 'GN':
        mod = g.modifiers.new("GN", 'NODES')
        mod.node_group = one_node_group()
    elif modifier == 'BEVEL':
        mod = g.modifiers.new("Bevel", 'BEVEL')
        mod.limit_method = 'WEIGHT'
        mod.segments = 2
    elif modifier == 'REMESH':
        mod = g.modifiers.new("Remesh", 'REMESH')
        mod.mode = 'VOXEL'
        mod.voxel_size = 0.1
    elif modifier == 'ARRAY':
        mod = g.modifiers.new("Array", 'ARRAY')
        mod.fit_type = 'FIT_LENGTH'
        mod.fit_length = 6.0
    elif modifier == 'SUBSURF':
        mod = g.modifiers.new("Subdivision", 'SUBSURF')
        mod.levels = 1
    bpy.context.view_layer.update()
    return g


def edit_rounds(obj, operator, leave=('mode_set', 'OBJECT'), rounds=ROUNDS):
    """`operator` (a callable) in Edit Mode, then leave, `rounds` times."""
    for r in range(rounds):
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        said = said_by(operator)
        if said:
            note("round %d: refused: %s" % (r + 1, said[:140]))
        how, mode = leave
        if how == 'toggle':
            bpy.ops.object.editmode_toggle()
        else:
            bpy.ops.object.mode_set(mode=mode)
            if obj.mode != 'OBJECT':
                bpy.ops.object.mode_set(mode='OBJECT')
        note("round %d left Edit Mode: %d vertices" % (r + 1, len(obj.data.vertices)))


def extrude():
    bpy.ops.mesh.extrude_region_move(TRANSFORM_OT_translate={"value": (0, 0, 0.01)})


# --------------------------------------------------------------------------
# The cases

def case_gn_extrude():
    """The review's: /Volumes/D/.../fixround3/uaf.py, as a case."""
    edit_rounds(grid('GN'), extrude)


def case_bevel_weight_extrude():
    edit_rounds(grid('BEVEL'), extrude)


def case_remesh_extrude():
    edit_rounds(grid('REMESH', 20), extrude)


def case_array_fit_extrude():
    edit_rounds(grid('ARRAY', 20), extrude)


def case_subsurf_extrude():
    edit_rounds(grid('SUBSURF', 30), extrude)


def case_gn_operators():
    g = grid('GN', 30)
    for op in (lambda: bpy.ops.mesh.subdivide(),
               lambda: bpy.ops.mesh.delete(type='FACE'),
               lambda: bpy.ops.mesh.primitive_cube_add(size=0.2),
               lambda: bpy.ops.mesh.bevel(offset=0.01),
               lambda: bpy.ops.mesh.remove_doubles(),
               lambda: bpy.ops.transform.resize(value=(0.5, 0.5, 0.5)),
               lambda: bpy.ops.mesh.select_all(action='DESELECT'),
               # The app's Mesh ▸ Extrude row (LastOperator.mesh(.extrude)).
               lambda: bpy.ops.mesh.extrude_region_shrink_fatten(TRANSFORM_OT_shrink_fatten={"value": 0.2})):
        edit_rounds(g, op, rounds=max(1, ROUNDS // 3))


def case_gn_toggle():
    edit_rounds(grid('GN'), extrude, leave=('toggle', None))


def case_gn_to_sculpt():
    """Edit Mode straight to Sculpt Mode, and to the paint modes."""
    g = grid('GN')
    for r in range(ROUNDS):
        for mode in ('SCULPT', 'VERTEX_PAINT', 'WEIGHT_PAINT', 'TEXTURE_PAINT'):
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
            # Extrude Region doubles the grid's vertices: once a round, or the
            # rounds spend their time on the budget's refusals.
            said = said_by(extrude) if mode == 'SCULPT' else said_by(bpy.ops.transform.translate,
                                                                      value=(0, 0, 0.001))
            if said:
                note("refused: " + said[:140])
            said = said_by(bpy.ops.object.mode_set, mode=mode)
            if said:
                note("to %s refused: %s" % (mode, said[:140]))
            g.location.x += 0.001
            said = mirror()
            if said:
                note("mirror: " + said[:140])
            bpy.ops.object.mode_set(mode='OBJECT')
        note("round %d: %d vertices" % (r + 1, len(g.data.vertices)))


def case_gn_undo():
    """Undo and Redo across the leave."""
    name = grid('GN').name
    for r in range(ROUNDS):
        g = bpy.data.objects[name]
        bpy.context.view_layer.objects.active = g
        bpy.ops.object.mode_set(mode='EDIT')
        undo.push(os.path.join(WORK, ".blender-history"), "edit")
        bpy.ops.mesh.select_all(action='SELECT')
        said_by(extrude)
        bpy.ops.object.mode_set(mode='OBJECT')
        undo.push(os.path.join(WORK, ".blender-history"), "left")
        for op in (bpy.ops.ed.undo, bpy.ops.ed.undo, bpy.ops.ed.redo, bpy.ops.ed.redo):
            said = said_by(op)
            if said:
                note("refused: " + said[:140])
            said = mirror()
            if said:
                note("mirror: " + said[:140])
        g = bpy.data.objects[name]
        if g.mode != 'OBJECT':
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='OBJECT')
        note("round %d: %d vertices" % (r + 1, len(g.data.vertices)))


def case_gn_bmesh():
    """A script's bmesh edit of the edited mesh, told and untold, then the
    leave."""
    import bmesh
    g = grid('GN')
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = g
        bpy.ops.object.mode_set(mode='EDIT')
        bm = bmesh.from_edit_mesh(g.data)
        bmesh.ops.subdivide_edges(bm, edges=bm.edges[:40], cuts=1)
        if r % 2:
            bmesh.update_edit_mesh(g.data)
        bpy.ops.object.mode_set(mode='OBJECT')
        note("round %d left Edit Mode: %d vertices" % (r + 1, len(g.data.vertices)))


def case_bmesh_modifiers():
    """The same bmesh edit, told and untold, then the leave, under each kind
    of modifier `_grows_from_cage` holds a transaction for. An untold edit
    reaches the budget's `price_state` as an `edited` struct, whose
    `_held_count` reads Blender's evaluated object while it still holds the
    freed edit mesh's wrapper (fix round 3's verification: only Geometry
    Nodes and an Array were run through that read before)."""
    import bmesh
    for kind in ('SUBSURF', 'REMESH', 'BEVEL', 'ARRAY', 'GN'):
        g = grid(kind, 20)
        for r in range(max(2, ROUNDS // 2)):
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='EDIT')
            bm = bmesh.from_edit_mesh(g.data)
            bmesh.ops.subdivide_edges(bm, edges=bm.edges[:20], cuts=1)
            for v in bm.verts[:10]:
                v.co.z += 0.01
            if r % 2:
                bmesh.update_edit_mesh(g.data)
            said = said_by(bpy.ops.object.mode_set, mode='OBJECT')
            if g.mode != 'OBJECT':
                bpy.ops.object.mode_set(mode='OBJECT')
            said = said or mirror()
            if said:
                note("%s round %d: %s" % (kind, r + 1, said[:140]))
        note("%s: %d vertices, Blender at %d" % (kind, len(g.data.vertices), count(g)))


def case_bmesh_leave_price():
    """The leave, priced: a script line's bmesh edit that tells Blender
    nothing, then leaving Edit Mode in the same line (the operator's call
    prices only what Blender was told). A cube under an Array fitted to 40,
    every vertex's x scaled to a ten-thousandth, budget 100,000. Before this
    round the leave's update skipped the vertices of a mesh just out of Edit
    Mode (`_edit_meshes_then`)."""
    import bmesh
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    m = a.modifiers.new("Array", 'ARRAY')
    m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    bpy.context.view_layer.update()
    before = count(a)
    budget.BUDGET, kept = 100_000, budget.BUDGET
    try:
        bpy.ops.object.mode_set(mode='EDIT')
        bm = bmesh.from_edit_mesh(a.data)
        for v in bm.verts:
            v.co.x *= 0.0001
        said = said_by(bpy.ops.object.mode_set, mode='OBJECT')
        if a.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        said = said or mirror()
        after = count(a)
    finally:
        budget.BUDGET = kept
    check("an untold bmesh edit, then leaving Edit Mode, is refused in words: a cube under an Array fitted to "
          "40 (%d) scaled to a ten-thousandth stays under 100,000 (Blender at %s)" % (before, format(after, ',')),
          said is not None and "stops at 100,000" in said and after <= 100_000, said)


def case_leave_unchanged():
    """Entering and leaving Edit Mode with nothing changed is no change to
    price: the gate keeps what Blender built the edit mesh from (`_post`),
    and the leave matches it. Counted calls of the budget's price."""
    g = grid('GN')
    calls = []
    inner = budget.price_state

    def counting(*args, **keywords):
        calls.append(1)
        return inner(*args, **keywords)
    budget.price_state = counting
    try:
        for r in range(ROUNDS):
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
            bpy.ops.object.mode_set(mode='OBJECT')
            mirror()
    finally:
        budget.price_state = inner
    check("%d round trips through Edit Mode with nothing changed priced nothing (%d prices)" % (ROUNDS, len(calls)),
          not calls)


def case_bevel_weight_line():
    """The guarantee the attribute read gave (round 4's fix round 2 review):
    a 120 x 120 grid under a Bevel limited by Weight at 14 segments, its
    Bevel Weights written by a script line in Object Mode, refused — after an
    Edit Mode round trip, whose leave no longer reads Blender's copy."""
    import numpy as np
    clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=120, y_subdivisions=120, size=2)
    g = bpy.context.object
    mod = g.modifiers.new("Bevel", 'BEVEL')
    mod.limit_method, mod.segments = 'WEIGHT', 14
    bpy.context.view_layer.update()
    for r in range(ROUNDS):
        edit_rounds(g, lambda: None, rounds=1)
    before = count(g)
    layer = g.data.attributes.get('bevel_weight_edge') or g.data.attributes.new('bevel_weight_edge', 'FLOAT', 'EDGE')
    layer.data.foreach_set('value', np.ones(len(g.data.edges), dtype=np.float32))
    g.data.update()
    said = mirror()
    after = count(g)
    check("Bevel Weights of 1 written by a script line on a 120 x 120 grid under a Bevel limited by Weight "
          "at 14 segments are refused (Blender %s -> %s)" % (format(before, ','), format(after, ',')),
          said is not None and "stops at" in said and after == before, said)


def case_bevel_weight_edit():
    """Bevel Weights written in Edit Mode by a script line through RNA, then
    the leave: priced, refused."""
    import numpy as np
    clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=120, y_subdivisions=120, size=2)
    g = bpy.context.object
    mod = g.modifiers.new("Bevel", 'BEVEL')
    mod.limit_method, mod.segments = 'WEIGHT', 14
    bpy.context.view_layer.update()
    before = count(g)
    bpy.ops.object.mode_set(mode='EDIT')
    import bmesh
    bm = bmesh.from_edit_mesh(g.data)
    layer = bm.edges.layers.float.get('bevel_weight_edge') or bm.edges.layers.float.new('bevel_weight_edge')
    for e in bm.edges:
        e[layer] = 1.0
    said = said_by(bpy.ops.object.mode_set, mode='OBJECT')
    if g.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    said = said or mirror()
    after = count(g)
    check("Bevel Weights of 1 set by bmesh in Edit Mode, untold, then leaving it, are refused in words "
          "(Blender %s -> %s)" % (format(before, ','), format(after, ',')),
          said is not None and "stops at" in said and after <= budget.BUDGET, said)


def case_curve_edit():
    clear()
    bpy.ops.curve.primitive_bezier_curve_add()
    c = bpy.context.object
    m = c.modifiers.new("Array", 'ARRAY') if hasattr(c, 'modifiers') else None
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = c
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.curve.select_all(action='SELECT')
        said_by(bpy.ops.curve.subdivide)
        said_by(bpy.ops.transform.resize, value=(0.9, 0.9, 0.9))
        bpy.ops.object.mode_set(mode='OBJECT')
        c.location.x += 0.001
        mirror()
        note("round %d: %d points" % (r + 1, len(c.data.splines[0].bezier_points)))


def case_lattice_edit():
    clear()
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    bpy.ops.object.add(type='LATTICE')
    lat = bpy.context.object
    m = cube.modifiers.new("Lattice", 'LATTICE')
    m.object = lat
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = lat
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.lattice.select_all(action='SELECT')
        said_by(bpy.ops.transform.resize, value=(0.9, 0.9, 0.9))
        bpy.ops.object.mode_set(mode='OBJECT')
        lat.data.points_u = 3 + r % 3
        mirror()
        note("round %d: %d points" % (r + 1, len(lat.data.points)))


def case_metaball_edit():
    clear()
    bpy.ops.object.metaball_add()
    mb = bpy.context.object
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = mb
        bpy.ops.object.mode_set(mode='EDIT')
        said_by(bpy.ops.mball.duplicate_metaelems)
        bpy.ops.object.mode_set(mode='OBJECT')
        mb.data.resolution = 0.4
        mirror()
        note("round %d: %d elements" % (r + 1, len(mb.data.elements)))


def case_text_edit():
    clear()
    bpy.ops.object.text_add()
    t = bpy.context.object
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = t
        bpy.ops.object.mode_set(mode='EDIT')
        said_by(bpy.ops.font.text_insert, text="ab")
        bpy.ops.object.mode_set(mode='OBJECT')
        t.data.extrude = 0.01 * (r + 1)
        mirror()
        note("round %d: %r" % (r + 1, t.data.body))


def case_armature_edit():
    clear()
    bpy.ops.object.armature_add()
    arm = bpy.context.object
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.armature.select_all(action='SELECT')
        said_by(bpy.ops.armature.subdivide)
        bpy.ops.object.mode_set(mode='OBJECT')
        arm.location.x += 0.001
        mirror()
        note("round %d: %d bones" % (r + 1, len(arm.data.bones)))


def case_remove_in_edit():
    """The edited mesh's object, then its mesh, removed by a script while in
    Edit Mode, then the next evaluation."""
    for r in range(ROUNDS):
        g = grid('GN', 30)
        bpy.ops.object.mode_set(mode='EDIT')
        said_by(extrude)
        mesh = g.data
        bpy.data.objects.remove(g)
        said = mirror()
        if said:
            note("mirror: " + said[:140])
        bpy.data.meshes.remove(mesh)
        bpy.context.view_layer.update()
        note("round %d: %d objects" % (r + 1, len(bpy.data.objects)))


def case_image_removed():
    """Data-blocks Blender's copies point at as they are (an image, a font):
    an image empty's image, a Geometry Nodes input's image, a custom
    property's image and a driver's image target, removed by a script line
    before the next evaluation."""
    for r in range(ROUNDS):
        clear()
        img = bpy.data.images.new("I%d" % r, 8, 8)
        bpy.ops.object.empty_add(type='IMAGE')
        empty = bpy.context.object
        empty.data = img
        bpy.ops.mesh.primitive_cube_add()
        cube = bpy.context.object
        cube["img"] = img
        mod = cube.modifiers.new("Array", 'ARRAY')
        curve = mod.driver_add("count")
        var = curve.driver.variables.new()
        var.targets[0].id_type = 'IMAGE'
        var.targets[0].id = img
        var.targets[0].data_path = 'size[0]'
        curve.driver.expression = "2"
        bpy.context.view_layer.update()
        bpy.data.images.remove(img)
        empty.location.x += 0.01
        cube.location.x += 0.01
        said = mirror()
        if said:
            note("mirror: " + said[:160])
        note("round %d: Blender at %d" % (r + 1, count(cube)))


def case_font_removed():
    for r in range(ROUNDS):
        clear()
        for f in list(bpy.data.fonts):
            if f.users == 0:
                bpy.data.fonts.remove(f)
        bpy.ops.object.text_add()
        t = bpy.context.object
        t.data.body = "Fonts %d" % r
        font = t.data.font
        bpy.context.view_layer.update()
        bpy.data.fonts.remove(font)
        t.location.x += 0.01
        said = mirror()
        if said:
            note("mirror: " + said[:160])
        note("round %d: font %r" % (r + 1, getattr(t.data.font, 'name', None)))


def case_action_removed():
    """An action and an NLA strip's action removed while assigned (the copies
    still point at Blender's copies of them, whose originals are freed: the
    frame plan's `_original_pointer` read `.original` there)."""
    for r in range(ROUNDS):
        clear()
        bpy.ops.mesh.primitive_cube_add()
        cube = bpy.context.object
        cube.keyframe_insert("location", frame=1)
        cube.location.x = 2.0
        cube.keyframe_insert("location", frame=10)
        act = cube.animation_data.action
        bpy.ops.object.empty_add()
        empty = bpy.context.object
        empty.animation_data_create()
        track = empty.animation_data.nla_tracks.new()
        strip_action = bpy.data.actions.new("S%d" % r)
        track.strips.new("S", 1, strip_action)
        bpy.context.view_layer.update()
        bpy.data.actions.remove(act)
        bpy.data.actions.remove(strip_action)
        cube.location.y += 0.01
        empty.location.y += 0.01
        said = mirror()
        if said:
            note("mirror: " + said[:160])
        bpy.context.scene.frame_set(1 + r)
        note("round %d: frame %d" % (r + 1, bpy.context.scene.frame_current))


def _heavy(name):
    import bmesh
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    obj.modifiers.new("Array", 'ARRAY').count = 400_000
    return obj


def _built(obj, scene):
    evaluated = obj.evaluated_get(scene.view_layers[0].depsgraph)
    return len(evaluated.data.vertices) if evaluated.data is not None else 0


def case_window_scene_removed():
    """Removing the window's own scene (fix round 2's final check: "The vertex
    budget could not price this change ('ID' object has no attribute
    'frame_current')"): Blender gives the window the other scene and starts
    its frame on a depsgraph built that moment, with copies not made yet.
    Works as Blender does, and what the other scene then evaluates for the
    first time is priced: a cube under an Array of 400,000 there is refused
    in words."""
    for r in range(ROUNDS):
        clear()
        heavy = r % 2 == 1
        s2 = bpy.data.scenes.new("S2-%d" % r)
        if heavy:
            s2.collection.objects.link(_heavy("H%d" % r))
        bpy.ops.mesh.primitive_cube_add()
        said = None
        try:
            bpy.data.scenes.remove(bpy.context.scene)
        except RuntimeError as error:
            said = str(error)
        said = said or mirror()
        internal = said is not None and "could not price" in said
        if heavy:
            built = _built(bpy.data.objects["H%d" % r], s2)
            check("round %d: the window's scene removed, the other holding a cube under an Array of 400,000: "
                  "the window shows it, refused in words, Blender at %s" % (r + 1, format(built, ',')),
                  bpy.context.scene == s2 and said is not None and "stops at" in said and not internal
                  and built < 2_500_000, said)
        else:
            check("round %d: the window's scene removed: the window shows the other, nothing said (%s)"
                  % (r + 1, said), bpy.context.scene == s2 and said is None, said)


def case_window_scene_set():
    """The window given a scene whose depsgraph Blender has evaluated, with an
    object linked to it since: the new object's copy is not made when its
    frame starts, and is priced as new."""
    clear()
    first = bpy.context.scene
    s2 = bpy.data.scenes.new("S2")
    s2.collection.objects.link(bpy.data.objects.new("L", bpy.data.meshes.new("L")))
    with bpy.context.temp_override(scene=s2, view_layer=s2.view_layers[0]):
        bpy.context.evaluated_depsgraph_get()
    s2.collection.objects.link(_heavy("H"))
    bpy.context.window.scene = s2
    said = mirror()
    built = _built(bpy.data.objects["H"], s2)
    check("the window given a scene with a cube under an Array of 400,000 linked since it was evaluated: "
          "refused in words, Blender at %s" % format(built, ','),
          said is not None and "stops at" in said and built < 2_500_000, said)
    bpy.context.window.scene = first


CASES = {name[5:]: f for name, f in globals().items() if name.startswith("case_")}

if CASE == "list":
    print("CASES " + " ".join(CASES))
    sys.exit(0)
print("\nfreed: %s, %d rounds" % (CASE, ROUNDS), flush=True)
CASES[CASE]()
print("SURVIVED %s" % CASE, flush=True)
sys.exit(1 if fail else 0)
