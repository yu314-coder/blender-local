"""Blender's Cursor tool, run where Blender's own cannot be.

The toolbar's Cursor is `view3d.cursor3d` on a click and a `transform.translate`
of the cursor on a drag (`km_3d_view_tool_cursor` in 5.3's keymap). The click's
operator has an invoke and no exec, and a Blender with no window has no event to
give it: round 3's review measured PASS_THROUGH and an unmoved cursor under the
borrowed 3D View. So `place` is `ED_view3d_cursor3d_update` and the two functions
it calls (`ED_view3d_cursor3d_position`, `ED_view3d_cursor3d_position_rotation`,
view3d_edit.cc in the 5.3 source), ported line for line, with the pointer the
app's finger and the view the app's camera.

What the port cannot read is a drawn 3D View: the depth buffer Surface Project
reads (`ED_view3d_autodist`) and the face the Geometry orientation snaps to
(`snap_object_project_view3d_ex`, SCE_SNAP_TO_FACE on the final geometry). The
app works both out from the mirror, which is Blender's evaluated mesh as the
3D View draws it (`CursorTool.depthHit` and `surfaceHit` in Swift), and hands
them in. `scene.ray_cast` is no stand-in for either: measured in desktop 5.2.1
in Edit Mode, it hits the edit mesh under a Subdivision Surface (y = -0.5 where
the drawn surface is at -0.15) and hits faces Edit Mode has hidden.

Everything else is Blender's own: the cursor tool's settings are read from the
workspace tool Blender keeps for the mode (`WorkSpaceTool.operator_properties`,
which the toolbar's Cursor draws its Surface Project and Orientation from), the
Transform orientation is `_blenderkit_orient`'s port of
`calc_orientation_from_type`, and the cursor is written as `View3DCursor::
set_rotation` writes it, per rotation mode. scripts/run-measure-blender-check.sh
holds the result to Blender's own invoke, run in desktop Blender with a made
event.

No undo step: `VIEW3D_OT_cursor3d` has no OPTYPE_UNDO (its flags are commented
out), and Blender's undo keeps the cursor where it is (`scene_undo_preserve`
swaps the current cursor into the restored scene; measured in desktop 5.2.1
through `_blenderkit_undo`: the cursor moved after a step stayed put through an
Undo and a Redo in Object Mode and an Undo in Edit Mode). Eight invokes left
Blender's stack one step deep.
"""
import math

import bpy

# `VIEW3D_OT_cursor3d`'s `orientation` items, in its order (view3d_edit.cc).
ORIENTATIONS = ('NONE', 'VIEW', 'XFORM', 'GEOM')
# The operator's RNA defaults: Surface Project on, Orientation View (measured
# on a tool Blender had just made for the mode, 5.2.1).
DEFAULT = (True, 'VIEW')
_OPERATOR = 'view3d.cursor3d'
WHAT = "Cursor"


def _workspace():
    window = getattr(bpy.context, 'window', None)
    workspace = getattr(bpy.context, 'workspace', None)
    if workspace is None and window is not None:
        workspace = getattr(window, 'workspace', None)
    return workspace


