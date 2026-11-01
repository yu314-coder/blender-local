"""The Mesh menu's rows that need more than the operator: Blender's Extrude to
Cursor or Add (Vertex menu, Ctrl+right click), Rip Vertices and Extend's ray,
and the selection each row needs, refused in words before Blender is asked.

Extrude to Cursor or Add
------------------------
`mesh.dupli_extrude_cursor` has an invoke and no exec: it reads the pointer
from the window's mouse event, and a Blender with no window has no event to
give it (`window->eventstate` is only made for a window with a GHOST window,
wm_window.cc). Measured in desktop 5.2.1 with the app's context: through the
operator search refused by its poll ("Expected a view3d region & editmesh"),
and under the borrowed 3D View PASS_THROUGH with nothing changed ("Invalid
operator call"), round 3's review and again here.

So `to_cursor` is that invoke, `edbm_dupli_extrude_cursor_invoke`
(editmesh_extrude.cc), ported line for line, with the pointer over the 3D
cursor in the app's own view: the selection's middle, the 2D normal of the
selected edges on screen (`line_point_side_v2` against the pointer), the
point under the pointer at the selection's depth (`ED_view3d_win_to_3d`), the
rotation that turns the normal toward it (halved with Rotate Source on, the
source turned by the other half), `edbm_extrude_ex` (the `extrude_face_region`
BMesh operator with the select history kept and edges on a clipping Mirror
modifier's plane left out) and then the same `rotate` and `translate` BMesh
operators Blender calls. With nothing selected it adds a vertex under the
pointer at the 3D cursor's depth, which with the pointer over the cursor is
the cursor itself. scripts/run-meshmenu-blender-check.sh runs Blender's own
invoke in desktop with the same pointer (through `WM_operator_name_call` and a
made event, which only a check may do) and holds this to it.

Blender has no redo panel for it: the panel only shows for an operator it can
run again (`WM_operator_repeat_check` wants an exec), so neither has the app.

Rip Vertices and Extend
-----------------------
`mesh.rip_edge` does have an exec, given a world-space ray (`location`,
`direction`; hidden properties its invoke fills from the pointer,
editmesh_rip_edge.cc). `pointer_ray` is that ray through the 3D cursor in the
app's view. Rip Vertices and Rip Vertices and Fill (`mesh.rip`) have no exec,
and with no pointer they cannot run (measured: `rip_move` FINISHED with nothing
changed); the menu says so.
"""

import math

import bpy


def _is_real_blender():
    # The simulator's stand-in has no RNA behind its operators.
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _bmesh(what):
    if not _is_real_blender():
        raise NotImplementedError(
            what + " needs Blender's own mesh (BMesh), which the simulator's stand-in for Blender "
            "does not have")
    import bmesh
    return bmesh


def _finite(values):
    return all(math.isfinite(float(c)) for c in values)


def _budget_module():
    """The vertex budget (_blenderkit_budget.py), imported or — where the
    site folder is not on the path, as in the desktop checks — loaded from
    beside this module."""
    import sys
    module = sys.modules.get('_blenderkit_budget')
    if module is not None:
        return module
    try:
        import _blenderkit_budget as module
        return module
    except ImportError:
        import importlib.util
        import os
        spec = importlib.util.spec_from_file_location(
            '_blenderkit_budget', os.path.join(os.path.dirname(os.path.abspath(__file__)), '_blenderkit_budget.py'))
        module = importlib.util.module_from_spec(spec)
        sys.modules['_blenderkit_budget'] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop('_blenderkit_budget', None)
            raise
        return module


def _edit_objects():
    """Every mesh in Edit Mode, the active one first, each mesh once — what
    Blender's mesh operators act on (`objects_in_mode_unique_data`)."""
    active = bpy.context.view_layer.objects.active
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or [active])
    objects = [o for o in objects if o is not None and o.type == 'MESH' and o.mode == 'EDIT']
    objects.sort(key=lambda o: o != active)
    return objects


def _edited(what):
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH' or obj.mode != 'EDIT':
        raise RuntimeError(what + " works on the mesh being edited: go into Edit Mode on a mesh first.")
    return obj


# --------------------------------------------------------------------------
# What a row needs selected, refused in words before Blender is asked.

