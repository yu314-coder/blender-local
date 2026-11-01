"""Edit Mode's Statistics and Measurement overlays, worked out from Blender's
edit mesh as Blender's 3D View works them out.

The 3D View's Overlays popover has Statistics (`show_stats`) and, for a mesh
in Edit Mode, Measurement: Edge Length, Edge Angle, Face Area and Face Angle
(`show_extra_edge_length`, … — `VIEW3D_PT_overlay_edit_mesh_measurement`).
Blender draws those numbers into its 3D View's text cache, which a Blender
without a window never draws and Python cannot read, so the numbers are
computed here by the code Blender draws them with, ported line for line:

  * the statistics are `stats_object_edit` summed over the objects in Edit
    Mode, with `stats_update`'s object count (info_stats.cc in the 5.3 source);
  * the measurements are `DRW_text_edit_mesh_measure_stats`
    (draw_manager_text.cc): the selected edges' lengths and the angles
    between their two faces' normals, the selected faces' areas summed over
    their tessellation triangles and the angles at each of their corners,
    in the object's space or — with the Sidebar's Global — through its
    matrix, as V3D_GLOBAL_STATS makes Blender do.

The positions are world space; the app clips an edge's to the view and
formats every value with the scene's units, as Blender does
(EditMeasure.swift, BlenderUnits.swift). Blender draws the measurements on
the edit cage; with a modifier shown on the cage the cage is a mesh Python
cannot reach (`BKE_object_get_editmesh_eval_cage`), so the measurements say
so instead of drawing numbers Blender would not.

What is handed over is bounded (`LABELS`). Blender writes a label for every
selected element into a text cache it draws and throws away; the app parses
what comes back on its main thread and draws each label as a view. Round 4's
review measured the unbounded read on a grid with everything selected and all
four switches on: 90,000 faces took 2.4 s in Python and 65 MB of JSON, which
the Swift parse took 1.95 s and 219 MB to read; 490,000 faces 12–14 s and
355 MB (Blender at 2.28 GB), and 4.4 million labels at 4 s a redraw. So the
read is Blender's own, exactly as before, while it stays within `LABELS`; past
that it is culled to the view the app draws (a label whose anchor is outside
the window is not drawn by Blender either: `DRW_text_cache_draw` projects with
V3D_PROJ_TEST_CLIP_WIN) and, if more than `LABELS` are still in view, every
n-th is kept and the record says so, for the app to say in words.
"""
import json

import bpy

# The most labels a read hands over. A SwiftUI Canvas draws a label in 17 µs
# on an M-series Mac (1,000 in 16.8 ms, 2,000 in 34.2 ms, measured with the
# overlay's own font and colour), and the 3D View redraws every label each
# frame of an orbit; 1,000 is also about as many as fit on an iPad's 3D View
# without lying on one another (a label is about 45 × 13 points).
LABELS = 1000
# Elements per chunk of the culled read, which keeps its working arrays to a
# few MB whatever the mesh (the app's mirror goes to 10 million vertices).
_CHUNK = 1 << 16
# The view's side planes are widened by this much of w for the cull, so the
# float rounding of the app's own clip (single precision) cannot keep a label
# the cull dropped; the app clips exactly afterwards.
_WIDEN = 1e-4


class _Full(Exception):
    """The exact read went past its budget."""


def _edit_objects():
    return [o for o in bpy.context.view_layer.objects
            if o.type == 'MESH' and o.mode == 'EDIT']


def _on_cage(obj):
    """The modifier Blender draws Edit Mode's cage from, if any: the last one
    shown in Edit Mode with On Cage on (`editbmesh_calc_modifiers`)."""
    named = None
    for md in obj.modifiers:
        if md.show_viewport and md.show_in_editmode and getattr(md, 'show_on_cage', False):
            named = md.name
    return named


def _local_view():
    sync = __import__('sys').modules.get('_blenderkit_sync')
    return getattr(sync, '_local', None) if sync is not None else None


