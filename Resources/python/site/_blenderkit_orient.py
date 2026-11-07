"""Blender's transform orientations, as the gizmo and every transform use them.

The 3D View header's Orientation (`scene.transform_orientation_slots[0].type`)
decides which axes the gizmo's handles follow and which axes a Move, Rotate or
Scale is measured in. Blender works the matrix out in
`calc_orientation_from_type_ex` (transform_orientations.cc), and nothing in the
Python API hands it back: there is no function for it, and an operator's
`orient_matrix` is written into its own properties, which a bpy call never
returns. So this is that function, line for line, from the 5.3 source the app
is built from (`/Volumes/D/OfflinAi/blender_ios/blender`):

* Global — the identity.
* Local — the active object's world axes, each normalised
  (`transform_orientations_create_from_axis`), in Object and Edit Mode.
* Normal — in Edit Mode, the selection's (`getTransformOrientation_ex` for an
  edit mesh, then `ED_getTransformOrientationMatrix`'s `createSpaceNormal` /
  `createSpaceNormalTangent`); in Object Mode it falls through to Local.
* Gimbal — the active object's Euler or axis-angle gimbal
  (`gimbal_axis_object`); a quaternion falls through to Parent.
* Parent — the parent's world axes, or the identity.
* Cursor — the 3D cursor's rotation.
* View — the view's, which only the app knows: the Swift side makes it.

The matrix is returned as Blender's `float[3][3]`, whose `[i]` is axis i — the
rows of the `orient_matrix` a transform takes (measured in 5.2.1: rows (0,1,0),
(-1,0,0), (0,0,1) with value=(1, 2, 3) moved a cube to (-2, 1, 3)).

Every transform the gizmo commits sends this matrix with
`orient_matrix_type` equal to `orient_type`, which makes Blender use it as
given (transform_generics.cc: "Constraints are forced to use the custom matrix
when redoing"), so the preview the gizmo draws on these axes is the commit.
`scripts/run-orient-blender-check.sh` holds the port to Blender's own matrix,
read back from the operator Blender registers when it computes the orientation
itself.

A curve's or a surface's Edit Mode Normal (Bézier normals and tilt,
`BKE_nurb_bezt_calc_normal`) is not ported: `matrix` answers None for it and
`unavailable` says so, and no gizmo is drawn rather than one on axes Blender
would not use. A lattice has no Normal in Blender (its matrix is the identity).
"""

import math

import bpy
from mathutils import Euler, Matrix, Quaternion, Vector

TYPES = ('GLOBAL', 'LOCAL', 'NORMAL', 'GIMBAL', 'VIEW', 'CURSOR', 'PARENT')

UNAVAILABLE_CURVE = ("Normal orientation for a curve's points is not worked out here, so no "
                     "gizmo is drawn for it. Choose another orientation, or move the points "
                     "with the Transform fields.")


# ---------------------------------------------------------------------------
# transform_orientations.cc: building a space
# ---------------------------------------------------------------------------

def _normalized(v):
    """normalize_v3: the unit vector and the length it had (0 leaves zero)."""
    v = Vector(v)
    length = v.length
    if length > 1e-35:
        return v / length, length
    return Vector((0.0, 0.0, 0.0)), 0.0


def _is_zero(v):
    return v[0] == 0.0 and v[1] == 0.0 and v[2] == 0.0


