"""The Self-Test: every check below, one after another, in the app on the
device, with a plain-text report.

Opened from Preferences: the Self-Test button in its Testing section opens
the Self-Test sheet, whose Run calls `run` on the main thread
(`BpySession.runSelfTest`). Test All Features (`_blenderkit_featuretest`)
reuses its fingerprint and scratch scene.
The checks are the repo's own, ported from the desktop Blender checks that
hold the app's modules to Blender 5.2.1, so a TestFlight build can be held to
them on the iPad itself:

  * the crash paths fix round 3 guarded (tests/budget/blender/freed.py): every
    case that crashed Blender on 6d31b90, and the window's-scene cases —
    leaving Edit Mode under Geometry Nodes, Subdivision, Remesh, Bevel and
    Array after edits, Undo and Redo across the leave, a script's bmesh edits,
    an image or a font removed while Blender's copies point at them;
  * operators the context guards refuse (tests/unsafe/blender/verify.py): New
    Scene's Full Copy and Linked Copy inside temp_override(scene=...,
    view_layer=...), the window given another scene inside one and then
    `evaluated_depsgraph_get()`, the window's own scene removed, and the
    guards' sealed closures;
  * one vertex-budget refusal per family of the budget check's parts 12, 12i
    and 12j (Array Count, Time Stretching, an F-curve modifier, a legacy
    texture, Geometry Nodes instances, Shift+D into a collection a Collection
    Info realizes, a driver, a Boolean), each refused with Blender's own count
    unchanged;
  * ordinary edits, allowed and timed; the mirror's pass the app runs after a
    script; a 64 x 64 EEVEE render through the Render panel's own script.

They run ordinary edits and the mirror's pass first, then the budget, the
guards and the crash paths, and the render last (`ORDER`): the checks least
likely to take the app down first, so a crash leaves the most on the report,
and the heaviest on memory last. None of the deliberately unguarded
controls the desktop checks crash Blender with is here: only guarded paths.

The user's work is never touched. Before the first check the scene is saved
to a temporary file the way the app writes its recovery file
(`_blenderkit_undo.autosave`; the app has written `autosave.blend` itself a
moment before, so a run that takes the app down leaves the next launch the
scene as it was); every check then starts from Blender's startup file, opened
the way File > New opens it; and after the last one the saved scene is opened
again the way the app opens its recovery file at launch. What Blender holds
is compared before and after — every object, mesh, curve, collection,
material, scene and the window's selection and modes — and the report says
whether it matched. Loading a file
ends Blender's own undo history, so Undo cannot go back past the Self-Test
(the sheet says so before Run); the history is left with the scene as it was,
never with a check's scene.

A check that raises is a FAIL with what it raised, and the run goes on. The
report is written as the checks go, each check's name before it starts, so a
run that takes the app down leaves the last check it started on disk.
Nothing here opens a window, a browser or another app.
"""
import contextlib
import hashlib
import json
import os
import platform
import sys
import tempfile
import threading
import time
import traceback
from array import array

import bpy

# Rounds of each freed-memory case. freed.py runs 6 under MallocScribble on
# the desktop, and on 6d31b90 every crashing case went down in its first;
# here 3, since Extrude doubles the grid each round: 6 took the app's
# footprint from 0.4 to 1.0 GB on the Mac, 3 to 0.3.
ROUNDS = 3
# An ordinary edit slower than this is a FAIL: each is a cube or a small grid.
ORDINARY_SECONDS = 3.0

CHECKS = []          # (group, key, name, function)
# The order a run takes: the checks least likely to take the app down first,
# so a crash leaves the most on the report; the render, the heaviest on
# memory, last.
ORDER = ('ordinary', 'mirror', 'budget', 'guards', 'crash', 'render')


class Fail(Exception):
    """A check's measured outcome was not what it has to be."""


def _need(ok, detail):
    if not ok:
        raise Fail(detail)


def _check(group, key, name):
    def register(function):
        CHECKS.append((group, key, name, function))
        return function
    return register


# --------------------------------------------------------------------------
# The app's modules, as the app has them loaded

def _module(name):
    found = sys.modules.get(name)
    if found is None:
        import importlib
        found = importlib.import_module(name)
    return found


def _gate():
    return sys.modules.get('_blenderkit_gate')


def _budget():
    return _module('_blenderkit_budget')


def _sync():
    return _module('_blenderkit_sync')


def _undo():
    return _module('_blenderkit_undo')


def _on_main_thread():
    app = sys.modules.get('_blenderkit')
    asked = getattr(app, 'is_main_thread', None)
    if asked is not None:
        try:
            return bool(asked())
        except Exception:                      # noqa: BLE001 - fall back to Python's own answer
            pass
    return threading.current_thread() is threading.main_thread()


# --------------------------------------------------------------------------
# Helpers the checks share (the desktop checks' own, as they are there)

def _said(call, *args, **keywords):
    """What a call was refused with, or None when it ran."""
    try:
        call(*args, **keywords)
    except RuntimeError as error:
        return str(error)
    return None


def _mirror():
    """The mirror's pass the app runs after every command, and what it was
    refused with."""
    try:
        _sync().sync()
    except RuntimeError as error:
        return str(error)
    return None


def _line(source):
    """A script line, then the mirror's pass."""
    try:
        exec(compile(source, "<line>", "exec"), {"bpy": bpy})
    except Exception as error:                     # noqa: BLE001 - the refusal is the finding
        return str(error)
    return _mirror()


def _attempt(body):
    """'ran ...' or 'refused: ...', as tests/unsafe/blender/verify.py says it."""
    try:
        return "ran " + repr(body())
    except Exception as error:                     # noqa: BLE001 - what it said is the finding
        return "refused: " + str(error).strip().replace("\n", " ")


def _count(obj):
    """Blender's evaluated vertex count of `obj`, evaluating what is pending."""
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


def _held(obj):
    """What Blender holds for `obj` now, evaluating nothing."""
    evaluated = obj.evaluated_get(bpy.context.view_layer.depsgraph)
    if evaluated == obj:
        return None
    mesh = evaluated.to_mesh()
    try:
        return len(mesh.vertices) if mesh is not None else 0
    finally:
        evaluated.to_mesh_clear()


def _refused(said, number=None):
    return said is not None and ("stops at" in said or "would take Blender" in said
                                 or "only Blender" in said) and (number is None or format(number, ',') in said)


def _n(value):
    return format(value, ',') if isinstance(value, int) else str(value)


class _bare:
    """The gate off while a fixture is made, and what was written evaluated
    before it is back on (the checks' `bare`)."""

    def __enter__(self):
        _gate()._busy += 1

    def __exit__(self, *exc):
        try:
            bpy.context.view_layer.update()
        finally:
            _gate()._busy -= 1


class _budget_at:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        self.kept = _budget().BUDGET
        _budget().BUDGET = self.value

    def __exit__(self, *exc):
        _budget().BUDGET = self.kept


def _object_mode():
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer else None
    if obj is not None and obj.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')


def _clear():
    _object_mode()
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    for collection in (bpy.data.meshes, bpy.data.curves, bpy.data.particles):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)
    bpy.context.view_layer.update()


def _select_only(obj):
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj


def _cube(name="A", location=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    return obj


def _cube_array(count=2, name="A"):
    _clear()
    a = _cube(name)
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = count
    bpy.context.view_layer.update()
    return a, m


def _fcurves(action):
    """Every F-curve of a slotted action (5.x layers, strips, channel bags)."""
    out = []
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                out.extend(bag.fcurves)
    return out


# --------------------------------------------------------------------------
# 1. The crash paths fix round 3 guarded: tests/budget/blender/freed.py's
#    cases that crashed Blender on 6d31b90 (each under MallocScribble on the
#    desktop), and its window's-scene cases. A case passes when Blender
#    survives every round and what it checks holds.

def _one_node_group(node='GeometryNodeSetPosition'):
    tree = bpy.data.node_groups.new("One", 'GeometryNodeTree')
    tree.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    tree.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    i = tree.nodes.new('NodeGroupInput')
    o = tree.nodes.new('NodeGroupOutput')
    s = tree.nodes.new(node)
    tree.links.new(i.outputs[0], s.inputs[0])
    tree.links.new(s.outputs[0], o.inputs[0])
    return tree


def _grid(modifier='GN', n=60):
    _clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2)
    g = bpy.context.object
    if modifier == 'GN':
        g.modifiers.new("GN", 'NODES').node_group = _one_node_group()
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
        g.modifiers.new("Subdivision", 'SUBSURF').levels = 1
    bpy.context.view_layer.update()
    return g


