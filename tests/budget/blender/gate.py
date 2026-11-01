"""Part 9 of the vertex budget's Blender check: the gate (_blenderkit_gate.py,
round 4's fix round 2, October 21).

Run from verify.py, in its globals (its fixtures, `run`, `counts`, `check`,
`blocks` from the Swift, `gate_off`). Every class round 4's second fix-round
review measured going round the budget, each through the app's own string or
function, refused before Blender evaluates it — Blender's count stays what it
was — and with a control: the same done with the gate off, where Blender
makes the review's count. Then ordinary edits, and the sweep of every
writable setting of the objects, constraints, pose bones, shape keys, curve
and metaball data on fixtures whose counts hang on them, written bare as a
script line writes them: the check fails any step after which Blender's own
evaluated count is past the budget and more than before.

Nothing here opens a window, a browser or another app.
"""
import bpy, bmesh, math, time

constraints_module = load("_blenderkit_constraints")
groups_module = load("_blenderkit_groups")
meshmenu_module = load("_blenderkit_meshmenu")
BUDGET = budget.BUDGET


class unpriced_operators:
    """The operator factory with no priced operators and no priced adds: the
    control."""
    def __enter__(self):
        self.kept = context.PRICED_OPERATORS, context.PRICED_ADDS
        context.PRICED_OPERATORS, context.PRICED_ADDS = (), ()

    def __exit__(self, *exc):
        context.PRICED_OPERATORS, context.PRICED_ADDS = self.kept


def refused_number(said):
    """The count a refusal names, or None."""
    import re
    found = re.search(r"would give \S+ ([0-9,]+) vertices", said or "")
    return int(found.group(1).replace(",", "")) if found else None


class gate_off_settled(gate_off):
    """`gate_off`, and what was written inside it evaluated before the gate
    is back on: a control's own state is then what Blender holds, and the
    gate's next refusal puts back nothing of it."""

    def __exit__(self, *exc):
        try:
            bpy.context.view_layer.update()
        finally:
            gate._busy -= 1


def said_of(fn):
    try:
        fn()
    except RuntimeError as error:
        return str(error)
    return None


def mirror_pass():
    """What the app runs after every command: the mirror, whose first act is
    the gate (`_blenderkit_sync.sync`). Returns the refusal it raised."""
    try:
        sync.sync()
    except RuntimeError as error:
        return str(error)
    return None


def command(source):
    """A command as the app sends it: the run, then the mirror. The refusal,
    if either raised one."""
    said = run(source)
    after = mirror_pass()
    return said or after


def fitted(length=40.0, at=(1.0, 0.0, 0.0), vertex_only=False, name="A", offset_name="O"):
    """A cube (or one vertex) under an Array fitted to `length` whose offset is
    the empty O: every move of O towards A multiplies A."""
    if vertex_only:
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata([(0.0, 0.0, 0.0)], [], [])
        a = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(a)
    else:
        bpy.ops.mesh.primitive_cube_add()
        a = bpy.context.object
        a.name = name
    bpy.ops.object.empty_add(location=at)
    o = bpy.context.object
    o.name = offset_name
    m = a.modifiers.new("Array", 'ARRAY')
    m.use_relative_offset = False
    m.use_object_offset = True
    m.offset_object = o
    m.fit_type = 'FIT_LENGTH'
    m.fit_length = length
    bpy.context.view_layer.update()
    return a, o


def select(*objects, active=None):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objects[-1]


def refused_at(said, number):
    return said is not None and format(number, ',') in said


print("\n9. the gate: every write priced as the state it leaves, before Blender evaluates it")

# -- shape keys ---------------------------------------------------------------
clear()
bpy.ops.mesh.primitive_cube_add()
b = bpy.context.object
b.name = "B"
m = b.modifiers.new("Array", 'ARRAY')
m.fit_type = 'FIT_LENGTH'
m.fit_length = 40.0
b.shape_key_add(name="Basis")
thin = b.shape_key_add(name="Thin")
thin.value = 0.0
for point in thin.data:
    point.co.x *= 0.00005
activate(b)
bpy.context.view_layer.update()
check("9.1 a cube with a key Thin (x × 0.00005) under an Array fitted to 40: 168", counts(b)[0] == 168, counts(b))
said = command(blocks["KEY THIN VALUE 1"])
check("the Shape Keys panel's Value 1 (`set_key`) is refused at 3,199,480, Blender's count stays 168",
      refused_at(said, 3_199_480) and counts(b)[0] == 168 and thin.value == 0.0, said)
with gate_off_settled():
    run(blocks["KEY THIN VALUE 1"])
    check("control: with the gate off, Blender makes %s" % format(counts(b)[0], ','), counts(b)[0] == 3_199_472)
    thin.value = 0.0
said = command(blocks["KEY ACTIVE THIN"] + "\n" + blocks["KEY SOLO ON"])
check("Solo Active Shape Key on Thin is refused at 3,200,008, Blender's count stays 168",
      refused_at(said, 3_200_008) and counts(b)[0] == 168 and not b.show_only_shape_key, said)
with gate_off_settled():
    run(blocks["KEY ACTIVE THIN"] + "\n" + blocks["KEY SOLO ON"])
    check("control: with the gate off, Solo makes %s" % format(counts(b)[0], ','), counts(b)[0] == 3_200_008)
    b.show_only_shape_key = False
# A key at Value 1 and muted adds nothing until its Mute is turned off (the
# panel's checkbox): the gate once skipped every `mute`, a constraint's alias.
muted = b.shape_key_add(name="Muted")
for point, base in zip(muted.data, thin.data):
    point.co = base.co
muted.value = 1.0
muted.mute = True
bpy.context.view_layer.update()
said = command(blocks["KEY MUTED UNMUTE"])
check("the Shape Keys panel's Mute off on a key Muted at Value 1 (as Thin) is refused at 3,199,480, "
      "Blender's count stays 168", refused_at(said, 3_199_480) and counts(b)[0] == 168 and muted.mute, said)
with gate_off_settled():
    run(blocks["KEY MUTED UNMUTE"])
    check("control: with the gate off, Blender makes %s" % format(counts(b)[0], ','), counts(b)[0] == 3_199_472)
    muted.mute = True
b.shape_key_remove(muted)
bpy.context.view_layer.update()
clear()
bpy.ops.mesh.primitive_cube_add()
c = bpy.context.object
c.name = "C"
c.shape_key_add(name="Basis")
big = c.shape_key_add(name="Big")
big.value = 0.0
for point in big.data:
    point.co *= 50.0
c.modifiers.new("Remesh", 'REMESH').voxel_size = 0.1
activate(c)
bpy.context.view_layer.update()
held = counts(c)[0]
said = said_of(lambda: sync.set_property("bpy.data.shape_keys[%r].key_blocks['Big']" % c.data.shape_keys.name,
                                         "value", 1.0))
