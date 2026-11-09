"""Render Animation, and what the Properties editor's Render, Output and World
tabs read and write (RenderSettings.swift, RenderPropertiesTabs.swift).

A render leaves the scene as it found it. Blender's F12 and Ctrl+F12 change no
setting and record no undo step; the Render panel used to set the engine, the
size, the samples, the file format and the output path for its render and
leave them so (the user's scene still had `filepath` set to a render of
September 21). `save` and `restore` bracket every render the panel runs: what
it sets for itself is put back in its `finally`, the media type before the
file format before the colour, because each resets the next (measured in
5.2.1: Media Type ▸ Video sets FFmpeg, Matroska, H.264 and RGB).

Render Animation is Blender's own `render.render(animation=True)`: its frame
loop, its image writers and its FFmpeg writer (the iOS build encodes H.264 and
H.265 through VideoToolbox; measured in the app, a 3-frame 64 x 36 render made
an MP4 that ffprobe reads as High-profile H.264, 3 frames, 24 fps, and that
AVFoundation plays). One call cannot be stopped headless — Escape sets
`G.is_break`, and there is no Escape — so Cancel is a file the panel writes:
the `render_post` handler sees it after a frame is saved and moves
`frame_current` to the end frame, and `RE_RenderAnim`'s loop, which counts on
`scene->r.cfra` and ends past `efra`, stops there (pipeline.cc), closes the
video and puts the frame back. Measured in desktop 5.2.1 and in the app: a
cancel after frame 2 of 10 left a valid 2-frame H.264 file and the frame where
it was.
"""

import json
import os

import bpy

# ---------------------------------------------------------------------------
# Reading the settings


def _choices(owner, prop):
    """A dynamic enum's items as (identifier, name): the identifiers Blender
    lists when it refuses a value (the view transforms and looks come from
    the OpenColorIO config, the engines from what is registered), the names
    as Blender's menus draw them (`UILayout.enum_item_name`: a look's
    'AgX - Punchy' is drawn "Punchy")."""
    identifiers = []
    try:
        setattr(owner, prop, '\x01')
    except TypeError as error:
        # 'enum "\x01" not found in ('AgX', 'Filmic', …)'
        text = str(error)
        start, end = text.find("not found in ("), text.rfind(')')
        if 0 <= start < end:
            body = text[start + len("not found in ("):end].strip()
            for part in body.split("', '"):
                part = part.strip().strip(',').strip().strip("'")
                if part:
                    identifiers.append(part)
    except Exception:                               # noqa: BLE001 - a read never raises
        pass
    if not identifiers:
        try:
            identifiers = [item.identifier for item in owner.bl_rna.properties[prop].enum_items]
        except Exception:                           # noqa: BLE001
            identifiers = []
    out = []
    for identifier in identifiers:
        try:
            name = bpy.types.UILayout.enum_item_name(owner, prop, identifier) or identifier
        except Exception:                           # noqa: BLE001
            name = identifier
        out.append([identifier, name])
    return out


def _number(value):
    value = float(value)
    return value if value == value and abs(value) != float('inf') else 0.0


def output_untouched(scene):
    """Whether the scene's Output is still Blender's factory one: Media Type
    Image, PNG, and FFmpeg's settings never chosen (MPEG-1 with no codec,
    what 5.2.1 and the app's 5.3 start with). Render Animation makes an
    MPEG-4 video of such a scene for that render — the app's default — and
    once a format is chosen in the Output tab it renders what was chosen.
    The output path is not part of it: the panel's renders before this one
    left it set to their file."""
    r = scene.render
    im, ff = r.image_settings, r.ffmpeg
    return (getattr(im, 'media_type', 'IMAGE') == 'IMAGE' and im.file_format == 'PNG'
            and ff.format == 'MPEG1' and ff.codec == 'NONE')