def _extrude():
    bpy.ops.mesh.extrude_region_move(TRANSFORM_OT_translate={"value": (0, 0, 0.01)})


def _edit_rounds(obj, operator, leave='mode_set', rounds=None):
    """`operator` in Edit Mode, then leave, `rounds` times; the refusals."""
    refusals = 0
    for _ in range(rounds or ROUNDS):
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        if _said(operator):
            refusals += 1
        if leave == 'toggle':
            bpy.ops.object.editmode_toggle()
        else:
            bpy.ops.object.mode_set(mode='OBJECT')
        if obj.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
    return refusals


def _survived(obj, refusals=0, rounds=None):
    return "%d rounds survived; the mesh at %s vertices%s" % (
        rounds or ROUNDS, _n(len(obj.data.vertices)),
        ", %d refused in words" % refusals if refusals else "")


def _freed_extrude(kind, n):
    g = _grid(kind, n)
    before = len(g.data.vertices)
    refused = _edit_rounds(g, _extrude)
    return "%d rounds survived; %s -> %s vertices%s" % (
        ROUNDS, _n(before), _n(len(g.data.vertices)), ", %d refused in words" % refused if refused else "")


@_check('crash', 'gn_extrude', "Leave Edit Mode under Geometry Nodes after Extrude")
def _gn_extrude():
    return _freed_extrude('GN', 60)


@_check('crash', 'bevel_weight_extrude', "Leave Edit Mode under a Bevel by Weight after Extrude")
def _bevel_weight_extrude():
    return _freed_extrude('BEVEL', 60)


@_check('crash', 'subsurf_extrude', "Leave Edit Mode under Subdivision after Extrude")
def _subsurf_extrude():
    return _freed_extrude('SUBSURF', 30)


@_check('crash', 'remesh_extrude', "Leave Edit Mode under Remesh after Extrude")
def _remesh_extrude():
    return _freed_extrude('REMESH', 20)


@_check('crash', 'array_fit_extrude', "Leave Edit Mode under an Array fitted to a length after Extrude")
def _array_fit_extrude():
    return _freed_extrude('ARRAY', 20)


@_check('crash', 'gn_operators', "Leave Edit Mode under Geometry Nodes after eight Edit Mode operators")
def _gn_operators():
    g = _grid('GN', 30)
    operators = (lambda: bpy.ops.mesh.subdivide(),
                 lambda: bpy.ops.mesh.delete(type='FACE'),
                 lambda: bpy.ops.mesh.primitive_cube_add(size=0.2),
                 lambda: bpy.ops.mesh.bevel(offset=0.01),
                 lambda: bpy.ops.mesh.remove_doubles(),
                 lambda: bpy.ops.transform.resize(value=(0.5, 0.5, 0.5)),
                 lambda: bpy.ops.mesh.select_all(action='DESELECT'),
                 # The app's Mesh > Extrude row (LastOperator.mesh(.extrude)).
                 lambda: bpy.ops.mesh.extrude_region_shrink_fatten(TRANSFORM_OT_shrink_fatten={"value": 0.2}))
    rounds = max(1, ROUNDS // 3)
    refused = sum(_edit_rounds(g, op, rounds=rounds) for op in operators)
    return "%d operators x %d round%s survived; the mesh at %s vertices%s" % (
        len(operators), rounds, "" if rounds == 1 else "s", _n(len(g.data.vertices)),
        ", %d refused in words" % refused if refused else "")


@_check('crash', 'gn_toggle', "Leave Edit Mode by editmode_toggle under Geometry Nodes after Extrude")
def _gn_toggle():
    g = _grid('GN')
    refused = _edit_rounds(g, _extrude, leave='toggle')
    return _survived(g, refused)


@_check('crash', 'gn_to_sculpt', "Edit Mode straight to Sculpt Mode and the paint modes under Geometry Nodes")
def _gn_to_sculpt():
    g = _grid('GN')
    refused = 0
    modes = ('SCULPT', 'VERTEX_PAINT', 'WEIGHT_PAINT', 'TEXTURE_PAINT')
    for _ in range(ROUNDS):
        for mode in modes:
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
            said = (_said(_extrude) if mode == 'SCULPT'
                    else _said(bpy.ops.transform.translate, value=(0, 0, 0.001)))
            said = said or _said(bpy.ops.object.mode_set, mode=mode)
            g.location.x += 0.001
            said = said or _mirror()
            refused += bool(said)
            bpy.ops.object.mode_set(mode='OBJECT')
    return "%d rounds of %d modes survived; the mesh at %s vertices%s" % (
        ROUNDS, len(modes), _n(len(g.data.vertices)), ", %d refused in words" % refused if refused else "")


def _blender_undo_push(label):
    """A step on Blender's own undo stack, as the history's push makes one
    (`ed.undo_push`), without a step in the app's history: the checks' scenes
    stay out of what Undo can reach after the Self-Test."""
    result = bpy.ops.ed.undo_push(message=label)
    if 'FINISHED' not in result:
        raise Fail("Blender's undo_push returned %r" % (result,))


@_check('crash', 'gn_undo', "Undo and Redo across leaving Edit Mode under Geometry Nodes")
def _gn_undo():
    name = _grid('GN').name
    refused = 0
    for _ in range(ROUNDS):
        g = bpy.data.objects[name]
        bpy.context.view_layer.objects.active = g
        bpy.ops.object.mode_set(mode='EDIT')
        _blender_undo_push("edit")
        bpy.ops.mesh.select_all(action='SELECT')
        _said(_extrude)
        bpy.ops.object.mode_set(mode='OBJECT')
        _blender_undo_push("left")
        for op in (bpy.ops.ed.undo, bpy.ops.ed.undo, bpy.ops.ed.redo, bpy.ops.ed.redo):
            said = _said(op) or _mirror()
            refused += bool(said)
        g = bpy.data.objects[name]
        if g.mode != 'OBJECT':
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='OBJECT')
    return _survived(bpy.data.objects[name], refused)


@_check('crash', 'gn_bmesh', "A script's bmesh edit, told and untold, then leaving Edit Mode under Geometry Nodes")
def _gn_bmesh():
    import bmesh
    g = _grid('GN')
    for r in range(ROUNDS):
        bpy.context.view_layer.objects.active = g
        bpy.ops.object.mode_set(mode='EDIT')
        bm = bmesh.from_edit_mesh(g.data)
        bmesh.ops.subdivide_edges(bm, edges=bm.edges[:40], cuts=1)
        if r % 2:
            bmesh.update_edit_mesh(g.data)
        bpy.ops.object.mode_set(mode='OBJECT')
    return _survived(g)


@_check('crash', 'bmesh_modifiers', "A script's bmesh edit, then leaving Edit Mode, under Subdivision, Remesh, "
                                    "Bevel, Array and Geometry Nodes")
