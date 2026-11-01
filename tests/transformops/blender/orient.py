"""Blender's transform orientations against the app's port of them
(`_blenderkit_orient.matrix`), case by case: Blender's own matrix is the one
`transform.translate` stores when it is handed the type alone and works the
matrix out itself (common.blender_matrix).

Object Mode: Local, Normal (Local there), Gimbal for each Euler order, an
axis angle and a quaternion (which falls through to Parent), Parent with and
without a parent, a sheared child, the Cursor turned. Edit Mode on meshes:
faces (one, two, all, triangles, an n-gon), edges (one, a boundary one), two
vertices with and without an active one, three with and without an edge, one
on a boundary and one inside, more than three, Active Element with a face, an
edge and a vertex active, and Local, Gimbal and Parent of an edited object. A
lattice's Edit Mode (no Normal: the identity). Then the negative control: the
port with its normal transform taken as the object matrix, not its inverse
transpose, must disagree on a non-uniformly scaled object.

The report line the app parses is printed for each, and `unavailable` is held
for a curve's Edit Mode.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *

cases = 0
reports = []


ties = []


def near_equilateral(obj):
    """Whether every selected face is a triangle whose edges agree to 1e-4:
    there the edge `bm_vert_tri_find_unique_edge` picks is decided by
    rounding (its three differences measured 1e-11 to 1e-10 apart on an
    icosahedron), in float in Blender and in double here."""
    if obj is None or obj.mode != 'EDIT' or obj.type != 'MESH':
        return False
    bm = bmesh.from_edit_mesh(obj.data)
    faces = [f for f in bm.faces if f.select]
    if not faces:
        return False
    for f in faces:
        if len(f.verts) != 3:
            return False
        lengths = [e.calc_length() for e in f.edges]
        if max(lengths) > min(lengths) * (1 + 1e-4):
            return False
    return True


def compare(label, kind):
    global cases
    mine = orient.matrix(kind)
    mine = [tuple(v) for v in mine] if mine is not None else None
    obj = bpy.context.view_layer.objects.active
    active_only = (obj is not None and obj.mode == 'EDIT'
                   and bpy.context.scene.tool_settings.transform_pivot_point == 'ACTIVE_ELEMENT')
    theirs = blender_matrix_in_view(obj, kind) if active_only else blender_matrix(kind)
    cases += 1
    same = close_axes(mine, theirs)
    if not same and kind == 'NORMAL' and near_equilateral(obj) and mine is not None and theirs is not None \
            and (Vector(mine[2]) - Vector(theirs[2])).length < 1e-5:
        ties.append(label)
        print("  TIE   %s %s: the normal agrees and the tangent is a rounding tie" % (label, kind))
    else:
        check("%s %s: the port is Blender's%s" % (label, kind, " (its 3D View's, Active Element)" if active_only else ""),
              same, "port %s Blender %s" % (fmt_axes(mine), fmt_axes(theirs)))
    reports.append(orient.report(kind))
    return mine, theirs


def edit(obj, select, mode='VERT', history=None, active_face=None):
    """Into Edit Mode with exactly `select` selected (vertices, edges or faces
    by index) and `history` as Blender's selection order."""
    bpy.context.view_layer.objects.active = obj
    if obj.mode != 'EDIT':
        bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type=mode)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table(); bm.edges.ensure_lookup_table(); bm.faces.ensure_lookup_table()
    for e in list(bm.verts) + list(bm.edges) + list(bm.faces):
        e.select = False
    bm.select_history.clear()
    seq = {'VERT': bm.verts, 'EDGE': bm.edges, 'FACE': bm.faces}[mode]
    for i in select:
        seq[i].select_set(True)
    bm.select_flush_mode()
    for kind, i in history or []:
        bm.select_history.add({'VERT': bm.verts, 'EDGE': bm.edges, 'FACE': bm.faces}[kind][i])
    bm.faces.active = bm.faces[active_face] if active_face is not None else None
    bmesh.update_edit_mesh(obj.data)
    return bm


# ---------------------------------------------------------------------------
# Object Mode
# ---------------------------------------------------------------------------
reset()
holder = make('empty', 'Holder', location=(1, 2, 0), rotation=(0.3, -0.2, 0.9), scale=(1, 2, 0.5))
cube = make('cube', 'Cube', location=(2, 0, 1), rotation=(0.4, 0.5, -0.6), scale=(1, 1.5, 0.75))
for kind in ('GLOBAL', 'LOCAL', 'NORMAL', 'GIMBAL', 'PARENT', 'CURSOR'):
    compare("object, no parent,", kind)
