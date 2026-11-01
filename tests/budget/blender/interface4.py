"""Part 12j: the review of fix round 3's "Close the budget gaps a user reaches
from the interface" answered (October 29). Each of its findings, refused
before Blender builds it, beside a control that puts that gap back and has
to let it through (or take Blender's own time).

Run from verify.py at the end of part 12 (or alone, `BUDGET_PARTS=12j`), in
its globals (`check`, `counts`, `clear`, `budget`, `sync`, `gate`, `context`,
`load`). Each case goes through the path the interface sends — the gizmo's
commit and the redo panel's Orientation row (`transform.*` with or without
a matrix), Shift+D and Duplicate Linked (`object.duplicate_move*`), the Data
API row (`_blenderkit_sync.set_property`), a script line followed by the
mirror's pass (`_blenderkit_sync.sync`) — and reads Blender's own count
after.

  j.1  a move with a bare orientation (no matrix, or one Blender works out
       again), in every orientation, and the place held in the update
  j.2  priced Object Mode operators other than the moves: Duplicate,
       Duplicate Linked, `object.duplicate` and Add ▸ Grid into a collection
       a Geometry Nodes Collection Info realizes
  j.3  Single Property drivers reading `matrix_world` and Dimensions
  j.4  a texture's colour ramp: its stops' colours, and a stop added
  j.5  empties that instance a collection, read by Collection Info
  j.6  Fast's Overlap Threshold: Blender's own time, refused before it runs
  j.7  an ordinary edit under Self Intersection, timed against Blender's own
  j.8  the four settings sweep2 now steps, swept with the fixes taken out

Nothing here opens a window, a browser or another app.
"""
import bpy, math, os, sys, time

SC4 = bpy.context.scene
nodecount_j = sys.modules.get("_blenderkit_nodecount") or load("_blenderkit_nodecount")


def said_j(fn):
    try:
        fn()
    except RuntimeError as error:
        return str(error)
    return None


