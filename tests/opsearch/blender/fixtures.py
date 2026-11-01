"""The scenes the operator-search check runs every operator on.

Each starts the way the app's File > New does (read_homefile with load_ui off)
and gives Blender the undo stack the app always has (`ed.undo_push` under a
window and screen override, as _blenderkit_undo does): without one, sculpt's
undo code reads a NULL stack, which is a crash of the test, not of the app.
"""
import bpy

FIXTURES = ('plain', 'rich', 'skin')
# Weight Paint and Vertex Paint since round 4: the bar takes Blender into
# both now (`_blenderkit_vwpaint`), and the search runs from there too.
# LOCAL_VIEW is Object Mode with the cube alone in Local View and an object
# outside it selected: there the app sends every command, the search's rows
# among them, inside `_blenderkit_localview.run`, which runs it under the
# borrowed 3D View (round 4's review of group 7) — a context the other modes'
# rows, with no area, never had.
MODES = ('OBJECT', 'EDIT', 'SCULPT', 'TEXTURE_PAINT', 'WEIGHT_PAINT', 'VERTEX_PAINT', 'LOCAL_VIEW')
# A file saved in Sculpt Mode, Weight Paint or Vertex Paint, opened as the app
# opens its autosave at launch (open_mainfile, load_ui=False) in a session
# whose workspace has no tools: the 3D View then has no tool for the mode,
# which the modes above, entered in the session, always had (round 4's fix
# round). Every operator the search lists is swept from these three, with
# the app's guards installed: `brush.asset_activate` with a brush crashed
# Blender there and nowhere else (`_blenderkit_context.UNSAFE_OPERATORS`), so
# whatever else the missing tool reaches is found here. Texture Paint opens
# with its tool, as do Grease Pencil's modes and Sculpt Curves (measured).
OPENED = ('OPENED_SCULPT', 'OPENED_WEIGHT_PAINT', 'OPENED_VERTEX_PAINT')
# The modifiers each fixture's cube carries, by name.
MODIFIERS = {'plain': (), 'rich': ('Multires', 'Hook'), 'skin': ('Skin',)}


def undo_stack():
    w = bpy.context.window_manager.windows[0]
    with bpy.context.temp_override(window=w, screen=w.screen):
        bpy.ops.ed.undo_push(message="Original")


def build(fixture, mode):
    """A cube called Cube, everything selected, left in `mode`."""
    if mode in OPENED:
        return opened(fixture, mode[len('OPENED_'):])
    bpy.ops.wm.read_homefile(use_empty=True, load_ui=False)
    undo_stack()
    bpy.ops.mesh.primitive_cube_add(size=2)
    cube = bpy.context.object
    cube.name = 'Cube'
    if fixture == 'rich':
        group = cube.vertex_groups.new(name='Group')
        group.add(range(len(cube.data.vertices)), 1.0, 'REPLACE')
        cube.modifiers.new('Multires', 'MULTIRES')
        bpy.ops.object.multires_subdivide(modifier='Multires', mode='CATMULL_CLARK')
        empty = bpy.data.objects.new('Hook Target', None)
        bpy.context.scene.collection.objects.link(empty)
        hook = cube.modifiers.new('Hook', 'HOOK')
        hook.object = empty
        hook.vertex_indices_set([0, 1, 2, 3])
        bpy.context.view_layer.objects.active = cube
        cube.select_set(True)
    elif fixture == 'skin':
        cube.modifiers.new('Skin', 'SKIN')
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    if mode == 'LOCAL_VIEW':
        bpy.ops.object.mode_set(mode='OBJECT')
        local_view(cube)
        return cube
    bpy.ops.object.mode_set(mode=mode)
    return cube


def local_view(cube):
    """The cube alone in the borrowed 3D View's Local View, as View ▸ Local
    View leaves it, then an empty outside it selected too, as an Outliner tap
    selects one. The view keeps its Local View across the next fixture's
    read_homefile (load_ui off keeps the screen), so it is left first."""
    import _blenderkit_localview as lv
    if lv.active():
        lv._in_view(lambda: bpy.ops.view3d.localview(frame_selected=False))
    outside = bpy.data.objects.new('Outside', None)
    bpy.context.scene.collection.objects.link(outside)
    outside.location = (4, 0, 0)
    for o in bpy.context.view_layer.objects:
        o.select_set(o == cube)
    bpy.context.view_layer.objects.active = cube
    lv._in_view(lambda: bpy.ops.view3d.localview(frame_selected=False))
    outside.select_set(True)
    bpy.context.view_layer.objects.active = cube
    bpy.context.evaluated_depsgraph_get()
    if lv.members() != {'Cube'}:
        raise RuntimeError('Local View holds ' + repr(lv.members()) + ', not the cube alone')


def opened(fixture, mode):
    """The fixture saved in `mode`, then opened as the app opens its autosave
    in a session whose workspace has no tools: the startup file's interface
    read first, which holds none (measured in 5.2.1: `read_homefile(
    load_ui=True)` empties every workspace's tools, as a fresh launch has
    them). Raises if the 3D View has a tool for the mode after all, so a
    Blender that keeps one cannot make these partitions measure nothing."""
    import os
    build(fixture, mode)
    path = os.path.join(bpy.app.tempdir, 'opened-%s-%s.blend' % (fixture, mode.lower()))
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    bpy.ops.wm.read_homefile(use_empty=True, load_ui=True)
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    undo_stack()
    cube = bpy.data.objects['Cube']
    key = {'SCULPT': 'SCULPT', 'WEIGHT_PAINT': 'PAINT_WEIGHT', 'VERTEX_PAINT': 'PAINT_VERTEX'}[mode]
    if cube.mode != mode or bpy.context.workspace.tools.from_space_view3d_mode(key, create=False) is not None:
        raise RuntimeError('opened in %s with a 3D View tool: not the state this measures' % cube.mode)
    return cube
