"""A `bpy`-shaped API over Blender Local's scene.

This is **not** Blender's `bpy`. It is Blender Local's own module, written to match
the shape of the calls people actually reach for — `bpy.ops.mesh.primitive_*`,
`bpy.data.objects[...]`, `bpy.context.selected_objects` — so scripts read the
way Blender scripts read and the Info log stays copy-pasteable.

It talks to the app through the built-in `_blenderkit` module, so everything
happens on device with no network involved.
"""

import _blenderkit as _bk
import mathutils
from mathutils import Vector, Euler, Matrix, Quaternion

__all__ = ["ops", "data", "context", "types", "app", "utils"]


class _BoundVector(Vector):
    """A `mathutils.Vector` that writes back to its object when mutated.

    Blender lets you say `obj.location.x = 2`, which only works if the vector
    knows where it came from. Inheriting from `mathutils.Vector` means the
    arithmetic (`obj.location + Vector((1, 0, 0))`, `.length`, `.cross`) all
    works too; those operations return a plain unbound Vector, as they do in
    Blender.
    """

    __slots__ = ("_owner", "_prop")

    def __init__(self, values, owner=None, prop=None):
        super().__init__(values)
        self._owner = owner
        self._prop = prop

    def _flush(self):
        if self._owner is not None:
            _bk.set_vec(self._owner, self._prop, *self._v)

    def _axis(i):
        def get(self):
            return self._v[i]

        def set(self, value):
            self._v[i] = float(value)
            self._flush()

        return property(get, set)

    x = _axis(0)
    y = _axis(1)
    z = _axis(2)
    del _axis

    def __setitem__(self, i, value):
        self._v[i] = float(value)
        self._flush()


class Object:
    """One scene object. Attributes read through to the app every time, so a
    change made in the Tools tab is visible here immediately."""

    __slots__ = ("_name", "_rotation_mode")

    def __init__(self, name):
        self._name = name

    @property
    def name(self):
        return self._name

    @name.setter
    def name(self, value):
        # Blender never lets two objects share a name; it suffixes instead, and
        # returns what the name actually became.
        self._name = _bk.rename(self._name, str(value))

    def _vec(self, prop):
        return _BoundVector(_bk.get_vec(self.name, prop), self.name, prop)

    @property
    def location(self):
        return self._vec("location")

    @location.setter
    def location(self, value):
        _bk.set_vec(self.name, "location", *[float(c) for c in value])

    @property
    def rotation_mode(self):
        """Blender objects carry a rotation mode; scripts set it to
        'QUATERNION' before assigning `rotation_quaternion`. Rotation is stored
        as XYZ Euler here, so the mode is remembered and the quaternion is
        converted on assignment — the resulting orientation is identical."""
        return getattr(self, "_rotation_mode", "XYZ")

    @rotation_mode.setter
    def rotation_mode(self, value):
        object.__setattr__(self, "_rotation_mode", str(value))

    @property
    def rotation_quaternion(self):
        from mathutils import Euler
        e = self.rotation_euler
        return Euler((e[0], e[1], e[2])).to_quaternion()

    @rotation_quaternion.setter
    def rotation_quaternion(self, value):
        from mathutils import Quaternion
        q = value if isinstance(value, Quaternion) else Quaternion(tuple(value))
        self.rotation_euler = tuple(q.to_euler())

    @property
    def rotation_euler(self):
        return self._vec("rotation_euler")

    @rotation_euler.setter
    def rotation_euler(self, value):
        _bk.set_vec(self.name, "rotation_euler", *[float(c) for c in value])

    @property
    def scale(self):
        return self._vec("scale")

    @scale.setter
    def scale(self, value):
        _bk.set_vec(self.name, "scale", *[float(c) for c in value])

    @property
    def type(self):
        return "MESH"

    @property
    def data(self):
        return Mesh(self.name)

    @property
    def modifiers(self):
        return _Modifiers(self.name)

    @property
    def active_material(self):
        return MaterialProxy(self.name)

    @property
    def uv_layers(self):
        """Present once the mesh is unwrapped, as Blender's is."""
        return _UVLayers(self.name)

    @property
    def color(self):
        """Viewport display colour, shown in Material Preview shading."""
        return Vector(_bk.get_color(self.name))

    @color.setter
    def color(self, value):
        v = list(value)
        if len(v) == 3:
            v.append(1.0)
        _bk.set_color(self.name, *[float(c) for c in v[:4]])

    # Blender keeps two flags where the stand-in once kept one: `hide_viewport`
    # (Disable in Viewports, the Outliner's monitor) and the view layer's
    # `hide_get()` (H, Alt+H and the Outliner's eye). `_bk.get_visible` and
    # `set_visible` take which: 0 the first, 1 the second, 2 (reading only)
    # whether the object is drawn at all, which is `visible_get()`.
    @property
    def hide_viewport(self):
        return not _bk.get_visible(self.name, 0)

    @hide_viewport.setter
    def hide_viewport(self, value):
        _bk.set_visible(self.name, not bool(value), 0)

    def hide_get(self, view_layer=None):
        return not _bk.get_visible(self.name, 1)

    def hide_set(self, state, view_layer=None):
        _bk.set_visible(self.name, not bool(state), 1)

    def visible_get(self, view_layer=None, viewport=None):
        return bool(_bk.get_visible(self.name, 2))

    @property
    def dimensions(self):
        """World-space bounding-box size, as Blender reports it."""
        lo_x, lo_y, lo_z, hi_x, hi_y, hi_z = _bk.bounds(self.name)
        return Vector((hi_x - lo_x, hi_y - lo_y, hi_z - lo_z))

    @property
    def bound_box(self):
        lo_x, lo_y, lo_z, hi_x, hi_y, hi_z = _bk.bounds(self.name)
        return tuple((x, y, z)
                     for x in (lo_x, hi_x) for y in (lo_y, hi_y) for z in (lo_z, hi_z))

    @property
    def matrix_world(self):
        """location @ rotation @ scale, composed in Blender's order."""
        loc = _bk.get_vec(self.name, "location")
        rot = _bk.get_vec(self.name, "rotation_euler")
        scl = _bk.get_vec(self.name, "scale")
        return (Matrix.Translation(loc)
                @ Euler(rot).to_matrix()
                @ Matrix.Diagonal(scl))

    def select_get(self):
        return _bk.is_selected(self.name)

    def evaluated_get(self, depsgraph):
        """The shim applies its modifier stack eagerly, so the evaluated object
        is the object."""
        return self

    def to_mesh(self, **kw):
        return Mesh(self.name)

    def to_mesh_clear(self):
        """Nothing to free: the shim does not allocate a temporary mesh."""
        return None

    def keyframe_insert(self, data_path="location", frame=None, **kw):
        """Keys one transform channel at a frame, as Blender does: the value it
        has now, at `frame` or the current one, with the playhead left alone.

        It used to move the playhead to `frame` first, which evaluated the keys
        already there and keyed their value instead of the one just set — a
        script keying x=0 at frame 1 and x=3 at frame 60 got 0 at both.
        """
        if data_path not in ("location", "rotation_euler", "scale"):
            raise NotImplementedError(
                "only location, rotation_euler and scale are keyable; "
                "'%s' needs a general F-curve system" % data_path)
        _bk.keyframe(self.name, data_path, _bk.set_frame(-1) if frame is None else int(frame), True)
        return True

    def keyframe_delete(self, data_path="location", frame=None, **kw):
        _bk.keyframe(self.name, data_path, _bk.set_frame(-1) if frame is None else int(frame), False)
        return True

    @property
    def primitive(self):
        """Blender Local extension: which primitive this object was made from."""
        return _bk.object_kind(self.name)

    @property
    def mode(self):
        """`object.mode` — which mode the object is in.

        It did not exist here at all, which is why code that branched on it
        threw `AttributeError` in the simulator and worked on device. Three
        separate mode bugs reached a device that way: there was no mode here to
        get wrong, so nothing depending on one could be tested.
        """
        return _bk.mode()

    def update_from_editmode(self):
        """Write the edit-mode mesh back to the datablock.

        Blender keeps a separate BMesh while you are in edit mode, and this is
        what flushes it to `object.data`. There is no such separation here —
        the shim edits the one mesh directly — so there is nothing to flush and
        this answers the way Blender does when it is not in edit mode: False,
        meaning nothing was written.

        It exists because the interface calls it before taking the backup that
        makes an operator adjustable. Without it every mesh operator failed on
        its first line in the simulator with an AttributeError.
        """
        return False

    def select_set(self, state):
        _bk.select(self.name, bool(state))

    def __eq__(self, other):
        return isinstance(other, Object) and other.name == self.name

    def __hash__(self):
        return hash(self.name)

    def __repr__(self):
        return 'bpy.data.objects["{}"]'.format(self.name)


class Modifier:
    """One entry in an object's modifier stack.

    Settings are named as Blender names them, so `mod.levels = 2` on a
    Subdivision modifier and `mod.count = 5` on an Array both read the same as
    they would in a Blender script.
    """

    __slots__ = ("_obj", "name", "type")

    # Which settings each modifier type accepts, and how many components each
    # takes across the bridge.
    _SETTINGS = {
        "subdivision":  {"levels": 1, "render_levels": 1},
        "array":        {"count": 1, "relative_offset_displace": 3},
        # Bisect and Flip are triples like the axes; Clipping and Merge are
        # flags; the merge distance a number.
        "mirror":       {"use_axis": 3, "use_bisect_axis": 3, "use_bisect_flip_axis": 3,
                         "use_clip": 1, "use_mirror_merge": 1, "merge_threshold": 1},
        "solidify":     {"thickness": 1},
        "smooth":       {"factor": 1, "iterations": 1},
        "cast":         {"factor": 1},
        "simple_deform": {"angle": 1, "deform_axis": 1, "deform_method": 1},
        "displace":     {"strength": 1},
        "weld":         {},
        # Wave has no axis: its `deform_axis` raises AttributeError in Blender
        # 5.2.1 (measured). Motion X and Y choose where the ripple travels.
        "wave":         {"height": 1, "use_x": 1, "use_y": 1},
        "triangulate":  {},
        "bevel":        {"width": 1, "segments": 1},
        # Boolean's `object` and Shrinkwrap's `target` are object pointers,
        # which `_bk.modifier_set` cannot carry: they go by name through
        # `_bk.modifier_set_object`. They used to be refused here, and the
        # Modifiers panel's picked target raised AttributeError in the simulator.
        "boolean":      {"operation": 1, "object": "object"},
        "shrinkwrap":   {"offset": 1, "wrap_method": 1, "target": "object"},
        "screw":        {"angle": 1, "steps": 1, "render_steps": 1, "axis": 1,
                         "screw_offset": 1},
        "decimate":     {"ratio": 1, "decimate_type": 1},
        "remesh":       {"mode": 1, "voxel_size": 1, "octree_depth": 1},
        "weighted_normal": {"mode": 1, "weight": 1, "thresh": 1, "keep_sharp": 1,
                            "use_face_influence": 1},
        # `total_levels` is read-only in Blender; the Subdivide and Delete
        # Higher operators below change it.
        "multires":     {"levels": 1, "sculpt_levels": 1, "render_levels": 1},
        "edge_split":   {"split_angle": 1, "use_edge_angle": 1, "use_edge_sharp": 1},
        "laplaciansmooth": {"iterations": 1, "lambda_factor": 1, "lambda_border": 1,
                            "use_x": 1, "use_y": 1, "use_z": 1,
                            "use_volume_preserve": 1, "use_normalized": 1},
        "corrective_smooth": {"factor": 1, "iterations": 1, "scale": 1, "smooth_type": 1,
                              "use_only_smooth": 1, "use_pin_boundary": 1},
        "lattice":      {"strength": 1, "object": "object"},
    }

    # The two switches every modifier has, whatever its kind — the ones every
    # row of the Modifiers panel sends.
    _COMMON = {"show_viewport": 1, "show_render": 1}

    # Enum settings whose identifiers depend on the modifier: Weighted
    # Normal's `mode` is not Remesh's.
    _KIND_ENUMS = {
        "weighted_normal": {"mode": ("FACE_AREA", "CORNER_ANGLE", "FACE_AREA_WITH_ANGLE")},
    }

    # Blender's enum settings are identifier strings and the bridge takes
    # doubles, so each is passed as its position in Blender's own enum order —
    # which is the order the Swift enums declare their cases in.
    _ENUMS = {
        "deform_method": ("TWIST", "BEND", "TAPER", "STRETCH"),
        "deform_axis":  ("X", "Y", "Z"),
        "axis":         ("X", "Y", "Z"),
        "operation":    ("DIFFERENCE", "UNION", "INTERSECT"),
        "wrap_method":  ("NEAREST_SURFACEPOINT", "PROJECT", "NEAREST_VERTEX",
                         "TARGET_PROJECT"),
        "mode":         ("BLOCKS", "SMOOTH", "SHARP", "VOXEL"),
        "decimate_type": ("COLLAPSE", "UNSUBDIV", "DISSOLVE"),
        "smooth_type":  ("SIMPLE", "LENGTH_WEIGHTED"),
    }

    # Settings the engine knows nothing about, because they refer to a curve.
    # They are kept here and consumed by the curve bake in `_bake_along_curve`.
    _CURVE_SETTINGS = {
        "array": ("fit_type", "curve", "fit_length", "use_relative_offset"),
        "curve": ("object", "deform_axis"),
    }

    def __init__(self, obj, name, kind):
        self._obj = obj
        self.name = name
        self.type = {"subdivision": "SUBSURF",
                     "array": "ARRAY",
                     "mirror": "MIRROR",
                     "solidify": "SOLIDIFY",
                     "smooth": "SMOOTH",
                     "cast": "CAST",
                     "simpleDeform": "SIMPLE_DEFORM",
                     "simple_deform": "SIMPLE_DEFORM",
                     "displace": "DISPLACE",
                     "weld": "WELD",
                     "wave": "WAVE",
                     "triangulate": "TRIANGULATE",
                     "bevel": "BEVEL",
                     "boolean": "BOOLEAN",
                     "shrinkwrap": "SHRINKWRAP",
                     "screw": "SCREW",
                     "decimate": "DECIMATE",
                     "remesh": "REMESH",
                     # The engine lists kinds by the Swift case name.
                     "weightedNormal": "WEIGHTED_NORMAL",
                     "multires": "MULTIRES",
                     "edgeSplit": "EDGE_SPLIT",
                     "laplacianSmooth": "LAPLACIANSMOOTH",
                     "correctiveSmooth": "CORRECTIVE_SMOOTH",
                     "lattice": "LATTICE"}.get(kind, kind.upper())

    @property
    def _kind(self):
        return {"SUBSURF": "subdivision", "ARRAY": "array", "MIRROR": "mirror",
                "SOLIDIFY": "solidify", "SMOOTH": "smooth", "CAST": "cast",
                "SIMPLE_DEFORM": "simple_deform", "DISPLACE": "displace",
                "WELD": "weld", "WAVE": "wave",
                "TRIANGULATE": "triangulate", "BEVEL": "bevel",
                "BOOLEAN": "boolean", "SHRINKWRAP": "shrinkwrap",
                "SCREW": "screw", "DECIMATE": "decimate",
                "REMESH": "remesh"}.get(self.type, self.type.lower())

    def __setattr__(self, key, value):
        if key in Modifier.__slots__:
            object.__setattr__(self, key, value)
            return
        kind = self._kind
        if key in Modifier._CURVE_SETTINGS.get(kind, ()):
            _curve_mod_set(self._obj, self.name, kind, key, value)
            return
        # relative_offset_displace feeds the curve bake as well as the engine,
        # so it is recorded before being passed along.
        if kind == "array" and key == "relative_offset_displace":
            _curve_mod_set(self._obj, self.name, kind, key, list(value),
                           rebake=False)
        allowed = dict(Modifier._SETTINGS.get(self._kind, {}), **Modifier._COMMON)
        if self._kind == "curve":
            raise AttributeError(
                "Curve modifier has no setting '{}'; available: object, "
                "deform_axis".format(key))
        if key not in allowed:
            raise AttributeError(
                "{} modifier has no setting '{}'; available: {}"
                .format(self.type, key, ", ".join(sorted(allowed))))
        if allowed[key] == "object":
            # Blender takes an object or None and raises TypeError for anything
            # else, including a name.
            if value is not None and not hasattr(value, "name"):
                raise TypeError(
                    "bpy_struct: item.attr = val: expected an Object type, not {}"
                    .format(type(value).__name__))
            _bk.modifier_set_object(self._obj, self.name, key,
                                    "" if value is None else value.name)
            return
        # A Subdivision's render_levels and a Screw's render_steps have no
        # separate meaning without a render engine. A Multires keeps its
        # render level apart, as the row shows it.
        bridge_key = {"relative_offset_displace": "relative_offset",
                      "render_levels": "render_levels" if kind == "multires" else "levels",
                      "render_steps": "steps"}.get(key, key)
        # An enum string in Blender; convert to its index. An identifier that
        # is not in the enum says so here rather than becoming float('X').
        choices = Modifier._KIND_ENUMS.get(kind, {}).get(key) or Modifier._ENUMS.get(key)
        if choices is not None and isinstance(value, str):
            if value.upper() not in choices:
                raise ValueError(
                    "'{}' is not a valid {} for a {} modifier; expected one of: {}"
                    .format(value, key, self.type, ", ".join(choices)))
            value = choices.index(value.upper())
        if allowed[key] == 1:
            _bk.modifier_set(self._obj, self.name, bridge_key, float(value), 0.0, 0.0)
        else:
            v = [float(c) for c in value]
            _bk.modifier_set(self._obj, self.name, bridge_key, *(v + [0.0, 0.0, 0.0])[:3])

    def __getattr__(self, key):
        # __slots__ means anything not stored lands here; the curve settings
        # live in the side table so a script can read back what it set.
        obj = object.__getattribute__(self, "_obj")
        mod = object.__getattribute__(self, "name")
        state = _CURVE_MODS.get((obj, mod)) or {}
        if key == "relative_offset_displace":
            return _ModVector(obj, mod, key,
                              state.get(key, (1.0, 0.0, 0.0)))
        if key in state:
            return state[key]
        raise AttributeError(key)

    def __repr__(self):
        return '<bpy_struct, {}Modifier("{}")>'.format(self.type.title(), self.name)


