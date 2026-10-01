"""Cameras, lights and empties, for the simulator's `bpy` shim.

On a device Blender makes these, and `_blenderkit_sync` hands the viewport the
settings it draws them from. Here the shim makes them, through
`_blenderkit.add_object`, and keeps each one's settings on the app's side in
that same record (`_blenderkit_sync._display_record`, ObjectDisplay.swift), so
the viewport draws from one thing wherever it runs.

The defaults are Blender 5.2.1's, measured: what `camera_add`, `light_add` and
`empty_add` leave on a new object, and what `bpy.data.cameras.new` and
`bpy.data.lights.new` start with. tests/camlight/shim holds the shim to the
records Blender itself mirrors for the same script.

`bpy/__init__.py` imports this once its classes exist; everything below is
installed onto them at the end. `Object.type`, `Object.data` and
`bpy.data.objects.new` are wrapped rather than replaced, so what
`bpy/__init__.py` answers for a mesh still answers for a mesh.
"""

import math

import _blenderkit as _bk

from . import Object, _Data, _ObjectOps, _Objects, _Scene, types

# Blender's properties and their defaults, in Blender's order.
_CAMERA = (
    ("type", "PERSP"), ("lens", 50.0), ("sensor_fit", "AUTO"), ("sensor_width", 36.0),
    ("sensor_height", 24.0), ("ortho_scale", 6.0), ("clip_start", 0.1), ("clip_end", 1000.0),
    ("shift_x", 0.0), ("shift_y", 0.0), ("display_size", 1.0), ("show_limits", False),
)
_LIGHT = (
    ("type", "POINT"), ("color", (1.0, 1.0, 1.0)), ("energy", 10.0),
    ("shadow_soft_size", 0.0), ("cutoff_distance", 40.0), ("shadow_buffer_clip_start", 0.05),
)
_SPOT = (("spot_size", math.radians(45.0)), ("spot_blend", 0.15), ("show_cone", False))
_AREA = (("shape", "SQUARE"), ("size", 0.25), ("size_y", 0.25))
_EMPTY = (("empty_display_type", "PLAIN_AXES"), ("empty_display_size", 1.0),
          ("empty_image_offset", (-0.5, -0.5)))

_ENUMS = {
    ("CAMERA", "type"): ("PERSP", "ORTHO", "PANO"),
    ("CAMERA", "sensor_fit"): ("AUTO", "HORIZONTAL", "VERTICAL"),
    ("LIGHT", "type"): ("POINT", "SUN", "SPOT", "AREA"),
    ("LIGHT", "shape"): ("SQUARE", "RECTANGLE", "DISK", "ELLIPSE"),
    ("EMPTY", "empty_display_type"): ("PLAIN_AXES", "ARROWS", "SINGLE_ARROW", "CIRCLE",
                                      "CUBE", "SPHERE", "CONE", "IMAGE"),
}

# The scene's resolution, which is also the shape of every camera's frame.
_RENDER = {"resolution_x": 1920, "resolution_y": 1080, "resolution_percentage": 100,
           "pixel_aspect_x": 1.0, "pixel_aspect_y": 1.0}


# ---------------------------------------------------------------------------
# The record


def _text(value):
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return repr(float(value))
    if isinstance(value, str):
        return value
    return ",".join(repr(float(c)) for c in value)


def _format(values):
    return ";".join(key + "=" + _text(value) for key, value in values.items())


def _parse(record):
    values = {}
    for pair in record.split(";"):
        key, sep, value = pair.partition("=")
        if sep:
            values[key] = value
    return values


def _typed(default, text):
    """A record's text as the type of the property's default."""
    if text is None:
        return default
    try:
        if isinstance(default, bool):
            return text in ("1", "True", "true")
        if isinstance(default, float):
            return float(text)
        if isinstance(default, tuple):
            return tuple(float(c) for c in text.split(","))
    except ValueError:
        return default
    return text