def world_state(scene):
    """The World tab's Surface: the node on the World Output's Surface and,
    when it is a Background, its Color and Strength."""
    world = scene.world
    if world is None:
        return None
    state = {'name': world.name, 'use_nodes': bool(getattr(world, 'use_nodes', True)),
             'node': None, 'background': False, 'color': [_number(c) for c in world.color[:3]],
             'strength': 1.0, 'color_linked': None, 'strength_linked': None}
    tree = world.node_tree
    if tree is None or not state['use_nodes']:
        return state
    output = None
    try:
        output = tree.get_output_node('ALL')
    except Exception:                               # noqa: BLE001
        output = None
    output = output or next((n for n in tree.nodes if n.bl_idname == 'ShaderNodeOutputWorld'), None)
    if output is None:
        return state
    surface = output.inputs.get('Surface')
    if surface is None or not surface.is_linked:
        return state
    node = surface.links[0].from_node
    state['node'] = node.name
    state['node_label'] = node.bl_label
    if node.bl_idname == 'ShaderNodeBackground':
        state['background'] = True
        color, strength = node.inputs['Color'], node.inputs['Strength']
        state['color'] = [_number(c) for c in color.default_value[:3]]
        state['strength'] = _number(strength.default_value)
        if color.is_linked:
            state['color_linked'] = color.links[0].from_node.name
        if strength.is_linked:
            state['strength_linked'] = strength.links[0].from_node.name
    return state


def settings():
    """Everything the Render, Output and World tabs and the Render panel show,
    as one JSON line."""
    scene = bpy.context.scene
    r = scene.render
    im, ff = r.image_settings, r.ffmpeg
    out = {
        'engine': r.engine,
        'engines': _choices(r, 'engine'),
        'resolution_x': r.resolution_x, 'resolution_y': r.resolution_y,
        'resolution_percentage': r.resolution_percentage,
        'fps': r.fps, 'fps_base': _number(r.fps_base),
        'frame_start': scene.frame_start, 'frame_end': scene.frame_end, 'frame_step': scene.frame_step,
        'media_type': getattr(im, 'media_type', 'IMAGE'),
        'file_format': im.file_format,
        'color_mode': im.color_mode, 'color_modes': _choices(im, 'color_mode'),
        'color_depth': im.color_depth, 'color_depths': _choices(im, 'color_depth'),
        'quality': im.quality, 'compression': im.compression,
        'exr_codec': getattr(im, 'exr_codec', ''),
        'ffmpeg_format': ff.format, 'ffmpeg_codec': ff.codec,
        'ffmpeg_crf': ff.constant_rate_factor, 'ffmpeg_preset': ff.ffmpeg_preset,
        'is_movie': bool(r.is_movie_format),
        'output_untouched': output_untouched(scene),
        'film_transparent': bool(r.film_transparent),
        'use_motion_blur': bool(r.use_motion_blur),
        'has_camera': scene.camera is not None,
        'ffmpeg_available': bool(getattr(bpy.app.build_options, 'codec_ffmpeg', False)),
    }
    cycles = getattr(scene, 'cycles', None)
    if cycles is not None:
        out['cycles'] = {
            'device': cycles.device, 'samples': cycles.samples,
            'use_adaptive_sampling': bool(cycles.use_adaptive_sampling),
            'adaptive_threshold': _number(cycles.adaptive_threshold),
            'time_limit': _number(cycles.time_limit),
            'use_denoising': bool(cycles.use_denoising), 'denoiser': cycles.denoiser,
            'denoisers': _choices(cycles, 'denoiser'),
            'max_bounces': cycles.max_bounces,
        }
    eevee = getattr(scene, 'eevee', None)
    if eevee is not None:
        out['eevee'] = {
            'taa_render_samples': eevee.taa_render_samples, 'taa_samples': eevee.taa_samples,
            'use_raytracing': bool(eevee.use_raytracing), 'use_shadows': bool(getattr(eevee, 'use_shadows', True)),
            'shadow_ray_count': getattr(eevee, 'shadow_ray_count', 1),
            'shadow_step_count': getattr(eevee, 'shadow_step_count', 6),
        }
    shading = scene.display.shading
    out['workbench'] = {
        'light': shading.light, 'color_type': shading.color_type,
        'single_color': [_number(c) for c in shading.single_color[:3]],
        'render_aa': scene.display.render_aa,
    }
    view, display = scene.view_settings, scene.display_settings
    out['color'] = {
        'display_device': display.display_device, 'display_devices': _choices(display, 'display_device'),
        'view_transform': view.view_transform, 'view_transforms': _choices(view, 'view_transform'),
        'look': view.look, 'looks': _choices(view, 'look'),
        'exposure': _number(view.exposure), 'gamma': _number(view.gamma),
    }
    out['world'] = world_state(scene)
    return json.dumps(out)