def mirror_j():
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def line_j(source):
    """A script line, then the mirror's pass the app runs after it."""
    try:
        exec(compile(source, "<line>", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the refusal is the finding
        return str(error)
    return mirror_j()


def held_j(obj):
    """What Blender holds for `obj` now, evaluating nothing."""
    dg = bpy.context.view_layer.depsgraph
    evaluated = obj.evaluated_get(dg)
    if evaluated == obj:
        return None
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


class bare_j:
    """The gate off, and what was written inside evaluated before it is back
    on (fixtures and controls)."""

    def __enter__(self):
        gate._busy += 1

    def __exit__(self, *exc):
        try:
            bpy.context.view_layer.update()
        finally:
            gate._busy -= 1


class put_j:
    """`module.name` set to `value` for a control (the gap put back)."""

    def __init__(self, module, name, value):
        self.module, self.name, self.value = module, name, value

    def __enter__(self):
        self.kept = getattr(self.module, self.name)
        setattr(self.module, self.name, self.value)
        # And nothing held at the mirror's pass after (`hold_unseen`, the
        # review of 12s's work): what the gap lets through is Blender's to
        # keep, as before that hold existed.
        self.kept_hold = gate.hold_unseen
        gate.hold_unseen = lambda: False

    def __exit__(self, *exc):
        gate.hold_unseen = self.kept_hold
        setattr(self.module, self.name, self.kept)


class budget_j:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        self.kept = budget.BUDGET
        budget.BUDGET = self.value

    def __exit__(self, *exc):
        budget.BUDGET = self.kept


def refused_j(said, number=None):
    return said is not None and "and this app stops at" in said and (
        number is None or format(number, ',') in said)


def reset_j():
    clear()
    # Every collection, linked or not: the cases look theirs up by name.
    for block in list(bpy.data.collections):
        try:
            bpy.data.collections.remove(block)
        except (RuntimeError, ReferenceError):
            pass
    for collection in (bpy.data.actions, bpy.data.node_groups, bpy.data.textures, bpy.data.curves, bpy.data.meshes):
        for block in list(collection):
            if block.users == 0:
                try:
                    collection.remove(block)
                except (RuntimeError, ReferenceError):
                    pass
    SC4.transform_orientation_slots[0].type = 'GLOBAL'
    SC4.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
    SC4.cursor.location = (0.0, 0.0, 0.0)
    SC4.cursor.rotation_euler = (0.0, 0.0, 0.0)


def select_j(obj):
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj


def old_orientation(keywords, constrained=None):
    """`_orientation` as 6d31b90 had it: a given matrix taken as a Matrix's
    rows whatever the types say, and every bare orientation the identity."""
    from mathutils import Matrix
    matrix = keywords.get('orient_matrix')
    kind = keywords.get('orient_type')
    if matrix is not None and kind in (None, 'CUSTOM_MATRIX', 'LOCAL', 'NORMAL', 'VIEW', 'CURSOR', 'GIMBAL',
                                       'PARENT'):
        try:
            return Matrix(matrix).to_3x3()
        except (TypeError, ValueError):
            pass
    return Matrix.Identity(3)


def old_within_move(found, scope):
    """`_within_move` as 6d31b90 had it: the scope's channels, wherever they
    put the objects."""
    if found.structs or found.animated or found.frame is not None:
        return False
    moved = []
    for c in found.changes:
        if c.bulk is not None or c.key not in gate._MOVE_KEYS or not isinstance(c.owner, bpy.types.Object):
            return False
        try:
            if c.owner.as_pointer() not in scope:
                return False
        except (AttributeError, ReferenceError):
            return False
        moved.append(c.owner)
    return not (moved and budget.read_by_drivers(moved))


print("\n12j. fix round 3's review of the interface's gaps, answered")

# -- j.1 bare orientations -----------------------------------------------------------
def offset_j(turn=math.pi / 2):
    """A: a cube under an Array fitted to 40 by its offset object O, an empty
    at (1, 0, 0) turned `turn` about Z (328 vertices); O selected."""
    reset_j()
    with bare_j():
        bpy.ops.mesh.primitive_cube_add()
        a = bpy.context.object
        a.name = "A"
        bpy.ops.object.empty_add(location=(1, 0, 0))
        o = bpy.context.object
        o.name = "O"
        o.rotation_euler = (0.0, 0.0, turn)
        m = a.modifiers.new("Array", 'ARRAY')
        m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, o
        m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    select_j(o)
    return a, o


a, o = offset_j()
said = said_j(lambda: bpy.ops.transform.resize(value=(1, 0.0001, 1), orient_type='LOCAL',
                                                constraint_axis=(False, True, False), center_override=(0, 0, 0)))
check("12j.1 a Scale in Local, as the gizmo commits it (`orient_type='LOCAL'` with no matrix), of O turned 90° "
      "to 0.0001 along its Y: refused, Blender at %s and O where it was" % format(held_j(a) or 0, ','),
      refused_j(said) and held_j(a) == 328 and abs(o.location.x - 1.0) < 1e-6, (said, held_j(a)))
with put_j(budget, '_orientation', old_orientation), put_j(gate, '_within_move', old_within_move):
    a, o = offset_j()
    control = said_j(lambda: bpy.ops.transform.resize(value=(1, 0.0001, 1), orient_type='LOCAL',
                                                       constraint_axis=(False, True, False),
                                                       center_override=(0, 0, 0)))
    built = held_j(a)
check("control: with a bare orientation priced as the identity and the update let through on its scope, as on "
      "6d31b90, it passed and Blender built %s" % format(built or 0, ','),
      control is None and (built or 0) > 2_500_000, (control, built))
a, o = offset_j()
said = said_j(lambda: bpy.ops.transform.translate(value=(0, 0.9999, 0), orient_type='LOCAL'))
check("the redo panel's Orientation row, a script line or the Operator Search: `transform.translate(value=(0, "
      "0.9999, 0), orient_type='LOCAL')` refused, Blender at %s" % format(held_j(a) or 0, ','),
      refused_j(said) and held_j(a) == 328, said)
a, o = offset_j()
with context.temp_override_view3d("12j"):
    SC4.transform_orientation_slots[0].type = 'LOCAL'
    said = said_j(lambda: bpy.ops.transform.translate(value=(0, 0.9999, 0)))
SC4.transform_orientation_slots[0].type = 'GLOBAL'
check("and in a 3D View with the scene's Orientation Local and no `orient_type`: refused, Blender at %s"
      % format(held_j(a) or 0, ','), refused_j(said) and held_j(a) == 328, said)
a, o = offset_j()
said = said_j(lambda: bpy.ops.transform.translate(value=(0, 0.9999, 0), orient_type='GLOBAL',
                                                   orient_matrix=((0, 1, 0), (-1, 0, 0), (0, 0, 1)),
                                                   orient_matrix_type='LOCAL'))
check("ordinary: Global chosen in the redo row after a Local drag (Local's matrix left behind, which Blender "
      "works out again as Global) moves O along world Y and passes, Blender at %s" % format(held_j(a) or 0, ','),
      said is None and abs(o.location.y - 0.9999) < 1e-4 and abs(o.location.x - 1.0) < 1e-4, (said, o.location[:]))
a, o = offset_j()
said = said_j(lambda: bpy.ops.transform.translate(value=(0, 0.5, 0), orient_type='LOCAL'))
check("ordinary: a Move of 0.5 along O's Local Y (toward A) passes, Blender at %s" % format(held_j(a) or 0, ','),
      said is None and held_j(a) == 648, (said, held_j(a)))


def orientation_fixture():
    """A as above; O an empty parented to P (turned 0.6 about Z) and turned
    itself, the cursor turned: no two orientations agree."""
    reset_j()
    with bare_j():
        bpy.ops.mesh.primitive_cube_add()
        a = bpy.context.object
        a.name = "A"
        p = bpy.data.objects.new("P", None)
        SC4.collection.objects.link(p)
        p.rotation_euler = (0.0, 0.0, 0.6)
        o = bpy.data.objects.new("O", None)
        SC4.collection.objects.link(o)
        o.parent = p
        o.location = (1.0, 0.0, 0.0)
        o.rotation_euler = (0.3, 0.2, 1.1)
        SC4.cursor.rotation_euler = (0.0, 0.7, 0.4)
        m = a.modifiers.new("Array", 'ARRAY')
        m.use_relative_offset, m.use_object_offset, m.offset_object = False, True, o
        m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    select_j(o)
    return a, o


def blender_axes(o, kind):
    """The orientation's three axes in the world as Blender works them out: a
    bare Move of 1 along each, measured with the gate off and put back."""
    from mathutils import Matrix
    axes = []
    for i in range(3):
        value = [0.0, 0.0, 0.0]
        value[i] = 1.0
        with bare_j():
            start = o.matrix_world.translation.copy()
            bpy.ops.transform.translate(value=tuple(value), orient_type=kind)
        with bare_j():
            axes.append(o.matrix_world.translation - start)
            o.matrix_world.translation = start
    return Matrix((axes[0], axes[1], axes[2])).transposed()


def orientation_sweep():
    """Every orientation: a Move of O to 0.00001 of where it is from A,
    along the orientation's own axes, and a Scale to 0.00001 along each of
    its axes about A's origin with O placed on that axis — each 4,000,000 in
    Blender. [(orientation, call, axis, Blender's count)] that passed with
    Blender past the budget, and the number of calls."""
    found, calls = [], 0
    for kind in ('GLOBAL', 'LOCAL', 'NORMAL', 'GIMBAL', 'VIEW', 'CURSOR', 'PARENT'):
        for op, axis in [('translate', None)] + [('resize', i) for i in range(3)]:
            a, o = orientation_fixture()
            m = blender_axes(o, kind)
            calls += 1
            if op == 'translate':
                start = o.matrix_world.translation.copy()
                value = tuple(m.inverted_safe() @ (-0.99999 * start))
                said = said_j(lambda: bpy.ops.transform.translate(value=value, orient_type=kind))
            else:
                with bare_j():
                    o.matrix_world.translation = m.col[axis].normalized()
                value = [1.0, 1.0, 1.0]
                value[axis] = 0.00001
                said = said_j(lambda: bpy.ops.transform.resize(value=tuple(value), orient_type=kind,
                                                                center_override=(0, 0, 0)))
            if said is None:
                said = mirror_j()
            made = held_j(a) or 0
            if said is None and made > budget.BUDGET:
                found.append((kind, op, axis, made))
    return found, calls


found, calls = orientation_sweep()
check("12j.1 every orientation (Global, Local, Normal, Gimbal, View, Cursor, Parent), a Move of O toward A and a "
      "Scale to 0.00001 along each of its axes, O parented and turned and the cursor turned: Blender never past "
      "the budget unrefused (%d moves)" % calls, not found, found[:4])
with put_j(budget, '_orientation', old_orientation), put_j(gate, '_within_move', old_within_move):
    control, _ = orientation_sweep()
check("control: with 6d31b90's orientation and update, the same sweep lets %d through past the budget (%s)"
      % (len(control), ", ".join(sorted({k for k, *_ in control}))), len(control) >= 3, control[:4])

# The place priced, held to what Blender evaluates: every move whose place
# Blender worked out otherwise is priced whole in its update.
a, o = offset_j()
with put_j(budget, '_orientation', lambda keywords, constrained: __import__('mathutils').Matrix.Identity(3)):
    said = said_j(lambda: bpy.ops.transform.translate(value=(0, 0.9999, 0), orient_type='LOCAL'))
check("with the move's own price made wrong (Local priced as Global), the update Blender evaluates is held to "
      "the place priced and refused there, Blender at %s" % format(held_j(a) or 0, ','),
      refused_j(said) and held_j(a) == 328, said)

# -- j.2 priced Object Mode operators other than the moves ------------------------------
def gathered_j(n=299):
    """G: Collection Info of C -> Realize Instances; C, the active collection,
    holds M, a grid of (n + 1)²; M selected."""
    reset_j()
    with bare_j():
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2)
        m = bpy.context.object
        m.name = "M"
        c = bpy.data.collections.new("C")
        SC4.collection.children.link(c)
        for holder in list(m.users_collection):
            holder.objects.unlink(m)
        c.objects.link(m)
        bpy.ops.mesh.primitive_cube_add(location=(5, 0, 0))
        g = bpy.context.object
        g.name = "G"
        tree = bpy.data.node_groups.new("Gather", 'GeometryNodeTree')
        tree.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
        out = tree.nodes.new('NodeGroupOutput')
        info, real = tree.nodes.new('GeometryNodeCollectionInfo'), tree.nodes.new('GeometryNodeRealizeInstances')
        info.inputs['Collection'].default_value = c
        tree.links.new(info.outputs[0], real.inputs[0])
        tree.links.new(real.outputs[0], out.inputs[0])
        g.modifiers.new("GN", 'NODES').node_group = tree
    def layer_of(lc):
        if lc.collection == c:
            return lc
        for child in lc.children:
            found = layer_of(child)
            if found is not None:
                return found
        return None

    # Add ▸ Grid adds to the active collection (`bpy.context.collection`).
    bpy.context.view_layer.active_layer_collection = layer_of(bpy.context.view_layer.layer_collection)
    select_j(m)
    return g, m


OPERATIONS_J = (("Shift+D (`object.duplicate_move`)", lambda: bpy.ops.object.duplicate_move()),
                ("Duplicate Linked (`object.duplicate_move_linked`)", lambda: bpy.ops.object.duplicate_move_linked()),
                ("`object.duplicate`", lambda: bpy.ops.object.duplicate()),
                ("Add ▸ Grid in Object Mode", lambda: bpy.ops.mesh.primitive_grid_add(x_subdivisions=299,
                                                                                     y_subdivisions=299)))


def presses_j(operation):
    """Three presses: (each one's words, Blender's count of G after each, the
    collections the press left active and selected)."""
    g, m = gathered_j()
    out = []
    for _ in range(3):
        said = said_j(operation) or mirror_j()
        where = (bpy.context.collection.name, sorted({c.name for o in bpy.context.selected_objects
                                                      for c in o.users_collection}))
        out.append((said, held_j(g), where))
    return out


with budget_j(200_000):
    for label, operation in OPERATIONS_J:
        presses = presses_j(operation)
        check("12j.2 %s three times into C, which G's Collection Info realizes (a 300 × 300 grid, budget 200,000): "
              "the first passes at %s, the second is refused, Blender never past the budget (%s)"
              % (label, format(presses[0][1] or 0, ','), ", ".join(format(p[1] or 0, ',') for p in presses)),
              presses[0][0] is None and presses[0][1] == 180_000 and refused_j(presses[1][0])
              and all((p[1] or 0) <= 200_000 for p in presses), presses)
        with put_j(gate, '_object_mode', lambda: False):
            control = presses_j(operation)
        check("control: with the update compared for Edit Mode's values only, as on 6d31b90, Blender built %s"
              % ", ".join(format(p[1] or 0, ',') for p in control),
              any((p[1] or 0) > 200_000 for p in control) and all(p[0] is None for p in control), control)
# The modifier operators keep their update read for Edit Mode's values only
# (`_PRICED_WITH_READERS`): their own price reaches what reads the object.
with budget_j(300_000):
    g, m = gathered_j(199)
    with bare_j():
        g.modifiers.new("Array", 'ARRAY').count = 3
    select_j(m)
    said = said_j(lambda: bpy.ops.object.modifier_add(type='SUBSURF')) or mirror_j()
check("12j.2 Add Modifier ▸ Subdivision Surface on M (159,201, inside a budget of 300,000) where G makes three of "
      "what it realizes (477,603): refused by the operator's own price, Blender at %s" % format(held_j(g) or 0, ','),
      refused_j(said, 477_603) and held_j(g) == 120_000 and not len(m.modifiers), (said, held_j(g)))
g, m = gathered_j(1000)
said = said_j(lambda: bpy.ops.object.duplicate_move()) or mirror_j()
check("12j.2 at the real budget, the review's case: Shift+D of a 1000 × 1000 grid in C passes once (G %s)"
      % format(held_j(g) or 0, ','), said is None and held_j(g) == 2_004_002, (said, held_j(g)))
said = said_j(lambda: bpy.ops.object.duplicate_move()) or mirror_j()
check("and the second is refused, Blender at %s" % format(held_j(g) or 0, ','),
      refused_j(said) and (held_j(g) or 0) <= 2_500_000, (said, held_j(g)))

# -- j.3 Single Property drivers of derived values -------------------------------------
def derived_j(kind):
    """A: a cube under an Array whose Count a driver works out as x × 40,000
    + 2, x = E's `matrix_world[3][0]` (16 vertices); or x × 20,000, x = T's
    `dimensions[0]` (a cube of 2: 320,000). E or T selected."""
    reset_j()
    with bare_j():
        bpy.ops.mesh.primitive_cube_add()
        a = bpy.context.object
        a.name = "A"
        m = a.modifiers.new("Array", 'ARRAY')
        m.count = 2
        if kind == 'matrix_world':
            bpy.ops.object.empty_add(location=(0, 0, 0))
            e = bpy.context.object
            e.name = "E"
            path, expression = 'matrix_world[3][0]', 'x*40000+2'
        else:
            bpy.ops.mesh.primitive_cube_add(location=(5, 5, 0))
            e = bpy.context.object
            e.name = "T"
            path, expression = 'dimensions[0]', 'x*20000'
        curve = m.driver_add('count')
        variable = curve.driver.variables.new()
        variable.name, variable.type = 'x', 'SINGLE_PROP'
        variable.targets[0].id, variable.targets[0].data_path = e, path
        curve.driver.expression = expression
    select_j(e)
    return a, e


DERIVED_J = (('matrix_world', 'location', (10.0, 0.0, 0.0), 16, 3_200_016,
              lambda e: bpy.ops.transform.translate(value=(10, 0, 0))),
             ('dimensions', 'scale', (10.0, 1.0, 1.0), 320_000, 3_200_000,
              lambda e: bpy.ops.transform.resize(value=(10, 1, 1))))
for kind, key, value, start, past, operate in DERIVED_J:
    ways = {}
    a, e = derived_j(kind)
    ways['the Data API row'] = (said_j(lambda: sync.set_property('bpy.data.objects["%s"]' % e.name, key, value)),
                                held_j(a))
    a, e = derived_j(kind)
    ways['a script line'] = (line_j('bpy.data.objects["%s"].%s = %r' % (e.name, key, value)), held_j(a))
    a, e = derived_j(kind)
    ways['the operator'] = (said_j(lambda: operate(e)) or mirror_j(), held_j(a))
    check("12j.3 a Count driven through E's %s: the row, a line and %s are each refused, Blender at %s"
          % (kind, "a Move" if kind == 'matrix_world' else "a Resize",
             ", ".join(format(v[1] or 0, ',') for v in ways.values())),
          all(refused_j(v[0], past) and v[1] == start for v in ways.values()), ways)
    with put_j(budget, '_derived_path', lambda path: False):
        a, e = derived_j(kind)
        control = said_j(lambda: sync.set_property('bpy.data.objects["%s"]' % e.name, key, value))
        built = held_j(a)
    check("control: with %s read from the original, as on 6d31b90, the row passed and Blender built %s"
          % (kind, format(built or 0, ',')), control is None and built == past, (control, built))
a, e = derived_j('matrix_world')
said = said_j(lambda: sync.set_property('bpy.data.objects["E"]', 'location', (0.0001, 0.0, 0.0)))
check("ordinary: the row's Location 0.0001 (Count 6) passes, Blender at %s" % format(held_j(a) or 0, ','),
      said is None and held_j(a) == 48, (said, held_j(a)))

# -- j.4 a texture's colour ramp -------------------------------------------------------
STRENGTH_J = math.sqrt(3.0) * (1.0 - 5e-5) / 0.25


def ramp_j():
    """T: a cube under a Displace along its normals reading a Blend texture at
    Contrast 0 through a colour ramp held at grey 0.5 (its two stops), then
    an Array fitted to 40 (168): both stops at grey 0.25 make it 0.0001 m
    wide (3,199,472)."""
    reset_j()
    with bare_j():
        bpy.ops.mesh.primitive_cube_add()
        t = bpy.context.object
        t.name = "T"
        texture = bpy.data.textures.new("TD", 'BLEND')
        texture.contrast = 0.0
        texture.use_color_ramp = True
        for stop in texture.color_ramp.elements:
            stop.color = (0.5, 0.5, 0.5, 1.0)
        d = t.modifiers.new("Displace", 'DISPLACE')
        d.texture, d.direction, d.strength, d.mid_level = texture, 'NORMAL', STRENGTH_J, 0.5
        arr = t.modifiers.new("Array", 'ARRAY')
        arr.fit_type, arr.fit_length = 'FIT_LENGTH', 40.0
    return t, texture


GREY_J = 'for e in bpy.data.textures["TD"].color_ramp.elements: e.color = (0.25, 0.25, 0.25, 1.0)'
STOP_J = 'e = bpy.data.textures["TD"].color_ramp.elements.new(0.5)\ne.color = (0.25, 0.25, 0.25, 1.0)'
t, texture = ramp_j()
said = line_j(GREY_J)
check("12j.4 a script line setting both colour ramp stops to grey 0.25: refused, Blender at %s and the stops back "
      "at %.2f" % (format(held_j(t) or 0, ','), texture.color_ramp.elements[0].color[0]),
      refused_j(said) and held_j(t) == 168 and abs(texture.color_ramp.elements[0].color[0] - 0.5) < 1e-6, said)
t, texture = ramp_j()
said = said_j(lambda: sync.set_property('bpy.data.textures["TD"].color_ramp.elements[0]', 'color', (0, 0, 0, 1)))
check("and the Data API row's first stop at black (the ramp 0.25 where the texture reads 0.5): refused, Blender at "
      "%s" % format(held_j(t) or 0, ','), refused_j(said) and held_j(t) == 168, said)
t, texture = ramp_j()
said = line_j(STOP_J)
check("and a stop of grey 0.25 added at 0.5 by a script line: refused, T's modifiers hidden (Blender at %s)"
      % format(held_j(t) or 0, ','), refused_j(said) and (held_j(t) or 0) <= 168, (said, held_j(t)))
t, texture = ramp_j()
said = line_j(GREY_J.replace("0.25", "0.45"))
check("ordinary: both stops at grey 0.45 pass, Blender at %s" % format(held_j(t) or 0, ','),
      said is None and 168 < (held_j(t) or 0) < 2_500_000, said)
with put_j(gate, '_NEVER', gate._NEVER | {'color'}):
    gate._props_cache.clear()
    t, texture = ramp_j()
    control = line_j(GREY_J)
    built = held_j(t)
gate._props_cache.clear()
check("control: with every colour left out of the gate, as on 6d31b90, the line passed and Blender built %s"
      % format(built or 0, ','), control is None and (built or 0) > 2_500_000, (control, built))
with put_j(budget, '_item_readers', lambda struct: []):
    t, texture = ramp_j()
    control = line_j(STOP_J)
    built = held_j(t)
check("control: with a stop added to a texture's ramp reaching no object, the line passed and Blender built %s"
      % format(built or 0, ','), control is None and (built or 0) > 2_500_000, (control, built))

# An object's own display Color is compared now too, where a driver reads it.
reset_j()
with bare_j():
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "A"
    m = a.modifiers.new("Array", 'ARRAY')
    bpy.ops.object.empty_add(location=(4, 0, 0))
    e = bpy.context.object
    e.name = "E"
    e.color = (0.0, 0.0, 0.0, 1.0)
    curve = m.driver_add('count')
    variable = curve.driver.variables.new()
    variable.name, variable.type = 'x', 'SINGLE_PROP'
    variable.targets[0].id, variable.targets[0].data_path = e, 'color[0]'
    curve.driver.expression = 'x*400000+2'
said = line_j('bpy.data.objects["E"].color[0] = 1.0')
check("12j.4 a Count driven by E's display Color (x × 400,000 + 2): a script line setting its red to 1 is refused, "
      "Blender at %s" % format(held_j(a) or 0, ','), refused_j(said) and held_j(a) == 16, said)
with put_j(gate, '_display_colour', lambda change: True):
    with bare_j():
        e.color = (0.0, 0.0, 0.0, 1.0)
    control = line_j('bpy.data.objects["E"].color[0] = 1.0')
    built = held_j(a)
check("control: with an object's display Color left unpriced whoever reads it, the line passed and Blender built %s"
      % format(built or 0, ','), control is None and built == 3_200_016, (control, built))

# -- j.5 empties that instance a collection --------------------------------------------
def instancing_j(kind='COLLECTION', n=999, empties=3):
    """D holds a grid of (n + 1)²; C holds `empties` empties instancing D
    (Instancing `kind`); G a cube, no modifier yet."""
    reset_j()
    with bare_j():
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2)
        grid = bpy.context.object
        grid.name = "Grid"
        d = bpy.data.collections.new("D")
        SC4.collection.children.link(d)
        for holder in list(grid.users_collection):
            holder.objects.unlink(grid)
        d.objects.link(grid)
        c = bpy.data.collections.new("C")
        SC4.collection.children.link(c)
        for i in range(empties):
            e = bpy.data.objects.new("I%d" % i, None)
            e.instance_type, e.instance_collection = kind, d
            c.objects.link(e)
        bpy.ops.mesh.primitive_cube_add(location=(5, 0, 0))
        g = bpy.context.object
        g.name = "G"
    return g, grid