# The tool Blender gives a mode's 3D View when it makes one
# (`toolsystem_default_tool`, wm_toolsystem.cc): Box Select, but for the brush
# modes, Particle Edit's Comb and Edit Text's Select Text.
DEFAULT_TOOL = 'builtin.select_box'
# Where the app makes a mode's tool for the Cursor's settings: the modes whose
# default is Box Select — Object Mode, Pose Mode and the Edit Modes but Edit
# Text, whose toolbars all have the Cursor (5.2's space_toolsystem_toolbar.py).
# Edit Text's default, Select Text, cannot be started without a window:
# measured in desktop 5.2.1, `wm.tool_set_by_id('builtin.select_text')` failed
# in Blender's own `_activate_by_item` ("WorkSpaceTool.setup(): … keymap
# expected a string type, not function": its keymap is made by the window's
# keymaps) and left behind exactly the unnamed tool this replaces. Calling
# `WorkSpaceTool.setup` from Python instead crashed that Blender
# (WorkSpaceTool_setup_call, exit 139), so nothing here calls it.
_SELECT_TOOLS = ('builtin.select_box',)
_OTHER_DEFAULTS = {'PARTICLE': 'builtin_brush.Comb', 'EDIT_TEXT': 'builtin.select_text'}
_BRUSH_MODES = frozenset((
    'SCULPT', 'PAINT_VERTEX', 'PAINT_WEIGHT', 'PAINT_TEXTURE', 'PAINT_GPENCIL', 'PAINT_GREASE_PENCIL',
    'SCULPT_GPENCIL', 'SCULPT_GREASE_PENCIL', 'WEIGHT_GPENCIL', 'WEIGHT_GREASE_PENCIL', 'VERTEX_GPENCIL',
    'VERTEX_GREASE_PENCIL', 'SCULPT_CURVES'))


def default_tool(mode):
    """`toolsystem_default_tool` for the 3D View in `mode` (bpy.context.mode)."""
    if mode in _BRUSH_MODES:
        return 'builtin.brush'
    return _OTHER_DEFAULTS.get(mode, DEFAULT_TOOL)


def _tool(create):
    """The workspace's tool for the 3D View in the mode Blender is in, which
    holds the Cursor tool's settings for that mode as Blender's toolbar does,
    or None (no workspace, or none made yet and `create` off).

    Made, with `create`, as Blender makes a mode's tool: with the mode's
    default tool (`toolsystem_reinit_ensure_toolref` names a tool it makes
    after `toolsystem_default_tool`), through the toolbar's own activation,
    `wm.tool_set_by_id`. `from_space_view3d_mode(create=True)` made one named
    '': round 4's review measured it in desktop 5.2.1 (factory startup, Object
    and Edit Mode had none before the Cursor bar's write and an idname of ''
    after it, kept by a save and a reload), and the app's own log then read
    "Tool '' not found for space 'VIEW_3D'". One left that way by an earlier
    build is given the default the same way. Only where that default is Box
    Select (Object Mode, Pose Mode, the Edit Modes but Edit Text, see
    `_SELECT_TOOLS`); in a mode whose default is a brush it refuses rather
    than start a brush tool from a setting — the app's Cursor bar is in
    Object and Edit Mode only."""
    workspace = _workspace()
    if workspace is None:
        return None
    mode = bpy.context.mode
    try:
        tool = workspace.tools.from_space_view3d_mode(mode, create=False)
    except (TypeError, RuntimeError, AttributeError):
        return None
    if not create or (tool is not None and tool.idname):
        return tool
    default = default_tool(mode)
    if mode == 'EDIT_TEXT':
        raise RuntimeError("In Edit Text Blender keeps the Cursor's settings with its Select Text tool, which "
                           "it cannot start without a window. The cursor is placed here with Surface Project "
                           "and View, Blender's defaults.")
    if default not in _SELECT_TOOLS:
        raise RuntimeError("The Cursor's settings are kept with Blender's tool for the mode, which the app "
                           "makes in Object Mode, Pose Mode and the Edit Modes only: here Blender's tool "
                           "would be a brush.")
    try:
        bpy.ops.wm.tool_set_by_id(name=default, space_type='VIEW_3D')
        tool = workspace.tools.from_space_view3d_mode(mode, create=False)
    except (TypeError, RuntimeError, AttributeError):
        tool = None
    if tool is None or not tool.idname:
        raise RuntimeError("The Cursor's settings live in Blender's tool for this mode, which Blender "
                           "could not make here.")
    return tool