def create_from_axis(x, y, z):
    """transform_orientations_create_from_axis: each axis normalised, a zero
    one rebuilt from the others, the identity when that fails."""
    mat = [Vector((0.0, 0.0, 0.0)) for _ in range(3)]
    is_zero = [True, True, True]
    for i, axis in enumerate((x, y, z)):
        if axis is not None:
            mat[i], length = _normalized(axis)
            is_zero[i] = length == 0.0
    zero_axis = sum(is_zero)
    if zero_axis == 0:
        return mat
    if zero_axis == 1:
        axis = 0 if is_zero[0] else 1 if is_zero[1] else 2
        mat[axis], length = _normalized(mat[(axis + 1) % 3].cross(mat[(axis + 2) % 3]))
        if length != 0.0:
            return mat
    elif zero_axis == 2:
        axis = 0 if not is_zero[0] else 1 if not is_zero[1] else 2
        a, b = (axis + 1) % 3, (axis + 2) % 3
        mat[a] = Vector((0.0, 0.0, 0.0))
        mat[b] = Vector((0.0, 0.0, 0.0))
        mat[a][a] = 1.0
        mat[b][b] = 1.0
        # project_plane_v3_v3v3
        for k in (a, b):
            n = mat[axis]
            d = n.dot(n)
            if d != 0.0:
                mat[k] = mat[k] - n * (mat[k].dot(n) / d)
        mat[a], la = _normalized(mat[a])
        mat[b], lb = _normalized(mat[b])
        if la != 0.0 and lb != 0.0:
            return mat
    return _identity()


def _identity():
    return [Vector((1.0, 0.0, 0.0)), Vector((0.0, 1.0, 0.0)), Vector((0.0, 0.0, 1.0))]


def _object_axes(obj):
    """UNPACK3(ob->object_to_world().ptr()): the world matrix's three axes."""
    m = obj.matrix_world
    return create_from_axis(m.col[0].xyz, m.col[1].xyz, m.col[2].xyz)


def create_space_normal(normal):
    """createSpaceNormal, or None for a zero normal."""
    z, length = _normalized(normal)
    if length == 0.0:
        return None
    x = z.cross(Vector((0.0, 0.0, 1.0)))
    if _is_zero(x):
        x = Vector((1.0, 0.0, 0.0)).cross(z)
    y = z.cross(x)
    return [_normalized(x)[0], _normalized(y)[0], _normalized(z)[0]]


def create_space_normal_tangent(normal, tangent):
    """createSpaceNormalTangent, or None where it fails. The normal goes in as
    it is: Blender asserts it is unit length and does not normalise it."""
    z = Vector(normal)
    if _is_zero(z):
        return None
    y = -Vector(tangent)
    if _is_zero(y):
        y = Vector((0.0, 0.0, 1.0))
    x, lx = _normalized(z.cross(y))
    if lx == 0.0:
        return None
    y, ly = _normalized(z.cross(x))
    if ly == 0.0:
        return None
    return [x, y, z]


# ---------------------------------------------------------------------------
# Gimbal
# ---------------------------------------------------------------------------

_ORDER_AXES = {'XYZ': (0, 1, 2), 'XZY': (0, 2, 1), 'YXZ': (1, 0, 2),
               'YZX': (1, 2, 0), 'ZXY': (2, 0, 1), 'ZYX': (2, 1, 0)}


def _euler_gimbal(eul, order):
    """eulO_to_gimbal_axis (math_rotation_c.cc)."""
    axes = _ORDER_AXES[order]
    gmat = [None, None, None]
    mat = Euler(eul, order).to_matrix()
    gmat[axes[0]] = mat.col[axes[0]].copy()
    teul = list(eul)
    teul[axes[0]] = 0.0
    mat = Euler(teul, order).to_matrix()
    gmat[axes[1]] = mat.col[axes[1]].copy()
    last = Vector((0.0, 0.0, 0.0))
    last[axes[2]] = 1.0
    gmat[axes[2]] = last
    return gmat


def _quat(axis, angle):
    """axis_angle_to_quat: the identity for a zero axis."""
    n, length = _normalized(axis)
    if length == 0.0:
        return Quaternion()
    return Quaternion(n, angle)


def _axis_angle_gimbal(axis, angle):
    """axis_angle_to_gimbal_axis (transform_orientations.cc)."""
    axis = Vector(axis)
    cross_vec = Vector((axis[1], axis[2], axis[0]))
    x = _normalized(cross_vec.cross(axis))[0]
    x = _quat(axis, angle) @ x
    y = _quat(axis, math.pi / 2) @ x
    z = axis.copy()
    return [_normalized(x)[0], _normalized(y)[0], _normalized(z)[0]]