GATHER_J = '''g = bpy.data.objects["G"]
tree = bpy.data.node_groups.new("Gather", 'GeometryNodeTree')
tree.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
out = tree.nodes.new('NodeGroupOutput')
info, real = tree.nodes.new('GeometryNodeCollectionInfo'), tree.nodes.new('GeometryNodeRealizeInstances')
info.inputs['Collection'].default_value = bpy.data.collections["C"]
info.inputs['Separate Children'].default_value = %s
tree.links.new(info.outputs[0], real.inputs[0])
tree.links.new(real.outputs[0], out.inputs[0])
g.modifiers.new("GN", 'NODES').node_group = tree
'''
def holding_j():
    """What C and D hold, and where the grid is, for a failure's words."""
    found = {}
    for name in ("C", "D"):
        c = bpy.data.collections.get(name)
        found[name] = None if c is None else [(o.name, o.type, getattr(o.instance_collection, 'name', None))
                                              for o in c.all_objects]
    found['collections'] = [c.name for c in bpy.data.collections]
    found['scene'] = (bpy.context.scene.name, bpy.context.view_layer.name,
                      [c.name for c in bpy.context.scene.collection.children])
    return found


g, grid = instancing_j()
said = line_j(GATHER_J % "False")
check("12j.5 one script line: Collection Info of C -> Realize Instances, C holding three empties that instance D "
      "(a 1000 × 1000 grid): refused at 3,000,000, G at %s" % format(held_j(g) or 0, ','),
      refused_j(said, 3_000_000) and held_j(g) == 8, (said, holding_j()))