def selected_counts():
    """(vertices, edges, faces) selected across every mesh in Edit Mode."""
    v = e = f = 0
    for obj in _edit_objects():
        me = obj.data
        v += me.total_vert_sel
        e += me.total_edge_sel
        f += me.total_face_sel
    return v, e, f


def require(what, verts=0, edges=0, faces=0, sentence=None):
    """Raises `sentence` (or one made from the row's name) unless at least
    this many vertices, edges and faces are selected."""
    v, e, f = selected_counts()
    if v >= verts and e >= edges and f >= faces:
        return
    if sentence is None:
        need = [(n, word) for n, word in ((verts, "vertex"), (edges, "edge"), (faces, "face")) if n]
        n, word = need[-1] if need else (1, "vertex")
        plural = {"vertex": "vertices", "edge": "edges", "face": "faces"}[word]
        sentence = what + " acts on the selection: select " + (
            "a " + word if n == 1 else "at least %d %s" % (n, plural)) + " first."
    raise RuntimeError(sentence)


def require_unselected_faces(what, sentence):
    """Raises unless some face of the meshes being edited is not selected and
    not hidden: the rows that cut the unselected geometry with the selected."""
    bmesh = _bmesh(what)
    for obj in _edit_objects():
        bm = bmesh.from_edit_mesh(obj.data)
        if any(not f.select and not f.hide for f in bm.faces):
            return
    raise RuntimeError(sentence)


def check_merge(type):
    """Merge's choices, refused as Blender's own menu would never offer them.

    Measured in desktop 5.2.1: At First and At Last are only in Blender's
    enum when the active mesh is in Vertex select mode and its select history
    starts (At First) or ends (At Last) with a vertex (`merge_type_itemf`);
    otherwise the call fails with 'enum "FIRST" not found in ('CENTER',
    'CURSOR', 'COLLAPSE')'. With nothing selected every type returns FINISHED
    and changes nothing; with one vertex At Center, Collapse, At First and At
    Last change nothing either, and At Cursor moves it to the cursor."""
    what = "Merge"
    v, _, _ = selected_counts()
    if v == 0:
        raise RuntimeError("Merge joins the selected vertices into one: select some first.")
    if v == 1 and type != 'CURSOR':
        raise RuntimeError("Merge joins the selected vertices into one, and one vertex is selected: "
                           "select another, or use At Cursor to move it to the 3D cursor.")
    if type in ('FIRST', 'LAST'):
        bmesh = _bmesh(what)
        obj = _edited(what)
        label = "At First" if type == 'FIRST' else "At Last"
        if not bpy.context.tool_settings.mesh_select_mode[0]:
            raise RuntimeError(label + " merges at the vertex selected " + ("first" if type == 'FIRST' else "last")
                               + ", which Blender only keeps in Vertex select mode: switch to Vertex.")
        history = list(bmesh.from_edit_mesh(obj.data).select_history)
        # Either end of an empty history is no vertex: a box select or Select
        # All leaves none, and `history[0]` raised IndexError there, which the
        # banner showed as "list index out of range" (round 4's review,
        # measured in 5.2.1 with three vertices selected without an order).
        end = (history[0] if type == 'FIRST' else history[-1]) if history else None
        if end is None or not isinstance(end, bmesh.types.BMVert):
            raise RuntimeError(label + " merges at the vertex selected " + ("first" if type == 'FIRST' else "last")
                               + ", and Blender holds no order for this selection: select the vertices one at a "
                               "time, by tapping, so Blender keeps the order.")


# --------------------------------------------------------------------------
# The app's view, as Blender's region would hold it.

