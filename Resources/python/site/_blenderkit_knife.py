"""Blender's Knife Project, with no 3D View to aim it.

`bpy.ops.mesh.knife_project` cuts the outline of another object into the mesh
being edited, projected along the 3D View's line of sight. Everything below was
measured in Blender 5.2.1 LTS under `-b --factory-startup`, the bpy an iPad
has: a window and a screen, but no area and no region.

  * Its poll wants a 3D View: "Expected a view3d region & editmesh". Under
    `temp_override(window, area, region)` with the startup screen's 3D View it
    polls True and cuts.

  * It cuts along that view's `perspective_matrix`, which is read-only and
    which nothing else recomputes headless: not setting `view_matrix`, not
    `view3d.view_axis` or `view3d.view_all` (both FINISHED, matrix unchanged),
    not `region.tag_redraw()`. Left as the startup file has it, a circle at
    (0, 0, 3) cut a plane lying at z = 0 around (-8.69, 3.87) — on the ray from
    that view's eye at (15.04, -6.70, 8.20) through the circle, nine and a half
    metres from where the cutter was.

  * `RegionView3D.update()` recomputes it, and with no GPU context it crashes
    Blender (`GPU_matrix_frustum_set`, from `view3d_winmatrix_set`).
    `gpu.init()` is what makes it safe: it starts the GPU module in background
    mode — the same `WM_init_gpu` the first Eevee render calls — and leaves the
    context current on the main thread. After it, `update()` works, before or
    after an Eevee render. On a worker thread there is no context; there,
    desktop Blender's `gpu.init()` aborted the process outright.

  * Aimed orthographically along the cutter's normal, the cut is exact: a
    32-sided circle of radius 0.5 cut a plane, and the faces of a cube along
    X, Y and Z, with every new vertex at 0.5 to within 1e-6. A circle tilted by
    (0.4, 0.25, 0.3) cut a cube along its own normal to within 2e-5.

  * How tight the view is matters. The knife snaps to geometry within a few
    pixels, so a pixel has to be small against the mesh. Over a grid 0.02
    apart, a circle 1 m across with `view_distance` equal to its size found 222
    of the 232 crossings; at twenty times that, 4; at forty, none — and the
    operator still returned FINISHED. At 0.005 of its size it found all 232,
    and 432 of 432 under a 10 m circle on a 0.1 grid, and circles from 1 mm to
    1 km came out exact. What lies outside the view is still cut.
"""

import contextlib
import threading

import bpy
from mathutils import Vector

# `view_distance` as a share of the cutter's size. See the last point above.
FRAMING = 0.005


def on_main_thread():
    """Whether this is the thread Blender gives its window, area and region
    out on. Sculpting asks the same question (`_blenderkit_sculpt`)."""
    try:
        from _blenderkit_context import _is_main_thread
    except ImportError:
        return threading.current_thread() is threading.main_thread()
    return _is_main_thread()


_on_main_thread = on_main_thread


def _corners(obj):
    return [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]


def _centre(obj):
    corners = _corners(obj)
    return sum(corners, Vector()) / len(corners)


def _size(obj):
    corners = _corners(obj)
    return max(max(c[i] for c in corners) - min(c[i] for c in corners) for i in range(3))


def direction(cutter, target):
    """The way the cut goes: along the cutter's normal, toward the target.

    The normal is the thin axis of the cutter's own bounds, turned by its
    rotation. A circle, a plane, a curve and a text object are all flat in
    their local XY, so for them that is exactly the normal however they have
    been turned since — and turning the cutter is how the cut is aimed, since
    there is no view here to aim instead. Ties go to Z, for the same reason.
    """
    box = [Vector(corner) for corner in cutter.bound_box]
    extent = [max(c[i] for c in box) - min(c[i] for c in box) for i in range(3)]
    axis = min((2, 1, 0), key=lambda i: extent[i])
    local = Vector((0.0, 0.0, 0.0))
    local[axis] = 1.0
    normal = cutter.matrix_world.to_quaternion() @ local
    return -normal if normal.dot(_centre(target) - _centre(cutter)) < 0 else normal