def _bmesh_modifiers():
    import bmesh
    rounds = max(2, ROUNDS // 2)
    built = []
    for kind in ('SUBSURF', 'REMESH', 'BEVEL', 'ARRAY', 'GN'):
        g = _grid(kind, 20)
        for r in range(rounds):
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='EDIT')
            bm = bmesh.from_edit_mesh(g.data)
            bmesh.ops.subdivide_edges(bm, edges=bm.edges[:20], cuts=1)
            for v in bm.verts[:10]:
                v.co.z += 0.01
            if r % 2:
                bmesh.update_edit_mesh(g.data)
            said = _said(bpy.ops.object.mode_set, mode='OBJECT')
            if g.mode != 'OBJECT':
                bpy.ops.object.mode_set(mode='OBJECT')
            _mirror()
        built.append("%s %s" % ({'SUBSURF': 'Subdivision', 'REMESH': 'Remesh', 'BEVEL': 'Bevel', 'ARRAY': 'Array',
                                 'GN': 'Geometry Nodes'}[kind], _n(_count(g))))
    return "%d rounds each survived; Blender at %s" % (rounds, ", ".join(built))


@_check('crash', 'bmesh_leave_price', "An untold bmesh edit, then leaving Edit Mode in the same line, priced")
def _bmesh_leave_price():
    import bmesh
    _clear()
    a = _cube()
    m = a.modifiers.new("Array", 'ARRAY')
    m.fit_type, m.fit_length = 'FIT_LENGTH', 40.0
    bpy.context.view_layer.update()
    before = _count(a)
    with _budget_at(100_000):
        bpy.ops.object.mode_set(mode='EDIT')
        bm = bmesh.from_edit_mesh(a.data)
        for v in bm.verts:
            v.co.x *= 0.0001
        said = _said(bpy.ops.object.mode_set, mode='OBJECT')
        if a.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        said = said or _mirror()
        after = _count(a)
    _need(said is not None and "stops at 100,000" in said and after <= 100_000,
          "a cube under an Array fitted to 40 (%s) scaled to a ten-thousandth: %s, Blender at %s"
          % (_n(before), said or "passed", _n(after)))
    return "refused in words at a budget of 100,000; Blender %s -> %s" % (_n(before), _n(after))


@_check('crash', 'leave_unchanged', "Edit Mode round trips with nothing changed under Geometry Nodes price nothing")
def _leave_unchanged():
    g = _grid('GN')
    budget = _budget()
    calls = []
    inner = budget.price_state

    def counting(*args, **keywords):
        calls.append(1)
        return inner(*args, **keywords)
    budget.price_state = counting
    try:
        for _ in range(ROUNDS):
            bpy.context.view_layer.objects.active = g
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
            bpy.ops.object.mode_set(mode='OBJECT')
            _mirror()
    finally:
        budget.price_state = inner
    _need(not calls, "%d round trips priced %d times" % (ROUNDS, len(calls)))
    return "%d round trips survived, 0 prices" % ROUNDS


def _bevel_grid():
    _clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=120, y_subdivisions=120, size=2)
    g = bpy.context.object
    mod = g.modifiers.new("Bevel", 'BEVEL')
    mod.limit_method, mod.segments = 'WEIGHT', 14
    bpy.context.view_layer.update()
    return g


@_check('crash', 'bevel_weight_line', "Bevel Weights written by a script line after Edit Mode round trips")
def _bevel_weight_line():
    import numpy as np
    g = _bevel_grid()
    for _ in range(ROUNDS):
        _edit_rounds(g, lambda: None, rounds=1)
    before = _count(g)
    layer = g.data.attributes.get('bevel_weight_edge') or g.data.attributes.new('bevel_weight_edge', 'FLOAT', 'EDGE')
    layer.data.foreach_set('value', np.ones(len(g.data.edges), dtype=np.float32))
    g.data.update()
    said = _mirror()
    after = _count(g)
    _need(said is not None and "stops at" in said and after == before,
          "a 120 x 120 grid under a Bevel by Weight at 14 segments: %s, Blender %s -> %s"
          % (said or "passed", _n(before), _n(after)))
    return "refused in words; Blender stays at %s" % _n(after)


@_check('crash', 'bevel_weight_edit', "Bevel Weights set by bmesh in Edit Mode, then leaving it")
def _bevel_weight_edit():
    import bmesh
    g = _bevel_grid()
    before = _count(g)
    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(g.data)
    layer = bm.edges.layers.float.get('bevel_weight_edge') or bm.edges.layers.float.new('bevel_weight_edge')
    for e in bm.edges:
        e[layer] = 1.0
    said = _said(bpy.ops.object.mode_set, mode='OBJECT')
    if g.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    said = said or _mirror()
    after = _count(g)
    _need(said is not None and "stops at" in said and after <= _budget().BUDGET,
          "%s, Blender %s -> %s" % (said or "passed", _n(before), _n(after)))
    return "refused in words; Blender %s -> %s" % (_n(before), _n(after))


@_check('crash', 'image_removed', "An image removed while Blender's copies point at it")
def _image_removed():
    for r in range(ROUNDS):
        _clear()
        img = bpy.data.images.new("I%d" % r, 8, 8)
        bpy.ops.object.empty_add(type='IMAGE')
        empty = bpy.context.object
        empty.data = img
        cube = _cube("C")
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
        _mirror()
        built = _count(cube)
    return "%d rounds survived; the cube at %s vertices" % (ROUNDS, _n(built))


@_check('crash', 'font_removed', "A font removed while Blender's copies point at it")
def _font_removed():
    for r in range(ROUNDS):
        _clear()
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
        _mirror()
    return "%d rounds survived; the text's font now %r" % (ROUNDS, getattr(t.data.font, 'name', None))


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


@_check('crash', 'window_scene_removed', "The window's own scene removed (twice: the other scene empty, then "
                                         "holding a cube under an Array of 400,000)")
def _window_scene_removed():
    out = []
    for r in range(max(2, ROUNDS)):
        _clear()
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
        said = said or _mirror()
        internal = said is not None and "could not price" in said
        if heavy:
            built = _built(bpy.data.objects["H%d" % r], s2)
            _need(bpy.context.scene == s2 and said is not None and "stops at" in said and not internal
                  and built < 2_500_000,
                  "round %d (heavy): the window shows %s, said %r, Blender at %s"
                  % (r + 1, bpy.context.scene.name, said, _n(built)))
            out.append("heavy: refused in words, Blender at %s" % _n(built))
        else:
            _need(bpy.context.scene == s2 and said is None,
                  "round %d: the window shows %s, said %r" % (r + 1, bpy.context.scene.name, said))
            out.append("empty: the window shows the other scene, nothing said")
    return "; ".join(sorted(set(out)))


@_check('crash', 'window_scene_set', "The window given a scene with a cube under an Array of 400,000 linked "
                                     "since Blender evaluated it")
def _window_scene_set():
    _clear()
    first = bpy.context.scene
    s2 = bpy.data.scenes.new("S2")
    s2.collection.objects.link(bpy.data.objects.new("L", bpy.data.meshes.new("L")))
    with bpy.context.temp_override(scene=s2, view_layer=s2.view_layers[0]):
        bpy.context.evaluated_depsgraph_get()
    s2.collection.objects.link(_heavy("H"))
    bpy.context.window.scene = s2
    try:
        said = _mirror()
        built = _built(bpy.data.objects["H"], s2)
    finally:
        bpy.context.window.scene = first
    _need(said is not None and "stops at" in said and built < 2_500_000,
          "said %r, Blender at %s" % (said, _n(built)))
    return "refused in words; Blender at %s" % _n(built)


# --------------------------------------------------------------------------
# 2. Operators the context guards refuse, from tests/unsafe/blender/verify.py

def _fixture():
    scene = bpy.context.scene
    return scene, bpy.context.view_layer, bpy.data.scenes.new("Scene 2")


def _within(members, call):
    with bpy.context.temp_override(**members):
        return call()