bpy.context.scene.cursor.rotation_euler = (0.2, 0.9, -0.4)
compare("object, the cursor turned,", 'CURSOR')
for order in ('XZY', 'YXZ', 'YZX', 'ZXY', 'ZYX'):
    cube.rotation_mode = order
    compare("object, Euler %s," % order, 'GIMBAL')
cube.rotation_mode = 'AXIS_ANGLE'
cube.rotation_axis_angle = (0.8, 0.3, -0.5, 0.7)
compare("object, axis angle,", 'GIMBAL')
cube.rotation_mode = 'QUATERNION'
cube.rotation_quaternion = Quaternion((0.3, 0.2, 0.5), 0.9)
compare("object, quaternion (Gimbal falls through to Parent),", 'GIMBAL')
cube.rotation_mode = 'XYZ'
cube.parent = holder
bpy.context.view_layer.update()
for kind in ('LOCAL', 'GIMBAL', 'PARENT', 'NORMAL'):
    compare("object under a turned, non-uniformly scaled parent,", kind)
cube.rotation_mode = 'QUATERNION'
compare("object, quaternion under a parent,", 'GIMBAL')
cube.rotation_mode = 'XYZ'

# ---------------------------------------------------------------------------
# Edit Mode on meshes
# ---------------------------------------------------------------------------
reset()
cube = make('cube', 'Cube', location=(0.5, -1, 0.3), rotation=(0.5236, 0.2, 0.1), scale=(1, 2, 0.5))
for sel, label in (([0], "one face"), ([0, 1], "two faces"), ([0, 1, 2], "three faces"),
                   (list(range(6)), "every face")):
    edit(cube, sel, 'FACE')
    compare("cube, %s," % label, 'NORMAL')
edit(cube, [0], 'EDGE'); compare("cube, one edge,", 'NORMAL')
edit(cube, [0, 5], 'EDGE'); compare("cube, two edges,", 'NORMAL')
edit(cube, [0, 1], 'VERT'); compare("cube, two vertices,", 'NORMAL')
edit(cube, [0, 1], 'VERT', history=[('VERT', 0), ('VERT', 1)]); compare("cube, two vertices, the second active,", 'NORMAL')
edit(cube, [0, 1], 'VERT', history=[('VERT', 1), ('VERT', 0)]); compare("cube, two vertices, the first active,", 'NORMAL')
edit(cube, [0, 1, 2], 'VERT'); compare("cube, three vertices,", 'NORMAL')
edit(cube, [0, 1, 3], 'VERT', history=[('VERT', 3), ('VERT', 1), ('VERT', 0)])
compare("cube, three vertices in an order,", 'NORMAL')
edit(cube, [0], 'VERT'); compare("cube, one vertex (three edges),", 'NORMAL')
edit(cube, [0, 1, 2, 3, 4], 'VERT'); compare("cube, five vertices,", 'NORMAL')
for kind in ('LOCAL', 'GIMBAL', 'PARENT', 'CURSOR', 'GLOBAL'):
    compare("cube in Edit Mode,", kind)
bpy.context.scene.tool_settings.transform_pivot_point = 'ACTIVE_ELEMENT'
edit(cube, [0, 2], 'FACE', history=[('FACE', 0), ('FACE', 2)], active_face=2)
compare("cube, Active Element, a face active,", 'NORMAL')
edit(cube, [0, 3], 'EDGE', history=[('EDGE', 0), ('EDGE', 3)])
compare("cube, Active Element, an edge active,", 'NORMAL')
edit(cube, [0, 5, 6], 'VERT', history=[('VERT', 5), ('VERT', 6)])
compare("cube, Active Element, a vertex active,", 'NORMAL')
edit(cube, [1, 4], 'FACE')
compare("cube, Active Element with no history (the median's),", 'NORMAL')
bpy.context.scene.tool_settings.transform_pivot_point = 'MEDIAN_POINT'
bpy.ops.object.mode_set(mode='OBJECT')