class _View:
    """The app's 3D View: `viewinv`'s axes (x right, y up, z towards the
    eye) and the eye, and the projection Blender's `ED_view3d_project_float`
    makes, up to the pixel scale and offset, which nothing below depends on
    (the side of a line, a normal's direction, a ray)."""

    def __init__(self, what, eye, forward, up, ortho):
        from mathutils import Vector
        if not _finite(list(eye) + list(forward) + list(up)):
            raise RuntimeError(what + " was given a view that is not a number.")
        forward = Vector(forward)
        if forward.length < 1e-9:
            raise RuntimeError(what + " was given no direction to look along.")
        forward.normalize()
        z = -forward
        up = Vector(up)
        y = up - z * up.dot(z)
        if y.length < 1e-6:
            # Looking along the up vector: any up across the line of sight.
            y = Vector((0.0, 0.0, 1.0)) if abs(z.z) < 0.9 else Vector((0.0, 1.0, 0.0))
            y = y - z * y.dot(z)
        y.normalize()
        self.x, self.y, self.z = y.cross(z), y, z
        self.eye = Vector(eye)
        self.ortho = bool(ortho)

    def project(self, p):
        """`ED_view3d_project_float_object` with V3D_PROJ_TEST_NOP: behind
        the eye it still projects (through the eye, mirrored), as Blender's
        does; on the eye's plane it lands on the middle (Blender's 1/w is 0)."""
        d = p - self.eye
        if self.ortho:
            return (d.dot(self.x), d.dot(self.y))
        w = -d.dot(self.z)
        s = 1.0 / w if w != 0.0 else 0.0
        return (d.dot(self.x) * s, d.dot(self.y) * s)

    def win_to_3d(self, depth, target):
        """`ED_view3d_win_to_3d`: the point under the pointer — which is over
        `target` — on the plane through `depth` facing the view."""
        if self.ortho:
            # The line through the pointer along the view, its point nearest
            # `depth` (`ray_point_factor_v3`).
            return target + self.z * (depth - target).dot(self.z)
        direction = target - self.eye
        along = direction.dot(self.z)
        if abs(along) < 1e-30:
            return depth.copy()
        # The unsigned factor, so the point is in front of the view whatever
        # side the plane is on, as Blender takes `fabsf(lambda)`.
        factor = abs((depth - self.eye).dot(self.z) / along)
        return self.eye + direction * factor


def _line_point_side_v2(l1, l2, pt):
    return (l1[0] - pt[0]) * (l2[1] - pt[1]) - (l2[0] - pt[0]) * (l1[1] - pt[1])


def _saasin(f):
    return -math.pi / 2 if f <= -1.0 else (math.pi / 2 if f >= 1.0 else math.asin(f))


def _angle_normalized(v1, v2):
    """`angle_normalized_v3v3`, which is more exact than `acos` near 0 and pi."""
    if v1.dot(v2) >= 0.0:
        return 2.0 * _saasin((v1 - v2).length / 2.0)
    return math.pi - 2.0 * _saasin((v1 + v2).length / 2.0)


def _axis_angle_to_mat3(axis, angle):
    """`axis_angle_to_mat3`: the identity for an axis of no length."""
    from mathutils import Matrix
    if axis.length == 0.0 or not math.isfinite(axis.length):
        return Matrix.Identity(3)
    return Matrix.Rotation(angle, 3, axis.normalized())


def _mirror_excluded_edges(obj, bm):
    """`edbm_extrude_edge_exclude_mirror`: under a Mirror modifier with
    Clipping, the selected boundary edges lying on its plane are not
    extruded, so the mirrored halves stay joined."""
    excluded = set()
    for md in obj.modifiers:
        if md.type != 'MIRROR' or not md.show_viewport or not md.use_clip:
            continue
        mtx = None
        if md.mirror_object is not None:
            mtx = md.mirror_object.matrix_world.inverted() @ obj.matrix_world
        tol = md.merge_threshold
        for e in bm.edges:
            if not e.select or len(e.link_faces) != 1 or not e.link_loops[0].face.select:
                continue
            co1, co2 = e.verts[0].co.copy(), e.verts[1].co.copy()
            if mtx is not None:
                co1, co2 = mtx @ co1, mtx @ co2
            for axis in range(3):
                if md.use_axis[axis] and abs(co1[axis]) < tol and abs(co2[axis]) < tol:
                    excluded.add(e)
    return excluded