def settings(known=False):
    """(Surface Project, Orientation) as Blender holds them for this mode:
    the operator's defaults where Blender has made no tool for the mode yet.
    With `known`, None where the workspace cannot be reached at all — off the
    main thread, where Blender gives out no window (measured: a pass on
    another thread read View while Blender held Geometry) — so the record is
    not made of defaults Blender does not hold."""
    if known and _workspace() is None:
        return None
    tool = _tool(False)
    if tool is None:
        return DEFAULT
    try:
        props = tool.operator_properties(_OPERATOR)
        return bool(props.use_depth), str(props.orientation)
    except (TypeError, RuntimeError, AttributeError):
        return None if known else DEFAULT


def set_settings(use_depth=None, orientation=None):
    """The tool header's Surface Project and Orientation, written where
    Blender's toolbar writes them. Returns what Blender then holds."""
    if orientation is not None and orientation not in ORIENTATIONS:
        raise RuntimeError("The Cursor's Orientation is one of None, View, Transform and Geometry.")
    tool = _tool(True)
    if tool is None:
        raise RuntimeError("The Cursor's settings live in Blender's workspace, and there is none to "
                           "keep them in.")
    props = tool.operator_properties(_OPERATOR)
    if use_depth is not None:
        props.use_depth = bool(use_depth)
    if orientation is not None:
        props.orientation = orientation
    return settings()


# ---------------------------------------------------------------------------
# What Blender's snapping meets in Edit Mode
# ---------------------------------------------------------------------------

# Modifier types Blender leaves out of Edit Mode's stack whatever their switch
# says: no eModifierTypeFlag_SupportsEditmode in their ModifierTypeInfo
# (5.3's MOD_*.cc), which `BKE_modifier_is_enabled` asks for in Edit Mode.
_NOT_IN_EDIT_MODE = frozenset((
    'BUILD', 'CLOTH', 'COLLISION', 'DECIMATE', 'DYNAMIC_PAINT', 'EXPLODE', 'FLUID', 'LINEART',
    'MESH_SEQUENCE_CACHE', 'MESH_TO_VOLUME', 'MULTIRES', 'PARTICLE_SYSTEM', 'SOFT_BODY', 'SURFACE',
    'VOLUME_DISPLACE', 'VOLUME_TO_MESH'))
# Types with no `is_disabled`: on whenever they are switched on.
_ALWAYS_ENABLED = frozenset((
    'CORRECTIVE_SMOOTH', 'EDGE_SPLIT', 'MIRROR', 'OCEAN', 'REMESH', 'SCREW', 'SIMPLE_DEFORM', 'SKIN',
    'SOLIDIFY', 'TRIANGULATE', 'UV_PROJECT', 'UV_WARP', 'WAVE', 'WEIGHTED_NORMAL', 'WELD', 'WIREFRAME'))


def _is(ob, kind):
    return ob is not None and getattr(ob, 'type', None) == kind


def _subsurf_level(md, scene):
    """`get_render_subsurf_level` for the viewport: Levels Viewport, or
    Simplify's Max Subdivision when that is less."""
    r = scene.render
    return min(md.levels, r.simplify_subdivision) if r.use_simplify else md.levels


