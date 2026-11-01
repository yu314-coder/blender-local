"""The vertex budget held to Blender (round 4's fix round, October 20).

scripts/run-budget-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup` and a HOME of its own. The app's context is built the
way the app builds it: its modules from the source tree, Blender's undo
started through `_blenderkit_undo.push`, `gpu.init()`. Rows' strings come from
the Swift (tests/budget/blender/main.swift), as the app sends them.

  1. The model has an entry for every modifier type in Blender's RNA enum.
  2. Completeness: for every type Add Modifier offers on a mesh, a curve, a
     text and a surface (the Swift's catalog), every int, float, enum and bool
     setting of the modifier — and its Object pointers, set to a heavier
     object — is raised (and lowered) step by step on a small fixture; and
     every such setting of the curve's, the surface's and the text's data and
     first spline, on its own, under an Array and under a Remesh. At each
     step the budget's count for the change (`_blenderkit_budget.counted`,
     what `price` judges) is held to Blender's evaluated count. A setting that
     grows Blender's mesh past GROWTH times the fixture's while the budget's
     count stays under it fails, unless it is on ALLOWED with the reason.
     Steps stop once Blender's count passes CAP, an evaluation takes more
     than SLOW seconds, or the budget's count passes the budget (it follows).
     A control runs the sweep on Bevel with today's bypass put back (a Bevel
     counted as making nothing) and has to fail.
  3. The bypasses round 4's reviews measured, through the rows' own lines.
  4. Ordinary edits pass, each counted at or above Blender's count.
  5. Non-finite geometry from a typed value is refused.

Nothing here opens a window, a browser or another app; Blender's own
settings are not read or written.
"""
import bpy, bmesh, gpu, sys, types, json, math, pathlib, importlib.util, contextlib, io, os, time

sys.dont_write_bytecode = True
CALLS, WORK = sys.argv[sys.argv.index("--") + 1:][:2]
CONTROL_ONLY = os.environ.get("BUDGET_CONTROL")  # e.g. "BEVEL": put that bypass back, sweep it
PARTS = set((os.environ.get("BUDGET_PARTS") or "1,2,3,4,5,6,7,8,9,11,12,13").split(","))  # to run some parts alone
ROOT = pathlib.Path(__file__).resolve().parents[3]
HISTORY = os.path.join(WORK, "Documents", ".blender-history")
fail = 0
passed = 0


def check(label, ok, detail=""):
    global fail, passed
    # Flushed: a log that stops mid-part says where Blender is.
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if ok:
        passed += 1
    else:
        fail += 1


# HOST RULE: nothing in this Blender may reach a browser or another process.
import webbrowser, subprocess


def _blocked(*a, **k):
    raise RuntimeError("blocked by the budget check: no browser or subprocess")


webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked
import pwd
_real = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, 'Library', 'Application Support', 'Blender')
if os.path.realpath(bpy.utils.user_resource('CONFIG')).startswith(os.path.realpath(_real)):
    raise SystemExit("refusing to run with Blender's own settings folder")

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[3:].strip()] = body


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
    spec = importlib.util.spec_from_file_location(name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
context.install(bpy)
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools", "_blenderkit_points"):
    load(sibling)
budget = load("_blenderkit_budget")
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
multires = load("_blenderkit_multires")
load("_blenderkit_knife")
sculpt = load("_blenderkit_sculpt")
text = load("_blenderkit_text")
load("_blenderkit_item")
gpu.init()
namespace = {"bpy": bpy}
undo.push(HISTORY, "start")
# The gate every write goes through (_blenderkit_gate.py), installed by
# `context.install` as the app installs it.
gate = sys.modules["_blenderkit_gate"]


class gate_off:
    """The gate switched off, as it was before it existed: the negative
    controls that write bare and let Blender evaluate it."""

    def __enter__(self):
        gate._busy += 1

    def __exit__(self, *exc):
        gate._busy -= 1
        # What the control built is Blender's to keep, as before the gate
        # held what it finds past the budget at the mirror's pass
        # (`hold_unseen`): the next pass takes it as allowed.
        gate._baseline_next = True


def run(source):
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(source, "<swift>", "exec"), namespace)
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return (type(error).__name__ + ": " + str(error)).strip()
    return None


def counts(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        return (len(mesh.vertices), len(mesh.edges), len(mesh.polygons), len(mesh.loops)) if mesh else (0, 0, 0, 0)
    finally:
        evaluated.to_mesh_clear()


def finite(obj):
    import numpy as np
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        if mesh is None or not len(mesh.vertices):
            return True
        co = np.empty(3 * len(mesh.vertices), dtype=np.float32)
        mesh.vertices.foreach_get('co', co)
        return bool(np.isfinite(co).all())
    finally:
        evaluated.to_mesh_clear()


def clear():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    for collection in (bpy.data.meshes, bpy.data.curves, bpy.data.particles):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)
    bpy.context.view_layer.update()


def activate(obj):
    bpy.context.view_layer.update()
    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def fixture(kind, name=None):
    """A small object of `kind`, active."""
    if kind == 'MESH':
        bpy.ops.mesh.primitive_cube_add()
    elif kind == 'CURVE':
        bpy.ops.curve.primitive_bezier_curve_add()
        bpy.context.object.data.bevel_depth = 0.1
        bpy.context.object.data.resolution_u = 4
        bpy.context.object.data.bevel_resolution = 1
    elif kind == 'FONT':
        bpy.ops.object.text_add()
        bpy.context.object.data.body = "Hi"
        bpy.context.object.data.extrude = 0.05
        bpy.context.object.data.resolution_u = 2
    elif kind == 'SURFACE':
        bpy.ops.surface.primitive_nurbs_surface_surface_add()
        bpy.context.object.data.resolution_u = 2
        bpy.context.object.data.resolution_v = 2
    obj = bpy.context.object
    if name:
        obj.name = name
    activate(obj)
    return obj


# Objects the Object pointers are set to: heavier than the fixture, so a
# modifier that takes another object's mesh (an Array's caps, a Boolean's
# operand, a Particle Instance's emitter) shows it.
def helpers():
    bpy.ops.mesh.primitive_uv_sphere_add(location=(0, 6, 0))
    heavy = bpy.context.object
    heavy.name = "Heavy"
    bpy.ops.curve.primitive_bezier_curve_add(location=(0, -6, 0))
    path = bpy.context.object
    path.name = "Path"
    path.scale = (20, 20, 20)
    bpy.ops.mesh.primitive_plane_add(location=(6, 0, 0))
    emitter = bpy.context.object
    emitter.name = "Emitter"
    emitter.modifiers.new("Particles", 'PARTICLE_SYSTEM')
    emitter.particle_systems[0].settings.count = 50
    bpy.ops.object.empty_add(location=(0.5, 0, 0))
    near = bpy.context.object
    near.name = "Near"
    return {"Heavy": heavy, "Path": path, "Emitter": emitter, "Near": near}


# ---------------------------------------------------------------------------
print("\n1. the model has every modifier type")
enum = [i.identifier for i in bpy.types.Modifier.bl_rna.properties['type'].enum_items]
mesh_kinds = [t for t in enum if not t.startswith('GREASE_PENCIL') and t != 'LINEART']
known = budget.growth_kinds()
missing = [t for t in mesh_kinds if t not in known]
check("all %d of Blender's non-Grease Pencil modifier types have a growth entry" % len(mesh_kinds),
      not missing, missing)
saved = budget._GROWTH.pop('BEVEL')
check("control: with Bevel's entry taken out, the same check finds it missing",
      'BEVEL' not in budget.growth_kinds())
budget._GROWTH['BEVEL'] = saved
for kind, why in sorted(budget._UNMODELLED.items()):
    print("        not counted: %s, %s" % (kind, why))

# ---------------------------------------------------------------------------
# The sweep's settings.
GROWTH = 1.5        # Blender's mesh grown this much over the fixture's...
TOL = 1.02          # ...while the budget counts less than Blender's / TOL fails
SLACK = 16          # vertices of noise either way
CAP = 120_000       # a ladder stops once Blender makes this many
SLOW = 3.0          # or an evaluation takes this long (s)
SKIP = {'name', 'show_viewport', 'show_render', 'show_in_editmode', 'show_on_cage', 'show_expanded',
        'is_override_data_editable', 'use_pin_to_last', 'is_active', 'persistent_uid', 'execution_time',
        'use_apply_on_spline', 'debug_options', 'type', 'frame_start', 'frame_end', 'filepath',
        'bake_directory', 'cache_directory', 'is_bound', 'is_baking', 'random_seed', 'time'}
# Settings whose growth the budget does not follow, each with why it is
# allowed. Keys: (object type or '*', kind or data, setting).
ALLOWED = {
}


def ladders(prop, now):
    """Values to step `prop` through from `now`, each list a direction."""
    t = prop.type
    if t == 'BOOLEAN':
        if getattr(prop, 'is_array', False):
            n = prop.array_length
            return [[tuple([True] * n)], [tuple([False] * n)]] + [[tuple(i == j for j in range(n))] for i in range(n)]
        return [[not now]]
    if t == 'ENUM':
        items = [i.identifier for i in prop.enum_items]
        if prop.is_enum_flag:
            return [[{i}] for i in items] + [[set(items)]]
        return [[i] for i in items if i != now]
    lo, hi = prop.hard_min, prop.hard_max
    if t == 'INT':
        if getattr(prop, 'is_array', False):
            return []
        out = []
        for sign in (1, -1):
            seq, v = [], int(now)
            for _ in range(16):
                if sign > 0:
                    v = v + 1 if v < 12 else v * 2
                else:
                    v = v - 1 if v > -12 else v * 2
                v = max(lo, min(hi, v))
                if seq and v == seq[-1]:
                    break
                seq.append(v)
                if v in (lo, hi):
                    break
            if seq:
                out.append(seq)
        return out
    if t == 'FLOAT':
        if getattr(prop, 'is_array', False):
            if prop.array_length not in (2, 3):
                return []
            base = tuple(now)
            if not any(base):
                base = tuple([0.25] * prop.array_length)
            up = [tuple(max(lo, min(hi, c * 4 ** k)) for c in base) for k in range(1, 9)]
            down = [tuple(max(lo, min(hi, c / 4 ** k)) for c in base) for k in range(1, 9)]
            return [up, down]
        out = []
        start = float(now)
        for sign in (1, -1):
            for growing in (True, False):
                seq = []
                v = abs(start) if start else 0.25
                for k in range(10):
                    v = v * 4 if growing else v / 4
                    value = max(lo, min(hi, sign * v))
                    if seq and value == seq[-1]:
                        break
                    seq.append(value)
                if seq:
                    out.append(seq)
        return out
    return []


def sweepable(struct):
    for prop in struct.bl_rna.properties:
        if prop.identifier in SKIP or prop.is_readonly or prop.identifier.startswith('show_'):
            continue
        if prop.type in ('BOOLEAN', 'INT', 'FLOAT', 'ENUM'):
            yield prop


def counted_all(changes):
    return budget.counted_all(changes)


def blender_count(obj):
    t = time.time()
    n = counts(obj)[0]
    return n, time.time() - t