def _check(kind, key, value):
    allowed = _ENUMS.get((kind, key))
    if allowed is not None and value not in allowed:
        raise TypeError('bpy_struct: item.attr = val: enum "%s" not found in %s' % (value, allowed))


def _converted(default, value):
    if isinstance(default, bool):
        return bool(value)
    if isinstance(default, float):
        return float(value)
    if isinstance(default, tuple):
        return tuple(float(c) for c in value)[:len(default)]
    return value


def _display(name):
    """(type, data-block name, values as text) for a camera, light or empty;
    None for anything else, including a name the scene does not have."""
    try:
        found = _bk.object_display(name)
    except KeyError:
        return None
    if found is None:
        return None
    return found[0], found[1], _parse(found[2])


def _store(name, data_name, values):
    _bk.set_object_display(name, data_name, _format(values))


def _render_aspect():
    return {"aspect_x": _RENDER["resolution_x"] * _RENDER["pixel_aspect_x"],
            "aspect_y": _RENDER["resolution_y"] * _RENDER["pixel_aspect_y"]}


# ---------------------------------------------------------------------------
# Object.type and Object.data

_mesh_type = Object.type
_mesh_data = Object.data


def display_type(name):
    """CAMERA, LIGHT or EMPTY for those, and None for anything else."""
    found = _display(name)
    return found[0] if found is not None else None


def _object_type(self):
    """`Object.type`: CAMERA, LIGHT or EMPTY for those, and what it was
    before for everything else."""
    return display_type(self.name) or _mesh_type.fget(self)


def _object_data(self):
    """`Object.data`: the camera's or light's data-block, None for an empty,
    and what it was before for everything else."""
    kind = display_type(self.name)
    if kind is None:
        return _mesh_data.fget(self)
    if kind == "CAMERA":
        return CameraData(self.name)
    if kind == "LIGHT":
        return LightData(self.name)
    return None


class _DataBlock:
    """A camera or light data-block.

    Bound to the object that holds it, whose record it reads and writes; or,
    made with `bpy.data.cameras.new` and not yet given to an object, holding
    its own values until `bpy.data.objects.new` takes it.
    """

    __slots__ = ("_owner", "_name", "_values")
    _KIND = ""

    def __init__(self, owner=None, name="", values=None):
        object.__setattr__(self, "_owner", owner)
        object.__setattr__(self, "_name", name)
        object.__setattr__(self, "_values", values)

    def _state(self):
        if self._owner is None:
            return self._name, dict(self._values)
        found = _display(self._owner)
        if found is None or found[0] != self._KIND:
            raise ReferenceError("StructRNA of type %s has been removed" % self._rna({}))
        return found[1], found[2]

    def _write(self, name, values):
        if self._owner is None:
            object.__setattr__(self, "_name", name)
            object.__setattr__(self, "_values", values)
        else:
            _store(self._owner, name, values)

    @classmethod
    def _fields(cls, values):
        return {}

    @classmethod
    def _rna(cls, values):
        return cls._KIND.title()

    @property
    def name(self):
        return self._state()[0]

    @name.setter
    def name(self, value):
        _, values = self._state()
        self._write(str(value), values)

    @property
    def users(self):
        """A data-block here lives on its object, so it has that one user
        while the object exists and none after."""
        if self._owner is None:
            return 0
        return 1 if _display(self._owner) is not None else 0

    def __getattr__(self, key):
        if key.startswith("_"):
            raise AttributeError(key)
        _, values = self._state()
        fields = self._fields(values)
        if key not in fields:
            raise AttributeError("'%s' object has no attribute '%s'" % (self._rna(values), key))
        return _typed(fields[key], values.get(key))

    def __setattr__(self, key, value):
        if isinstance(getattr(type(self), key, None), property):
            object.__setattr__(self, key, value)
            return
        name, values = self._state()
        fields = self._fields(values)
        if key not in fields:
            raise AttributeError("'%s' object has no attribute '%s'" % (self._rna(values), key))
        _check(self._KIND, key, value)
        values[key] = _converted(fields[key], value)
        self._write(name, values)

    def __eq__(self, other):
        return isinstance(other, type(self)) and other.name == self.name

    def __hash__(self):
        return hash((self._KIND, self.name))

    def __repr__(self):
        return 'bpy.data.%s["%s"]' % ("cameras" if self._KIND == "CAMERA" else "lights", self.name)