def view3d(what="Knife Project"):
    """(window, area, region) of the startup screen's 3D View, the one the
    app borrows to aim Blender's view: Knife Project here, and the sculpt
    brushes (`_blenderkit_sculpt`), which stroke through the same view.
    `what` names the command in the refusal."""
    for window in bpy.context.window_manager.windows:
        screen = window.screen
        if screen is None:
            continue
        for area in screen.areas:
            if area.type != 'VIEW_3D':
                continue
            for region in area.regions:
                if region.type == 'WINDOW' and region.width > 1 and region.height > 1:
                    return window, area, region
    if what == "Knife Project":
        raise RuntimeError("Knife Project projects through a 3D View, and Blender's "
                           "screen has none to borrow")
    raise RuntimeError(what + " works through Blender's 3D View, and Blender's "
                       "screen has none to borrow")


def _view3d():
    return view3d()


def require_gpu_context(what="Knife Project"):
    """Makes `RegionView3D.update()` safe, or says why it is not.

    Asked on every cut, and before every sculpt stroke: `gpu.init()` returns
    at once when the GPU is already up, and what matters is a context current
    on this thread, because without one `update()` does not raise — it takes
    the process down. An empty `GPUFrameBuffer` is the cheapest thing that
    checks for one and raises ("No active GPU context found", measured on a
    worker thread) instead.
    """
    import gpu
    try:
        gpu.init()
        gpu.types.GPUFrameBuffer()
    except (SystemError, RuntimeError) as error:
        raise RuntimeError(what + " aims Blender's view with its GPU module, "
                           "which is not available here: " + str(error)) from None


def _require_gpu_context():
    require_gpu_context()


def _edited(layer):
    return [o for o in layer.objects if o.mode == 'EDIT' and o.type == 'MESH']


def _counts(objects):
    import bmesh
    counts = []
    for obj in objects:
        bm = bmesh.from_edit_mesh(obj.data)
        counts.append((len(bm.verts), len(bm.edges), len(bm.faces)))
    return counts


@contextlib.contextmanager
def projecting(cutter_name):
    """Aims Blender's 3D View along `cutter_name`'s normal for the call inside.

    The view and the selection are put back afterwards, whether or not the
    call worked. Blender leaves the cutter selected; here it was picked from a
    menu rather than selected, and left selected it joins the next edit
    session and is cut instead of cutting.
    """
    if not hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type'):
        raise NotImplementedError(
            "Knife Project cuts through Blender's 3D View, which the simulator's "
            "stand-in for Blender does not have")
    if not _on_main_thread():
        raise RuntimeError(
            "Knife Project aims Blender's 3D View, which exists on the main thread "
            "only. To run it from a script, turn off Run Scripts Off the Main Thread "
            "in the Scripting tab's Options menu.")

    layer = bpy.context.view_layer
    target = layer.objects.active
    if target is None or target.mode != 'EDIT':
        raise RuntimeError("Knife Project cuts the mesh being edited. Go into Edit Mode first.")
    cutter = bpy.data.objects.get(cutter_name)
    if cutter is None:
        raise RuntimeError("Knife Project: there is no object called %r to cut with."
                           % cutter_name)
    if cutter == target:
        raise RuntimeError("Knife Project cuts %s with another object's outline, not its own."
                           % target.name)
    if cutter.name not in layer.objects or not cutter.visible_get():
        raise RuntimeError("Knife Project: %s is hidden. Show it to cut with it." % cutter.name)

    # Selected when edit mode was entered, the cutter went into edit mode with
    # the target, and the operator then finds nothing to cut with: "No other
    # selected objects have wire or boundary edges to use for projection".
    if cutter.mode == 'EDIT':
        bpy.ops.object.mode_set(mode='OBJECT')
        cutter.select_set(False)
        layer.objects.active = target
        bpy.ops.object.mode_set(mode='EDIT')

    # The operator cuts with every selected object that is not being edited,
    # so the one picked is the only one selected while it runs.
    selection = {o.name: o.select_get() for o in layer.objects if o.mode != 'EDIT'}

    _require_gpu_context()
    window, area, region = _view3d()
    rv3d = area.spaces.active.region_3d
    kept = (rv3d.view_rotation.copy(), rv3d.view_location.copy(),
            rv3d.view_distance, rv3d.view_perspective)
    edited = _edited(layer)
    before = _counts(edited)
    try:
        for name, selected in selection.items():
            obj = bpy.data.objects[name]
            if selected and obj != cutter:
                obj.select_set(False)
        cutter.select_set(True)
        with bpy.context.temp_override(window=window, area=area, region=region):
            rv3d.view_rotation = direction(cutter, target).to_track_quat('-Z', 'Y')
            rv3d.view_location = _centre(cutter)
            rv3d.view_distance = max(_size(cutter), 1e-4) * FRAMING
            rv3d.view_perspective = 'ORTHO'
            rv3d.update()
            yield
    finally:
        (rv3d.view_rotation, rv3d.view_location,
         rv3d.view_distance, rv3d.view_perspective) = kept
        rv3d.update()
        for name, selected in selection.items():
            obj = bpy.data.objects.get(name)
            if obj is not None:
                obj.select_set(selected)

    # Blender answers FINISHED when the outline misses the mesh, and reports
    # it nowhere a bpy module can see. A cut that changed nothing is an error
    # the reader can act on, not a success.
    if _counts(edited) == before:
        raise RuntimeError(
            "Knife Project: the outline of %s does not cross %s along the way it "
            "faces, so nothing was cut. Move it over the part to cut, or turn it "
            "to face that part." % (cutter.name, target.name))


