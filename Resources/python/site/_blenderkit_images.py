"""Add ▸ Image ▸ Reference and Background, and the picture an image empty
draws (round 4, group 8).

Measured in desktop Blender 5.2.1 with the app's context:

  * `object.empty_image_add` polls for a 3D View region (`object_image_add_poll`
    is `CTX_wm_region_view3d`): the Operator Search's context (window and
    screen, no area) refuses it, and under the borrowed 3D View
    (`_blenderkit_context.temp_override_view3d`) it adds an IMAGE empty with
    the picture as its data, Size 5. It runs in Object Mode only ("Image
    objects can only be added in Object Mode", object_add.cc).
  * Background sets Depth to Back and Side to Front, and — when the view is
    not a perspective one — hides the image in perspective views
    (`rv3d->persp != RV3D_PERSP`). The borrowed view is always perspective, so
    the app's own view decides that here, as Blender's would.
  * Blender's menu adds the image facing the view (`align='VIEW'` in the
    operator's invoke). The borrowed view is not the app's, so the app's view
    rotation is passed with `align='WORLD'`, as Add ▸ Camera does.
  * A file that is not an image is still added, with an image that has no
    data (size 0 × 0): Blender's own behaviour, and the frame is drawn
    without a picture. A path that does not exist is refused by Blender
    ("Cannot read Image …: No such file or directory").

The picture is packed into the .blend (`Image.pack`, measured to keep the
PNG's bytes), so the autosave and a saved file carry it, whatever happens to
the file the picker handed over.

What Blender is handed (round 4's review of this group):

  * PNG or JPEG, and nothing else. Measured in 5.2.1: a HEIC — what Photos
    gives for a camera's picture on an iPad or iPhone — is "unknown
    file-format", 0 × 0, and only its frame is drawn. The app converts what
    Photos and Files give before Blender sees it (`ReferenceImages.prepare`
    in TextAndImages.swift), and `add` refuses anything else in words.
  * Its pixels the right way up. Blender ignores a JPEG's EXIF orientation:
    a 64 × 32 picture tagged to turn a quarter loads as 64 × 32, unturned.
    The conversion turns the pixels themselves, so what Blender holds is the
    picture as Photos shows it, and the viewport draws the file as Blender
    reads it, its tag ignored (`ReferenceImages.viewportImage`).
  * At most `MAX_PIXEL_BYTES` decoded. Blender decodes the whole picture
    when its size is first asked for: a 6,000 × 6,000 PNG of 644 KB took
    Blender from 310 to 522 MB, and a 16-bit PNG decodes to floats, four
    times that per pixel. The conversion scales a picture to 4,096 pixels on
    its longer side; `add` refuses a bigger one, and the record reads the
    size from the file's own header (`picture_size`) instead of asking
    Blender, which would decode it.
"""

import hashlib
import os
import struct
import tempfile

import bpy

# The most a picture may decode to in Blender: 4,096 × 4,096 at 8 bits a
# channel (Blender's byte buffer, 4 bytes a pixel), what the conversion
# scales Photos' and Files' pictures to. A 16-bit PNG decodes to floats,
# 16 bytes a pixel.
MAX_SIDE = 4096
MAX_PIXEL_BYTES = MAX_SIDE * MAX_SIDE * 4
_JPEG_FRAMES = frozenset((0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF))


def picture_size(path):
    """(width, height, bits per channel, 'PNG' or 'JPEG') from the file's own
    header, without decoding it; None for a file that is neither, or that
    cannot be read. A JPEG's width and height are its stored pixels', as
    Blender reads them, its EXIF orientation aside."""
    try:
        with open(path, 'rb') as handle:
            head = handle.read(26)
            if head[:8] == b'\x89PNG\r\n\x1a\n' and head[12:16] == b'IHDR' and len(head) >= 25:
                width, height = struct.unpack('>II', head[16:24])
                return (width, height, head[24], 'PNG')
            if head[:2] != b'\xff\xd8':
                return None
            handle.seek(2)
            for _ in range(4096):
                byte = handle.read(1)
                if byte != b'\xff':
                    return None
                marker = handle.read(1)
                while marker == b'\xff':
                    marker = handle.read(1)
                if not marker:
                    return None
                code = marker[0]
                if code == 0x01 or 0xD0 <= code <= 0xD8:
                    continue  # no length
                if code in (0xD9, 0xDA):
                    return None  # the end, or the pixels, before any frame header
                length = handle.read(2)
                if len(length) < 2:
                    return None
                size = struct.unpack('>H', length)[0]
                if code in _JPEG_FRAMES:
                    frame = handle.read(5)
                    if len(frame) < 5:
                        return None
                    precision, height, width = frame[0], *struct.unpack('>HH', frame[1:5])
                    return (width, height, precision, 'JPEG')
                handle.seek(size - 2, 1)
    except (OSError, struct.error, ValueError):
        return None
    return None