class _ModVector:
    """A modifier's vector setting.

    Blender scripts overwhelmingly write these one component at a time
    (`arr.relative_offset_displace[0] = 1.15`), so reading one has to hand back
    something that writes through rather than a plain tuple."""

    __slots__ = ("_obj", "_mod", "_key", "_v")

    def __init__(self, obj, mod, key, values):
        object.__setattr__(self, "_obj", obj)
        object.__setattr__(self, "_mod", mod)
        object.__setattr__(self, "_key", key)
        object.__setattr__(self, "_v", [float(c) for c in values])

    def __setitem__(self, i, value):
        self._v[i] = float(value)
        _curve_mod_set(self._obj, self._mod, "array", self._key,
                       list(self._v), rebake=False)
        _bk.modifier_set(self._obj, self._mod, "relative_offset", *self._v[:3])

    def __getitem__(self, i):
        return self._v[i]

    def __iter__(self):
        return iter(self._v)

    def __len__(self):
        return len(self._v)

    def __repr__(self):
        return "Vector(({:.4f}, {:.4f}, {:.4f}))".format(*self._v)


class _Modifiers:
    """`obj.modifiers` — the stack, in evaluation order."""

    __slots__ = ("_obj",)

    def __init__(self, obj):
        self._obj = obj

    def _entries(self):
        raw = _bk.modifier_list(self._obj)
        engine = [line.split("|", 1) for line in raw.split("\n") if line] if raw else []
        return engine + [[n, "curve"] for n in _CURVE_MOD_ORDER.get(self._obj, [])]

    def new(self, name="", type="SUBSURF"):
        """Matches Blender's `obj.modifiers.new(name, type)`.

        A Curve modifier deforms geometry along a curve, which the engine has
        no notion of, so it is held on this side and evaluated by the bake in
        `_bake_along_curve` once its target curve is known."""
        if type.upper() == "CURVE":
            nm = name or "Curve"
            _CURVE_MODS.setdefault((self._obj, nm), {"kind": "curve"})
            _CURVE_MOD_ORDER.setdefault(self._obj, []).append(nm)
            return Modifier(self._obj, nm, "curve")
        actual = _bk.modifier_add(self._obj, type)
        return Modifier(self._obj, actual, type.lower())

    def remove(self, modifier):
        nm = modifier.name if isinstance(modifier, Modifier) else str(modifier)
        if _CURVE_MODS.pop((self._obj, nm), None) is not None:
            order = _CURVE_MOD_ORDER.get(self._obj, [])
            if nm in order:
                order.remove(nm)
            return
        _bk.modifier_remove(self._obj, nm)

    def clear(self):
        for name, _ in self._entries():
            _bk.modifier_remove(self._obj, name)

    def __getitem__(self, key):
        entries = self._entries()
        if isinstance(key, int):
            name, kind = entries[key]
        else:
            match = [e for e in entries if e[0] == key]
            if not match:
                raise KeyError('no modifier named "{}"'.format(key))
            name, kind = match[0]
        return Modifier(self._obj, name, kind)

    def get(self, key, default=None):
        try:
            return self[key]
        except (KeyError, IndexError):
            return default

    @property
    def active(self):
        """The one `modifier_add` just made, as Blender's is (measured in 5.2.1,
        including ahead of a modifier pinned to last): here, the newest the
        engine holds."""
        engine = [e for e in self._entries() if e[1] != "curve"]
        if not engine:
            return None
        name, kind = engine[-1]
        return Modifier(self._obj, name, kind)

    def __iter__(self):
        return (Modifier(self._obj, n, k) for n, k in self._entries())

    def __len__(self):
        return len(self._entries())

    def keys(self):
        return [n for n, _ in self._entries()]

    def __repr__(self):
        return "<bpy_collection[{}], ObjectModifiers>".format(len(self))


class _StandaloneMaterial:
    """A material made with `bpy.data.materials.new(...)`.

    Blender's materials are datablocks that exist before anything uses them,
    and scripts build them that way: create, set the Principled inputs, then
    append to a mesh. Nothing here modelled that — `bpy.data.materials` did not
    exist at all — so any script that opened with it stopped on its first line
    with a bare AttributeError.

    The values are held until the material is appended to an object, at which
    point they are pushed through the same bridge `obj.active_material` uses.
    """

    def __init__(self, name):
        self.name = name
        self.values = {}
        self._use_nodes = True

    @property
    def use_nodes(self):
        return self._use_nodes

    @use_nodes.setter
    def use_nodes(self, value):
        self._use_nodes = bool(value)

    @property
    def node_tree(self):
        return _StandaloneNodeTree(self)

    @property
    def diffuse_color(self):
        return self.values.get("Base Color", (0.8, 0.8, 0.8, 1.0))

    @diffuse_color.setter
    def diffuse_color(self, value):
        self.values["Base Color"] = tuple(value)

    def apply_to(self, obj_name):
        """Pushes the buffered inputs onto an object."""
        for key, value in self.values.items():
            if isinstance(value, (int, float)):
                _bk.material_set(obj_name, key, float(value), 0.0, 0.0)
            else:
                v = list(value) + [0.0, 0.0, 0.0]
                _bk.material_set(obj_name, key, float(v[0]), float(v[1]), float(v[2]))

    def __repr__(self):
        return 'bpy.data.materials[%r]' % self.name


class _StandaloneNodeTree:
    def __init__(self, material):
        self._material = material

    @property
    def nodes(self):
        return {"Principled BSDF": _StandaloneBSDF(self._material)}


class _StandaloneBSDF:
    def __init__(self, material):
        self._material = material

    @property
    def inputs(self):
        return _StandaloneInputs(self._material)


class _StandaloneInputs:
    def __init__(self, material):
        self._material = material

    def __getitem__(self, key):
        if key not in MaterialProxy._INPUTS:
            raise KeyError("no Principled BSDF input named %r here; "
                           "this shim carries %s" % (key, ", ".join(MaterialProxy._INPUTS)))
        return _StandaloneSocket(self._material, key)


class _StandaloneSocket:
    def __init__(self, material, key):
        self._material = material
        self._key = key

    @property
    def default_value(self):
        return self._material.values.get(self._key, 0.0)

    @default_value.setter
    def default_value(self, value):
        self._material.values[self._key] = value


class _Materials:
    """`bpy.data.materials`."""

    def __init__(self):
        self._store = {}

    def new(self, name="Material"):
        # Blender's .001 rule applies to datablocks too.
        final, n = name, 1
        while final in self._store:
            final = "%s.%03d" % (name, n)
            n += 1
        mat = _StandaloneMaterial(final)
        self._store[final] = mat
        return mat

    def get(self, name, default=None):
        return self._store.get(name, default)

    def remove(self, material):
        self._store.pop(getattr(material, "name", material), None)

    def __getitem__(self, key):
        return self._store[key]

    def __iter__(self):
        return iter(self._store.values())

    def __len__(self):
        return len(self._store)

    def keys(self):
        return list(self._store)


class MaterialProxy:
    """`obj.active_material` — the Principled BSDF's inputs.

    Blender reaches these through the node tree
    (`mat.node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value`);
    that path works here too, which is what most scripts actually write.
    """

    __slots__ = ("_obj",)

    _INPUTS = ("Base Color", "Metallic", "Roughness", "IOR",
               "Emission Color", "Emission Strength")

    def __init__(self, obj):
        self._obj = obj

    @property
    def name(self):
        return "Material"

    @property
    def node_tree(self):
        return _NodeTree(self._obj)

    def __repr__(self):
        return 'bpy.data.materials["Material"]'


class _Socket:
    __slots__ = ("_obj", "_name")

    def __init__(self, obj, name):
        self._obj = obj
        self._name = name

    @property
    def default_value(self):
        raise NotImplementedError(
            "socket values are write-only in Blender Local; read them from the "
            "Shader Editor")

    @default_value.setter
    def default_value(self, value):
        if isinstance(value, (int, float)):
            _bk.material_set(self._obj, self._name, float(value), 0.0, 0.0)
        else:
            v = [float(c) for c in value]
            _bk.material_set(self._obj, self._name, *(v + [0.0, 0.0, 0.0])[:3])


class _Inputs:
    __slots__ = ("_obj",)

    def __init__(self, obj):
        self._obj = obj

    def __getitem__(self, key):
        if key not in MaterialProxy._INPUTS:
            raise KeyError(
                "no input '%s'; available: %s"
                % (key, ", ".join(MaterialProxy._INPUTS)))
        return _Socket(self._obj, key)


class _BSDFNode:
    __slots__ = ("_obj",)

    def __init__(self, obj):
        self._obj = obj

    @property
    def inputs(self):
        return _Inputs(self._obj)


class _NodeTree:
    __slots__ = ("_obj",)

    def __init__(self, obj):
        self._obj = obj

    @property
    def nodes(self):
        obj = self._obj

        class _Nodes:
            def __getitem__(self, key):
                if key not in ("Principled BSDF", "Material Output"):
                    raise KeyError(
                        "Blender Local's graph has only Principled BSDF and "
                        "Material Output")
                return _BSDFNode(obj)

        return _Nodes()


class _UVLayers:
    __slots__ = ("_obj",)

    def __init__(self, obj):
        self._obj = obj

    def __len__(self):
        return 1

    def new(self, name="UVMap", **kw):
        _bk.uv_project(self._obj, "smart")
        return self

    @property
    def active(self):
        return self