def statistics():
    """`stats_update` in Edit Mode: [objects in Edit Mode, objects counted,
    selected vertices, vertices, selected edges, edges, selected faces,
    faces, triangles] over the meshes being edited."""
    import bmesh
    local = _local_view()
    counted = editing = 0
    v = vs = e = es = f = fs = t = 0
    for obj in bpy.context.view_layer.objects:
        # BASE_ENABLED_AND_VISIBLE_IN_DEFAULT_VIEWPORT.
        if not obj.visible_get():
            continue
        if obj.mode == 'EDIT':
            if obj.type == 'MESH':
                bm = bmesh.from_edit_mesh(obj.data)
                me = obj.data
                v += len(bm.verts); vs += me.total_vert_sel
                e += len(bm.edges); es += me.total_edge_sel
                f += len(bm.faces); fs += me.total_face_sel
                # `em->looptris.size()`: a face of n corners is n - 2.
                t += sum(len(face.verts) - 2 for face in bm.faces)
            editing += 1
        elif local is not None and obj.name not in local:
            # Outside Local View, unless it is being edited.
            continue
        counted += 1
    return [editing, counted, vs, v, es, e, fs, f, t]


def _angle_v3v3(a, b):
    import math
    la, lb = a.length, b.length
    na = a / la if la > 0.0 else a
    nb = b / lb if lb > 0.0 else b
    if na.dot(nb) >= 0.0:
        return 2.0 * math.asin(min(max((na - nb).length / 2.0, -1.0), 1.0))
    return math.pi - 2.0 * math.asin(min(max((na + nb).length / 2.0, -1.0), 1.0))


class _Space:
    """An object's matrices, as `DRW_text_edit_mesh_measure_stats` uses them."""

    def __init__(self, obj, use_global):
        self.mw = obj.matrix_world
        self.m3 = self.mw.to_3x3()
        self.i3 = self.mw.inverted_safe().to_3x3()
        self.use_global = use_global

    def w(self, co):
        return list(self.mw @ co)


# One row per label, each exactly what the overlay would draw for that element
# (shared by the whole read and the culled one, so both write the same rows).

def _length_row(edge, s):
    a, b = edge.verts[0].co, edge.verts[1].co
    if s.use_global:
        length = (s.m3 @ a - s.m3 @ b).length
    else:
        length = (a - b).length
    return s.w(a) + s.w(b) + [length]


def _edge_angle_row(edge, s):
    """None unless exactly two faces meet at the edge (BM_edge_loop_pair)."""
    la = edge.link_loops[0] if edge.link_loops else None
    if la is None:
        return None
    lb = la.link_loop_radial_next
    if lb == la or lb.link_loop_radial_next != la:
        return None
    na, nb = la.face.normal.copy(), lb.face.normal.copy()
    if s.use_global:
        na = (s.i3 @ na).normalized()
        nb = (s.i3 @ nb).normalized()
    a, b = edge.verts[0].co, edge.verts[1].co
    return s.w(a) + s.w(b) + [_angle_v3v3(na, nb)]


def _area_row(triangles, s):
    """Face Area's row for a face whose tessellation is `triangles`."""
    from mathutils import Vector
    area = 0.0
    mid = Vector((0.0, 0.0, 0.0))
    for loops in triangles:
        v1, v2, v3 = (loop.vert.co for loop in loops)
        mid += v1 + v2 + v3
        if s.use_global:
            v1, v2, v3 = s.m3 @ v1, s.m3 @ v2, s.m3 @ v3
        area += (v2 - v1).cross(v3 - v1).length / 2.0
    n = 3 * len(triangles)
    if n:
        mid = mid * (1.0 / n)
    return s.w(mid) + [area]


def _quad_flip(v1, v2, v3, v4):
    """`is_quad_flip_v3_first_third_fast` (math_geom.cc)."""
    d13 = v3 - v1
    return (v2 - v1).cross(d13).dot((v4 - v1).cross(d13)) > 0.0


