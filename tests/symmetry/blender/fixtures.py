"""The meshes the mirror-editing checks drag, built the same way twice: once
for the Swift side (meshes.py), and again in verify.py to run what the Swift
sends. Both runs start from `--factory-startup`, so the same operators give
the same vertex and edge order.

Each object is moved, turned and scaled unevenly: Blender mirrors in the
mesh's own space, and a preview that mirrored in the world's would be right
only for an object at rest.

  * grid    — 11 × 11 vertices, with a column on x = 0 and a row on y = 0;
  * cube    — a cube subdivided twice, symmetric in X, Y and Z;
  * monkey  — Suzanne, whose halves Topology Mirror can pair by their edges;
  * skewed  — Suzanne with its +X half pushed out of place, so only Topology
              Mirror still finds the pairs;
  * twisted — the grid under a SimpleDeform with its defaults (Twist, 45°
              about X, shown in edit mode), so what the viewport draws is not
              symmetric while the edit mesh Blender pairs on is;
  * sphere, cylinder, torus, monkey2 (Suzanne subdivided twice) — more
              edge graphs for Topology Mirror's pairs.
"""
import bpy
import bmesh

FIXTURES = ('grid', 'cube', 'monkey', 'skewed', 'twisted', 'sphere', 'cylinder', 'torus', 'monkey2')


def build(name):
    """A fresh scene holding one mesh object called `name`, in object mode."""
    bpy.ops.wm.read_homefile(use_empty=True)
    if name in ('grid', 'twisted'):
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=10, size=2)
        if name == 'twisted':
            bpy.context.object.modifiers.new("SimpleDeform", 'SIMPLE_DEFORM')
    elif name == 'cube':
        bpy.ops.mesh.primitive_cube_add(size=2)
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.subdivide(number_cuts=2)
        bpy.ops.object.mode_set(mode='OBJECT')
    elif name == 'sphere':
        bpy.ops.mesh.primitive_uv_sphere_add()
    elif name == 'cylinder':
        bpy.ops.mesh.primitive_cylinder_add()
    elif name == 'torus':
        bpy.ops.mesh.primitive_torus_add()
    elif name == 'monkey2':
        bpy.ops.mesh.primitive_monkey_add(size=2)
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.subdivide(number_cuts=1)
        bpy.ops.mesh.subdivide(number_cuts=1)
        bpy.ops.object.mode_set(mode='OBJECT')
    elif name in ('monkey', 'skewed'):
        bpy.ops.mesh.primitive_monkey_add(size=2)
        if name == 'skewed':
            for v in bpy.context.object.data.vertices:
                if v.co.x > 0.01:
                    v.co.x += 0.013 * (1 + v.index % 5)
                    v.co.z += 0.007 * (v.index % 3)
    else:
        raise ValueError(name)
    obj = bpy.context.object
    obj.name = name
    obj.location = (0.5, -0.25, 0.3)
    obj.rotation_euler = (0.2, 0.0, 0.6)
    obj.scale = (1.5, 0.8, 1.0)
    bpy.context.view_layer.update()
    return obj


def select_vertices(obj, indices, hidden=()):
    """Edit mode on `obj` with exactly these vertices selected and these
    hidden, in vertex select mode — what the app's selection push leaves
    Blender holding."""
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.tool_settings.mesh_select_mode = (True, False, False)
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    for f in bm.faces:
        f.select = False
    for e in bm.edges:
        e.select = False
    for v in bm.verts:
        v.select = False
    for i in indices:
        bm.verts[i].select = True
    bm.select_flush_mode()
    for i in hidden:
        bm.verts[i].hide = True
    bmesh.update_edit_mesh(obj.data)