def gimbal_axes(obj):
    """gimbal_axis_object, or None for a quaternion (Blender falls through to
    Parent)."""
    mode = obj.rotation_mode
    if mode == 'QUATERNION':
        return None
    if mode == 'AXIS_ANGLE':
        aa = obj.rotation_axis_angle
        gmat = _axis_angle_gimbal((aa[1], aa[2], aa[3]), aa[0])
    else:
        gmat = _euler_gimbal(tuple(obj.rotation_euler), mode)
    if obj.parent is not None:
        p = obj.parent.matrix_world
        # copy_m3_m4 + normalize_m3: each of the parent's axes normalised.
        cols = [_normalized(p.col[i].xyz)[0] for i in range(3)]
        parent3 = Matrix((cols[0], cols[1], cols[2])).transposed()
        gmat = [parent3 @ g for g in gmat]
    return gmat


def parent_axes(obj):
    """handle_object_parent_orientation."""
    if obj.parent is not None:
        return _object_axes(obj.parent)
    return _identity()


# ---------------------------------------------------------------------------
# Normal, in a mesh's Edit Mode: getTransformOrientation_ex
# ---------------------------------------------------------------------------

def _select_get_n(bm, seq, kind, n):
    """bm_mesh_elems_select_get_n__internal: the last n selected elements of
    the select history when they are of one kind, else the first n in the
    mesh's order."""
    if n <= 0:
        return []
    history = list(bm.select_history)
    if history:
        out = []
        for ele in reversed(history):
            if not ele.select:
                continue
            if not isinstance(ele, kind):
                out = []
                break
            out.append(ele)
            if len(out) == n:
                break
        if out and len(out) == n:
            return out
    out = []
    for ele in seq:
        if ele.select:
            out.append(ele)
            if len(out) == n:
                break
    return out


def _longest_loop(face):
    """BM_face_find_longest_loop (>=: a tie goes to the later loop)."""
    loops = list(face.loops)
    best = loops[0]
    best_len = 0.0
    for l in loops:
        d = (l.vert.co - l.link_loop_next.vert.co).length_squared
        if d >= best_len:
            best = l
            best_len = d
    return best


def _project(p, v):
    """project_v3_v3v3."""
    d = v.dot(v)
    if d == 0.0:
        return Vector((0.0, 0.0, 0.0))
    return v * (p.dot(v) / d)


def _axis_sort(values):
    """axis_sort_v3: the axis order with the smallest value first."""
    v = list(values)
    order = [0, 1, 2]

    def swap(a, b):
        v[a], v[b] = v[b], v[a]
        order[a], order[b] = order[b], order[a]

    if v[0] < v[1]:
        if v[2] < v[0]:
            swap(0, 2)
    else:
        if v[1] < v[2]:
            swap(0, 1)
        else:
            swap(0, 2)
    if v[2] < v[1]:
        swap(1, 2)
    return order


def _tri_unique_edge(verts):
    """bm_vert_tri_find_unique_edge."""
    difs = [0.0, 0.0, 0.0]
    i_prev, i_curr = 1, 2
    for i_next in range(3):
        co = verts[i_curr].co
        others = (verts[i_prev].co, verts[i_next].co)
        proj_dir = (others[0] + others[1]) * 0.5 - co
        a = _project(Vector(others[0]), proj_dir)
        b = _project(Vector(others[1]), proj_dir)
        difs[i_next] = (a - b).length_squared
        i_prev, i_curr = i_curr, i_next
    return _axis_sort(difs)[0]


def _tri_tangent_from_edge(verts):
    """BM_vert_tri_calc_tangent_from_edge."""
    index = _tri_unique_edge(verts)
    return _normalized(verts[index].co - verts[(index + 1) % 3].co)[0]