class _Tessellation:
    """Each face's triangles as Blender's edit mesh tessellates it, which Face
    Area sums (`em->looptris`, `BM_mesh_calc_tessellation` in
    bmesh_mesh_tessellate.cc): a triangle as it is; a quad as (0 1 2) and
    (0 2 3), or (0 1 3) and (1 2 3) where `is_quad_flip_v3_first_third_fast`
    says so; an n-gon by `BLI_polyfill_calc` over its projection, read from
    the mesh's own tessellation (mesh_tessellate.cc runs the same polyfill
    over the same projection) once `update_from_editmode` has written it —
    or from `BMesh.calc_loop_triangles` where a shape key other than the
    Basis is active and the mesh's positions are the Basis's.

    Face by face because `BMesh.calc_loop_triangles` makes a Python tuple of
    three loops for every triangle of the mesh: 286 MB at 490,000 faces
    (measured with tracemalloc in desktop 5.2.1), for a read that needs the
    selected faces' alone."""

    def __init__(self, obj, bm):
        self.obj = obj
        self.bm = bm
        self._ngons = None

    def of(self, face, index):
        loops = face.loops
        n = len(loops)
        if n == 3:
            return [(loops[0], loops[1], loops[2])]
        if n == 4:
            l0, l1, l2, l3 = loops
            if _quad_flip(l0.vert.co, l1.vert.co, l2.vert.co, l3.vert.co):
                return [(l0, l1, l3), (l1, l2, l3)]
            return [(l0, l1, l2), (l0, l2, l3)]
        if self._ngons is None:
            self._ngons = self._ngon_table()
        return [tuple(loops[k] for k in tri) for tri in self._ngons.get(index, ())]

    def _ngon_table(self):
        """{face index: [(corner, corner, corner), …]} for the n-gons, the
        corners counted from the face's first."""
        me = self.obj.data
        keys = getattr(me, 'shape_keys', None)
        blocks = getattr(keys, 'key_blocks', None) or ()
        index = getattr(self.obj, 'active_shape_key_index', 0)
        if 0 <= index < len(blocks) and blocks[index] != keys.reference_key:
            table = {}
            self.bm.faces.index_update()
            for tri in self.bm.calc_loop_triangles():
                face = tri[0].face
                if len(face.loops) > 4:
                    first = face.loops[0]
                    order = {}
                    loop = first
                    for k in range(len(face.loops)):
                        order[loop] = k
                        loop = loop.link_loop_next
                    table.setdefault(face.index, []).append(tuple(order[l] for l in tri))
            return table
        self.obj.update_from_editmode()
        import numpy as np
        nt = len(me.loop_triangles)
        corners = np.empty(3 * nt, dtype=np.int32)
        me.loop_triangles.foreach_get('loops', corners)
        faces = np.empty(nt, dtype=np.int32)
        me.loop_triangles.foreach_get('polygon_index', faces)
        nf = len(me.polygons)
        starts = np.empty(nf, dtype=np.int32)
        me.polygons.foreach_get('loop_start', starts)
        totals = np.empty(nf, dtype=np.int32)
        me.polygons.foreach_get('loop_total', totals)
        table = {}
        wanted = np.flatnonzero(totals[faces] > 4)
        corners = corners.reshape(nt, 3)
        for t in wanted:
            f = int(faces[t])
            table.setdefault(f, []).append(tuple(int(c) - int(starts[f]) for c in corners[t]))
        return table


def _corner_rows(face, s):
    from mathutils import Vector
    # BM_face_calc_center_bounds: the middle of the corners' box.
    lo = Vector(face.verts[0].co)
    hi = Vector(face.verts[0].co)
    for vert in face.verts:
        for k in range(3):
            lo[k] = min(lo[k], vert.co[k])
            hi[k] = max(hi[k], vert.co[k])
    mid = (lo + hi) * 0.5
    rows = []
    for loop in face.loops:
        v1, v2, v3 = loop.link_loop_prev.vert.co, loop.vert.co, loop.link_loop_next.vert.co
        at = mid.lerp(v2, 0.8)
        if s.use_global:
            v1, v2, v3 = s.m3 @ v1, s.m3 @ v2, s.m3 @ v3
        rows.append(s.w(at) + [_angle_v3v3(v1 - v2, v3 - v2)])
    return rows


def _measure(obj, edge_length, edge_angle, face_area, face_angle, use_global, out, budget=None):
    """Every label of `obj`, appended to `out`; `_Full` as soon as `out` holds
    more than `budget` — before the rest of the mesh costs anything."""
    import bmesh
    bm = bmesh.from_edit_mesh(obj.data)
    s = _Space(obj, use_global)
    count = [sum(len(out[k]) for k in _KEYS)]

    def add(key, row):
        out[key].append(row)
        count[0] += 1
        if budget is not None and count[0] > budget:
            raise _Full

    if edge_length:
        for edge in bm.edges:
            if edge.select:
                add('lengths', _length_row(edge, s))
    if edge_angle:
        for edge in bm.edges:
            if edge.select:
                row = _edge_angle_row(edge, s)
                if row is not None:
                    add('edge_angles', row)
    if face_area:
        tessellation = _Tessellation(obj, bm)
        for index, face in enumerate(bm.faces):
            if face.select:
                add('areas', _area_row(tessellation.of(face, index), s))
    if face_angle:
        for face in bm.faces:
            if face.select:
                for row in _corner_rows(face, s):
                    add('face_angles', row)


_KEYS = ('lengths', 'edge_angles', 'areas', 'face_angles')


# ---------------------------------------------------------------------------
# Past the budget: culled to the view, then thinned
# ---------------------------------------------------------------------------