# ---------------------------------------------------------------------------
# Writing the settings that are more than one assignment


# The containers AVKit plays, so the Render panel can show the video.
PLAYABLE_CONTAINERS = ('MPEG4', 'QUICKTIME')


def set_file_format(choice):
    """Output ▸ File Format, as the app offers it: an image format, or
    'FFMPEG' (FFmpeg Video). In 5.x a video format needs Media Type ▸ Video
    first (`file_format = 'FFMPEG'` is refused while the media type is
    Image). Video starts in MPEG-4 with H.264 where Blender's own switch
    starts Matroska — a container AVKit cannot play in the Render panel —
    and keeps a container the user chose that it can. Choosing an image
    format on a scene whose Output was never chosen sets FFmpeg's container
    and codec too, so the scene no longer reads as untouched and Render
    Animation renders the frames it was asked for."""
    scene = bpy.context.scene
    r = scene.render
    im, ff = r.image_settings, r.ffmpeg
    if choice == 'FFMPEG':
        im.media_type = 'VIDEO'
        im.file_format = 'FFMPEG'
        if ff.format not in PLAYABLE_CONTAINERS:
            ff.format = 'MPEG4'
        if ff.codec == 'NONE':
            ff.codec = 'H264'
        if ff.constant_rate_factor == 'NONE':
            ff.constant_rate_factor = 'MEDIUM'
        return
    untouched = output_untouched(scene)
    if getattr(im, 'media_type', 'IMAGE') != 'IMAGE':
        im.media_type = 'IMAGE'
    im.file_format = choice
    if untouched:
        ff.format, ff.codec = 'MPEG4', 'H264'


def world_new():
    """The World tab's New (`world.new`, Blender's "New World"): a world made
    the way 5.2.1 makes one — `bpy.data.worlds.new` already carries a
    Background on the World Output, colour 0.05 — given to the scene. The
    operator itself gives it to whatever the interface's World field is,
    which a Blender with no interface has not (measured: headless it adds
    World.001 and the scene keeps its own)."""
    scene = bpy.context.scene
    world = bpy.data.worlds.new("World")
    if not getattr(world, 'use_nodes', True):
        world.use_nodes = True
    _background(world)
    scene.world = world
    return world.name


def _background(world):
    """The Background node feeding the World Output's Surface, made and linked
    when there is none (use_nodes on, as Blender's Surface panel's Use Nodes
    does)."""
    if not getattr(world, 'use_nodes', True):
        world.use_nodes = True
    tree = world.node_tree
    output = None
    try:
        output = tree.get_output_node('ALL')
    except Exception:                               # noqa: BLE001
        output = None
    output = output or next((n for n in tree.nodes if n.bl_idname == 'ShaderNodeOutputWorld'), None)
    if output is None:
        output = tree.nodes.new('ShaderNodeOutputWorld')
        output.location = (300, 300)
    surface = output.inputs['Surface']
    if surface.is_linked and surface.links[0].from_node.bl_idname == 'ShaderNodeBackground':
        return surface.links[0].from_node
    if surface.is_linked:
        raise RuntimeError("The World's Surface is a %s, not a Background. Edit it in the Shading "
                           "workspace's node editor." % surface.links[0].from_node.bl_label)
    node = tree.nodes.new('ShaderNodeBackground')
    node.location = (output.location.x - 200, output.location.y)
    node.inputs['Color'].default_value[:3] = world.color[:3]
    tree.links.new(node.outputs['Background'], surface)
    return node