check("the Data API row's key Value 1 (× 50) under a Remesh at 0.1 is refused, Blender's count stays %d" % held,
      said is not None and "2,500,000" in said and counts(c)[0] == held, said)
check("and the budget counts the key as Blender does (%s against %s)" % (
    format(budget.stack_vertices(c), ','), format(held, ',')), budget.stack_vertices(c) >= held)

# -- constraints --------------------------------------------------------------
clear()
a, o = fitted()
t = bpy.data.objects.new("T", None)
bpy.context.scene.collection.objects.link(t)
t.location = (0.0001, 0.0, 0.0)
select(o)
bpy.context.view_layer.update()
said = command(blocks["CONSTRAINT ADD COPY_LOCATION"] + "\n" + blocks["CONSTRAINT TARGET T"])
check("9.2 the Constraints tab's Copy Location with Target T at 0.0001 m is refused at 3,200,008",
      refused_at(said, 3_200_008) and counts(a)[0] == 328 and o.constraints[0].target is None, said)
with gate_off_settled():
    run(blocks["CONSTRAINT TARGET T"])
    check("control: with the gate off, Blender makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_008)
    o.constraints[0].target = None
o.constraints[0].target = t
o.constraints[0].influence = 0.0
mirror_pass()
said = said_of(lambda: sync.set_property("bpy.data.objects['O'].constraints['Copy Location']", "influence", 1.0))
check("the Data API row's Influence 0 → 1 is refused at 3,200,008", refused_at(said, 3_200_008)
      and counts(a)[0] == 328, said)
said = command(blocks["CONSTRAINT INFLUENCE 1"])
check("the tab's own Influence 1 is refused at 3,200,008", refused_at(said, 3_200_008) and counts(a)[0] == 328, said)
# A pass is reused only for the state it priced. Found by this round's own
# run of the app's functions: a Target set at Influence 0 passed, the
# Influence went back to the 1.0 Blender had last evaluated, the Target alone
# was left waiting — passed already — and Blender built 3,200,008.
clear()
a, o = fitted()
t = bpy.data.objects.new("T", None)
bpy.context.scene.collection.objects.link(t)
t.location = (0.0001, 0.0, 0.0)
o.constraints.new('COPY_LOCATION')
mirror_pass()
o.constraints[0].influence = 0.0
o.constraints[0].target = t
said = said_of(gate.gate)
check("a Copy Location's Target at Influence 0 passes, nothing evaluated yet", said is None, said)
o.constraints[0].influence = 1.0
said = mirror_pass()
check("then its Influence back to the 1.0 Blender last evaluated is refused at 3,200,008 (a pass is not reused "
      "for another state)", refused_at(said, 3_200_008) and counts(a)[0] == 328, said)
clear()
a, o = fitted()
o.constraints.new('LIMIT_ROTATION')
bpy.context.view_layer.update()
constraints_module.drag_begin()
said = said_of(lambda: constraints_module.drag_frame('bpy.data.objects["O"].location[0] = 0.0001'))
check("the Transform fields' constrained preview frame at 0.0001 is refused inside the frame; Blender stays at 328",
      refused_at(said, 3_200_008) and counts(a)[0] == 328, said)
constraints_module.drag_end()
with gate_off_settled():
    constraints_module.drag_begin()
    constraints_module.drag_frame('bpy.data.objects["O"].location[0] = 0.0001')
    check("control: with the gate off, the preview frame builds %s" % format(counts(a)[0], ','),
          counts(a)[0] == 3_200_008)
    constraints_module.drag_end()
clear()
a, o = fitted()
bpy.ops.object.empty_add(location=(0.0001, 0, 0))
t = bpy.context.object
t.name = "T"
bpy.ops.object.empty_add(location=(5, 0, 0))
src = bpy.context.object
src.name = "S"
src.constraints.new('COPY_LOCATION').target = t
select(o, src, active=src)
bpy.context.view_layer.update()
said = command("bpy.ops.object.constraints_copy()")
check("Copy Constraints to Selected Objects (a script line) is refused at 3,200,008", refused_at(said, 3_200_008)
      and counts(a)[0] == 328, said)

# -- Object Mode moves outside the priced ones ----------------------------------
clear()
# Fitted to 80: the app's Shear string carries the angle to four places
# (0.7853 rad), which slides O to 0.000196 m, not the review's 0.0001.
a, o = fitted(length=80.0, at=(1.0, 1.0, 0.0))
a.location = (0.0, 1.0, 0.0)
select(o)
bpy.context.scene.tool_settings.transform_pivot_point = 'CURSOR'
bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
bpy.context.view_layer.update()
said = command(blocks["SHEAR OBJECTS"])
sheared_at = refused_number(said)
check("9.3 Object ▸ Transform ▸ Shear sliding O to 0.0002 m of A is refused (%s), O and A where they were"
      % (format(sheared_at, ',') if sheared_at else None),
      sheared_at is not None and sheared_at > BUDGET and counts(a)[0] == 648 and tuple(o.location) == (1.0, 1.0, 0.0),
      (said, tuple(o.location)))
with gate_off_settled():
    run(blocks["SHEAR OBJECTS"])
    made = counts(a)[0]
    # The price's arithmetic and Blender's round the slid offset apart by a
    # copy at most (measured: 3,260,688 refused, 3,260,680 made; 8 a copy).
    check("control: with the gate off, Shear takes O to x %.6f and Blender makes %s, the count refused or a copy "
          "under it" % (o.location.x, format(made, ',')), sheared_at is not None and 0 <= sheared_at - made <= 8)
bpy.context.scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
clear()
a, o = fitted()
bpy.ops.object.empty_add(location=(5, 0, 0))
p = bpy.context.object
p.name = "P"
bpy.ops.object.empty_add()
q = bpy.context.object
q.name = "Q"
o.parent = p
o.matrix_parent_inverse.identity()
o.location = (0.0001, 0.0, 0.0)
select(o, q, active=q)
bpy.context.view_layer.update()
held = counts(a)[0]
said = command(blocks["PARENT KEEP OFF"])
check("Object ▸ Parent with Keep Transform off, dropping the old parent's 5 m, is refused at 3,200,008",
      refused_at(said, 3_200_008) and counts(a)[0] == held and o.parent == p, said)
with gate_off_settled():
    run(blocks["PARENT KEEP OFF"])
    check("control: with the gate off, Blender makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_008)
clear()
a, o = fitted()
select(o)
said = command(blocks["SEARCH TRANSFORM TRANSLATION"])
check("the Operator Search's transform.transform (TRANSLATION, -0.9999) is refused at 3,199,480",
      refused_at(said, 3_199_480) and counts(a)[0] == 328, said)

# -- a curve's Join -----------------------------------------------------------
clear()
bpy.ops.curve.primitive_bezier_curve_add()
wire = bpy.context.object
wire.name = "Wire"
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.curve.select_all(action='SELECT')
bpy.ops.curve.subdivide(number_cuts=255)
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.curve.primitive_bezier_curve_add(location=(0, 3, 0))
bevelled = bpy.context.object
bevelled.name = "Bevelled"
bevelled.data.bevel_depth = 0.05
bevelled.data.bevel_resolution = 10
bevelled.modifiers.new("Array", 'ARRAY').count = 40
select(wire, bevelled, active=bevelled)
bpy.context.view_layer.update()
said = command(blocks["JOIN CURVES"])
joined_at = refused_number(said)
check("9.4 Object ▸ Join of a wire of 257 points into a curve with Bevel Depth 0.05 under an Array of 40 is "
      "refused (%s: the bevel the joined splines take)" % (format(joined_at, ',') if joined_at else None),
      joined_at is not None and joined_at > BUDGET and len(bpy.data.objects) == 2, said)
with unpriced_operators(), gate_off_settled():
    run(blocks["JOIN CURVES"])
    check("control: bare, Blender makes %s, the count refused" % format(counts(bevelled)[0], ','),
          counts(bevelled)[0] == joined_at)

# -- Edit Mode ----------------------------------------------------------------
clear()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
cube.name = "Cube"
cube.modifiers.new("Subdivision", 'SUBSURF').levels = 6
bpy.ops.object.mode_set(mode='EDIT')
saids = [command("bpy.ops.mesh.primitive_monkey_add()") for _ in range(3)]
bpy.ops.object.mode_set(mode='OBJECT')
check("9.5 Edit Mode Add ▸ Monkey into a cube under Subdivision 6: the first passes, the next two refused "
      "(4,057,734), Blender at %s" % format(counts(cube)[0], ','),
      saids[0] is None and all(refused_at(x, 4_057_734) for x in saids[1:]) and counts(cube)[0] == 2_041_156, saids)
clear()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
cube.modifiers.new("Subdivision", 'SUBSURF').levels = 6
bpy.ops.object.mode_set(mode='EDIT')
with unpriced_operators(), gate_off_settled():
    for _ in range(3):
        bpy.ops.mesh.primitive_monkey_add()
    bpy.ops.object.mode_set(mode='OBJECT')
    check("control: bare, three presses make %s" % format(counts(cube)[0], ','), counts(cube)[0] == 6_074_312)


def ngon_sides(obj):
    obj.update_from_editmode()
    return max((len(p.vertices) for p in obj.data.polygons), default=0)


clear()
bpy.ops.mesh.primitive_grid_add(x_subdivisions=63, y_subdivisions=63)
grid = bpy.context.object
grid.modifiers.new("Subdivision", 'SUBSURF').levels = 1
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
said = command(blocks["DISSOLVE FACES"])
check("Edit Mode Dissolve Faces on a 63 × 63 grid under Subdivision 1 (one 252-gon) is refused for the limit "
      "surface's time, the faces put back", said is not None and "limit surface" in said
      and ngon_sides(grid) == 4 and len(grid.data.polygons) == 3969, said)
with gate_off_settled():
    grid.modifiers[0].show_viewport = False
    run(blocks["DISSOLVE FACES"])
    check("control: with the gate off, Dissolve Faces leaves a %d-gon under the Subdivision" % ngon_sides(grid),
          ngon_sides(grid) == 252)
bpy.ops.object.mode_set(mode='OBJECT')
clear()
bpy.ops.mesh.primitive_circle_add(vertices=250, fill_type='NOTHING')
ring = bpy.context.object
ring.modifiers.new("Subdivision", 'SUBSURF').levels = 1
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
said = command(blocks["FILL"])
check("Edit Mode Fill on a 250-vertex wire circle under Subdivision 1 is refused for the limit surface's time",
      said is not None and "limit surface" in said and ngon_sides(ring) == 0, said)
with gate_off_settled():
    started = time.time()
    run(blocks["FILL"])
    bpy.ops.object.mode_set(mode='OBJECT')
    counts(ring)
    took = time.time() - started
check("control: with the gate off, Fill and the Subdivision's build take %.1f s" % took, took > 5.0)
clear()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
cube.modifiers.new("Subdivision", 'SUBSURF').levels = 1
bpy.ops.object.mode_set(mode='EDIT')
said = command("bpy.ops.mesh.primitive_circle_add(vertices=250, fill_type='NGON')")
check("Edit Mode Add ▸ Circle of 250 as an N-Gon into a cube under Subdivision 1 is refused for the time",
      said is not None and "limit surface" in said and ngon_sides(cube) == 4, said)
bpy.ops.object.mode_set(mode='OBJECT')
clear()
bpy.ops.mesh.primitive_circle_add(vertices=250, fill_type='NGON')
ngon = bpy.context.object
ngon.modifiers.new("Multires", 'MULTIRES')
said = command(blocks["SEARCH MULTIRES SUBDIVIDE"])
check("Multires Subdivide on a 250-gon (the search) is refused for the limit surface's time",
      said is not None and "limit surface" in said and ngon.modifiers[0].total_levels == 0, said)

# An Edit Mode move: the gizmo's Resize commit as the app sends it, on a cube
# under an Array fitted to 100 with every vertex selected. Measured before the
# gate held moves (`EDIT_MOVES`): nothing priced it.
clear()
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
cube.name = "Cube"
array = cube.modifiers.new("Array", 'ARRAY')
array.fit_type = 'FIT_LENGTH'
array.fit_length = 100.0
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')


def x_span(obj):
    obj.update_from_editmode()
    xs = [v.co.x for v in obj.data.vertices]
    return max(xs) - min(xs)


said = command(blocks["EDIT RESIZE X 0.0001"])
check("9.5b the gizmo's Edit Mode Resize of 0.0001 on X under an Array fitted to 100 is refused (%s), the "
      "vertices put back" % refused_number(said), said is not None and "Edit Mode" in said
      and abs(x_span(cube) - 2.0) < 1e-6 and array.show_viewport, said)
said = command(blocks["EDIT RESIZE X 0.5"])
check("and the gizmo's Resize of 0.5 passes (Blender at %s, under the budget)" % format(counts(cube)[0], ','),
      said is None and abs(x_span(cube) - 1.0) < 1e-6 and 408 < counts(cube)[0] <= budget.BUDGET, said)
said = command("bpy.ops.transform.translate(value=(0.5, 0.0, 0.0), cursor_transform=True)")
check("the Cursor's own drag is not held as a move of the mesh", said is None
      and abs(bpy.context.scene.cursor.location.x - 0.5) < 1e-6, said)
bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
bpy.ops.transform.resize(value=(2.0, 1.0, 1.0))
with gate_off_settled():
    run(blocks["EDIT RESIZE X 0.0001"])
    bpy.ops.object.mode_set(mode='OBJECT')
    check("control: with the gate off, Blender makes %s" % format(counts(cube)[0], ','),
          counts(cube)[0] > budget.BUDGET)
clear()


# What Edit Mode holds apart from the data: a curve's and a lattice's points,
# which Blender's evaluated copy shares with the original (so there is no
# copy to compare with), a metaball's elements, an edited mesh's vertices
# changed by a script, and what reads an edited mesh. Each measured passing
# before this round's last pass, with the budget lowered to 100,000 so that
# the controls' bare counts stay small: a Bézier curve's points resized to a
# thousandth under an Array fitted to 100, 650,013; a lattice's, under a
# cube's Lattice and Array, 399,944; a metaball's element resized 30 times,
# 152 → 138,320; a script's bmesh edit, 400,000; a linked duplicate's Array,
# 400,008.
class lowered:
    """The budget lowered for a test, its controls kept small."""

    def __init__(self, value):
        self.value = value

    def __enter__(self):
        self.kept = budget.BUDGET
        budget.BUDGET = self.value

    def __exit__(self, *exc):
        budget.BUDGET = self.kept


def object_mode():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')


def span(collection, attribute='co', axis=0):
    values = [getattr(p, attribute)[axis] for p in collection]
    return max(values) - min(values)


def fitted_curve():
    clear()
    bpy.ops.curve.primitive_bezier_curve_add()
    curve = bpy.context.object
    curve.name = "Curve"
    array = curve.modifiers.new("Array", 'ARRAY')
    array.fit_type = 'FIT_LENGTH'
    array.fit_length = 100.0
    bpy.context.view_layer.update()
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.curve.select_all(action='SELECT')
    return curve


def latticed_cube():
    """A cube under a Lattice (Linear along U) and an Array fitted to 100."""
    clear()
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    cube.name = "Cube"
    bpy.ops.object.add(type='LATTICE')
    lattice = bpy.context.object
    lattice.name = "Lattice"
    lattice.scale = (2.5, 2.5, 2.5)
    lattice.data.interpolation_type_u = 'KEY_LINEAR'
    cube.modifiers.new("Lattice", 'LATTICE').object = lattice
    array = cube.modifiers.new("Array", 'ARRAY')
    array.fit_type = 'FIT_LENGTH'
    array.fit_length = 100.0
    bpy.context.view_layer.update()
    return cube, lattice


SHRINK_POINTS = ("c = bpy.data.objects['Curve'].data\nfor p in c.splines[0].bezier_points:\n"
                 "    p.co.x *= 0.001\n    p.handle_left.x *= 0.001\n    p.handle_right.x *= 0.001")
with lowered(100_000):
    curve = fitted_curve()
    rest = counts(curve)[0]
    run(blocks["POINTS BEGIN DRAG Curve"])
    frame = command(blocks["POINTS PREVIEW RESIZE X 0.001"])
    said = command(blocks["POINTS COMMIT RESIZE X 0.001"])
    check("9.5c a curve's Edit Mode drag of its points to a thousandth on X under an Array fitted to 100 is "
          "refused, frame (%s) and release (%s), the points where they were and Blender at %s"
          % (refused_number(frame), refused_number(said), format(counts(curve)[0], ',')),
          refused_at(frame, 650_013) and refused_at(said, 650_013) and counts(curve)[0] == rest
          and abs(span(curve.data.splines[0].bezier_points) - 2.0) < 1e-5, (frame, said))
    said = command(SHRINK_POINTS)
    check("and a script line writing them there in its Edit Mode (%s)" % refused_number(said),
          refused_at(said, 650_013) and counts(curve)[0] == rest, said)
    run(blocks["POINTS BEGIN DRAG Curve"])
    said = command(blocks["POINTS COMMIT RESIZE X 0.5"])
    check("and a drag to half its width passes (Blender at %s)" % format(counts(curve)[0], ','),
          said is None and abs(span(curve.data.splines[0].bezier_points) - 1.0) < 1e-5
          and rest < counts(curve)[0] < budget.BUDGET, said)
    with gate_off_settled():
        run(SHRINK_POINTS)
        check("control: with the gate off, Blender makes %s" % format(counts(curve)[0], ','),
              counts(curve)[0] > budget.BUDGET)
    object_mode()

    cube, lattice = latticed_cube()
    rest = counts(cube)[0]
    said = command("for p in bpy.data.lattices['Lattice'].points:\n    p.co_deform.x *= 0.001")
    check("9.5d a script line writing a lattice's points to a thousandth on X, the cube under its Lattice and "
          "an Array fitted to 100, is refused (%s) and the cube stays at %s" % (refused_number(said), rest),
          refused_at(said, 399_944) and counts(cube)[0] == rest, said)
    select(lattice)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.lattice.select_all(action='SELECT')
    run(blocks["POINTS BEGIN DRAG Lattice"])
    said = command(blocks["POINTS COMMIT RESIZE X 0.001"])
    check("and the same in its Edit Mode, through the drag's release (%s)" % refused_number(said),
          refused_at(said, 399_944) and counts(cube)[0] == rest
          and abs(span(lattice.data.points, 'co_deform') - 1.0) < 1e-5, said)
    with gate_off_settled():
        run(blocks["POINTS BEGIN DRAG Lattice"])
        run(blocks["POINTS COMMIT RESIZE X 0.001"])
        check("control: with the gate off, Blender makes %s" % format(counts(cube)[0], ','),
              counts(cube)[0] > budget.BUDGET)
    object_mode()

    clear()
    bpy.ops.object.metaball_add(type='ELLIPSOID')
    ball = bpy.context.object
    bpy.context.view_layer.update()
    rest = counts(ball)[0]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mball.select_all(action='SELECT')
    said = command(blocks["SEARCH RESIZE 30"])
    check("9.5e a metaball's Edit Mode Resize of 30 from the search is refused (%s), Blender at %s"
          % (refused_number(said), rest), (refused_number(said) or 0) > budget.BUDGET
          and counts(ball)[0] == rest and abs(ball.data.elements[0].size_x - 1.2) < 1e-5, said)
    said = command("e = bpy.context.object.data.elements[0]\ne.size_x *= 30; e.size_y *= 30; e.size_z *= 30")
    check("and a script line writing its sizes there in Edit Mode (%s)" % refused_number(said),
          said is not None and counts(ball)[0] == rest, said)
    said = command(blocks["SEARCH RESIZE 1.5"])
    check("and a Resize of 1.5 passes", said is None and abs(ball.data.elements[0].size_x - 1.8) < 1e-5, said)
    with gate_off_settled():
        run(blocks["SEARCH RESIZE 30"])
        check("control: with the gate off, Blender makes %s" % format(counts(ball)[0], ','),
              counts(ball)[0] > budget.BUDGET)
    # Its copy keeps the elements it had while an operator edits them in Edit
    # Mode, and Blender evaluates the original's (the note above `_EditSnap`):
    # compared with the copy, leaving Edit Mode after the control was refused
    # and the element put back to the size before the Resize of 1.5 passed.
    said = said_of(object_mode)
    check("and Edit Mode is left with the state Blender holds (Size X %.1f)" % ball.data.elements[0].size_x,
          said is None and ball.mode == 'OBJECT' and ball.data.elements[0].size_x > 20.0, said)
    object_mode()
    # An operator writes past RNA's range (Size X stops at 20 through RNA):
    # the change is priced as Blender holds it. Measured in desktop 5.2.1 at
    # Resolution 1, Resize 100 took an element of 1.2 to 120, and clamped to
    # 20 the gate counted 23,240 and passed.
    clear()
    bpy.ops.object.metaball_add(type='ELLIPSOID')
    ball = bpy.context.object
    ball.data.resolution = 1.0
    bpy.context.view_layer.update()
    rest = counts(ball)[0]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mball.select_all(action='SELECT')
    said = command(blocks["SEARCH RESIZE 100"])
    check("a metaball's Edit Mode Resize of 100 at Resolution 1, Size X 120 past RNA's 20, is refused (%s), "
          "Blender at %s" % (refused_number(said), rest), (refused_number(said) or 0) > budget.BUDGET
          and counts(ball)[0] == rest and abs(ball.data.elements[0].size_x - 1.2) < 1e-5, said)
    with gate_off_settled():
        run(blocks["SEARCH RESIZE 100"])
        check("control: with the gate off, Size X %.0f and Blender makes %s" % (
            ball.data.elements[0].size_x, format(counts(ball)[0], ',')),
            counts(ball)[0] > budget.BUDGET and ball.data.elements[0].size_x > 20.0)
    object_mode()

    clear()
    bpy.ops.mesh.primitive_cube_add()
    a = bpy.context.object
    a.name = "Cube"
    bpy.ops.object.duplicate_move_linked()
    b = bpy.context.object
    b.name = "B"
    array = b.modifiers.new("Array", 'ARRAY')
    array.fit_type = 'FIT_LENGTH'
    array.fit_length = 100.0
    select(a)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    rest = counts(b)[0]
    said = command(blocks["EDIT RESIZE X 0.001"])
    check("9.5f the gizmo's Edit Mode Resize of 0.001 on a cube with no modifier, whose linked duplicate B is "
          "under an Array fitted to 100, is refused (%s) and B stays at %s" % (refused_number(said), rest),
          refused_at(said, 400_008) and counts(b)[0] == rest and array.show_viewport, said)
    with gate_off_settled():
        run(blocks["EDIT RESIZE X 0.001"])
        check("control: with the gate off, B makes %s" % format(counts(b)[0], ','), counts(b)[0] > budget.BUDGET)
    object_mode()

    clear()
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    cube.name = "Cube"
    array = cube.modifiers.new("Array", 'ARRAY')
    array.fit_type = 'FIT_LENGTH'
    array.fit_length = 100.0
    bpy.context.view_layer.update()
    bpy.ops.object.mode_set(mode='EDIT')
    rest = counts(cube)[0]
    BMESH_SHRINK = ("import bmesh\nbm = bmesh.from_edit_mesh(bpy.context.object.data)\nfor v in bm.verts:\n"
                    "    v.co.x *= %s\nbmesh.update_edit_mesh(bpy.context.object.data)")
    said = command(BMESH_SHRINK % "1.5")
    check("9.5g a script's bmesh edit of an edited mesh under an Array fitted to 100: 1.5 times wider passes",
          said is None and array.show_viewport, said)
    said = command(BMESH_SHRINK % "0.001")
    check("and a thousandth of its width is refused (%s), the Array held hidden, Blender at %s"
          % (refused_number(said), format(counts(cube)[0], ',')),
          (refused_number(said) or 0) > budget.BUDGET
          and not array.show_viewport and counts(cube)[0] <= rest and "hidden" in said, said)
    array.show_viewport = True
    said = mirror_pass()
    check("and showing the Array again is refused too (%s)" % refused_number(said),
          said is not None and not array.show_viewport, said)
    object_mode()
    clear()
    bpy.ops.mesh.primitive_cube_add()
    cube = bpy.context.object
    array = cube.modifiers.new("Array", 'ARRAY')
    array.fit_type = 'FIT_LENGTH'
    array.fit_length = 100.0
    bpy.context.view_layer.update()
    bpy.ops.object.mode_set(mode='EDIT')
    with gate_off_settled():
        run(BMESH_SHRINK % "0.001")
        check("control: with the gate off, Blender makes %s" % format(counts(cube)[0], ','),
              counts(cube)[0] > budget.BUDGET)
        # Left with the gate off too: since fix round 3 the leave prices what
        # it writes against the Edit Mode state the gate passed, and this
        # one it never priced (tests/budget/blender/freed.py,
        # bmesh_leave_price).
        object_mode()
clear()

# The transaction hides what Edit Mode's own operators do not read: a Mirror
# with Clipping, whose plane Extrude keeps its edges off, stays shown. Found
# by the meshmenu check: hidden, Extrude to Cursor or Add and Blender's own
# Extrude Region extruded the plane's edges too (30/56/28 for 30/53/24).
def half_grid():
    """The +X half of a 4 × 4 grid under a Mirror with Clipping and a
    Subdivision (which the transaction holds), every edge selected."""
    clear()
    mesh = bpy.data.meshes.new("Half")
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=4, y_segments=4, size=1.0)
    for v in [v for v in bm.verts if v.co.x < -1e-4]:
        bm.verts.remove(v)
    bm.to_mesh(mesh)
    bm.free()
    half = bpy.data.objects.new("Half", mesh)
    bpy.context.scene.collection.objects.link(half)
    half.modifiers.new("Mirror", 'MIRROR').use_clip = True
    half.modifiers.new("Subdivision", 'SUBSURF').levels = 1
    activate(half)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = (False, True, False)
    bpy.ops.mesh.select_all(action='SELECT')
    return half


def edit_topology(obj):
    bm = bmesh.from_edit_mesh(obj.data)
    return len(bm.verts), len(bm.edges), len(bm.faces)


half = half_grid()
said = command(blocks["EDIT EXTRUDE"])
gated = edit_topology(half)
object_mode()
half = half_grid()
with gate_off_settled():
    run(blocks["EDIT EXTRUDE"])
    bare = edit_topology(half)
object_mode()
check("9.5h the Mesh menu's Extrude on a half grid under a Mirror with Clipping and a Subdivision keeps the plane's "
      "edges off as Blender bare does (%s, bare %s)" % (gated, bare), said is None and gated == bare == (30, 53, 24),
      said)
clear()


# -- pose bones and other objects' data under the Data API row -------------------
clear()
bpy.ops.mesh.primitive_cube_add()
c = bpy.context.object
c.name = "C"
bpy.ops.object.armature_add()
rig = bpy.context.object
c.modifiers.new("Armature", 'ARMATURE').object = rig
c.vertex_groups.new(name="Bone").add(range(8), 1.0, 'REPLACE')
c.modifiers.new("Remesh", 'REMESH').voxel_size = 0.1
bpy.context.view_layer.update()
said = said_of(lambda: sync.set_property('bpy.data.objects["%s"].pose.bones["Bone"]' % rig.name, 'scale',
                                         [40, 40, 40]))
check("9.6 the Data API row's pose bone Scale 40 under an Armature and a Remesh at 0.1 is refused; Blender at "
      "2,648", said is not None and "2,500,000" in said and counts(c)[0] == 2_648, said)
with gate_off_settled():
    rig.pose.bones['Bone'].scale = (40, 40, 40)
    check("control: with the gate off, Blender makes %s" % format(counts(c)[0], ','), counts(c)[0] > 2_500_000)
    rig.pose.bones['Bone'].scale = (1, 1, 1)
clear()
a, o = fitted()
bpy.ops.mesh.primitive_plane_add(location=(1, 0, 0))
plane = bpy.context.object
o.location = (0, 0, 0)
o.parent = plane
o.parent_type = 'VERTEX'
o.parent_vertices = (0, 0, 0)
bpy.context.view_layer.update()
said = said_of(lambda: sync.set_property('bpy.data.meshes["%s"].vertices[0]' % plane.data.name, 'co',
                                         [-1.0, -0.0001, 0.0]))
check("a vertex parent's vertex moved through the Data API row so O sits 0.0001 m off A: refused at 3,200,008",
      refused_at(said, 3_200_008) and counts(a)[0] == 328, said)
with gate_off_settled():
    plane.data.vertices[0].co = (-1.0, -0.0001, 0.0)
    check("control: with the gate off, Blender makes %s" % format(counts(a)[0], ','), counts(a)[0] == 3_200_008)

# -- metaballs, Extrude to Cursor, a curve's Duplicate -----------------------------
clear()
bpy.ops.object.metaball_add(type='BALL', radius=2.0)
ball = bpy.context.object
ball.data.resolution = 0.05
bpy.ops.object.mode_set(mode='EDIT')
refusal = None
for press in range(9):
    bpy.ops.mball.select_all(action='SELECT')
    said = command(blocks["SEARCH MBALL DUPLICATE"])
    if said is not None:
        refusal = (press, len(ball.data.elements), said)
        break
bpy.ops.object.mode_set(mode='OBJECT')
check("9.7 a metaball's Edit Mode Duplicate, all selected, again and again from the search: refused at %s"
      % (str(refusal[:2]) if refusal else "no press"), refusal is not None and counts(ball)[0] <= BUDGET, refusal)
s = budget.Prices()
seconds = budget.meta_seconds(ball, s, budget._meta_base(ball, s).v)
s.close()
check("and the family's polygonization is held to METABALL_SECONDS (%.1f s now)" % seconds,
      seconds <= budget.METABALL_SECONDS)
clear()
bpy.ops.mesh.primitive_monkey_add()
suzanne = bpy.context.object
suzanne.modifiers.new("Subdivision", 'SUBSURF').levels = 5
bpy.context.scene.cursor.location = (0, -5, 0)
bpy.ops.object.mode_set(mode='EDIT')
saids = []
for press in range(3):
    bpy.ops.mesh.select_all(action='SELECT')
    saids.append(command(blocks["EXTRUDE TO CURSOR"]))
bpy.ops.object.mode_set(mode='OBJECT')
check("9.8 Mesh ▸ Vertex ▸ Extrude to Cursor or Add, Select All before each, on Suzanne under Subdivision 5: "
      "refused once past the budget, Blender at %s" % format(counts(suzanne)[0], ','),
      any(x is not None and "2,500,000" in x for x in saids) and counts(suzanne)[0] <= BUDGET, saids)
clear()
bpy.ops.mesh.primitive_monkey_add()
suzanne = bpy.context.object
suzanne.modifiers.new("Subdivision", 'SUBSURF').levels = 5
bpy.ops.object.mode_set(mode='EDIT')
with gate_off_settled():
    for press in range(3):
        bpy.ops.mesh.select_all(action='SELECT')
        context_was = budget.price_extrude_to_cursor
        budget.price_extrude_to_cursor = lambda: None
        try:
            run(blocks["EXTRUDE TO CURSOR"])
        finally:
            budget.price_extrude_to_cursor = context_was
    bpy.ops.object.mode_set(mode='OBJECT')
    check("control: bare, three presses make %s" % format(counts(suzanne)[0], ','), counts(suzanne)[0] > 4_000_000)
clear()
bpy.ops.curve.primitive_bezier_curve_add()
k = bpy.context.object
k.data.bevel_depth = 0.05
k.modifiers.new("A1", 'ARRAY').count = 64
k.modifiers.new("A2", 'ARRAY').count = 64
k.modifiers["A2"].relative_offset_displace = (0, 1, 0)
bpy.ops.object.mode_set(mode='EDIT')
history = []
for press in range(6):
    bpy.ops.curve.select_all(action='SELECT')
    history.append(command(blocks["SEARCH CURVE DUPLICATE"]))
bpy.ops.object.mode_set(mode='OBJECT')
check("9.9 a curve's Edit Mode Duplicate from the search under two Arrays of 64: refused once past the budget, "
      "Blender at %s" % format(counts(k)[0], ','),
      any(x is not None and "2,500,000" in x for x in history) and counts(k)[0] <= BUDGET, history)

# -- values under HUGE that overflow ------------------------------------------
clear()
bpy.ops.mesh.primitive_cube_add()
a = bpy.context.object
a.name = "A"
arr = a.modifiers.new("Array", 'ARRAY')
arr.count = 1000
arr.use_relative_offset = False
arr.use_constant_offset = True
activate(a)
said = said_of(lambda: sync.set_property("bpy.data.objects['A'].modifiers['Array']", "constant_offset_displace",
                                         [0, 0, 1e14]))
check("9.10 an Array at Count 1000 with a Constant Offset of 1e14: finite, inside REACH, passes", said is None
      and finite(a), said)
refused = None
for i in range(3):
    deform = a.modifiers.new("Taper%d" % i, 'SIMPLE_DEFORM')
    deform.deform_method = 'TAPER'
    said = said_of(lambda: sync.set_property("bpy.data.objects['A'].modifiers['Taper%d']" % i, "factor", 1e14))
    if said is not None:
        refused = (i, said)
        break
check("then a Simple Deform on Taper at 1e14 is refused for its reach (%s), Blender's vertices finite"
      % (refused[0] if refused else "none"), refused is not None and finite(a), refused)
with gate_off_settled():
    for i in range(3):
        name = "Taper%d" % i
        if a.modifiers.get(name) is None:
            d = a.modifiers.new(name, 'SIMPLE_DEFORM')
            d.deform_method = 'TAPER'
        a.modifiers[name].factor = 1e14
    check("control: with the gate off, three Tapers at 1e14 leave Blender's vertices not all finite",
          not finite(a))
clear()
mesh = bpy.data.meshes.new("far")
mesh.from_pydata([(2e14, 0, 0), (2e14, 1, 0), (2e14, 0, 1)], [], [(0, 1, 2)])
far = bpy.data.objects.new("Far", mesh)
bpy.context.scene.collection.objects.link(far)
bpy.context.view_layer.update()
said = said_of(lambda: sync.set_property("bpy.data.objects['Far']", "scale", [1e14, 1e14, 1e14]))
check("an object's scale of 1e14 on vertices at 2e14 (2e28 m out, past the app's float) is refused",
      said is not None and "infinite" in said and tuple(far.scale) == (1.0, 1.0, 1.0), said)

# -- Dynamic Topology ---------------------------------------------------------
clear()
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=5)
ico = bpy.context.object
ico.modifiers.new("Subdivision", 'SUBSURF').levels = 4
activate(ico)
bpy.ops.object.mode_set(mode='SCULPT')
stroke = dict(camera={'distance': 10.0, 'fov_y': 0.8}, view=(1000, 1000), mapped=(1000, 1000))
brush = None
settings = sculpt._sculpt_settings()
settings.detail_type_method = 'RELATIVE'
settings.detail_size = 12.0
said = said_of(lambda: sculpt._refuse_dyntopo_growth(stroke, ico, brush, 200))
check("9.11 a Dynamic Topology chunk on an icosphere of 10,242 under Subdivision 4 is priced through the stack, "
      "as leaving Sculpt Mode builds it", said is not None and "modifiers are counted" in said, said)
