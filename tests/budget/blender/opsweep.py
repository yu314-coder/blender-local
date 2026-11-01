"""The vertex budget's operator sweep (round 4's fix round 2, October 21).

Every operator the Operator Search lists, run with its defaults the way the
search runs it (`_blenderkit_sync.run_operator(path, {})`, then the mirror,
`_blenderkit_sync.sync`), with the app's context and its gate installed, on
a scene of traps where any growth passes the budget — lowered here to
BUDGET so that a trap is cheap to evaluate:

  * A, a cube under an Array fitted to 40 whose offset is the empty O 1 m
    away (328 vertices): an operator that moves O towards A, constrains it,
    re-parents it, snaps it or aligns it multiplies A;
  * S, a plane under Subdivision 6 (4,225): one face more passes the budget;
  * R, a wire circle of 64 vertices under Subdivision 1: an operator that
    fills it, pokes it or merges it makes an N-Gon or a vertex of 64 edges,
    which Subdivision Surface's limit surface takes long on;
  * K, a bevelled curve under an Array of 20 (3,120), and M, a metaball at
    a Resolution of 0.08 (3,900 or so): a spline or an element more passes the budget;
  * the 3D cursor 0.0001 m from A: a snap of O to it multiplies A;
  * N, a cube whose Array Count is keyed 2 at this frame and 2,000 at the
    next and every frame after, and D, a cube whose Count is driven by
    `frame * 1000`: an operator that changes the frame grows them (round 4's
    fix round 2 review: the frame operators, which `screen` holds, were not
    swept, nor animation);
  * W, a 20 × 20 grid under a Bevel limited by Weight at 10 segments: an
    operator that writes Bevel Weights grows it;
  * G, a Grease Pencil object of 1,216 points under a Grease Pencil Array of
    4, and H, a plane with 500 hair strands of 9 points: an operator that
    adds points, strokes or particles grows them — the oracle counts a Grease
    Pencil's points and a particle system's (it counted meshes, curves,
    texts and metaballs alone, so neither could be seen).

Each operator runs from Object Mode with each trap's object active and
selected, and from Edit Mode on S, R, K and M. The oracle is Blender's own:
after the run and the mirror, every object's evaluated count (`to_mesh`, as
the mirror reads it) and, during them, every evaluation's (a
`depsgraph_update_post` handler): an object past BUDGET that was not before
fails, as does a face or a vertex of more than LIMIT_SIDES sides or edges
under a Subdivision Surface that was not there before, and a run past
SLOW seconds.

One line before and one after each run, for the driver (opdrive.py), which
restarts Blender after anything that takes it down and names the operator.

    Blender -b --factory-startup --python opsweep.py -- part=<state> <first index>
"""
import bpy, gpu, sys, types, pathlib, importlib.util, time, os

sys.dont_write_bytecode = True
here = pathlib.Path(__file__).resolve().parent
root = here.parents[2]
site = root / "Resources/python/site"
BUDGET = 5_000
LIMIT_SIDES = 48
SLOW = 30.0


class Bridge(types.ModuleType):
    def __init__(self):
        super().__init__("_blenderkit")

    def is_main_thread(self):
        return True

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules["_blenderkit"] = Bridge()


def load(name):
    spec = importlib.util.spec_from_file_location(name, site / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
context.install(bpy)
for name in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools", "_blenderkit_points",
             "_blenderkit_knife"):
    load(name)
budget = load("_blenderkit_budget")
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
load("_blenderkit_sculpt")
gate = sys.modules["_blenderkit_gate"]
gpu.init()
budget.BUDGET = BUDGET
# The limit surface's time bound lowered with it, so that a 64-gon (0.15 s on
# a desktop Mac by the model) is past it.
budget.SUBDIVISION_SECONDS = 0.05
undo.push(os.path.join(os.environ.get("TMPDIR", "/tmp"), "opsweep-history"), "start")
# The control (`control` among the arguments): the gate switched off and no
# operator priced, as before round 4's fix round — the sweep has to find
# what grows then.
CONTROL = "control" in sys.argv
if CONTROL:
    gate._busy += 1
    context.PRICED_OPERATORS = ()
    context.PRICED_ADDS = ()