class CameraData(_DataBlock):
    """`bpy.types.Camera`."""

    __slots__ = ()
    _KIND = "CAMERA"

    @classmethod
    def _fields(cls, values):
        return dict(_CAMERA)

    @classmethod
    def _rna(cls, values):
        return "Camera"

    def _sensor(self):
        return self.sensor_height if self.sensor_fit == "VERTICAL" else self.sensor_width

    @property
    def angle(self):
        """The field of view, from the lens and the sensor its fit measures."""
        return 2.0 * math.atan(self._sensor() / 2.0 / self.lens)

    @angle.setter
    def angle(self, value):
        self.lens = (self._sensor() / 2.0) / math.tan(float(value) / 2.0)

    @property
    def dof(self):
        return _CameraDof(self)


class _CameraDof:
    """`Camera.dof`, as far as the viewport needs it: the focus distance the
    limits draw their cross at. A focus object has nowhere to live here."""

    __slots__ = ("_camera",)

    def __init__(self, camera):
        self._camera = camera

    focus_object = None
    use_dof = False

    @property
    def focus_distance(self):
        _, values = self._camera._state()
        return _typed(10.0, values.get("focus_distance"))

    @focus_distance.setter
    def focus_distance(self, value):
        name, values = self._camera._state()
        values["focus_distance"] = float(value)
        self._camera._write(name, values)


class LightData(_DataBlock):
    """`bpy.types.Light`: a PointLight, SunLight, SpotLight or AreaLight,
    offering only the properties its type has, as Blender's do."""

    __slots__ = ()
    _KIND = "LIGHT"
    _CLASSES = {"POINT": "PointLight", "SUN": "SunLight", "SPOT": "SpotLight", "AREA": "AreaLight"}

    @classmethod
    def _fields(cls, values):
        fields = dict(_LIGHT)
        kind = values.get("type", "POINT")
        if kind == "SPOT":
            fields.update(_SPOT)
        elif kind == "AREA":
            fields.update(_AREA)
        return fields

    @classmethod
    def _rna(cls, values):
        return cls._CLASSES.get(values.get("type", "POINT"), "Light")


class _DataBlocks:
    """`bpy.data.cameras` and `bpy.data.lights`: the data-blocks the scene's
    objects hold."""

    def __init__(self, kind, block):
        self._kind = kind
        self._block = block

    def _held(self):
        return [self._block(name) for name in _bk.object_names()
                if display_type(name) == self._kind]

    def __iter__(self):
        return iter(self._held())

    def __len__(self):
        return len(self._held())

    def keys(self):
        return [block.name for block in self._held()]

    def values(self):
        return self._held()

    def items(self):
        return [(block.name, block) for block in self._held()]

    def __contains__(self, key):
        return key in self.keys()

    def __getitem__(self, key):
        blocks = self._held()
        if isinstance(key, int):
            return blocks[key]
        for block in blocks:
            if block.name == key:
                return block
        raise KeyError('bpy_prop_collection[key]: key "%s" not found' % key)

    def get(self, key, default=None):
        try:
            return self[key]
        except (KeyError, IndexError):
            return default

    def remove(self, block, do_unlink=True, **kw):
        """Removing a camera's or light's data-block removes the objects using
        it too — measured in Blender 5.2.1 — and here that is its one object."""
        owner = getattr(block, "_owner", None)
        if owner is not None and owner in _bk.object_names():
            _bk.remove(owner)

    def __repr__(self):
        return "<bpy_collection[%d], BlendData%ss>" % (len(self), self._kind.title())