class _Objects:
    """`bpy.data.objects` — indexable by name or position, and iterable."""

    def __getitem__(self, key):
        names = _bk.object_names()
        if isinstance(key, int):
            return list(self)[key]
        if key in names:
            return Object(key)
        if key in _CURVE_OBJECTS:
            return _CURVE_OBJECTS[key]
        raise KeyError(
            'bpy_prop_collection[key]: key "{}" not found'.format(key))

    def get(self, key, default=None):
        try:
            return self[key]
        except (KeyError, IndexError):
            return default

    def __contains__(self, key):
        return key in _bk.object_names() or key in _CURVE_OBJECTS

    def __iter__(self):
        linked = [o for o in _CURVE_OBJECTS.values() if o._linked]
        return iter([Object(n) for n in _bk.object_names()] + linked)

    def __len__(self):
        return len(_bk.object_names()) + sum(
            1 for o in _CURVE_OBJECTS.values() if o._linked)

    def keys(self):
        return list(_bk.object_names()) + [
            n for n, o in _CURVE_OBJECTS.items() if o._linked]

    def values(self):
        return list(self)

    def items(self):
        return [(o.name, o) for o in self]

    def new(self, name, object_data):
        """`bpy.data.objects.new(name, data)` — an object created *unlinked*.

        Blender only shows it once it is linked into a collection. Mesh data
        has no meaning without geometry to fill it, so this is supported for
        curve data, which is the case scripts actually use it for."""
        if isinstance(object_data, Curve):
            base, n, nm = name, 1, name
            while nm in _CURVE_OBJECTS or nm in _bk.object_names():
                nm = "{}.{:03d}".format(base, n)
                n += 1
            obj = _CurveObject(nm, object_data)
            _CURVE_OBJECTS[nm] = obj
            return obj
        raise TypeError(
            "bpy.data.objects.new() here takes curve data; to create mesh "
            "geometry use the bpy.ops.mesh.primitive_*_add operators")

    def remove(self, obj, do_unlink=True, **kw):
        name = obj.name if hasattr(obj, "name") else str(obj)
        if name in _CURVE_OBJECTS:
            del _CURVE_OBJECTS[name]
            return
        _bk.remove(name)

    def find(self, key):
        names = _bk.object_names()
        return names.index(key) if key in names else -1

    def __repr__(self):
        return "<bpy_collection[{}], BlendDataObjects>".format(len(self))


class Mesh:
    """`obj.data` — the mesh datablock. Blender names it after the object."""

    __slots__ = ("name",)

    @property
    def users(self):
        """A mesh here is never orphaned — it exists only while its object
        does — so it always has exactly the one user."""
        return 1

    def __init__(self, name):
        self.name = name

    @property
    def vertices(self):
        return _VertexArray(self.name)

    @property
    def polygons(self):
        return _Elements(_bk.mesh_counts(self.name)[1], "MeshPolygon")

    @property
    def loop_triangles(self):
        return _TriangleArray(self.name)

    loops = polygons

    # The Mesh menu's edge tools read these before they run, to refuse an
    # empty selection in words. The stand-in keeps no edge selection to count,
    # so it says that, rather than AttributeError from `__slots__`.
    def _selection_count(self, what):
        raise NotImplementedError(
            "counting selected %s needs a half-edge mesh; the real bpy on device has it" % what)

    @property
    def total_vert_sel(self):
        return self._selection_count("vertices")

    @property
    def total_edge_sel(self):
        return self._selection_count("edges")

    @property
    def total_face_sel(self):
        return self._selection_count("faces")

    def calc_loop_triangles(self):
        """A no-op here: the shim's meshes are already triangulated."""
        return None

    # Mesh symmetry. The stand-in keeps none and mirrors no transform (it
    # refuses `mirror=True`), so the four read False — what the mirror's
    # `_blenderkit_sync._symmetry` then reports — and a toggle says why it
    # did nothing rather than raising AttributeError from `__slots__`.
    def _symmetry_unmodelled(self, value):
        raise NotImplementedError(
            "mesh symmetry is not modelled by the simulator's stand-in; the real bpy on device has it")

    use_mirror_x = property(lambda self: False, _symmetry_unmodelled)
    use_mirror_y = property(lambda self: False, _symmetry_unmodelled)
    use_mirror_z = property(lambda self: False, _symmetry_unmodelled)
    use_mirror_topology = property(lambda self: False, _symmetry_unmodelled)

    def __repr__(self):
        return 'bpy.data.meshes["{}"]'.format(self.name)

    @property
    def materials(self):
        """`mesh.materials` — the slot list. Appending applies the material's
        Principled inputs to the object, which is the visible effect here."""
        return _MeshMaterials(self.name)


class _MeshArray:
    """Base for the collections `foreach_get` reads from.

    Blender's `foreach_get` fills a preallocated buffer in one call instead of
    iterating in Python. Matching that here means the viewport mirroring code
    is identical against the shim and against Blender.
    """

    __slots__ = ("_name",)
    _ATTRS = {}

    def __init__(self, name):
        self._name = name

    def _arrays(self):
        return _bk.mesh_arrays(self._name)

    def foreach_get(self, attr, seq):
        index = self._ATTRS.get(attr)
        if index is None:
            raise AttributeError(
                "{} has no attribute '{}'; available: {}"
                .format(type(self).__name__, attr, ", ".join(sorted(self._ATTRS))))
        raw = self._arrays()[index]
        # array.frombytes would append; the caller owns a sized buffer, so the
        # values are written in place.
        typecode = seq.typecode
        source = __import__("array").array(typecode)
        source.frombytes(raw)
        n = min(len(seq), len(source))
        seq[:n] = source[:n]

    def __len__(self):
        raise NotImplementedError

    def __repr__(self):
        return "<bpy_collection[{}], {}>".format(len(self), type(self).__name__)


class _VertexArray(_MeshArray):
    __slots__ = ()
    _ATTRS = {"co": 0, "normal": 1}

    def __len__(self):
        return _bk.mesh_counts(self._name)[0]


class _TriangleArray(_MeshArray):
    __slots__ = ()
    _ATTRS = {"vertices": 2}

    def __len__(self):
        return _bk.mesh_counts(self._name)[1]


class _Elements:
    """A counted collection. `len()` works, which is what most scripts want;
    per-element access would mean streaming mesh data across the bridge and is
    not implemented rather than faked."""

    __slots__ = ("_count", "_kind")

    def __init__(self, count, kind):
        self._count = count
        self._kind = kind

    def __len__(self):
        return self._count

    def __getitem__(self, i):
        raise NotImplementedError(
            "per-{} access is not implemented; len() is available"
            .format(self._kind))

    def foreach_get(self, attribute, seq):
        """Every element's value at once is per-element access too. Said, so
        Object > Convert > Curve's check for loose edges ends in a sentence
        rather than AttributeError."""
        raise NotImplementedError(
            "reading {} of every {} needs the mesh streamed across the bridge; "
            "the real bpy on device has it".format(attribute, self._kind))

    def __repr__(self):
        return "<bpy_collection[{}], {}>".format(self._count, self._kind)


class _Scenes:
    def __getitem__(self, key):
        if key in (0, "Scene"):
            return _Scene()
        raise KeyError('key "{}" not found'.format(key))

    def __iter__(self):
        return iter([_Scene()])

    def __len__(self):
        return 1

    def keys(self):
        return ["Scene"]


# Slots live here rather than on the proxy: `mesh.materials` builds a fresh
# proxy on every access, so anything held on the instance would vanish between
# an append and the next read.
_MATERIAL_SLOTS = {}


class _MeshMaterials:
    """The material slots on a mesh."""

    def __init__(self, obj_name):
        self._obj = obj_name
        self._slots = _MATERIAL_SLOTS.setdefault(obj_name, [])

    def append(self, material):
        self._slots.append(material)
        if hasattr(material, "apply_to"):
            material.apply_to(self._obj)

    def clear(self):
        del self._slots[:]

    def __len__(self):
        return len(self._slots)

    def __getitem__(self, i):
        return self._slots[i]



# ---------------------------------------------------------------------------
# Curves
#
# Blender Local's engine draws meshes, not curves, so a curve datablock lives
# entirely on this side: it holds its control points, and the modifiers that
# consume it (Array fit-to-curve, Curve deform) are evaluated here in Python
# and baked to real mesh geometry the engine can draw. A script written against
# Blender sees the same API; what it does not see is that the result is baked
# once rather than staying live.
# ---------------------------------------------------------------------------

_CURVE_OBJECTS = {}          # name -> _CurveObject, the ones not in the engine


class SplinePoint:
    """A control point. Blender stores POLY/NURBS points as 4D (x, y, z, w)."""

    __slots__ = ("co", "radius", "tilt", "weight")

    def __init__(self, co=(0.0, 0.0, 0.0, 1.0)):
        self.co = Vector(co) if len(co) == 4 else Vector(tuple(co) + (1.0,))
        self.radius = 1.0
        self.tilt = 0.0
        self.weight = 1.0

    def __repr__(self):
        return "<bpy_struct, SplinePoint>"


class _SplinePoints:
    """`spline.points` — Blender grows this with `add(n)`, never by assignment."""

    __slots__ = ("_list",)

    def __init__(self):
        self._list = []

    def add(self, count=1):
        for _ in range(int(count)):
            self._list.append(SplinePoint())

    def __iter__(self):
        return iter(self._list)

    def __len__(self):
        return len(self._list)

    def __getitem__(self, i):
        return self._list[i]


class Spline:
    __slots__ = ("type", "points", "bezier_points", "use_cyclic_u",
                 "use_smooth", "order_u", "resolution_u")

    def __init__(self, kind="POLY"):
        self.type = kind
        # A new spline starts with one point in Blender; `add(n-1)` tops it up.
        self.points = _SplinePoints()
        self.points.add(1)
        self.bezier_points = _SplinePoints()
        self.use_cyclic_u = False
        self.use_smooth = True
        self.order_u = 4
        self.resolution_u = 12

    def _coords(self):
        return [(p.co[0], p.co[1], p.co[2]) for p in self.points]

    def __repr__(self):
        return '<bpy_struct, Spline("{}")>'.format(self.type)


class _Splines:
    __slots__ = ("_list",)

    def __init__(self):
        self._list = []

    def new(self, kind="POLY"):
        sp = Spline(kind)
        self._list.append(sp)
        return sp

    def clear(self):
        self._list = []

    def __iter__(self):
        return iter(self._list)

    def __len__(self):
        return len(self._list)

    def __getitem__(self, i):
        return self._list[i]


class Curve:
    """`bpy.data.curves[name]` — the datablock, independent of any object."""

    __slots__ = ("name", "type", "dimensions", "splines", "bevel_depth",
                 "bevel_resolution", "resolution_u", "extrude", "fill_mode",
                 "use_fill_caps", "bevel_object", "taper_object", "materials")

    def __init__(self, name, kind="CURVE"):
        self.name = name
        self.type = kind
        self.dimensions = "2D"
        self.splines = _Splines()
        self.bevel_depth = 0.0
        self.bevel_resolution = 4
        self.resolution_u = 12
        self.extrude = 0.0
        self.fill_mode = "FULL"
        self.use_fill_caps = False
        self.bevel_object = None
        self.taper_object = None
        self.materials = []

    @property
    def users(self):
        return sum(1 for o in _CURVE_OBJECTS.values() if o.data is self)

    def _polyline(self):
        """Every spline flattened to a single list of world-space points."""
        pts = []
        for sp in self.splines:
            co = sp._coords()
            if sp.use_cyclic_u and co:
                co = co + [co[0]]
            pts.extend(co)
        return pts

    def __repr__(self):
        return '<bpy_struct, Curve("{}")>'.format(self.name)


class _Curves:
    """`bpy.data.curves`."""

    def __init__(self):
        self._store = {}

    def new(self, name, type="CURVE"):
        base, n = name, 1
        while name in self._store:
            name = "{}.{:03d}".format(base, n)
            n += 1
        c = Curve(name, type)
        self._store[name] = c
        return c

    def remove(self, curve, **kw):
        self._store.pop(getattr(curve, "name", str(curve)), None)

    def get(self, key, default=None):
        return self._store.get(key, default)

    def __getitem__(self, key):
        if isinstance(key, int):
            return list(self._store.values())[key]
        return self._store[key]

    def __contains__(self, key):
        return key in self._store

    def __iter__(self):
        return iter(list(self._store.values()))

    def __len__(self):
        return len(self._store)

    def keys(self):
        return list(self._store)

    def __repr__(self):
        return "<bpy_collection[{}], BlendDataCurves>".format(len(self))


class _CurveObject:
    """An object whose data is a curve.

    Blender Local's engine has nowhere to put one, so it stays here: visible to
    `bpy.data.objects` and usable as a modifier target, but not drawn. That is
    close to what a chain path looks like in Blender anyway — the curve is
    scaffolding, and only the geometry arrayed along it is meant to be seen.
    """

    def __init__(self, name, data):
        self.name = name
        self.data = data
        self.type = "CURVE"
        self.location = Vector((0.0, 0.0, 0.0))
        self.rotation_euler = Euler((0.0, 0.0, 0.0))
        self.scale = Vector((1.0, 1.0, 1.0))
        self.hide_viewport = False
        self._linked = False
        self._selected = False

    def select_set(self, state):
        self._selected = bool(state)

    def select_get(self):
        return self._selected

    def __repr__(self):
        return '<bpy_struct, Object("{}")>'.format(self.name)


def _curve_world_points(curve_object):
    """The curve's points in world space — its own transform folded in."""
    pts = curve_object.data._polyline()
    ox, oy, oz = curve_object.location
    sx, sy, sz = curve_object.scale
    return [(ox + x * sx, oy + y * sy, oz + z * sz) for x, y, z in pts]


