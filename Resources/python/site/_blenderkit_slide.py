"""G pressed twice in Edit Mode: Blender's Edge Slide and Vertex Slide, previewed.

During Move in a mesh's Edit Mode, G again turns the move into Edge Slide
(TFM_MODAL_TRANSLATE in transform.cc, 5.2.1): the selected edges slide along
the faces beside them. Where Edge Slide cannot slide the selection, Blender
tries Vertex Slide, each selected vertex along one of its own edges; where that
fails too, it stays a Move.

The app previews the slide itself, as it previews every transform, from what
these functions read out of Blender before the pointer moves:

* Edge Slide moves every vertex in a straight line, linearly in its factor:
  measured in 5.2.1 on a cylinder's middle loop, the place at 0.5, -0.3 and 0.8
  was the start mixed with the place at +1 or -1 by that fraction, within
  6e-8. So `edge` runs it once at +1 and once at -1 and reports both ends.
* Vertex Slide, run without a pointer, slides each vertex along the edge
  pointing most nearly the way of its `direction` (a world-space vector);
  measured, also linear, and still at a negative value (Clamp). The app picks
  the edge the pointer points along, as Blender does, and `vertex` reports
  where a factor of 1 takes each vertex that way. `links` gives the app the
  edges to choose from.

Each run is undone before anything else sees it: the operator is called with
its undo off ('EXEC_DEFAULT', False) and every vertex is put back exactly where
it was, so the probe leaves neither a step in the history nor a moved vertex.
`correct_uv` is off for the probe (it changes the UVs and not the places); the
commit runs the operator as the Edge menu does, with Blender's defaults.

`mirror` is what the commit sends: True when the mesh mirrors on an axis
(LastOperator.mesh, `honoursMeshSymmetry`), so the ends include the mirror
images the commit will move too.

`even`, `flipped` and `clamp` are the slide's E, F and C keys
(`handleEventEdgeSlide`, `handleEventVertSlide`): the operators' `use_even`,
`flipped` and `use_clamp`. Measured in 5.2.1 on a tube of three uneven rings,
each case at five factors against the mix of its own ±1 ends: Edge Slide
without Even stays a straight mix (1.3e-7), past ±1 too with Clamp off;
with Even it does not (0.08 off with Clamp, 0.9 without). Vertex Slide stays
a mix (1.2e-7) except with Even and Flipped together. Where it is not a mix,
`at` reports where the slide puts every vertex at one factor, and the app
asks again whenever the factor changes.

Each function prints one line of JSON, or {"kind": null} when there is nothing
to slide.
"""
import json


def _edit_bmesh():
    import bpy
    import bmesh
    ob = bpy.context.edit_object
    if ob is None or ob.type != 'MESH':
        return None, None
    bm = bmesh.from_edit_mesh(ob.data)
    bm.verts.ensure_lookup_table()
    return ob, bm


def _run_and_put_back(ob, op, **props):
    """Runs a slide with its undo off, reads where every vertex went, and puts
    every vertex back. None when Blender did not slide (CANCELLED)."""
    import bmesh
    bm = bmesh.from_edit_mesh(ob.data)
    bm.verts.ensure_lookup_table()
    start = [v.co.copy() for v in bm.verts]
    result = op('EXEC_DEFAULT', False, correct_uv=False, **props)
    bm = bmesh.from_edit_mesh(ob.data)
    bm.verts.ensure_lookup_table()
    moved = {}
    for i, v in enumerate(bm.verts):
        if i < len(start) and v.co != start[i]:
            moved[i] = tuple(v.co)
            v.co = start[i]
    if moved:
        bmesh.update_edit_mesh(ob.data, loop_triangles=True, destructive=False)
    if 'FINISHED' not in result:
        return None, start
    return moved, start


def _report(kind, start, ends):
    return json.dumps({
        'kind': kind,
        'count': len(start),
        'v': [[i, list(start[i]), list(plus), list(minus)] for i, (plus, minus) in sorted(ends.items())],
    })


def _flags(mirror, even, flipped, clamp):
    extra = {'use_even': bool(even), 'flipped': bool(flipped), 'use_clamp': bool(clamp)}
    if mirror:
        extra['mirror'] = True
    return extra


def edge(mirror=False, even=False, flipped=False, clamp=True):
    """Edge Slide's two ends for every vertex it moves, or kind null when
    Blender cannot edge-slide the selection."""
    import bpy
    ob, bm = _edit_bmesh()
    if ob is None:
        print(json.dumps({'kind': None}))
        return
    extra = _flags(mirror, even, flipped, clamp)
    plus, start = _run_and_put_back(ob, bpy.ops.transform.edge_slide, value=1.0, **extra)
    if not plus:
        print(json.dumps({'kind': None}))
        return
    minus, _ = _run_and_put_back(ob, bpy.ops.transform.edge_slide, value=-1.0, **extra)
    minus = minus or {}
    ends = {i: (plus.get(i, tuple(start[i])), minus.get(i, tuple(start[i])))
            for i in set(plus) | set(minus)}
    print(_report('EDGE', start, ends))


def links():
    """Each selected vertex, where it is, and the vertices at the other ends
    of its edges — what the pointer chooses an edge from."""
    ob, bm = _edit_bmesh()
    if ob is None:
        print(json.dumps({'kind': None}))
        return
    out = [[v.index, list(v.co), [list(e.other_vert(v).co) for e in v.link_edges]]
           for v in bm.verts if v.select and not v.hide and v.link_edges]
    print(json.dumps({'kind': 'VERTEX' if out else None, 'count': len(bm.verts), 'links': out}))


def vertex(direction, mirror=False, even=False, flipped=False, clamp=True):
    """Vertex Slide's ends at a factor of 1 and -1 for every vertex it moves
    along the edges pointing most nearly `direction` (with Clamp on, -1
    moves nothing and the end is where the vertex is)."""
    import bpy
    ob, bm = _edit_bmesh()
    if ob is None:
        print(json.dumps({'kind': None}))
        return
    extra = _flags(mirror, even, flipped, clamp)
    plus, start = _run_and_put_back(ob, bpy.ops.transform.vert_slide, value=1.0,
                                    direction=tuple(direction), **extra)
    if not plus:
        print(json.dumps({'kind': None}))
        return
    minus = {}
    if not clamp:
        minus, _ = _run_and_put_back(ob, bpy.ops.transform.vert_slide, value=-1.0,
                                     direction=tuple(direction), **extra)
        minus = minus or {}
    ends = {i: (plus.get(i, tuple(start[i])), minus.get(i, tuple(start[i])))
            for i in set(plus) | set(minus)}
    print(_report('VERTEX', start, ends))


def at(kind, value, mirror=False, even=False, flipped=False, clamp=True, direction=None):
    """Where the slide at `value` puts every vertex it moves, each reported
    with that place as both ends: for the slides that are not a straight
    mix of their ends. Kind null when Blender would not slide."""
    import bpy
    ob, bm = _edit_bmesh()
    if ob is None:
        print(json.dumps({'kind': None}))
        return
    extra = _flags(mirror, even, flipped, clamp)
    if kind == 'VERTEX':
        if direction is None:
            print(json.dumps({'kind': None}))
            return
        extra['direction'] = tuple(direction)
        op = bpy.ops.transform.vert_slide
    else:
        op = bpy.ops.transform.edge_slide
    moved, start = _run_and_put_back(ob, op, value=float(value), **extra)
    if moved is None:
        print(json.dumps({'kind': None}))
        return
    print(json.dumps({'kind': kind, 'count': len(start),
                      'v': [[i, list(start[i]), list(p), list(p)] for i, p in sorted(moved.items())]}))