# --------------------------------------------------------------------------
# The drawn knife (K): a path of points the app's 3D View was tapped at.

# The longest lens Blender's 3D View takes (SpaceView3D.lens runs 1 to 250 mm
# in 5.2.1): the narrowest frame a perspective cut can be aimed with.
LONGEST_LENS = 250.0

# The temporary object the path is cut with. It lives only inside `drawing`.
PATH_OBJECT = "_bk_knife_path"


def _finite(values):
    import math
    return all(math.isfinite(v) for v in values)


def _view_rotation(forward, up):
    """The 3D View's rotation for a view looking along `forward` with `up`
    as near its up as `forward` allows: -Z is the line of sight, as
    `projecting` aims it (`to_track_quat('-Z', 'Y')`)."""
    from mathutils import Matrix
    z = -forward
    y = up - z * up.dot(z)
    if y.length < 1e-6:
        return forward.to_track_quat('-Z', 'Y')
    y.normalize()
    x = y.cross(z)
    return Matrix((x, y, z)).transposed().to_quaternion()


@contextlib.contextmanager
def drawing(points, eye, forward, up, ortho=False):
    """Cuts along `points` — the app's knife path, world positions on the
    lines of sight it was tapped along — as Blender's Knife does, for the
    `bpy.ops.mesh.knife_project` call inside.

    Blender's knife (`mesh.knife_tool`) is modal and has no form that runs
    without a pointer: round 3's review measured PASS_THROUGH and no cut
    under the borrowed 3D View, from EXEC and from INVOKE. Knife Project is
    the same knife: `EDBM_mesh_knife` (editmesh_knife.cc) starts a cut at
    each outline's first point and adds one cut per point after it —
    `knife_start_cut`, then `knifetool_update_mval` and `knife_add_cut` —
    exactly what a click per point does in the modal tool, with the vertex
    and edge snapping a click has turned off, as the knife's Ctrl does. The
    app snaps each point as the modal knife would before it joins the path
    (`KnifeSnap` in CutTools.swift), onto an edge or a vertex exactly, and
    Knife Project takes a point within half a pixel of an edge or a vertex
    as a hit on it (`knife_find_line_hits`). So the path becomes a wire
    object of its own, one edge per segment — closed when it comes back to
    a point it had, which Knife Project then cuts as a closed outline — and
    Blender's view is aimed from where the app's view looks:

      * in perspective, the same eye. A cut between two points is then the
        plane through the eye and the two lines of sight, whatever depth the
        points sit at, and so are the faces the path is in front of (Cut
        Through off cuts only those). The view looks at the path's middle
        with the longest lens there is, so a pixel of Blender's view is as
        small as it can be made around the path.
      * orthographic, the same direction, framed tightly on the path as
        Knife Project's cutter is framed (FRAMING).

    Points that land within half a pixel of each other in that view are one
    point (`_wire`): two points on one line of sight make no plane.

    The view, Blender's lens and clipping and the selection of other
    objects are put back afterwards and the path object removed, whether or
    not the cut worked. A cut that changed nothing raises. What stays
    selected is what Blender's Knife leaves (`_select_like_the_knife`).
    """
    from mathutils import Vector
    what = "Knife"
    if not hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type'):
        raise NotImplementedError(
            "The Knife cuts through Blender's 3D View, which the simulator's stand-in for "
            "Blender does not have")
    if not _on_main_thread():
        raise RuntimeError(
            "The Knife aims Blender's 3D View, which exists on the main thread only. To run it "
            "from a script, turn off Run Scripts Off the Main Thread in the Scripting tab's "
            "Options menu.")
    layer = bpy.context.view_layer
    target = layer.objects.active
    if target is None or target.type != 'MESH' or target.mode != 'EDIT':
        raise RuntimeError("The Knife cuts the mesh being edited. Go into Edit Mode on a mesh first.")
    flat = [float(c) for p in points for c in p] + [float(c) for c in eye] \
        + [float(c) for c in forward] + [float(c) for c in up]
    if not _finite(flat):
        raise RuntimeError("The Knife was given a point that is not a number.")
    raw = [Vector(p) for p in points]
    # The distinct places, for framing the view; the wire is made from all of
    # them once the view is aimed.
    path = []
    for v in raw:
        if not any((v - q).length <= 1e-9 for q in path):
            path.append(v)
    if len(path) < 2:
        raise RuntimeError("The Knife cuts between points: tap at least two.")
    eye = Vector(eye)
    forward = Vector(forward)
    if forward.length < 1e-9:
        raise RuntimeError("The Knife was given no direction to look along.")
    forward.normalize()
    if not ortho and any((p - eye).dot(forward) <= 0 for p in path):
        raise RuntimeError("A point of the knife path is behind the view. Turn the view back "
                           "to where the path was drawn, or Cancel it.")

    # Blender cuts with every selected object that is not being edited, so the
    # path is the only one selected while it runs (`projecting` says why).
    selection = {o.name: o.select_get() for o in layer.objects if o.mode != 'EDIT'}
    _require_gpu_context_for(what)
    window, area, region = view3d(what)
    space = area.spaces.active
    rv3d = space.region_3d
    kept = (rv3d.view_rotation.copy(), rv3d.view_location.copy(),
            rv3d.view_distance, rv3d.view_perspective)
    kept_space = (space.lens, space.clip_start, space.clip_end)
    edited = _edited(layer)
    before = _counts(edited)
    select_mode = tuple(bpy.context.scene.tool_settings.mesh_select_mode)
    old_selection = _selection(edited)

    # Where the mesh is, so Blender's clipping takes all of it in and no
    # more. The knife starts each line of sight at the near end of the clip
    # range (`ED_view3d_win_to_segment_clipped`) in float32, so a range wider
    # than the scene moves the cut: measured in 5.2.1 on a 2 m cube in an
    # orthographic view 22 degrees above the horizon, the default 1000 m
    # range (the rays start 500 m out) put every new vertex 2.2 mm off the
    # plane the path makes; the range fitted to the mesh, 0.04 mm.
    corners = [target.matrix_world @ Vector(c) for c in target.bound_box]
    centre = sum(path, Vector()) / len(path)
    low = Vector([min(c[i] for c in corners) for i in range(3)])
    high = Vector([max(c[i] for c in corners) for i in range(3)])

    mesh = cutter = None
    tags = None
    cut_view = None
    cut = False
    try:
        for name, selected in selection.items():
            if selected:
                bpy.data.objects[name].select_set(False)
        with bpy.context.temp_override(window=window, area=area, region=region):
            rotation_up = Vector(up)
            if ortho:
                # Blender's orthographic range is half the clip end either
                # side of the view's centre, which is the path's middle.
                reach = max(max((c - centre).length for c in corners),
                            max((p - centre).length for p in path))
                size = max(max((p - centre).length for p in path) * 2, 1e-4)
                rv3d.view_rotation = _view_rotation(forward, rotation_up)
                rv3d.view_location = centre
                rv3d.view_distance = size * FRAMING
                rv3d.view_perspective = 'ORTHO'
                space.clip_end = max(2.2 * reach, 1e-4)
            else:
                rays = [(p - eye).normalized() for p in path]
                axis = sum(rays, Vector())
                axis = axis.normalized() if axis.length > 1e-9 else forward
                depth = max((centre - eye).dot(axis), 1e-4)
                # From half the way to the mesh's bounds (or very near, from
                # inside them) to a little past their far corner.
                nearest = Vector([min(max(eye[i], low[i]), high[i]) for i in range(3)])
                gap = (nearest - eye).length
                far = max((c - eye).length for c in corners)
                rv3d.view_rotation = _view_rotation(axis, rotation_up)
                rv3d.view_location = eye + axis * depth
                rv3d.view_distance = depth
                rv3d.view_perspective = 'PERSP'
                space.lens = LONGEST_LENS
                space.clip_start = max(1e-6, gap * 0.5 if gap > 0 else depth * 1e-3)
                space.clip_end = max(1.1 * far, space.clip_start * 2)
            rv3d.update()
            vertices, edges = _wire(raw, region, rv3d)
            # The cut as Blender's view sees it, for telling the edges the
            # knife makes along it from the ones it adds to join an island
            # (`_select_like_the_knife`).
            cut_view = _CutView(rv3d.perspective_matrix.copy(), region.width, region.height,
                                [(Vector(vertices[a]), Vector(vertices[b])) for a, b in edges])
            if not edges:
                raise RuntimeError("The knife path's points are on one line of sight from this view, so "
                                   "there is nothing between them to cut. Turn the view back to where the "
                                   "path was drawn, or tap another point.")
            mesh = bpy.data.meshes.new(PATH_OBJECT)
            mesh.from_pydata(vertices, edges, [])
            cutter = bpy.data.objects.new(PATH_OBJECT, mesh)
            bpy.context.scene.collection.objects.link(cutter)
            cutter.select_set(True)
            tags = _tag(edited)
            yield
            cut = True
    finally:
        (rv3d.view_rotation, rv3d.view_location,
         rv3d.view_distance, rv3d.view_perspective) = kept
        space.lens, space.clip_start, space.clip_end = kept_space
        rv3d.update()
        if cutter is not None:
            bpy.data.objects.remove(cutter, do_unlink=True)
        if mesh is not None and mesh.users == 0:
            bpy.data.meshes.remove(mesh)
        for name, selected in selection.items():
            obj = bpy.data.objects.get(name)
            if obj is not None:
                obj.select_set(selected)
        if not cut and tags is not None:
            _untag(edited, tags)

    try:
        if _counts(edited) == before:
            # Knife Project has already cleared the selection and turned
            # Vertex select mode off by now, cut or no cut (measured in the
            # app, 5.3: a path past a cube left Edge select mode on). Nothing
            # was cut, so the elements are the ones there were, and what they
            # had is put back.
            _restore_selection(edited, select_mode, old_selection)
            raise RuntimeError(
                "The knife path does not cross %s where the view sees it, so nothing was cut: it "
                "misses the mesh, or runs along edges the mesh already has. Draw it across the mesh "
                "where it shows, or turn on Cut Through to cut what is behind." % target.name)
        _select_like_the_knife(edited, select_mode, tags, cut_view)
    finally:
        _untag(edited, tags)


