"""Animation for Blender Local: keyframes, the timeline and playback, done the
way Blender does them — without the window Blender's own operators need.

`bpy.ops.anim.keyframe_insert` and `bpy.ops.anim.keyframe_delete_v3d` both poll
with `modify_key_op_poll`, which requires `CTX_wm_area` (keyframing.cc). The bpy
module on an iPad has no area, so both fail with "context is incorrect". What
they do is done here from the same RNA, and tests/animation/blender/verify.py
holds the result against the operators themselves, run in desktop Blender 5.2.1
under a 3D View override the iPad does not have.

Blender 5 keeps keys in layered actions: `action.fcurves` is gone, and the
curves live in a channelbag per action slot. Everything here reads them there.

The same functions answer against the simulator's shim, whose animation lives
in Swift (Sources/BlenderLocalBridge/Animation.swift).
"""

from array import array
import itertools
import re

import bpy
import _blenderkit

# BEZT_BINARYSEARCH_THRESH: keys closer than this are the same key to Blender.
THRESHOLD = 0.01

# scene.playback_loop_mode, in the order the interface numbers the items
# (PlaybackLoopMode in AnimationTimeline.swift).
LOOP_MODES = ('INFINITE', 'STOP_END_FRAME', 'STOP_START_FRAME', 'RESTORE', 'BOUNCE')

# What the viewport draws as geometry — the set _blenderkit_sync.sync uses.
_DRAWN = {'MESH', 'CURVE', 'SURFACE', 'FONT', 'META'}
_MAX_VERTS = 10_000_000

# Printed by a frame change that the viewport can only follow with a whole
# mirroring pass: a keyed visibility adds or hides an object, which moving
# matrices cannot express. BpyAnimation.fullMirrorMarker in Swift.
FULL_MIRROR = 'BK_ANIM_FULL_MIRROR'

# The report Blender makes when auto keying may not create the F-curves a
# transform would key (CombinedKeyingResult::generate_reports).
AUTOKEY_REPORT = ("Could not create %d F-Curve(s). This can happen when only "
                  "inserting to available F-Curves.")


def is_real_blender():
    """Blender's operators carry their RNA; the shim's are plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


# ---------------------------------------------------------------------------
# Reading keys
# ---------------------------------------------------------------------------

def channelbag(animdata):
    """The F-curves of the action slot a data-block is animated by, or None."""
    if animdata is None:
        return None
    action, slot = animdata.action, animdata.action_slot
    if action is None or slot is None:
        return None
    for layer in action.layers:
        for strip in layer.strips:
            bag = strip.channelbag(slot)
            if bag is not None:
                return bag
    return None


def animated_ids(obj):
    """The object and the data-blocks whose keys the timeline counts as its
    own: its data, the data's shape keys and node tree, and its materials and
    their node trees. A light's energy and a camera's lens are keyed on the
    data, a material's colour on its node tree — none of them on the object."""
    ids = [obj]

    def add(idblock):
        if idblock is None or any(idblock == known for known in ids):
            return
        ids.append(idblock)
        tree = getattr(idblock, 'node_tree', None)
        if tree is not None and not any(tree == known for known in ids):
            ids.append(tree)

    data = getattr(obj, 'data', None)
    add(data)
    if data is not None:
        add(getattr(data, 'shape_keys', None))
    for slot in getattr(obj, 'material_slots', ()):
        add(slot.material)
    return ids


def scene_ids(scene):
    """Keys on the scene itself count everywhere in the timeline: the scene,
    its world and the world's nodes, and the compositor."""
    ids = [scene]
    world = getattr(scene, 'world', None)
    if world is not None:
        ids.append(world)
        if getattr(world, 'node_tree', None) is not None:
            ids.append(world.node_tree)
    compositor = getattr(scene, 'compositing_node_group', None)
    if compositor is not None:
        ids.append(compositor)
    return ids


def _collect(idblock, every, chosen):
    """One data-block's key frames, in scene time, into `every`; the frames
    with a selected key also into `chosen`."""
    animdata = getattr(idblock, 'animation_data', None)
    bag = channelbag(animdata)
    if bag is None:
        return
    tweaked = animdata.use_tweak_mode
    for fcurve in bag.fcurves:
        points = fcurve.keyframe_points
        count = len(points)
        if count == 0:
            continue
        co = array('f', [0.0]) * (2 * count)
        points.foreach_get('co', co)
        selected = array('b', [0]) * count
        points.foreach_get('select_control_point', selected)
        frames = co[0::2]
        if tweaked:
            # A strip being tweaked plays its keys at the strip's time.
            frames = array('f', (animdata.nla_tweak_strip_time_to_scene(f) for f in frames))
        every.update(frames)
        chosen.update(itertools.compress(frames, selected))