def world_background(color=None, strength=None):
    """The Surface panel's Color and Strength: the Background node's inputs,
    with a Background made when the World Output has none."""
    scene = bpy.context.scene
    if scene.world is None:
        raise RuntimeError("This scene has no World. Press New in the World tab.")
    node = _background(scene.world)
    if color is not None:
        node.inputs['Color'].default_value = (float(color[0]), float(color[1]), float(color[2]), 1.0)
        # The viewport's world colour (Viewport Display), as Blender keeps it
        # beside the node when there is one.
        scene.world.color = tuple(float(c) for c in color[:3])
    if strength is not None:
        node.inputs['Strength'].default_value = float(strength)


# ---------------------------------------------------------------------------
# A render leaves the scene as it found it


def _owner(scene, name):
    if name == 'scene':
        return scene
    if name == 'render':
        return scene.render
    if name == 'image_settings':
        return scene.render.image_settings
    if name == 'ffmpeg':
        return scene.render.ffmpeg
    return getattr(scene, name, None)


# Everything a render from the Render panel sets for itself, in the order it
# is put back: the media type first, then the format, then the colour, since
# each resets the next.
SAVED = (
    ('render', 'engine'), ('render', 'resolution_x'), ('render', 'resolution_y'),
    ('render', 'resolution_percentage'), ('render', 'filepath'), ('render', 'use_file_extension'),
    ('image_settings', 'media_type'), ('image_settings', 'file_format'),
    ('image_settings', 'color_mode'), ('image_settings', 'color_depth'),
    ('ffmpeg', 'format'), ('ffmpeg', 'codec'), ('ffmpeg', 'constant_rate_factor'),
    ('ffmpeg', 'ffmpeg_preset'),
    ('cycles', 'samples'), ('cycles', 'use_adaptive_sampling'), ('cycles', 'device'),
    ('eevee', 'taa_render_samples'), ('eevee', 'shadow_pool_size'),
    ('scene', 'frame_start'), ('scene', 'frame_end'), ('scene', 'frame_step'),
    ('scene', 'frame_current'),
)


def save(scene):
    saved = []
    for owner, key in SAVED:
        target = _owner(scene, owner)
        if target is not None and hasattr(target, key):
            saved.append((owner, key, getattr(target, key)))
    return saved


def restore(scene, saved):
    """Puts back what `save` read, each value only where it changed — the
    frame through `frame_set`, so the scene is evaluated there again."""
    for owner, key, value in saved:
        target = _owner(scene, owner)
        try:
            if getattr(target, key) == value:
                continue
            if owner == 'scene' and key == 'frame_current':
                scene.frame_set(value)
            else:
                setattr(target, key, value)
        except Exception:                           # noqa: BLE001 - one value must not stop the rest
            pass


# ---------------------------------------------------------------------------
# Render Animation


_VIDEO_EXTENSIONS = {'MPEG4': '.mp4', 'QUICKTIME': '.mov', 'MKV': '.mkv', 'WEBM': '.webm',
                     'AVI': '.avi', 'OGG': '.ogv', 'FLASH': '.flv', 'DV': '.dv',
                     'MPEG1': '.mpg', 'MPEG2': '.dvd'}


def frame_count(scene):
    return len(range(scene.frame_start, scene.frame_end + 1, max(scene.frame_step, 1)))


def _write(path, text):
    if not path:
        return
    try:
        with open(path, 'w') as f:
            f.write(text)
    except Exception:                               # noqa: BLE001 - a report must never stop a render
        pass