def _scene_new_in_override(kind):
    scene, layer, scene2 = _fixture()
    scenes = len(bpy.data.scenes)
    said = _attempt(lambda: _within(dict(scene=scene2, view_layer=scene2.view_layers[0]),
                                    lambda: bpy.ops.scene.new(type=kind)))
    expected = "refused: bpy.ops.scene.new was not run: it gives the window another scene"
    _need(said.startswith(expected) and len(bpy.data.scenes) == scenes and bpy.context.scene == scene,
          "%s; %d scenes (was %d), the window shows %s" % (said[:200], len(bpy.data.scenes), scenes,
                                                           bpy.context.scene.name))
    after = _attempt(lambda: bpy.ops.object.select_all(action='SELECT'))
    _need(after.startswith("ran"), "the next operator: " + after[:160])
    return "refused in words (\"%s\"); the next operator ran" % said[len("refused: "):][:72]


@_check('guards', 'scene_full_copy', "New Scene, Full Copy, inside temp_override(scene=<another>, "
                                     "view_layer=<its own>)")
def _scene_full_copy():
    return _scene_new_in_override('FULL_COPY')


@_check('guards', 'scene_link_copy', "New Scene, Linked Copy, inside temp_override(scene=<another>, "
                                     "view_layer=<its own>)")
def _scene_link_copy():
    return _scene_new_in_override('LINK_COPY')


@_check('guards', 'window_scene_depsgraph', "The window given another scene inside temp_override(scene=<its own>, "
                                            "view_layer=<its own>), then evaluated_depsgraph_get()")
def _window_scene_depsgraph():
    scene, layer, scene2 = _fixture()

    def body():
        with bpy.context.temp_override(scene=scene, view_layer=layer):
            bpy.context.window.scene = scene2
            return bpy.context.evaluated_depsgraph_get()
    try:
        said = _attempt(body)
    finally:
        bpy.context.window.scene = scene
    expected = "refused: bpy.context.evaluated_depsgraph_get was not run"
    _need(said.startswith(expected), said[:200])
    after = _attempt(lambda: bpy.ops.object.select_all(action='SELECT'))
    _need(after.startswith("ran"), "the next operator: " + after[:160])
    return "refused in words; the next operator ran"


@_check('guards', 'window_scene_remove', "The window's own scene removed, then a cube added in the scene it shows")
def _window_scene_remove():
    first = bpy.context.scene
    other = bpy.data.scenes.new("Other")
    said = _attempt(lambda: bpy.data.scenes.remove(first))
    _need(said.startswith("ran") and bpy.context.scene == other, "%s; the window shows %s"
          % (said[:200], bpy.context.scene.name))
    added = _attempt(lambda: bpy.ops.mesh.primitive_cube_add())
    mirrored = _mirror()
    _need(added.startswith("ran") and mirrored is None and len(other.objects) == 1,
          "Add Cube: %s; the mirror: %s; %d objects there" % (added[:120], mirrored, len(other.objects)))
    return "removed; the window shows the other scene, a cube added there and mirrored"


@_check('guards', 'sealed_closures', "The guards' closures, each called from a script, refuse the call")
def _sealed_closures():
    import _bpy
    cells = {}
    for label, f, call in (("bpy.ops._op_create_function", bpy.ops._op_create_function,
                            lambda c: c("uv", "stitch")),
                           ("_bpy.ops.create_function", _bpy.ops.create_function, lambda c: c("uv", "stitch")),
                           ("_bpy.ops.macro_define", _bpy.ops.macro_define, lambda c: c(None, "UV_OT_stitch")),
                           ("bpy.types.Context.temp_override", bpy.types.Context.temp_override,
                            lambda c: c(bpy.context))):
        for i, cell in enumerate(getattr(f, "__closure__", None) or ()):
            held = cell.cell_contents
            key = "%s.__closure__[%d]" % (label, i)
            if type(held).__name__ in ("builtin_function_or_method", "method_descriptor"):
                cells[key] = "holds Blender's " + type(held).__name__
                continue
            if not callable(held):
                continue
            try:
                call(held)
                cells[key] = "called: ran"
            except TypeError as error:
                cells[key] = "called: refused" if "Blender's own" in str(error) else "called: " + str(error)[:60]
            try:
                held._inner
                cells[key] += ", ._inner handed out"
            except AttributeError:
                pass
    wrong = {k: v for k, v in cells.items() if v != "called: refused"}
    _need(len(cells) >= 4 and not wrong, "%d cells; %s" % (len(cells), wrong or "fewer than 4"))
    return "%d cells, each refused in words" % len(cells)


# --------------------------------------------------------------------------
# 3. One vertex-budget refusal per family, from the budget check's parts 12
#    (bypass.py), 12i (interface3.py) and 12j (interface4.py): refused, and
#    Blender's own count unchanged.

def _keyed_i3():
    """A cube under an Array whose Count is keyed 2 at frame 1 and 400,000
    at frame 10, held between them (interface3.py's `keyed_i3`)."""
    _clear()
    scene = bpy.context.scene
    a = _cube()
    m = a.modifiers.new("Array", 'ARRAY')
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.count = 400_000
    m.keyframe_insert("count", frame=10)
    with _bare():
        m.count = 2
    for curve in _fcurves(a.animation_data.action):
        for key in curve.keyframe_points:
            key.interpolation = 'CONSTANT'
    with _bare():
        scene.frame_set(1)
    return a, m


@_check('budget', 'array_count', "Array Count: a key written to 400,000 at the current frame by a script line "
                                 "(part 12.3)")
def _array_count():
    a, m = _cube_array()
    scene = bpy.context.scene
    with _bare():
        scene.frame_set(1)
    m.count = 2
    m.keyframe_insert("count", frame=1)
    m.count = 400_000
    m.keyframe_insert("count", frame=10)
    m.count = 2
    with _bare():
        scene.frame_set(1)
    before = _held(a)
    from bpy_extras import anim_utils
    bag = anim_utils.action_get_channelbag_for_slot(a.animation_data.action, a.animation_data.action_slot)
    bag.fcurves[0].keyframe_points[0].co.y = 400_000
    said = _mirror()
    key = bag.fcurves[0].keyframe_points[0].co.y
    _need(_refused(said, 3_200_000) and _count(a) == 16 and key == 2.0,
          "said %r, Blender at %s, the key at %g" % (said, _n(_count(a)), key))
    return "refused at 3,200,000; Blender stays at %s (was %s), the key back at %g" % (_n(_count(a)), _n(before), key)


@_check('budget', 'time_stretching', "Time Stretching: the script line `scene.render.frame_map_new = 10` with a "
                                     "Count keyed 400,000 at frame 10 (part 12i.1)")
def _time_stretching():
    a, m = _keyed_i3()
    scene = bpy.context.scene
    said = _line("bpy.context.scene.render.frame_map_new = 10")
    _need(_refused(said, 3_200_000) and _held(a) == 16 and scene.render.frame_map_new == 100,
          "said %r, Blender at %s, Map New at %d" % (said, _n(_held(a)), scene.render.frame_map_new))
    return "refused at 3,200,000; Blender stays at 16, Frame Map New back at 100"


@_check('budget', 'fcurve_modifier', "F-curve modifier: a Generator of (400,000, 0) on the keyed Count's F-curve "
                                     "by a script line (part 12i.2)")
def _fcurve_modifier():
    a, m = _keyed_i3()
    said = _line("curve = bpy.data.objects['A'].animation_data.action.layers[0].strips[0].channelbags[0]"
                 ".fcurves[0]\ng = curve.modifiers.new('GENERATOR')\ng.coefficients = (400000.0, 0.0)\n")
    curve = _fcurves(a.animation_data.action)[0]
    _need(_refused(said, 3_200_000) and curve.mute and _held(a) == 16 and _mirror() is None and _held(a) == 16,
          "said %r, the curve %s, Blender at %s" % (said, "muted" if curve.mute else "not muted", _n(_held(a))))
    return "refused at 3,200,000; the curve muted, Blender stays at 16 through the next mirror's pass"


@_check('budget', 'legacy_texture', "Legacy texture: the Data API row's Brightness 1 -> 2 of a Displace's Blend "
                                    "texture under a Remesh, at a budget of 20,000 (part 12i.7)")