# Two points of the path closer than this in Blender's knife view are one:
# the knife's own tolerance for a point on a vertex when it runs without a
# pointer (`knife_find_line_hits`: vert_tol 0.5 px, not interactive).
SAME_POINT_PX = 0.5


def _wire(points, region, rv3d):
    """The knife path as a wire mesh: (vertices, edges).

    A point within SAME_POINT_PX of an earlier one in the view the cut is
    made in is that point, so a path that comes back to where it was closes
    there (an edge back to that vertex, which Knife Project cuts as a closed
    outline: `knifeproject_poly_from_object` repeats a cyclic outline's first
    point), and two points on one line of sight become one. Round 4's review
    measured what such points did to the cut in 5.2.1 while only identical
    ones were joined: p1 on a cube's face, p2 on its line of sight at 1.8
    times the depth, p3 across the face cut 11/14/6 — a duplicate vertex at
    p1, two loose edges and the face not split — and [p1, p2] alone two
    coincident vertices joined by an edge of no length. Repeated edges and
    edges of no length are left out."""
    from bpy_extras.view3d_utils import location_3d_to_region_2d
    places, screens, order = [], [], []
    for p in points:
        s = location_3d_to_region_2d(region, rv3d, p)
        index = None
        for i, (q, t) in enumerate(zip(places, screens)):
            if (s is not None and t is not None and (s - t).length < SAME_POINT_PX) or (p - q).length <= 1e-9:
                index = i
                break
        if index is None:
            places.append(p)
            screens.append(s)
            index = len(places) - 1
        if not order or order[-1] != index:
            order.append(index)
    edges, seen = [], set()
    for a, b in zip(order, order[1:]):
        key = (min(a, b), max(a, b))
        if a != b and key not in seen:
            seen.add(key)
            edges.append((a, b))
    return [tuple(p) for p in places], edges