def _switches(struct, props):
    """(the setting, the values it can be switched to) for each enum and bool:
    a growth can hide behind another setting (round 4's review: an Array's
    Fit Length counts only once Fit Type is Fit Length)."""
    for prop in props:
        try:
            now = getattr(struct, prop.identifier)
        except AttributeError:
            continue
        if prop.type == 'ENUM' and not prop.is_enum_flag:
            yield prop, [i.identifier for i in prop.enum_items if i.identifier != now]
        elif prop.type == 'BOOLEAN' and not getattr(prop, 'is_array', False):
            yield prop, [not now]
        elif prop.type == 'BOOLEAN':
            yield prop, [tuple([True] * prop.array_length)]


# A row sends a viewport setting with its render twin (the Subdivision row's
# Levels Viewport and Render together): round 4's fix-round review found the
# pair priced as a render only, which no single-key step could show. Each
# twin is also stepped with its pair, as the row sends it (`counted_all`).
TWINS = {'levels': 'render_levels', 'steps': 'render_steps', 'viewport_resolution': 'resolution',
         'resolution_u': 'render_resolution_u', 'resolution_v': 'render_resolution_v'}
# The settings of another object a modifier reads that place it, stepped on
# the helper it is pointed at (round 4's fix-round review: a Hook's empty
# scaled, an offset object's parent moved, a Fit Curve's Delta Scale).
PLACES = ('location', 'scale', 'rotation_euler', 'delta_location', 'delta_scale')
TWINNED_KINDS = ('SUBSURF', 'SCREW', 'OCEAN')


def sweep_struct(label, struct, obj, extra=(), allowed_key=None, pairs=True, only=None):
    """Steps every setting of `struct` (or those named in `only`), alone and
    then with each enum and bool switched; returns (the failures, how many
    steps)."""
    failures = []
    steps = [0]
    base, _ = blender_count(obj)
    props = [p for p in sweepable(struct) if only is None or p.identifier in only]

    def ladder_all(selection, held):
        for prop in selection:
            key = prop.identifier if hasattr(prop, 'identifier') else prop[0]
            if hasattr(prop, 'identifier'):
                try:
                    original = getattr(struct, key)
                except AttributeError:
                    continue
                if hasattr(original, '__len__') and not isinstance(original, str):
                    original = tuple(original) if not isinstance(original, set) else set(original)
                values = ladders(prop, original)
            else:
                original = getattr(struct, key)
                values = [[prop[1]]]
            twin = TWINS.get(key) if hasattr(prop, 'identifier') and hasattr(struct, TWINS.get(key, '')) else None
            twinned = twin is not None and held == "with its render twin: "
            for ladder in values:
                for value in ladder:
                    try:
                        if twinned:
                            model = counted_all([(struct, key, value), (struct, twin, value)]).get(obj.name)
                        else:
                            model = budget.counted(struct, key, value).get(obj.name)
                    except Exception as error:  # noqa: BLE001
                        # The price raises what Blender's own assignment raises (a
                        # read-only texture space, a 3D fill mode on a text): fine.
                        try:
                            setattr(struct, key, value)
                        except (TypeError, ValueError, AttributeError, RuntimeError):
                            break
                        failures.append((label, key, value, "%sthe budget raised where Blender took it: %s"
                                         % (held, error)))
                        break
                    if model is None:
                        model = 0
                    if model > budget.BUDGET:
                        break  # the budget refuses it: it follows
                    try:
                        setattr(struct, key, value)
                        if twinned:
                            setattr(struct, twin, value)
                    except (TypeError, ValueError, AttributeError, RuntimeError):
                        continue
                    n, took = blender_count(obj)
                    steps[0] += 1
                    grown = n >= GROWTH * max(base, 1) and n - base > SLACK
                    if grown and n > model * TOL + SLACK:
                        why = ALLOWED.get((obj.type, allowed_key or label, key)) or \
                            ALLOWED.get(('*', allowed_key or label, key))
                        if why is None:
                            failures.append((label, key, value, "%sBlender %d, the budget %d (fixture %d)"
                                             % (held, n, model, base)))
                        break
                    if n > CAP or took > SLOW:
                        break
                try:
                    setattr(struct, key, original)
                    if twinned:
                        setattr(struct, twin, twin_original)
                except (TypeError, ValueError, AttributeError, RuntimeError):
                    pass

    ladder_all(props + list(extra), "")
    twins = [p for p in props if p.identifier in TWINS and hasattr(struct, TWINS[p.identifier])]
    for prop in twins:
        twin_original = getattr(struct, TWINS[prop.identifier])
        ladder_all([prop], "with its render twin: ")
    if pairs:
        numeric = [p for p in props if p.type in ('INT', 'FLOAT')] + list(extra)
        for switch, alternatives in list(_switches(struct, props)):
            original = getattr(struct, switch.identifier)
            if hasattr(original, '__len__') and not isinstance(original, str):
                original = tuple(original)
            for alternative in alternatives:
                try:
                    setattr(struct, switch.identifier, alternative)
                except (TypeError, ValueError, AttributeError, RuntimeError):
                    continue
                if blender_count(obj)[1] > SLOW:
                    continue
                ladder_all([p for p in numeric if p is not switch], "with %s=%r: " % (switch.identifier, alternative))
            try:
                setattr(struct, switch.identifier, original)
            except (TypeError, ValueError, AttributeError, RuntimeError):
                pass
    return failures, steps[0]


def sweep_kind(otype, kind, refs):
    obj = fixture(otype, "Fixture")
    if kind in TWINNED_KINDS:
        # A modifier hidden from renders before it: a viewport setting priced
        # as a render (round 4's fix-round review) leaves it out.
        hidden = obj.modifiers.new("Hidden from renders", 'ARRAY')
        hidden.count = 3
        hidden.show_render = False
    source = blocks.get("ADD %s %s" % (otype, kind))
    said = run(source) if source else None
    if said is not None or not obj.modifiers or obj.modifiers[-1].type != kind:
        return None, said or "nothing added", 0
    modifier = obj.modifiers[-1]
    if kind == 'EXPLODE':
        # Explode takes its pieces from a particle system on the same mesh.
        obj.modifiers.new("Particles", 'PARTICLE_SYSTEM')
        obj.particle_systems[0].settings.count = 20
        bpy.ops.object.modifier_move_to_index(modifier=modifier.name, index=len(obj.modifiers) - 1)
    pointers = []
    for prop in modifier.bl_rna.properties:
        if prop.type == 'POINTER' and not prop.is_readonly and getattr(prop.fixed_type, 'identifier', '') == 'Object':
            for helper in refs.values():
                pointers.append((prop.identifier, helper))
    failures, steps = sweep_struct(kind, modifier, obj, extra=pointers)
    # Where another object it reads is: each Object pointer set to the empty
    # helper, whose place is stepped.
    for prop in modifier.bl_rna.properties:
        if prop.type == 'POINTER' and not prop.is_readonly and getattr(prop.fixed_type, 'identifier', '') == 'Object':
            near = refs["Near"]
            kept_pointer = getattr(modifier, prop.identifier)
            try:
                setattr(modifier, prop.identifier, near)
            except (TypeError, ValueError, AttributeError, RuntimeError):
                continue
            more, n = sweep_struct("%s's %s, moved" % (kind, prop.identifier), near, obj, allowed_key=kind,
                                   pairs=False, only=PLACES)
            failures += more
            steps += n
            try:
                setattr(modifier, prop.identifier, kept_pointer)
            except (TypeError, ValueError, AttributeError, RuntimeError):
                pass
    # A Fluid domain's own settings are a struct of their own (round 4's
    # fix-round review: Domain ▸ Liquid ▸ Mesh replaced the mesh unseen).
    if kind == 'FLUID':
        modifier.fluid_type = 'DOMAIN'
        domain = modifier.domain_settings
        domain.cache_directory = os.path.join(WORK, "sweep-fluid")
        domain.cache_type = 'REPLAY'
        for kind_of, mesh_on in (('GAS', False), ('LIQUID', True)):
            domain.domain_type = kind_of
            if kind_of == 'LIQUID':
                domain.use_mesh = mesh_on
            more, n = sweep_struct("FLUID %s domain" % kind_of, domain, obj, allowed_key=kind, pairs=False)
            failures += more
            steps += n
        modifier.fluid_type = 'NONE'
    # A Particle Instance's count is its emitter's particles.
    if kind == 'PARTICLE_INSTANCE':
        modifier.object = refs["Emitter"]
        settings = refs["Emitter"].particle_systems[0].settings
        more, n = sweep_struct("PARTICLE_INSTANCE particles", settings, obj, allowed_key=kind)
        failures += more
        steps += n
        modifier.object = None
    bpy.data.objects.remove(obj)
    return failures, None, steps


def sweep(kinds_by_type, refs, label):
    total_failures, total_steps = [], 0
    started = time.time()
    for otype, kinds in kinds_by_type.items():
        for kind in kinds:
            if kind in budget._UNMODELLED:
                continue
            failures, said, steps = sweep_kind(otype, kind, refs)
            total_steps += steps
            if failures is None:
                print("        %s %s not added: %s" % (otype, kind, said))
                continue
            for f in failures:
                total_failures.append((otype,) + f)
    print("        %s: %d steps in %.1f s" % (label, total_steps, time.time() - started))
    return total_failures


catalog = {}
KINDS = set(filter(None, (os.environ.get("BUDGET_KINDS") or "").split(",")))  # to sweep some kinds alone
for otype in ("MESH", "CURVE", "FONT", "SURFACE"):
    catalog[otype] = [line for line in blocks["CATALOG " + otype].splitlines()
                      if line.strip() and (not KINDS or line.strip() in KINDS)]

clear()
refs = helpers()
if CONTROL_ONLY:
    print("\nthe control alone: %s counted as making nothing" % CONTROL_ONLY)
    budget._GROWTH[CONTROL_ONLY] = budget._keep
    found = sweep({"MESH": [CONTROL_ONLY]}, refs, "control")
    for f in found:
        print("        found: %s %s %s=%r: %s" % f)
    check("the sweep fails with %s's growth taken out" % CONTROL_ONLY, bool(found), "nothing found")
    print("\n%d passed, %d failed" % (passed, fail))
    sys.exit(1 if fail else 0)

print("\n2. completeness: every setting of every Add Modifier row, on four object types")
found = sweep(catalog, refs, "the rows") if "2" in PARTS else []
for f in found:
    print("        missed: %s %s %s=%r: %s" % f)
check("no setting of any row grows Blender's mesh past the budget's count", not found,
      "%d settings" % len(found))

print("\n   the control: a row's setting and its render twin priced as a render, the fix-round review's bypass")


def counted_as_render(changes):
    """The old price: any render key made the whole change a render's."""
    s = budget.Prices(render=budget._renders(changes))
    try:
        for o, k, v in changes:
            s.change(o, k, v)
            if isinstance(o, bpy.types.Modifier):
                s.shown.add(budget._pointer(o))
        return {o.name: budget._final(o, s).final.v for o in budget.affected([o for o, k, v in changes], s)}
    finally:
        s.close()


kept_counted_all = counted_all
counted_all = counted_as_render
control = sweep({"MESH": ['SUBSURF']}, refs, "control")
counted_all = kept_counted_all
check("the sweep fails with the render twin priced as a render (%d settings: %s)"
      % (len(control), sorted(set("%s=%r" % (f[2], f[3]) for f in control))[:4]),
      any(f[2] == 'levels' for f in control), control[:3])