def _tri_tangent_pair(verts):
    """BM_vert_tri_calc_tangent_pair_from_edge."""
    index = _tri_unique_edge(verts)
    index_next = (index + 1) % 3
    index_prev = (index_next + 1) % 3
    a = _normalized(verts[index].co - verts[index_next].co)[0]
    vec_prev = verts[index_prev].co - verts[index].co
    vec_next = verts[index_next].co - verts[index_prev].co
    tmp_prev = a.cross(vec_prev)
    tmp_next = a.cross(vec_next)
    b = _normalized(vec_next if tmp_next.length_squared > tmp_prev.length_squared else vec_prev)[0]
    return a, b


def _quad_tangent_pair(face):
    """bm_face_calc_tangent_pair_from_quad_edge_pair."""
    v = [l.vert.co for l in face.loops]
    a = (v[3] - v[2]) + (v[0] - v[1])
    b = (v[0] - v[3]) + (v[1] - v[2])
    a, la = _normalized(a)
    b, lb = _normalized(b)
    if la < lb:
        a, b = b, a
    return a, b


def _ngon_tangent_pair(face):
    """BM_face_calc_tangent_pair_from_edge."""
    l_long = _longest_loop(face)
    a = _normalized(l_long.vert.co - l_long.link_loop_next.vert.co)[0]
    vec_prev = l_long.link_loop_prev.vert.co - l_long.vert.co
    vec_next = l_long.link_loop_next.vert.co - l_long.link_loop_next.link_loop_next.vert.co
    tmp_prev = a.cross(vec_prev)
    tmp_next = a.cross(vec_next)
    b = _normalized(vec_next if tmp_next.length_squared > tmp_prev.length_squared else vec_prev)[0]
    return a, b


def _face_tangent_pair(face):
    """BM_face_calc_tangent_pair_auto."""
    n = len(face.verts)
    if n == 3:
        return _tri_tangent_pair([l.vert for l in face.loops])
    if n == 4:
        return _quad_tangent_pair(face)
    return _ngon_tangent_pair(face)


def _quad_tangent(face):
    """bm_face_calc_tangent_from_quad_edge_pair."""
    v = [l.vert.co for l in face.loops]
    t = (v[3] - v[2]) + (v[0] - v[1])
    vec = (v[0] - v[3]) + (v[1] - v[2])
    if t.length_squared < vec.length_squared:
        t = vec
    return _normalized(t)[0]


def _face_tangent_auto(face):
    """BM_face_calc_tangent_auto."""
    n = len(face.verts)
    if n == 3:
        return _tri_tangent_from_edge([l.vert for l in face.loops])
    if n == 4:
        return _quad_tangent(face)
    l_long = _longest_loop(face)
    return _normalized(l_long.vert.co - l_long.link_loop_next.vert.co)[0]


def _active_face(bm):
    """BM_mesh_active_face_get(bm, false, true)."""
    f = bm.faces.active
    if f is not None and f.select:
        return f
    return None


def _history_active(bm):
    """BM_select_history_active_get: the last of the select history (the
    active face for a face), else the active face; the copy it hands back has
    no `prev`."""
    history = list(bm.select_history)
    face = _active_face(bm)
    if history:
        last = history[-1]
        if isinstance(last, bmesh_types().BMFace):
            return face if face is not None else last
        return last
    return face


def bmesh_types():
    import bmesh
    return bmesh.types


def _edit_selection_normal(ele):
    """BM_editselection_normal."""
    t = bmesh_types()
    if isinstance(ele, t.BMVert):
        return ele.normal.copy()
    if isinstance(ele, t.BMEdge):
        normal = ele.verts[0].normal + ele.verts[1].normal
        plane = ele.verts[1].co - ele.verts[0].co
        vec = normal.cross(plane)
        return _normalized(plane.cross(vec))[0]
    return ele.normal.copy()