class _Meshes:
    """`bpy.data.meshes` — one mesh datablock per object, named after it.

    Blender lets a mesh outlive its object, which is why cleanup scripts sweep
    this collection for zero-user datablocks. Here a mesh only exists while its
    object does, so `users` is always 1 and the sweep finds nothing to do —
    which is the correct answer, not a stub.
    """

    def _names(self):
        return _bk.object_names()

    def __getitem__(self, key):
        names = self._names()
        if isinstance(key, int):
            return Mesh(names[key])
        if key not in names:
            raise KeyError('bpy_prop_collection[key]: key "{}" not found'.format(key))
        return Mesh(key)

    def get(self, key, default=None):
        try:
            return self[key]
        except (KeyError, IndexError):
            return default

    def __contains__(self, key):
        return key in self._names()

    def __iter__(self):
        return (Mesh(n) for n in self._names())

    def __len__(self):
        return len(self._names())

    def keys(self):
        return list(self._names())

    def values(self):
        return list(self)

    def items(self):
        return [(n, Mesh(n)) for n in self._names()]

    def remove(self, mesh, **kw):
        _bk.remove(getattr(mesh, "name", str(mesh)))

    def new(self, name):
        return Mesh(name)

    def __repr__(self):
        return "<bpy_collection[{}], BlendDataMeshes>".format(len(self))



# ---------------------------------------------------------------------------
# Array-along-a-curve
#
# In Blender an Array modifier set to FIT_CURVE paired with a Curve modifier
# repeats geometry along a path — the standard way to build a chain, a fence or
# a string of beads. Both halves depend on a curve, which the engine has no
# notion of, so the pair is evaluated here and baked into real geometry the
# moment it is fully configured: the copies are placed along the path and
# joined back into the source object, so the object keeps its name and picks up
# any material assigned afterwards.
#
# The one place this differs from Blender is that the result is baked, not
# live: moving the curve afterwards will not drag the geometry with it.
# ---------------------------------------------------------------------------

_CURVE_MODS = {}         # (object, modifier) -> settings held on this side
_CURVE_MOD_ORDER = {}    # object -> Curve-modifier names, in stack order
_BAKED = set()           # objects already baked, so it happens once

_DEFORM_AXES = {"POS_X": (1.0, 0.0, 0.0), "POS_Y": (0.0, 1.0, 0.0),
                "POS_Z": (0.0, 0.0, 1.0), "NEG_X": (-1.0, 0.0, 0.0),
                "NEG_Y": (0.0, -1.0, 0.0), "NEG_Z": (0.0, 0.0, -1.0)}


def _curve_mod_set(obj, mod, kind, key, value, rebake=True):
    state = _CURVE_MODS.setdefault((obj, mod), {"kind": kind})
    state[key] = value
    if rebake:
        _try_bake_along_curve(obj)


def _try_bake_along_curve(obj):
    """Bake if an Array(FIT_CURVE) and a Curve modifier are both ready."""
    if obj in _BAKED:
        return
    array = curve_mod = array_name = None
    for (o, name), st in _CURVE_MODS.items():
        if o != obj:
            continue
        if st.get("kind") == "array" and st.get("curve") is not None \
                and st.get("fit_type") == "FIT_CURVE":
            array, array_name = st, name
        elif st.get("kind") == "curve" and st.get("object") is not None:
            curve_mod = st
    if array is None or curve_mod is None:
        return
    _BAKED.add(obj)
    try:
        _bake_along_curve(obj, array, curve_mod, array_name)
    except Exception as exc:            # a bake failure must not kill the script
        _BAKED.discard(obj)
        print("array-along-curve: {}".format(exc))


def _resample(points, distance):
    """Position and unit tangent at `distance` along a polyline."""
    travelled = 0.0
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        seg = Vector(b) - Vector(a)
        length = seg.length
        if length < 1e-9:
            continue
        if travelled + length >= distance or i == len(points) - 2:
            t = (distance - travelled) / length
            t = max(0.0, min(1.0, t))
            pos = Vector(a) + seg * t
            return pos, seg.normalized()
        travelled += length
    last = Vector(points[-1])
    return last, Vector((1.0, 0.0, 0.0))


def _polyline_length(points):
    return sum((Vector(points[i + 1]) - Vector(points[i])).length
               for i in range(len(points) - 1))


def _bake_along_curve(obj, array, curve_mod, array_name=None):
    path = curve_mod["object"]
    pts = _curve_world_points(path) if isinstance(path, _CurveObject) else []
    if len(pts) < 2:
        raise ValueError("the Curve modifier's object has no usable path")

    axis_name = curve_mod.get("deform_axis", "POS_X")
    axis = Vector(_DEFORM_AXES.get(axis_name, (1.0, 0.0, 0.0)))
    ai = "XYZ".index(axis_name[-1])

    # How long one copy is along the deform axis, and how far apart they sit.
    lo = _bk.bounds(obj)
    span = abs(lo[ai + 3] - lo[ai])
    offsets = array.get("relative_offset_displace", [1.0, 0.0, 0.0])
    step = span * (offsets[ai] if ai < len(offsets) else 1.0)
    if step <= 1e-6:
        raise ValueError("the array's spacing works out to zero")

    total = _polyline_length(pts)
    count = max(1, int(round(total / step)))

    # The source object becomes the first copy; the rest are duplicates of it,
    # so they carry whatever geometry it has rather than assuming a shape.
    before = set(_bk.object_names())
    _bk.select_all(0)
    _bk.select(obj, 1)
    for _ in range(count - 1):
        _bk.duplicate_selected()
        _bk.select_all(0)
        _bk.select(obj, 1)
    made = [n for n in _bk.object_names() if n not in before]
    copies = [obj] + made[:count - 1]

    for i, name in enumerate(copies):
        pos, tangent = _resample(pts, (i + 0.5) * step)
        _bk.set_vec(name, "location", pos[0], pos[1], pos[2])
        rot = axis.rotation_difference(tangent).to_euler()
        _bk.set_vec(name, "rotation_euler", rot[0], rot[1], rot[2])

    # The engine still carries the Array modifier the script added, and it
    # would repeat the baked chain all over again on top of this. The array has
    # been evaluated here, so take it off — the same thing applying a modifier
    # does.
    if array_name:
        try:
            _bk.modifier_remove(obj, array_name)
        except Exception:
            pass

    # Join them back into one object so the result keeps the source's name and
    # any material the script assigns after setting the modifiers up.
    if len(copies) > 1:
        _bk.select_all(0)
        for name in copies:
            _bk.select(name, 1)
        _bk.set_active(obj)
        _bk.join_selected()


class _Data:
    objects = _Objects()
    scenes = _Scenes()
    materials = _Materials()
    curves = _Curves()
    meshes = _Meshes()

    filepath = ""

    def __repr__(self):
        return "<bpy.data>"


class _App:
    """`bpy.app` — version numbers scripts branch on."""
    version = (4, 2, 0)
    version_string = "4.2.0 (Blender Local shim)"
    binary_path = ""
    background = False

    class _Handlers:
        def __getattr__(self, name):
            raise NotImplementedError(
                "bpy.app.handlers is not implemented in Blender Local")

    handlers = _Handlers()