class _Cameras(_DataBlocks):
    def __init__(self):
        super().__init__("CAMERA", CameraData)

    def new(self, name):
        values = dict(_CAMERA)
        values.update(_render_aspect())
        values.update(focus_distance=10.0, scene_camera=False)
        return CameraData(None, str(name), values)


class _Lights(_DataBlocks):
    def __init__(self):
        super().__init__("LIGHT", LightData)

    def new(self, name, type):
        _check("LIGHT", "type", type)
        values = dict(_LIGHT)
        values.update(_SPOT)
        values.update(_AREA)
        values["type"] = type
        return LightData(None, str(name), values)


def makes(data):
    """Whether `bpy.data.objects.new(name, data)` makes an empty, a camera or
    a light."""
    return data is None or isinstance(data, _DataBlock)


def new_object(name, data):
    """`bpy.data.objects.new` for an empty (no data), a camera or a light.

    Blender makes the object unlinked until a collection takes it. The shim's
    objects are in the scene from the start — `collection.objects.link`
    accepts them and does nothing — so this adds it unselected, as a script
    that goes on to link it expects to find it.
    """
    if data is None:
        made = _bk.add_object("EMPTY", str(name), 0.0, 0.0, 0.0, "", _format(dict(_EMPTY)), False)
        return Object(made)
    data_name, values = data._state()
    made = _bk.add_object(data._KIND, str(name), 0.0, 0.0, 0.0, data_name, _format(values), False)
    if data._owner is None:
        object.__setattr__(data, "_owner", made)
    return Object(made)


_objects_new = _Objects.new


def _new_object(self, name, object_data):
    """`bpy.data.objects.new`: an empty, a camera or a light here, and
    whatever it made before for anything else."""
    if makes(object_data):
        return new_object(name, object_data)
    return _objects_new(self, name, object_data)


# ---------------------------------------------------------------------------
# The operators


def _vector(value, fallback=(0.0, 0.0, 0.0)):
    return [float(c) for c in value] if value else list(fallback)


def _add(kind, name, data_name, values, location, rotation):
    loc = _vector(location)
    made = _bk.add_object(kind, name, loc[0], loc[1], loc[2], data_name, _format(values))
    rot = _vector(rotation)
    if any(abs(c) > 1e-9 for c in rot):
        _bk.set_vec(made, "rotation_euler", *rot)
    return {"FINISHED"}


def camera_add(self, enter_editmode=False, align="WORLD", location=(0.0, 0.0, 0.0),
               rotation=(0.0, 0.0, 0.0), scale=(0.0, 0.0, 0.0), **kw):
    """`bpy.ops.object.camera_add`.

    Like a Blender with no window, this leaves `scene.camera` alone; the
    interface's Add Camera sets it the way Blender's 3D View does."""
    values = dict(_CAMERA)
    values.update(_render_aspect())
    values.update(focus_distance=10.0, scene_camera=False)
    return _add("CAMERA", "Camera", "Camera", values, location, rotation)


def light_add(self, type="POINT", radius=1.0, align="WORLD", location=(0.0, 0.0, 0.0),
              rotation=(0.0, 0.0, 0.0), scale=(0.0, 0.0, 0.0), **kw):
    """`bpy.ops.object.light_add`, named after its type as Blender names it."""
    _check("LIGHT", "type", type)
    # object_light_add_exec: the radius scales the light's sizes, four times
    # over for an area light and by half for a sun.
    size = float(radius) * {"AREA": 4.0, "SUN": 0.5}.get(type, 1.0)
    values = dict(_LIGHT)
    values.update(_SPOT)
    values.update(_AREA)
    values["type"] = type
    for key in ("shadow_soft_size", "size", "size_y"):
        values[key] = values[key] * size
    if type == "SUN":
        values["energy"] = 1.0
    label = type.title()
    return _add("LIGHT", label, label, values, location, rotation)