reset()
grid = make('grid', 'Grid', rotation=(0.3, 0.0, 0.7), scale=(1.5, 1, 1), x_subdivisions=4, y_subdivisions=4)
edit(grid, [0], 'VERT'); compare("grid, a corner (two edges, a boundary),", 'NORMAL')
edit(grid, [1], 'VERT'); compare("grid, a vertex on its side,", 'NORMAL')
edit(grid, [6], 'VERT'); compare("grid, an inside vertex (four edges),", 'NORMAL')
bm = edit(grid, [], 'EDGE')
boundary = [e.index for e in bm.edges if e.is_boundary][0]
inner = [e.index for e in bm.edges if not e.is_boundary][0]
edit(grid, [boundary], 'EDGE'); compare("grid, a boundary edge,", 'NORMAL')
edit(grid, [inner], 'EDGE'); compare("grid, an inside edge,", 'NORMAL')
edit(grid, [0, 1, 5], 'VERT'); compare("grid, three vertices with two edges among them,", 'NORMAL')
edit(grid, [0, 2, 10], 'VERT'); compare("grid, three vertices with no edge,", 'NORMAL')
bpy.ops.object.mode_set(mode='OBJECT')

reset()
sphere = make('sphere', 'Sphere', rotation=(0.2, 0.4, 0.1), segments=12, ring_count=6)
bm = edit(sphere, [], 'FACE')
tri = [f.index for f in bm.faces if len(f.verts) == 3][0]
quad = [f.index for f in bm.faces if len(f.verts) == 4][0]
edit(sphere, [tri], 'FACE'); compare("sphere, a pole triangle,", 'NORMAL')
edit(sphere, [quad], 'FACE'); compare("sphere, a quad,", 'NORMAL')
edit(sphere, [tri, quad], 'FACE'); compare("sphere, a triangle and a quad,", 'NORMAL')
bpy.ops.object.mode_set(mode='OBJECT')

reset()
cylinder = make('cylinder', 'Cylinder', rotation=(0.1, -0.3, 0.2), vertices=8)
bm = edit(cylinder, [], 'FACE')
ngon = [f.index for f in bm.faces if len(f.verts) == 8][0]
edit(cylinder, [ngon], 'FACE'); compare("cylinder, an octagon cap,", 'NORMAL')
bpy.ops.object.mode_set(mode='OBJECT')

reset()
ico = make('ico', 'Ico', rotation=(0.5, 0.1, 0.3), subdivisions=1)
edit(ico, [0, 3, 7], 'FACE'); compare("icosphere, three triangles,", 'NORMAL')
edit(ico, [0, 1], 'VERT'); compare("icosphere, two vertices,", 'NORMAL')
bpy.ops.object.mode_set(mode='OBJECT')

reset()
monkey = make('monkey', 'Suzanne', rotation=(0.3, 0.2, -0.5), scale=(1.2, 0.8, 1))
import random
rng = random.Random(7)
for trial in range(6):
    faces = rng.sample(range(500), 1 + trial * 3)
    edit(monkey, faces, 'FACE')
    compare("Suzanne, %d faces," % len(faces), 'NORMAL')
for trial in range(4):
    verts = rng.sample(range(500), 1 + trial)
    edit(monkey, verts, 'VERT')
    compare("Suzanne, %d vertices," % len(verts), 'NORMAL')
bpy.ops.object.mode_set(mode='OBJECT')

# A lattice in its Edit Mode: Blender has no Normal there.
reset()
lattice = make('lattice', 'Lattice', rotation=(0.3, 0.4, 0.2))
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.lattice.select_all(action='SELECT')
for kind in ('NORMAL', 'LOCAL', 'GIMBAL'):
    compare("lattice in Edit Mode,", kind)
bpy.ops.object.mode_set(mode='OBJECT')

# A curve's Edit Mode Normal is not ported: said, and no matrix.
reset()
curve = make('curve', 'Curve', rotation=(0.2, 0, 0.4))
bpy.ops.object.mode_set(mode='EDIT')
bpy.context.scene.transform_orientation_slots[0].type = 'NORMAL'
check("a curve's Edit Mode Normal is said to be unavailable",
      orient.matrix() is None and orient.unavailable() and orient.report().startswith("NORMAL none "),
      orient.report())
check("and its Local is still worked out", orient.matrix('LOCAL') is not None)
bpy.ops.object.mode_set(mode='OBJECT')

# A custom orientation, made as Create Orientation makes one (under the
# borrowed 3D View, its poll's area, undo off): read as Blender applies it, and
# a call carrying its matrix alone (no orient_type: CUSTOM_MATRIX) moves along
# it — what a gizmo drag commits in one.
reset()
cube = make('cube', 'Cube', rotation=(0.5236, 0.2, 0.1), scale=(1, 2, 0.5))
edit(cube, [0], 'FACE')
with ctx.temp_override_view3d('check'):
    made = bpy.ops.transform.create_orientation(name='My Face', use=True)
check("a custom orientation is made and used", 'FINISHED' in made
      and bpy.context.scene.transform_orientation_slots[0].type == 'My Face')