def _edit_selection_plane(ele):
    """BM_editselection_plane, for a copy with no `prev`."""
    t = bmesh_types()
    if isinstance(ele, t.BMVert):
        no = ele.normal
        vec = Vector((0.0, 0.0, 0.0))
        if no[0] < 0.5:
            vec[0] = 1.0
        elif no[1] < 0.5:
            vec[1] = 1.0
        else:
            vec[2] = 1.0
        return _normalized(no.cross(vec))[0]
    if isinstance(ele, t.BMEdge):
        if ele.is_boundary:
            l = ele.link_loops[0]
            plane = l.vert.co - l.link_loop_next.vert.co
        elif ele.verts[1].co[1] > ele.verts[0].co[1]:
            plane = ele.verts[1].co - ele.verts[0].co
        else:
            plane = ele.verts[0].co - ele.verts[1].co
        return _normalized(plane)[0]
    return _face_tangent_auto(ele)


def _ortho(v):
    """ortho_v3_v3."""
    x, y, z = abs(v[0]), abs(v[1]), abs(v[2])
    axis = (0 if x > z else 2) if x > y else (1 if y > z else 2)
    if axis == 0:
        return Vector((-v[1] - v[2], v[0], v[0]))
    if axis == 1:
        return Vector((v[1], -v[0] - v[2], v[1]))
    return Vector((v[2], v[2], -v[0] - v[1]))


_NONE, _NORMAL, _VERT, _EDGE, _FACE = range(5)


def _mesh_normal_plane(obj, bm, active_only):
    """The edit-mesh half of getTransformOrientation_ex: (type, normal, plane)
    in the object's own space, before the world transform."""
    normal = Vector((0.0, 0.0, 0.0))
    plane = Vector((0.0, 0.0, 0.0))
    result = _NONE
    t = bmesh_types()
    ese = _history_active(bm) if active_only else None
    if ese is not None:
        normal = _edit_selection_normal(ese)
        plane = _edit_selection_plane(ese)
        result = _VERT if isinstance(ese, t.BMVert) else _EDGE if isinstance(ese, t.BMEdge) else _FACE
    else:
        faces = [f for f in bm.faces if f.select]
        verts_sel = sum(1 for v in bm.verts if v.select)
        edges_sel = sum(1 for e in bm.edges if e.select)
        if faces:
            pair = [Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.0))]
            for f in faces:
                a, b = _face_tangent_pair(f)
                normal += f.normal
                pair[0] += a
                pair[1] += b
            if len(faces) == 1:
                index = 0
            else:
                nu = _normalized(normal)[0]
                o0 = nu.cross(_normalized(pair[0])[0])
                o1 = nu.cross(_normalized(pair[1])[0])
                index = 0 if o0.length_squared > o1.length_squared else 1
            plane = pair[index].copy()
            result = _FACE
        elif verts_sel == 3:
            v_tri = _select_get_n(bm, bm.verts, t.BMVert, 3)
            a, b, c = (v.co for v in v_tri)
            normal = _normalized((a - b).cross(b - c))[0]
            no_test = v_tri[0].normal + v_tri[1].normal + v_tri[2].normal
            if no_test.dot(normal) < 0.0:
                normal = -normal
            e = None
            if edges_sel >= 1:
                e_length = 0.0
                for j in range(3):
                    e_test = _edge_between(v_tri[j], v_tri[(j + 1) % 3])
                    if e_test is not None and e_test.select:
                        length = e_test.calc_length() ** 2
                        if e is None or e_length < length:
                            e = e_test
                            e_length = length
            if e is not None:
                if e.is_boundary:
                    l = e.link_loops[0]
                    pair = (l.vert, l.link_loop_next.vert)
                else:
                    pair = (e.verts[0], e.verts[1])
                plane = pair[0].co - pair[1].co
            else:
                plane = _tri_tangent_from_edge(v_tri)
            result = _FACE
        elif edges_sel == 1 or verts_sel == 2:
            eed = None
            if edges_sel == 1:
                eed = _select_get_n(bm, bm.edges, t.BMEdge, 1)[0]
                v_pair = [eed.verts[0], eed.verts[1]]
            else:
                v_pair = _select_get_n(bm, bm.verts, t.BMVert, 2)
            history = list(bm.select_history)
            active_vert = history[-1] if history and isinstance(history[-1], t.BMVert) else None
            swap = False
            if active_vert is not None and active_vert == v_pair[1]:
                swap = True
            elif eed is not None and eed.is_boundary:
                if eed.link_loops[0].vert != v_pair[0]:
                    swap = True
            if swap:
                v_pair = [v_pair[1], v_pair[0]]
            normal = v_pair[1].normal + v_pair[0].normal
            plane, length = _normalized(v_pair[1].co - v_pair[0].co)
            if length != 0.0:
                normal = normal - plane * normal.dot(plane)
                normal, ln = _normalized(normal)
                if ln == 0.0:
                    normal = _ortho(plane)
            result = _EDGE
        elif verts_sel == 1:
            v = _select_get_n(bm, bm.verts, t.BMVert, 1)[0]
            normal = v.normal.copy()
            edges = list(v.link_edges)
            if len(edges) == 2:
                swap = False
                v_pair = [edges[0].other_vert(v), edges[1].other_vert(v)]
                if edges[0].is_boundary:
                    if edges[0].link_loops[0].vert != v:
                        swap = True
                elif edges[0].calc_length() ** 2 < edges[1].calc_length() ** 2:
                    swap = True
                if swap:
                    v_pair = [v_pair[1], v_pair[0]]
                d0 = _normalized(v.co - v_pair[0].co)[0]
                d1 = _normalized(v_pair[1].co - v.co)[0]
                plane = d0 + d1
            result = _VERT if _is_zero(plane) else _EDGE
        elif verts_sel > 3:
            for v in bm.verts:
                if v.select:
                    normal += v.normal
            normal = _normalized(normal)[0]
            result = _VERT
    # "Not needed but this matches 2.68 and older behavior."
    plane = -plane
    return result, normal, plane