ico.modifiers[0].show_viewport = False
said = said_of(lambda: sculpt._refuse_dyntopo_growth(stroke, ico, brush, 200))
check("control: with the Subdivision hidden, the same chunk passes", said is None, said)
bpy.ops.object.mode_set(mode='OBJECT')

# -- Fluid at Blender's default Mesh Upres -------------------------------------
clear()
bpy.ops.mesh.primitive_cube_add(size=4)
dom = bpy.context.object
dom.name = "Domain"
fluid = dom.modifiers.new("Fluid", 'FLUID')
fluid.fluid_type = 'DOMAIN'
settings = fluid.domain_settings
settings.domain_type = 'LIQUID'
settings.use_mesh = True
activate(dom)
path = "bpy.data.objects['Domain'].modifiers['Fluid'].domain_settings"
said = said_of(lambda: sync.set_property(path, "resolution_max", 64))
check("9.12 a Liquid domain's Resolution 64 at Blender's default Mesh Upres 2 passes (counted %s; measured "
      "peaks 123,880 to 404,750)" % format(budget.stack_vertices(dom), ','), said is None and
      settings.resolution_max == 64, said)
said = said_of(lambda: sync.set_property(path, "resolution_max", 160))
check("and Resolution 160 is refused", said is not None and settings.resolution_max == 64, said)