def _disabled(md, scene):
    """`ModifierTypeInfo.is_disabled` (5.3's MOD_*.cc) where its test reads
    only what RNA shows: True or False, or None where it cannot be told here
    (Normal Edit's target test, Surface Deform's binding, Particle Instance's
    particle system)."""
    t = md.type
    if t in _ALWAYS_ENABLED:
        return False

    def g(name):
        return getattr(md, name, None)

    if t == 'SUBSURF':
        return _subsurf_level(md, scene) == 0
    if t == 'ARMATURE':
        return not _is(g('object'), 'ARMATURE')
    if t == 'ARRAY':
        return any(o is not None and o.type != kind for o, kind in
                   ((g('curve'), 'CURVE'), (g('start_cap'), 'MESH'), (g('end_cap'), 'MESH')))
    if t == 'BEVEL':
        return g('width') == 0.0
    if t == 'BOOLEAN':
        if g('operand_type') == 'OBJECT':
            return not _is(g('object'), 'MESH')
        if g('operand_type') == 'COLLECTION':
            # "The Exact solver tolerates an empty collection."
            return g('collection') is None and g('solver') != 'EXACT'
        return False
    if t in ('CAST', 'SMOOTH'):
        return g('factor') == 0.0 or not (g('use_x') or g('use_y') or g('use_z'))
    if t == 'CURVE':
        return not _is(g('object'), 'CURVE')
    if t == 'DATA_TRANSFER':
        return not _is(g('object'), 'MESH')
    if t == 'DISPLACE':
        return (g('texture') is None and g('direction') == 'RGB_TO_XYZ') or g('strength') == 0.0
    if t == 'HOOK':
        return g('object') is None
    if t == 'LAPLACIANDEFORM':
        return not g('vertex_group')
    if t == 'LAPLACIANSMOOTH':
        return not (g('use_x') or g('use_y') or g('use_z'))
    if t == 'LATTICE':
        return not _is(g('object'), 'LATTICE')
    if t == 'MASK':
        return g('armature') is not None and g('armature').type != 'ARMATURE'
    if t == 'MESH_CACHE':
        return (g('factor') or 0.0) <= 0.0 or not g('filepath')
    if t == 'MESH_DEFORM':
        return not _is(g('object'), 'MESH')
    if t == 'NODES':
        return g('node_group') is None
    if t == 'SHRINKWRAP':
        return not _is(g('target'), 'MESH') or (g('auxiliary_target') is not None
                                                and g('auxiliary_target').type != 'MESH')
    if t == 'WARP':
        return g('object_from') is None or g('object_to') is None
    if t == 'VERTEX_WEIGHT_EDIT':
        return not g('vertex_group')
    if t == 'VERTEX_WEIGHT_MIX':
        return not g('vertex_group_a')
    if t == 'VERTEX_WEIGHT_PROXIMITY':
        return not g('vertex_group') or g('target') is None
    return None


def subdivides_last(obj):
    """The Subdivision Surface Blender evaluates last in Edit Mode, by name, or
    None: what makes Blender's snapping to the final geometry in Edit Mode
    meet a mesh the 3D View does not draw.

    A Subdivision Surface that is the last modifier enabled for the mode
    (`modifier_get_last_enabled_for_mode`, MOD_subsurf.cc) returns its input
    as the final mesh and leaves the subdividing to the drawing code or to
    whoever asks for it (`subdiv_cache_mesh_wrapper_settings`). Snapping to the
    final geometry in Edit Mode reads that mesh as it is
    (`BKE_object_get_editmesh_eval_final` in `data_for_snap`,
    transform_snap_object.cc), and the edit mesh itself where it is the edit
    mesh's wrapper — while the 3D View draws, and the app's mirror holds, the
    subdivided mesh. The Cursor's Geometry orientation and its drag both snap
    that way. Measured in desktop 5.2.1 with Blender's own cursor3d invoke
    (Geometry, a cube at x = +2 turned): under Subdivision Surface alone, or
    Mirror then Subdivision Surface, every snap followed the mesh before the
    subdivision (52 of 52 pixels on the cube, the mirrored copy's 14 on
    neither); under Mirror, Array, Subdivision Surface then Mirror, or
    Subdivision Surface then Simple Deform, Blender met the mesh the mirror
    holds (43, 43, 30 and 16 pixels only it has, none against it).

    Conservative where the stack after it cannot be read: a modifier whose
    `is_disabled` this cannot test counts as maybe off, and the Subdivision
    Surface before it as maybe last."""
    if getattr(obj, 'type', '') != 'MESH' or getattr(obj, 'mode', '') != 'EDIT':
        return None
    scene = bpy.context.scene
    for md in reversed(list(obj.modifiers)):
        if not (md.show_viewport and md.show_in_editmode) or md.type in _NOT_IN_EDIT_MODE:
            continue
        off = _disabled(md, scene)
        if off:
            continue
        if off is None:
            # On, it would be the last; off, the one before is. Only a
            # Subdivision Surface before it matters, so keep looking.
            continue
        return md.name if md.type == 'SUBSURF' else None
    return None