# What reaches outside Blender, left out by name as the opsearch sweep leaves
# it out (tests/opsearch/blender/sweep.py, HOST_SIDE_EFFECTS), and refused
# inside this Blender whatever it is (`keep_to_blender`).
HOST_SIDE_EFFECTS = {'wm.url_open', 'wm.url_open_preset', 'wm.path_open', 'wm.save_homefile',
                     'wm.save_userpref', 'wm.read_userpref', 'wm.read_factory_userpref',
                     'wm.app_template_install', 'wm.keyconfig_preset_add', 'wm.interface_theme_preset_add',
                     'wm.interface_theme_preset_remove', 'wm.interface_theme_preset_save',
                     'wm.keyconfig_preset_remove', 'wm.theme_install', 'wm.keyconfig_import',
                     'wm.keyconfig_export', 'wm.owner_enable', 'wm.owner_disable',
                     'wm.doc_view', 'wm.doc_view_manual', 'wm.doc_view_manual_ui_context',
                     'render.play_rendered_anim', 'image.external_edit', 'wm.previews_batch_generate',
                     'wm.previews_batch_clear', 'wm.clear_recent_files', 'wm.operator_presets_cleanup',
                     'wm.sysinfo', 'sound.mixdown', 'wm.save_auto_save'}


def keep_to_blender():
    """As the opsearch sweep: this Blender's settings are its own (the driver
    gives it a HOME), and nothing it runs starts anything outside it."""
    import pwd, subprocess, webbrowser
    mine = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library", "Application Support", "Blender")
    config = os.path.realpath(bpy.utils.user_resource('CONFIG'))
    if config.startswith(os.path.realpath(mine) + os.sep):
        print("REFUSED: this Blender's settings are this Mac's own; run through opdrive.py", flush=True)
        raise SystemExit(2)

    def refuse(*args, **kwargs):
        raise PermissionError("the budget's operator sweep starts nothing outside Blender")

    class NoProcess:
        def __init__(self, *args, **kwargs):
            refuse()

    for name in ('open', 'open_new', 'open_new_tab', 'get', 'register'):
        setattr(webbrowser, name, refuse)
    subprocess.Popen = NoProcess
    for name in ('system', 'popen', 'startfile', 'posix_spawn', 'posix_spawnp', 'fork', 'forkpty',
                 'execv', 'execve', 'execvp', 'execvpe', 'execl', 'execle', 'execlp', 'execlpe',
                 'spawnv', 'spawnve', 'spawnvp', 'spawnvpe', 'spawnl', 'spawnle', 'spawnlp', 'spawnlpe'):
        if hasattr(os, name):
            setattr(os, name, refuse)


keep_to_blender()

# The modules whose operators the search lists that act on the scene's
# objects, meshes, curves, metaballs, armatures and lattices. Left out: the
# interface's own (screen, ui, wm — loading, saving and the rest, which the
# opsearch sweep runs), images, nodes, materials, sound, render (priced, and
# slow), and the file browser.
MODULES = ('object', 'mesh', 'curve', 'curves', 'surface', 'mball', 'transform', 'constraint', 'pose', 'armature',
           'lattice', 'view3d', 'anim', 'collection', 'outliner', 'scene', 'uv', 'paint', 'sculpt', 'ed',
           'geometry', 'particle', 'rigidbody', 'boid', 'dpaint', 'fluid', 'ptcache', 'cloth', 'grease_pencil',
           'font', 'text')
# Of `screen`, the operators that change the frame (the rest of it is the
# interface's own, which the opsearch sweep runs).
FRAME_OPERATORS = ('screen.frame_offset', 'screen.frame_jump', 'screen.keyframe_jump', 'screen.marker_jump',
                   'screen.animation_step')