def columns(every, chosen):
    """Frames as the columns Blender's keylist makes of them: sorted, with
    frames closer than THRESHOLD merged, selected if any merged key is."""
    out = []
    for frame in sorted(every):
        selected = frame in chosen
        if out and frame - out[-1][0] <= THRESHOLD:
            out[-1][1] = out[-1][1] or selected
        else:
            out.append([frame, selected])
    return out


# ---------------------------------------------------------------------------
# Mirroring: what the timeline shows
# ---------------------------------------------------------------------------

# Whether each object was hidden at the last full mirror, so a frame change can
# tell when keyed visibility means the viewport's object list must change.
_hidden = {}


def _is_hidden(obj):
    hidden = bool(getattr(obj, 'hide_viewport', False))
    try:
        hidden = hidden or not obj.visible_get()
    except (AttributeError, RuntimeError):
        pass
    return hidden


def report():
    """Hand the interface the scene's animation: range, rate, keying settings
    and every object's keys.

    Called by _blenderkit_sync.sync after the meshes are in, so every object
    the keys are reported for is already on screen to receive them."""
    if not hasattr(_blenderkit, 'anim_state') or not is_real_blender():
        # The shim's animation is Swift's to begin with.
        return
    scene = bpy.context.scene
    report_state(scene)
    report_keys(scene)
    _hidden.clear()
    for obj in scene.objects:
        _hidden[obj.name] = _is_hidden(obj)


def report_state(scene=None):
    scene = scene or bpy.context.scene
    render = scene.render
    tool = scene.tool_settings
    edit = bpy.context.preferences.edit
    loop = scene.playback_loop_mode
    _blenderkit.anim_state(
        scene.frame_start, scene.frame_end, scene.frame_current,
        float(scene.frame_subframe), render.fps / render.fps_base,
        int(scene.use_preview_range), scene.frame_preview_start, scene.frame_preview_end,
        int(tool.use_keyframe_insert_auto), int(tool.auto_keying_mode == 'REPLACE_KEYS'),
        int(edit.use_keyframe_insert_available), int(scene.show_keys_from_selected_only),
        LOOP_MODES.index(loop) if loop in LOOP_MODES else 0)


def report_keys(scene=None):
    """Every object's key columns, and the scene's own, in one call."""
    scene = scene or bpy.context.scene
    names = []
    counts = array('I')
    frames = array('f')
    flags = array('B')
    for obj in scene.objects:
        every, chosen = set(), set()
        for idblock in animated_ids(obj):
            _collect(idblock, every, chosen)
        if not every:
            continue
        found = columns(every, chosen)
        names.append(obj.name)
        counts.append(len(found))
        for frame, selected in found:
            frames.append(frame)
            flags.append(1 if selected else 0)
    every, chosen = set(), set()
    for idblock in scene_ids(scene):
        _collect(idblock, every, chosen)
    found = columns(every, chosen)
    _blenderkit.anim_keys('\0'.join(names).encode(), counts.tobytes(), frames.tobytes(),
                          flags.tobytes(), array('f', [f for f, _ in found]).tobytes(),
                          array('B', [1 if s else 0 for _, s in found]).tobytes())


# ---------------------------------------------------------------------------
# Changing the frame
# ---------------------------------------------------------------------------

