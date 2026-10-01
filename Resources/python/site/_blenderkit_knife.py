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