# -- ordinary edits pass, and the gate costs little -------------------------------
clear()
bpy.ops.mesh.primitive_monkey_add()
suzanne = bpy.context.object
activate(suzanne)
edits = [
    ("Add Subdivision Surface, level 2", lambda: run(blocks["ADD MESH SUBSURF"]) or run(blocks["ROW subdivision level 2"])),
    ("move it 3 m (a script line)", lambda: setattr(suzanne, 'location', (3, 0, 0))),
    ("a shape key at 0.5 (a script line)", lambda: (suzanne.shape_key_add(name="Basis"),
                                                   setattr(suzanne.shape_key_add(name="K"), 'value', 0.5))),
    ("a Copy Location to an empty 2 m away", lambda: setattr(suzanne.constraints.new('COPY_LOCATION'), 'target',
                                                             bpy.data.objects.new("E", None))),
    ("a Mirror on X", lambda: suzanne.modifiers.new("Mirror", 'MIRROR')),
]
for label, fn in edits:
    started = time.time()
    said = said_of(fn) or mirror_pass()
    check("ordinary: %s passes (%s vertices, %.0f ms with the mirror)" % (
        label, format(counts(suzanne)[0], ','), 1000 * (time.time() - started)), said is None, said)
started = time.perf_counter()
for _ in range(100):
    gate.gate()