EDGE_TAG = "_bk_knife_edge"
FACE_TAG = "_bk_knife_face"


def _tag(objects):
    """Marks every edge and face of the meshes about to be cut with what it
    had selected (2) or not (1), in integer layers the knife carries through
    its cut: an edge it splits gives its half its own data (`BM_edge_split`,
    `BM_elem_attrs_copy`), a face it splits gives the pieces the face's
    (`BM_face_split_edgenet` makes each with the face as its example), and an
    edge it makes inside a face has none, so it reads 0. Vertices are told by
    their position, which a cut never moves. Returns what `_select_like_the_knife`
    reads: the layers and each mesh's selected vertices and selection order."""
    import bmesh
    out = {}
    for obj in objects:
        bm = bmesh.from_edit_mesh(obj.data)
        edge_layer = bm.edges.layers.int.get(EDGE_TAG) or bm.edges.layers.int.new(EDGE_TAG)
        face_layer = bm.faces.layers.int.get(FACE_TAG) or bm.faces.layers.int.new(FACE_TAG)
        # A new layer can reallocate the elements' data: read them again.
        bm = bmesh.from_edit_mesh(obj.data)
        edge_layer = bm.edges.layers.int[EDGE_TAG]
        face_layer = bm.faces.layers.int[FACE_TAG]
        for e in bm.edges:
            e[edge_layer] = 2 if e.select else 1
        for f in bm.faces:
            f[face_layer] = 2 if f.select else 1
        verts = {tuple(v.co) for v in bm.verts if v.select}
        history = []
        for element in bm.select_history:
            if isinstance(element, bmesh.types.BMVert):
                history.append(('V', tuple(element.co)))
            elif isinstance(element, bmesh.types.BMEdge):
                history.append(('E', frozenset((tuple(element.verts[0].co), tuple(element.verts[1].co)))))
            else:
                # In loop order: `BMFaceSeq.get` finds a face by its corners in order.
                history.append(('F', tuple(tuple(v.co) for v in element.verts)))
        out[obj.name] = (verts, history)
    return out