def _legacy_texture():
    with _budget_at(20_000):
        _clear()
        d = _cube("D")
        texture = bpy.data.textures.new("T", 'BLEND')
        displace = d.modifiers.new("Displace", 'DISPLACE')
        displace.texture, displace.strength = texture, 20.0
        remesh = d.modifiers.new("Remesh", 'REMESH')
        remesh.mode, remesh.voxel_size = 'VOXEL', 0.5
        bpy.context.view_layer.update()
        before = _held(d)
        said = _said(lambda: _sync().set_property("bpy.data.textures['T']", 'intensity', 2.0))
        after = _held(d)
    _need(_refused(said) and after == before and texture.intensity == 1.0,
          "said %r, Blender %s -> %s, Brightness %g" % (said, _n(before), _n(after), texture.intensity))
    return "refused; Blender stays at %s, Brightness back at 1" % _n(after)


NESTED = """
bpy.ops.mesh.primitive_cube_add()
o = bpy.context.object
o.name = 'NR'
g = bpy.data.node_groups.new('Nested', 'GeometryNodeTree')
g.interface.new_socket('Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
out = g.nodes.new('NodeGroupOutput')
p1 = g.nodes.new('GeometryNodePoints'); p1.inputs['Count'].default_value = 100
p2 = g.nodes.new('GeometryNodePoints'); p2.inputs['Count'].default_value = 100
grid = g.nodes.new('GeometryNodeMeshGrid')
grid.inputs['Vertices X'].default_value = 20; grid.inputs['Vertices Y'].default_value = 20
i1 = g.nodes.new('GeometryNodeInstanceOnPoints'); i2 = g.nodes.new('GeometryNodeInstanceOnPoints')
r = g.nodes.new('GeometryNodeRealizeInstances')
g.links.new(p2.outputs[0], i1.inputs['Points']); g.links.new(grid.outputs[0], i1.inputs['Instance'])
g.links.new(p1.outputs[0], i2.inputs['Points']); g.links.new(i1.outputs[0], i2.inputs['Instance'])
g.links.new(i2.outputs[0], r.inputs[0]); g.links.new(r.outputs[0], out.inputs[0])
o.modifiers.new('GN', 'NODES').node_group = g
"""


@_check('budget', 'gn_instances', "Geometry Nodes instances: Points (100) -> Instance on Points of [Points (100) "
                                  "-> a 20 x 20 Grid] -> Realize Instances, by a script line (part 12i.3)")
def _gn_instances():
    _clear()
    said = _line(NESTED)
    nr = bpy.data.objects['NR']
    held = _held(nr) or 0
    _need(_refused(said, 4_000_000) and held <= 8, "said %r, Blender at %s" % (said, _n(held)))
    return "refused at 4,000,000; Blender holds %s" % _n(held)


def _gathered(n=299):
    """G: Collection Info of C -> Realize Instances; C, the active collection,
    holds M, a grid of (n + 1)^2; M selected (interface4.py's `gathered_j`)."""
    _clear()
    for block in list(bpy.data.collections):
        bpy.data.collections.remove(block)
    with _bare():
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=n, y_subdivisions=n, size=2)
        m = bpy.context.object
        m.name = "M"
        c = bpy.data.collections.new("C")
        bpy.context.scene.collection.children.link(c)
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
    bpy.context.view_layer.active_layer_collection = layer_of(bpy.context.view_layer.layer_collection)
    _select_only(m)
    return g, m


@_check('budget', 'duplicate_collection_info', "Shift+D three times into a collection a Collection Info realizes "
                                               "(a 300 x 300 grid, budget 200,000; part 12j.2)")
def _duplicate_collection_info():
    with _budget_at(200_000):
        g, m = _gathered()
        presses = []
        for _ in range(3):
            said = _said(lambda: bpy.ops.object.duplicate_move()) or _mirror()
            presses.append((said, _held(g) or 0))
    counts = ", ".join(_n(p[1]) for p in presses)
    _need(presses[0][0] is None and presses[0][1] == 180_000 and _refused(presses[1][0])
          and all(p[1] <= 200_000 for p in presses),
          "Blender at %s after each; said %r" % (counts, [p[0] for p in presses]))
    return "the first passed at 180,000, the second and third refused; Blender at %s" % counts


@_check('budget', 'driver', "A driver of '400000' on Array Count, added by a script line (part 12.2)")
def _driver():
    a, m = _cube_array()
    curve = m.driver_add("count")
    curve.driver.expression = "400000"
    said = _mirror()
    _need(_refused(said, 3_200_000) and _count(a) == 16 and curve.mute,
          "said %r, Blender at %s, the driver %s" % (said, _n(_count(a)), "muted" if curve.mute else "live"))
    return "refused at 3,200,000; Blender stays at 16, the driver muted"


@_check('budget', 'boolean', "Boolean: the Data API row's Fast Overlap Threshold 1e-6 -> 0.01 on two 40 x 40 "
                             "grids (part 12j.6)")
def _boolean():
    _clear()
    n = 40
    with _bare():
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
        m.operation, m.solver, m.double_threshold, m.object = 'UNION', 'FLOAT', 1e-6, b
    before = _held(a)
    started = time.perf_counter()
    said = _said(lambda: _sync().set_property("bpy.data.objects['A'].modifiers['Boolean']", 'double_threshold', 0.01))
    took = time.perf_counter() - started
    after = _held(a)
    _need(said is not None and ("Fast solver" in said or _refused(said)) and took < 3.0 and after == before
          and abs(m.double_threshold - 1e-6) < 1e-9,
          "said %r in %.2f s, Blender %s -> %s, the threshold %g" % (said, took, _n(before), _n(after),
                                                                      m.double_threshold))
    return "refused for Blender's own time in %.2f s, nothing evaluated; Blender stays at %s" % (took, _n(after))


# --------------------------------------------------------------------------
# 4. Ordinary edits pass, and quickly

def _timed(call):
    started = time.perf_counter()
    said = _said(call)
    said = said or _mirror()
    return said, time.perf_counter() - started


def _ordinary(said, took, what):
    _need(said is None, "%s was refused: %s" % (what, said))
    _need(took < ORDINARY_SECONDS, "%s took %.2f s (more than %g s)" % (what, took, ORDINARY_SECONDS))


@_check('ordinary', 'move', "Move: a 100 x 100 grid under a Subdivision")
def _move():
    _clear()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=100, y_subdivisions=100, size=2)
    g = bpy.context.object
    g.modifiers.new("Subdivision", 'SUBSURF').levels = 1
    bpy.context.view_layer.update()
    _select_only(g)
    said, took = _timed(lambda: bpy.ops.transform.translate(value=(0.5, 0.0, 0.0)))
    _ordinary(said, took, "the Move")
    _need(abs(g.location.x - 0.5) < 1e-6, "the grid at x = %g" % g.location.x)
    return "passed in %.2f s with the mirror's pass; Blender at %s vertices" % (took, _n(_held(g)))


@_check('ordinary', 'extrude', "Extrude: Mesh > Extrude of a plane in Edit Mode")
def _extrude_ordinary():
    _clear()
    bpy.ops.mesh.primitive_plane_add()
    c = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    said, took = _timed(lambda: bpy.ops.mesh.extrude_region_shrink_fatten(
        TRANSFORM_OT_shrink_fatten={"value": 0.2}))
    bpy.ops.object.mode_set(mode='OBJECT')
    _ordinary(said, took, "Extrude")
    _need(len(c.data.vertices) == 8, "the plane at %d vertices, not 8" % len(c.data.vertices))
    return "passed in %.2f s; the plane at 8 vertices" % took


@_check('ordinary', 'subdivide', "Subdivide: a cube's edges, 2 cuts, in Edit Mode")
def _subdivide():
    _clear()
    c = _cube("C")
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    said, took = _timed(lambda: bpy.ops.mesh.subdivide(number_cuts=2))
    bpy.ops.object.mode_set(mode='OBJECT')
    _ordinary(said, took, "Subdivide")
    _need(len(c.data.vertices) == 56, "the cube at %d vertices, not 56" % len(c.data.vertices))
    return "passed in %.2f s; the cube at 56 vertices" % took


