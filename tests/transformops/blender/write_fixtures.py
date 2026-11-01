"""Stage 1: the fixtures as the app's mirror would hand them to the viewport —
each object's `matrix_world`, an edited mesh's positions, loop triangles and
edges, the selection — and the orientation matrices `_blenderkit_orient`
reports for each, which the Swift draws its gizmo on (stage 2)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
import fixtures


def matrix(obj):
    m = obj.matrix_world
    return [m[r][c] for c in range(4) for r in range(4)]


out = {}
for name in fixtures.FIXTURES:
    active = fixtures.build(name)
    scene = bpy.context.scene
    record = {
        'mode': active.mode,
        'pivot': scene.tool_settings.transform_pivot_point,
        'cursor': list(scene.cursor.location),
        'objects': [{'name': o.name, 'matrix': matrix(o), 'selected': o.select_get(),
                     'parent': o.parent.name if o.parent else None}
                    for o in bpy.context.view_layer.objects],
        'active': active.name,
        'orient': {},
    }
    for kind in ('GLOBAL', 'LOCAL', 'NORMAL', 'GIMBAL', 'CURSOR', 'PARENT'):
        m = orient.matrix(kind)
        record['orient'][kind] = [c for axis in m for c in axis]
    if active.mode == 'EDIT':
        active.update_from_editmode()
        mesh = active.data
        mesh.calc_loop_triangles()
        record['co'] = [c for v in mesh.vertices for c in v.co]
        record['tris'] = [i for t in mesh.loop_triangles for i in t.vertices]
        record['tri_poly'] = [t.polygon_index for t in mesh.loop_triangles]
        record['polygons'] = len(mesh.polygons)
        record['edges'] = [i for e in mesh.edges for i in e.vertices]
        record['selected'] = [v.index for v in mesh.vertices if v.select]
    out[name] = record

with open(sys.argv[-1], 'w') as f:
    json.dump(out, f)
print("wrote %d fixtures to %s" % (len(out), sys.argv[-1]))