def _untag(objects, tags):
    import bmesh
    if not tags:
        return
    for obj in objects:
        if obj.name not in tags or obj.mode != 'EDIT':
            continue
        bm = bmesh.from_edit_mesh(obj.data)
        for layers, name in ((bm.edges.layers.int, EDGE_TAG), (bm.faces.layers.int, FACE_TAG)):
            layer = layers.get(name)
            if layer is not None:
                layers.remove(layer)
        bmesh.update_edit_mesh(obj.data)
    tags.clear()


def _selection(objects):
    import bmesh
    out = {}
    for obj in objects:
        bm = bmesh.from_edit_mesh(obj.data)
        out[obj.name] = ([v.select for v in bm.verts], [e.select for e in bm.edges], [f.select for f in bm.faces])
    return out


def _restore_selection(objects, select_mode, selection):
    """The select mode and every element's selection as `_selection` read
    them, on a mesh whose elements have not changed."""
    import bmesh
    tool = bpy.context.scene.tool_settings
    if tuple(tool.mesh_select_mode) != select_mode:
        tool.mesh_select_mode = select_mode
    for obj in objects:
        kept = selection.get(obj.name)
        if kept is None:
            continue
        bm = bmesh.from_edit_mesh(obj.data)
        groups = (bm.verts, bm.edges, bm.faces)
        if any(len(flags) != len(elements) for flags, elements in zip(kept, groups)):
            continue
        # Deselecting an edge or a face deselects its vertices too
        # (BM_edge_select_set), so everything goes first and only what was
        # selected comes back: a selection read from Blender is already
        # flushed, so selecting an edge brings back nothing it did not have.
        for elements in reversed(groups):
            for element in elements:
                element.select = False
        for flags, elements in zip(kept, groups):
            for flag, element in zip(flags, elements):
                if flag:
                    element.select = True
        bmesh.update_edit_mesh(obj.data, loop_triangles=False, destructive=False)