with put_j(budget, '_collection_instance', lambda *args: None), \
        put_j(budget, '_with_instanced', lambda objects: set(objects)):
    g, grid = instancing_j()
    control = line_j(GATHER_J % "False")
    built = held_j(g)
check("control: with an instancing empty counted as nothing, as on 6d31b90, the line passed and Blender built %s"
      % format(built or 0, ','), control is None and built == 3_000_000, (control, built))
for kind, separate in (('NONE', "False"), ('COLLECTION', "True")):
    g, grid = instancing_j(kind, n=99)
    with budget_j(29_999):
        said = line_j(GATHER_J % separate)
    with bare_j():
        g.modifiers["GN"].show_viewport = True
    check("and with the empties' Instancing %s, Separate Children %s (three grids of 10,000 at a budget of 29,999): "
          "refused, Blender building %s with it shown" % (kind.title(), separate, format(held_j(g) or 0, ',')),
          refused_j(said, 30_000) and held_j(g) == 30_000, said)
g, grid = instancing_j(n=99)
with bare_j():
    exec(compile(GATHER_J % "False", "<fixture>", "exec"), {"bpy": bpy})
with budget_j(300_000):
    said = line_j('bpy.data.objects["Grid"].modifiers.new("Subdivision", "SUBSURF").levels = 2')