# ---------------------------------------------------------------------------
# blenlib's math, as the port needs it (float, single steps, Blender's order)
# ---------------------------------------------------------------------------

def _safe_acos(x):
    return 0.0 if x >= 1.0 else (math.pi if x <= -1.0 else math.acos(x))


def _safe_asin(x):
    return math.pi / 2 if x >= 1.0 else (-math.pi / 2 if x <= -1.0 else math.asin(x))


def _angle_normalized_v3v3(a, b):
    # `angle_normalized_v3v3`: the asin form, which is more accurate than acos.
    if a.dot(b) >= 0.0:
        return 2.0 * _safe_asin((a - b).length / 2.0)
    return math.pi - 2.0 * _safe_asin((a + b).length / 2.0)


def _axis_dominant_single(v):
    x, y, z = abs(v[0]), abs(v[1]), abs(v[2])
    return (0 if x > z else 2) if x > y else (1 if y > z else 2)


def _axis_dominant_ortho_single(v):
    x, y, z = abs(v[0]), abs(v[1]), abs(v[2])
    return (0 if x < z else 2) if x < y else (1 if y < z else 2)


def _ortho_v3(v):
    from mathutils import Vector
    axis = _axis_dominant_single(v)
    if axis == 0:
        return Vector((-v[1] - v[2], v[0], v[0]))
    if axis == 1:
        return Vector((v[1], -v[0] - v[2], v[1]))
    return Vector((v[2], v[2], -v[0] - v[1]))


def _rotation_between_vecs(v1, v2):
    """`rotation_between_vecs_to_quat` (both unit length)."""
    from mathutils import Quaternion
    axis = v1.cross(v2)
    length = axis.length
    if length > 1.1920929e-07:      # FLT_EPSILON
        axis = axis / length
        angle = _angle_normalized_v3v3(v1, v2)
        return Quaternion((math.cos(angle * 0.5), *(axis * math.sin(angle * 0.5))))
    if v1.dot(v2) > 0.0:
        return Quaternion((1.0, 0.0, 0.0, 0.0))
    axis = _ortho_v3(v1)
    return Quaternion(axis.normalized(), math.pi)


def _angle_signed_on_axis(v1, v2, axis):
    """`angle_signed_on_axis_v3v3_v3`."""
    p1 = v1 - axis * v1.dot(axis)
    p2 = v2 - axis * v2.dot(axis)
    # `angle_v3v3` normalizes both, a zero vector staying zero.
    n1 = p1.normalized() if p1.length > 0.0 else p1
    n2 = p2.normalized() if p2.length > 0.0 else p2
    angle = _angle_normalized_v3v3(n1, n2)
    if p2.cross(p1).dot(axis) < 0.0:
        angle = math.pi * 2.0 - angle
    return angle


def _quat_to_axis_angle(q):
    """`quat_to_axis_angle`."""
    from mathutils import Vector
    ha = _safe_acos(q[0])
    si = math.sin(ha)
    angle = ha * 2.0
    if abs(si) < 0.0005:
        si = 1.0
    axis = Vector((q[1] / si, q[2] / si, q[3] / si))
    if axis.length == 0.0:
        axis[1] = 1.0
    return axis, angle


def _finite(values):
    return all(isinstance(v, (int, float)) and math.isfinite(v) for v in values)


def _vector(what, value, name):
    from mathutils import Vector
    if value is None or len(value) != 3 or not _finite(list(value)):
        raise RuntimeError("%s was given a %s that is not three numbers." % (what, name))
    return Vector(value)