def render_animation(base, video=False, frames=None, cancel=None, result=None):
    """Blender's Render Animation into `base` (a path without extension):
    `base` + the container's extension for a video format, the folder `base`
    of numbered frames (Blender's own 0001.png …) for an image format.

    `video`: render an MPEG-4 H.264 video whatever the Output says — the app's
    default while the scene's Output is untouched (`output_untouched`); the
    settings are the caller's to put back (`save`/`restore`).
    `frames`: a file the frame being rendered is written to, "index total
    frame", for the panel's "Frame 12 of 250".
    `cancel`: a file whose existence stops the render after the frame being
    rendered (see the module's note).
    `result`: a file the outcome is written to as JSON — what was written,
    how many frames, whether it was cancelled.

    Called as `_blenderkit_render.render_animation(…)`, which a script's text
    shows as containing "render.render": the session starts Blender's GPU
    module on the main thread first and arms the first-Cycles-render warning
    for such a script (`ScriptThread.mayStartGPU`, `CyclesKernels.mayRender`),
    as it does for the still render's `bpy.ops.render.render`."""
    scene = bpy.context.scene
    r = scene.render
    im, ff = r.image_settings, r.ffmpeg
    if scene.camera is None:
        raise RuntimeError("This scene has no camera. Add ▸ Camera, then Render Animation.")
    if video:
        im.media_type = 'VIDEO'
        im.file_format = 'FFMPEG'
        ff.format = 'MPEG4'
        ff.codec = 'H264'
        ff.constant_rate_factor = 'MEDIUM'
        ff.ffmpeg_preset = 'GOOD'
        im.color_mode = 'RGB'
    r.use_file_extension = True
    if r.is_movie_format:
        extension = _VIDEO_EXTENSIONS.get(ff.format, '.mp4')
        r.filepath = base + extension
        path = r.frame_path(frame=scene.frame_start)
        kind = 'video'
    else:
        os.makedirs(base, exist_ok=True)
        r.filepath = os.path.join(base, '')
        path = base
        kind = 'images'
    existed = os.path.exists(path)
    total = frame_count(scene)
    step = max(scene.frame_step, 1)
    state = {'done': 0, 'cancelled': False, 'last': None}

    def _bk_anim_pre(render_scene, *_):
        index = (render_scene.frame_current - scene.frame_start) // step + 1
        _write(frames, "%d %d %d" % (index, total, render_scene.frame_current))

    def _bk_anim_post(render_scene, *_):
        state['done'] += 1
        if kind == 'images':
            state['last'] = render_scene.render.frame_path(frame=render_scene.frame_current)
        if cancel and os.path.exists(cancel) and not state['cancelled']:
            state['cancelled'] = True
            # RE_RenderAnim counts on scene->r.cfra: past the end frame its
            # loop ends, the video is closed and the frame put back.
            render_scene.frame_current = render_scene.frame_end

    handlers = ((bpy.app.handlers.render_pre, _bk_anim_pre), (bpy.app.handlers.render_post, _bk_anim_post))
    for collection, function in handlers:
        collection.append(function)
    error = None
    try:
        bpy.ops.render.render(animation=True)
    except Exception as failure:                    # noqa: BLE001 - said in the result, then raised
        error = failure
        raise
    finally:
        for collection, function in handlers:
            if function in collection:
                collection.remove(function)
        # A video Blender opened and never wrote a frame into (a render that
        # failed on its first frame) is a stub no player opens: measured, a
        # missing camera left a 305-byte MP4. Only a file this render made.
        if kind == 'video' and state['done'] == 0 and not existed and os.path.exists(path):
            try:
                os.remove(path)
            except Exception:                       # noqa: BLE001
                pass
        _write(result, json.dumps({
            'kind': kind, 'path': path, 'frames': state['done'], 'total': total,
            'cancelled': state['cancelled'], 'last': state['last'],
            'error': None if error is None else str(error).strip(),
            'fps': r.fps / (r.fps_base or 1.0),
        }))
    return path