STATES = ('OBJECT:A', 'OBJECT:O', 'OBJECT:S', 'OBJECT:K', 'OBJECT:M', 'EDIT:S', 'EDIT:R', 'EDIT:K', 'EDIT:M',
          'OBJECT:N', 'OBJECT:W', 'EDIT:W', 'OBJECT:G', 'EDIT:G', 'OBJECT:H')
# Calls with other than their defaults, for what defaults never do: write a
# value (a Bevel Weight of 1), or move with Proportional Editing (A moved
# 1.98 m with a Linear falloff of 2 m moves O, 1 m away, half as far, which
# leaves 0.01 m between them). Each is run in the states named.
EXTRA_CALLS = (
    (('EDIT:W',), 'mesh.attribute_set', {'value_float': 1.0}),
    (('EDIT:W',), 'transform.edge_bevelweight', {'value': 1.0}),
    (('OBJECT:A',), 'transform.translate', {'value': (1.98, 0.0, 0.0), 'use_proportional_edit': True,
                                            'proportional_edit_falloff': 'LINEAR', 'proportional_size': 2.0}),
    (('OBJECT:N', 'OBJECT:A'), 'screen.frame_offset', {'delta': 1}),
    (('OBJECT:N',), 'screen.frame_jump', {'end': True}),
)
# Left out, each with why.
SKIPPED = {
    'ed.undo': "goes back to the step before the sweep's fixture, which is not this run's change",
    'ed.redo': "the same", 'ed.undo_history': "the same", 'ed.undo_redo': "the same",
    'object.quadriflow_remesh': "priced (PRICED_OPERATORS), and runs for minutes on a fixture of this size",
    'mesh.knife_tool': "modal: it waits for the pointer", 'mesh.loopcut': "it needs an edge under the pointer",
    'object.bake': "renders", 'object.bake_image': "renders", 'outliner.orphans_purge': "frees what the next "
    "fixture is built from", 'scene.delete': "takes the fixture's scene", 'object.convert': "measured on its own: "
    "it makes the evaluated mesh the object's, the count Blender holds",
}