check("and D's grid given a Subdivision of 2 by a script line (157,609, inside a budget of 300,000), G reading it "
      "through the empties (30,000 -> 472,827): refused, Blender at %s" % format(held_j(g) or 0, ','),
      refused_j(said, 472_827) and held_j(g) == 30_000, said)

# -- j.6 Fast's own time ---------------------------------------------------------------
def fast_j(n, threshold=1e-6):
    """A and B, n × n grids under a Solidify of 0.05, B half a cell over and
    tilted 0.002 rad on A's plane; A's Boolean Union, Fast, at `threshold`."""
    reset_j()
    with bare_j():
        made = []
        for name, place in (("A", (0, 0, 0)), ("B", (1.0 / n, 1.0 / n, 0.0))):
            bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2, location=place)
            obj = bpy.context.object
            obj.name = name
            obj.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.05
            made.append(obj)
        a, b = made
        b.rotation_euler.x = 0.002
        m = a.modifiers.new("Boolean", 'BOOLEAN')
        m.operation, m.solver, m.double_threshold, m.object = 'UNION', 'FLOAT', threshold, b
    return a, b, m


ROW_J = "bpy.data.objects['A'].modifiers['Boolean']"
for n, value, blender in ((40, 0.05, "18.3 to 27.3 s"), (40, 0.01, "3.9 to 5.6 s"), (80, 0.05, "248.7 s")):
    a, b, m = fast_j(n)
    before = held_j(a)
    started = time.perf_counter()
    said = said_j(lambda: sync.set_property(ROW_J, 'double_threshold', value))
    took = time.perf_counter() - started
    check("12j.6 two %d × %d grids, the Data API row's Overlap Threshold 1e-6 -> %g (Blender's own Fast measured "
          "%s): refused for its time in %.2f s, nothing evaluated (Blender at %s, the threshold %g)"
          % (n, n, value, blender, took, format(held_j(a) or 0, ','), m.double_threshold),
          said is not None and "Fast solver" in said and took < 3.0 and held_j(a) == before
          and abs(m.double_threshold - 1e-6) < 1e-9, (said, took, before, held_j(a)))