def _coordinates(np, obj, me):
    """The edit mesh's own coordinates, in the object's space, as the
    measurements read them (`BMVert.co`), from the mesh `update_from_editmode`
    has just written. With a shape key other than the Basis active, the mesh's
    vertices hold the Basis and the key's block the edit mesh's
    (`_blenderkit_sync._edit_coordinates`, measured in 5.2.1)."""
    n = len(me.vertices)
    co = np.empty(3 * n, dtype=np.float32)
    keys = getattr(me, 'shape_keys', None)
    blocks = getattr(keys, 'key_blocks', None) or ()
    index = getattr(obj, 'active_shape_key_index', 0)
    block = blocks[index] if 0 <= index < len(blocks) else None
    if block is not None and block != keys.reference_key and len(block.data) == n:
        block.data.foreach_get('co', co)
    else:
        me.vertices.foreach_get('co', co)
    return co.reshape(n, 3)


def _planes(np, view, obj):
    """The view's four side planes (-w ≤ x ≤ w, -w ≤ y ≤ w in its clip
    space), widened by `_WIDEN`, as rows over the object's homogeneous
    coordinates: a point is in view when every row's dot with it is ≥ 0."""
    mc = np.array(view, dtype=np.float64).reshape(4, 4) @ np.array(obj.matrix_world, dtype=np.float64)
    w = mc[3] * (1.0 + _WIDEN)
    return np.stack([w + mc[0], w - mc[0], w + mc[1], w - mc[1]]).astype(np.float32)


def _edges_in_view(np, co, ends, picked, planes):
    """Of the edges `picked`, those with a part inside the planes: the clip
    the app makes (`EditMeasurements.clip`, `clip_segment_v3_plane_n`), done
    on every edge at once."""
    keep = []
    for start in range(0, len(picked), _CHUNK):
        chunk = picked[start:start + _CHUNK]
        a = co[ends[chunk, 0]]
        b = co[ends[chunk, 1]]
        da = a @ planes[:, :3].T + planes[:, 3]
        db = b @ planes[:, :3].T + planes[:, 3]
        with np.errstate(divide='ignore', invalid='ignore'):
            t = da / (da - db)
        t0 = np.where(da < 0, t, 0.0).max(axis=1)
        t1 = np.where((da >= 0) & (db < 0), t, 1.0).min(axis=1)
        inside = ~((da < 0) & (db < 0)).any(axis=1) & (t0 <= t1)
        keep.append(chunk[inside])
    return np.concatenate(keep) if keep else picked[:0]


def _faces_in_view(np, co, starts, totals, corner_verts, picked, planes):
    """Of the faces `picked`, those whose corners' box reaches inside the
    planes. Both labels of a face are inside that box (Face Area's at the
    mean of its triangles' corners, Face Angle's at 0.8 of the way from the
    box's middle to a corner), so a face left out has no label in view."""
    keep = []
    for start in range(0, len(picked), _CHUNK):
        chunk = picked[start:start + _CHUNK]
        # The faces' corners, face after face (each face's `starts` onwards,
        # `totals` of them), then reduced per face.
        sizes = totals[chunk]
        firsts = np.concatenate(([0], np.cumsum(sizes)[:-1]))
        offsets = np.repeat(starts[chunk] - firsts, sizes)
        corners = co[corner_verts[np.arange(int(sizes.sum())) + offsets]]
        lo = np.minimum.reduceat(corners, firsts, axis=0)
        hi = np.maximum.reduceat(corners, firsts, axis=0)
        # The box's farthest point along each plane's normal.
        reach = planes[:, 3] + np.maximum(lo[:, None, :] * planes[None, :, :3],
                                          hi[:, None, :] * planes[None, :, :3]).sum(axis=2)
        keep.append(chunk[(reach >= 0).all(axis=1)])
    return np.concatenate(keep) if keep else picked[:0]