def build(state):
    mode, focus = state.split(":")
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        try:
            bpy.ops.object.mode_set(mode='OBJECT')
        except RuntimeError:
            pass
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    for collection in (bpy.data.meshes, bpy.data.curves, bpy.data.metaballs, bpy.data.actions,
                       bpy.data.grease_pencils, bpy.data.particles):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)
    bpy.context.scene.frame_set(1)
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    bpy.ops.object.empty_add(location=(1, 0, 0))
    o = bpy.context.object
    o.name = "O"
    o.constraints.new('LIMIT_ROTATION')
    arr = a.modifiers.new("Array", 'ARRAY')
    arr.use_relative_offset = False
    arr.use_object_offset = True
    arr.offset_object = o
    arr.fit_type = 'FIT_LENGTH'
    arr.fit_length = 40.0
    bpy.ops.mesh.primitive_plane_add(location=(0, 6, 0))
    s = bpy.context.object
    s.name = "S"
    s.modifiers.new("Subdivision", 'SUBSURF').levels = 6
    bpy.ops.mesh.primitive_circle_add(vertices=64, location=(0, -6, 0))
    r = bpy.context.object
    r.name = "R"
    r.modifiers.new("Subdivision", 'SUBSURF').levels = 1
    bpy.ops.curve.primitive_bezier_curve_add(location=(6, 0, 0))
    k = bpy.context.object
    k.name = "K"
    k.data.bevel_depth = 0.05
    k.modifiers.new("Array", 'ARRAY').count = 20
    bpy.ops.object.metaball_add(location=(-6, 0, 0))
    m = bpy.context.object
    m.name = "M"
    m.data.resolution = 0.08
    # The 3D cursor 0.0001 m from A: a snap of O to it multiplies A.
    bpy.context.scene.cursor.location = (0.0001, 0.0, 0.0)
    # N: Count keyed 2 here and 2,000 at every frame after; D: driven by the
    # frame.
    bpy.ops.mesh.primitive_cube_add(location=(0, 12, 0))
    n = bpy.context.object
    n.name = "N"
    keyed = n.modifiers.new("Array", 'ARRAY')
    keyed.count = 2
    keyed.keyframe_insert("count", frame=1)
    keyed.count = 2000
    keyed.keyframe_insert("count", frame=2)
    keyed.count = 2
    bpy.ops.mesh.primitive_cube_add(location=(0, -12, 0))
    d = bpy.context.object
    d.name = "D"
    driven = d.modifiers.new("Array", 'ARRAY').driver_add("count")
    driven.driver.expression = "2 if frame < 1.5 else frame * 1000"
    # W: Bevel Weights grow it.
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=19, y_subdivisions=19, location=(12, 0, 0))
    w = bpy.context.object
    w.name = "W"
    w.data.attributes.active = w.data.attributes.new('bevel_weight_edge', 'FLOAT', 'EDGE')
    bevel = w.modifiers.new("Bevel", 'BEVEL')
    bevel.limit_method, bevel.segments = 'WEIGHT', 10
    # G: a Grease Pencil under a Grease Pencil Array; H: hair.
    bpy.ops.object.grease_pencil_add(type='MONKEY', location=(-12, 0, 0))
    g = bpy.context.object
    g.name = "G"
    g.modifiers.new("Array", 'GREASE_PENCIL_ARRAY').count = 4
    bpy.ops.mesh.primitive_plane_add(location=(12, 12, 0))
    h = bpy.context.object
    h.name = "H"
    hair = h.modifiers.new("Hair", 'PARTICLE_SYSTEM').particle_system.settings
    hair.type, hair.count, hair.display_step = 'HAIR', 500, 3
    bpy.context.view_layer.update()
    target = bpy.data.objects[focus]
    for obj in bpy.context.view_layer.objects:
        obj.select_set(obj == target)
    bpy.context.view_layer.objects.active = target
    if mode == 'EDIT':
        bpy.ops.object.mode_set(mode='EDIT')
        for select in ('mesh', 'curve', 'mball', 'grease_pencil'):
            try:
                getattr(bpy.ops, select).select_all(action='SELECT')
                break
            except (RuntimeError, AttributeError):
                continue
    sync.sync()


def _points(ev):
    """What a Grease Pencil, a Curves or a point cloud holds, and what its
    particle systems do: its points, a hair strand's display points each."""
    n = 0
    if ev.type == 'GREASEPENCIL':
        for layer in ev.data.layers:
            frame = layer.current_frame()
            if frame is not None and frame.drawing is not None:
                position = frame.drawing.attributes.get('position')
                n += len(position.data) if position is not None else 0
    elif ev.type in ('CURVES', 'POINTCLOUD'):
        n += len(ev.data.points)
    for system in getattr(ev, 'particle_systems', ()):
        settings = system.settings
        per = 2 ** settings.display_step + 1 if settings.type == 'HAIR' else 1
        n += (len(system.particles) + len(system.child_particles)) * per
    return n


def everyone():
    found = {}
    # An edited curve's or mesh's edits written back first, then evaluated:
    # read the other way round, a curve in Edit Mode counted 0.
    for obj in bpy.context.view_layer.objects:
        if obj.mode == 'EDIT' and obj.type in ('MESH', 'CURVE', 'SURFACE'):
            obj.update_from_editmode()
    dg = bpy.context.evaluated_depsgraph_get()
    for obj in bpy.context.view_layer.objects:
        ev = obj.evaluated_get(dg)
        count = 0
        if obj.type in ('MESH', 'CURVE', 'SURFACE', 'FONT', 'META'):
            mesh = ev.to_mesh()
            count = len(mesh.vertices) if mesh is not None else 0
            ev.to_mesh_clear()
        try:
            count += _points(ev)
        except (AttributeError, ReferenceError, RuntimeError):
            pass
        found[obj.name] = count
    return found