a, b, m = fast_j(20)
started = time.perf_counter()
said = said_j(lambda: sync.set_property(ROW_J, 'double_threshold', 0.05))
took = time.perf_counter() - started
check("ordinary: two 20 × 20 grids at 0.05 (Blender's own Fast about 1.1 to 1.9 s) pass, in %.2f s" % took,
      said is None and abs(m.double_threshold - 0.05) < 1e-6, said)
with put_j(budget, 'FAST_SECONDS', float('inf')):
    a, b, m = fast_j(40)
    started = time.perf_counter()
    control = said_j(lambda: sync.set_property(ROW_J, 'double_threshold', 0.01))
    took = time.perf_counter() - started
check("control: with Blender's Fast time not priced, as on 6d31b90, the row's 0.01 on 40 × 40 grids passed and "
      "took %.2f s (the price asked Blender for its own Fast evaluation)" % took,
      control is None and took > 2.0, (control, took))

# -- j.7 an ordinary edit under Self Intersection ----------------------------------------
reset_j()
with bare_j():
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=199, y_subdivisions=199, size=2)
    a = bpy.context.object
    a.name = "A"
    a.modifiers.new("Solidify", 'SOLIDIFY').thickness = 0.05
    bpy.ops.mesh.primitive_cube_add(location=(20, 0, 0))
    far = bpy.context.object
    far.name = "Far"
    m = a.modifiers.new("Boolean", 'BOOLEAN')
    m.operation, m.solver, m.use_self, m.object = 'UNION', 'EXACT', True, far