class _View:
    """The app's 3D View as Blender's region view keeps it: `viewinv`'s axes
    (x right, y up, z towards the eye), the eye, the projection, and
    `viewquat`, which Blender keeps world-to-view (`RegionView3D.view_rotation`
    is its inverse, rna_space.cc)."""

    def __init__(self, eye, forward, up, ortho, center):
        from mathutils import Vector, Matrix
        forward = _vector(WHAT, forward, "view direction")
        if forward.length < 1e-9:
            raise RuntimeError(WHAT + " was given no direction to look along.")
        forward.normalize()
        z = -forward
        up = _vector(WHAT, up, "view up")
        y = up - z * up.dot(z)
        if y.length < 1e-6:
            y = Vector((0.0, 0.0, 1.0)) if abs(z.z) < 0.9 else Vector((0.0, 1.0, 0.0))
            y = y - z * y.dot(z)
        y.normalize()
        self.x, self.y, self.z = y.cross(z), y, z
        self.eye = _vector(WHAT, eye, "eye")
        self.center = _vector(WHAT, center, "view centre")
        self.ortho = bool(ortho)
        # What `RegionView3D.view_rotation` holds for these axes (the checks aim
        # the borrowed 3D View with this same quaternion), and `viewquat` its
        # inverse, as `rna_RegionView3D_view_rotation_set` stores it.
        self.view_rotation = Matrix((self.x, self.y, self.z)).transposed().to_quaternion()
        self.viewquat = self.view_rotation.inverted()

    def win_to_3d(self, depth, point):
        """`ED_view3d_win_to_3d`: the point under the pointer — whose line of
        sight passes through `point` — on the plane through `depth` facing the
        view."""
        if self.ortho:
            # The pointer's line along the view, its point nearest `depth`
            # (`ray_point_factor_v3`).
            return point + self.z * (depth - point).dot(self.z)
        direction = point - self.eye
        along = direction.dot(self.z)
        if abs(along) < 1e-30:
            return depth.copy()
        # `isect_ray_plane_v3`, then the unsigned factor: the point is in front
        # of the view whichever side the plane is on (`fabsf(lambda)`).
        factor = abs((depth - self.eye).dot(self.z) / along)
        return self.eye + direction * factor

    def behind(self, co):
        """`ED_view3d_calc_zfac_ex`'s `flip`: the point is behind the eye. An
        orthographic view never flips (its zfac is 1)."""
        if self.ortho:
            return False
        w = -(co - self.eye).dot(self.z)
        if -1e-6 < w < 1e-6:
            return False
        return w < 0.0


def _current_quat(cursor):
    """`View3DCursor::rotation`."""
    from mathutils import Euler, Quaternion
    mode = cursor.rotation_mode
    if mode == 'QUATERNION':
        return Quaternion(cursor.rotation_quaternion).normalized()
    if mode == 'AXIS_ANGLE':
        a = cursor.rotation_axis_angle
        axis = (a[1], a[2], a[3])
        if math.sqrt(axis[0] ** 2 + axis[1] ** 2 + axis[2] ** 2) == 0.0:
            return Quaternion((1.0, 0.0, 0.0, 0.0))
        return Quaternion(axis, a[0])
    return Euler(cursor.rotation_euler, mode).to_quaternion()


def _orientation_matrix(view):
    """`calc_orientation_from_type`: the scene's transform orientation's axes,
    the view's for View. Refused for what `_blenderkit_orient` cannot work
    out (a curve's Normal), which Blender would."""
    import _blenderkit_orient
    from mathutils import Matrix
    kind = bpy.context.scene.transform_orientation_slots[0].type
    if kind == 'VIEW':
        return Matrix((view.x, view.y, view.z)).transposed()
    why = _blenderkit_orient.unavailable(kind)
    if why:
        raise RuntimeError("The Cursor's Orientation is Transform, and " + why[0].lower() + why[1:])
    axes = _blenderkit_orient.matrix(kind)
    return Matrix((axes[0], axes[1], axes[2])).transposed()