print("\n   the control: a Bevel counted as making nothing, round 4's bypass")
saved = budget._GROWTH['BEVEL']
budget._GROWTH['BEVEL'] = budget._keep
control = sweep({"MESH": ['BEVEL']}, refs, "control")
budget._GROWTH['BEVEL'] = saved
check("control: with it, the sweep fails on Bevel's Segments",
      any(f[2] == 'segments' for f in control), control)

print("\n   the control: an Array fitted to a length counted as one copy, round 4's bypass")
saved = budget._GROWTH['ARRAY']


def _one_copy_when_fitted(x, c):
    if x.get('fit_type') != 'FIXED_COUNT':
        return c
    return saved(x, c)


budget._GROWTH['ARRAY'] = _one_copy_when_fitted
control = sweep({"MESH": ['ARRAY']}, refs, "control")
budget._GROWTH['ARRAY'] = saved
check("control: with it, the sweep fails on Fit Length once Fit Type is Fit Length",
      any(f[2] == 'fit_length' and 'FIT_LENGTH' in f[4] for f in control), control)

print("\n   curve, surface and text data, and their first spline")


def data_sweep(otype, downstream):
    obj = fixture(otype, "Data")
    if downstream == 'ARRAY':
        a = obj.modifiers.new("Array", 'ARRAY')
        a.count = 3
    elif downstream == 'REMESH':
        r = obj.modifiers.new("Remesh", 'REMESH')
        r.voxel_size = 0.2
    failures, steps = sweep_struct("%s data" % otype, obj.data, obj, allowed_key="data")
    if obj.data.splines:
        more, n = sweep_struct("%s spline" % otype, obj.data.splines[0], obj, allowed_key="spline")
        failures += more
        steps += n
    bpy.data.objects.remove(obj)
    return failures, steps


data_found = []
started = time.time()
total = 0
for otype in (("CURVE", "SURFACE", "FONT") if "2" in PARTS or "2d" in PARTS else ()):
    for downstream in (None, 'ARRAY', 'REMESH'):
        failures, steps = data_sweep(otype, downstream)
        total += steps
        data_found += [(otype, downstream) + f for f in failures]
print("        %d steps in %.1f s" % (total, time.time() - started))
for f in data_found:
    print("        missed: %s under %s: %s %s=%r: %s" % f)
check("no curve, surface or text data setting grows Blender's mesh past the budget's count",
      not data_found, "%d settings" % len(data_found))

# ---------------------------------------------------------------------------
print("\n3. round 4's bypasses, through the rows' own lines")
clear()