own = None
for step in range(2):
    gate._busy += 1
    try:
        far.location.x = 20.1 + 0.1 * step
        started = time.perf_counter()
        bpy.context.view_layer.update()
        took = time.perf_counter() - started
    finally:
        gate._busy -= 1
    own = took if own is None else min(own, took)
row = None
for step in range(2):
    started = time.perf_counter()
    said = said_j(lambda: sync.set_property('bpy.data.objects["Far"]', 'location', (21.0 + 0.1 * step, 0.0, 0.0)))
    took = time.perf_counter() - started
    row = took if row is None else min(row, took)
print("        Self Intersection, %s vertices: the row %.2f s, Blender's own evaluation %.2f s"
      % (format(held_j(a) or 0, ','), row, own))
check("12j.7 an ordinary edit under Self Intersection (the row's Location of a far operand of an 80,000-vertex "
      "Exact Union): passes in at most 3× Blender's own evaluation (%.2f s against %.2f s)" % (row, own),
      said is None and row <= 3.0 * own + 0.1, (said, row, own))
# The material picker's write (`BpyBridge.setMaterial`), which sets the
# object's display Color too: no price of the Boolean for a colour.
PICK_J = """_o = bpy.data.objects["A"]
_m = bpy.data.materials.get("A Material") or bpy.data.materials.new("A Material")
_m.diffuse_color = (0.2, 0.4, 0.1, 1.0)
if _o.data.materials:
    _o.data.materials[0] = _m
else:
    _o.data.materials.append(_m)
_o.color = (0.2, 0.4, 0.1, 1.0)
"""
judged = {'n': 0}
real_judge = budget._judge