def place(eye, forward, up, ortho, point, center, axis_view=False, depth=None, surface=None):
    """Blender's Cursor tool, clicked with the pointer over `point`.

    `eye`, `forward`, `up` and `ortho` are the app's view, `center` its pivot
    (Blender's view location, `-rv3d->ofs`); `point` is any point on the
    pointer's line of sight (the near plane's, as the app casts it).
    `axis_view` says the view is one of the six numpad views
    (`RV3D_VIEW_IS_AXIS`), which only an Axis Angle cursor reads. `depth` is
    where the drawn surfaces meet the pointer, as Surface Project would read
    it, or None where nothing is drawn under it; `surface` is the face under
    the pointer for the Geometry orientation: `(location, normal, x, y, z)`,
    the object's world axes with their scale, or None.

    Returns the cursor's location and its rotation as a quaternion (w, x, y, z).
    """
    from mathutils import Vector, Quaternion
    view = _View(eye, forward, up, ortho, center)
    point = _vector(WHAT, point, "pointer")
    if depth is not None:
        depth = _vector(WHAT, depth, "depth")
    if surface is not None:
        if len(surface) != 5:
            raise RuntimeError(WHAT + " was given a surface that is not a place, a normal and three axes.")
        surface = [_vector(WHAT, s, "surface") for s in surface]
    known = settings(known=True)
    if known is None:
        raise RuntimeError(WHAT + " reads its Surface Project and Orientation from Blender's workspace, which "
                           "Blender gives out on the main thread only. To run it from a script, turn off Run "
                           "Scripts Off the Main Thread in the Scripting tab's Options menu.")
    use_depth, orientation = known
    scene = bpy.context.scene
    cursor = scene.cursor

    # ED_view3d_cursor3d_position.
    co = cursor.location.copy()
    if view.behind(co):
        # The cursor is behind the view: its depth is the view centre's.
        co = view.center.copy()
    if use_depth and depth is not None:
        co = depth.copy()
    else:
        co = view.win_to_3d(co, point)

    # ED_view3d_cursor3d_position_rotation.
    quat_prev = _current_quat(cursor)
    quat = quat_prev.copy()
    if orientation == 'VIEW':
        quat = view.viewquat.copy()
        quat[0] *= -1.0
    elif orientation == 'XFORM':
        quat = _orientation_matrix(view).to_quaternion()
    elif orientation == 'GEOM':
        quat = view.viewquat.copy()
        quat[0] *= -1.0
        if surface is not None:
            ray_co, ray_no, ob_x, ob_y, ob_z = surface
            ray_no = ray_no.normalized()
            if use_depth:
                co = ray_co.copy()
            # Math normal (Z).
            z_src = quat @ Vector((0.0, 0.0, 1.0))
            quat = _rotation_between_vecs(z_src.normalized(), ray_no) @ quat
            # Match object matrix (X), rolling the shortest way (#72419).
            axes = (ob_x, ob_y, ob_z)
            ortho_axis = _axis_dominant_ortho_single([ray_no.dot(a) for a in axes])
            target = axes[ortho_axis]
            tan_dst = target - ray_no * (target.dot(ray_no) / ray_no.dot(ray_no))
            tan_dst.normalize()
            best, angle_best = None, -1.0
            for axis in range(2):
                tan_src = Vector((1.0 if axis == 0 else 0.0, 1.0 if axis == 1 else 0.0, 0.0))
                tan_src = quat @ tan_src
                for _sign in range(2):
                    test = _rotation_between_vecs(tan_src.normalized(), tan_dst)
                    angle = 2.0 * _safe_acos(test[0])
                    if angle < angle_best or angle_best == -1.0:
                        angle_best, best = angle, test
                    tan_src = -tan_src
            quat = best @ quat

    # ED_view3d_cursor3d_update: the rotation is written only when it changed.
    if tuple(quat) != tuple(quat_prev):
        mode = cursor.rotation_mode
        if mode == 'AXIS_ANGLE' and axis_view:
            m = quat.to_matrix()
            axis = -m.col[2]
            # axis_angle_to_mat3(cmat, axis, 0): the identity, whose X is (1, 0, 0).
            angle = _angle_signed_on_axis(Vector((1.0, 0.0, 0.0)), m.col[0].copy(), axis.normalized())
            cursor.rotation_axis_angle = (angle, axis[0], axis[1], axis[2])
        elif mode == 'QUATERNION':
            new = quat.normalized()
            new.make_compatible(Quaternion(cursor.rotation_quaternion))
            cursor.rotation_quaternion = new
        elif mode == 'AXIS_ANGLE':
            axis, angle = _quat_to_axis_angle(quat.normalized())
            cursor.rotation_axis_angle = (angle, axis[0], axis[1], axis[2])
        else:
            from mathutils import Euler
            cursor.rotation_euler = quat.to_euler(mode, Euler(cursor.rotation_euler, mode))
    cursor.location = co
    return tuple(cursor.location), tuple(_current_quat(cursor))