mine = [tuple(v) for v in orient.matrix()]
check("the port reads a custom orientation as Blender applies it", close_axes(mine, blender_matrix('My Face')))
line = orient.report()
reports.append(line)
check("its report starts with its name, spaces and all", line.startswith('My Face ') and len(line.split()) == 11, line)
bm = bmesh.from_edit_mesh(cube.data)
bm.verts.ensure_lookup_table()
v = [v for v in bm.verts if v.select][0]
w0 = cube.matrix_world @ v.co
bpy.ops.transform.translate(value=(0, 0, 1), orient_matrix=tuple(mine))
bm = bmesh.from_edit_mesh(cube.data)
bm.verts.ensure_lookup_table()
v = [v for v in bm.verts if v.select][0]
check("a move with its matrix alone goes along its Z", ((cube.matrix_world @ v.co) - w0 - Vector(mine[2])).length < 1e-5)
bpy.ops.object.mode_set(mode='OBJECT')

# The header's menu writes the slot through the tool settings, and a name
# Blender does not have is refused, not taken.
tools = sys.modules['_blenderkit_tools']
tools.set_tools(orientation='PARENT')
check("set_tools(orientation=…) writes Blender's slot",
      bpy.context.scene.transform_orientation_slots[0].type == 'PARENT')
try:
    tools.set_tools(orientation='SIDEWAYS')
    check("an orientation Blender does not have is refused", False)
except TypeError as error:
    check("an orientation Blender does not have is refused: %s" % str(error).split(':')[-1].strip()[:60], True)

# The report never raises: it runs after every command. A port that failed
# comes back as none, with the error as the reason.
real_matrix = orient.matrix
orient.matrix = lambda kind=None: (_ for _ in ()).throw(ValueError("a deliberate failure"))
try:
    line = orient.report('NORMAL')
    check("a failing matrix is reported as none, with why", line.startswith("NORMAL none ") and "deliberate" in line, line)
except Exception as error:
    check("a failing matrix is reported as none, with why", False, repr(error))
finally:
    orient.matrix = real_matrix

# The other modes, which a gizmo never shows in: read without error.
reset()
cube = make('cube', 'Cube', rotation=(0.2, 0.3, 0.4))
for mode in ('SCULPT', 'WEIGHT_PAINT', 'VERTEX_PAINT', 'TEXTURE_PAINT'):
    bpy.ops.object.mode_set(mode=mode)
    try:
        line = orient.report('NORMAL')
        ok = line.startswith('NORMAL ')
    except Exception as error:
        ok, line = False, repr(error)
    check("the report reads in %s" % mode, ok, line)
    bpy.ops.object.mode_set(mode='OBJECT')
for o in bpy.context.view_layer.objects:
    o.select_set(False)
bpy.context.view_layer.objects.active = None
check("and with no active object, Local is the identity",
      close_axes([tuple(v) for v in orient.matrix('LOCAL')], [(1, 0, 0), (0, 1, 0), (0, 0, 1)]))

# ---------------------------------------------------------------------------
# The negative control: a port that transforms the normal by the object's own
# matrix, not its inverse transpose, on a non-uniformly scaled cube.
# ---------------------------------------------------------------------------
reset()
cube = make('cube', 'Cube', rotation=(0.5236, 0.2, 0.1), scale=(1, 3, 0.4))
edit(cube, [0, 1], 'FACE')
real = orient.matrix('NORMAL')


def without_inverse_transpose(obj):
    """The port's own steps with one taken out: the face normal carried by
    the object matrix itself."""
    bm = bmesh.from_edit_mesh(obj.data)
    result, normal, plane = orient._mesh_normal_plane(obj, bm, False)
    m3 = obj.matrix_world.to_3x3()
    normal = (m3 @ normal).normalized()
    plane = (m3 @ plane).normalized()
    return orient.create_space_normal_tangent(normal, plane)


broken = without_inverse_transpose(cube)
theirs = blender_matrix('NORMAL')
check("negative control: the port without the inverse transpose disagrees with Blender",
      not close_axes([tuple(v) for v in broken], theirs), fmt_axes(broken))
check("while the port itself agrees", close_axes([tuple(v) for v in real], theirs))
bpy.ops.object.mode_set(mode='OBJECT')

print("%d orientations compared, %d of them rounding ties left out: %s" % (cases, len(ties), ties))
out = os.environ.get("BK_REPORTS")
if out:
    with open(out, "w") as f:
        f.write("\n".join(reports) + "\n")
finish()