def _extrude_ex(bmesh, obj, bm, htype):
    """`edbm_extrude_ex(…, use_normal_flip=false, use_dissolve_ortho_edges=
    false, use_mirror=true, use_select_history=true)`."""
    if 'FACE' in htype:
        htype = htype | {'EDGE'}
    geom = []
    if 'VERT' in htype:
        geom += [v for v in bm.verts if v.select]
    if 'EDGE' in htype:
        geom += [e for e in bm.edges if e.select]
    if 'FACE' in htype:
        geom += [f for f in bm.faces if f.select]
    excluded = _mirror_excluded_edges(obj, bm)
    # BM_SELECT_HISTORY_BACKUP / EDBM_flag_disable_all / _RESTORE.
    history = list(bm.select_history)
    for seq in (bm.verts, bm.edges, bm.faces):
        for ele in seq:
            ele.select_set(False)
    bm.select_history.clear()
    for ele in history:
        if ele.is_valid:
            bm.select_history.add(ele)
    ret = bmesh.ops.extrude_face_region(bm, geom=geom, edges_exclude=excluded, use_normal_flip=False,
                                        use_dissolve_ortho_edges=False, use_select_history=True)
    for ele in ret['geom']:
        ele.select_set(True)


def to_cursor(eye, forward, up, ortho=False, target=None, rotate_source=True):
    """Blender's Extrude to Cursor or Add with the pointer over `target` —
    the 3D cursor unless a check says otherwise — in the view looking from
    `eye` along `forward`. Returns the vertices, edges and faces of the
    active mesh afterwards."""
    from mathutils import Vector, Matrix
    what = "Extrude to Cursor or Add"
    bmesh = _bmesh(what)
    active = _edited(what)
    scene = bpy.context.scene
    view = _View(what, eye, forward, up, ortho)
    cursor = scene.cursor.location.copy()
    target = cursor if target is None else Vector(target)
    if not _finite(target):
        raise RuntimeError(what + " was given a place that is not a number.")
    if not view.ortho and (target - view.eye).dot(view.z) >= 0.0:
        raise RuntimeError(what + " extrudes towards the 3D cursor as the view shows it, and the cursor is "
                           "behind the view: turn the view towards the cursor first.")
    ts = scene.tool_settings
    # Blender projects the result onto the faces under it when snapping to
    # Face (Project) is on (`EDBM_project_snap_verts`), which casts rays
    # through a drawn region this Blender has none of.
    if ts.use_snap and ('FACE' in ts.snap_elements_base or 'FACE_PROJECT' in ts.snap_elements_individual):
        raise RuntimeError(what + " would project onto the faces under the pointer, as Blender does while "
                           "Snapping to Face is on, and that needs a drawn 3D View: turn Snapping off first.")
    objects = _edit_objects()
    # The extrusion is worked out in each object's own space, and an object
    # scaled to nothing on an axis has none to work in: `inverted_safe` put
    # the new vertex 2.17e8 m out where Blender's own invoke left it at
    # (-1, -1, -1) (round 4's review, measured in 5.2.1; at a scale of 1e-6
    # the two agree within 0.2 %). Checked before any mesh is changed.
    for obj in objects:
        if obj.matrix_world.to_3x3().determinant() == 0.0:
            raise RuntimeError(what + " works in the object's own space, and " + obj.name + " is scaled to "
                               "nothing on an axis: set its Scale to something other than 0 first.")
    # Priced before any mesh is changed (its own vertices), and through each
    # mesh's stack, exactly, once the bmesh code below has run and before
    # Blender evaluates it — taken back when that is past the budget: this is
    # bmesh code of the app's own, which no operator's price sees (round 4's
    # second fix-round review: Suzanne under Subdivision 5, Select All and
    # three presses, 504,482 → 4,202,512 vertices, nothing refused).
    _budget_module().price_extrude_to_cursor()
    import sys
    gate = sys.modules.get('_blenderkit_gate')
    if gate is None:
        try:
            import _blenderkit_gate as gate
        except ImportError:
            gate = None
    if gate is None:
        return _to_cursor(what, bmesh, active, scene, view, cursor, target, ts, objects, rotate_source)
    with gate.editing(what):
        return _to_cursor(what, bmesh, active, scene, view, cursor, target, ts, objects, rotate_source)