def frame_set(frame, subframe=0.0):
    """`scene.frame_set`, handing the interface only what the frame changed.

    `depsgraph.updates` is empty outside a handler, but inside
    `frame_change_post` it names exactly what the new frame re-evaluated — the
    objects whose transform changed and those whose geometry did. Measured in
    5.2.1: a keyed object and its children report a transform; shape keys, an
    armature's deform, a keyed modifier and a time-dependent one report
    geometry; an object nothing animates reports nothing at all."""
    scene = bpy.context.scene
    if not is_real_blender():
        # The shim evaluates its animation in Swift as the frame changes.
        scene.frame_set(int(frame))
        return
    changed = {}

    def collect(_scene, depsgraph):
        for update in depsgraph.updates:
            # Only the name and the flags, both read from the evaluated copy,
            # which is the depsgraph's own memory and lives until its next
            # rebuild. Never `update.id.original`: a user's frame_change_post
            # handler that runs before this one can delete the object, the
            # updates still list it, and `original` is then freed memory.
            # Reading it segfaulted desktop 5.2.1 two runs of two (exit 139,
            # pyrna_struct_CreatePyObject under this getattr), and with the
            # memory reused by cameras it raised "'ID' object has no attribute
            # 'matrix_world'" out of the frame instead
            # (tests/animation/blender/handler_removes.py).
            idblock = update.id
            if isinstance(idblock, bpy.types.Object):
                transform, geometry = changed.get(idblock.name, (False, False))
                changed[idblock.name] = (transform or update.is_updated_transform,
                                         geometry or update.is_updated_geometry)

    handlers = bpy.app.handlers.frame_change_post
    handlers.append(collect)
    try:
        scene.frame_set(int(frame), subframe=float(subframe))
    finally:
        handlers.remove(collect)
    if push_frame(scene, changed):
        print(FULL_MIRROR)


def _blenderkit_sync():
    """Imported late: _blenderkit_sync imports this module for its report."""
    import _blenderkit_sync
    return _blenderkit_sync


def push_frame(scene, changed):
    """The matrices and meshes one frame changed. True when the viewport needs
    a whole mirroring pass instead."""
    names = []
    matrices = array('d')
    rebuild = False
    depsgraph = None
    # The objects by name, one table a frame, built from the scene as it is
    # now — after every frame handler ran. Looking each changed name up with
    # `scene.objects.get` walks the scene each time: with every object keyed
    # that cost 154 of a frame change's 212 ms at 3,000 objects in desktop
    # 5.2.1 (cProfile), 28.8 ms a frame at 1,000.
    present = {obj.name: obj for obj in scene.objects} if changed else {}
    try:
        for name, (transform, geometry) in changed.items():
            obj = present.get(name)
            if obj is None:
                # Deleted since the last pass, by a frame handler: the screen
                # still draws it, and only a whole mirror takes it off. A name
                # the last pass never saw — an object a collection instance
                # brings in, which the depsgraph evaluates and the scene does
                # not list — is not a reason to ask for one every frame.
                if name in _hidden:
                    rebuild = True
                continue
            hidden = _is_hidden(obj)
            if _hidden.get(name, hidden) != hidden:
                rebuild = True
                continue
            if transform:
                matrix = [value for row in obj.matrix_world for value in row]
                names.append(name)
                matrices.extend(matrix)
                # Object ▸ Apply reads the object's own channels, which a keyed
                # location, rotation or scale moves with the playhead too.
                _blenderkit_sync().push_local(obj)
            if geometry and not hidden and obj.type in _DRAWN:
                if depsgraph is None:
                    depsgraph = bpy.context.evaluated_depsgraph_get()
                try:
                    push_mesh(obj, depsgraph)
                except ValueError:
                    # Refused for an object the viewport does not hold yet, one
                    # added since the last pass (AnimationMirror.applyMesh).
                    # Raised from here it cost the frame — `anim_frame` was
                    # never sent (measured in 5.2.1) — where a whole mirror
                    # brings it in.
                    rebuild = True
                # A keyed shape-key value moves with the playhead, and the Data
                # tab's Value fields follow it as Blender's do: the record
                # again, uncounted (`_push_groups` keeps it from costing the
                # frame).
                if getattr(getattr(obj, 'data', None), 'shape_keys', None) is not None:
                    _blenderkit_sync()._push_groups(obj, during_pass=False)
    finally:
        # Whatever went wrong above, the timeline hears of the frame Blender is
        # on: without `anim_frame` it stops a frame behind (round 1's review),
        # and the frame's shared name index on the Swift side is only dropped
        # when it arrives (SceneMirror.frameIndex).
        _blenderkit.anim_frame(scene.frame_current, float(scene.frame_subframe),
                               '\0'.join(names).encode(), matrices.tobytes())
    return rebuild