idle = (time.perf_counter() - started) * 10
check("the gate with nothing waiting costs %.3f ms" % idle, idle < 1.0)


# -- the sweep -----------------------------------------------------------------
# Every writable setting of the objects a count hangs on — transforms,
# parents, constraints and their targets, pose bones, shape keys, a curve's
# and a metaball's data — stepped up and down from a small fixture, written
# bare as a script line writes it, then the mirror (the gate): a step after
# which Blender's own evaluated count is past the budget and more than before
# fails. Allowed only with a commented measurement (none needed).

STATE_ALLOWED = {
}
STATE_SKIP = SKIP | {'location_mass_center', 'rotation_estimate', 'scale_estimate', 'tag', 'pass_index',
                     'hide_select', 'hide_render', 'is_holdout', 'is_shadow_catcher', 'visible_camera',
                     'visible_diffuse', 'visible_glossy', 'visible_transmission', 'visible_volume_scatter',
                     'visible_shadow', 'lightgroup', 'display_type', 'display_bounds_type', 'empty_display_type',
                     'empty_display_size', 'empty_image_offset', 'color', 'active_material_index',
                     'add_rest_position_attribute', 'use_grease_pencil_lights', 'track_axis', 'up_axis',
                     'use_instance_vertices_rotation', 'use_instance_faces_scale', 'instance_faces_scale',
                     'show_instancer_for_viewport', 'show_instancer_for_render', 'use_dynamic_topology_sculpting',
                     'use_shape_key_edit_mode', 'use_camera_lock_parent', 'hide_probe_volume',
                     'hide_probe_sphere', 'hide_probe_plane', 'use_mesh_mirror_x', 'use_mesh_mirror_y',
                     'use_mesh_mirror_z', 'use_simulation_cache', 'mode'}


