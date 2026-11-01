"""The undo steps Blender itself records, measured in whichever Blender runs this.

tests/names/blender/verify.py measures these in desktop Blender 5.2.1. The
app embeds another build (bpy 5.3), and the only undo names round 4 read in
the app were the app's own: its history pushes each step under the app's
label (`_blenderkit_undo.push` → `ed.undo_push(message=label)`), so reading
them back from Blender's stack showed the app's strings arriving, not that
they are Blender's (round 4's review). This asks Blender: each operator is
called with its undo on, as a button's call is, and the step Blender pushed
is read back from its own stack (`_blenderkit_undo.blender_steps`).

It runs the same in the app (`-eval64`, on the main thread: it mentions
temp_override) and in desktop Blender (blender/verify.py runs it there as
well, to hold this script to its own measurement). It loads no file and
pushes no step of its own: the fixture is made with `bpy.data` in the scene
that is open, and taken out again at the end. The context is the one a
script and the Operator Search have in the app — a window and its screen, no
area — where an operator called with its undo on opens no redo panel
(`wm_operator_finished` asks for one only in an area; the view-polling
operators that crashed desktop Blender doing that are not called here).

Output: one line per call, `[steps] <call>: <step>`, and the same as JSON at
STEPS_OUT (a variable the caller may set), else blenderlocal-app-steps.json
in the temporary folder. tests/names/app_steps_compare.py holds a run's JSON
to the steps the app records (tests/names/main.swift's dump).
"""
import json
import os
import tempfile

import bmesh
import bpy
import _blenderkit_undo

OUT = globals().get('STEPS_OUT') or os.path.join(tempfile.gettempdir(), 'blenderlocal-app-steps.json')
NAMES = ('StepsCube', 'StepsBall', 'StepsTriangle')


def _active():
    rows = _blenderkit_undo.blender_steps() or []
    active = [row for row in rows if row[3]]
    return (active[-1][0], active[-1][2]) if active else None


def _object_mode():
    o = bpy.context.view_layer.objects.active
    if o is not None and o.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')


def _clear():
    for o in list(bpy.data.objects):
        if o.name.split('.')[0] in NAMES:
            bpy.data.objects.remove(o)
    for m in list(bpy.data.meshes):
        if m.users == 0 and m.name.split('.')[0] in NAMES:
            bpy.data.meshes.remove(m)


def _mesh(name, make):
    bm = bmesh.new()
    make(bm)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def scene(edit=None):
    """A cube with a sphere parented to it, both selected, the cube active;
    in Edit Mode with `edit` selected (ALL, EDGE, NONE) — the scene
    blender/verify.py measures in, made in the open scene."""
    _object_mode()
    _clear()
    # The view layer still lists what _clear removed until it is updated
    # (None in its place: measured on the app's autosave in desktop 5.2.1).
    bpy.context.view_layer.update()
    for o in bpy.context.view_layer.objects:
        if o is not None:
            o.select_set(False)
    cube = _mesh('StepsCube', lambda bm: bmesh.ops.create_cube(bm, size=2))
    ball = _mesh('StepsBall', lambda bm: bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=8, radius=1))
    ball.location = (3, 0, 0)
    ball.parent = cube
    ball.select_set(True)
    cube.select_set(True)
    bpy.context.view_layer.objects.active = cube
    bpy.context.view_layer.update()
    if edit:
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_mode(type='VERT')
        bpy.ops.mesh.select_all(action='SELECT' if edit == 'ALL' else 'DESELECT')
        if edit == 'EDGE':
            bm = bmesh.from_edit_mesh(cube.data)
            bm.edges.ensure_lookup_table()
            bm.select_mode = {'EDGE'}
            bm.edges[0].select = True
            bm.select_flush_mode()
            bmesh.update_edit_mesh(cube.data)