def push_mesh(obj, depsgraph):
    """One evaluated mesh, extracted the way _blenderkit_sync.sync extracts
    every mesh — foreach_get, and the temporary mesh freed afterwards."""
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    if mesh is None:
        return
    try:
        mesh.calc_loop_triangles()
        nverts = len(mesh.vertices)
        ntris = len(mesh.loop_triangles)
        if nverts == 0 or nverts > _MAX_VERTS:
            return
        co = array('f', [0.0]) * (nverts * 3)
        mesh.vertices.foreach_get('co', co)
        normals = array('f', [0.0]) * (nverts * 3)
        mesh.vertices.foreach_get('normal', normals)
        tris = array('I', [0]) * (ntris * 3)
        mesh.loop_triangles.foreach_get('vertices', tris)
        # While editing, the faces the user hid are left out, as the mirroring
        # pass leaves them out. The evaluated mesh still carries them after a
        # frame_set (5.2.1: a Wave grid in Edit Mode with 50 of 200 faces
        # hidden kept all 200), and sent whole they were drawn again, and the
        # new topology cost the edit overlay its hidden-vertex record, until
        # the next pass (round 2's review).
        editing = getattr(obj, 'mode', '') == 'EDIT'
        if editing:
            tris = _blenderkit_sync()._unhidden_triangles(mesh, tris)
            ntris = len(tris) // 3
        if ntris:
            _blenderkit.anim_mesh(obj.name, co.tobytes(), normals.tobytes(), tris.tobytes())
            return
        # No faces: a wire circle, a curve, an edge-only mesh. Its edges are
        # what the viewport draws, as `sync` sends them. This returned early
        # here once, so a deforming wire stood still through playback while
        # Blender moved it (measured in 5.2.1: a wire circle with a Wave, 0.126
        # off at frame 9).
        edges = array('I', [0]) * (2 * len(mesh.edges))
        mesh.edges.foreach_get('vertices', edges)
        if editing:
            edges = _blenderkit_sync()._unhidden_edges(mesh, edges)
        _blenderkit.anim_mesh(obj.name, co.tobytes(), normals.tobytes(), tris.tobytes(),
                              edges.tobytes())
    finally:
        evaluated.to_mesh_clear()


# ---------------------------------------------------------------------------
# Inserting and deleting keys
# ---------------------------------------------------------------------------

_ROTATION_PATHS = {'QUATERNION': 'rotation_quaternion', 'AXIS_ANGLE': 'rotation_axis_angle'}


def rotation_path(target):
    """get_rotation_mode_path: the property a rotation key goes on."""
    return _ROTATION_PATHS.get(getattr(target, 'rotation_mode', 'XYZ'), 'rotation_euler')


def keyable_custom_properties(target):
    """get_keyable_id_property_paths: numbers, booleans, and arrays of them.
    A string property cannot be keyed and is left out."""
    paths = []
    for key in target.keys():
        try:
            value = target[key]
        except KeyError:
            continue
        if not isinstance(value, (bool, int, float)):
            items = value.to_list() if hasattr(value, 'to_list') else None
            if not items or not all(isinstance(v, (bool, int, float)) for v in items):
                continue
        paths.append('["%s"]' % bpy.utils.escape_identifier(key))
    return paths


def default_channels(target, bone=False):
    """construct_rna_paths (keyframing.cc): what I keys when no keying set is
    active — Preferences ▸ Animation ▸ Default Key Channels — each with the
    group Blender files it under."""
    channels = bpy.context.preferences.edit.key_insert_channels
    group = target.name if bone else 'Object Transforms'
    paths = []
    if 'LOCATION' in channels:
        paths.append(('location', group))
    if 'ROTATION' in channels:
        paths.append((rotation_path(target), group))
    if 'SCALE' in channels:
        paths.append(('scale', group))
    if 'ROTATE_MODE' in channels:
        paths.append(('rotation_mode', group))
    if 'CUSTOM_PROPS' in channels:
        paths.extend((path, group if bone else '') for path in keyable_custom_properties(target))
    return paths


def keying_options(scene):
    """get_keyframing_flags: what the preferences add to a key inserted by hand."""
    edit = bpy.context.preferences.edit
    options = set()
    if edit.use_keyframe_insert_needed:
        options.add('INSERTKEY_NEEDED')
    if edit.use_visual_keying:
        options.add('INSERTKEY_VISUAL')
    if scene.tool_settings.use_keyframe_cycle_aware:
        options.add('INSERTKEY_CYCLE_AWARE')
    return options


def _refuse_keying_set(scene):
    active = scene.keying_sets_all.active
    if active is not None:
        raise RuntimeError(
            "Keying set '%s' is active, and keying sets run through operators "
            "that need a window here; clear it to key the default channels"
            % active.bl_label)