def state_fixture():
    """One vertex under an Array fitted to 40 whose offset is O (under P, with
    a Copy Location to T at 1e-5 m, at Influence 0): a move of any of them
    towards A multiplies A, by at most about 2,700,000 copies of the one
    vertex within the ladders' steps (a vector's smallest is a quarter to the
    eighth, 1/65,536 m), and at most 4,000,000 at Influence 1. B: two
    vertices 1 m apart with a key that puts them 1e-6 apart, under an Array
    fitted to 3 by their size (at most 6,000,000). C: the same pair deformed
    by a bone, fitted to 30. K: a bevelled curve under an Array of 64. M: a
    metaball. Bounded so that a bypass the sweep finds stays in memory."""
    clear()
    a, o = fitted(vertex_only=True)
    bpy.ops.object.empty_add(location=(0, 0, 0))
    p = bpy.context.object
    p.name = "P"
    o.parent = p
    t = bpy.data.objects.new("T", None)
    bpy.context.scene.collection.objects.link(t)
    t.location = (1e-5, 0, 0)
    con = o.constraints.new('COPY_LOCATION')
    con.target = t
    con.influence = 0.0
    o.constraints.new('LIMIT_DISTANCE').target = t
    o.constraints[-1].influence = 0.0

    def pair(name):
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata([(0, 0, 0), (1, 0, 0)], [(0, 1)], [])
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        return obj

    b = pair("B")
    b.location = (0, 5, 0)
    b.shape_key_add(name="Basis")
    key = b.shape_key_add(name="Thin")
    key.value = 0.0
    key.data[1].co.x = 1e-6
    # And one at Value 1 kept muted: its Mute off is the same 6,000,000.
    muted = b.shape_key_add(name="Muted")
    muted.data[1].co.x = 1e-6
    muted.value = 1.0
    muted.mute = True
    arr = b.modifiers.new("Array", 'ARRAY')
    arr.fit_type = 'FIT_LENGTH'
    arr.fit_length = 3.0
    c = pair("C")
    c.location = (0, -5, 0)
    bpy.ops.object.armature_add(location=(0, -5, 0))
    rig = bpy.context.object
    rig.name = "Rig"
    c.modifiers.new("Armature", 'ARMATURE').object = rig
    c.vertex_groups.new(name="Bone").add([0, 1], 1.0, 'REPLACE')
    arr = c.modifiers.new("Array", 'ARRAY')
    arr.fit_type = 'FIT_LENGTH'
    arr.fit_length = 30.0
    bpy.ops.curve.primitive_bezier_curve_add(location=(5, 0, 0))
    k = bpy.context.object
    k.name = "K"
    k.data.bevel_depth = 0.05
    k.modifiers.new("Array", 'ARRAY').count = 64
    bpy.ops.object.metaball_add(location=(-5, 0, 0))
    mb = bpy.context.object
    mb.data.resolution = 0.4
    bpy.context.view_layer.update()
    return dict(A=a, O=o, P=p, T=t, B=b, C=c, Rig=rig, K=k, M=mb)