def counting_judge(*args, **kwargs):
    judged['n'] += 1
    return real_judge(*args, **kwargs)


budget._judge = counting_judge
try:
    started = time.perf_counter()
    said = line_j(PICK_J)
    took = time.perf_counter() - started
finally:
    budget._judge = real_judge
# Deterministic, where the time is not under other work: a price of the
# object is a `_judge` of it (the row's above made Blender's Boolean twice).
check("ordinary: the material picker's colour on that object, its display Color with it, passes with no price of "
      "the Boolean (%d judgements; %.2f s for the line and the mirror's pass, Blender's own evaluation %.2f s)"
      % (judged['n'], took, own), said is None and judged['n'] == 0, (said, judged['n'], took))
with put_j(gate, '_display_colour', lambda change: False):
    judged['n'] = 0
    budget._judge = counting_judge
    try:
        line_j(PICK_J.replace("0.2, 0.4, 0.1", "0.3, 0.4, 0.1"))
    finally:
        budget._judge = real_judge
check("control: with every display Color priced, the same pick judges the object (%d judgements)" % judged['n'],
      judged['n'] > 0, judged['n'])

# -- j.8 the sweep's new fixtures, with this round's fixes taken out ----------------------
if "sweep2" not in globals():
    print("  SKIP  12j.8 needs part 12's sweep (sweep2.py), which part 12 runs before this")
else:
    with put_j(gate, '_NEVER', gate._NEVER | {'color'}), put_j(budget, '_derived_path', lambda path: False), \
            put_j(budget, '_collection_instance', lambda *args: None), \
            put_j(budget, '_with_instanced', lambda objects: set(objects)):
        gate._props_cache.clear()
        gaps, _ = sweep2(gated=True, only=CONTROL_ROUND3B, paths=False)
    gate._props_cache.clear()
    settings = {(f[0], f[1]) for f in gaps}
    check("12j.8 sweep2's four new settings with the gate on and this round's fixes taken out: the sweep finds %d of "
          "%d past the budget" % (len(settings), len(CONTROL_ROUND3B)), settings == CONTROL_ROUND3B,
          sorted(CONTROL_ROUND3B - settings))
reset_j()
