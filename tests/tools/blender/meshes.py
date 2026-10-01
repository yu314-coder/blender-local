"""Blender's edit-mode meshes, written out for the Swift side of
scripts/run-tools-blender-check.sh.

What is written is what the app's mirror would hand the viewport on a device:
positions, loop triangles, the polygon each triangle belongs to, Blender's own
edges and the object's `matrix_world`. The Swift previews its drags on exactly
these, so what verify.py then compares is the preview against Blender on one
and the same mesh.
"""
import bpy, sys, json, pathlib

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fixtures  # noqa: E402

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
        # The face corner behind each triangle corner, and a UV per corner:
        # what the mirror's `sync_uvs` sends, from which the Swift tells a
        # quad's diagonal from its edges.
        'loops': [i for t in mesh.loop_triangles for i in t.loops],
        'uvs': [c for d in mesh.uv_layers.active.data for c in d.uv] if mesh.uv_layers.active else [],
        # Column-major, as simd_float4x4 is built.
        'matrix': [m[r][c] for c in range(4) for r in range(4)],
    }
# What each object of the relations fixture depends on, as the mirror's own
# `_blenderkit_sync._relations` reads it: the record the Swift side works the
# snap exclusions out from, which verify.py holds against Blender's depsgraph.
import types  # noqa: E402
import importlib.util  # noqa: E402
sys.modules.setdefault('_blenderkit', types.ModuleType('_blenderkit'))
ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    '_blenderkit_sync', ROOT / 'Resources/python/site/_blenderkit_sync.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
records = {}
for obj in fixtures.relations():
    parent, names = sync._relations(obj)
    records[obj.name] = {'parent': parent, 'depends': names}
out['relations'] = records

with open(sys.argv[-1], 'w') as f:
    json.dump(out, f)
print("wrote %d meshes and %d objects' relations to %s"
      % (len(fixtures.FIXTURES), len(records), sys.argv[-1]))