def everyone():
    found = {}
    for obj in bpy.context.view_layer.objects:
        if obj.type in budget.GEOMETRY_TYPES:
            found[obj.name] = counts(obj)[0]
    return found


def state_structs(objects):
    """(label, struct) for each struct the sweep steps."""
    out = []
    for name in ('O', 'P', 'T', 'A', 'B', 'C', 'Rig'):
        out.append(("%s" % name, objects[name]))
    for con in objects['O'].constraints:
        out.append(("O constraint %s" % con.name, con))
    for bone in objects['Rig'].pose.bones:
        out.append(("Rig pose bone %s" % bone.name, bone))
    key = objects['B'].data.shape_keys
    out.append(("B's Key", key))
    for block in key.key_blocks:
        out.append(("B key %s" % block.name, block))
    out.append(("K's curve", objects['K'].data))
    out.append(("K's spline", objects['K'].data.splines[0]))
    out.append(("M's metaball", objects['M'].data))
    out.append(("M's element", objects['M'].data.elements[0]))
    return out


def state_sweep(label, gated=True, only=None, limit=None):
    """Steps every setting (or `only` (struct label, setting)s) and returns
    the bypasses found: (struct, setting, value, Blender's count)."""
    found, steps, started = [], 0, time.time()
    objects = state_fixture()
    for struct_label, struct in state_structs(objects):
        for prop in struct.bl_rna.properties:
            ident = prop.identifier
            if ident in STATE_SKIP or prop.is_readonly or ident.startswith('show_'):
                continue
            if prop.type not in ('BOOLEAN', 'INT', 'FLOAT', 'ENUM'):
                continue
            if only is not None and (struct_label, ident) not in only:
                continue
            if (struct_label, ident) in STATE_ALLOWED:
                continue
            try:
                now = getattr(struct, ident)
            except AttributeError:
                continue
            now = tuple(now) if hasattr(now, '__len__') and not isinstance(now, str) else now
            for ladder in ladders(prop, now):
                for value in ladder:
                    if limit is not None and steps >= limit:
                        return found, steps, time.time() - started
                    before = everyone()
                    steps += 1
                    try:
                        setattr(struct, ident, value)
                    except (TypeError, ValueError, AttributeError, RuntimeError):
                        continue
                    if gated:
                        mirror_pass()
                    try:
                        after = everyone()
                    except (RuntimeError, ReferenceError):
                        after = before
                    grown = [(n, c) for n, c in after.items() if c > BUDGET and c > before.get(n, 0)]
                    if grown:
                        found.append((struct_label, ident, value, grown))
                    try:
                        setattr(struct, ident, now)
                    except (TypeError, ValueError, AttributeError, RuntimeError):
                        pass
                    if gated:
                        mirror_pass()
                    else:
                        bpy.context.view_layer.update()
                    if grown:
                        break
    return found, steps, time.time() - started