# ---------------------------------------------------------------------------
# What the interface shows: the cursor, the tool's settings, the units
# ---------------------------------------------------------------------------

def _number(v):
    return repr(float(v))


def record():
    """`loc=x,y,z;quat=w,x,y,z;mode=XYZ;depth=1;orient=VIEW` — the cursor as
    Blender holds it and the Cursor tool's settings for the mode Blender is
    in (`CursorState` in Swift); without the settings where they cannot be
    read (`settings(known=True)`), and the interface keeps what it had."""
    cursor = bpy.context.scene.cursor
    q = _current_quat(cursor)
    text = 'loc=%s;quat=%s;mode=%s' % (','.join(_number(v) for v in cursor.location),
                                       ','.join(_number(v) for v in q), cursor.rotation_mode)
    known = settings(known=True)
    if known is not None:
        text += ';depth=%d;orient=%s' % (1 if known[0] else 0, known[1])
    return text


def _grid():
    """The borrowed 3D View's grid scale (`View3DOverlay.grid_scale`), or
    Blender's default, 1."""
    screen = getattr(bpy.context, 'screen', None)
    windows = getattr(bpy.context.window_manager, 'windows', [])
    screens = [screen] if screen is not None else [w.screen for w in windows if w.screen is not None]
    for s in screens:
        for area in s.areas:
            if area.type == 'VIEW_3D':
                return float(area.spaces.active.overlay.grid_scale)
    return 1.0


def units_record():
    """`system=METRIC;rotation=DEGREES;scale=1.0;length=METERS;split=0;grid=1.0`:
    the scene's units, which the ruler and Edit Mode's measurements print
    with (`UnitSettings` in Swift), and the snapping the ruler uses."""
    u = bpy.context.scene.unit_settings
    ts = bpy.context.scene.tool_settings
    return 'system=%s;rotation=%s;scale=%s;length=%s;split=%d;grid=%s;snap_tool=%s' % (
        u.system, u.system_rotation, _number(u.scale_length), u.length_unit,
        1 if u.use_separate else 0, _number(_grid()), getattr(ts, 'snap_elements_tool', 'GEOMETRY'))


def file_record():
    """`loads=N`: how many files have been loaded in front of the reader
    (`_blenderkit_undo.file_loads`), so the interface can let go of what
    belonged to the file it showed — the Measure tool's rulers."""
    import sys
    undo = sys.modules.get('_blenderkit_undo')
    loads = undo.file_loads() if undo is not None and hasattr(undo, 'file_loads') else 0
    return 'loads=%d' % loads


def push():
    """Hands the records over (`_blenderkit_sync`, once a pass)."""
    import _blenderkit
    send = getattr(_blenderkit, 'sync_record', None)
    if send is None:
        return
    send('cursor', '', record())
    send('units', '', units_record())
    send('file', '', file_record())