def _timeline_ids(scene):
    ids = scene_ids(scene)
    for obj in scene.objects:
        if scene.show_keys_from_selected_only and not obj.select_get():
            continue
        for idblock in animated_ids(obj):
            if not any(idblock == known for known in ids):
                ids.append(idblock)
    return ids


def deselect_timeline_keys(scene):
    """ANIM_deselect_keys_in_animation_editors: inserting a key first deselects
    the keys the animation editors show, so the new ones are the selected
    ones. The timeline shows the selected objects' keys — everyone's, with
    Only Show Selected off — and the scene's."""
    for idblock in _timeline_ids(scene):
        bag = channelbag(getattr(idblock, 'animation_data', None))
        if bag is None:
            continue
        for fcurve in bag.fcurves:
            count = len(fcurve.keyframe_points)
            if count:
                zeros = array('b', [0]) * count
                for flag in ('select_control_point', 'select_left_handle', 'select_right_handle'):
                    fcurve.keyframe_points.foreach_set(flag, zeros)


def keyframe_insert():
    """I in the 3D View: `anim.keyframe_insert` with no keying set active.

    Each selected object — each selected bone, in pose mode — gets Blender's
    default channels at the current frame, in Blender's groups and with its
    interpolation. Keying a frame that already has a key replaces that key.
    Returns how many channels were keyed."""
    context = bpy.context
    scene = context.scene
    if not is_real_blender():
        return _shim_keyframe_insert()
    _refuse_keying_set(scene)
    mode = context.mode
    if mode == 'OBJECT':
        targets = [(obj, False) for obj in context.selected_objects]
    elif mode == 'POSE':
        targets = [(bone, True) for bone in (context.selected_pose_bones or ())]
    else:
        raise RuntimeError("Unsupported context mode")
    if not targets:
        raise RuntimeError("Nothing selected to key")
    frame = scene.frame_current + scene.frame_subframe
    options = keying_options(scene)
    keytype = scene.tool_settings.keyframe_type
    deselect_timeline_keys(scene)
    inserted = 0
    for target, bone in targets:
        for path, group in default_channels(target, bone):
            # A curve with no group is given no `group` at all: an empty name
            # is a name to Blender, and it files the curve under "Group".
            grouping = {'group': group} if group else {}
            try:
                if target.keyframe_insert(path, frame=frame, options=options,
                                          keytype=keytype, **grouping):
                    inserted += 1
            except (TypeError, RuntimeError):
                # Not animatable, or not editable: Blender counts it as a
                # failure and keys the rest.
                continue
    if inserted == 0:
        raise RuntimeError("No keyframes were inserted")
    return inserted


_BONE_PATH = re.compile(r'pose\.bones\["((?:[^"\\]|\\.)*)"\]')


def _can_delete_key(fcurve, obj):
    """can_delete_key (keyframing.cc): not a locked curve, and in pose mode only
    the selected bones' curves."""
    if fcurve.lock or (fcurve.group is not None and fcurve.group.lock):
        print("Warning: Not deleting keyframe for locked F-Curve '%s', object '%s'"
              % (fcurve.data_path, obj.name))
        return False
    if obj.mode == 'POSE':
        match = _BONE_PATH.search(fcurve.data_path)
        if match is None:
            return False
        bone = obj.pose.bones.get(bpy.utils.unescape_identifier(match.group(1)))
        if bone is not None and not bone.select:
            return False
    return True


def _delete_key_at(fcurve, time):
    """fcurve_delete_keyframe_at_time: the key within THRESHOLD of the frame."""
    points = fcurve.keyframe_points
    for point in points:
        if abs(point.co.x - time) <= THRESHOLD:
            points.remove(point)
            return True
    return False