found, steps, took = state_sweep("gated")
print("        %d steps in %.0f s" % (steps, took))
for f in found[:20]:
    print("        bypass: %s %s = %r → %s" % f)
check("9.13 the sweep of every writable setting of objects, constraints, pose bones, shape keys, a curve's and a "
      "metaball's data, written bare: Blender is never past the budget unpriced (%d steps)" % steps,
      not found, found[:5])
with gate_off_settled():
    control, control_steps, _ = state_sweep("off", gated=False, only={
        ("O", "location"), ("O constraint Copy Location", "influence"), ("B key Thin", "value"),
        ("B key Muted", "mute"), ("Rig pose bone Bone", "scale")})
check("control: with the gate off, the same sweep finds %d of those settings growing Blender past the budget"
      % len({(f[0], f[1]) for f in control}), len({(f[0], f[1]) for f in control}) >= 5,
      [(f[0], f[1]) for f in control])

# -- an approval of what is gone ---------------------------------------------
# Found by the modifier check (Geometry Nodes modifiers made and the file
# reloaded between them): a passed setting's approval waits for Blender's
# evaluation, and the next pass read an approved Node Group removed since,
# which raised "StructRNA of type GeometryNodeTree has been removed" and lost
# the whole mirror pass.
clear()
bpy.ops.mesh.primitive_uv_sphere_add()
sphere = bpy.context.object
nodes = sphere.modifiers.new("GeometryNodes", 'NODES')
twist = bpy.data.node_groups.new("Twist", 'GeometryNodeTree')
gate.approve([(nodes, 'node_group', twist)])
bpy.data.node_groups.remove(twist)
said, approved = None, None
try:
    approved = gate._is_approved(gate.Change(nodes, 'node_group', None,
                                             bpy.data.node_groups.new("Other", 'GeometryNodeTree'), 1))
except ReferenceError as error:
    said = str(error)
check("9.14 a change met by the approval of a data-block removed since is not taken as approved, and raises "
      "nothing", said is None and approved is False, said)
clear()