def cases(obj_file):
    ops = bpy.ops
    return {
        "object.select_all": (None, lambda: ops.object.select_all('EXEC_DEFAULT', True, action='SELECT')),
        "mesh.select_all": ('ALL', lambda: ops.mesh.select_all('EXEC_DEFAULT', True, action='INVERT')),
        "object.editmode_toggle": (None, lambda: ops.object.editmode_toggle('EXEC_DEFAULT', True)),
        "object.mode_set:EDIT": (None, lambda: ops.object.mode_set('EXEC_DEFAULT', True, mode='EDIT')),
        "object.mode_set:OBJECT": ('ALL', lambda: ops.object.mode_set('EXEC_DEFAULT', True, mode='OBJECT')),
        "sculpt.sculptmode_toggle": (None, lambda: ops.object.mode_set('EXEC_DEFAULT', True, mode='SCULPT')),
        "mesh.duplicate_move": ('ALL', lambda: ops.mesh.duplicate_move('EXEC_DEFAULT', True)),
        "object.duplicate_move": (None, lambda: ops.object.duplicate_move('EXEC_DEFAULT', True)),
        "object.delete": (None, lambda: ops.object.delete('EXEC_DEFAULT', True)),
        "mesh.delete": ('ALL', lambda: ops.mesh.delete('EXEC_DEFAULT', True, type='VERT')),
        "mesh.separate": ('EDGE', lambda: ops.mesh.separate('EXEC_DEFAULT', True, type='SELECTED')),
        "object.shade_smooth": (None, lambda: ops.object.shade_smooth('EXEC_DEFAULT', True)),
        "object.shade_flat": (None, lambda: ops.object.shade_flat('EXEC_DEFAULT', True)),
        "mesh.mark_seam": ('EDGE', lambda: ops.mesh.mark_seam('EXEC_DEFAULT', True, clear=True)),
        "mesh.mark_sharp": ('EDGE', lambda: ops.mesh.mark_sharp('EXEC_DEFAULT', True, clear=True)),
        "transform.translate": (None, lambda: ops.transform.translate('EXEC_DEFAULT', True, value=(1, 0, 0))),
        "transform.rotate": (None, lambda: ops.transform.rotate('EXEC_DEFAULT', True, value=0.3)),
        "transform.resize": (None, lambda: ops.transform.resize('EXEC_DEFAULT', True, value=(2, 2, 2))),
        "mesh.hide": ('ALL', lambda: ops.mesh.hide('EXEC_DEFAULT', True, unselected=False)),
        "mesh.reveal": ('ALL', lambda: ops.mesh.reveal('EXEC_DEFAULT', True)),
        "object.modifier_add": (None, lambda: ops.object.modifier_add('EXEC_DEFAULT', True, type='SUBSURF')),
        "mesh.extrude_region_shrink_fatten": ('ALL', lambda: ops.mesh.extrude_region_shrink_fatten('EXEC_DEFAULT',
                                                                                                   True)),
        "mesh.extrude_faces_move": ('ALL', lambda: ops.mesh.extrude_faces_move('EXEC_DEFAULT', True)),
        "mesh.select_edge_loop_multi": ('EDGE', lambda: ops.mesh.select_edge_loop_multi('EXEC_DEFAULT', True)),
        "mesh.subdivide_edgering": ('EDGE', lambda: ops.mesh.subdivide_edgering('EXEC_DEFAULT', True)),
        "mesh.tris_convert_to_quads": ('ALL', lambda: ops.mesh.tris_convert_to_quads('EXEC_DEFAULT', True)),
        "mesh.vertices_smooth": ('ALL', lambda: ops.mesh.vertices_smooth('EXEC_DEFAULT', True)),
        "mesh.edge_face_add": ('ALL', lambda: ops.mesh.edge_face_add('EXEC_DEFAULT', True)),
        "mesh.merge": ('ALL', lambda: ops.mesh.merge('EXEC_DEFAULT', True, type='CENTER')),
        "transform.vert_slide": ('EDGE', lambda: ops.transform.vert_slide('EXEC_DEFAULT', True, value=0.1)),
        "mesh.quads_convert_to_tris": ('ALL', lambda: ops.mesh.quads_convert_to_tris('EXEC_DEFAULT', True)),
        "object.parent_clear": (None, lambda: ops.object.parent_clear('EXEC_DEFAULT', True)),
        "object.select_hierarchy": (None, lambda: ops.object.select_hierarchy('EXEC_DEFAULT', True,
                                                                             direction='CHILD')),
        "object.select_by_type": (None, lambda: ops.object.select_by_type('EXEC_DEFAULT', True, type='MESH')),
        "object.select_pattern": (None, lambda: ops.object.select_pattern('EXEC_DEFAULT', True,
                                                                         pattern='Steps*')),
        "object.origin_set": (None, lambda: ops.object.origin_set('EXEC_DEFAULT', True, type='ORIGIN_GEOMETRY')),
        "object.transform_apply": (None, lambda: ops.object.transform_apply('EXEC_DEFAULT', True, location=True,
                                                                           rotation=False, scale=False)),
        "object.vertex_group_add": (None, lambda: ops.object.vertex_group_add('EXEC_DEFAULT', True)),
        "object.shape_key_add": (None, lambda: ops.object.shape_key_add('EXEC_DEFAULT', True, from_mix=True)),
        "object.join": (None, lambda: ops.object.join('EXEC_DEFAULT', True)),
        "wm.obj_import": (None, lambda: ops.wm.obj_import('EXEC_DEFAULT', True, filepath=obj_file)),
    }


def measure():
    """{call: the step Blender pushed for it, None when it pushed none or did
    not finish, "ERROR ..." when it raised}."""
    # Entering Sculpt Mode with its undo on segfaults a Blender that has no
    # undo stack (`_blenderkit_undo.ensure_stack`, which the app's history now
    # calls; this script found it, report BlenderLocal-2026-10-19-210858).
    if not _blenderkit_undo.blender_steps():
        raise RuntimeError("Blender has no undo stack here, so there is nothing to measure "
                           "(and entering Sculpt Mode with its undo on would crash it).")
    # The importer names the object after the file: StepsTriangle.
    obj_file = os.path.join(tempfile.gettempdir(), 'StepsTriangle.obj')
    with open(obj_file, 'w') as f:
        f.write("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
    steps = {}
    try:
        for key, (edit, call) in cases(obj_file).items():
            try:
                scene(edit)
                before = _active()
                result = call()
                after = _active()
                steps[key] = after[1] if after and after != before and 'FINISHED' in result else None
            except Exception as error:
                steps[key] = f"ERROR {type(error).__name__}: {error}"
    finally:
        try:
            _object_mode()
        finally:
            _clear()
            os.remove(obj_file)
    return steps


def run():
    # The app's script context: its window and that window's screen, no area.
    window = bpy.context.window or bpy.context.window_manager.windows[0]
    with bpy.context.temp_override(window=window, screen=window.screen):
        steps = measure()
    with open(OUT, 'w') as f:
        json.dump({"version": bpy.app.version_string, "steps": steps}, f, indent=1, sort_keys=True)
    print(f"[steps] Blender {bpy.app.version_string}, {len(steps)} calls, written to {OUT}")
    for key, step in steps.items():
        print(f"[steps] {key}: {step}")
    return steps


if __name__ == '__main__' or globals().get('STEPS_RUN'):
    run()