def keyframe_delete_v3d():
    """Alt I in the 3D View: `anim.keyframe_delete_v3d`, done the way
    delete_key_v3d_without_keying_set does it (keyframing.cc).

    The selected objects' keys on the current frame go, from every curve of the
    object's action; a curve left with no keys goes with them. Keys on the
    object's data stay, as they do in Blender. Returns how many curves lost a
    key."""
    context = bpy.context
    scene = context.scene
    if not is_real_blender():
        return _shim_keyframe_delete()
    _refuse_keying_set(scene)
    frame = scene.frame_current + scene.frame_subframe
    objects = list(context.selected_objects)
    succeeded = 0
    removed = 0
    for obj in objects:
        animdata = obj.animation_data
        bag = channelbag(animdata)
        if bag is None:
            continue
        time = (animdata.nla_tweak_strip_time_to_scene(frame, invert=True)
                if animdata.use_tweak_mode else frame)
        modified = []
        for fcurve in bag.fcurves:
            if _can_delete_key(fcurve, obj) and _delete_key_at(fcurve, time):
                modified.append(fcurve)
        for fcurve in modified:
            if len(fcurve.keyframe_points) == 0:
                bag.fcurves.remove(fcurve)
        if modified:
            succeeded += 1
            removed += len(modified)
    if not succeeded:
        raise RuntimeError("No keyframes removed from %d object(s)" % len(objects))
    print("%d object(s) successfully had %d keyframes removed" % (succeeded, removed))
    return removed


# ---------------------------------------------------------------------------
# Auto keying
# ---------------------------------------------------------------------------

def autokey_paths(obj, mode, more_than_one, scene=None):
    """autokeyframe_object (transform_convert_object.cc): the paths auto keying
    keys after a transform. With Autokey Insert Needed on — the default — that
    is what the transform changed; with it off, all three."""
    scene = scene or bpy.context.scene
    tool = scene.tool_settings
    rotation = rotation_path(obj)
    if not bpy.context.preferences.edit.use_auto_keyframe_insert_needed:
        return ['location', rotation, 'scale']
    paths = []
    pivot = tool.transform_pivot_point
    if pivot == 'ACTIVE_ELEMENT':
        if obj != bpy.context.view_layer.objects.active:
            paths.append('location')
    elif more_than_one and pivot != 'INDIVIDUAL_ORIGINS':
        paths.append('location')
    elif pivot == 'CURSOR':
        paths.append('location')
    if mode == 'TRANSLATE':
        if 'location' not in paths:
            paths.append('location')
    elif mode in ('ROTATE', 'TRACKBALL'):
        if not tool.use_transform_pivot_point_align:
            paths.append(rotation)
    elif mode == 'RESIZE':
        if not tool.use_transform_pivot_point_align:
            paths.append('scale')
    else:
        if 'location' not in paths:
            paths.append('location')
        paths += [rotation, 'scale']
    return paths


def _has_key_at(idblock, frame):
    """id_frame_has_keyframe: any key of the data-block's action on this frame."""
    bag = channelbag(getattr(idblock, 'animation_data', None))
    if bag is None:
        return False
    return any(abs(point.co.x - frame) <= THRESHOLD
               for fcurve in bag.fcurves for point in fcurve.keyframe_points)


def after_transform(mode):
    """What auto keying adds to a transform the gizmo made, run in that
    transform's own evaluation.

    On a device Blender has already keyed, inside `bpy.ops.transform.*` —
    measured headless in 5.2.1. What it cannot do headless is say so when it
    keyed nothing because "Only Insert Available" (on by default) or Replace
    mode would not create the curves: that report goes to a window manager
    nobody sees here, and the transform looks as if auto keying were broken.
    This says it where the interface can show it.

    In the simulator the shim's transforms key nothing, so this keys for them.
    """
    try:
        if not is_real_blender():
            return _shim_after_transform(mode)
        return _report_uncreated_curves(mode)
    except Exception as error:   # never let a report undo the transform
        print("Auto keying report failed: %s" % error)
        return 0


def _report_uncreated_curves(mode):
    context = bpy.context
    scene = context.scene
    tool = scene.tool_settings
    if not tool.use_keyframe_insert_auto or context.mode != 'OBJECT':
        return 0
    only_available = context.preferences.edit.use_keyframe_insert_available
    replace = tool.auto_keying_mode == 'REPLACE_KEYS'
    if not (only_available or replace):
        return 0
    objects = list(context.selected_editable_objects)
    frame = scene.frame_current + scene.frame_subframe
    last = 0
    for obj in objects:
        if replace and not _has_key_at(obj, frame):
            # autokeyframe_cfra_can_key: Replace mode leaves this object alone.
            continue
        bag = channelbag(obj.animation_data)
        missing = 0
        for path in autokey_paths(obj, mode, len(objects) > 1, scene):
            if bag is None:
                # With nothing to key into, Blender counts the path once.
                missing += 1
            else:
                missing += sum(1 for index in range(len(getattr(obj, path)))
                               if bag.fcurves.find(path, index=index) is None)
        if missing:
            last = missing
    if last and hasattr(_blenderkit, 'anim_notice'):
        _blenderkit.anim_notice(AUTOKEY_REPORT % last)
    return last