def empty_add(self, type="PLAIN_AXES", radius=1.0, align="WORLD", location=(0.0, 0.0, 0.0),
              rotation=(0.0, 0.0, 0.0), scale=(0.0, 0.0, 0.0), **kw):
    """`bpy.ops.object.empty_add`: the radius is the display size."""
    _check("EMPTY", "empty_display_type", type)
    values = dict(_EMPTY)
    values["empty_display_type"] = type
    values["empty_display_size"] = values["empty_display_size"] * float(radius)
    return _add("EMPTY", "Empty", "", values, location, rotation)


# ---------------------------------------------------------------------------
# Object and scene properties


def _empty_property(key, default):
    """An empty's display property. Blender keeps these on every object; the
    shim keeps them on empties, and answers the default for the rest."""

    def get(self):
        found = _display(self.name)
        if found is None or found[0] != "EMPTY":
            return default
        return _typed(default, found[2].get(key))

    def set(self, value):
        found = _display(self.name)
        if found is None or found[0] != "EMPTY":
            return
        _check("EMPTY", key, value)
        values = found[2]
        values[key] = _converted(default, value)
        _store(self.name, found[1], values)

    return property(get, set)


# A scene camera that is not a camera — Blender allows any object — has no
# record to mark, so it is remembered here.
_other_scene_camera = [None]


def _scene_camera_get(self):
    for name in _bk.object_names():
        found = _display(name)
        if found is not None and found[0] == "CAMERA" and _typed(False, found[2].get("scene_camera")):
            return Object(name)
    other = _other_scene_camera[0]
    if other is not None and other in _bk.object_names():
        return Object(other)
    return None


def _scene_camera_set(self, value):
    target = None if value is None else value.name
    _other_scene_camera[0] = None
    for name in _bk.object_names():
        found = _display(name)
        if found is None or found[0] != "CAMERA":
            continue
        chosen = name == target
        if _typed(False, found[2].get("scene_camera")) != chosen:
            values = found[2]
            values["scene_camera"] = chosen
            _store(name, found[1], values)
    if target is not None and display_type(target) != "CAMERA":
        _other_scene_camera[0] = target


class _Render:
    """`scene.render`: the resolution. It is also the shape of every camera's
    frame, so changing it redraws them."""

    __slots__ = ()

    def __getattr__(self, key):
        if key in _RENDER:
            return _RENDER[key]
        raise AttributeError("'RenderSettings' object has no attribute '%s' in this shim" % key)

    def __setattr__(self, key, value):
        if key not in _RENDER:
            raise AttributeError("'RenderSettings' object has no attribute '%s' in this shim" % key)
        _RENDER[key] = int(value) if isinstance(_RENDER[key], int) else float(value)
        if key == "resolution_percentage":
            return
        aspect = _render_aspect()
        for name in _bk.object_names():
            found = _display(name)
            if found is not None and found[0] == "CAMERA":
                values = found[2]
                values.update(aspect)
                _store(name, found[1], values)


Object.type = property(_object_type)
Object.data = property(_object_data)
_Objects.new = _new_object
Object.empty_display_type = _empty_property("empty_display_type", "PLAIN_AXES")
Object.empty_display_size = _empty_property("empty_display_size", 1.0)
Object.empty_image_offset = _empty_property("empty_image_offset", (-0.5, -0.5))
_Scene.camera = property(_scene_camera_get, _scene_camera_set)
_Scene.render = property(lambda self: _Render())
_Data.cameras = _Cameras()
_Data.lights = _Lights()
_ObjectOps.camera_add = camera_add
_ObjectOps.light_add = light_add
_ObjectOps.empty_add = empty_add
types.Camera = CameraData
types.Light = LightData