def _edge_between(a, b):
    for e in a.link_edges:
        if e.other_vert(a) == b:
            return e
    return None


def normal_axes(obj, pivot):
    """ED_getTransformOrientationMatrix for an edited mesh, in world space."""
    import bmesh
    bm = bmesh.from_edit_mesh(obj.data)
    result, normal, plane = _mesh_normal_plane(obj, bm, pivot == 'ACTIVE_ELEMENT')
    m3 = obj.matrix_world.to_3x3()
    if result == _EDGE:
        # "Vectors from edges don't need the special transpose inverse."
        normal = m3 @ normal
        plane = m3 @ plane
        normal = normal - _project(normal, plane)
    else:
        try:
            nmat = m3.inverted().transposed()
        except ValueError:
            nmat = Matrix(((0.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)))
        normal = nmat @ normal
        plane = nmat @ plane
    normal = _normalized(normal)[0]
    plane = _normalized(plane)[0]
    if result in (_NORMAL, _EDGE, _FACE) and _is_zero(plane):
        result = _VERT
    mat = None
    if result in (_NORMAL, _EDGE, _FACE):
        mat = create_space_normal_tangent(normal, plane)
    elif result == _VERT:
        mat = create_space_normal(normal)
    return mat if mat is not None else _identity()


# ---------------------------------------------------------------------------
# calc_orientation_from_type_ex
# ---------------------------------------------------------------------------

def _edit_object():
    obj = bpy.context.view_layer.objects.active
    if obj is not None and obj.mode == 'EDIT':
        return obj
    return None


def unavailable(kind=None):
    """Why `matrix` has no answer for the orientation in use, or None."""
    scene = bpy.context.scene
    kind = kind or scene.transform_orientation_slots[0].type
    obedit = _edit_object()
    if kind == 'NORMAL' and obedit is not None and obedit.type in {'CURVE', 'SURFACE'}:
        return UNAVAILABLE_CURVE
    return None