class _MeshOps:
    """`bpy.ops.mesh` — the primitive_*_add operators and, once in edit mode,
    the mesh-editing operators mixed in from _EditMeshOps.

    Signatures accept the keyword arguments Blender's operators take so pasted
    scripts work; the ones Blender Local has no concept of are accepted and
    ignored rather than raising.
    """

    # The engine builds every primitive at Blender's default dimensions —
    # a 2m cube, a radius-1 depth-2 cylinder — so a requested size becomes a
    # scale factor against that, baked into the mesh the way Blender bakes it.
    @staticmethod
    def _add(kind, location, scale=(1.0, 1.0, 1.0), rotation=(0.0, 0.0, 0.0)):
        loc = tuple(float(c) for c in location) if location else (0.0, 0.0, 0.0)
        _bk.add_primitive(kind, *loc)
        name = _bk.active_name()
        scale = tuple(float(c) for c in scale)
        if any(abs(c - 1.0) > 1e-9 for c in scale):
            if not name:
                return {"FINISHED"}
            # Blender leaves a freshly added primitive at scale 1 with the size
            # already in its vertices, so bake it rather than leaving a scale on
            # the object — a script that reads `obj.scale` expects (1, 1, 1),
            # and an unbaked scale would compound with any it sets later.
            after_add = [n for n in _bk.object_names() if _bk.is_selected(n)]
            _bk.set_vec(name, "scale", *scale)
            _bk.select_all(0)
            _bk.select(name, 1)
            _bk.object_op("transform_apply", 4.0)   # scale only
            _bk.select_all(0)
            for n in after_add:
                _bk.select(n, 1)
            _bk.set_active(name)
        # Every primitive operator takes `rotation`, and dropping it is not a
        # harmless simplification: a torus added with rotation=(pi/2, 0, 0) is
        # a wheel standing up, and without it the same call lays it flat. It is
        # set after the size is baked so it stays on the object, where Blender
        # leaves it.
        rot = tuple(float(c) for c in rotation) if rotation else (0.0, 0.0, 0.0)
        if name and any(abs(c) > 1e-9 for c in rot):
            _bk.set_vec(name, "rotation_euler", *rot)
        return {"FINISHED"}

    def primitive_plane_add(self, size=2.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        f = size / 2.0
        return self._add("plane", location, (f, f, 1.0), rotation)

    def primitive_cube_add(self, size=2.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        f = size / 2.0
        return self._add("cube", location, (f, f, f), rotation)

    def primitive_circle_add(self, radius=1.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        return self._add("circle", location, (radius, radius, 1.0), rotation)

    def primitive_uv_sphere_add(self, radius=1.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        return self._add("uv_sphere", location, (radius, radius, radius), rotation)

    def primitive_ico_sphere_add(self, radius=1.0, subdivisions=2,
                                 location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        return self._add("ico_sphere", location, (radius, radius, radius), rotation)

    def primitive_grid_add(self, size=2.0, x_subdivisions=10,
                           y_subdivisions=10, location=(0, 0, 0),
                           rotation=(0, 0, 0), **kw):
        f = size / 2.0
        return self._add("grid", location, (f, f, 1.0), rotation)

    def primitive_monkey_add(self, size=2.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        # Suzanne's mesh is a Blender datafile. The shim substitutes a sphere;
        # the real backend has the actual monkey.
        f = size / 2.0
        return self._add("monkey", location, (f, f, f), rotation)

    def primitive_cylinder_add(self, radius=1.0, depth=2.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        return self._add("cylinder", location, (radius, radius, depth / 2.0), rotation)

    def primitive_cone_add(self, radius1=1.0, depth=2.0, location=(0, 0, 0), rotation=(0, 0, 0), **kw):
        return self._add("cone", location, (radius1, radius1, depth / 2.0), rotation)

    def primitive_torus_add(self, location=(0, 0, 0), major_radius=1.0,
                            minor_radius=0.25, major_segments=48,
                            minor_segments=12, rotation=(0, 0, 0), **kw):
        # A torus is the one primitive whose two radii are independent, so no
        # scaling of the default one produces an arbitrary ring — it is built
        # to the requested proportions instead.
        loc = tuple(float(c) for c in location) if location else (0.0, 0.0, 0.0)
        name = _bk.add_torus(loc[0], loc[1], loc[2],
                             float(major_radius), float(minor_radius),
                             int(major_segments), int(minor_segments))
        rot = tuple(float(c) for c in rotation) if rotation else (0.0, 0.0, 0.0)
        if name and any(abs(c) > 1e-9 for c in rot):
            _bk.set_vec(name, "rotation_euler", *rot)
        return {"FINISHED"}


class _ObjectOps:
    def delete(self, use_global=False, confirm=True, **kw):
        _bk.delete_selected()
        # Curve objects live on this side, so the engine's delete cannot see
        # them. Without this, "select all and delete" quietly leaves them.
        for name in [n for n, o in _CURVE_OBJECTS.items()
                     if o._linked and o._selected]:
            del _CURVE_OBJECTS[name]
        return {"FINISHED"}

    def duplicate(self, linked=False, **kw):
        """`bpy.ops.object.duplicate()` — copies the selection in place.

        Blender offers both this and `duplicate_move`; the latter is the
        keyboard shortcut's macro, which duplicates and then starts a move.
        With no interactive move to start, they do the same thing here."""
        _bk.duplicate_selected()
        return {"FINISHED"}

    def duplicate_move(self, **kw):
        _bk.duplicate_selected()
        return {"FINISHED"}

    def modifier_add(self, type="SUBSURF", **kw):
        """Adds to every selected object, as Blender's operator does."""
        names = [n for n in _bk.object_names() if _bk.is_selected(n)]
        if not names:
            return {"CANCELLED"}
        for n in names:
            _bk.modifier_add(n, type)
        return {"FINISHED"}

    def modifier_apply(self, modifier="", **kw):
        _bk.modifier_apply(modifier)
        return {"FINISHED"}

    def modifier_remove(self, modifier="", **kw):
        active = _bk.active_name()
        if not active:
            return {"CANCELLED"}
        _bk.modifier_remove(active, modifier)
        return {"FINISHED"}

    def mode_set_sculpt(self, **kw):
        _bk.set_mode("SCULPT")
        return {"FINISHED"}

    def shade_smooth(self, **kw):
        _bk.object_shade(True)
        return {"FINISHED"}

    def shade_flat(self, **kw):
        _bk.object_shade(False)
        return {"FINISHED"}

    def join(self, **kw):
        """Blender merges the selection into the active object."""
        _bk.join_selected()
        return {"FINISHED"}

    def select_random(self, ratio=0.5, seed=0, action="SELECT", **kw):
        _bk.object_op("select_random", float(ratio)); return {"FINISHED"}

    def location_clear(self, clear_delta=False, **kw):
        _bk.object_op("location_clear"); return {"FINISHED"}

    def rotation_clear(self, clear_delta=False, **kw):
        _bk.object_op("rotation_clear"); return {"FINISHED"}

    def scale_clear(self, clear_delta=False, **kw):
        _bk.object_op("scale_clear"); return {"FINISHED"}

    def transform_apply(self, location=True, rotation=True, scale=True, **kw):
        """Bakes the chosen channels into the mesh, as Blender does.

        Which channels is not a detail: `transform_apply(scale=True)` has to
        leave the origin where it is, or anything rotated afterwards turns
        about the world centre instead of about itself.

        Meshes only. A camera or a point, sun or spot light is left alone, as
        Blender leaves it. An empty and an area light are refused: Blender
        bakes their scale into `empty_display_size` and the light's size
        (measured in 5.2.1: scale (1,2,3) made an empty's display size 1 into
        3, and a square area light a 1 x 2 rectangle), which the shim does not
        model — and doing nothing to them would answer FINISHED for a change
        that never happened."""
        mask = (1 if location else 0) | (2 if rotation else 0) | (4 if scale else 0)
        if mask == 0:
            return {"CANCELLED"}
        chosen = context.selected_objects
        for obj in chosen:
            if obj.type == 'LIGHT' and obj.data.type == 'AREA' and (location or rotation):
                # Blender's own refusal, word for word (measured).
                raise RuntimeError('Error: Area Lights can only have scale applied: "%s"' % obj.name)
        unmodelled = [obj.name for obj in chosen
                      if obj.type == 'EMPTY' or (obj.type == 'LIGHT' and obj.data.type == 'AREA')]
        if unmodelled:
            raise NotImplementedError(
                "the simulator applies transforms to meshes only, not to %s"
                % ", ".join('"%s"' % n for n in unmodelled))
        if not any(obj.type == 'MESH' for obj in chosen):
            return {"CANCELLED"}
        # None baked is Blender's CANCELLED: a zero scale under Apply Rotation
        # is skipped there, and here (BKScene.bakeSelectedTransforms).
        baked = _bk.object_op("transform_apply", float(mask))
        return {"FINISHED"} if baked > 0 else {"CANCELLED"}

    def origin_set(self, type="ORIGIN_GEOMETRY", center="MEDIAN", **kw):
        """Only Origin to Geometry about the median is real here.

        The shim shifts the mesh so the median of its vertices sits at the
        object's origin, which is `ORIGIN_GEOMETRY` with `center='MEDIAN'` and
        nothing else. A centre of mass weights by face area and a bounds centre
        is the middle of the bounding box: measured in Blender 5.2.1 on a cube
        at (1,0,0) with one vertex 30 units out, `ORIGIN_GEOMETRY` put the
        origin at x=4.333 for MEDIAN and x=15.5 for BOUNDS. This used to accept
        `ORIGIN_CENTER_OF_MASS` and swallow `center=` entirely, so it answered
        three of the five types with the median — a wrong origin returned as a
        right one. Refusing says "unsupported", which is true."""
        if type != "ORIGIN_GEOMETRY" or center != "MEDIAN":
            raise NotImplementedError(
                "only origin_set(type='ORIGIN_GEOMETRY', center='MEDIAN') is implemented")
        _bk.object_op("origin_set"); return {"FINISHED"}

    # As Blender's (measured in 5.2.1): Hide deselects what it hides, Show
    # Hidden selects what it shows unless told not to, and each returns
    # CANCELLED when there was nothing to do. `amount` carries the flag.
    def hide_view_set(self, unselected=False, **kw):
        changed = _bk.object_op("hide_view_set", 1.0 if unselected else 0.0)
        return {"FINISHED"} if changed > 0 else {"CANCELLED"}

    def hide_view_clear(self, select=True, **kw):
        changed = _bk.object_op("hide_view_clear", 1.0 if select else 0.0)
        return {"FINISHED"} if changed > 0 else {"CANCELLED"}

    # Offered by the interface and performed by the real module on device.
    # Named here so the simulator says which one it cannot do.
    def shade_auto_smooth(self, **kw):
        raise NotImplementedError(
            "auto smooth adds a Geometry Nodes modifier; the real bpy on device has them")

    def shade_smooth_by_angle(self, **kw):
        raise NotImplementedError(
            "smoothing by angle marks sharp edges, which are not stored here")

    def quadriflow_remesh(self, **kw):
        raise NotImplementedError(
            "QuadriFlow rebuilds the surface in quads; the real bpy on device has it")

    def text_add(self, **kw):
        raise NotImplementedError(
            "text objects are drawn by the real bpy on device, not by the simulator's stand-in")

    # The Object menu's Duplicate Linked, Parent and Convert rows: data shared
    # between objects, a hierarchy and object types other than meshes are
    # the real module's (the Outliner's tree reads Blender's parents, which
    # this stand-in has none of). Join it models.
    def duplicate_move_linked(self, **kw):
        raise NotImplementedError(
            "linked duplicates share their mesh; the real bpy on device has them")

    def parent_set(self, **kw):
        raise NotImplementedError(
            "parenting needs object hierarchies; the real bpy on device has them")

    def parent_clear(self, **kw):
        raise NotImplementedError(
            "parenting needs object hierarchies; the real bpy on device has them")

    def convert(self, target="MESH", **kw):
        raise NotImplementedError(
            "converting between object types needs the real bpy on device")

    # CANCELLED past either end, as Blender's are (measured in 5.2.1: "Cannot
    # move modifier beyond the start of the list"); the row raises on it.
    def modifier_move_up(self, modifier="", **kw):
        moved = _bk.object_op("modifier_move_up", _modifier_index(modifier))
        return {"FINISHED"} if moved else {"CANCELLED"}

    def modifier_move_down(self, modifier="", **kw):
        moved = _bk.object_op("modifier_move_down", _modifier_index(modifier))
        return {"FINISHED"} if moved else {"CANCELLED"}

    # Multiresolution's operators. Subdivide adds a level and raises the three
    # levels to it, as Blender's does outside sculpt mode (measured in 5.2.1:
    # 1 1 1 1, then 2 2 2 2); Delete Higher drops the levels above the
    # viewport level. The other two rebuild or reshape the mesh from its
    # multires grids, which this stand-in does not keep.
    def multires_subdivide(self, modifier="Multires", mode="CATMULL_CLARK", **kw):
        _bk.modifier_set(_bk.active_name(), _active_modifier(modifier, "MULTIRES"),
                         "multires_subdivide", 0.0, 0.0, 0.0)
        return {"FINISHED"}

    def multires_higher_levels_delete(self, modifier="Multires", **kw):
        _bk.modifier_set(_bk.active_name(), _active_modifier(modifier, "MULTIRES"),
                         "multires_delete_higher", 0.0, 0.0, 0.0)
        return {"FINISHED"}

    def multires_unsubdivide(self, modifier="Multires", **kw):
        raise NotImplementedError(
            "Unsubdivide rebuilds levels from the mesh's subdivision grids; the real bpy on device has it")

    def multires_base_apply(self, modifier="Multires", **kw):
        raise NotImplementedError(
            "Apply Base reshapes the base mesh from its multires grids; the real bpy on device has it")

    def mode_set(self, mode="OBJECT", **kw):
        _bk.set_mode(mode)
        return {"FINISHED"}

    def _select_all_curves(self, action):
        for obj in _CURVE_OBJECTS.values():
            if not obj._linked:
                continue
            if action == "SELECT":
                obj._selected = True
            elif action == "DESELECT":
                obj._selected = False
            elif action == "INVERT":
                obj._selected = not obj._selected
            elif action == "TOGGLE":
                obj._selected = not obj._selected

    def select_all(self, action="SELECT", **kw):
        if action == "DESELECT":
            _bk.select_all(False)
        elif action == "SELECT":
            _bk.select_all(True)
        elif action in ("INVERT", "TOGGLE"):
            # No bulk invert on the bridge, so flip each object in turn.
            for name in _bk.object_names():
                _bk.select(name, not _bk.is_selected(name))
        self._select_all_curves(action)
        return {"FINISHED"}


# Arguments Blender's transform operators take that change nothing here: the
# modal ones (a bpy module never runs the modal path) and the snapping details,
# which mean nothing without `snap=True`.
_TRANSFORM_IGNORED = frozenset((
    'release_confirm', 'use_accurate', 'alt_navigation', 'remove_on_cancel',
    'view2d_edge_pan', 'use_duplicated_keyframes', 'mouse_dir_constraint',
    'snap_elements', 'snap_target', 'use_snap_self', 'use_snap_edit',
    'use_snap_nonedit', 'use_snap_selectable', 'snap_point', 'snap_normal',
    'orient_axis_ortho', 'constraint_axis'))
# Arguments that would do something the stand-in does not model. At their
# defaults they are accepted; set, the call is refused rather than run as
# something else.
_TRANSFORM_REFUSED = frozenset((
    'mirror', 'snap', 'use_snap_project', 'snap_align', 'use_proportional_projected',
    'gpencil_strokes', 'cursor_transform', 'texture_space', 'use_automerge_and_split',
    'translate_origin'))


class _TransformOps:
    """`bpy.ops.transform` — the operation the 3D View's gizmo previews.

    translate, rotate and resize reduce their arguments to world-space values
    and hand them to TransformOperation (`_bk.transform_operator`), the Swift the
    gizmo's live preview runs, so a drag in the simulator commits what it
    showed. Before this they took **kw and dropped `center_override` and every
    proportional argument: rotate and resize acted in place whatever the pivot,
    and proportional editing previewed a pull the commit never made.

    `constraint_axis` is not applied to `value`, because Blender's exec path
    does not: measured in 5.2.1, translate(value=(1, 2, 3),
    constraint_axis=(True, False, False)) moved a cube to (1, 2, 3), and
    resize(value=(2, 3, 4)) with the same constraint scaled it (2, 3, 4).
    """

    @staticmethod
    def _call(name, kind, value, kw, axis=None, orientation='GLOBAL'):
        import json
        center = kw.pop('center_override', None)
        proportional = None
        use = kw.pop('use_proportional_edit', False)
        falloff = kw.pop('proportional_edit_falloff', 'SMOOTH')
        size = kw.pop('proportional_size', 1.0)
        connected = kw.pop('use_proportional_connected', False)
        if use:
            proportional = {'falloff': str(falloff), 'size': float(size),
                            'connected': bool(connected)}
        for key, given in kw.items():
            if key in _TRANSFORM_IGNORED:
                continue
            if key in _TRANSFORM_REFUSED:
                if given:
                    raise RuntimeError("bpy.ops.transform.%s: %s=%r is not modelled by the "
                                       "simulator's stand-in" % (name, key, given))
                continue
            raise TypeError('Converting py args to operator properties: keyword "%s" '
                            'unrecognized' % key)
        # Tool settings Blender's transform reads from the scene that this
        # stand-in does not model: refused, as the arguments above are.
        # (Skipped where there are no tool settings to read: the animation
        # suite's stand-in for _blenderkit has none.)
        if hasattr(_bk, 'tool_state_get'):
            state = _tool_state()
            editing = getattr(_bk, 'mode', lambda: 'OBJECT')() == 'EDIT'
            for flag, applies in (('use_transform_data_origin', not editing),
                                  ('use_mesh_automerge_and_split', editing and state['automerge'])):
                if applies and state['snap_flags'] & (1 << _TOOL_SNAP_FLAGS.index(flag)):
                    raise RuntimeError("bpy.ops.transform.%s: tool_settings.%s is not modelled by "
                                       "the simulator's stand-in" % (name, flag))
        call = {'kind': kind, 'value': list(value), 'orientation': orientation,
                'center': [float(c) for c in center] if center is not None else None,
                'proportional': proportional}
        if axis is not None:
            call['axis'] = [float(c) for c in axis]
        _bk.transform_operator(json.dumps(call))
        return {"FINISHED"}

    @staticmethod
    def _orientation(name, orient_type, orient_matrix, supported):
        if orient_type not in supported:
            raise RuntimeError("bpy.ops.transform.%s: orient_type=%r is not modelled by the "
                               "simulator's stand-in" % (name, orient_type))
        if orient_type == 'VIEW' and orient_matrix is None:
            # A headless Blender has no view to take one from either.
            raise RuntimeError("bpy.ops.transform.%s: orient_type='VIEW' needs an "
                               "orient_matrix here" % name)

    def translate(self, value=(0, 0, 0), orient_type='GLOBAL', orient_matrix=None,
                  orient_matrix_type=None, **kw):
        self._orientation('translate', orient_type, orient_matrix, ('GLOBAL', 'VIEW'))
        v = [float(c) for c in value]
        if orient_type == 'VIEW':
            # The matrix's rows are the orientation's axes. Measured in 5.2.1:
            # value=(1, 2, 3) with rows (0,1,0), (-1,0,0), (0,0,1) moved a
            # cube to (-2, 1, 3).
            rows = [[float(c) for c in row] for row in orient_matrix]
            v = [sum(v[i] * rows[i][k] for i in range(3)) for k in range(3)]
        return self._call('translate', 'translate', v, kw)

    def rotate(self, value=0.0, orient_axis="Z", orient_type='GLOBAL', orient_matrix=None,
               orient_matrix_type=None, **kw):
        self._orientation('rotate', orient_type, orient_matrix, ('GLOBAL', 'VIEW'))
        index = {"X": 0, "Y": 1, "Z": 2}.get(orient_axis)
        if index is None:
            raise TypeError('enum "%s" not found in (\'X\', \'Y\', \'Z\')' % orient_axis)
        if orient_type == 'VIEW':
            axis = [float(c) for c in orient_matrix[index]]
        else:
            axis = [1.0 if k == index else 0.0 for k in range(3)]
        return self._call('rotate', 'rotate', [float(value)], kw, axis=axis)

    def resize(self, value=(1, 1, 1), orient_type='GLOBAL', orient_matrix=None,
               orient_matrix_type=None, **kw):
        self._orientation('resize', orient_type, orient_matrix, ('GLOBAL', 'LOCAL'))
        return self._call('resize', 'resize', [float(c) for c in value], kw,
                          orientation=orient_type)

    def mirror(self, constraint_axis=(True, False, False), **kw):
        """Blender mirrors by negating scale on the constrained axis."""
        axis = 0
        for i, on in enumerate(tuple(constraint_axis)[:3]):
            if on:
                axis = i
                break
        _bk.object_op(("mirror_x", "mirror_y", "mirror_z")[axis])
        return {"FINISHED"}

    def vertex_random(self, offset=0.0, uniform=0.0, normal=0.0, seed=0, **kw):
        """`bpy.ops.transform.vertex_random` — jitters the selected vertices."""
        _bk.mesh_op("vertex_random", offset)
        return {"FINISHED"}

    def shrink_fatten(self, value=0.0, **kw):
        """`bpy.ops.transform.shrink_fatten` — moves the selection along its normals."""
        _bk.mesh_op("shrink_fatten", float(value))
        return {"FINISHED"}

    def push_pull(self, value=0.0, **kw):
        """`bpy.ops.transform.push_pull` — toward the median point, or away."""
        _bk.mesh_op("push_pull", float(value))
        return {"FINISHED"}

    def tosphere(self, value=0.0, **kw):
        """`bpy.ops.transform.tosphere` — blends the selection onto a sphere."""
        _bk.mesh_op("tosphere", float(value))
        return {"FINISHED"}

    # The Mesh menu's edge tools. Each slides along, or writes to, the edges
    # beside a vertex, and this stand-in's mesh is triangles with no edges of
    # their own; named so the simulator says which tool it cannot do rather
    # than raising AttributeError about `_TransformOps`.
    def edge_slide(self, **kw):
        raise NotImplementedError(
            "edge slide needs a half-edge mesh; the real bpy on device has it")

    def vert_slide(self, **kw):
        raise NotImplementedError(
            "vertex slide needs a half-edge mesh; the real bpy on device has it")

    def edge_crease(self, **kw):
        raise NotImplementedError("edge attributes are not stored here")

    def edge_bevelweight(self, **kw):
        raise NotImplementedError("edge attributes are not stored here")

    def shear(self, **kw):
        raise NotImplementedError(
            "shear runs through Blender's 3D View; the real bpy on device has it")


class _WmOps:
    def read_homefile(self, **kw):
        _bk.select_all(True)
        _bk.delete_selected()
        _bk.add_primitive("cube", 0.0, 0.0, 0.0)
        return {"FINISHED"}


class _EditMeshOps:
    """`bpy.ops.mesh` operators that need edit mode."""

    def _select_all_curves(self, action):
        for obj in _CURVE_OBJECTS.values():
            if not obj._linked:
                continue
            if action == "SELECT":
                obj._selected = True
            elif action == "DESELECT":
                obj._selected = False
            elif action == "INVERT":
                obj._selected = not obj._selected
            elif action == "TOGGLE":
                obj._selected = not obj._selected

    def select_all(self, action="SELECT", **kw):
        _bk.mesh_select_all(action != "DESELECT")
        return {"FINISHED"}

    def extrude_region_move(self, TRANSFORM_OT_translate=None, **kw):
        # Blender passes the move as a nested operator dictionary; the distance
        # along the face normal is what Blender Local uses.
        amount = 0.4
        if TRANSFORM_OT_translate:
            value = TRANSFORM_OT_translate.get("value")
            if value:
                amount = max(abs(c) for c in value) or 0.4
        _bk.mesh_op("extrude", amount)
        return {"FINISHED"}

    def inset(self, thickness=0.3, depth=0.0, use_individual=False, **kw):
        """Blender's operator is `mesh.inset`, not `inset_faces`.

        Individual is refused rather than ignored: the engine insets the
        selection as one region, and answering FINISHED for it would show
        a region inset under a redo panel that says Individual."""
        if use_individual:
            raise NotImplementedError(
                "Inset Individual needs the real bpy on device; the simulator "
                "insets the selection as one region")
        _bk.mesh_op("inset", thickness)
        return {"FINISHED"}

    def extrude_faces_move(self, TRANSFORM_OT_shrink_fatten=None, **kw):
        """The offset is the macro's Shrink/Fatten value, as in Blender:
        positive moves the faces out along their normals (0.2 took a cube's
        top face from z = 1 to 1.2 in Blender 5.2.1). The engine takes 0 as
        its own default, so a zero offset is sent as the smallest one."""
        value = 0.0
        if TRANSFORM_OT_shrink_fatten:
            value = float(TRANSFORM_OT_shrink_fatten.get("value", 0.0))
        _bk.mesh_op("extrude_individual", value if value != 0.0 else 1e-6)
        return {"FINISHED"}

    def poke(self, **kw):
        _bk.mesh_op("poke", 0.0)
        return {"FINISHED"}

    def flip_normals(self, **kw):
        _bk.mesh_op("flip_normals", 0.0)
        return {"FINISHED"}

    def normals_make_consistent(self, inside=False, **kw):
        _bk.mesh_op("normals_make_consistent", 0.0)
        return {"FINISHED"}

    def merge(self, type="CENTER", threshold=0.0001, **kw):
        """Blender's Merge. `type='COLLAPSE'` and the distance variants both
        come down to welding, which is what remove_doubles does."""
        if type not in ("CENTER", "COLLAPSE", "FIRST", "LAST"):
            raise NotImplementedError("merge type %r needs a half-edge mesh" % type)
        _bk.mesh_op("remove_doubles", max(threshold, 1e-4))
        return {"FINISHED"}

    def separate(self, type="SELECTED", **kw):
        raise NotImplementedError(
            "separate needs per-object mesh splitting; the real bpy on device has it")

    def hide(self, unselected=False, **kw):
        raise NotImplementedError(
            "hiding mesh elements needs a half-edge mesh; the real bpy on device has it")

    def reveal(self, select=True, **kw):
        raise NotImplementedError(
            "hiding mesh elements needs a half-edge mesh; the real bpy on device has it")

    def symmetrize(self, direction="NEGATIVE_X", **kw):
        raise NotImplementedError(
            "symmetrize needs a half-edge mesh; the real bpy on device has it")

    # The Mesh menu's Split, clean-up, Un-Subdivide and Beautify rows. Each
    # works on edges and polygons this stand-in's triangle mesh does not have.
    def split(self, **kw):
        raise NotImplementedError("split needs a half-edge mesh; the real bpy on device has it")

    def edge_split(self, type="EDGE", **kw):
        raise NotImplementedError("edge split needs a half-edge mesh; the real bpy on device has it")

    def dissolve_limited(self, **kw):
        raise NotImplementedError("limited dissolve needs a half-edge mesh; the real bpy on device has it")

    def delete_loose(self, **kw):
        raise NotImplementedError("delete loose needs a half-edge mesh; the real bpy on device has it")

    def fill_holes(self, **kw):
        raise NotImplementedError("fill holes needs a half-edge mesh; the real bpy on device has it")

    def unsubdivide(self, **kw):
        raise NotImplementedError("un-subdivide needs a half-edge mesh; the real bpy on device has it")

    def beautify_fill(self, **kw):
        raise NotImplementedError("beautify needs a half-edge mesh; the real bpy on device has it")

    # Offered by the interface, and performed by the real module on device.
    # Named here so the simulator says which one it is rather than answering
    # with an AttributeError about an object nobody asked about.
    def spin(self, **kw):
        raise NotImplementedError(
            "spin needs a half-edge mesh; the real bpy on device has it")

    def solidify(self, thickness=0.01, **kw):
        raise NotImplementedError(
            "solidify needs a half-edge mesh; the real bpy on device has it")

    def wireframe(self, **kw):
        raise NotImplementedError(
            "wireframe needs a half-edge mesh; the real bpy on device has it")

    def edge_face_add(self, **kw):
        raise NotImplementedError(
            "building a face from a selection needs a half-edge mesh")

    def mark_seam(self, clear=False, **kw):
        raise NotImplementedError("edge attributes are not stored here")

    def mark_sharp(self, clear=False, use_verts=False, **kw):
        raise NotImplementedError("edge attributes are not stored here")

    def duplicate_move(self, **kw):
        raise NotImplementedError(
            "duplicating mesh elements needs a half-edge mesh")

    def remove_doubles(self, threshold=0.0001, **kw):
        merged = _bk.mesh_op("remove_doubles", threshold)
        return {"FINISHED"}

    def vertices_smooth(self, factor=0.5, repeat=1, **kw):
        for _ in range(max(1, int(repeat))):
            _bk.mesh_op("vertices_smooth", factor)
        return {"FINISHED"}

    def select_random(self, ratio=0.5, seed=0, action="SELECT", **kw):
        _bk.mesh_op("select_random", float(ratio)); return {"FINISHED"}

    def select_linked(self, delimit=None, **kw):
        _bk.mesh_op("select_linked", 0.0)
        return {"FINISHED"}

    def select_more(self, use_face_step=True, **kw):
        _bk.mesh_op("select_more", 0.0)
        return {"FINISHED"}

    def select_less(self, use_face_step=True, **kw):
        _bk.mesh_op("select_less", 0.0)
        return {"FINISHED"}

    def faces_shade_smooth(self, **kw):
        _bk.mesh_op("shade_smooth", 0.0)
        return {"FINISHED"}

    def faces_shade_flat(self, **kw):
        _bk.mesh_op("shade_flat", 0.0)
        return {"FINISHED"}

    def bevel(self, offset=0.1, segments=1, **kw):
        raise NotImplementedError(
            "bevel needs a half-edge mesh; the real bpy on device has it")

    def loopcut_slide(self, **kw):
        raise NotImplementedError(
            "loop cut needs a half-edge mesh; the real bpy on device has it")

    def knife_tool(self, **kw):
        raise NotImplementedError(
            "the knife needs a half-edge mesh; the real bpy on device has it")

    def quads_convert_to_tris(self, **kw):
        """The mesh is already triangles here, so this is a no-op."""
        return {"FINISHED"}

    def tris_convert_to_quads(self, **kw):
        raise NotImplementedError(
            "tris-to-quads needs a half-edge mesh; the real bpy on device has it")

    def select_edge_ring_multi(self, **kw):
        raise NotImplementedError(
            "edge rings need a half-edge mesh; the real bpy on device has it")

    def select_edge_loop_multi(self, **kw):
        raise NotImplementedError(
            "edge loops need a half-edge mesh; the real bpy on device has it")

    def vert_connect_path(self, **kw):
        raise NotImplementedError(
            "connecting vertices needs a half-edge mesh; the real bpy on device has it")

    def offset_edge_loops_slide(self, **kw):
        raise NotImplementedError(
            "offset edge loops need a half-edge mesh; the real bpy on device has it")

    def subdivide_edgering(self, **kw):
        raise NotImplementedError(
            "Loop Cut needs a half-edge mesh; the real bpy on device has it")

    def subdivide(self, number_cuts=1, **kw):
        for _ in range(max(1, int(number_cuts))):
            _bk.mesh_op("subdivide", 0.0)
        return {"FINISHED"}

    def delete(self, type="VERT", **kw):
        if type not in ("FACE", "VERT", "EDGE"):
            raise ValueError("unknown delete type: %s" % type)
        _bk.mesh_op({"FACE": "delete", "VERT": "delete_verts",
                     "EDGE": "delete_edges"}[type], 0.0)
        return {"FINISHED"}

    def _unused_delete(self, type="VERT", **kw):
        if type != "FACE":
            raise NotImplementedError(
                "only delete(type='FACE') is implemented; vertex and edge "
                "deletion need a half-edge mesh structure")
        _bk.mesh_op("delete", 0.0)
        return {"FINISHED"}

    def select_mode(self, type="VERT", **kw):
        return {"FINISHED"}

    def normals_make_consistent(self, inside=False, **kw):
        return {"FINISHED"}


class _UVOps:
    """`bpy.ops.uv` — the projection unwraps.

    Blender's `unwrap()` uses angle-based flattening, which solves over the
    whole mesh; these are projections, so they assign coordinates without
    solving and can overlap. The UV editor reports the resulting stretch.
    """

    @staticmethod
    def _project(kind):
        active = _bk.active_name()
        if not active:
            return {"CANCELLED"}
        count, stretch = _bk.uv_project(active, kind)
        return {"FINISHED"}

    def unwrap(self, method='ANGLE_BASED', **kw):
        return self._project("unwrap")

    def smart_project(self, **kw):
        return self._project("smart")

    def cube_project(self, **kw):
        return self._project("cube")

    def cylinder_project(self, **kw):
        return self._project("cylinder")

    def sphere_project(self, **kw):
        return self._project("sphere")

    # The rest of the UV Editor's menu needs Blender's islands — a packer, a
    # quad walker, per-corner UVs — which the stand-in's per-vertex projections
    # do not have. Saying so beats a projection passed off as the real thing.
    @staticmethod
    def _needs_blender(name):
        raise NotImplementedError(
            "uv.%s needs Blender's UV islands; the real bpy on device has it" % name)

    def follow_active_quads(self, **kw):
        self._needs_blender("follow_active_quads")

    def lightmap_pack(self, **kw):
        self._needs_blender("lightmap_pack")

    def pack_islands(self, **kw):
        self._needs_blender("pack_islands")

    def average_islands_scale(self, **kw):
        self._needs_blender("average_islands_scale")

    def seams_from_islands(self, **kw):
        self._needs_blender("seams_from_islands")

    def reset(self, **kw):
        self._needs_blender("reset")


class _PaintOps:
    """`bpy.ops.paint` — texture painting.

    Blender projects the brush through the view onto the surface; Blender Local
    paints at a UV, so `image_paint` takes the coordinate directly rather than
    a screen position.
    """

    def image_paint(self, u=0.5, v=0.5, color=None, radius=0.04, strength=0.8, **kw):
        active = _bk.active_name()
        if not active:
            return {"CANCELLED"}
        c = color or (1.0, 0.0, 0.0)
        _bk.paint(active, float(u), float(v), float(c[0]), float(c[1]), float(c[2]),
                  float(radius), float(strength))
        return {"FINISHED"}


class _RenderOps:
    def render(self, write_still=False, **kw):
        raise NotImplementedError(
            "this stand-in renders from the viewport, not from bpy; use "
            "More \u25b8 Render in the 3D View. The real module on an iPad "
            "renders with Cycles or Eevee")


def _active_modifier(name, type_):
    """`name` on the active object, checked to be a `type_` modifier — the
    operator's own refusal in Blender when it is not."""
    active = _bk.active_name()
    for entry in (_bk.modifier_list(active) if active else "").split("\n"):
        mod, _, kind = entry.partition("|")
        if mod == name and Modifier(active, mod, kind).type == type_:
            return mod
    raise RuntimeError("Error: Modifier \"%s\" is not a %s modifier on the active object"
                       % (name, type_.title()))


def _modifier_index(name):
    """Position of a modifier in the active object's stack, or -1."""
    try:
        active = _bk.active_name()
        raw = _bk.modifier_list(active) if active else ""
        names = [line.split("|", 1)[0] for line in (raw or "").split("\n") if line]
        return names.index(name)
    except (ValueError, RuntimeError):
        return -1


class _View3DOps:
    """`bpy.ops.view3d.*` — the viewport's own operators."""

    # `step` is this shim's, not Blender's: Blender's operator takes the grid
    # from the 3D View's own spacing, and the viewport here has its own
    # increment (ViewportOptions.snapIncrement) that _blenderkit_tools passes
    # on, so the simulator snaps to the same grid a device does.
    def snap_selected_to_grid(self, step=1.0, **kw):
        _bk.object_op("snap_selected_to_grid", float(step)); return {"FINISHED"}

    def snap_selected_to_cursor(self, use_offset=False, **kw):
        _bk.object_op("snap_selected_to_cursor", 1.0 if use_offset else 0.0)
        return {"FINISHED"}

    def snap_cursor_to_selected(self, **kw):
        _bk.object_op("snap_cursor_to_selected"); return {"FINISHED"}

    def snap_cursor_to_center(self, **kw):
        _bk.object_op("snap_cursor_to_center"); return {"FINISHED"}

    def snap_selected_to_active(self, **kw):
        _bk.object_op("snap_selected_to_active"); return {"FINISHED"}

    # `step` is this shim's, as for snap_selected_to_grid above.
    def snap_cursor_to_grid(self, step=1.0, **kw):
        _bk.object_op("snap_cursor_to_grid", float(step)); return {"FINISHED"}

    def snap_cursor_to_active(self, **kw):
        _bk.object_op("snap_cursor_to_active"); return {"FINISHED"}

    def copybuffer(self, **kw):
        _bk.object_op("copybuffer"); return {"FINISHED"}

    def pastebuffer(self, autoselect=True, active_collection=True, **kw):
        _bk.object_op("pastebuffer"); return {"FINISHED"}

    def view_all(self, center=False, **kw):
        """Framing is the viewport's business, not the scene's — this is a
        no-op here so a script written against Blender does not fail on it."""
        return {"FINISHED"}

    def view_axis(self, type="FRONT", **kw):
        return {"FINISHED"}


class _AnimOps:
    """`bpy.ops.anim.*` — keyframes on the selection."""

    def keyframe_insert_menu(self, type="LocRotScale", **kw):
        n = _bk.object_op("keyframe_insert_loc" if type == "Location" else "keyframe_insert")
        return {"FINISHED"} if n else {"CANCELLED"}

    def keyframe_insert(self, type="LocRotScale", **kw):
        return self.keyframe_insert_menu(type=type)

    def keyframe_delete_v3d(self, **kw):
        n = _bk.object_op("keyframe_delete")
        return {"FINISHED"} if n else {"CANCELLED"}


class _CurveOps:
    """`bpy.ops.curve`: the Add menu's two curves. The stand-in keeps curve
    data for a script's Array and Curve modifiers but cannot add a curve
    object to the scene or draw one."""

    def primitive_bezier_curve_add(self, **kw):
        raise NotImplementedError(
            "curve objects are drawn by the real bpy on device, not by the simulator's stand-in")

    def primitive_bezier_circle_add(self, **kw):
        raise NotImplementedError(
            "curve objects are drawn by the real bpy on device, not by the simulator's stand-in")


class _Ops:
    curve = _CurveOps()
    paint = _PaintOps()
    render = _RenderOps()
    uv = _UVOps()
    mesh = _MeshOps()
    object = _ObjectOps()
    transform = _TransformOps()
    view3d = _View3DOps()
    anim = _AnimOps()
    wm = _WmOps()

    def __repr__(self):
        return "<bpy.ops>"


class _Context:
    @property
    def object(self):
        """The *active* object — the last one selected, whose properties the
        editors show. Not simply the last object in the scene."""
        name = _bk.active_name()
        return Object(name) if name else None

    active_object = object

    @property
    def selected_objects(self):
        return [Object(n) for n in _bk.object_names() if _bk.is_selected(n)]

    # What Shade Auto Smooth's refusal reads. Nothing here is linked from a
    # library, so every selected object is an editable one.
    selected_editable_objects = selected_objects

    @property
    def visible_objects(self):
        return [Object(n) for n in _bk.object_names() if _bk.get_visible(n)]

    @property
    def scene(self):
        return _Scene()

    @property
    def mode(self):
        """`bpy.context.mode`. Reported as the mode actually in effect rather
        than "OBJECT" unconditionally, which is what it used to say."""
        return _bk.mode()

    @property
    def view_layer(self):
        """`bpy.context.view_layer` — the layer objects are evaluated in.

        Blender Local has exactly one, so this is a view onto the same scene
        the rest of `bpy.context` describes. Scripts reach for it mainly to set
        `view_layer.objects.active`, which is how you pick the object an
        operator will act on."""
        return _ViewLayer()

    @property
    def collection(self):
        """`bpy.context.collection` — the collection new objects are linked
        into. There is one, and it holds the whole scene."""
        return _Collection()

    def evaluated_depsgraph_get(self):
        """Blender returns the dependency graph used to evaluate modifiers. The
        shim has no graph, so this is a token that `evaluated_get` ignores."""
        return _Depsgraph()


class _ViewLayerObjects:
    """`view_layer.objects` — the scene's objects, plus the active one."""

    @property
    def active(self):
        name = _bk.active_name()
        return Object(name) if name else None

    @active.setter
    def active(self, obj):
        if obj is None:
            _bk.set_active("")
            return
        name = getattr(obj, "name", str(obj))
        if name in _CURVE_OBJECTS:
            # A curve object is not in the engine, so it cannot be active
            # there; the assignment is accepted and simply has no effect.
            return
        _bk.set_active(name)

    @property
    def selected(self):
        return [Object(n) for n in _bk.object_names() if _bk.is_selected(n)]

    def __iter__(self):
        return iter(_Data.objects)

    def __len__(self):
        return len(_Data.objects)

    def __getitem__(self, key):
        return _Data.objects[key]

    def get(self, key, default=None):
        return _Data.objects.get(key, default)

    def __contains__(self, key):
        return key in _Data.objects


class _ViewLayer:
    name = "ViewLayer"

    @property
    def objects(self):
        return _ViewLayerObjects()

    def update(self):
        """Blender re-evaluates the depsgraph here. Every change through this
        shim is applied as it is made, so there is nothing left to flush."""
        return None

    def __repr__(self):
        return '<bpy_struct, ViewLayer("ViewLayer")>'


class _CollectionObjects:
    """`collection.objects` — link() is how an unlinked object enters the
    scene, and the only reason most scripts touch a collection at all."""

    def link(self, obj):
        name = getattr(obj, "name", str(obj))
        if name in _CURVE_OBJECTS:
            _CURVE_OBJECTS[name]._linked = True
            return
        # Engine objects are linked the moment they are created.
        return None

    def unlink(self, obj):
        name = getattr(obj, "name", str(obj))
        if name in _CURVE_OBJECTS:
            _CURVE_OBJECTS[name]._linked = False
            return
        _bk.remove(name)

    def __iter__(self):
        return iter(_Data.objects)

    def __len__(self):
        return len(_Data.objects)

    def __getitem__(self, key):
        return _Data.objects[key]

    def get(self, key, default=None):
        return _Data.objects.get(key, default)

    def __contains__(self, key):
        return key in _Data.objects


class _Collection:
    name = "Collection"

    @property
    def objects(self):
        return _CollectionObjects()

    @property
    def children(self):
        return []

    def __repr__(self):
        return '<bpy_struct, Collection("Collection")>'


class _Depsgraph:
    def __repr__(self):
        return "<bpy_struct, Depsgraph (Blender Local shim)>"


class _Scene:
    name = "Scene"

    @property
    def frame_current(self):
        return _bk.set_frame(-1)

    @frame_current.setter
    def frame_current(self, value):
        _bk.set_frame(int(value))

    def frame_set(self, frame, subframe=0.0):
        """`scene.frame_set(n)` — how a script moves the playhead.

        Blender offers this as well as assigning `frame_current` because the
        method also re-evaluates the dependency graph. Setting the frame here
        already evaluates every object's animation, so the two are equivalent —
        but a script written against Blender calls this one.
        """
        _bk.set_frame(int(frame))
        return None

    @property
    def objects(self):
        return _Data.objects

    def __repr__(self):
        return 'bpy.data.scenes["Scene"]'


class types:
    Object = Object
    Mesh = Mesh


class utils:
    @staticmethod
    def register_class(cls):
        raise NotImplementedError(
            "Blender Local has no add-on system; register_class is unavailable")

    unregister_class = register_class


# Blender puts primitive adds and edit operators in the same bpy.ops.mesh
# namespace, so the two classes are merged onto one instance.
for _name in dir(_EditMeshOps):
    if not _name.startswith("_"):
        setattr(_MeshOps, _name, getattr(_EditMeshOps, _name))

# Cameras, lights and empties: installed onto the classes above by their own
# module (bpy/_objects.py), which wraps Object.type, Object.data and
# bpy.data.objects.new rather than replacing them.
from . import _objects

ops = _Ops()
data = _Data()
context = _Context()
app = _App()

types.Scene = _Scene


# ---------------------------------------------------------------------------
# The scene's animation settings
#
# Blender keeps the frame range, the rate, the preview range and the keying
# settings on the scene, and the timeline reads and writes them there. In the
# simulator they are Swift's (BKScene.animation), reached through
# `_bk.anim_state`, so a script and the timeline change the same values. The
# rules are Blender's: a start after the end drags the end along, and frames
# stop at 0 and 1048574.
# ---------------------------------------------------------------------------

_ANIM_FIELDS = ('start', 'end', 'current', 'subframe', 'fps', 'preview', 'preview_start',
                'preview_end', 'autokey', 'replace', 'only_available', 'only_selected', 'loop')
_ANIM_LOOP_MODES = ('INFINITE', 'STOP_END_FRAME', 'STOP_START_FRAME', 'RESTORE', 'BOUNCE')
_ANIM_MAX_FRAME = 1048574
# fps_base has nowhere to live in Swift, which keeps only the rate it makes.
_ANIM_FPS_BASE = [1.0]


def _anim_state():
    return dict(zip(_ANIM_FIELDS, _bk.anim_state_get()))


def _anim_update(**changes):
    state = _anim_state()
    state.update(changes)
    _bk.anim_state(*[float(state[k]) if k in ('subframe', 'fps') else int(state[k])
                     for k in _ANIM_FIELDS])


def _anim_clamp(value):
    return min(max(int(value), 0), _ANIM_MAX_FRAME)


class _AnimRenderSettings(_objects._Render):
    """`scene.render` — the resolution, from bpy/_objects.py, and the frame
    rate the timeline plays at. Blender has one RenderSettings for both."""

    __slots__ = ()

    def __setattr__(self, key, value):
        # The resolution's __setattr__ refuses any name that is not one of its
        # own fields; the rate's are properties, which set themselves.
        if key in ('fps', 'fps_base'):
            object.__setattr__(self, key, value)
        else:
            super().__setattr__(key, value)

    @property
    def fps(self):
        return int(round(_anim_state()['fps'] * _ANIM_FPS_BASE[0]))

    @fps.setter
    def fps(self, value):
        _anim_update(fps=max(1, int(value)) / _ANIM_FPS_BASE[0])

    @property
    def fps_base(self):
        return _ANIM_FPS_BASE[0]

    @fps_base.setter
    def fps_base(self, value):
        fps = self.fps
        _ANIM_FPS_BASE[0] = float(value)
        _anim_update(fps=fps / _ANIM_FPS_BASE[0])


# ---------------------------------------------------------------------------
# The transform tool settings, and the 3D cursor
#
# Snapping, the pivot point and proportional editing are Blender's
# `scene.tool_settings`; the 3D cursor is `scene.cursor`. In the simulator all
# of them are Swift's (BKScene.tools and BKScene.cursor), reached through
# `_bk.tool_state`, so a script, the header's menus and the N-panel change the
# same values. Resources/python/site/_blenderkit_tools.py is the other side on
# a device, and writes the same property names there.
#
# The sixteen scalars — eleven ints, then five doubles — are in one fixed
# order, spelled out here, in `_blenderkit_tools.report`, in `tool_state` in
# PythonBootstrap.c and in TransformToolsMirror.
# ---------------------------------------------------------------------------

_TOOL_FIELDS = ('use_snap', 'elements', 'individual', 'target', 'pivot',
                'proportional_edit', 'proportional_objects', 'connected', 'falloff',
                'automerge', 'snap_flags',
                'size', 'cursor_x', 'cursor_y', 'cursor_z', 'merge_threshold')
_TOOL_INTS = 11
# The bits of `snap_flags`: _blenderkit_tools.SNAP_FLAGS.
_TOOL_SNAP_FLAGS = ('use_snap_self', 'use_snap_nonedit', 'use_mesh_automerge_and_split',
                    'use_transform_skip_children', 'use_transform_data_origin')
_TOOL_ELEMENTS = ('INCREMENT', 'GRID', 'VERTEX', 'EDGE', 'FACE', 'VOLUME',
                  'EDGE_MIDPOINT', 'EDGE_PERPENDICULAR', 'FACE_MIDPOINT')
_TOOL_INDIVIDUAL = ('FACE_PROJECT', 'FACE_NEAREST')
_TOOL_TARGETS = ('CLOSEST', 'CENTER', 'MEDIAN', 'ACTIVE')
_TOOL_PIVOTS = ('BOUNDING_BOX_CENTER', 'CURSOR', 'INDIVIDUAL_ORIGINS',
                'MEDIAN_POINT', 'ACTIVE_ELEMENT')
_TOOL_FALLOFFS = ('SMOOTH', 'SPHERE', 'ROOT', 'INVERSE_SQUARE', 'SHARP', 'LINEAR',
                  'CONSTANT', 'RANDOM')
# proportional_size's and double_threshold's hard ranges, read from Blender
# 5.2.1's bl_rna.
_TOOL_SIZE_RANGE = (1e-5, 5000.0)
_TOOL_MERGE_RANGE = (0.0, 1.0)


def _tool_state():
    return dict(zip(_TOOL_FIELDS, _bk.tool_state_get()))


def _tool_update(**changes):
    state = _tool_state()
    state.update(changes)
    _bk.tool_state(*([int(state[k]) for k in _TOOL_FIELDS[:_TOOL_INTS]]
                     + [float(state[k]) for k in _TOOL_FIELDS[_TOOL_INTS:]]))


def _tool_bits(names, values):
    chosen = set(values)
    unknown = chosen - set(names)
    if unknown:
        raise TypeError('enum "%s" not found in %s' % (sorted(unknown)[0], names))
    return sum(1 << i for i, name in enumerate(names) if name in chosen)


def _tool_names(names, bits):
    return {name for i, name in enumerate(names) if bits & (1 << i)}


def _tool_index(names, value):
    if value not in names:
        raise TypeError('enum "%s" not found in %s' % (value, names))
    return names.index(value)


class _CursorVector(_BoundVector):
    """`scene.cursor.location`. A Vector that writes back, so
    `scene.cursor.location.x = 2` moves the cursor as it does in Blender."""

    __slots__ = ()

    def _flush(self):
        _tool_update(cursor_x=self._v[0], cursor_y=self._v[1], cursor_z=self._v[2])


class _ToolCursor:
    """`scene.cursor` — the 3D cursor. Only its location is kept: nothing in
    this app reads the cursor's rotation, and Swift has nowhere to put one."""

    @property
    def location(self):
        state = _tool_state()
        return _CursorVector((state['cursor_x'], state['cursor_y'], state['cursor_z']))

    @location.setter
    def location(self, value):
        x, y, z = (float(c) for c in tuple(value)[:3])
        _tool_update(cursor_x=x, cursor_y=y, cursor_z=z)


class _AnimToolSettings:
    """`scene.tool_settings`, for auto keying: the record button."""

    @property
    def use_keyframe_insert_auto(self):
        return bool(_anim_state()['autokey'])

    @use_keyframe_insert_auto.setter
    def use_keyframe_insert_auto(self, value):
        _anim_update(autokey=bool(value))

    @property
    def auto_keying_mode(self):
        return 'REPLACE_KEYS' if _anim_state()['replace'] else 'ADD_REPLACE_KEYS'

    @auto_keying_mode.setter
    def auto_keying_mode(self, value):
        if value not in ('ADD_REPLACE_KEYS', 'REPLACE_KEYS'):
            raise TypeError("enum \"%s\" not found in ('ADD_REPLACE_KEYS', 'REPLACE_KEYS')" % value)
        _anim_update(replace=value == 'REPLACE_KEYS')

    keyframe_type = 'KEYFRAME'

    # --- snapping ---

    @property
    def use_snap(self):
        return bool(_tool_state()['use_snap'])

    @use_snap.setter
    def use_snap(self, value):
        _tool_update(use_snap=bool(value))

    @property
    def snap_elements_base(self):
        return _tool_names(_TOOL_ELEMENTS, _tool_state()['elements'])

    @snap_elements_base.setter
    def snap_elements_base(self, value):
        bits = _tool_bits(_TOOL_ELEMENTS, value)
        # Measured in 5.2.1: Blender will not leave base and individual both
        # empty. set() here left {'VERTEX'} as it was while the individual
        # set was empty, and was taken with {'FACE_PROJECT'} in it. The shim
        # used to store the empty set either way, so the simulator and a
        # device disagreed about the same script.
        if bits or _tool_state()['individual']:
            _tool_update(elements=bits)

    # Blender's `snap_elements` is an alias for the base set — measured in
    # 5.2.1, except that it routes FACE_PROJECT and FACE_NEAREST into
    # snap_elements_individual. Nothing here writes it, so it is the plain
    # alias, and _blenderkit_tools writes snap_elements_base on a device.
    @property
    def snap_elements(self):
        return self.snap_elements_base

    @snap_elements.setter
    def snap_elements(self, value):
        self.snap_elements_base = value

    @property
    def snap_elements_individual(self):
        return _tool_names(_TOOL_INDIVIDUAL, _tool_state()['individual'])

    @snap_elements_individual.setter
    def snap_elements_individual(self, value):
        bits = _tool_bits(_TOOL_INDIVIDUAL, value)
        # The same rule from this side (measured: set() here stayed
        # {'FACE_PROJECT'} with the base set empty).
        if bits or _tool_state()['elements']:
            _tool_update(individual=bits)

    @property
    def snap_target(self):
        return _TOOL_TARGETS[_tool_state()['target']]

    @snap_target.setter
    def snap_target(self, value):
        _tool_update(target=_tool_index(_TOOL_TARGETS, value))

    # --- the pivot point ---

    @property
    def transform_pivot_point(self):
        return _TOOL_PIVOTS[_tool_state()['pivot']]

    @transform_pivot_point.setter
    def transform_pivot_point(self, value):
        _tool_update(pivot=_tool_index(_TOOL_PIVOTS, value))

    # --- proportional editing ---

    @property
    def use_proportional_edit(self):
        return bool(_tool_state()['proportional_edit'])

    @use_proportional_edit.setter
    def use_proportional_edit(self, value):
        _tool_update(proportional_edit=bool(value))

    @property
    def use_proportional_edit_objects(self):
        return bool(_tool_state()['proportional_objects'])

    @use_proportional_edit_objects.setter
    def use_proportional_edit_objects(self, value):
        _tool_update(proportional_objects=bool(value))

    @property
    def use_proportional_connected(self):
        return bool(_tool_state()['connected'])

    @use_proportional_connected.setter
    def use_proportional_connected(self, value):
        _tool_update(connected=bool(value))

    @property
    def proportional_edit_falloff(self):
        return _TOOL_FALLOFFS[_tool_state()['falloff']]

    @proportional_edit_falloff.setter
    def proportional_edit_falloff(self, value):
        _tool_update(falloff=_tool_index(_TOOL_FALLOFFS, value))

    @property
    def proportional_size(self):
        return _tool_state()['size']

    @proportional_size.setter
    def proportional_size(self, value):
        low, high = _TOOL_SIZE_RANGE
        _tool_update(size=min(max(float(value), low), high))

    # Blender's second name for proportional_size: measured in 5.2.1, writing
    # either one changes the other, so it is one field.
    @property
    def proportional_distance(self):
        return self.proportional_size

    @proportional_distance.setter
    def proportional_distance(self, value):
        self.proportional_size = value

    # --- Auto Merge, which BKScene.perform welds by after an edit-mode
    # transform, as Blender does ---

    @property
    def use_mesh_automerge(self):
        return bool(_tool_state()['automerge'])

    @use_mesh_automerge.setter
    def use_mesh_automerge(self, value):
        _tool_update(automerge=bool(value))

    @property
    def double_threshold(self):
        return _tool_state()['merge_threshold']

    @double_threshold.setter
    def double_threshold(self, value):
        low, high = _TOOL_MERGE_RANGE
        _tool_update(merge_threshold=min(max(float(value), low), high))

    # --- snapping's Target Selection ---

    def _snap_flag(self, name):
        return bool(_tool_state()['snap_flags'] & (1 << _TOOL_SNAP_FLAGS.index(name)))

    def _set_snap_flag(self, name, value):
        bit = 1 << _TOOL_SNAP_FLAGS.index(name)
        flags = _tool_state()['snap_flags']
        _tool_update(snap_flags=(flags | bit) if value else (flags & ~bit))

    @property
    def use_snap_self(self):
        return self._snap_flag('use_snap_self')

    @use_snap_self.setter
    def use_snap_self(self, value):
        self._set_snap_flag('use_snap_self', bool(value))

    @property
    def use_snap_nonedit(self):
        return self._snap_flag('use_snap_nonedit')

    @use_snap_nonedit.setter
    def use_snap_nonedit(self, value):
        self._set_snap_flag('use_snap_nonedit', bool(value))

    # --- Auto Merge's Split Edges & Faces, and the Options popover's Affect
    # Only: mirrored so the header shows them. The stand-in's transform does
    # not split edges or move origins alone, so a transform with either on is
    # refused rather than run as something else (_TransformOps). ---

    @property
    def use_mesh_automerge_and_split(self):
        return self._snap_flag('use_mesh_automerge_and_split')

    @use_mesh_automerge_and_split.setter
    def use_mesh_automerge_and_split(self, value):
        self._set_snap_flag('use_mesh_automerge_and_split', bool(value))

    @property
    def use_transform_skip_children(self):
        return self._snap_flag('use_transform_skip_children')

    @use_transform_skip_children.setter
    def use_transform_skip_children(self, value):
        self._set_snap_flag('use_transform_skip_children', bool(value))

    @property
    def use_transform_data_origin(self):
        return self._snap_flag('use_transform_data_origin')

    @use_transform_data_origin.setter
    def use_transform_data_origin(self, value):
        self._set_snap_flag('use_transform_data_origin', bool(value))


class _SceneAnimation:
    """Merged onto `_Scene` below, alongside its own frame_current and frame_set."""

    @property
    def frame_start(self):
        return _anim_state()['start']

    @frame_start.setter
    def frame_start(self, value):
        start = _anim_clamp(value)
        _anim_update(start=start, end=max(_anim_state()['end'], start))

    @property
    def frame_end(self):
        return _anim_state()['end']

    @frame_end.setter
    def frame_end(self, value):
        end = _anim_clamp(value)
        _anim_update(end=end, start=min(_anim_state()['start'], end))

    @property
    def frame_subframe(self):
        return 0.0

    @property
    def frame_float(self):
        return float(_anim_state()['current'])

    @property
    def use_preview_range(self):
        return bool(_anim_state()['preview'])

    @use_preview_range.setter
    def use_preview_range(self, value):
        state = _anim_state()
        if value and state['preview_start'] == 0 and state['preview_end'] == 0:
            # A preview range that was never set takes the scene range.
            _anim_update(preview=True, preview_start=state['start'], preview_end=state['end'])
        else:
            _anim_update(preview=bool(value))

    @property
    def frame_preview_start(self):
        return _anim_state()['preview_start']

    @frame_preview_start.setter
    def frame_preview_start(self, value):
        start = min(max(int(value), -_ANIM_MAX_FRAME), _ANIM_MAX_FRAME)
        _anim_update(preview_start=start, preview_end=max(_anim_state()['preview_end'], start))

    @property
    def frame_preview_end(self):
        return _anim_state()['preview_end']

    @frame_preview_end.setter
    def frame_preview_end(self, value):
        end = min(max(int(value), -_ANIM_MAX_FRAME), _ANIM_MAX_FRAME)
        _anim_update(preview_end=end, preview_start=min(_anim_state()['preview_start'], end))

    @property
    def show_keys_from_selected_only(self):
        return bool(_anim_state()['only_selected'])

    @show_keys_from_selected_only.setter
    def show_keys_from_selected_only(self, value):
        _anim_update(only_selected=bool(value))

    @property
    def playback_loop_mode(self):
        return _ANIM_LOOP_MODES[_anim_state()['loop']]

    @playback_loop_mode.setter
    def playback_loop_mode(self, value):
        if value not in _ANIM_LOOP_MODES:
            raise TypeError("enum \"%s\" not found in %s" % (value, _ANIM_LOOP_MODES))
        _anim_update(loop=_ANIM_LOOP_MODES.index(value))

    @property
    def render(self):
        return _AnimRenderSettings()

    @property
    def tool_settings(self):
        return _AnimToolSettings()


# Added rather than written into _Scene, and only where _Scene has no member of
# that name, so settings another part of the shim gives the scene keep theirs.
for _name, _member in list(vars(_SceneAnimation).items()):
    if not _name.startswith('__') and not hasattr(_Scene, _name):
        setattr(_Scene, _name, _member)
# Except the render settings, which bpy/_objects.py gave the scene for the
# resolution: these are those, with the rate added, so they replace them.
_Scene.render = _SceneAnimation.render

# Blender keeps the 3D cursor on the scene rather than in tool_settings, and
# nothing else in the shim gives _Scene one.
_Scene.cursor = property(lambda self: _ToolCursor())