def set_auto_keying(on=None, replace=None, only_available=None):
    """The record button and its popover. Only Insert Available is a
    preference in Blender, which on an iPad has no Preferences editor to set it
    from, so it is set here with the rest."""
    if not is_real_blender():
        state = _shim_state()
        if on is not None:
            state['autokey'] = bool(on)
        if replace is not None:
            state['replace'] = bool(replace)
        if only_available is not None:
            state['only_available'] = bool(only_available)
        _shim_apply(state)
        return
    tool = bpy.context.scene.tool_settings
    if on is not None:
        tool.use_keyframe_insert_auto = bool(on)
    if replace is not None:
        tool.auto_keying_mode = 'REPLACE_KEYS' if replace else 'ADD_REPLACE_KEYS'
    if only_available is not None:
        bpy.context.preferences.edit.use_keyframe_insert_available = bool(only_available)
    if hasattr(_blenderkit, 'anim_state'):
        report_state()


# ---------------------------------------------------------------------------
# The simulator's shim
#
# Its scene and its keys are Swift's (BKScene.animation, BKObject.animation);
# these read and write them through the bridge, so the interface's Python means
# the same thing in the simulator as on a device.
# ---------------------------------------------------------------------------

_STATE_FIELDS = ('start', 'end', 'current', 'subframe', 'fps', 'preview', 'preview_start',
                 'preview_end', 'autokey', 'replace', 'only_available', 'only_selected', 'loop')


def _shim_state():
    return dict(zip(_STATE_FIELDS, _blenderkit.anim_state_get()))


def _shim_apply(state):
    _blenderkit.anim_state(*[int(state[k]) if k not in ('subframe', 'fps') else float(state[k])
                             for k in _STATE_FIELDS])


def _shim_channels(name):
    channels = {}
    for line in _blenderkit.anim_channels(name).splitlines():
        path, _, frames = line.partition(':')
        channels[path] = [int(f) for f in frames.split(',') if f]
    return channels


def _shim_keyframe_insert():
    if bpy.context.mode != 'OBJECT':
        raise RuntimeError("Unsupported context mode")
    objects = list(bpy.context.selected_objects)
    if not objects:
        raise RuntimeError("Nothing selected to key")
    # The shim keys whole transform vectors, and has no custom properties or
    # rotation modes to key beyond them.
    for obj in objects:
        for path in ('location', 'rotation_euler', 'scale'):
            obj.keyframe_insert(path)
    return 3 * len(objects)


def _shim_keyframe_delete():
    frame = bpy.context.scene.frame_current
    objects = list(bpy.context.selected_objects)
    succeeded = removed = 0
    for obj in objects:
        here = [path for path, frames in _shim_channels(obj.name).items() if frame in frames]
        for path in here:
            obj.keyframe_delete(path)
        if here:
            succeeded += 1
            removed += len(here)
    if not succeeded:
        raise RuntimeError("No keyframes removed from %d object(s)" % len(objects))
    print("%d object(s) successfully had %d keyframes removed" % (succeeded, removed))
    return removed


def _shim_after_transform(mode):
    state = _shim_state()
    if not state['autokey'] or bpy.context.mode != 'OBJECT':
        return 0
    frame = bpy.context.scene.frame_current
    objects = list(bpy.context.selected_objects)
    last = 0
    for obj in objects:
        channels = _shim_channels(obj.name)
        if state['replace'] and not any(frame in frames for frames in channels.values()):
            continue
        # Blender's defaults: Autokey Insert Needed, the median point pivot.
        paths = ['location'] if mode == 'TRANSLATE' or len(objects) > 1 else []
        if mode == 'ROTATE':
            paths.append('rotation_euler')
        elif mode == 'RESIZE':
            paths.append('scale')
        missing = 0
        for path in paths:
            if (state['only_available'] or state['replace']) and path not in channels:
                missing += 3 if channels else 1
                continue
            obj.keyframe_insert(path)
        if missing:
            last = missing
    if last:
        _blenderkit.anim_notice(AUTOKEY_REPORT % last)
    return last