def refuse_picture(path, what):
    """Raises, in words, for a file Blender should not be handed: not a PNG or
    a JPEG, empty, or bigger than `MAX_PIXEL_BYTES` decoded. Returns
    (width, height) otherwise."""
    size = picture_size(path)
    name = os.path.basename(path)
    if size is None:
        raise RuntimeError("%s: %s is not a PNG or a JPEG. The app hands Blender those two, converted "
                           "from what Photos and Files give, since Blender reads no HEIC." % (what, name))
    width, height, bits, kind = size
    if width <= 0 or height <= 0:
        raise RuntimeError("%s: %s has no pixels." % (what, name))
    per_pixel = 16 if bits > 8 else 4
    need = width * height * per_pixel
    if need > MAX_PIXEL_BYTES:
        raise RuntimeError(
            "%s: %s is %d × %d pixels%s, which Blender decodes whole, to about %d MB. This app "
            "takes pictures up to %d MB decoded (%d × %d at 8 bits); the app scales what Photos and "
            "Files give to that." % (what, name, width, height, " at %d bits" % bits if bits > 8 else "",
                                     need // 1_000_000, MAX_PIXEL_BYTES // 1_000_000, MAX_SIDE, MAX_SIDE))
    return width, height


def add(filepath, background, location, rotation, orthographic):
    """Adds the image at `filepath` as Blender's Add ▸ Image row does, at
    `location` facing `rotation` (the app's view), and returns the new
    object's name."""
    import _blenderkit_context
    what = "Background" if background else "Reference"
    obj = bpy.context.view_layer.objects.active
    if obj is not None and obj.mode != 'OBJECT':
        raise RuntimeError("Image objects can only be added in Object Mode, and Blender is in "
                           + obj.mode.replace('_', ' ').title() + " Mode.")
    if not os.path.isfile(filepath):
        raise RuntimeError("%s: %s is not there to read." % (what, os.path.basename(filepath)))
    refuse_picture(filepath, what)
    with _blenderkit_context.temp_override_view3d(what):
        result = bpy.ops.object.empty_image_add(
            filepath=filepath, relative_path=False, align='WORLD',
            location=tuple(location), rotation=tuple(rotation), background=bool(background))
    if 'FINISHED' not in result:
        raise RuntimeError("Blender did not add the image (%s)." % ', '.join(sorted(result)))
    added = bpy.context.view_layer.objects.active
    if added is None or added.type != 'EMPTY' or added.empty_display_type != 'IMAGE':
        raise RuntimeError("Blender did not add an image empty.")
    if background and orthographic:
        added.show_empty_image_perspective = False
    _pack(added.data)
    return added.name


def _pack(image):
    # Not `has_data`: Blender loads an image lazily and it reads False until
    # something asks for the pixels; `pack` reads the file's bytes itself.
    if image is not None and image.packed_file is None:
        try:
            image.pack()
        except RuntimeError as error:
            print("[Blender Local] %s could not be packed: %s" % (image.name, error))


# Blender's undo step for Mesh Plane...: its operator's name.
PLANE_UNDO = "Import Images as Planes"


def add_plane(filepath):
    """Add ▸ Image ▸ Mesh Plane...: Blender's `image.import_as_mesh_planes`
    on the picture at `filepath`, with its defaults, and returns the new
    plane's name. The picture is packed, as Reference... packs it.

    Measured in desktop 5.2.1 with the app's context: a core operator
    (bl_operators/image_as_planes.py, in the app's bundled bpy too), which
    polls True with the window and screen alone and under the borrowed 3D
    View, and adds a 2 × 1 plane for a 64 × 32 picture at the 3D cursor
    (under the borrowed view; at the origin without it), with a material
    named after the file whose Image Texture is the picture. Facing: its
    default, the scene camera's main axis, or +Z without a camera. From Edit
    Mode it takes the object to Object Mode itself. A file that is not there
    is CANCELLED, "Please select at least one image". It writes and puts
    back the Preferences' Enter Edit Mode while it runs. Undo and Redo take
    the plane away and back. It asks for the picture's size, which decodes
    it (`refuse_picture` first)."""
    import _blenderkit_context
    what = "Mesh Plane"
    if not os.path.isfile(filepath):
        raise RuntimeError("%s: %s is not there to read." % (what, os.path.basename(filepath)))
    refuse_picture(filepath, what)
    before = set(bpy.data.objects)
    with _blenderkit_context.temp_override_view3d(what):
        result = bpy.ops.image.import_as_mesh_planes(
            files=[{'name': os.path.basename(filepath)}], directory=os.path.dirname(filepath))
    if 'FINISHED' not in result:
        raise RuntimeError("Blender did not add the plane (%s)." % ', '.join(sorted(result)))
    added = [obj for obj in bpy.data.objects if obj not in before]
    if not added:
        raise RuntimeError("Blender did not add a plane.")
    plane = added[0]
    for slot in plane.material_slots:
        material = slot.material
        if material is None or material.node_tree is None:
            continue
        for node in material.node_tree.nodes:
            if node.type == 'TEX_IMAGE':
                _pack(node.image)
    return plane.name


_CACHE = os.path.join(tempfile.gettempdir(), 'blenderlocal-images')
_WRITTEN = {}


def image_file(image):
    """A file the viewport can read `image`'s picture from: its own file when
    that is there, else its packed bytes written once to a cache. '' when
    there is neither (a generated or missing image), and the frame is drawn
    without a picture."""
    if image is None:
        return ''
    packed = image.packed_file
    if packed is not None:
        key = (image.name, packed.size)
        path = _WRITTEN.get(key)
        if path is not None and os.path.isfile(path):
            return path
        data = packed.data
        digest = hashlib.sha1(data).hexdigest()[:16]
        extension = os.path.splitext(image.filepath)[1].lower() or '.png'
        os.makedirs(_CACHE, exist_ok=True)
        path = os.path.join(_CACHE, digest + extension)
        if not os.path.isfile(path):
            with open(path, 'wb') as handle:
                handle.write(data)
        _WRITTEN[key] = path
        return path
    try:
        path = bpy.path.abspath(image.filepath_from_user())
    except (AttributeError, TypeError, ValueError):
        path = image.filepath
    return path if path and os.path.isfile(path) else ''


def picture_dimensions(image, path=None):
    """`image`'s width and height in pixels as Blender reads them: from its
    file's header (`picture_size`) for a PNG or a JPEG, which decodes
    nothing, else from Blender (`Image.size`), which decodes it. Round 4's
    review measured `Image.size` decoding the whole picture — 212 MB for a
    6,000 × 6,000 PNG — where its comment here said it read the header."""
    if image is None:
        return (0, 0)
    if path is None:
        path = image_file(image)
    size = picture_size(path) if path else None
    if size is not None:
        return (size[0], size[1])
    return (int(image.size[0]), int(image.size[1]))


def record_values(obj):
    """What an image empty's record adds for the picture (`_display_record`):
    the file, Blender's settings that decide when and how it is drawn, and
    whether the image holds data at all."""
    image = obj.data
    path = image_file(image) if image is not None else ''
    width, height = picture_dimensions(image, path)
    values = [('image_name', image.name if image is not None else ''),
              ('image_file', path),
              # Measured: 64 x 32 right after the add, 0 x 0 for a file that
              # is not an image, whose frame Blender draws without a picture.
              ('image_has_data', bool(width > 0 and height > 0)),
              ('image_premultiplied', bool(image is not None and image.alpha_mode == 'PREMUL')),
              ('empty_image_depth', obj.empty_image_depth),
              ('empty_image_side', obj.empty_image_side),
              ('show_empty_image_orthographic', obj.show_empty_image_orthographic),
              ('show_empty_image_perspective', obj.show_empty_image_perspective),
              ('show_empty_image_only_axis_aligned', obj.show_empty_image_only_axis_aligned),
              ('use_empty_image_alpha', obj.use_empty_image_alpha),
              ('color', tuple(obj.color)),
              ('show_in_front', obj.show_in_front)]
    return values


# The Empty panel's image rows (properties_data_empty.py), by property name,
# and the values each takes.
SETTINGS = {
    'empty_image_depth': ('DEFAULT', 'FRONT', 'BACK'),
    'empty_image_side': ('DOUBLE_SIDED', 'FRONT', 'BACK'),
    'show_empty_image_orthographic': None,
    'show_empty_image_perspective': None,
    'show_empty_image_only_axis_aligned': None,
    'use_empty_image_alpha': None,
    'empty_image_offset_x': None,
    'empty_image_offset_y': None,
    'opacity': None,
}


def set_setting(name, key, value):
    """One of the Empty panel's image rows on the empty `name`."""
    obj = bpy.data.objects.get(name)
    if obj is None or obj.type != 'EMPTY':
        raise RuntimeError("%r is not an empty." % (name,))
    if key not in SETTINGS:
        raise RuntimeError("The Empty panel has no image setting %r" % (key,))
    choices = SETTINGS[key]
    if choices is not None and value not in choices:
        raise RuntimeError("%s takes %s, not %r" % (key, ', '.join(choices), value))
    if key == 'opacity':
        # The slider beside Opacity's checkbox is the object colour's alpha.
        obj.color[3] = min(max(float(value), 0.0), 1.0)
        return obj.color[3]
    if key in ('empty_image_offset_x', 'empty_image_offset_y'):
        obj.empty_image_offset[0 if key.endswith('x') else 1] = float(value)
        return tuple(obj.empty_image_offset)
    setattr(obj, key, value)
    return getattr(obj, key)
