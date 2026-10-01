"""The scenes the operator-search check runs every operator on.

Each starts the way the app's File > New does (read_homefile with load_ui off)
and gives Blender the undo stack the app always has (`ed.undo_push` under a
window and screen override, as _blenderkit_undo does): without one, sculpt's
undo code reads a NULL stack, which is a crash of the test, not of the app.
"""
import bpy

FIXTURES = ('plain', 'rich', 'skin')
MODES = ('OBJECT', 'EDIT', 'SCULPT', 'TEXTURE_PAINT')
# The modifiers each fixture's cube carries, by name.
MODIFIERS = {'plain': (), 'rich': ('Multires', 'Hook'), 'skin': ('Skin',)}


def undo_stack():
    w = bpy.context.window_manager.windows[0]
    with bpy.context.temp_override(window=w, screen=w.screen):
        bpy.ops.ed.undo_push(message="Original")


def build(fixture, mode):
    """A cube called Cube, everything selected, left in `mode`."""
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
    bpy.ops.object.mode_set(mode=mode)
    return cube