@_check('ordinary', 'add_modifier', "Add Modifier: Subdivision Surface on a cube")
def _add_modifier():
    _clear()
    c = _cube("C")
    _select_only(c)
    said, took = _timed(lambda: bpy.ops.object.modifier_add(type='SUBSURF'))
    _ordinary(said, took, "Add Modifier")
    _need(len(c.modifiers) == 1, "%d modifiers" % len(c.modifiers))
    return "passed in %.2f s; Blender at %s vertices" % (took, _n(_held(c)))


@_check('ordinary', 'legal_array', "A legal Array: the Data API row's Count 2 -> 50 on a cube")
def _legal_array():
    a, m = _cube_array()
    said, took = _timed(lambda: _sync().set_property("bpy.data.objects['A'].modifiers['Array']", 'count', 50))
    _ordinary(said, took, "Count 50")
    _need(m.count == 50 and _held(a) == 400, "Count %d, Blender at %s" % (m.count, _n(_held(a))))
    return "passed in %.2f s; Blender at 400 vertices" % took


# --------------------------------------------------------------------------
# 5. The mirror's pass, as the app runs it after a script

SCENE_LINE = """
bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
bpy.context.object.modifiers.new('Subdivision', 'SUBSURF').levels = 2
bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
bpy.ops.object.text_add(location=(0, 3, 0))
bpy.ops.curve.primitive_bezier_circle_add(location=(3, 3, 0))
bpy.context.object.data.bevel_depth = 0.1
bpy.ops.object.metaball_add(location=(-3, 0, 0))
bpy.ops.object.empty_add(location=(0, -3, 0))
bpy.ops.object.light_add(type='POINT', location=(4, -4, 4))
bpy.ops.object.camera_add(location=(7, -7, 5))
"""


@_check('mirror', 'mirror_pass', "The mirror's pass after a script: a cube under Subdivision, a sphere, a text, a "
                                 "curve, a metaball, an empty, a light and a camera")
def _mirror_pass():
    _clear()
    exec(compile(SCENE_LINE, "<line>", "exec"), {"bpy": bpy})
    started = time.perf_counter()
    pushed = _sync().sync()
    took = time.perf_counter() - started
    _need(isinstance(pushed, int) and pushed >= 5, "the pass mirrored %r of 8 objects" % (pushed,))
    again = time.perf_counter()
    _sync().sync()
    second = time.perf_counter() - again
    return "%d objects with geometry mirrored in %.3f s (again: %.3f s)" % (pushed, took, second)


# --------------------------------------------------------------------------
# 6. A small EEVEE render through the Render panel's own script
#    (RenderRequest.python, which the app hands in)

RENDER = {"source": None, "output": None}


def _png_size(path):
    import struct
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    return struct.unpack('>II', head[16:24])


@_check('render', 'eevee', "A 64 x 64 EEVEE render through the Render panel's script (Metal)")
def _eevee():
    source, output = RENDER["source"], RENDER["output"]
    _need(source and output, "no render script was handed in")
    if os.path.exists(output):
        os.remove(output)
    try:
        import gpu
        gpu.init()
    except Exception:                      # noqa: BLE001 - the render says it in its own words
        pass
    started = time.perf_counter()
    try:
        exec(compile(source, "<render>", "exec"), {"bpy": bpy})
        took = time.perf_counter() - started
        _need(os.path.isfile(output), "no image was written")
        size = _png_size(output)
        _need(size == (64, 64), "the image is %r, not 64 x 64" % (size,))
        image = bpy.data.images.load(output, check_existing=False)
        try:
            pixels = array('f', [0.0]) * (len(image.pixels))
            image.pixels.foreach_get(pixels)
        finally:
            bpy.data.images.remove(image)
        lit = sum(1 for i in range(0, len(pixels), 4) if max(pixels[i], pixels[i + 1], pixels[i + 2]) > 0.02)
        _need(lit > 0, "every pixel black")
        engine = bpy.context.scene.render.engine
        samples = getattr(getattr(bpy.context.scene, 'eevee', None), 'taa_render_samples', '?')
        return "%s, %s samples, 64 x 64 in %.2f s; %d of 4,096 pixels lit" % (engine, samples, took, lit)
    finally:
        if os.path.exists(output):
            os.remove(output)


# --------------------------------------------------------------------------
# What Blender holds of the user's work, compared before and after

def _r(*values):
    return tuple(round(v, 5) if isinstance(v, float) else v for v in values)


def _vec(values):
    return tuple(round(float(v), 5) for v in values)


def _kept(blocks):
    """The data-blocks a save keeps: Blender writes none with no user and
    no fake user, so an orphan is gone after any save and load (the app's
    own launch included) and is not the Self-Test's to keep."""
    return [b for b in blocks if b.users or b.use_fake_user]


def fingerprint():
    """Every scene, object, mesh, curve, collection and data-block name, with
    what each holds that a check could change; meshes by their vertex
    positions' hash. A list of rows, compared whole."""
    rows = []

    def row(*values):
        rows.append(repr(values))

    window = bpy.context.window
    row('window', window.scene.name if window else None,
        bpy.context.view_layer.name if bpy.context.view_layer else None)
    for s in bpy.data.scenes:
        row('scene', s.name, s.frame_current, s.frame_start, s.frame_end, s.render.engine,
            s.render.resolution_x, s.render.resolution_y, s.render.frame_map_old, s.render.frame_map_new,
            s.camera.name if s.camera else None, s.world.name if s.world else None,
            _vec(s.cursor.location), sorted(o.name for o in s.objects), s.collection.name,
            sorted(c.name for c in s.collection.children))
        for layer in s.view_layers:
            active = layer.objects.active
            row('view layer', s.name, layer.name, active.name if active else None,
                sorted(o.name for o in layer.objects if o.select_get(view_layer=layer)))
    for o in _kept(bpy.data.objects):
        row('object', o.name, o.type, o.data.name if o.data else None, o.parent.name if o.parent else None,
            o.mode, _vec(o.location), o.rotation_mode, _vec(o.rotation_euler), _vec(o.rotation_quaternion),
            _vec(o.scale), o.hide_viewport, o.hide_render, o.hide_get() if o.name in bpy.context.view_layer.objects
            else None, [(m.name, m.type, m.show_viewport) for m in o.modifiers],
            [(c.name, c.type) for c in o.constraints],
            [slot.material.name if slot.material else None for slot in o.material_slots],
            sorted(c.name for c in o.users_collection),
            o.animation_data.action.name if o.animation_data and o.animation_data.action else None,
            o.instance_type, o.instance_collection.name if o.instance_collection else None)
    vertices = 0
    for me in _kept(bpy.data.meshes):
        co = array('f', [0.0]) * (len(me.vertices) * 3)
        me.vertices.foreach_get('co', co)
        vertices += len(me.vertices)
        row('mesh', me.name, len(me.vertices), len(me.edges), len(me.polygons), len(me.loops),
            hashlib.sha1(co.tobytes()).hexdigest()[:16], sorted(a.name for a in me.attributes),
            [u.name for u in me.uv_layers], [m.name if m else None for m in me.materials],
            [k.name for k in me.shape_keys.key_blocks] if me.shape_keys else None)
    for c in _kept(bpy.data.curves):
        points = sum(len(s.points) + len(s.bezier_points) for s in c.splines)
        row('curve', c.name, type(c).__name__, len(c.splines), points, getattr(c, 'body', None),
            _r(c.extrude, c.bevel_depth, c.resolution_u))
    for name, collection in (('collection', bpy.data.collections),):
        for c in _kept(collection):
            row(name, c.name, sorted(o.name for o in c.objects), sorted(k.name for k in c.children),
                c.hide_viewport, c.hide_render)
    for name, blocks in (('material', bpy.data.materials), ('node group', bpy.data.node_groups),
                         ('image', bpy.data.images), ('action', bpy.data.actions), ('texture', bpy.data.textures),
                         ('light', bpy.data.lights), ('camera', bpy.data.cameras), ('world', bpy.data.worlds),
                         ('text', bpy.data.texts), ('metaball', bpy.data.metaballs),
                         ('armature', bpy.data.armatures), ('lattice', bpy.data.lattices),
                         ('grease pencil', getattr(bpy.data, 'grease_pencils', ())),
                         ('font', bpy.data.fonts), ('particles', bpy.data.particles)):
        for b in _kept(blocks):
            extra = ()
            if name in ('material', 'node group', 'world') and getattr(b, 'node_tree' if name != 'node group'
                                                                       else 'nodes', None) is not None:
                tree = b if name == 'node group' else b.node_tree
                extra = (len(tree.nodes), len(tree.links))
            elif name == 'image':
                extra = (tuple(b.size), b.source, bool(b.packed_file))
            elif name == 'action':
                extra = (len(_fcurves(b)) if hasattr(b, 'layers') else 0,)
            elif name == 'light':
                extra = (b.type, _r(float(b.energy)), _vec(b.color))
            elif name == 'camera':
                extra = (b.type, _r(float(b.lens)))
            elif name == 'text':
                extra = (hashlib.sha1(b.as_string().encode('utf-8', 'replace')).hexdigest()[:12],)
            row(name, b.name, *extra)
    return rows, len(bpy.data.objects), vertices