def _to_cursor(what, bmesh, active, scene, view, cursor, target, ts, objects, rotate_source):
    from mathutils import Vector, Matrix
    mval = view.project(target)

    # First the middle of the selection, over every mesh being edited.
    center = Vector()
    verts_len = 0
    for obj in objects:
        bm = bmesh.from_edit_mesh(obj.data)
        sel = [v for v in bm.verts if v.select]
        if not sel:
            continue
        local = sum((v.co for v in sel), Vector()) / len(sel)
        center += (obj.matrix_world @ local) * len(sel)
        verts_len += len(sel)
    if verts_len:
        center /= verts_len

    for obj in objects:
        me = obj.data
        bm = bmesh.from_edit_mesh(me)
        if verts_len:
            if not any(v.select for v in bm.verts):
                continue
        elif obj != active:
            continue
        world = obj.matrix_world
        inverse = world.inverted_safe()
        local_center = inverse @ center
        if verts_len:
            select_mode = tuple(ts.mesh_select_mode)
            htype = {'VERT', 'EDGE', 'FACE'}
            if select_mode[0]:
                pass
            elif select_mode[1]:
                htype.discard('VERT')
            else:
                htype -= {'VERT', 'EDGE'}
            if not any(e.select for e in bm.edges):
                htype -= {'EDGE', 'FACE'}
            elif not any(f.select for f in bm.faces):
                htype.discard('FACE')

            # The selected edges' normal on screen, each pointing away from
            # the pointer's side, weighted by its length there.
            nor = [0.0, 0.0]
            done = False
            for e in bm.edges:
                if not e.select:
                    continue
                co1 = view.project(world @ e.verts[0].co)
                co2 = view.project(world @ e.verts[1].co)
                if _line_point_side_v2(co1, co2, mval) >= 0.0:
                    nor[0] += co1[1] - co2[1]
                    nor[1] += -(co1[0] - co2[0])
                else:
                    nor[0] += co2[1] - co1[1]
                    nor[1] += -(co2[0] - co1[0])
                done = True
            rot = inverse.to_3x3()
            normal = Vector()
            if done:
                normal = rot @ (view.x * nor[0] + view.y * nor[1])
                view_vec = rot @ view.z
                cross = normal.cross(view_vec)
                normal = view_vec.cross(cross)
                if normal.length > 0.0:
                    normal.normalize()

            ofs = inverse @ view.win_to_3d(world @ local_center, target) - local_center

            mat = Matrix.Identity(3)
            if done:
                vec = ofs.normalized() if ofs.length > 0.0 else Vector()
                angle = _angle_normalized(vec, normal)
                if angle != 0.0:
                    axis = normal.cross(vec)
                    if rotate_source:
                        angle *= 0.5
                    mat = _axis_angle_to_mat3(axis, angle)

            if rotate_source:
                bmesh.ops.rotate(bm, cent=local_center, matrix=mat, verts=[v for v in bm.verts if v.select])
            _extrude_ex(bmesh, obj, bm, htype)
            selected = [v for v in bm.verts if v.select]
            bmesh.ops.rotate(bm, cent=local_center, matrix=mat, verts=selected)
            bmesh.ops.translate(bm, vec=ofs, verts=selected)
        else:
            point = inverse @ view.win_to_3d(cursor, target)
            made = bmesh.ops.create_vert(bm, co=point)
            for v in made['vert']:
                v.select_set(True)
        bmesh.update_edit_mesh(me, loop_triangles=True, destructive=True)
    bm = bmesh.from_edit_mesh(active.data)
    return len(bm.verts), len(bm.edges), len(bm.faces)


# --------------------------------------------------------------------------
# Rip Vertices and Extend.

def pointer_ray(eye, forward, ortho=False, target=None):
    """The ray `edbm_rip_edge_invoke` makes from the pointer
    (`ED_view3d_win_to_ray`), with the pointer over `target` — the 3D cursor
    unless given — in the app's view: a point on it and its direction, which
    is all `rip_edge`'s exec reads (`closest_to_line_v3`)."""
    from mathutils import Vector
    what = "Rip Vertices and Extend"
    target = bpy.context.scene.cursor.location.copy() if target is None else Vector(target)
    if not _finite(list(eye) + list(forward) + list(target)):
        raise RuntimeError(what + " was given a view that is not a number.")
    direction = Vector(forward) if ortho else target - Vector(eye)
    if direction.length < 1e-9:
        raise RuntimeError(what + " extends towards the 3D cursor as the view shows it, and the cursor is at "
                           "the eye: move the view or the cursor first.")
    direction.normalize()
    return tuple(target), tuple(direction)