def topology(obj):
    """(the most sides of a face, the most edges at a vertex) of `obj`'s own
    mesh, where a Subdivision Surface reads it."""
    if obj.type != 'MESH' or not any(m.type == 'SUBSURF' and m.show_viewport for m in obj.modifiers):
        return (0, 0)
    if obj.mode == 'EDIT':
        obj.update_from_editmode()
    mesh = obj.data
    sides = max((len(p.vertices) for p in mesh.polygons), default=0)
    valence = [0] * len(mesh.vertices)
    for e in mesh.edges:
        valence[e.vertices[0]] += 1
        valence[e.vertices[1]] += 1
    return sides, max(valence, default=0)


seen = []


def _watch(scene, depsgraph):
    # Every evaluation during a run: what each mesh object came to.
    if gate.busy():
        return
    try:
        for obj in depsgraph.objects:
            if obj.type == 'MESH' and obj.data is not None:
                seen.append((obj.name, len(obj.data.vertices)))
    except (ReferenceError, RuntimeError):
        pass


bpy.app.handlers.depsgraph_update_post.append(_watch)


def operators():
    names = []
    for module in MODULES:
        group = getattr(bpy.ops, module, None)
        if group is None:
            continue
        names += [module + "." + n for n in dir(group)]
    names += list(FRAME_OPERATORS)
    return sorted(n for n in names if n not in HOST_SIDE_EFFECTS and not n.endswith(('preset_add', 'preset_remove')))


part = [a[5:] for a in sys.argv if a.startswith('part=')]
states = part[0].split(",") if part else STATES
first = int(sys.argv[-1]) if sys.argv[-1].isdigit() else 0
only = [a[5:].split(",") for a in sys.argv if a.startswith('only=')]
index = -1
for state in states:
    calls = [(name, {}) for name in operators()]
    calls += [(name, dict(values)) for where, name, values in EXTRA_CALLS if state in where]
    for name, values in calls:
        if only and name not in only[0]:
            continue
        index += 1
        if index < first:
            continue
        if name in SKIPPED:
            print("S|%d|%s|%s|%s" % (index, state, name, SKIPPED[name]), flush=True)
            continue
        try:
            build(state)
        except Exception as error:                     # noqa: BLE001
            print("S|%d|%s|%s|fixture failed: %s" % (index, state, name, error), flush=True)
            continue
        before = everyone()
        shapes = {o.name: topology(o) for o in bpy.context.view_layer.objects}
        print("B|%d|%s|%s" % (index, state, name + ("(%s)" % ",".join(sorted(values)) if values else "")),
              flush=True)
        seen.clear()
        started = time.time()
        try:
            sync.run_operator(name, dict(values))
            outcome = "ran"
        except Exception as error:                     # noqa: BLE001
            outcome = "refused:" + str(error).replace("\n", " ").replace("|", "/")[:140]
        try:
            sync.sync()
        except RuntimeError as error:
            outcome += " mirror:" + str(error).replace("\n", " ").replace("|", "/")[:140]
        took = time.time() - started
        try:
            after = everyone()
        except Exception:                              # noqa: BLE001
            after = {}
        grown = [(n, c) for n, c in after.items() if c > BUDGET and c > before.get(n, 0)]
        grown += [(n, c) for n, c in seen if c > BUDGET and c > before.get(n, 0)]
        sharp = []
        for obj in bpy.context.view_layer.objects:
            then = shapes.get(obj.name, (0, 0))
            now = topology(obj)
            if (now[0] > LIMIT_SIDES and now[0] > then[0]) or (now[1] > LIMIT_SIDES and now[1] > then[1]):
                sharp.append((obj.name, now))
        verdict = "ok"
        if grown:
            verdict = "GREW:" + ",".join("%s=%d" % g for g in sorted(set(grown))[:4])
        elif sharp:
            verdict = "SHARP:" + ",".join("%s=%s" % s for s in sharp[:4])
        elif took > SLOW:
            verdict = "SLOW:%.1f" % took
        detail = ""
        if os.environ.get("BK_OPSWEEP_DEBUG"):
            detail = "before=%s after=%s" % (before, after)
        print("E|%d|%s|%s|%.2f|%s" % (index, verdict, outcome[:160], took, detail), flush=True)
print("DONE", flush=True)