def matrix(kind=None):
    """Blender's matrix for `kind` (the scene's orientation by default), as
    three world-space axes, or None for View (the app's) and for what
    `unavailable` names. Custom orientations are read as Blender applies one."""
    scene = bpy.context.scene
    slot = scene.transform_orientation_slots[0]
    kind = kind or slot.type
    ob = bpy.context.view_layer.objects.active
    obedit = _edit_object()
    pivot = scene.tool_settings.transform_pivot_point
    if kind == 'VIEW' or unavailable(kind):
        return None
    if kind == 'GLOBAL':
        return _identity()
    if kind == 'CURSOR':
        c = scene.cursor.matrix.to_3x3()
        return [c.col[0].copy(), c.col[1].copy(), c.col[2].copy()]
    if kind not in TYPES:
        custom = slot.custom_orientation
        if custom is None:
            return _identity()
        c = custom.matrix
        return [c.col[0].copy(), c.col[1].copy(), c.col[2].copy()]
    if kind == 'GIMBAL':
        if ob is not None:
            g = gimbal_axes(ob)
            if g is not None:
                return g
        kind = 'PARENT'
    if kind == 'PARENT':
        if ob is not None:
            return parent_axes(ob)
        kind = 'NORMAL'
    if kind == 'NORMAL':
        if obedit is not None:
            if obedit.type == 'MESH':
                return normal_axes(obedit, pivot)
            # A lattice, a metaball: Blender's mesh-less cases come back
            # ORIENTATION_NONE, the identity, for a lattice.
            return _identity()
        kind = 'LOCAL'
    if kind == 'LOCAL':
        if ob is not None:
            return _object_axes(ob)
    return _identity()


def active_axes():
    """Align View to Active (Shift+Numpad 1, 3, 7: `view3d.view_axis` with
    align_active): the matrix `ED_getTransformOrientationMatrix` gives about
    the active element — an edited mesh's active element's normal and tangent
    (`normal_axes` with Active Element), otherwise the active object's axes.
    Printed as nine numbers, axis X, Y, Z; 'none' with no active object."""
    ob = bpy.context.view_layer.objects.active
    if ob is None:
        print('none')
        return
    obedit = _edit_object()
    m = normal_axes(obedit, 'ACTIVE_ELEMENT') if obedit is not None and obedit.type == 'MESH' else _object_axes(ob)
    print(' '.join('%.7g' % float(c) for axis in m for c in axis))


def redo_matrix(kind):
    """`kind`'s matrix as a transform's `orient_matrix` takes it — its rows
    the axes — worked out now, for a redo panel's choice that has to be
    computed on the scene as the re-run finds it: Normal in Edit Mode, which
    a headless Blender would work out with the bounds centre for its pivot
    rather than the scene's (TransformCommit). Refuses in words, rather than
    hand over a matrix Blender would not use, where `matrix` has no answer."""
    why = unavailable(kind)
    if why:
        raise RuntimeError(why)
    m = matrix(kind)
    if m is None:
        raise RuntimeError("The %s orientation has no matrix to work out here." % kind.capitalize())
    return tuple(tuple(float(c) for c in axis) for axis in m)


def report(kind=None):
    """One line for the interface: the orientation's identifier, then nine
    numbers (axis X, Y, Z) or the word `none` and the reason.

    It never raises: it runs after every command and every tap the gizmo
    follows, and a failure here would put a traceback in the console each
    time. A matrix that cannot be worked out is reported as none, with the
    error as the reason, and the gizmo is then not drawn."""
    scene = bpy.context.scene
    kind = kind or scene.transform_orientation_slots[0].type
    try:
        why = unavailable(kind)
        if why:
            return "%s none %s" % (kind, why)
        m = matrix(kind)
    except Exception as error:
        return "%s none The %s orientation could not be worked out here (%s: %s)." % (
            kind, kind.capitalize(), type(error).__name__, error)
    if m is None:
        return "%s none" % kind
    return kind + " " + " ".join(repr(float(c)) for axis in m for c in axis)