def cubes(n):
    mesh = bpy.data.meshes.new("Cubes")
    bm = bmesh.new()
    for i in range(n):
        made = bmesh.ops.create_cube(bm, size=1.0)
        bmesh.ops.translate(bm, verts=made['verts'], vec=((i % 8) * 2.0, (i // 8) * 2.0, 0))
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Cubes", mesh)
    bpy.context.scene.collection.objects.link(obj)
    activate(obj)
    return obj


obj = cubes(64)
check("Add Modifier ▸ Bevel on 64 cubes", run(blocks["ADD MESH BEVEL"]) is None)
said = run(blocks["ROW bevel segments 12"])
check("Bevel Segments 12 passes with the row's line", said is None, said)
check("and is counted at or above Blender's %d (%d)" % (counts(obj)[0], multires.stack_vertices(obj)),
      multires.stack_vertices(obj) >= counts(obj)[0])
check("Add Modifier ▸ Subdivision Surface below it passes", run(blocks["ADD MESH SUBSURF"]) is None)
said = run(blocks["ROW subdivision level 2"])
check("Subdivision level 2 passes (Blender %d, counted %d)" % (counts(obj)[0], multires.stack_vertices(obj)),
      said is None and multires.stack_vertices(obj) >= counts(obj)[0], said)
said = run(blocks["ROW subdivision level 3"])
check("level 3 is refused (Blender would make about 4.15 million)", said is not None and "2,500,000" in said, said)
check("and Blender keeps level 2", obj.modifiers["Subdivision"].levels == 2)
# The control: the row's lines with the price left out run.
bare = "\n".join(line for line in blocks["ROW subdivision level 3"].splitlines() if "_blenderkit_budget" not in line)
check("control: the same lines without the price set level 3",
      run(bare) is None and obj.modifiers["Subdivision"].levels == 3)
obj.modifiers["Subdivision"].levels = 2

clear()
bpy.ops.curve.primitive_bezier_curve_add()
curve = bpy.context.object
curve.name = "Curve"
activate(curve)
for i in range(2):
    run(blocks["ADD CURVE ARRAY"])
    run("bpy.context.object.modifiers[-1].count = 64")
check("a Bézier curve with two Arrays at 64 (%d)" % counts(curve)[0], counts(curve)[0] == 53_248)
said = [run(blocks[k]) for k in ("DATA bevel_depth=0.05", "DATA bevel_resolution=32", "DATA resolution_u=64")]
check("the curve Data tab's Depth passes, then Bevel Resolution 32 is refused", said[0] is None and said[1] is not None
      and "2,500,000" in said[1], said)
check("and Resolution Preview U 64 is refused too", said[2] is not None and "2,500,000" in said[2], said[2])
check("Blender holds %d, inside the budget" % counts(curve)[0], counts(curve)[0] <= budget.BUDGET)
check("control: the Data tab's line without its price sets Bevel Resolution 32",
      run(blocks["DATA bevel_resolution=32"].splitlines()[-1]) is None and curve.data.bevel_resolution == 32)
curve.data.bevel_resolution = 4
curve.data.bevel_depth = 0.0

clear()
bpy.ops.surface.primitive_nurbs_surface_sphere_add()
sphere = bpy.context.object
activate(sphere)
sphere.modifiers.new("Array", 'ARRAY').count = 64
try:
    sync.set_property('bpy.data.objects["%s"].data' % sphere.name, 'resolution_u', 64)
    sync.set_property('bpy.data.objects["%s"].data' % sphere.name, 'resolution_v', 64)
    said = None
except RuntimeError as error:
    said = str(error)
check("a NURBS sphere under an Array at 64: the Data API row's Resolution U and V of 64 is refused "
      "(Blender: 10,485,760)", said is not None and "10,485,760" in said, said)
try:
    sync.set_property('bpy.data.objects["%s"].data.splines[0]' % sphere.name, 'resolution_v', 64)
    said = None
except RuntimeError as error:
    said = str(error)
check("and the same through its spline's own Resolution V", said is not None and "2,500,000" in said, said)

clear()
bpy.ops.object.text_add()
txt = bpy.context.object
txt.name = "Text"
txt.data.body = "Hello"
activate(txt)
remesh = txt.modifiers.new("Remesh", 'REMESH')
remesh.voxel_size = 0.1
for size, blender_says in ((1.0, 248), (4.0, 2226), (16.0, 27622)):
    said = run(blocks["TEXT size=%s" % size])
    n = counts(txt)[0]
    check("Remesh at 0.1 on 'Hello', Size %g with the Data tab's line: counted %d, Blender %d (review: %d)"
          % (size, multires.stack_vertices(txt), n, blender_says),
          said is None and multires.stack_vertices(txt) >= n, said)
said = run(blocks["TEXT size=1000.0"])
check("Size 1,000 is refused", said is not None and "2,500,000" in said, said)
check("control: Size 1,000 written bare would make %s vertices (worked out from Size 16, not built)"
      % format(int(counts(txt)[0] * (1000 / 16.0) ** 2), ','), counts(txt)[0] * (1000 / 16.0) ** 2 > budget.BUDGET)

clear()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
activate(cube)
cube.modifiers.new("Array", 'ARRAY')
path = 'bpy.data.objects["Cube"].modifiers["Array"]'
sync.set_property(path, 'fit_type', 'FIT_LENGTH')
sync.set_property(path, 'fit_length', 2000.0)
check("Array Fit Length 2,000 through the Data API row is counted as Blender makes it (%d, review: 8,008)"
      % counts(cube)[0], multires.stack_vertices(cube) == counts(cube)[0] == 8008)
try:
    sync.set_property(path, 'fit_length', 2e6)
    said = None
except RuntimeError as error:
    said = str(error)
check("Fit Length 2,000,000 is refused (8,000,016)", said is not None and "8,000,016" in said, said)
sync.set_property(path, 'fit_length', 2.0)
cube.modifiers["Array"].use_relative_offset = False
cube.modifiers["Array"].use_object_offset = True
bpy.ops.object.empty_add(location=(0.001, 0, 0))
near = bpy.context.object
activate(cube)
cube.modifiers["Array"].offset_object = near
try:
    sync.set_property(path, 'fit_length', 1000.0)
    said = None
except RuntimeError as error:
    said = str(error)
check("Fit Length 1,000 with an Object offset 1 mm away is refused (1,000,001 copies)",
      said is not None and "8,000,008" in said, said)
cube.modifiers["Array"].fit_length = 30.0
try:
    sync.set_property('bpy.data.objects["%s"]' % near.name, 'location', (1e-5, 0.0, 0.0))
    said = None
except RuntimeError as error:
    said = str(error)
check("at 30 m, moving that object to 0.01 mm through the Data API row is refused (3,000,001 copies)",
      said is not None and "2,500,000" in said, said)
cube.modifiers["Array"].fit_type = 'FIT_CURVE'
bpy.ops.curve.primitive_bezier_curve_add(location=(0, 4, 0))
guide = bpy.context.object
activate(cube)
cube.modifiers["Array"].use_object_offset = False
cube.modifiers["Array"].use_constant_offset = True
cube.modifiers["Array"].constant_offset_displace = (0.001, 0, 0)
try:
    sync.set_property(path, 'curve', 'bpy.data.objects["%s"]' % guide.name)
    said = None
except RuntimeError as error:
    said = str(error)
check("Fit Curve along a 2.08 m curve at a 1 mm offset passes (2,082 copies of the cube)", said is None, said)
bpy.context.view_layer.update()
check("Fit Curve is counted at or above Blender's %d (%d)" % (counts(cube)[0], multires.stack_vertices(cube)),
      multires.stack_vertices(cube) >= counts(cube)[0])
try:
    sync.set_property('bpy.data.objects["%s"]' % guide.name, 'scale', (1000.0, 1000.0, 1000.0))
    said = None
except RuntimeError as error:
    said = str(error)
check("scaling the curve by 1,000 is refused (the copies follow its length)",
      said is not None and "2,500,000" in said, said)

clear()
bpy.ops.object.text_add()
txt = bpy.context.object
txt.name = "Text"
txt.data.body = "*" * 50
txt.data.resolution_u = 3
activate(txt)
txt.modifiers.new("Array", 'ARRAY').count = 64
said = run(blocks["TEXT offset=10.0"])
check("50 '*' under an Array at 64: Offset 10 with the Data tab's line is priced (counted %d, Blender %d; "
      "review: 761,600)" % (multires.stack_vertices(txt), counts(txt)[0]),
      said is None and multires.stack_vertices(txt) >= counts(txt)[0], said)
txt.data.offset = 0.0
txt.modifiers["Array"].count = 300
said = run(blocks["TEXT offset=10.0"])
check("and under 300 copies (990,000 vertices) Offset 10 is refused", said is not None and "2,500,000" in said, said)

# A text's Bevel Object is a curve of its own, whose Data tab grows the text
# (round 4's review: a text bevelled by a Bézier circle went from 1,008,000 to
# 5,376,000 vertices when the circle's Resolution Preview U went from 12 to
# 64). Measured here: 'Hello' bevelled by a circle is 10,320 at 12 and 55,040
# at 64.
clear()
bpy.ops.curve.primitive_bezier_circle_add(radius=0.02, location=(0, 5, 0))
circle = bpy.context.object
circle.name = "Curve"
bpy.ops.object.text_add()
txt = bpy.context.object
txt.name = "Text"
txt.data.body = "Hello"
txt.data.bevel_mode = 'OBJECT'
txt.data.bevel_object = circle
txt.modifiers.new("Array", 'ARRAY').count = 100
activate(circle)
check("'Hello' bevelled by a circle under an Array of 100 (%s)" % format(counts(txt)[0], ','),
      counts(txt)[0] == 1_032_000)
said = run(blocks["DATA resolution_u=64"])
check("the circle's Resolution Preview U 64 on its own Data tab is refused for the text it bevels",
      said is not None and "Text 5,504,000" in said and circle.data.resolution_u == 12, said)
said = run(blocks["DATA resolution_u=4"])
check("and lowering it passes (%s)" % format(counts(txt)[0], ','), said is None and circle.data.resolution_u == 4, said)

clear()
bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10)
grid = bpy.context.object
activate(grid)
run(blocks["ADD MESH MIRROR"])
grid.modifiers[-1].name = "Mirror"
grid.modifiers["Mirror"].use_mirror_merge = False
check("Skin added on a 10 x 10 grid under Mirror X (199 loops)", run(blocks["ADD MESH SKIN"]) is None)
said = run(blocks["ROW mirror xyz"])
check("the Mirror row's X Y Z is refused (793 loops; Blender's Skin took 10.9 s)",
      said is not None and "793" in said, said)
check("and Blender keeps X alone", tuple(grid.modifiers["Mirror"].use_axis) == (True, False, False))
said = run(blocks["ROW mirror xy"])
check("X Y passes (397 loops)", said is None, said)

clear()
bpy.ops.mesh.primitive_uv_sphere_add()
ball = bpy.context.object
activate(ball)
run(blocks["ADD MESH SCREW"])
ball.modifiers[-1].name = "Screw"
said = run(blocks["ROW screw angle"])
check("a Screw row's Angle edit is priced too (it passes)", said is None and "_blenderkit_budget" in blocks["ROW screw angle"], said)

# ---------------------------------------------------------------------------
print("\n4. ordinary edits pass, each counted at or above Blender's count")
clear()


def ordinary(label, build, source=None):
    obj = build()
    said = run(source) if source else None
    n = counts(obj)[0]
    model = multires.stack_vertices(obj)
    t = time.time()
    try:
        budget.price(obj, 'location', tuple(obj.location))
        priced = None
    except RuntimeError as error:
        priced = str(error)
    took = time.time() - t
    check("%s: passes, counted %s against Blender's %s (priced in %.0f ms)"
          % (label, format(model, ','), format(n, ','), took * 1000),
          said is None and priced is None and model >= n, said or priced)
    bpy.data.objects.remove(obj)


def build_suzanne_subsurf():
    bpy.ops.mesh.primitive_monkey_add()
    obj = bpy.context.object
    activate(obj)
    obj.modifiers.new("Subdivision", 'SUBSURF').levels = 2
    return obj


def build_bevel_dense():
    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64)
    obj = bpy.context.object
    activate(obj)
    b = obj.modifiers.new("Bevel", 'BEVEL')
    b.segments = 4
    return obj


def build_text():
    bpy.ops.object.text_add()
    obj = bpy.context.object
    obj.data.body = "Blender Local"
    obj.data.extrude = 0.1
    obj.data.bevel_depth = 0.02
    obj.data.bevel_resolution = 4
    obj.data.resolution_u = 12
    activate(obj)
    return obj


def build_curve():
    bpy.ops.curve.primitive_bezier_circle_add()
    obj = bpy.context.object
    obj.data.bevel_depth = 0.1
    obj.data.bevel_resolution = 6
    obj.data.resolution_u = 24
    activate(obj)
    obj.modifiers.new("Array", 'ARRAY').count = 20
    return obj


def build_remesh():
    bpy.ops.mesh.primitive_cube_add()
    obj = bpy.context.object
    activate(obj)
    obj.modifiers.new("Remesh", 'REMESH').voxel_size = 0.02
    return obj


def build_mirror_subsurf():
    bpy.ops.mesh.primitive_monkey_add()
    obj = bpy.context.object
    activate(obj)
    m = obj.modifiers.new("Mirror", 'MIRROR')
    m.use_axis = (True, True, True)
    obj.modifiers.new("Subdivision", 'SUBSURF').levels = 2
    return obj


def build_surface():
    bpy.ops.surface.primitive_nurbs_surface_torus_add()
    obj = bpy.context.object
    obj.data.resolution_u = 16
    obj.data.resolution_v = 16
    activate(obj)
    return obj


def build_array_bevel_subsurf():
    bpy.ops.mesh.primitive_cube_add()
    obj = bpy.context.object
    activate(obj)
    obj.modifiers.new("Bevel", 'BEVEL').segments = 3
    obj.modifiers.new("Array", 'ARRAY').count = 10
    obj.modifiers.new("Subdivision", 'SUBSURF').levels = 2
    return obj


ordinary("Suzanne at Subdivision level 2", build_suzanne_subsurf)
ordinary("a 128 x 64 UV sphere with Bevel at 4 segments (Angle limit)", build_bevel_dense)
ordinary("'Blender Local' with Extrude, a Bevel at 4 and Resolution U 12", build_text)
ordinary("a bevelled Bézier circle at Resolution U 24 under an Array of 20", build_curve)
ordinary("a 2 m cube under a Remesh at a 0.02 voxel", build_remesh)
ordinary("Suzanne mirrored on X Y Z, then Subdivision level 2", build_mirror_subsurf)
ordinary("a NURBS torus at Resolution 16 x 16", build_surface)
ordinary("a cube: Bevel 3, Array 10, Subdivision 2", build_array_bevel_subsurf)

# ---------------------------------------------------------------------------
print("\n5. a typed value that would give Blender non-finite geometry")
clear()
bpy.ops.object.text_add()
txt = bpy.context.object
txt.name = "Text"
txt.data.body = "Hello"
activate(txt)
for key in ("offset=3.4e+38", "bevel_depth=3.4e+38"):
    said = run(blocks["TEXT " + key])
    check("the text Data tab's %s is refused in words" % key.replace("=", " "), said is not None and "finite" in said, said)
    check("and Blender's text stays finite", finite(txt))
with gate_off():
    txt.data.offset = 3.4e38
    check("control: set bare, Offset 3.4e38 gives Blender non-finite vertices", not finite(txt))
    txt.data.offset = 0.0
said = run(blocks["TEXT offset_x=3.4e+38"])
check("Offset X 3.4e38 moves the text only and stays finite, so it passes", said is None and finite(txt), said)

# ---------------------------------------------------------------------------
print("\n6. the measures Remesh is counted from, one implementation for the modifier and the Sculpt header")


def python_walk(mesh):
    """The pure-Python walk `_blenderkit_sculpt.remesh_measures` was before
    this round, kept here as the reference: polygon areas, then the same
    curvature and pieces."""
    from array import array
    faces = len(mesh.polygons)
    if not faces:
        return 0.0, 0.0, 0
    areas = array('f', [0.0]) * faces
    mesh.polygons.foreach_get('area', areas)
    normals = array('f', [0.0]) * (3 * faces)
    mesh.polygons.foreach_get('normal', normals)
    starts = array('i', [0]) * faces
    mesh.polygons.foreach_get('loop_start', starts)
    totals = array('i', [0]) * faces
    mesh.polygons.foreach_get('loop_total', totals)
    corners = len(mesh.loops)
    corner_edges = array('i', [0]) * corners
    mesh.loops.foreach_get('edge_index', corner_edges)
    corner_verts = array('i', [0]) * corners
    mesh.loops.foreach_get('vertex_index', corner_verts)
    edges = len(mesh.edges)
    ends = array('i', [0]) * (2 * edges)
    mesh.edges.foreach_get('vertices', ends)
    co = array('f', [0.0]) * (3 * len(mesh.vertices))
    mesh.vertices.foreach_get('co', co)
    first = array('i', [-1]) * edges
    second = array('i', [-1]) * edges
    uses = array('i', [0]) * edges
    for f in range(faces):
        for c in range(starts[f], starts[f] + totals[f]):
            e = corner_edges[c]
            if uses[e] == 0:
                first[e] = f
            elif uses[e] == 1:
                second[e] = f
            uses[e] += 1
    parent = list(range(len(mesh.vertices)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    curvature = 0.0
    open_vertices = []
    for e in range(edges):
        a, b = ends[2 * e], ends[2 * e + 1]
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
        n = uses[e]
        if n == 0:
            continue
        length = math.dist(co[3 * a:3 * a + 3], co[3 * b:3 * b + 3])
        if n == 2:
            f, g = first[e], second[e]
            dot = (normals[3 * f] * normals[3 * g] + normals[3 * f + 1] * normals[3 * g + 1]
                   + normals[3 * f + 2] * normals[3 * g + 2])
            curvature += length * math.acos(max(-1.0, min(1.0, dot))) / 2.0
        else:
            curvature += length * math.pi / 2.0
            if n == 1:
                open_vertices.append(a)
    piece_area = {}
    for f in range(faces):
        root = find(corner_verts[starts[f]])
        piece_area[root] = piece_area.get(root, 0.0) + areas[f]
    opened = {find(v) for v in open_vertices}
    area = sum(value * (2.0 if root in opened else 1.0) for root, value in piece_area.items())
    return area, curvature, len(piece_area)


clear()
shapes = []
bpy.ops.mesh.primitive_cube_add(); shapes.append(bpy.context.object)
bpy.ops.mesh.primitive_uv_sphere_add(); shapes.append(bpy.context.object)
bpy.ops.mesh.primitive_monkey_add(); shapes.append(bpy.context.object)
bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10); shapes.append(bpy.context.object)
speck_mesh = bpy.data.meshes.new("Specks")
bm = bmesh.new()
for i in range(200):
    made = bmesh.ops.create_cube(bm, size=0.004)
    bmesh.ops.translate(bm, verts=made['verts'], vec=((i % 20) * 0.1, (i // 20) * 0.1, 0))
bm.to_mesh(speck_mesh)
bm.free()
specks = bpy.data.objects.new("Specks", speck_mesh)
bpy.context.scene.collection.objects.link(specks)
shapes.append(specks)
for shape in shapes:
    want = python_walk(shape.data)
    got = budget.Measures(shape.data).remesh()
    # The curvature and the pieces exactly; the area as the triangles have it,
    # which is the polygons' own on a planar face and more on a bent one
    # (Suzanne's quads: 1.3%).
    same = want[0] * (1 - 1e-5) <= got[0] <= want[0] * 1.02 + 1e-6 \
        and abs(got[1] - want[1]) <= 1e-4 * max(1.0, want[1]) and got[2] == want[2]
    check("%s: the numpy measures are the Python walk's (%s; the walk's area %.4f)"
          % (shape.name, tuple(round(x, 4) for x in got), want[0]), same, "numpy %s, walk %s" % (got, want))
check("the Sculpt header's estimate reads the same measures",
      sculpt.remesh_measures(shapes[2].data) == budget.Measures(shapes[2].data).remesh())
bpy.ops.curve.primitive_bezier_curve_add()
ribbon = bpy.context.object
ribbon.data.bevel_depth = 0.1
ribbon.data.resolution_u = 4
ribbon.data.bevel_resolution = 1
ribbon.data.twist_mode = 'TANGENT'
ribbon.data.extrude = 64
activate(ribbon)
remesh = ribbon.modifiers.new("Remesh", 'REMESH')
remesh.voxel_size = 0.2
n = counts(ribbon)[0]
model = multires.stack_vertices(ribbon)
with budget._built(ribbon.data) as mesh:
    walk = python_walk(mesh)
    triangle_area = budget.Measures(mesh).remesh()[0]
check("a ribbon twisted by Twist Tangent: its faces as triangles (%.0f m², the open sheet twice) where their "
      "own area says %.0f" % (triangle_area, walk[0]), triangle_area > 10 * walk[0])
check("so its Remesh at 0.2 is counted at or above Blender's %s (%s)" % (format(n, ','), format(model, ',')),
      model >= n)
before = int(sculpt._remesh_count(walk, 0.2) * budget.REMESH_MARGIN)
check("control: from the polygons' own areas it would have been counted %s" % format(before, ','), before < n)

# ---------------------------------------------------------------------------
print("\n7. Add ▸ Mesh's primitives, priced from their own settings before Blender makes them")
clear()
for name, settings in [('primitive_plane_add', {}), ('primitive_cube_add', {}), ('primitive_monkey_add', {}),
                       ('primitive_circle_add', {'vertices': 7, 'fill_type': 'TRIFAN'}),
                       ('primitive_circle_add', {'vertices': 700}),
                       ('primitive_uv_sphere_add', {'segments': 5, 'ring_count': 4}),
                       ('primitive_uv_sphere_add', {'segments': 300, 'ring_count': 200}),
                       ('primitive_ico_sphere_add', {'subdivisions': 1}), ('primitive_ico_sphere_add', {'subdivisions': 7}),
                       ('primitive_cylinder_add', {'vertices': 9, 'end_fill_type': 'TRIFAN'}),
                       ('primitive_cylinder_add', {'vertices': 900, 'end_fill_type': 'NGON'}),
                       ('primitive_cone_add', {'vertices': 9, 'radius2': 0.5, 'end_fill_type': 'TRIFAN'}),
                       ('primitive_cone_add', {'vertices': 9}),
                       ('primitive_torus_add', {'major_segments': 256, 'minor_segments': 256}),
                       ('primitive_grid_add', {'x_subdivisions': 3, 'y_subdivisions': 5}),
                       ('primitive_grid_add', {'x_subdivisions': 1000, 'y_subdivisions': 400})]:
    op = getattr(bpy.ops.mesh, name)
    model = budget.primitive_vertices(op, name, settings)
    said = run("bpy.ops.mesh.%s(**%r)" % (name, settings))
    made = len(bpy.context.object.data.vertices) if said is None and bpy.context.object else None
    # Exact for each, but a cone, counted as its top were a ring (2n + 2):
    # to a point Blender makes n + 1.
    check("%s %s: counted %s, Blender made %s" % (name, settings, model, made),
          said is None and model is not None and made is not None and model >= made
          and (model == made or name == 'primitive_cone_add'), said)
    clear()
check("each is handed out priced (%s)" % type(bpy.ops.mesh.primitive_grid_add).__name__,
      type(bpy.ops.mesh.primitive_grid_add).__name__ == '_PricedAdd')
said = None
try:
    sync.run_operator('mesh.primitive_uv_sphere_add', {'segments': 100000, 'ring_count': 100000})
except RuntimeError as error:
    said = str(error)
check("the Operator Search's UV Sphere at Segments and Rings 100,000 is refused before it runs",
      said is not None and "9,999,900,002" in said and not bpy.data.objects, said)
said = run("bpy.ops.mesh.primitive_grid_add(x_subdivisions=10000, y_subdivisions=10000)")
check("a script line's 10,000 x 10,000 grid is refused (100,020,001)", said is not None and "100,020,001" in said
      and not bpy.data.objects, said)
said = run("bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=10)")
check("an Ico Sphere at Subdivisions 10 is refused (2,621,442)", said is not None and "2,621,442" in said, said)
said = run("bpy.ops.mesh.primitive_circle_add(vertices=3_000_000)")
check("a circle of 3,000,000 vertices is refused", said is not None and "3,000,000" in said, said)
said = run("bpy.ops.mesh.primitive_cylinder_add(vertices=1_000_000, end_fill_type='NOTHING')")
check("a cylinder of 1,000,000 with no caps (2,000,000 vertices) passes", said is None
      and bpy.context.object is not None and len(bpy.context.object.data.vertices) == 2_000_000, said)
clear()
# With its N-Gon caps, the default, the same cylinder is inside the budget
# and froze this check: Blender's N-Gon fill had not finished after 30 minutes
# (the first version of this part). Refused for the sides of its N-Gon.
said = run("bpy.ops.mesh.primitive_cylinder_add(vertices=1_000_000)")
check("with its N-Gon caps it is refused for their sides, before Blender fills them", said is not None
      and "N-Gon of 1,000,000 sides" in said and not bpy.data.objects, said)
said = run("bpy.ops.mesh.primitive_circle_add(vertices=2000, fill_type='NGON')")
check("a circle filled with an N-Gon of 2,000 passes", said is None and len(bpy.data.objects) == 1, said)
clear()
said = run("bpy.ops.mesh.primitive_circle_add(vertices=2001, fill_type='NGON')")
check("and of 2,001 is refused", said is not None and "2,001 sides" in said and not bpy.data.objects, said)
said = run("bpy.ops.mesh.primitive_cone_add(vertices=50_000, end_fill_type='TRIFAN')")
check("a cone of 50,000 with a Triangle Fan base passes", said is None and len(bpy.data.objects) == 1, said)
clear()
# Why the cap: the fill's time grows far faster than its sides. Timed on the
# operator as Blender hands it out, bare (4,000 sides is past the cap).
timings = []
kept_adds = context.PRICED_ADDS
context.PRICED_ADDS = ()
bare_circle = bpy.ops.mesh.primitive_circle_add
context.PRICED_ADDS = kept_adds
# Blender's own operator under the wrapper: what is timed is its fill, not the
# gate's price of the new object around the call (a few ms that, on a loaded
# Mac, took the 1,000-sided fill's 0.02 s up to a ratio of 7.6).
bare_circle = getattr(bare_circle, '_operator', bare_circle)
# The gate off too, and the least of three runs: the Mac this was measured on
# had other work running (load 111 to 198), and one slow 1,000-sided run is
# enough to pull the ratio under 8.
with gate_off():
    for sides in (1000, 4000):
        runs = []
        for _ in range(3):
            started = time.time()
            bare_circle(vertices=sides, fill_type='NGON')
            runs.append(time.time() - started)
            clear()
        timings.append(min(runs))
check("control: an N-Gon fill of 4,000 sides takes %.0f times one of 1,000 (%.3f s, %.3f s)"
      % (timings[1] / max(timings[0], 1e-6), timings[0], timings[1]), timings[1] > 8 * timings[0], timings)
# In Edit Mode Blender adds the primitive into the edited mesh, under its
# modifiers.
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
activate(cube)
cube.modifiers.new("Subdivision", 'SUBSURF').levels = 4
bpy.ops.object.mode_set(mode='EDIT')
said = run("bpy.ops.mesh.primitive_grid_add(x_subdivisions=300, y_subdivisions=300)")
bpy.ops.object.mode_set(mode='OBJECT')
check("in Edit Mode under a Subdivision at level 4, a 300 x 300 grid into the cube is refused", said is not None
      and "Edit Mode" in said and "2,500,000" in said and len(cube.data.vertices) == 8, said)
cube.modifiers.clear()
bpy.ops.object.mode_set(mode='EDIT')
said = run("bpy.ops.mesh.primitive_grid_add(x_subdivisions=300, y_subdivisions=300)")
bpy.ops.object.mode_set(mode='OBJECT')
check("and with no modifier it goes in (%d vertices)" % len(cube.data.vertices),
      said is None and len(cube.data.vertices) == 8 + 301 * 301, said)
clear()
# The control: with the primitives off the list the factory hands the
# operator out bare, and nothing would stop the grid the budget counts at
# 100,020,001 (not run).
kept_adds = context.PRICED_ADDS
context.PRICED_ADDS = ()
bare_grid = bpy.ops.mesh.primitive_grid_add
context.PRICED_ADDS = kept_adds
check("control: off the list it is handed out bare (%s), and the same grid would be built: counted %s"
      % (type(bare_grid).__name__, format(budget.primitive_vertices(
          bare_grid, 'primitive_grid_add', {'x_subdivisions': 10000, 'y_subdivisions': 10000}), ',')),
      type(bare_grid).__name__ != '_PricedAdd')

# ---------------------------------------------------------------------------
# 8. Round 4's fix-round review (October 21): each class it measured going
# round the budget, through the app's own strings where the app sends one,
# each with a control that shows the bypass (the same thing done bare, or the
# model as it was).
if "8" in PARTS:
    print("\n8. the fix-round review's classes, each with its control")

    def said_by(fn):
        try:
            fn()
        except RuntimeError as error:
            return str(error)
        return None

    def bare(source):
        return "\n".join(line for line in source.splitlines() if "_blenderkit_budget" not in line)

    def grid(n, name="Grid"):
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=10)
        g = bpy.context.object
        g.name = name
        activate(g)
        return g

    class unpriced_operators:
        """The operator factory with no priced operators: the control."""
        def __enter__(self):
            self.kept = context.PRICED_OPERATORS
            context.PRICED_OPERATORS = ()

        def __exit__(self, *exc):
            context.PRICED_OPERATORS = self.kept

    # -- the Subdivision row: Levels Viewport and Render sent together --
    clear()
    g = grid(400)
    check("8.1 Add Modifier ▸ Subdivision Surface on a 400 × 400 grid passes", run(blocks["ADD MESH SUBSURF"]) is None)
    said = run(blocks["ROW subdivision level 2"])
    check("the row's Levels 1 → 2 (with Render 2, as it sends them) is refused at 2,563,201", said is not None
          and "2,563,201" in said and g.modifiers[-1].levels == 1, said)
    with gate_off():
        said = run(bare(blocks["ROW subdivision level 2"]))
        check("control: the row's lines bare: Blender makes %s" % format(counts(g)[0], ','),
              said is None and counts(g)[0] == 2_563_201, said)
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    activate(a)
    for count, axis in ((64, 0), (32, 1)):
        run(blocks["ADD MESH ARRAY"])
        m = a.modifiers[-1]
        m.relative_offset_displace = (1.5, 0, 0) if axis == 0 else (0, 1.5, 0)
        run(blocks["ROW array count %d" % count].replace('"Array"', '"%s"' % m.name))
        run(blocks["ROW array camera off"].replace('"Array"', '"%s"' % m.name))
    run(blocks["ADD MESH SUBSURF"])
    said = run(blocks["ROW subdivision level 4"])
    check("two Arrays hidden from renders, then the row's 1 → 4: refused at 3,149,824 (the viewport counted)",
          said is not None and "3,149,824" in said, said)
    rendered = budget.Prices(render=True)
    render_count = budget._final(a, rendered).final.v
    rendered.close()
    check("control: the camera off hides them from a render's count (%s), which alone passed the row's 1 → 4"
          % format(render_count, ','), render_count < 10_000)

    # -- the Object menu's modifier and data operators --
    def object_menu_fixture():
        clear()
        bpy.ops.mesh.primitive_cube_add()
        a = bpy.context.object
        a.name = "A"
        a.modifiers.new("Subdivision", 'SUBSURF').levels = 4
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=120, y_subdivisions=120, size=4, location=(6, 0, 0))
        b = bpy.context.object
        b.name = "B"
        for o in bpy.context.view_layer.objects:
            o.select_set(True)
        bpy.context.view_layer.objects.active = a
        return a, b

    for key, target, blender_says in (("JOIN", "A", 3_691_779), ("COPY MODIFIERS TO SELECTED", "B", 3_690_241),
                                      ("LINK MODIFIERS", "B", 3_690_241)):
        a, b = object_menu_fixture()
        said = run(blocks[key])
        check("8.2 %s from a cube under Subdivision 4 with a 120 × 120 grid: refused at %s"
              % (key.title(), format(blender_says, ',')), said is not None and format(blender_says, ',') in said, said)
        a, b = object_menu_fixture()
        with unpriced_operators(), gate_off():
            said = run(blocks[key])
            made = counts(bpy.data.objects[target])[0]
        check("control: with the operator handed out bare, Blender makes %s" % format(made, ','),
              said is None and made == blender_says, said)
    a, b = object_menu_fixture()
    bpy.context.view_layer.objects.active = b
    b.select_set(True)
    a.select_set(True)
    said = run(blocks["LINK OBDATA"])
    check("Link Object Data from the grid to the cube under Subdivision 4: refused at 3,690,241",
          said is not None and "3,690,241" in said, said)
    a.modifiers.clear()
    said = run(blocks["LINK OBDATA"])
    check("and with the cube's Subdivision gone it passes", said is None and a.data == b.data, said)

    # -- operators that rebuild the base under a priced stack --
    clear()
    bpy.ops.mesh.primitive_cube_add()
    c = bpy.context.object
    activate(c)
    c.modifiers.new("Subdivision", 'SUBSURF').levels = 6
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    said = run(blocks["EDIT SUBDIVIDE 10"])
    bpy.ops.object.mode_set(mode='OBJECT')
    check("8.3 Edit Mode Subdivide at 10 cuts on a cube under Subdivision 6 is refused", said is not None
          and "2,500,000" in said and len(c.data.vertices) == 8, said)
    # The control on a fresh cube: had the check above let it through, a
    # second Subdivide would be 10 cuts of 10 cuts.
    clear()
    bpy.ops.mesh.primitive_cube_add()
    c = bpy.context.object
    activate(c)
    c.modifiers.new("Subdivision", 'SUBSURF').levels = 6
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    with unpriced_operators(), gate_off():
        said = run(blocks["EDIT SUBDIVIDE 10"])
    bpy.ops.object.mode_set(mode='OBJECT')
    check("control: bare, Blender makes %s" % format(counts(c)[0], ','), said is None and counts(c)[0] == 2_973_698, said)
    clear()
    bpy.ops.curve.primitive_bezier_curve_add()
    cu = bpy.context.object
    activate(cu)
    for i in range(2):
        m = cu.modifiers.new("Array%d" % i, 'ARRAY')
        m.count = 64
        m.relative_offset_displace = (1.0 if i == 0 else 0.0, 1.0 if i == 1 else 0.0, 0.0)
    cu.data.bevel_depth = 0.05
    cu.data.bevel_resolution = 2
    results = []
    for press in (1, 2):
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.curve.select_all(action='SELECT')
        results.append(run(blocks["CURVE SUBDIVIDE 4"]))
        bpy.ops.object.mode_set(mode='OBJECT')
    check("the curve's Segments ▸ Subdivide, 4 cuts under two Arrays of 64: the first press passes (%s), "
          "the second is refused" % format(counts(cu)[0], ','),
          results[0] is None and results[1] is not None and "2,500,000" in results[1]
          and counts(cu)[0] == 1_998_848, results)
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    activate(a)
    m = a.modifiers.new("Array", 'ARRAY')
    sync.set_property("bpy.data.objects['A'].modifiers['Array']", "fit_type", "FIT_LENGTH")
    sync.set_property("bpy.data.objects['A'].modifiers['Array']", "fit_length", 100.0)
    sync.set_property("bpy.data.objects['A']", "scale", [0.0001, 1.0, 1.0])
    said = run(blocks["APPLY SCALE"])
    check("Apply ▸ Scale of an Array fitted to 100 m at a scale of 0.0001 is refused at 4,000,008",
          said is not None and "4,000,008" in said and counts(a)[0] == 408, said)
    with unpriced_operators(), gate_off():
        said = run(blocks["APPLY SCALE"])
        check("control: bare, Blender makes %s" % format(counts(a)[0], ','), said is None and counts(a)[0] == 4_000_008,
              said)
    clear()
    bpy.ops.mesh.primitive_uv_sphere_add()
    sp = bpy.context.object
    activate(sp)
    sp.modifiers.new("Subdivision", 'SUBSURF').levels = 3
    said = run(blocks["QUADRIFLOW 40000"])
    check("QuadriFlow at 40,000 faces under Subdivision 3 is refused before it runs (Blender, the review: "
          "2,553,282)", said is not None and "2,500,000" in said and len(sp.data.vertices) == 482, said)
    clear()
    bpy.ops.mesh.primitive_cube_add()
    c = bpy.context.object
    activate(c)
    c.modifiers.new("Subdivision", 'SUBSURF').levels = 3
    c.data.remesh_voxel_size = 0.02
    said = said_by(lambda: sync.run_operator('object.voxel_remesh', {}))
    check("Voxel Remesh at 0.02 under Subdivision 3 is refused through the stack (the review: 3,917,186)",
          said is not None and "2,500,000" in said and len(c.data.vertices) == 8, said)
    kept_price = budget.price_voxel_remesh
    budget.price_voxel_remesh = lambda obj, count: None
    said = said_by(lambda: sculpt.refuse_voxel_remesh(c))
    budget.price_voxel_remesh = kept_price
    check("control: its base alone (as before) passes it", said is None, said)

    # Edit Mode's operators that add to the edited mesh, priced as they are
    # handed out (`_EDIT_GROWTH`), and a few that pass.
    for label, call, refused in (("Bevel at 100 Segments", "bpy.ops.mesh.bevel(offset=0.1, segments=100)", True),
                                 ("Spin at 1,000 Steps", "bpy.ops.mesh.spin(steps=1000, angle=6.28, axis=(0, 0, 1))", True),
                                 ("Extrude Region", "bpy.ops.mesh.extrude_region_move()", False),
                                 ("Duplicate", "bpy.ops.mesh.duplicate_move()", False),
                                 ("Inset Faces", "bpy.ops.mesh.inset(thickness=0.1)", False)):
        clear()
        bpy.ops.mesh.primitive_cube_add()
        c = bpy.context.object
        activate(c)
        c.modifiers.new("Subdivision", 'SUBSURF').levels = 5
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        said = run(call)
        bpy.ops.object.mode_set(mode='OBJECT')
        check("Edit Mode %s on a cube under Subdivision 5 %s (Blender %s)"
              % (label, "is refused" if refused else "passes", format(counts(c)[0], ',')),
              (said is not None and "2,500,000" in said and len(c.data.vertices) == 8) if refused
              else (said is None and multires.stack_vertices(c) >= counts(c)[0]), said)
    clear()
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=7)
    ico = bpy.context.object
    activate(ico)
    said = run("bpy.ops.object.subdivision_set(level=1)")
    check("Subdivision Set on an Ico Sphere at 7 is refused for its limit surface's time", said is not None
          and "limit surface" in said and not ico.modifiers, said)
    clear()
    bpy.ops.mesh.primitive_uv_sphere_add()
    sphere = bpy.context.object
    activate(sphere)
    bpy.ops.object.mode_set(mode='SCULPT')
    bpy.context.scene.tool_settings.sculpt.constant_detail_resolution = 10000
    said = said_by(lambda: budget.price_operator('sculpt.detail_flood_fill', {}))
    bpy.ops.object.mode_set(mode='OBJECT')
    check("Detail Flood Fill at a Constant Resolution of 10,000 is refused (priced, not run)", said is not None
          and "2,500,000" in said, said)

    # -- the Transform fields and the Data API row through other objects --
    def fitted_to(length, offset_location, parent=None):
        clear()
        bpy.ops.mesh.primitive_cube_add()
        a = bpy.context.object
        a.name = "A"
        bpy.ops.object.empty_add(location=offset_location)
        o = bpy.context.object
        o.name = "O"
        if parent is not None:
            bpy.ops.object.empty_add(location=(0, 0, 0))
            p = bpy.context.object
            p.name = "P"
            o.parent = p
        m = a.modifiers.new("Array", 'ARRAY')
        m.fit_type = 'FIT_LENGTH'
        m.fit_length = length
        m.use_relative_offset = False
        m.use_object_offset = True
        m.offset_object = o
        bpy.context.view_layer.update()
        return a, o

    a, o = fitted_to(40.0, (1, 0, 0))
    said = run(blocks["FIELD O location x 0.0001"])
    check("8.4 the Transform field's X 0.0001 for an Array's offset object 1 m away is refused at 3,200,008",
          said is not None and "3,200,008" in said and counts(a)[0] == 328, said)
    said = run(blocks["FIELD O location x 0.9"])
    check("and X 0.9 passes (%s, counted at or above it)" % format(counts(a)[0], ','),
          said is None and multires.stack_vertices(a) >= counts(a)[0], said)
    o.location.x = 1.0
    with gate_off():
        said = run(bare(blocks["FIELD O location x 0.0001"]))
        check("control: the field's assignment bare: Blender makes %s" % format(counts(a)[0], ','),
              said is None and counts(a)[0] == 3_200_008, said)
    a, o = fitted_to(10.0, (1, 0, 0), parent=True)
    said = said_by(lambda: sync.set_property("bpy.data.objects['P']", "location", [-0.99998, 0, 0]))
    check("8.5 the Data API row's move of the offset object's parent is refused (3,994,584)",
          said is not None and "3,994,584" in said, said)
    with gate_off():
        bpy.data.objects['P'].location = (-0.99998, 0, 0)
        check("control: set bare, Blender makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_994_576)

    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    bpy.ops.object.empty_add()
    h = bpy.context.object
    h.name = "H"
    hook = a.modifiers.new("Hook", 'HOOK')
    hook.vertex_indices_set(list(range(8)))
    hook.object = h
    a.modifiers.new("Remesh", 'REMESH').voxel_size = 0.1
    said = said_by(lambda: sync.set_property("bpy.data.objects['H']", "scale", [36, 36, 36]))
    check("8.6 a Hook's empty scaled 36 through the Data API row, a Remesh at 0.1 after it: refused",
          said is not None and "2,500,000" in said and counts(a)[0] == 2_648, said)
    with gate_off():
        h.scale = (36, 36, 36)
        check("control: set bare, Blender makes %s" % format(counts(a)[0], ','), counts(a)[0] > 2_500_000)
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    a.modifiers.new("Remesh", 'REMESH').voxel_size = 0.1
    path = "bpy.data.meshes[%r].vertices[0]" % a.data.name
    said = said_by(lambda: sync.set_property(path, "co", [2400.0, 2400.0, 2400.0]))
    check("a vertex moved to (2400, 2400, 2400) through the Data API row under a Remesh at 0.1: refused",
          said is not None and "2,500,000" in said, said)
    said = said_by(lambda: sync.set_property(path, "co", [5.0, 5.0, 5.0]))
    check("and to (5, 5, 5) passes, counted at or above Blender's %s" % format(counts(a)[0], ','),
          said is None and multires.stack_vertices(a) >= counts(a)[0], said)
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    bpy.ops.curve.primitive_bezier_curve_add(location=(0, 4, 0))
    cv = bpy.context.object
    cv.name = "C"
    m = a.modifiers.new("Array", 'ARRAY')
    m.fit_type = 'FIT_CURVE'
    m.curve = cv
    bpy.context.view_layer.update()
    said = said_by(lambda: sync.set_property("bpy.data.objects['C']", "delta_scale", [5e5, 5e5, 5e5]))
    check("a Fit Curve's curve's Delta Scale × 5e5 through the Data API row: refused", said is not None
          and "2,500,000" in said, said)
    said = run(blocks["DIMENSION C X"])
    check("and the Item tab's Dimensions X 1,000,000 for the curve: refused", said is not None and "2,500,000" in said, said)
    with gate_off():
        cv.delta_scale = (5e5, 5e5, 5e5)
        bpy.context.view_layer.update()
        held = counts(a)[0]
    said = said_by(lambda: sync.set_property("bpy.data.objects['A'].modifiers['Array']", "relative_offset_displace",
                                             [1.1, 0, 0]))
    check("set bare (Blender keeps %d: it adds no transform relation), the next edit on the Array is refused "
          "as heavier than what Blender holds" % held, held == 16 and said is not None and "2,500,000" in said, said)

    # -- caps of caps --
    clear()
    chain = []
    for i in range(20):
        bpy.ops.mesh.primitive_cube_add(location=(0, 3 * i, 0))
        x = bpy.context.object
        x.name = "X%02d" % i
        chain.append(x)
    for x in chain[:-1]:
        x.modifiers.new("Array", 'ARRAY').count = 1
    refused_at = None
    for i in reversed(range(19)):
        for key in ("start_cap", "end_cap"):
            said = said_by(lambda: sync.set_property("bpy.data.objects['%s'].modifiers['Array']" % chain[i].name, key,
                                                     "bpy.data.objects['%s']" % chain[i + 1].name))
            if said is not None and refused_at is None:
                refused_at = (i, key, said)
    check("8.7 a chain of 19 Arrays whose caps are the next: refused where it passes the budget %s"
          % (str(refused_at[:2]) if refused_at else "nowhere"),
          refused_at is not None and "2,500,000" in refused_at[2] and counts(chain[0])[0] <= 2_500_000, refused_at)
    check("and the first is counted as Blender makes it (%s)" % format(counts(chain[0])[0], ','),
          multires.stack_vertices(chain[0]) == counts(chain[0])[0])
    with gate_off():
        chain[0].modifiers['Array'].end_cap = chain[1]
        check("control: set bare, Blender makes %s" % format(counts(chain[0])[0], ','), counts(chain[0])[0] > 2_500_000)

    # -- Fluid, metaballs, volumes --
    clear()
    bpy.ops.mesh.primitive_cube_add(size=4)
    dom = bpy.context.object
    dom.name = "Domain"
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.8, location=(0, 0, 0.8))
    flow = bpy.context.object
    activate(dom)
    run(blocks["ADD MESH FLUID"])
    fpath = "bpy.data.objects['Domain'].modifiers['Fluid']"
    sync.set_property(fpath, "fluid_type", "DOMAIN")
    for key, value in (("domain_type", "LIQUID"), ("use_mesh", True), ("resolution_max", 32),
                       ("cache_directory", os.path.join(WORK, "fluid"))):
        sync.set_property(fpath + ".domain_settings", key, value)
    dom.modifiers['Fluid'].domain_settings.cache_type = 'REPLAY'
    fl = flow.modifiers.new("Fluid", 'FLUID')
    fl.fluid_type = 'FLOW'
    fl.flow_settings.flow_type = 'LIQUID'
    check("8.8 a Liquid domain with Mesh at Resolution 32: counted at or above Blender's %s (%s)"
          % (format(counts(dom)[0], ','), format(multires.stack_vertices(dom), ',')),
          counts(dom)[0] > 1000 and multires.stack_vertices(dom) >= counts(dom)[0])
    # Its mesh is bounded by the domain's surface on the mesh's grid since round
    # 4's fix round 2 (`FLUID_MESH_VERTICES_PER_SURFACE_CELL`, measured): at
    # Resolution 64 and the default Upres 2, 1,179,648.
    sync.set_property(fpath + ".domain_settings", "resolution_max", 64)
    said = run(blocks["ADD MESH SUBSURF"])
    check("and at Resolution 64 Add Modifier ▸ Subdivision Surface on it is refused (its bound, twelve vertices a "
          "cell of the domain's surface on the mesh's grid)", said is not None and "2,500,000" in said, said)
    said = said_by(lambda: sync.set_property(fpath + ".domain_settings", "resolution_max", 200))
    check("Resolution Divisions 200 is refused", said is not None, said)
    sync.set_property(fpath + ".domain_settings", "domain_type", "GAS")
    said = said_by(lambda: sync.set_property(fpath + ".domain_settings", "resolution_max", 300))
    check("a Gas domain's 300 is refused for its grids' memory (27,000,000 cells)", said is not None
          and "GB" in said, said)
    kept = budget._GROWTH['FLUID']
    budget._GROWTH['FLUID'] = budget._keep
    sync.set_property(fpath + ".domain_settings", "domain_type", "LIQUID")
    control = multires.stack_vertices(dom)
    budget._GROWTH['FLUID'] = kept
    check("control: Fluid counted as keeping its mesh, as before: %d" % control, control == 8)

    clear()
    said = said_by(lambda: sync.run_operator('object.metaball_add', {'type': 'BALL', 'radius': 2.0}))
    ball = bpy.context.object
    mb = "bpy.data.metaballs[%r]" % ball.data.name
    sync.set_property(mb + ".elements[0]", "radius", 8.0)
    sync.set_property(mb, "resolution", 0.05)
    check("8.9 Add ▸ Metaball, Radius 8, Viewport Size 0.05 (the Data API row): counted at or above Blender's %s (%s)"
          % (format(counts(ball)[0], ','), format(multires.stack_vertices(ball), ',')),
          multires.stack_vertices(ball) >= counts(ball)[0] > 100_000)
    said = said_by(lambda: sync.set_property(mb, "resolution", 0.01))
    check("Viewport Size 0.01 is refused (the review: 3,987,960 in 111.9 s)", said is not None and "2,500,000" in said, said)
    said = said_by(lambda: sync.run_operator('object.metaball_add', {'type': 'BALL', 'radius': 300.0}))
    check("a second Add ▸ Metaball of Radius 300 into the family is refused", said is not None, said)
    sync.set_property(mb, "resolution", 0.04)
    activate(ball)
    said = run("bpy.ops.object.duplicate_move()")
    check("and a Duplicate of it at 0.04, which joins its family, is refused (counted %s alone)"
          % format(multires.stack_vertices(ball), ','), said is not None and "2,500,000" in said
          and len([o for o in bpy.data.objects if o.type == 'META']) == 1, said)
    kept = budget._meta_base
    budget._meta_base = lambda o, s: budget.Counts(0, 0, 0, 0)
    control = said_by(lambda: budget.price(ball.data, "resolution", 0.01))
    budget._meta_base = kept
    check("control: metaballs counted as making nothing, as before: Viewport Size 0.01 passes (not run)", control is None)

    clear()
    bpy.ops.mesh.primitive_cube_add()
    src = bpy.context.object
    src.name = "Src"
    sync.run_operator('object.volume_add', {})
    vol = bpy.context.object
    vol.name = "Vol"
    activate(vol)
    sync.run_operator('object.modifier_add', {'type': 'MESH_TO_VOLUME'})
    mtv = "bpy.data.objects['Vol'].modifiers[%r]" % vol.modifiers[-1].name
    sync.set_property(mtv, "object", "bpy.data.objects['Src']")
    bpy.ops.mesh.primitive_plane_add(location=(5, 0, 0))
    n = bpy.context.object
    n.name = "N"
    activate(n)
    run(blocks["ADD MESH VOLUME_TO_MESH"])
    sync.set_property("bpy.data.objects['N'].modifiers[-1]", "object", "bpy.data.objects['Vol']")
    sync.set_property(mtv, "voxel_amount", 256)
    check("8.10 Volume to Mesh of a volume made by Mesh to Volume at 256: counted at or above Blender's %s (%s)"
          % (format(counts(n)[0], ','), format(multires.stack_vertices(n), ',')),
          multires.stack_vertices(n) >= counts(n)[0] > 100_000)
    said = said_by(lambda: sync.set_property(mtv, "voxel_amount", 1200))
    check("Voxel Amount 1,200 is refused (the review: 2,766,248 in 9.9 s)", said is not None, said)
    kept = budget._GROWTH['VOLUME_TO_MESH']
    budget._GROWTH['VOLUME_TO_MESH'] = budget._keep
    control = multires.stack_vertices(n)
    budget._GROWTH['VOLUME_TO_MESH'] = kept
    check("control: Volume to Mesh counted as keeping its mesh, as before: %d" % control, control == 4)

    # -- Boolean crossings, and the Subdivision's time --
    clear()
    plates, length = 50, 0.2 * 50 + 1.0
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    a = bpy.context.object
    a.name = "A"
    a.scale = (0.02, length, 1.0)
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    b = bpy.context.object
    b.name = "B"
    b.scale = (length, 0.02, 0.6)
    for o in (a, b):
        activate(o)
        bpy.ops.object.transform_apply(scale=True)
    ma = a.modifiers.new("Array", 'ARRAY')
    ma.count = plates
    ma.relative_offset_displace = (10, 0, 0)
    mb_ = b.modifiers.new("Array", 'ARRAY')
    mb_.count = plates
    mb_.relative_offset_displace = (0, 10, 0)
    a.location = (-0.1 * plates + 0.1, 0, 0)
    b.location = (0, -0.1 * plates + 0.1, 0)
    activate(a)
    bo = a.modifiers.new("Boolean", 'BOOLEAN')
    bo.operation = 'UNION'
    bo.solver = 'MANIFOLD'
    bo.object = b
    bpy.context.view_layer.update()
    w = budget._walk(a, budget.Prices(), refine=True)
    check("8.11 two combs of 50 plates under a Boolean Union: the crossings counted, %s at or above Blender's %s"
          % (format(w.final.v, ','), format(counts(a)[0], ',')), w.final.v >= counts(a)[0] == 20_800)
    said = run(blocks["ADD MESH SUBSURF"])
    check("Add Modifier ▸ Subdivision Surface on it is refused for its time (the review: not done in 300 s)",
          said is not None and "limit surface" in said, said)
    kept, kept_slow = budget._GROWTH['BOOLEAN'], budget._SLOW
    budget._GROWTH['BOOLEAN'] = lambda x, c: c.bound().plus(budget._object_final(x.get('object'), x))
    budget._SLOW = kept_slow + ('BOOLEAN',)
    control = budget._walk(a, budget.Prices(), refine=True).final.v
    budget._GROWTH['BOOLEAN'], budget._SLOW = kept, kept_slow
    check("control: the crossings left out and never refined, as before: %d" % control, control < 1000)
    clear()
    for label, add, refused in (("a Circle of 250 as an N-Gon", "primitive_circle_add(vertices=250, fill_type='NGON')", True),
                                ("a Circle of 250 as a Triangle Fan", "primitive_circle_add(vertices=250, fill_type='TRIFAN')", True),
                                ("a UV Sphere of 250 segments", "primitive_uv_sphere_add(segments=250, ring_count=6)", True),
                                ("an Ico Sphere at 7", "primitive_ico_sphere_add(subdivisions=7)", True),
                                ("Suzanne", "primitive_monkey_add()", False),
                                ("a UV Sphere of 64 × 32", "primitive_uv_sphere_add(segments=64, ring_count=32)", False),
                                ("a Cylinder of 128", "primitive_cylinder_add(vertices=128)", False)):
        clear()
        run("bpy.ops.mesh." + add)
        activate(bpy.context.object)
        said = run(blocks["ADD MESH SUBSURF"])
        check("8.12 Add Modifier ▸ Subdivision Surface on %s %s" % (label, "is refused for its time" if refused else "passes"),
              (said is not None and "limit surface" in said) if refused else said is None, said)
    clear()
    run("bpy.ops.mesh.primitive_circle_add(vertices=250, fill_type='NGON')")
    activate(bpy.context.object)
    said = said_by(lambda: budget.price_add('SUBSURF', settings={'use_limit_surface': False}))
    check("and with Use Limit Surface off it passes", said is None, said)
    kept = budget.SUBDIVISION_SECONDS
    budget.SUBDIVISION_SECONDS = 1e9
    said = run(blocks["ADD MESH SUBSURF"])
    budget.SUBDIVISION_SECONDS = kept
    check("control: with no time cap, as before, it passes (not evaluated: the review's 8.7 s)", said is None, said)

    # -- non-finite, Solidify on non-manifold, Remesh refined --
    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    a.modifiers.new("Array", 'ARRAY').count = 5
    sync.set_property("bpy.data.objects['A'].modifiers['Array']", "use_constant_offset", True)
    said = said_by(lambda: sync.set_property("bpy.data.objects['A'].modifiers['Array']", "constant_offset_displace",
                                             [1e38, 0, 0]))
    check("8.13 an Array's Constant Offset (1e38, 0, 0) through the Data API row is refused as non-finite",
          said is not None and "infinite" in said and finite(a), said)
    with gate_off():
        a.modifiers['Array'].constant_offset_displace = (1e38, 0, 0)
        check("control: set bare, Blender's vertices are not all finite", not finite(a))
    clear()
    me = bpy.data.meshes.new("fan")
    bm = bmesh.new()
    p0, p1 = bm.verts.new((0, 0, 0)), bm.verts.new((0, 0, 1))
    for i in range(50):
        t_ = 2 * math.pi * i / 50
        q1 = bm.verts.new((math.cos(t_), math.sin(t_), 1))
        q0 = bm.verts.new((math.cos(t_), math.sin(t_), 0))
        bm.faces.new((p0, q0, q1, p1))
    bm.to_mesh(me)
    bm.free()
    fan = bpy.data.objects.new("Fan", me)
    bpy.context.scene.collection.objects.link(fan)
    so = fan.modifiers.new("Solidify", 'SOLIDIFY')
    so.solidify_mode = 'NON_MANIFOLD'
    check("8.14 Solidify Complex on 50 quads sharing an edge: counted %s, at or above Blender's %s"
          % (format(multires.stack_vertices(fan), ','), format(counts(fan)[0], ',')),
          multires.stack_vertices(fan) >= counts(fan)[0] == 300)
    kept = budget._GROWTH['SOLIDIFY']
    budget._GROWTH['SOLIDIFY'] = lambda x, c: c.times(2)
    control = multires.stack_vertices(fan)
    budget._GROWTH['SOLIDIFY'] = kept
    check("control: counted as two shells, as before: %d" % control, control == 204)
    clear()
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    activate(cube)
    cube.modifiers.new("Remesh", 'REMESH').voxel_size = 0.015
    said = run(blocks["ADD MESH SUBSURF"])
    said = said or run(blocks["ROW subdivision level 2"])
    check("8.15 a cube under a Remesh at 0.015, + Subdivision Surface at level 2 passes (Blender %s, counted %s)"
          % (format(counts(cube)[0], ','), format(multires.stack_vertices(cube), ',')),
          said is None and cube.modifiers[-1].levels == 2
          and multires.stack_vertices(cube) >= counts(cube)[0], said)
    budget._SLOW = budget._SLOW + ('REMESH',)
    control = multires.stack_vertices(cube)
    budget._SLOW = budget._SLOW[:-1]
    check("control: with Remesh's bound never refined, as before, it counts %s" % format(control, ','),
          control > budget.BUDGET)
    # Its time, which the count left out: Suzanne under a Remesh at 0.01
    # (175,276) took 6.2 s to subdivide once in desktop 5.2.1.
    clear()
    bpy.ops.mesh.primitive_monkey_add()
    suz = bpy.context.object
    activate(suz)
    suz.modifiers.new("Remesh", 'REMESH').voxel_size = 0.01
    said = run(blocks["ADD MESH SUBSURF"])
    check("and on Suzanne under a Remesh at 0.01 it is refused for its time, not its count", said is not None
          and "limit surface" in said, said)

    # -- Dynamic Topology's dabs, a render's own levels --
    clear()
    bpy.ops.mesh.primitive_uv_sphere_add()
    sp = bpy.context.object
    settings = bpy.context.scene.tool_settings.sculpt
    stroke = dict(camera=dict(distance=10.0, fov_y=0.7), view=(1000, 800), mapped=(1.0, 1000, 800, 1000, 800))
    settings.detail_type_method = 'CONSTANT'
    settings.constant_detail_resolution = 10000
    said = said_by(lambda: sculpt._refuse_dyntopo_growth(stroke, sp, None, 4))
    check("8.16 Dynamic Topology at a Constant Resolution of 10,000: a chunk of 4 dabs is refused", said is not None
          and "Dynamic Topology" in said, said)
    settings.detail_type_method = 'RELATIVE'
    settings.detail_size = 12
    said = said_by(lambda: sculpt._refuse_dyntopo_growth(stroke, sp, None, 4))
    check("and at Blender's Relative 12 px it passes (up to %s a dab)"
          % format(int(sculpt._dyntopo_dab_vertices(stroke, sp, None)), ','), said is None, said)
    clear()
    g = grid(300)
    g.modifiers.new("Subdivision", 'SUBSURF').render_levels = 3
    said = said_by(lambda: budget.price_render())
    check("8.17 a render of a 300 × 300 grid at Subdivision's Render level 3 is refused (5,764,801)",
          said is not None and "5,764,801" in said, said)
    g.modifiers[-1].render_levels = 1
    said = said_by(lambda: budget.price_render())
    check("and at Render level 1 it passes", said is None, said)
    check("each operator Blender's render runs through is handed out priced (%s)" % type(bpy.ops.render.render).__name__,
          type(bpy.ops.render.render).__name__ == '_PricedOperator')

    # -- a frame change, from what its keys set --
    clear()
    bpy.context.scene.frame_set(1)
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.count = 400_000
    m.keyframe_insert("count", frame=100)
    m.count = 2
    anim = sys.modules["_blenderkit_anim"]
    said = said_by(lambda: anim.frame_set(100))
    check("8.18 the timeline's frame 100, where a keyed Array's Count is 400,000, is refused before Blender "
          "evaluates it (the frame stays %d)" % bpy.context.scene.frame_current,
          said is not None and "3,200,000" in said and bpy.context.scene.frame_current == 1, said)
    said = said_by(lambda: anim.frame_set(10))
    check("and frame 10 passes (%s)" % format(counts(a)[0], ','), said is None and bpy.context.scene.frame_current == 10
          and multires.stack_vertices(a) >= counts(a)[0], said)
    # The control with the gate off: since round 4's fix round 2 a script's
    # own frame_set is priced as the timeline's is.
    with gate_off():
        bpy.context.scene.frame_set(100)
        control = counts(a)[0]
        bpy.context.scene.frame_set(1)
    check("control: Blender's own frame change makes %s" % format(control, ','), control == 3_200_000)

if "9" in PARTS:
    # The gate (_blenderkit_gate.py): its own file, in these globals.
    exec(compile(open(str(ROOT / "tests/budget/blender/gate.py")).read(), "gate.py", "exec"), globals())

if "11" in PARTS:
    # Frame changes and a legal Boolean, priced in proportion to what changes.
    exec(compile(open(str(ROOT / "tests/budget/blender/frames.py")).read(), "frames.py", "exec"), globals())

if "12" in PARTS:
    # The bypasses round 4's fix round 2 review measured past the gate, and
    # (at its end, 12i) fix round 3's.
    exec(compile(open(str(ROOT / "tests/budget/blender/bypass.py")).read(), "bypass.py", "exec"), globals())
else:
    if "12i" in PARTS:
        # Fix round 3's cases alone (`BUDGET_PARTS=12i`).
        exec(compile(open(str(ROOT / "tests/budget/blender/interface3.py")).read(), "interface3.py", "exec"),
             globals())
    if "12j" in PARTS:
        # The review of 12i's work, answered, alone (`BUDGET_PARTS=12j`; its
        # last case needs part 12's sweep and is skipped).
        exec(compile(open(str(ROOT / "tests/budget/blender/interface4.py")).read(), "interface4.py", "exec"),
             globals())

if "12" in PARTS or "12s" in PARTS:
    # Fix round 3's script-only cases: the budget gaps a script reaches, and
    # the gate's own holes (`BUDGET_PARTS=12s` alone).
    exec(compile(open(str(ROOT / "tests/budget/blender/script3.py")).read(), "script3.py", "exec"), globals())

if "13" in PARTS:
    # The review of frame changes and Boolean pricing, answered.
    exec(compile(open(str(ROOT / "tests/budget/blender/review13.py")).read(), "review13.py", "exec"), globals())

if "12" in PARTS or "12s" in PARTS or "12t" in PARTS:
    # The review of 12s's work, answered (`BUDGET_PARTS=12t` alone). Last:
    # it opens files, which replaces the scene the other parts hold.
    exec(compile(open(str(ROOT / "tests/budget/blender/review3s.py")).read(), "review3s.py", "exec"), globals())

print("\n%d passed, %d failed" % (passed, fail))
sys.exit(1 if fail else 0)