class _CutView:
    """Blender's knife view as the cut was made in it: where a point lands
    (`location_3d_to_region_2d`'s arithmetic, on a copy of the view's
    matrix, so it holds after the view is put back) and whether it lands on
    the cut's path."""

    def __init__(self, matrix, width, height, segments):
        self.matrix, self.width, self.height = matrix, width, height
        self.segments = [(self.project(a), self.project(b)) for a, b in segments]

    def project(self, co):
        from mathutils import Vector
        prj = self.matrix @ Vector((co[0], co[1], co[2], 1.0))
        if prj.w <= 0.0:
            return None
        return Vector((self.width / 2 * (1 + prj.x / prj.w), self.height / 2 * (1 + prj.y / prj.w)))

    def on_cut(self, co, tolerance=1.0):
        from mathutils.geometry import intersect_point_line
        s = self.project(co)
        if s is None:
            return False
        for a, b in self.segments:
            if a is None or b is None:
                continue
            if (b - a).length < 1e-9:
                if (s - a).length <= tolerance:
                    return True
                continue
            point, along = intersect_point_line(s, a, b)
            along = min(max(along, 0.0), 1.0)
            if (s - (a + (b - a) * along)).length <= tolerance:
                return True
        return False


def _select_like_the_knife(objects, select_mode, tags, cut_view):
    """What Blender's Knife leaves selected, in place of what Knife Project
    does.

    Knife Project ends by selecting the faces inside the cutter's outline and
    turning Vertex select mode off (`knifeproject_exec`, editmesh_knife_project.cc:
    `EDBM_selectmode_disable(..., SCE_SELECT_VERTEX, SCE_SELECT_EDGE)`).
    Measured in 5.2.1, a two-point path across a cube left Edge select mode
    on in place of Vertex and nothing selected. Blender's Knife keeps the
    select mode and the selection (editmesh_knife.cc):

      * outside Face select mode (`select_result`, `selectmode !=
        SCE_SELECT_FACE`) every edge along the cut, made by it
        (`knife_make_face_cuts`) or already there (`knife_make_cuts`: "Select
        edges that lie directly on the cut");
      * in Face select mode, the edges it makes inside a selected face;
      * the edges it adds to join a closed path inside a face to the face's
        border (`BM_face_split_edgenet_connect_islands`) when that face is
        selected, in any mode;
      * an edge it splits keeps its selection in both halves
        (`BM_edge_split`), a face it splits in every piece
        (`BM_face_split_edgenet`), and a vertex it makes is selected only as
        the end of an edge it selects;

    and then flushes the select mode up (`knifetool_finish_single_post`:
    `EDBM_selectmode_flush`): in Vertex mode an edge is selected when both
    its ends are and a face when all its edges are, in Edge mode a face when
    all its edges are, in Face mode nothing. That is what this puts back,
    reading `_tag`'s layers and the cut's place in Blender's view, and the
    selection order of what the cut left as it was."""
    import bmesh
    tool = bpy.context.scene.tool_settings
    if tuple(tool.mesh_select_mode) != select_mode:
        tool.mesh_select_mode = select_mode
    modes = {name for name, on in zip(('VERT', 'EDGE', 'FACE'), select_mode) if on}
    for obj in objects:
        kept = (tags or {}).get(obj.name)
        bm = bmesh.from_edit_mesh(obj.data)
        edge_layer = bm.edges.layers.int.get(EDGE_TAG)
        face_layer = bm.faces.layers.int.get(FACE_TAG)
        if kept is None or edge_layer is None or face_layer is None:
            continue
        old_verts, history = kept
        mw = obj.matrix_world

        def along(e):
            if cut_view is None:
                return e[edge_layer] == 0
            a, b = mw @ e.verts[0].co, mw @ e.verts[1].co
            return cut_view.on_cut(a) and cut_view.on_cut(b) and cut_view.on_cut((a + b) / 2)

        def in_selected_face(e):
            return any(f[face_layer] == 2 for f in e.link_faces)

        chosen = []
        for e in bm.edges:
            if e.hide:
                continue
            on_cut = along(e)
            if 'VERT' in modes or 'EDGE' in modes:
                if on_cut or (e[edge_layer] == 0 and in_selected_face(e)):
                    chosen.append(e)
            elif e[edge_layer] == 0 and in_selected_face(e):
                chosen.append(e)
        for element in list(bm.faces) + list(bm.edges) + list(bm.verts):
            element.select = False
        if 'VERT' in modes:
            for v in bm.verts:
                if tuple(v.co) in old_verts:
                    v.select = True
            for e in chosen:
                e.verts[0].select = True
                e.verts[1].select = True
        elif 'EDGE' in modes:
            for v in bm.verts:
                if tuple(v.co) in old_verts:
                    v.select = True
            for e in bm.edges:
                if e[edge_layer] == 2:
                    e.select = True
            for e in chosen:
                e.select = True
        else:
            for f in bm.faces:
                if f[face_layer] == 2:
                    f.select = True
        bm.select_mode = modes
        bm.select_flush_mode()
        # The selection order, for what the cut left where it was.
        verts = {tuple(v.co): v for v in bm.verts}
        for kind, key in history:
            element = None
            ends = [verts.get(k) for k in ([key] if kind == 'V' else key)]
            if all(ends):
                element = ends[0] if kind == 'V' else bm.edges.get(ends) if kind == 'E' else bm.faces.get(ends)
            if element is not None and element.select:
                bm.select_history.add(element)
        bmesh.update_edit_mesh(obj.data, loop_triangles=False, destructive=False)


def cage_json():
    """Prints, as one line, the edit cage Blender's knife snaps to on the
    active mesh: its vertices in world space and each face that is not
    hidden, by vertex index. The Knife asks for it under a modifier that
    rebuilds the mesh, where the viewport draws the modifier's result and
    Blender's knife still snaps to the cage (`KnifeCage(json:)`)."""
    import bmesh, json
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH' or obj.mode != 'EDIT':
        print(json.dumps({"refused": "The Knife cuts the mesh being edited."}))
        return
    bm = bmesh.from_edit_mesh(obj.data)
    if len(bm.verts) > CAGE_LIMIT:
        print(json.dumps({"refused": "%s has %d vertices, more than the Knife snaps to." % (obj.name, len(bm.verts))}))
        return
    bm.verts.index_update()
    mw = obj.matrix_world
    positions = []
    for v in bm.verts:
        positions.extend(mw @ v.co)
    faces = [[v.index for v in f.verts] for f in bm.faces if not f.hide]
    print(json.dumps({"positions": positions, "faces": faces, "vertices": len(bm.verts)}))


# The most cage vertices `cage_json` hands over in one line.
CAGE_LIMIT = 300000


def _require_gpu_context_for(what):
    require_gpu_context(what)
