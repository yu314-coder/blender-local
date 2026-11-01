"""The Sidebar's Item tab (`_blenderkit_item`) in Blender: what it reads and
what each typed number writes, as Blender's own Transform panel would
(`v3d_editvertex_buts`, `v3d_object_dimension_buts`, view3d_buttons.cc).

  * Median (several selected) and Vertex (one), Global and Local, on a turned,
    non-uniformly scaled cube: the typed number reads back on its axis, the
    other two stay, every selected vertex moves by the same difference, one
    vertex is put where it was typed.
  * Vertex Data and Edge Data: Bevel Weight and Vertex Crease, Bevel Weight
    and Crease, each added on demand as Blender adds it; the mean comes back
    as typed, each element where Blender's `compute_scale_factor` and
    `apply_scale_factor_clamp` put it (worked out again here from the C), 0
    and 1 set outright.
  * Each write is one step of the app's undo history: Undo puts it back.
  * Refusals in words: nothing selected, a dimension along an axis with no
    size.
  * Dimensions: a typed size comes back as typed on a plain cube, a turned
    one, a child of a scaled parent and one with a delta scale; `obj.dimensions
    = …` does not under the scaled parent (the negative control). In Edit Mode
    Blender's Dimensions follow the edit mesh once evaluated.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *

states = []


def state(use_global=True, label=""):
    line = item.state(use_global)
    states.append(label + "\t" + line)
    return json.loads(line)


def edit_cube(select, mode='VERT'):
    reset()
    cube = make('cube', 'Cube', location=(0.5, -1, 0.3), rotation=(0.5236, 0.2, 0.1), scale=(1, 2, 0.5))
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type=mode)
    bm = bmesh.from_edit_mesh(cube.data)
    bm.verts.ensure_lookup_table(); bm.edges.ensure_lookup_table(); bm.faces.ensure_lookup_table()
    for e in list(bm.verts) + list(bm.edges) + list(bm.faces):
        e.select = False
    seq = {'VERT': bm.verts, 'EDGE': bm.edges, 'FACE': bm.faces}[mode]
    for i in select:
        seq[i].select_set(True)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(cube.data)
    return cube


def selected_world(cube):
    bm = bmesh.from_edit_mesh(cube.data)
    return [cube.matrix_world @ v.co for v in bm.verts if v.select]


def selected_local(cube):
    bm = bmesh.from_edit_mesh(cube.data)
    return [v.co.copy() for v in bm.verts if v.select]


# ---------------------------------------------------------------------------
# Median and Vertex
# ---------------------------------------------------------------------------
for use_global in (True, False):
    space = "Global" if use_global else "Local"
    for select, what in (([0, 1, 2, 3], "Median"), ([5], "Vertex")):
        cube = edit_cube(select)
        before = state(use_global, "%s %s" % (what, space))
        rows = selected_world(cube) if use_global else selected_local(cube)
        for axis, value in ((0, 1.25), (2, -0.5)):
            shown = state(use_global)['median']
            item.set_median(axis, value, use_global)
            after = state(use_global, "%s %s after %s" % (what, space, 'XYZ'[axis]))
            others = [i for i in range(3) if i != axis]
            check("%s %s %s typed %.2f reads back as typed, the other axes kept"
                  % (what, space, 'XYZ'[axis], value),
                  abs(after['median'][axis] - value) < 1e-5
                  and all(abs(after['median'][i] - shown[i]) < 1e-5 for i in others),
                  "%s -> %s" % (shown, after['median']))
        rows_after = selected_world(cube) if use_global else selected_local(cube)
        if len(select) > 1:
            deltas = [b - a for a, b in zip(rows, rows_after)]
            check("%s %s: every selected vertex moved by the same difference" % (what, space),
                  all((d - deltas[0]).length < 1e-5 for d in deltas))
        bpy.ops.object.mode_set(mode='OBJECT')

cube = edit_cube([])
check("Nothing selected reads as none (tot 0)", state(True, "none selected")['tot'] == 0)
try:
    item.set_median(0, 1.0)
    check("a Median edit with nothing selected is refused", False)
except RuntimeError as error:
    check("a Median edit with nothing selected is refused in words: %s" % error, "Nothing selected" in str(error))
bpy.ops.object.mode_set(mode='OBJECT')
check("Object Mode reads as no mesh being edited", json.loads(item.state(True))['mesh'] is False)
states.append("object mode\t" + item.state(True))

# ---------------------------------------------------------------------------
# Vertex Data and Edge Data
# ---------------------------------------------------------------------------


def scale_factor(new, diff):
    """compute_scale_factor, from view3d_buttons.cc, again."""
    if new <= 0.0:
        return 0.0
    if new >= 1.0:
        return 1.0
    orig = min(max(new - diff, 0.0), 1.0)
    new_c = min(max(new, 0.0), 1.0)
    return new_c / orig if new_c <= orig else -(1.0 - new_c) / (1.0 - orig)


def expected(values, tot, new):
    mean = sum(values) / len(values)
    sca = scale_factor(new, new - mean)
    out = []
    for v in values:
        if tot == 1:
            out.append(min(max(new, 0.0), 1.0))
        elif sca in (0.0, 1.0):
            out.append(sca)
        else:
            w = v * sca if sca > 0.0 else 1.0 + (1.0 - v) * sca
            out.append(min(max(w, 0.0), 1.0))
    return out


def layer_values(cube, name):
    bm = bmesh.from_edit_mesh(cube.data)
    seq = bm.verts if name.endswith('_vert') else bm.edges
    layer = seq.layers.float.get(name)
    return [e[layer] if layer is not None else 0.0 for e in seq if e.select]


for name, mode, select in (('bevel_weight_vert', 'VERT', [0, 1, 2]), ('crease_vert', 'VERT', [0, 1, 2]),
                           ('bevel_weight_edge', 'EDGE', [0, 1, 2, 3]), ('crease_edge', 'EDGE', [0, 1, 2, 3]),
                           ('bevel_weight_edge', 'EDGE', [5])):
    cube = edit_cube(select, mode)
    bm = bmesh.from_edit_mesh(cube.data)
    seq = bm.verts if name.endswith('_vert') else bm.edges
    check("%s: no layer before the first write" % name, seq.layers.float.get(name) is None)
    tot = sum(1 for v in bm.verts if v.select)
    for value in (0.4, 0.1, 0.7, 1.0, 0.0, 0.35):
        before = layer_values(cube, name)
        item.set_data(name, value)
        after = layer_values(cube, name)
        want = expected(before, tot, value)
        mean = sum(after) / len(after)
        check("%s (%d selected) typed %.2f: the mean is %.2f and each element where Blender puts it"
              % (name, len(after), value, value),
              abs(mean - value) < 1e-5 and all(abs(a - b) < 1e-5 for a, b in zip(after, want)),
              "before %s after %s Blender's %s" % (before, after, want))
    s = state(True, "%s rows" % name)
    check("%s: the state's mean reads back" % name, abs(s[name] - 0.35) < 1e-5, s)
    bpy.ops.object.mode_set(mode='OBJECT')

# Different values to start from, which a mean moved by setting every element
# would flatten: Blender scales them.
cube = edit_cube([0, 1, 2, 3], 'VERT')
bm = bmesh.from_edit_mesh(cube.data)
layer = bm.verts.layers.float.new('crease_vert')
for v, w in zip([v for v in bm.verts if v.select], (0.1, 0.2, 0.5, 0.8)):
    v[layer] = w
bmesh.update_edit_mesh(cube.data)
item.set_data('crease_vert', 0.6)
after = layer_values(cube, 'crease_vert')
check("uneven creases are scaled towards the typed mean, not flattened to it",
      len(set(round(a, 4) for a in after)) == 4 and abs(sum(after) / 4 - 0.6) < 1e-5, after)
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------------
# One undo step each
# ---------------------------------------------------------------------------
cube = edit_cube([0, 1], 'VERT')
push("Edit Mode")
start = state(True)['median']
item.set_median(1, 3.0)
push("Y")
item.set_data('bevel_weight_vert', 0.5)
push("Mean Bevel Weight")
check("two edits made", abs(state(True)['median'][1] - 3.0) < 1e-5 and abs(state(True)['bevel_weight_vert'] - 0.5) < 1e-5)
undo.step(-1)
s = state(True)
check("Undo takes back the weight alone", abs(s['bevel_weight_vert']) < 1e-5 and abs(s['median'][1] - 3.0) < 1e-5, s)
undo.step(-1)
s = state(True)
check("and again the Median", all(abs(a - b) < 1e-5 for a, b in zip(s['median'], start)), s)
undo.step(1)
check("Redo puts the Median back", abs(state(True)['median'][1] - 3.0) < 1e-5)
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------------
# Dimensions
# ---------------------------------------------------------------------------
reset()
plain = make('cube', 'Plain')
turned = make('cube', 'Turned', location=(3, 0, 0), rotation=(0.4, 0.6, 0.2), scale=(1, 2, 0.5))
holder = make('empty', 'Holder', location=(0, 4, 0), rotation=(0, 0, 0.5), scale=(2, 2, 2))
child = make('cube', 'Child', location=(1, 0, 0))
child.parent = holder
delta = make('cube', 'Delta', location=(-3, 0, 0))
delta.delta_scale = (1.5, 1, 3)
bpy.context.view_layer.update()
for obj in (plain, turned, child, delta):
    for axis, value in ((0, 2.0), (2, 4.0), (1, 0.75)):
        item.set_dimension(obj.name, axis, value)
        d = json.loads(item.dimensions(obj.name))
        check("%s: Dimensions %s typed %.2f reads back as typed" % (obj.name, 'XYZ'[axis], value),
              abs(d[axis] - value) < 1e-4, d)
check("the plain cube's dimensions are (2, 0.75, 4) after the three",
      all(abs(a - b) < 1e-4 for a, b in zip(json.loads(item.dimensions('Plain')), (2, 0.75, 4))))
# The negative control: Blender's own property setter under the scaled parent.
child.scale = (1, 1, 1)
bpy.context.view_layer.update()
dims = list(child.dimensions)
dims[0] = 2.0
child.dimensions = dims
bpy.context.view_layer.update()
check("negative control: obj.dimensions = … under a parent scaled 2 does not read back (%.3f)" % child.dimensions[0],
      abs(child.dimensions[0] - 2.0) > 0.1)
flat = make('grid', 'Flat')
try:
    item.set_dimension('Flat', 2, 1.0)
    check("a flat grid's Z cannot be given a size", False)
except RuntimeError as error:
    check("a flat grid's Z is refused in words: %s" % error, "no size along Z" in str(error))

# In Edit Mode Blender's Dimensions follow the edit mesh, once evaluated.
reset()
cube = make('cube', 'Cube', scale=(1, 1, 0.5))
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(cube.data)
for v in bm.verts:
    v.select = v.co.z > 0
    if v.select:
        v.co.z += 1.0
bmesh.update_edit_mesh(cube.data)
d = json.loads(item.dimensions('Cube'))
check("in Edit Mode, Dimensions are the edit mesh's: Z 1.5 after a top lifted 1 (scale 0.5)", abs(d[2] - 1.5) < 1e-5, d)
states.append("edit after lift\t" + item.state(True))

# ---------------------------------------------------------------------------
# Round 4's review: Dimensions in Edit Mode, non-finite results, objects with
# no Dimensions
# ---------------------------------------------------------------------------
# Edit Mode: refused in words, and the scale untouched. The reason, measured:
# Blender's Edit Mode undo keeps only the mesh, so a scale written there and
# recorded as a step does not come back with Undo (the negative control).
push("Edit Mode")
try:
    item.set_dimension('Cube', 0, 5.0)
    check("Dimensions typed in Edit Mode are refused", False)
except RuntimeError as error:
    check("Dimensions typed in Edit Mode are refused in words: %s" % error,
          "Object Mode" in str(error) and tuple(cube.scale) == (1.0, 1.0, 0.5), tuple(cube.scale))
cube.scale[0] = 2.5
push("X")
undo.step(-1)
cube = bpy.data.objects['Cube']
check("negative control: a scale written in Edit Mode and recorded is not undone there (%.2f after Undo)"
      % cube.scale[0], abs(cube.scale[0] - 2.5) < 1e-6)
bpy.ops.object.mode_set(mode='OBJECT')
cube.scale = (1, 1, 0.5)
push("Object Mode")
item.set_dimension('Cube', 0, 5.0)
push("X")
undo.step(-1)
cube = bpy.data.objects['Cube']
check("in Object Mode a typed Dimension is undone (scale X %.3f after Undo)" % cube.scale[0],
      abs(cube.scale[0] - 1.0) < 1e-6)

# A Median past float32: refused, the mesh put back, and the state still JSON.
cube = edit_cube([0, 1, 2, 3, 4, 5, 6, 7])
before = selected_local(cube)
for value in (3e38, -3e38, 2e38):
    try:
        item.set_median(0, value, True)
        check("Median X %g is refused" % value, False, state(True)['median'])
    except RuntimeError as error:
        check("Median X %g is refused in words: %s" % (value, error),
              "finite" in str(error) and all((a - b).length == 0.0 for a, b in zip(before, selected_local(cube))))
line = item.state(True)
check("and the state stays JSON the app reads: %s" % line[:60], "Infinity" not in line and "NaN" not in line)
# A value that stays finite still goes in.
item.set_median(0, 1e6, True)
check("a large but finite Median still goes in", abs(state(True)['median'][0] - 1e6) < 1.0)
# What a script can still do: put a vertex at infinity. The state reads it
# as Blender's UI prints it, and a typed Median on top is refused.
bm = bmesh.from_edit_mesh(cube.data)
[v for v in bm.verts if v.select][0].co.x = float('inf')
bmesh.update_edit_mesh(cube.data)
line = item.state(True)
states.append("a vertex at infinity\t" + line)
s_inf = json.loads(line)
check("a vertex a script put at infinity reads as 'inf' and 'nan', not Infinity: %s" % s_inf['median'],
      s_inf['median'][0] in ('inf', 'nan') and "Infinity" not in line)
try:
    item.set_median(1, 0.5, True)
    check("a typed Median on a non-finite selection is refused", False)
except RuntimeError as error:
    check("a typed Median on a non-finite selection is refused in words", "finite" in str(error))
d_line = item.dimensions('Cube')
check("its Dimensions read too: %s" % d_line, "Infinity" not in d_line and "NaN" not in d_line
      and json.loads(d_line) is not None)
bpy.ops.object.mode_set(mode='OBJECT')

# Dimensions past float32: 3e38 made the scale 1.5e38 and the Dimensions inf.
reset()
cube = make('cube', 'Cube')
try:
    item.set_dimension('Cube', 0, 3e38)
    check("Dimensions X 3e38 is refused", False, tuple(cube.dimensions))
except RuntimeError as error:
    check("Dimensions X 3e38 is refused in words, the scale put back: %s" % error,
          "finite" in str(error) and tuple(cube.scale) == (1.0, 1.0, 1.0), tuple(cube.scale))
item.set_dimension('Cube', 0, 1e9)
check("a large but finite Dimension still goes in", abs(cube.dimensions[0] - 1e9) / 1e9 < 1e-5, tuple(cube.dimensions))
try:
    item.set_dimension('Cube', 1, float('inf'))
    check("an infinite Dimension is refused", False)
except RuntimeError as error:
    check("an infinite Dimension is refused in words", "type a number" in str(error))

# Blender's Item tab draws no Dimensions for an Empty, a Camera or a Light.
for kind, add in (('Empty', lambda: bpy.ops.object.empty_add()), ('Camera', lambda: bpy.ops.object.camera_add()),
                  ('Light', lambda: bpy.ops.object.light_add(type='POINT'))):
    add()
    obj = bpy.context.active_object
    check("%s: no Dimensions to read (null)" % kind, json.loads(item.dimensions(obj.name)) is None)
    try:
        item.set_dimension(obj.name, 0, 2.0)
        check("%s: Dimensions refused" % kind, False)
    except RuntimeError as error:
        check("%s: Dimensions refused in words: %s" % (kind, error), kind in str(error))

out = os.environ.get("BK_STATES")
if out:
    with open(out, "w") as f:
        f.write("\n".join(states) + "\n")
finish()
