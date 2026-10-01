"""Blender's meshes, written out for the Swift side of
scripts/run-symmetry-blender-check.sh: what the app's mirror would hand the
viewport on a device — positions, loop triangles and the polygon of each,
Blender's edges in Blender's order, and `matrix_world` — and the `kind`
string `_blenderkit_sync._kind` writes for the mesh with each combination of
its symmetry flags, which is how the flags reach the app.
"""
import bpy, sys, json, pathlib, types, importlib.util
from array import array

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixtures  # noqa: E402

ROOT = HERE.parents[2]
sys.modules.setdefault('_blenderkit', types.ModuleType('_blenderkit'))
spec = importlib.util.spec_from_file_location(
    '_blenderkit_sync', ROOT / 'Resources/python/site/_blenderkit_sync.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

out = {}
for name in fixtures.FIXTURES:
    obj = fixtures.build(name)
    mesh = obj.data
    mesh.calc_loop_triangles()
    m = obj.matrix_world
    out[name] = {
        'co': [c for v in mesh.vertices for c in v.co],
        'tris': [i for t in mesh.loop_triangles for i in t.vertices],
        'tri_poly': [t.polygon_index for t in mesh.loop_triangles],
        'polygons': len(mesh.polygons),
        'edges': [i for e in mesh.edges for i in e.vertices],
        # Column-major, as simd_float4x4 is built.
        'matrix': [m[r][c] for c in range(4) for r in range(4)],
    }
    # While editing, the mirror draws the evaluated mesh, read in edit mode,
    # and the selection report carries what `_edit_coordinates` returns: the
    # edit mesh's own coordinates under a modifier shown in edit mode, else
    # nothing.
    bpy.ops.object.mode_set(mode='EDIT')
    obj.update_from_editmode()
    sent = sync._edit_coordinates(obj, obj.data, len(obj.data.vertices))
    out[name]['sent'] = len(sent)
    if sent:
        evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
        shown = evaluated.to_mesh()
        assert len(shown.vertices) == len(mesh.vertices)
        out[name]['co'] = [c for v in shown.vertices for c in v.co]
        evaluated.to_mesh_clear()
        flat = array('f')
        flat.frombytes(sent)
        out[name]['blender_co'] = list(flat)
    bpy.ops.object.mode_set(mode='OBJECT')

# The flags as the mirror sends them, in object mode and in edit mode.
obj = fixtures.build('grid')
kinds = {}
for mode in ('OBJECT', 'EDIT'):
    bpy.ops.object.mode_set(mode=mode)
    for combo in ('', 'x', 'y', 'z', 't', 'xt', 'yz', 'xyz', 'xyzt'):
        mesh = obj.data
        mesh.use_mirror_x = 'x' in combo
        mesh.use_mirror_y = 'y' in combo
        mesh.use_mirror_z = 'z' in combo
        mesh.use_mirror_topology = 't' in combo
        kinds[mode + ':' + combo] = sync._kind(obj)
bpy.ops.object.mode_set(mode='OBJECT')
# Not a mesh: no flag, whatever a light's data holds.
bpy.ops.object.light_add(type='POINT')
kinds['LIGHT'] = sync._kind(bpy.context.object)
out['kinds'] = kinds

with open(sys.argv[-1], 'w') as f:
    json.dump(out, f)
print("wrote %d meshes and %d kind strings to %s" % (len(fixtures.FIXTURES), len(kinds), sys.argv[-1]))