def _culled(objects, flags, use_global, view, budget, out):
    """The labels of `objects` whose anchors can be in `view` (16 numbers, the
    app's world-to-clip matrix, row by row; None for every selected element),
    every n-th of them when more than `budget` are: the same rows the whole
    read writes, for those elements. Returns (in view, n)."""
    import bmesh
    import numpy as np
    edge_length, edge_angle, face_area, face_angle = flags
    found = []
    for obj in objects:
        # The mesh as the edit mesh is now, selection included; the mirror's
        # pass does the same every time (`_blenderkit_sync`).
        obj.update_from_editmode()
        me = obj.data
        co = _coordinates(np, obj, me)
        planes = _planes(np, view, obj) if view is not None else None
        edges = angles = faces = totals = None
        corner_count = 0
        if edge_length or edge_angle:
            ne = len(me.edges)
            ends = np.empty(2 * ne, dtype=np.int32)
            me.edges.foreach_get('vertices', ends)
            ends = ends.reshape(ne, 2)
            selected = np.empty(ne, dtype=bool)
            me.edges.foreach_get('select', selected)
            edges = np.flatnonzero(selected).astype(np.int32)
            if planes is not None:
                edges = _edges_in_view(np, co, ends, edges, planes)
            if edge_angle:
                # Exactly two faces round it, as the row asks.
                corner_edges = np.empty(len(me.loops), dtype=np.int32)
                me.loops.foreach_get('edge_index', corner_edges)
                around = np.bincount(corner_edges, minlength=ne)
                angles = edges[around[edges] == 2]
        if face_area or face_angle:
            nf = len(me.polygons)
            selected = np.empty(nf, dtype=bool)
            me.polygons.foreach_get('select', selected)
            totals = np.empty(nf, dtype=np.int32)
            me.polygons.foreach_get('loop_total', totals)
            faces = np.flatnonzero(selected).astype(np.int32)
            if planes is not None:
                starts = np.empty(nf, dtype=np.int32)
                me.polygons.foreach_get('loop_start', starts)
                corner_verts = np.empty(len(me.loops), dtype=np.int32)
                me.loops.foreach_get('vertex_index', corner_verts)
                faces = _faces_in_view(np, co, starts, totals, corner_verts, faces, planes)
            corner_count = int(totals[faces].sum()) if face_angle else 0
        found.append((obj, edges if edge_length else None, angles, faces, corner_count, totals))
    in_view = sum((len(e) if e is not None else 0) + (len(a) if a is not None else 0)
                  + (len(f) if (f is not None and face_area) else 0) + c
                  for _, e, a, f, c, _ in found)
    every = max(1, -(-in_view // budget))
    for obj, edges, angles, faces, _, totals in found:
        bm = bmesh.from_edit_mesh(obj.data)
        bm.edges.ensure_lookup_table()
        bm.faces.ensure_lookup_table()
        s = _Space(obj, use_global)
        if edges is not None:
            for i in edges[::every]:
                out['lengths'].append(_length_row(bm.edges[int(i)], s))
        if angles is not None:
            for i in angles[::every]:
                row = _edge_angle_row(bm.edges[int(i)], s)
                if row is not None:
                    out['edge_angles'].append(row)
        if faces is not None and face_area:
            tessellation = _Tessellation(obj, bm)
            for i in faces[::every]:
                i = int(i)
                out['areas'].append(_area_row(tessellation.of(bm.faces[i], i), s))
        if faces is not None and face_angle:
            for i in faces[::every]:
                out['face_angles'] += _corner_rows(bm.faces[int(i)], s)
    return in_view, every


def edit_overlay(stats=False, edge_length=False, edge_angle=False, face_area=False, face_angle=False,
                 use_global=False, view=None, budget=LABELS):
    """What Edit Mode's overlays draw, as one line of JSON: `stats` (see
    `statistics`), and per measurement the world positions and the value —
    `lengths` and `edge_angles` [ax, ay, az, bx, by, bz, value],
    `areas` and `face_angles` [x, y, z, value] — or `cage` naming the
    modifier whose cage they would be drawn on.

    At most about `budget` labels (`LABELS`): past it, those in `view` (the
    app's world-to-clip matrix, 16 numbers row by row), every n-th of them if
    there are still more, with `thinned` = [labels in view, n] and `culled`
    true when the view decided which (see the module's note)."""
    out = {k: [] for k in _KEYS}
    objects = _edit_objects()
    if stats:
        out['stats'] = statistics()
    flags = (edge_length, edge_angle, face_area, face_angle)
    if any(flags):
        measured = []
        for obj in objects:
            cage = _on_cage(obj)
            if cage is not None:
                out['cage'] = obj.name + ': ' + cage
                continue
            measured.append(obj)
        try:
            for obj in measured:
                _measure(obj, edge_length, edge_angle, face_area, face_angle, use_global, out, budget)
        except _Full:
            for k in _KEYS:
                out[k] = []
            in_view, every = _culled(measured, flags, use_global, view, max(1, budget), out)
            out['thinned'] = [in_view, every]
            out['culled'] = view is not None
    return json.dumps(out, separators=(',', ':'))