def _differences(before, after):
    gone = [r for r in before if r not in set(after)]
    new = [r for r in after if r not in set(before)]
    return gone, new


# --------------------------------------------------------------------------
# Scratch scenes, and the user's scene put back

def _opening(path=None, words=None, priced=False):
    """`_blenderkit_gate.opening` as the app's own loads use it, or nothing
    where the gate has none."""
    gate = _gate()
    opening = getattr(gate, 'opening', None)
    if opening is None:
        return contextlib.nullcontext()
    if not hasattr(gate, 'vouch'):
        return opening()
    return opening(path=path, words=words, priced=priced)


class _Run:
    """One run: the history root, whether the history has had its first
    Self-Test step, and the scene put back. `label` names the history's step
    (Test All Features' run is one of these too, under its own name)."""

    def __init__(self, history_root, label="Self-Test"):
        self.history_root = history_root
        self.label = label
        self.pushed = False
        self.history = None

    def push(self):
        """A step of the app's history after a load, as the app pushes one
        after File > New; after the first, each takes the place of the one
        before, so Undo never reaches a check's scene."""
        if not self.history_root:
            return
        self.history = _undo().push(self.history_root, self.label, replace=self.pushed)
        self.pushed = True

    def fresh(self):
        """Blender's startup file, as File > New opens it (`Bpy.newScene`:
        the app's own load, priced as a script's load)."""
        with _opening(words="File ▸ New's startup file", priced=True):
            result = bpy.ops.wm.read_homefile(load_ui=False, use_factory_startup=True)
        if 'FINISHED' not in result:
            raise Fail("Blender's startup file did not open: %r" % (result,))
        self.push()

    def restore(self, path):
        """The user's scene, opened again as the app opens its recovery file
        at launch: as saved while it is as the app wrote it."""
        gate = _gate()
        vouched = getattr(gate, 'vouched', None)
        trusted = vouched is not None and vouched(path)
        with (_opening(path=path) if trusted else _opening()):
            result = bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
        if 'FINISHED' not in result:
            raise RuntimeError("Blender did not open %s: %r" % (path, result))


# --------------------------------------------------------------------------
# The report

def _footprint():
    """(this process's memory footprint now, its peak over the process's
    life), in bytes, from `proc_pid_rusage` (RUSAGE_INFO_V4); None where it
    cannot be read."""
    try:
        import ctypes
        buffer = (ctypes.c_uint64 * 37)()
        if ctypes.CDLL(None).proc_pid_rusage(os.getpid(), 4, ctypes.byref(buffer)) != 0:
            return None
        # A 16-byte UUID, then the fields: ri_phys_footprint is the 8th,
        # ri_lifetime_max_phys_footprint the 29th.
        return int(buffer[2 + 7]), int(buffer[2 + 28])
    except Exception:                      # noqa: BLE001 - memory is reported only when it is cheap
        return None


def _sysctl(name, number=False):
    try:
        import ctypes
        lib = ctypes.CDLL(None)
        size = ctypes.c_size_t(0)
        if lib.sysctlbyname(name.encode(), None, ctypes.byref(size), None, 0) != 0:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if lib.sysctlbyname(name.encode(), buffer, ctypes.byref(size), None, 0) != 0:
            return None
        if number:
            return int.from_bytes(buffer.raw[:size.value], sys.byteorder)
        return buffer.value.decode('utf-8', 'replace')
    except Exception:                      # noqa: BLE001
        return None


def _mb(value):
    return "%s MB" % format(int(round(value / 1048576.0)), ',')


def _about_defaults():
    """What the header says where the app said nothing (the desktop)."""
    try:
        return _about_found()
    except Exception as error:             # noqa: BLE001 - the header never stops the run
        return [("Device", "unknown (%s)" % error)]


def _about_found():
    memory = _sysctl('hw.memsize', number=True)
    model = _sysctl('hw.model') or platform.machine()
    system = ("iOS " + platform.ios_ver().release if hasattr(platform, 'ios_ver') and sys.platform == 'ios'
              else "macOS " + (platform.mac_ver()[0] or platform.release()))
    return [("Device", model), ("System", system),
            ("RAM", "%.1f GB" % (memory / 1073741824.0) if memory else "unknown"),
            ("App", "not the app: desktop Blender with the app's modules")]


def _clean(text):
    return " ".join(str(text).replace("\t", " ").split())


def _duration(seconds):
    if seconds < 60:
        return "%.1f s" % seconds
    return "%d min %.1f s" % (int(seconds // 60), seconds % 60)


class _Report:
    def __init__(self, path, about):
        self.path = path
        self.about = about
        self.lines = []
        self.running = None
        self.total = None
        self.summary = None
        self.memory = None
        self.notes = []
        self.started = time.time()

    def header(self):
        out = ["Blender Local Self-Test", ""]
        for key, value in self.about:
            out.append("%-9s %s" % (key + ":", value))
        out.append("%-9s %s" % ("Blender:", bpy.app.version_string))
        out.append("%-9s %s" % ("Python:", platform.python_version()))
        out.append("%-9s %s" % ("Started:", time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.started))))
        out.append("%-9s %s" % ("Total:", _duration(self.total) if self.total is not None
                                else "did not finish (the last check started is the last line)"))
        if self.memory:
            out.append("%-9s %s" % ("Memory:", self.memory))
        for note in self.notes:
            out.append("%-9s %s" % ("Note:", note))
        return out

    def write(self):
        body = list(self.header()) + [""] + list(self.lines)
        if self.running:
            body.append("RUNNING  %s" % self.running)
        if self.summary:
            body += ["", self.summary]
        folder = os.path.dirname(self.path)
        if folder:
            os.makedirs(folder, exist_ok=True)
        partial = self.path + ".partial"
        with open(partial, "w", encoding="utf-8") as f:
            f.write("\n".join(body) + "\n")
        os.replace(partial, self.path)

    def text(self):
        with open(self.path, encoding="utf-8") as f:
            return f.read()


def _result_line(passed, seconds, name, detail):
    return "%s  %7.2f s  %s — %s" % ("PASS" if passed else "FAIL", seconds, name, _clean(detail))


def console_progress(index, total, name, result=None):
    """`run`'s progress, printed for the app's sheet (`SelfTest.event`): one
    tab-separated line as each check starts and as it ends."""
    if result is None:
        print("[self-test] start\t%d\t%d\t%s" % (index, total, _clean(name)), flush=True)
    else:
        passed, seconds, detail = result
        print("[self-test] done\t%d\t%d\t%s\t%.2f\t%s\t%s" % (index, total, "PASS" if passed else "FAIL",
                                                             seconds, _clean(name), _clean(detail)), flush=True)


def _say(progress, *args):
    if progress is None:
        return
    try:
        progress(*args)
    except Exception:                      # noqa: BLE001 - the progress shown never stops the run
        pass


# --------------------------------------------------------------------------
# The run

def run(report_path, progress=None, about=None, history_root=None, render_source=None,
        render_output=None, only=None, rounds=None):
    """Runs every check one after another and writes the report to
    `report_path`; returns a dict of what it found.

    `progress(index, total, name, result=None)` is told as each check starts,
    and again with (passed, seconds, detail) as it ends (`console_progress`
    prints both for the app). `about` is the header's (key, value) pairs:
    device, system, RAM and the app's version and build. `history_root` is
    the app's undo history folder (`BpySession.historyRoot`).
    `render_source` is the Render panel's script for a 64 x 64 EEVEE render
    writing `render_output`. `only` runs the checks with these keys alone,
    `rounds` sets the freed-memory cases' rounds."""
    global ROUNDS
    started = time.perf_counter()
    if rounds:
        ROUNDS = int(rounds)
    RENDER["source"], RENDER["output"] = render_source, render_output
    about = [tuple(pair) for pair in (about or [])]
    have = {key for key, _ in about}
    if 'iOS' in have:
        have.add('System')
    about += [pair for pair in _about_defaults() if pair[0] not in have]
    report = _Report(report_path, about)
    checks = sorted((c for c in CHECKS if not only or c[1] in only), key=lambda c: ORDER.index(c[0]))
    total = len(checks) + 1                       # and the user's scene, put back
    memory_before = _footprint()
    outcome = dict(passed=0, failed=0, total=total, report=report_path, restored=False, history=None)

    def record(passed, seconds, name, detail):
        report.lines.append(_result_line(passed, seconds, name, detail))
        outcome['passed' if passed else 'failed'] += 1

    def end():
        outcome['seconds'] = report.total
        outcome['summary'] = report.summary
        if progress is console_progress:
            print("[self-test] end\t%d\t%d\t%d\t%.1f\t%s" % (outcome['passed'], outcome['failed'],
                                                            outcome['passed'] + outcome['failed'], report.total,
                                                            report_path), flush=True)
            if outcome['history'] is not None:
                print("[self-test] history\t" + json.dumps(outcome['history']), flush=True)
        return outcome

    def not_run(why):
        """Nothing was changed, and no check ran: said as the one line."""
        name = "The Self-Test"
        _say(progress, 1, 1, name)
        record(False, 0.0, name, "not run: " + why)
        _say(progress, 1, 1, name, (False, 0.0, "not run: " + why))
        report.summary = "Summary:  not run"
        report.total = time.perf_counter() - started
        report.write()
        return end()

    report.write()
    if not _on_main_thread():
        return not_run("it runs on the main thread only, where Blender's window is")
    dirty = [image.name for image in bpy.data.images if image.is_dirty]
    if dirty:
        return not_run("painted pixels of %s are not saved in the scene yet, and the Self-Test opens the saved "
                       "scene again; leave Texture Paint, or pack the image, first" % ", ".join(dirty))

    gate, budget = _gate(), _budget()
    busy, ceiling = getattr(gate, '_busy', 0), budget.BUDGET
    session = _Run(history_root or getattr(_undo(), '_root', None))
    # The user's scene, saved as the app writes its recovery file (the app
    # has written that too, a moment before: if anything here takes the app
    # down, the next launch opens it).
    saved = os.path.join(tempfile.gettempdir(), "blender-local-self-test-%d.blend" % os.getpid())
    try:
        _undo().autosave(saved)
        before, objects, vertices = fingerprint()
    except Exception as error:                     # noqa: BLE001 - said, and nothing is touched
        return not_run("your scene could not be saved first (%s: %s)" % (type(error).__name__, error))
    report.notes.append("your scene (%s object%s, %s vertices) was saved and is opened again at the end"
                        % (_n(objects), "" if objects == 1 else "s", _n(vertices)))
    stopped = None
    try:
        for index, (group, key, name, function) in enumerate(checks, 1):
            _say(progress, index, total, name)
            report.running = name
            report.write()
            began = time.perf_counter()
            try:
                session.fresh()
                detail = function()
                passed = True
            except Fail as error:
                passed, detail = False, str(error)
            except KeyboardInterrupt:
                passed, detail = False, "stopped"
                stopped = name
            except Exception as error:             # noqa: BLE001 - a check that raises is a FAIL, and the run goes on
                frame = traceback.extract_tb(error.__traceback__)[-1]
                passed, detail = False, "raised %s: %s (%s line %d)" % (
                    type(error).__name__, error, os.path.basename(frame.filename), frame.lineno)
            seconds = time.perf_counter() - began
            # What a check may not leave behind: the gate switched off, or the
            # budget lowered.
            if getattr(gate, '_busy', 0) != busy:
                gate._busy = busy
                passed, detail = False, "left the gate switched off; " + str(detail)
            if budget.BUDGET != ceiling:
                budget.BUDGET = ceiling
                passed, detail = False, "left the budget changed; " + str(detail)
            report.running = None
            record(passed, seconds, name, detail)
            _say(progress, index, total, name, (passed, seconds, detail))
            report.write()
            if stopped:
                break
    finally:
        name = "Your scene, opened again"
        _say(progress, total, total, name)
        report.running = name
        report.write()
        began = time.perf_counter()
        error = None
        for attempt in range(3):
            try:
                session.restore(saved)
                error = None
                break
            except KeyboardInterrupt as interrupted:
                error = interrupted
            except Exception as failed:            # noqa: BLE001 - said in the report, with where the scene is
                error = failed
                break
        if error is None:
            after, objects_after, vertices_after = fingerprint()
            gone, new = _differences(before, after)
            passed = not gone and not new
            detail = ("%s object%s, %s vertices, as before the test" % (
                _n(objects_after), "" if objects_after == 1 else "s", _n(vertices_after))
                      if passed else "differs from before the test: was %s; now %s"
                      % ("; ".join(gone[:3]) or "-", "; ".join(new[:3]) or "-"))
            outcome['restored'] = passed
            # Its history step, in the place of the checks' own.
            try:
                session.push()
            except Exception as failed:            # noqa: BLE001 - said: Undo may then reach a check's scene
                passed = False
                detail += ("; but the undo history could not be put right (%s: %s), so Undo may reach a "
                           "check's scene" % (type(failed).__name__, failed))
        else:
            passed, detail = False, ("could not be opened (%s: %s); it is saved in %s, and File ▸ Revert opens "
                                     "the app's recovery file" % (type(error).__name__, error, saved))
        seconds = time.perf_counter() - began
        report.running = None
        record(passed, seconds, name, detail)
        _say(progress, total, total, name, (passed, seconds, detail))
        if error is None:
            for path in (saved, saved + '1'):
                if os.path.exists(path):
                    os.remove(path)
            forget = getattr(gate, 'forget', None)
            if forget is not None:
                forget(saved)
        outcome['history'] = session.history
        report.total = time.perf_counter() - started
        memory_after = _footprint()
        if memory_before and memory_after:
            report.memory = "peak %s over the app's life; %s before the test, %s after" % (
                _mb(max(memory_before[1], memory_after[1])), _mb(memory_before[0]), _mb(memory_after[0]))
        if stopped:
            report.notes.append("stopped during: " + stopped)
        report.summary = "Summary:  %d of %d passed, %d failed, in %s" % (
            outcome['passed'], outcome['passed'] + outcome['failed'], outcome['failed'], _duration(report.total))
        report.write()
    return end()
